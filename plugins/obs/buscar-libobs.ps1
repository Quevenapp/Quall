# Busca os cabeçalhos do libobs numa **tag fixa**, com checkout esparso. Gêmeo de
# `buscar-libobs.sh`, com uma diferença que só existe aqui.
#
# No macOS o que falta do OBS instalado são os cabeçalhos do `libobs`. No Windows falta isso **e**
# os cabeçalhos do `w32-pthreads`: `libobs/util/threading.h` inclui `<pthread.h>` sem condição, e
# no MSVC esse `pthread.h` é o do `deps/w32-pthreads/` do próprio obs-studio. Sem ele, qualquer
# arquivo que inclua `obs-module.h` não compila.
#
# A tag precisa casar com o OBS instalado. O `LIBOBS_API_VER` que o módulo devolve é conferido pelo
# OBS no carregamento: major/minor mais novos que o host são recusados; patch é ignorado.
# Usar a tag instalada não substitui a prova de carga e de fluxo.
#
# **Este arquivo é UTF-8 com BOM, e o BOM não é enfeite.** O Windows PowerShell 5.1 — o único que o
# Dell tem — lê `.ps1` sem BOM como ANSI da página de código do sistema. Um "não" vira dois bytes
# soltos, o parser reclama de aspas não terminadas trinta linhas adiante, e o erro não tem nada a
# ver com a linha que ele aponta.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# **Segunda armadilha do PowerShell, e ela some se ninguém escrever:** com
# `$ErrorActionPreference = "Stop"`, um programa nativo que escreve no **stderr** vira exceção,
# mesmo terminando com código 0. O `git clone` escreve "Cloning into..." no stderr; o `cargo` e o
# `cmake` também falam por lá. Redirecionar com `2>&1` não salva — piora, porque transforma cada
# linha num `ErrorRecord`. Por isso todo comando nativo passa por `Rodar`, que baixa a guarda
# durante a chamada e confere o que de fato importa: o `$LASTEXITCODE`.
function Rodar {
    param([scriptblock]$bloco, [string]$oque)
    $antigo = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $bloco 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $antigo
    if ($LASTEXITCODE -ne 0) { throw "$oque falhou (codigo $LASTEXITCODE)" }
}


$tag = if ($env:QUALL_OBS_TAG) { $env:QUALL_OBS_TAG } else { "32.2.1" }
$destino = ".libobs"

if ((Test-Path "$destino\.tag") -and ((Get-Content "$destino\.tag" -Raw).Trim() -eq $tag)) {
    Write-Host "== cabeçalhos do libobs $tag já estão em $destino"
    exit 0
}

if (Test-Path $destino) { Remove-Item -Recurse -Force $destino }
New-Item -ItemType Directory -Path $destino | Out-Null
Push-Location $destino

# `--filter=blob:none --sparse` traz só a árvore; os blobs vêm no `sparse-checkout`. Um clone cheio
# do obs-studio passa de 400 MB e nós queremos dois diretórios de cabeçalho.
Rodar { git clone --depth 1 --branch $tag --filter=blob:none --sparse https://github.com/obsproject/obs-studio obs-studio } "git clone do obs-studio na tag $tag"
Rodar { git -C obs-studio sparse-checkout set libobs deps/w32-pthreads } "sparse-checkout"

if (-not (Test-Path "obs-studio\deps\w32-pthreads\pthread.h")) {
    throw "deps/w32-pthreads/pthread.h não veio no checkout esparso — a tag $tag mudou de layout?"
}

Set-Content -Path ".tag" -Value $tag -NoNewline
Pop-Location
Write-Host "== cabeçalhos do libobs $tag e w32-pthreads em $((Resolve-Path $destino).Path)"
