# Carregador isolado no Windows

A prova GPL-3.0-or-later usa a libobs efetiva e headers da mesma tag da instalação
OBS x64. As import libraries devem ser geradas das DLLs dessa instalação,
conforme plugins/obs/construir.ps1. Compile o plugin em uma pasta de build nova
e preserve a configuração, fontes exatos, hashes e logs; esta prova não instala.

Com o ambiente MSVC x64 já inicializado e variáveis de diretório explícitas:

```powershell
cl /nologo /std:c17 /utf-8 /MD /O2 /I"$Sdk/libobs" /I"$Sdk/deps/w32-pthreads" /I"$BuildPlugin/gerado" plugins/obs/bancada/prova-compatibilidade-windows.c /Fo"$SaidaNova/prova.obj" /Fe"$SaidaNova/prova.exe" /link /LIBPATH:"$ImportLibraries" obs.lib w32-pthreads.lib
$env:PATH = "$ObsInstalado/bin/64bit;" + $env:PATH
& "$SaidaNova/prova.exe" "$BuildPlugin/quall-obs.dll" "$BuildPlugin/data" "$ConfigNova"
```

Use paths com separador / nos três argumentos de execução, e uma pasta de
configuração nova fora das pastas pessoais OBS. Conferir código de saída e os
resultados nomeados. Se houver travamento, encerrar somente o próprio processo
de prova e preservar seus logs. Não declarar sucesso se houver timeout.

A prova carrega/inicializa/descarrega o módulo, confere traduções, propriedades
PIN OBS_TEXT_PASSWORD, registro da classe de fonte, flags de mídia e liberações
de recursos libobs. A inicialização abre descoberta mDNS e os logs omitem a lista
de aparelhos. Nenhuma fonte é criada e nenhum frame/áudio é recebido. Este
resultado não comprova frontend, fluxo de mídia, reconexão, latência ou câmera.
Logs de ambiente podem conter nomes/caminhos e devem ser revisados antes de publicação.
