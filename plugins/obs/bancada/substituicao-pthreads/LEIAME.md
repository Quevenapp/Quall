# Prova de substituição dinâmica pthreads

Somente em processo/diretório de bancada próprio. Não instalar estas saídas
em OBS, Windows ou qualquer app. O plugin continua usando o núcleo estático
original e a API pública de OBS; esta prova não cria fonte nem captura mídia.

Obter o source oficial de obsproject/obs-studio na tag 32.2.1, commit
0052d024fd6a5ff1aa04c76cbdffd3085a5dfacc. Preserve COPYING, COPYING.LIB,
CONTRIBUTORS e os avisos de deps/w32-pthreads. Não copiar DLLs do sistema.
O marcador marca.c é LGPL-2.1-or-later e só adiciona um export de diagnóstico;
não muda os algoritmos de pthreads nem os termos dos arquivos originais.

Com MSVC x64 inicializado, um diretório novo e o source pthreads explícito:

```powershell
cmake -S plugins/obs/bancada/substituicao-pthreads -B $BuildNovo -G Ninja -DCMAKE_BUILD_TYPE=Release "-DSDK_PTHREADS=$Sdk/deps/w32-pthreads"
cmake --build $BuildNovo --parallel 2
```

Compilar prova-substituicao.c com os mesmos includes/import libraries de
PROVA-WINDOWS.md, em pasta de executável nova. Copiar somente w32-pthreads.dll
deste build para essa pasta. Use configuração nova e PATH de OBS apenas no
processo de prova. Rodar com os três argumentos binário/recursos/config como
na prova base. Conferir o marcador quall_pthread_rebuild_probe e o caminho da
DLL efetivamente carregada; o retorno deve ser 1000. Não substituir a DLL
instalada para fazer este teste. A prova conclui apenas seleção/substituição
dinâmica e carga/inicialização/encerramento isolados, sem mídia ou frontend.
