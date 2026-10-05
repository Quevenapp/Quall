# Compila o plugin no Windows e o instala em %ProgramData%\obs-studio\plugins.
#
# Gêmeo de `construir.sh`, com a mesma regra de fundo: **o alvo é o OBS instalado nesta máquina**,
# não um pacote pré-compilado das releases. O `obs-plugintemplate` faz o contrário, e é assim que
# se compila um módulo contra uma minor que a máquina não tem.
#
# Três coisas que este script resolve e que não são óbvias:
#
# 1. **O OBS instalado não traz `obs.lib`.** No macOS dá para linkar direto contra a biblioteca de
#    dentro do `OBS.app`; no Windows o linker precisa da biblioteca de **importação**, e ela só sai
#    de um build do libobs. Aqui ela é gerada da própria `obs.dll` instalada, por
#    `dumpbin /exports` → `.def` → `lib /def`. Mesma coisa para `w32-pthreads.lib`.
# 2. **`util/threading.h` inclui `<pthread.h>` sem condição**, e no MSVC esse cabeçalho é o do
#    `deps/w32-pthreads/` do obs-studio. `buscar-libobs.ps1` traz os dois.
# 3. vcvars64.bat e importado neste processo quando as ferramentas MSVC nao estao no PATH.
#
# -SemInstalar compila e copia documentos para build/data sem tocar o OBS instalado.
# O portao de compilacao usa esta opcao. A instalacao manual e uma etapa separada.
param([switch]$SemInstalar)
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


$raiz = (Resolve-Path "..\..").Path
$avisos = Join-Path $raiz "THIRD_PARTY_NOTICES.txt"
if (-not (Test-Path -LiteralPath $avisos -PathType Leaf) -or (Get-Item -LiteralPath $avisos).Length -eq 0) {
    throw "THIRD_PARTY_NOTICES.txt ausente ou vazio na raiz: $avisos"
}
$documentosLicenca = @(
    [pscustomobject]@{ Fonte = (Join-Path $PSScriptRoot "LICENSE"); Nome = "LICENSE" },
    [pscustomobject]@{ Fonte = (Join-Path $PSScriptRoot "LICENSE-SCOPE.md"); Nome = "LICENSE-SCOPE.md" },
    [pscustomobject]@{ Fonte = (Join-Path $raiz "LICENSE"); Nome = "LICENSE-MPL-2.0.txt" }
)
foreach ($documento in $documentosLicenca) {
    if (-not (Test-Path -LiteralPath $documento.Fonte -PathType Leaf) -or
        (Get-Item -LiteralPath $documento.Fonte).Length -eq 0) {
        throw "Documento de licenca ausente ou vazio: $($documento.Fonte)"
    }
}
$obsDir = if ($env:QUALL_OBS_DIR) { $env:QUALL_OBS_DIR } else { "C:\Program Files\obs-studio" }
$obsBin = Join-Path $obsDir "bin\64bit"

if (-not (Test-Path (Join-Path $obsBin "obs.dll"))) { throw "obs.dll não encontrada em $obsBin. O OBS está instalado?" }

# --- a versão do OBS instalado manda na tag dos cabeçalhos ------------------------------------
$versao = (Get-Item (Join-Path $obsBin "obs64.exe")).VersionInfo.FileVersion.Trim()
if (-not $env:QUALL_OBS_TAG) { $env:QUALL_OBS_TAG = $versao }
Write-Host "== OBS instalado: $versao (cabeçalhos na tag $($env:QUALL_OBS_TAG))"

Rodar { powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\buscar-libobs.ps1" } "buscar-libobs.ps1"

# --- ambiente do MSVC -------------------------------------------------------------------------
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "VS Build Tools com VCTools não encontrado" }
    $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
    Write-Host "== importando $vcvars"
    & cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
}

# --- obs.lib e w32-pthreads.lib, geradas das DLLs instaladas ----------------------------------
$libs = Join-Path $PSScriptRoot ".libobs\lib"
New-Item -ItemType Directory -Path $libs -Force | Out-Null

