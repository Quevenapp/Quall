#!/usr/bin/env python3
"""Compara imports VC++ dos dois PE aos exports do framework instalado, só leitura."""
import argparse,json,hashlib
from pathlib import Path
from preparar_msix import PE,exported_names,digest
p=argparse.ArgumentParser();p.add_argument('--payload',type=Path,required=True);p.add_argument('--framework',type=Path,required=True);p.add_argument('--saida',type=Path,required=True);a=p.parse_args()
if a.saida.exists():raise ValueError('Saída já existe')
r=dict(runtime_verified=False,scope='imports VC++ diretos do app e DLL e exports do framework CRT instalado; não é fechamento transitivo',framework=str(a.framework),files=[],errors=[])
for name in ['quall-app.exe','quall_camera_fonte.dll']:
 for entry in PE(a.payload/name).imports():
  dll=entry['dll']
  if not dll.lower().startswith(('msvcp','vcruntime','concrt')):continue
  f=a.framework/dll
  try:
   exports=exported_names(PE(f));missing=[s for s in entry['symbols'] if s not in exports]
   r['files'].append(dict(importer=name,dll=dll,framework_file=str(f),sha256=digest(f),symbols=len(entry['symbols']),missing=missing))
   r['errors'].extend(name+' -> '+dll+'!'+s for s in missing)
  except Exception as e:r['errors'].append(str(e))
a.saida.write_text(json.dumps(r,indent=2),encoding='utf-8');print(json.dumps(r,indent=2));raise SystemExit(bool(r['errors']))
