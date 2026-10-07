#!/usr/bin/env python3
"""Compara imports VC++ diretos/delay com exports do framework instalado, só leitura.

Store: payload apenas do app. Desktop separado: app e câmera DLL, por opção explícita.
Não prova carregamento, resolução transitiva de forwarders ou certificação da Store.
"""
import argparse
import hashlib
import json
from pathlib import Path
from verificar_pe import PE


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def exported_symbols(pe):
    address, size = pe.directory(0)
    if not address or size < 40:
        raise ValueError('Framework DLL export directory absent')
    offset = pe.rva(address, 40)
    base, functions, names = pe.unpack('<III', offset + 16)
    if not 0 < functions <= 65536 or names > functions:
        raise ValueError('Invalid framework export count')
    function_table, name_table, ordinal_table = pe.unpack('<III', offset + 28)
    ordinals = {base + i for i in range(functions)
                if pe.u32(pe.rva(function_table + i * 4, 4))}
    exported = set()
    for i in range(names):
        index = pe.u16(pe.rva(ordinal_table + i * 2, 2))
        if index >= functions or base + index not in ordinals:
            raise ValueError('Invalid named framework export index')
        exported.add(pe.string(pe.u32(pe.rva(name_table + i * 4, 4))))
    return exported, ordinals


def check(payload, framework, edition):
    expected = {'quall-app.exe'}
    if edition == 'desktop':
        expected.add('quall_camera_fonte.dll')
    if {f.name for f in payload.iterdir()} != expected:
        raise ValueError('Binary payload differs from explicit edition')
    result = dict(runtime_verified=False, edition=edition,
                  scope='imports VC++ diretos e delay do payload versus exports do framework CRT; não é fechamento transitivo',
                  framework=str(framework), binary_sha256={name: digest(payload / name) for name in sorted(expected)}, files=[], errors=[])
    for name in sorted(expected):
        importer = PE(payload / name)
        for delayed in (False, True):
            for entry in importer.imports(delayed):
                dll = entry['dll']
                if not dll.lower().startswith(('msvcp', 'vcruntime', 'concrt')):
                    continue
                file = framework / dll
                try:
                    target = PE(file)
                    if target.machine != importer.machine or target.is64 != importer.is64:
                        raise ValueError('Framework architecture differs from importer')
                    names, ordinals = exported_symbols(target)
                    missing = [s for s in entry['symbols'] if
                               (s['ordinal'] not in ordinals if isinstance(s, dict) else s not in names)]
                    result['files'].append(dict(importer=name, dll=dll, delayed=delayed,
                                                framework_file=str(file), sha256=digest(file),
                                                symbols=len(entry['symbols']), missing=missing))
                    result['errors'].extend(f'{name} -> {dll}!{s}' for s in missing)
                except (OSError, ValueError, KeyError) as error:
                    result['errors'].append(f'{name} -> {dll}: {error}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--framework', type=Path, required=True)
    parser.add_argument('--edition', choices=('store', 'desktop'), default='store')
    parser.add_argument('--saida', type=Path, required=True)
    args = parser.parse_args()
    if args.saida.exists():
        raise ValueError('Saída já existe')
    result = check(args.payload, args.framework, args.edition)
    args.saida.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    return bool(result['errors'])


if __name__ == '__main__':
    raise SystemExit(main())
