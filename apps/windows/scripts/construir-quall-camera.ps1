#Requires -Version 5.1
<#
  Constroi o INSTALADOR AVULSO DA CAMERA VIRTUAL (`quall-camera.exe`), o arquivo que vai para a
  pagina do Quall (https://queven.com.br/quall/#camera) e para as releases do repositorio. A camera
  segue o molde do instalador do driver da tela estendida: um exe elevado com a DLL dentro.

  NAO ASSINA e NAO PUBLICA. Sem certificado de assinatura de codigo, o Windows mostra o aviso do
  SmartScreen ao abrir o exe baixado (o mesmo do quall-driver.exe).

  O que ele faz, e por que nesta ordem:

    1. compila a fonte da camera (`integrations\camera-windows`, release): o exe a EMBUTE;
    2. compila `quall-camera` com `QUALL_CAMERA_FONTE_DLL` apontando para ela (apps\windows\build.rs),
       sem o nucleo (`--no-default-features`: nada de OpenSSL nem libdatachannel, compila em
       segundos);
    3. confere NO ARTEFATO: x64, o manifesto `requireAdministrator`, e os bytes da DLL dentro do exe
       (um exe sem a fonte instalaria e diria "a fonte da camera nao veio dentro deste Quall");
    4. copia para -Saida, com LICENSE, LICENSE-SCOPE.md, NOTICE.txt e THIRD_PARTY_NOTICES.txt da raiz
       (o exe distribuido sozinho leva os avisos ao lado) e o SHA-256 num recibo.

  Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File construir-quall-camera.ps1 -Saida C:\saida\quall-camera
    powershell -NoProfile -ExecutionPolicy Bypass -File construir-quall-camera.ps1 -Raiz C:\src\Quall -Saida ...
#>
param(
    [Parameter(Mandatory = $true)][string]$Saida,
    [string]$Raiz,
    [string]$AlvoCargo
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path }
if ([string]::IsNullOrWhiteSpace($AlvoCargo)) { $AlvoCargo = Join-Path $Raiz "apps\windows\target\quall-camera" }
Write-Output "raiz do repositorio: $Raiz"

# 1. A fonte.
$camera = Join-Path $Raiz "integrations\camera-windows"
$dll = Join-Path $camera "target\release\quall_camera_fonte.dll"
Write-Output ""
Write-Output "== cargo build --release --locked -p quall-camera-fonte  (integrations\camera-windows)"
Push-Location $camera
try { & cargo build --release --locked -p quall-camera-fonte; if ($LASTEXITCODE -ne 0) { throw "cargo falhou na DLL da camera" } }
finally { Pop-Location }
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "artefato ausente: $dll" }

# 2. O instalador, com a fonte dentro.
Write-Output ""
Write-Output "== cargo build --release --locked --bin quall-camera --no-default-features  (apps\windows, QUALL_CAMERA_FONTE_DLL=$dll)"
Push-Location (Join-Path $Raiz "apps\windows")
$env:QUALL_CAMERA_FONTE_DLL = $dll
try {
    & cargo build --release --locked --bin quall-camera --no-default-features --target-dir $AlvoCargo
    if ($LASTEXITCODE -ne 0) { throw "cargo falhou no quall-camera" }
} finally { Pop-Location; Remove-Item Env:QUALL_CAMERA_FONTE_DLL -ErrorAction SilentlyContinue }
$exe = Join-Path $AlvoCargo "release\quall-camera.exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "artefato ausente: $exe" }

# 3. Conferir no artefato. Latin-1 preserva cada byte (inclusive NUL), como em construir-msi.ps1.
function Maquina($caminho) {
    $fs = [System.IO.File]::OpenRead($caminho)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $pe = $br.ReadInt32()
        $fs.Position = $pe + 4
        $br.ReadUInt16()
    } finally { $fs.Dispose() }
}
foreach ($a in @($exe, $dll)) {
    if ((Maquina $a) -ne 0x8664) { throw "$a nao e x64 -- o Frame Server e x64 e nao carregaria a DLL" }
}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$exeBytes = [System.IO.File]::ReadAllBytes($exe)
$exeTexto = $latin1.GetString($exeBytes)
if (-not $exeTexto.Contains('level="requireAdministrator"')) { throw "quall-camera.exe sem o manifesto requireAdministrator" }
$dllBytes = [System.IO.File]::ReadAllBytes($dll)
if (-not $exeTexto.Contains($latin1.GetString($dllBytes))) { throw "a fonte da camera nao esta dentro do quall-camera.exe" }
Write-Output ("conferido: x64, requireAdministrator, fonte embutida ({0} B)" -f $dllBytes.Length)

# 4. A saida.
New-Item -ItemType Directory -Path $Saida -Force | Out-Null
$final = Join-Path $Saida "quall-camera.exe"
Copy-Item -LiteralPath $exe -Destination $final -Force
$avisos = @("LICENSE", "LICENSE-SCOPE.md", "NOTICE.txt", "THIRD_PARTY_NOTICES.txt")
foreach ($nome in $avisos) {
    $origem = Join-Path $Raiz $nome
    if (-not (Test-Path -LiteralPath $origem -PathType Leaf) -or (Get-Item -LiteralPath $origem).Length -eq 0) {
        throw "aviso ausente ou vazio na raiz: $origem"
    }
    Copy-Item -LiteralPath $origem -Destination (Join-Path $Saida $nome) -Force
}
# O commit da fonte vai no recibo (o binario publicado tem de sair de um commit publico). Sem git
# no PATH, ou fora de um clone, fica vazio.
$commit = $null
try {
    $ErrorActionPreference = "Continue"
    $lido = & git -C $Raiz rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = "$lido".Trim() }
} catch { $commit = $null } finally { $ErrorActionPreference = "Stop" }
$recibo = [ordered]@{
    arquivo = "quall-camera.exe"
    bytes = (Get-Item -LiteralPath $final).Length
    sha256 = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash
    sha256_fonte_embutida = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    assinado = $false
    commit_da_fonte = $commit
    avisos = $avisos
}
$recibo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Saida "quall-camera.recibo.json") -Encoding UTF8
Write-Output ""
Write-Output ($recibo | ConvertTo-Json)
Write-Output "pronto: $final  (nao assinado; o SmartScreen avisa ao abrir o arquivo baixado)"
