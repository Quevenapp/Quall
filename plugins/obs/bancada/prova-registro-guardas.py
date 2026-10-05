#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Guardas de escopo do logging; só lê código versionado, sem libobs, rede ou dados do usuário."""
from pathlib import Path
import re
import subprocess

raiz = Path(__file__).resolve().parents[3]
src = raiz / "plugins/obs/src"
casos = []


def conferir(nome, ok):
    casos.append((nome, bool(ok)))
    print(f"{'PASSOU' if ok else 'FALHOU'} {nome}")


def chamadas(texto, nome):
    for inicio in re.finditer(rf"\b{re.escape(nome)}\s*\(", texto):
        i = inicio.end()
        nivel = 1
        aspas = None
        while i < len(texto) and nivel:
            c = texto[i]
            if aspas:
                if c == "\\":
                    i += 2
                    continue
                if c == aspas:
                    aspas = None
            elif c in ('"', "'"):
                aspas = c
            elif c == "(":
                nivel += 1
            elif c == ")":
                nivel -= 1
            i += 1
        yield texto[inicio.start():i]


def corpo(texto, assinatura):
    inicio = texto.index(assinatura)
    abre = texto.index("{", inicio)
    # Esta função não tem chaves em suas strings; comparação literal do corpo operacional.
    nivel = 1
    fim = abre + 1
    while nivel:
        nivel += (texto[fim] == "{") - (texto[fim] == "}")
        fim += 1
    return texto[inicio:fim]


receptor = (src / "receptor.c").read_text()
som = (src / "som.c").read_text()
anterior_som = subprocess.run(
    ["git", "show", "HEAD:plugins/obs/src/som.c"], cwd=raiz, check=True,
    stdout=subprocess.PIPE, text=True,
).stdout
conferir("som_ligar operacional byte idêntico a HEAD",
         corpo(som, "bool som_ligar(") == corpo(anterior_som, "bool som_ligar("))
conferir("GUI usa texto original e argumentos originais",
         "vsnprintf(buf, sizeof(buf), texto_formato(chave), ap);" in receptor and
         'snprintf(r->estado, sizeof(r->estado), "%s", buf);' in receptor)
conferir("falha de conexão mantém mensagem completa só na GUI",
         'snprintf(erro, sizeof erro, "%s", quall_last_error());' in receptor and
         'dizer(r, "Quall.Estado.NaoConectou", erro, (int)status_conexao);' in receptor and
         '(void)va_arg(ap_diario, const char *);' in receptor)
conferir("nome do arquivo de gravação não foi alterado",
         's->grav = gravacao_abrir(obs_source_get_name(r->fonte));' in receptor)
header = (src / "quall-obs.h").read_text()
conferir("identificador salvo da fonte preservado", '#define QUALL_FONTE_ID "quall_fonte"' in header)
conferir("diga usa sink único", '#define diga(nivel, ...) registro_dizer(nivel, __VA_ARGS__)' in header)
prod = list(src.glob("*.c")) + [src / "quall-obs.h"]
logs = [(p, c) for p in prod for c in chamadas(p.read_text(), "diga")]
conferir("nenhum nome pessoal direto em diga", all("obs_source_get_name(" not in c for _, c in logs))
conferir("nenhum erro opaco direto em diga", all("quall_last_error(" not in c for _, c in logs))
conferir("som só publica cópia categorizada", '"fonte", motivo_do_diario);' in receptor and
         '"fonte", motivo);' not in receptor)
conferir("blog próprio só existe no sink", all(
    p.name == "quall-obs.h" or not list(chamadas(p.read_text(), "blog")) for p in prod))
conferir("pânico não copia payload", "UNUSED_PARAMETER(mensagem);" in (src / "plugin.c").read_text())
conferir("JSON RTP bruto não é registrado", 'diga(LOG_INFO, "  núcleo: %s", b);' not in receptor and
         'diga(LOG_INFO, "  núcleo: %s", linha.array);' in receptor)
conferir("IDRs quebrados e métricas aninhadas mantidos", all(
    chave in receptor for chave in ('"idrs_broken"', '"clock."', '"jitter_buffer."')))
conferir("null de libobs tratado como objeto NULL", 'nulo = objeto == NULL;' in receptor and
         'tipo == OBS_DATA_OBJECT && !objeto' in receptor)
conferir("tipos inválidos não viram zero", '"%s=indisponivel", nome' in receptor)
falhas = sum(not ok for _, ok in casos)
print(f"RESULTADO {len(casos)} guardas, {falhas} falhas; inspeção de fonte, sem runtime")
raise SystemExit(1 if falhas else 0)
