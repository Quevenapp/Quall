#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Preserva os avisos exatos dos crates adicionados à revisão de segurança.

Requer Python 3.11+, Cargo e crates previamente obtidos por cargo fetch --locked.
Não compila, publica ou assina. O inventário registra presença no lock, não
incorporação comprovada em cada binário. A base histórica permanece identificada.
"""
import hashlib
import io
import json
import pathlib
import re
import subprocess
import tarfile
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = "3172b188c29a010cd161c56bbeeb2cbcefbb220a"
BEGIN = "QUALL-CRYPTO-V3-NOTICES BEGIN"
END = "QUALL-CRYPTO-V3-NOTICES END"
OPENSSL_NOTICE_SOURCES = [
    "crypto/LPdir_nyi.c", "crypto/LPdir_unix.c", "crypto/LPdir_vms.c",
    "crypto/LPdir_win.c", "crypto/LPdir_win32.c", "crypto/LPdir_wince.c",
    "crypto/chacha/chacha_riscv.c", "crypto/seed/seed.c", "crypto/seed/seed_local.h",
    "crypto/x509/v3_pci.c", "crypto/x509/v3_pcia.c",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(*args):
    return subprocess.check_output(args, cwd=ROOT)


def main():
    lock_bytes = (ROOT / "Cargo.lock").read_bytes()
    current = tomllib.loads(lock_bytes.decode())["package"]
    old = tomllib.loads(command("git", "show", BASE + ":Cargo.lock").decode())["package"]
    old_keys = {(p["name"], p["version"]) for p in old}
    added = [p for p in current if (p["name"], p["version"]) not in old_keys
             and p.get("source", "").startswith("registry+")]
    current_keys = {(p["name"], p["version"]) for p in current}
    removed = [{"name": p["name"], "version": p["version"]} for p in old
               if (p["name"], p["version"]) not in current_keys]
    metadata = json.loads(command("cargo", "metadata", "--format-version", "1", "--locked", "--offline"))
    packages = {(p["name"], p["version"]): p for p in metadata["packages"]}
    staged = {}
    components = []
    notice_parts = [BEGIN, "Cargo.lock security revision v3; baseline " + BASE,
                    "Presence in the lock is not proof of incorporation into every platform binary."]
    for entry in sorted(added, key=lambda p: (p["name"], p["version"])):
        pkg = packages[(entry["name"], entry["version"])]
        directory = pathlib.Path(pkg["manifest_path"]).parent
        archive_path = directory.parents[2] / "cache" / directory.parent.name / (
            entry["name"] + "-" + entry["version"] + ".crate")
        archive_bytes = archive_path.read_bytes()
        if digest(archive_bytes) != entry["checksum"]:
            raise ValueError("Registry checksum differs from lock: " + entry["name"])
        archive = tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:*")
        prefix = entry["name"] + "-" + entry["version"] + "/"
        manifest = tomllib.loads(archive.extractfile(prefix + "Cargo.toml").read().decode())
        declared_license = manifest["package"].get("license")
        if declared_license != pkg.get("license"):
            raise ValueError("Cached manifest license differs from crate: " + entry["name"])
        files = sorted(p for p in directory.iterdir() if p.is_file()
                       and p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")))
        if pkg.get("license_file"):
            files = sorted(set(files + [pathlib.Path(pkg["license_file"])]))
        if entry["name"] == "openssl-src":
            # O wrapper Rust e a biblioteca nativa têm avisos separados. Inclui
            # também a licença do gerador Perl de build, sem afirmar incorporação.
            files = sorted(set(files + [p for p in (directory / "openssl").rglob("*")
                                       if p.is_file() and p.name.upper().startswith(
                                           ("LICENSE", "LICENCE", "COPYING", "NOTICE"))]))
        if not files or not pkg.get("license"):
            raise ValueError("License review required: " + entry["name"])
        notices = []
        for source in files:
            content = source.read_bytes()
            relative_source = source.relative_to(directory).as_posix()
            upstream = archive.extractfile(prefix + relative_source)
            if upstream is None or content != upstream.read():
                raise ValueError("Registry notice modified: " + entry["name"] + "/" + relative_source)
            destination = pathlib.PurePosixPath("docs/distribuicao/licencas/textos/crypto-v3") / (
                entry["name"] + "-" + entry["version"]) / relative_source
            staged[str(destination)] = content
            notices.append({"origem": str(destination), "sha256": digest(content)})
            # A cópia por crate conserva os bytes exatos; a concatenação remove somente
            # espaços finais de apresentação para os checks de whitespace do repositório.
            rendered = "\n".join(line.rstrip() for line in content.decode("utf-8").splitlines()).rstrip()
            notice_parts.extend(["", entry["name"] + " " + entry["version"] + " — " + relative_source,
                                 rendered])
        if entry["name"] == "openssl-src":
            for relative in OPENSSL_NOTICE_SOURCES:
                relative_source = "openssl/" + relative
                source = directory / relative_source
                content = source.read_bytes()
                upstream = archive.extractfile(prefix + relative_source)
                if upstream is None or content != upstream.read():
                    raise ValueError("OpenSSL source notice modified: " + relative_source)
                match = re.match(rb"\A(?:\s*/\*.*?\*/)+", content, re.S)
                if not match or b"Copyright" not in match.group():
                    raise ValueError("OpenSSL legal header review required: " + relative_source)
                legal = match.group()
                destination = pathlib.PurePosixPath("docs/distribuicao/licencas/textos/crypto-v3") / (
                    entry["name"] + "-" + entry["version"]) / (relative_source + ".notice.txt")
                staged[str(destination)] = legal
                notices.append({"origem": str(destination), "sha256": digest(legal),
                                "fonte_upstream": relative_source, "fonte_sha256": digest(content),
                                "extracao": "Contiguous leading C comments, exact bytes; available source, not binary incorporation."})
                rendered = "\n".join(line.rstrip() for line in legal.decode().splitlines()).rstrip()
                notice_parts.extend(["", entry["name"] + " " + entry["version"] + " — " + relative_source,
                                     rendered])
        archive.close()
        components.append({"componente": entry["name"], "versao": entry["version"],
                           "tipo": "rust-lock-v3", "licenca_declarada": pkg["license"],
                           "checksum_crate": entry["checksum"],
                           "fonte": "https://crates.io/crates/" + entry["name"] + "/" + entry["version"],
                           "repositorio_upstream": pkg.get("repository"), "avisos": notices})
    notice_parts.append(END)
    if (ROOT / "Cargo.lock").read_bytes() != lock_bytes:
        raise ValueError("Cargo.lock changed during inventory; rerun after the source is stable")
    inventory = {"base": BASE, "cargo_lock_sha256": digest(lock_bytes),
                 "metodo": "Current locked Cargo metadata; registry notice bytes checked against crate checksums.",
                 "limite": "Lock delta; final platform builds and incorporated dependency graphs require separate verification.",
                 "componentes": components, "removidos_do_lock": removed}
    for relative, content in staged.items():
        destination = ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    destination = ROOT / "docs/distribuicao/licencas/crypto-v3-lock.json"
    destination.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n")
    notices = ROOT / "THIRD_PARTY_NOTICES.txt"
    text = notices.read_text()
    if BEGIN in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1:
            raise ValueError("Unexpected existing v3 notice delimiters")
        start = text.index(BEGIN)
        finish = text.index(END, start) + len(END)
        text = text[:start] + text[finish:]
    notices.write_text(text.rstrip() + "\n\n" + "\n".join(notice_parts) + "\n")
    print(json.dumps({"added_packages": len(components), "preserved_notice_files": len(staged),
                      "removed_lock_packages": len(removed), "cargo_lock_sha256": digest(lock_bytes)}))


if __name__ == "__main__":
    main()