function Gerar-Lib([string]$dll, [string]$nome) {
    $saida = Join-Path $libs "$nome.lib"
    if (Test-Path $saida) { return }
    $exports = & dumpbin /exports $dll
    $nomes = @()
    foreach ($linha in $exports) {
        # ordinal / hint / RVA / nome. Entradas sem RVA são reexportações e não interessam.
        # **O nome pode vir seguido de ` = nome_decorado`** quando a DLL foi ligada com um `.def`,
        # que é o caso da `obs.dll`: 1.784 linhas no formato `blog = blog`. Ancorar o casamento no
        # fim da linha devolve zero símbolo e o erro fala de dumpbin, não de regex.
        if ($linha -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') { $nomes += $matches[1] }
    }
    if ($nomes.Count -eq 0) { throw "dumpbin não achou export nenhum em $dll" }
    $def = Join-Path $libs "$nome.def"
    Set-Content -Path $def -Value (@("EXPORTS") + $nomes) -Encoding ASCII
    Rodar { lib /nologo "/def:$def" /machine:x64 "/out:$saida" } "lib /def de $nome" | Out-Null
    Write-Host "== $nome.lib gerada de $(Split-Path -Leaf $dll): $($nomes.Count) símbolos"
}

Gerar-Lib (Join-Path $obsBin "obs.dll") "obs"
Gerar-Lib (Join-Path $obsBin "w32-pthreads.dll") "w32-pthreads"

# --- núcleo -----------------------------------------------------------------------------------
# **Sempre, e não só quando a `.lib` falta.** Ver o comentário gêmeo em `construir.sh`: o atalho
# custou uma medida em 07/09, entregando um plugin com um núcleo de cinco dias antes.
Write-Host "== compilando o núcleo (LTO desligado: dívida 17)"
$env:CARGO_PROFILE_RELEASE_LTO = "false"
Push-Location $raiz
Rodar { cargo build -p quall-ffi --release --locked --jobs 2 } "cargo build do quall-ffi"
Pop-Location

# --- cmake ------------------------------------------------------------------------------------
Write-Host "== cmake"
Rodar { cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo "-DQUALL_OBS_DIR=$obsDir" } "cmake configure" | Out-Null
Rodar { cmake --build build --parallel 2 } "cmake --build"

$avisosEmpacotados = Join-Path $PSScriptRoot "build\data\THIRD_PARTY_NOTICES.txt"
if (-not (Test-Path -LiteralPath $avisosEmpacotados -PathType Leaf) -or
    (Get-FileHash -LiteralPath $avisosEmpacotados).Hash -ne (Get-FileHash -LiteralPath $avisos).Hash) {
    throw "Os avisos empacotados nao correspondem ao THIRD_PARTY_NOTICES.txt atual da raiz."
}
foreach ($documento in $documentosLicenca) {
    $empacotado = Join-Path $PSScriptRoot ("build\data\" + $documento.Nome)
    if (-not (Test-Path -LiteralPath $empacotado -PathType Leaf) -or
        (Get-FileHash -LiteralPath $empacotado).Hash -ne (Get-FileHash -LiteralPath $documento.Fonte).Hash) {
        throw "A licenca empacotada nao corresponde a fonte atual: $($documento.Nome)"
    }
}

if ($SemInstalar) {
    Write-Host "== compilado sem instalar: build\quall-obs.dll e build\data (inclui licencas e THIRD_PARTY_NOTICES.txt)"
    exit 0
}

# --- instalar ---------------------------------------------------------------------------------
# **A pasta de plugins de usuário do OBS no Windows é `%ProgramData%`, não `%APPDATA%`.** Custou uma
# corrida inteira: o `.dll` estava em `%APPDATA%\obs-studio\plugins\quall-obs\bin\64bit\`, com o
# layout certo, e o diário do OBS **não tinha uma linha sequer** sobre ele — nem erro, nem aviso.
# Ele nunca foi procurado ali. `AddExtraModulePaths()` do `frontend/widgets/OBSBasic.cpp` usa
# `GetAppConfigPath` no macOS e `GetProgramDataPath` no Windows, e a assimetria não está em lugar
# nenhum da documentação de plugin. O sintoma foi "Source ID 'quall_fonte' not found".
#
# O layout dentro da pasta é `<plugin>/bin/64bit/<plugin>.dll` e `<plugin>/data/`.
# **O OBS aberto trava o `.dll` e este roteiro pendurava.** Medido em 07/09/2026: o build terminou
# às 12:49:22 e a sessão ficou parada **quase duas horas** sem escrever uma linha. O `Copy-Item`
# levanta `IOException` ("o arquivo está sendo usado por outro processo"), e com
# `$ErrorActionPreference = "Stop"` isso deveria abortar — mas numa sessão de SSH o erro não chega
# a lugar nenhum e o processo fica de pé. Falhar em silêncio já é ruim; pendurar é pior, porque
# quem espera não tem como distinguir de compilação lenta.
#
# Conferir antes custa uma chamada e transforma duas horas numa frase.
if (Get-Process obs64 -ErrorAction SilentlyContinue) {
    throw "o OBS esta aberto neste computador e mantem o quall-obs.dll travado. Feche o OBS e rode de novo."
}

$destino = Join-Path $env:ProgramData "obs-studio\plugins\quall-obs"
# Uma cópia em `%APPDATA%` de uma tentativa anterior não atrapalha, mas confunde quem for depurar.
$errado = Join-Path $env:APPDATA "obs-studio\plugins\quall-obs"
if (Test-Path $errado) { Remove-Item -Recurse -Force $errado }
New-Item -ItemType Directory -Path "$destino\bin\64bit" -Force | Out-Null
Copy-Item "build\quall-obs.dll" "$destino\bin\64bit\quall-obs.dll" -Force
if (Test-Path "build\quall-obs.pdb") { Copy-Item "build\quall-obs.pdb" "$destino\bin\64bit\" -Force }
if (Test-Path "$destino\data") { Remove-Item -Recurse -Force "$destino\data" }
Copy-Item -Recurse "build\data" "$destino\data"

$tam = [math]::Round((Get-Item "$destino\bin\64bit\quall-obs.dll").Length / 1MB, 2)
Write-Host "== instalado em $destino ($tam MiB)"
Write-Host "== símbolos exportados (só os do OBS devem aparecer):"
$ex = & dumpbin /exports "$destino\bin\64bit\quall-obs.dll"
foreach ($linha in $ex) {
    if ($linha -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') { Write-Host "   $($matches[1])" }
}
Write-Host "== dependências dinâmicas:"
$dep = & dumpbin /dependents "$destino\bin\64bit\quall-obs.dll"
foreach ($linha in $dep) { if ($linha -match '^\s+(\S+\.dll)\s*$') { Write-Host "   $($matches[1])" } }
