#Requires -Version 5.1
<#
  Monta o MSI do plugin do OBS para Windows: QuallOBS-<versao>-x64.msi. Ver LEIA.md, ao lado.

  Uso (no Dell, da raiz do repositorio):
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\obs\instalador\construir-msi.ps1
        compila (..\construir.ps1 -SemInstalar) e empacota o plugin desta arvore
    ... -Plugin C:\caminho\windows-x64.zip       empacota o ZIP publicado (pasta quall-obs dentro)
    ... -Plugin C:\caminho\quall-obs            empacota uma pasta quall-obs pronta (bin\64bit e data)
    ... -Versao 1.0.1 -ObsMinimo 32.2

  NAO ASSINA e NAO INSTALA. Instalar e com o msiexec, por quem testa.

  Este arquivo e ASCII de proposito: o Windows PowerShell 5.1 le .ps1 sem BOM como ANSI
  (armadilha 5 do README do plugin), e ASCII e igual nas duas leituras.

  O WiX e o do app (apps\windows\scripts\instalador\construir-msi.ps1): v5+, ferramenta .NET, com a
  extensao Util (CloseApplication). `-culture en-US` pelo mesmo motivo de la: as extensoes so
  publicam en-US, e o pacote nao tem texto localizado proprio (as mensagens levam ingles e
  portugues juntos).
#>
param(
    [string]$Plugin,
    [string]$Versao,
    [string]$ObsMinimo,
    [string]$Saida,
    [string]$Estagio
)
$ErrorActionPreference = "Stop"

$aqui = $PSScriptRoot
$pluginDir = (Resolve-Path (Join-Path $aqui "..")).Path
$raiz = (Resolve-Path (Join-Path $aqui "..\..\..")).Path
if ([string]::IsNullOrWhiteSpace($Saida)) { $Saida = Join-Path $aqui "saida" }
if ([string]::IsNullOrWhiteSpace($Estagio)) { $Estagio = Join-Path $aqui "estagio" }

# --- versao -----------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Versao)) {
    $cm = Get-Content -Raw (Join-Path $pluginDir "CMakeLists.txt")
    if ($cm -notmatch 'project\(quall-obs VERSION (\d+\.\d+\.\d+)') { throw "sem VERSION no CMakeLists.txt; passe -Versao" }
    $Versao = $matches[1]
}
if ($Versao -notmatch '^\d+\.\d+\.\d+$') { throw "versao invalida: $Versao (X.Y.Z)" }

# --- OBS minimo: o major.minor dos cabecalhos ---------------------------------------------------
# O OBS recusa major/minor de API mais novos que ele e ignora o patch (README do plugin).
if ([string]::IsNullOrWhiteSpace($ObsMinimo)) {
    $cfg = Join-Path $pluginDir ".libobs\obs-studio\libobs\obs-config.h"
    if (-not (Test-Path $cfg)) { throw "sem $cfg para tirar o OBS minimo; passe -ObsMinimo X.Y" }
    $txt = Get-Content -Raw $cfg
    if ($txt -notmatch '#define LIBOBS_API_MAJOR_VER (\d+)') { throw "LIBOBS_API_MAJOR_VER ausente em $cfg" }
    $maj = [int]$matches[1]
    if ($txt -notmatch '#define LIBOBS_API_MINOR_VER (\d+)') { throw "LIBOBS_API_MINOR_VER ausente em $cfg" }
    $ObsMinimo = "$maj.$([int]$matches[1])"
}
if ($ObsMinimo -notmatch '^(\d+)\.(\d+)(\.0)?$') { throw "OBS minimo invalido: $ObsMinimo (X.Y)" }
$omaj = [int]$matches[1]; $omin = [int]$matches[2]
$ObsMinimo = "$omaj.$omin"
# Uma versao abaixo do minimo, para o MinVersion do .wxs (ver o comentario das buscas la).
if ($omin -gt 0) { $abaixo = "$omaj.$($omin - 1).65535.65535" } else { $abaixo = "$($omaj - 1).65535.65535.65535" }

Write-Output "plugin do OBS: versao $Versao, OBS $ObsMinimo ou mais novo (MinVersion $abaixo)"

