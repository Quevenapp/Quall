#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Aplica os quatro assets exatos da receita oficial; nunca substitui icones de controle."""
from pathlib import Path
import json,hashlib,shutil
BASE=Path(__file__).resolve().parents[2]
MANIFEST=BASE/'tools/icones/overlays/quall-studio-1.0.0/manifesto.json'
for asset in json.loads(MANIFEST.read_text())['assets']:
    source=BASE/asset['input'];destination=BASE/asset['destination']
    if hashlib.sha256(source.read_bytes()).hexdigest()!=asset['sha256']:
        raise SystemExit('Hash de asset divergente: '+asset['input'])
    destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,destination)
print('Marca oficial conferida e aplicada aos quatro destinos; controles preservados.')