# --- o plugin ---------------------------------------------------------------------------------
Remove-Item $Estagio -Recurse -Force -ErrorAction SilentlyContinue
$destPlugin = Join-Path $Estagio "quall-obs"
New-Item -ItemType Directory -Path (Join-Path $destPlugin "bin\64bit") -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($Plugin)) {
    Write-Output "== compilando (construir.ps1 -SemInstalar)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginDir "construir.ps1") -SemInstalar
    if ($LASTEXITCODE -ne 0) { throw "construir.ps1 falhou (codigo $LASTEXITCODE)" }
    Copy-Item (Join-Path $pluginDir "build\quall-obs.dll") (Join-Path $destPlugin "bin\64bit\quall-obs.dll")
    Copy-Item -Recurse (Join-Path $pluginDir "build\data") (Join-Path $destPlugin "data")
} else {
    $origem = (Resolve-Path $Plugin).Path
    if ($origem -like "*.zip") {
        $zip = Join-Path $Estagio "zip"
        Expand-Archive -LiteralPath $origem -DestinationPath $zip -Force
        $achado = Get-ChildItem -Path $zip -Recurse -Directory -Filter "quall-obs" | Where-Object { Test-Path (Join-Path $_.FullName "bin\64bit\quall-obs.dll") } | Select-Object -First 1
        if (-not $achado) { throw "o ZIP nao tem quall-obs\bin\64bit\quall-obs.dll" }
        $origem = $achado.FullName
    }
    if (-not (Test-Path (Join-Path $origem "bin\64bit\quall-obs.dll"))) { throw "$origem nao e uma pasta quall-obs (falta bin\64bit\quall-obs.dll)" }
    Copy-Item (Join-Path $origem "bin\64bit\quall-obs.dll") (Join-Path $destPlugin "bin\64bit\quall-obs.dll")
    Copy-Item -Recurse (Join-Path $origem "data") (Join-Path $destPlugin "data")
}

# A lista fechada do .wxs. Um arquivo a mais (um locale novo) tem de entrar la antes de entrar aqui.
$esperados = @(
    "bin\64bit\quall-obs.dll",
    "data\LICENSE", "data\LICENSE-SCOPE.md", "data\LICENSE-MPL-2.0.txt", "data\THIRD_PARTY_NOTICES.txt",
    "data\locale\en-US.ini", "data\locale\pt-BR.ini"
) | Sort-Object
$base = (Resolve-Path $destPlugin).Path
$achados = Get-ChildItem -Path $base -Recurse -File | ForEach-Object { $_.FullName.Substring($base.Length + 1) } | Sort-Object
$diferenca = Compare-Object -ReferenceObject $esperados -DifferenceObject $achados
if ($diferenca) {
    $diferenca | ForEach-Object { Write-Output ("   {0} {1}" -f $_.SideIndicator, $_.InputObject) }
    throw "o plugin nao tem exatamente os arquivos que QuallOBS.wxs instala (<= falta, => sobra)"
}
foreach ($f in $esperados) {
    if ((Get-Item (Join-Path $base $f)).Length -eq 0) { throw "arquivo vazio: $f" }
}

# x64, e com os exports do OBS (texto ASCII da tabela de exports).
$dll = Join-Path $base "bin\64bit\quall-obs.dll"
$fs = [System.IO.File]::OpenRead($dll)
try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C; $pe = $br.ReadInt32()
    $fs.Position = $pe; if ($br.ReadUInt32() -ne 0x00004550) { throw "$dll sem assinatura PE" }
    $maquina = $br.ReadUInt16()
} finally { $fs.Dispose() }
if ($maquina -ne 0x8664) { throw ("{0} nao e x64 (maquina 0x{1:X})" -f $dll, $maquina) }
$texto = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($dll))
foreach ($s in @("obs_module_load", "obs_module_ver")) {
    if (-not $texto.Contains($s)) { throw "$dll nao exporta ${s}: nao e um plugin do OBS" }
}
$hash = (Get-FileHash -Algorithm SHA256 $dll).Hash.ToLower()
Write-Output ("   quall-obs.dll  x64  {0:N2} MiB  sha256 {1}" -f ((Get-Item $dll).Length / 1MB), $hash)

$icone = Join-Path $raiz "apps\windows\quall.ico"
if (-not (Test-Path $icone)) { throw "icone ausente: $icone" }
Copy-Item $icone (Join-Path $Estagio "quall.ico")

# --- WiX --------------------------------------------------------------------------------------
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    throw @"
'wix' nao esta no PATH. O WiX v5+ e uma ferramenta .NET:

    dotnet tool install --global wix
    wix extension add -g WixToolset.Util.wixext
"@
}
New-Item -ItemType Directory -Path $Saida -Force | Out-Null
$msi = Join-Path $Saida "QuallOBS-$Versao-x64.msi"
$argumentos = @(
    "build", (Join-Path $aqui "windows\QuallOBS.wxs"),
    "-d", "Versao=$Versao",
    "-d", "Estagio=$Estagio",
    "-d", "ObsMinimo=$ObsMinimo",
    "-d", "ObsAbaixoDoMinimo=$abaixo",
    "-arch", "x64",
    "-culture", "en-US",
    "-ext", "WixToolset.Util.wixext",
    "-o", $msi
)
Write-Output ""
Write-Output "== wix $($argumentos -join ' ')"
& wix @argumentos
if ($LASTEXITCODE -ne 0) { throw "wix build falhou com codigo $LASTEXITCODE" }

Write-Output ""
Write-Output ("pacote: {0}  ({1:N1} MB)" -f $msi, ((Get-Item $msi).Length / 1MB))
Write-Output "Nao assinado. Instalar:    msiexec /i `"$msi`" /l*v `"$Saida\instalar.log`""
Write-Output "Desinstalar:               msiexec /x `"$msi`" /l*v `"$Saida\desinstalar.log`""
