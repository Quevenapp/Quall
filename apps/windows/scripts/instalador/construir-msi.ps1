#Requires -Version 5.1
<#
  Constroi o instalador MSI do Quall Studio em Windows x64.

  NAO ASSINA. Assinar exige um certificado de assinatura de codigo do dono -- ver a secao
  "Assinatura" no README desta pasta, que traz o comando exato de signtool e onde parar.

  Uso:
    powershell -NoProfile -File construir-msi.ps1
    powershell -NoProfile -File construir-msi.ps1 -Versao 0.2.0
    powershell -NoProfile -File construir-msi.ps1 -SoEmpacotar    # pula o cargo

  ------------------------------------------------------------------------------------------------
  O QUE ELE JUNTA, E DE ONDE
  ------------------------------------------------------------------------------------------------

  O produto Windows sai de DOIS workspaces Cargo diferentes, e NENHUM DELES E O DA RAIZ:

    apps\windows                      -> quall-app.exe            (workspace proprio)
    integrations\camera-windows       -> quall_camera_fonte.dll   (workspace proprio, membro `fonte`)

  Os dois `Cargo.toml` declaram `[workspace]` por conta propria, com o mesmo motivo escrito em
  ambos: "so compila no Windows e nunca no host de desenvolvimento". A raiz nao os lista.

  ISTO JA QUEBROU ESTE SCRIPT, e a primeira execucao dele o pegou (2026-08-30, no Windows de teste). A versao
  anterior chamava

      cargo build --release -p quall-camera-fonte   (a partir da RAIZ)

  e recebia `error: package ID specification 'quall-camera-fonte' did not match any packages` --
  porque o pacote nao pertence ao workspace da raiz. O caminho do artefato tinha o mesmo engano:
  `target\release\quall_camera_fonte.dll` em vez de
  `integrations\camera-windows\target\release\...`. Os dois consertos sao a mesma frase: o pacote
  se compila DENTRO do workspace dele, e o `target\` e o de la.

  Este script copia os dois artefatos para uma area de estagio unica e e dela que o WiX monta o
  pacote -- em vez de o `.wxs` carregar dois caminhos relativos longos que quebram quando alguem
  move a pasta.

  `quall-app` exige `--features net`: sem `quall-core/webrtc` ele nao hospeda sessao, e um
  `quall-app.exe` incapaz de espelhar dentro de um instalador seria pior do que um erro de
  compilacao. Esse build arrasta OpenSSL vendorizado e libdatachannel em C++ -- minutos a frio.
#>
param(
    [string]$Versao = "0.1.0",
    [string]$Saida,
    [string]$Estagio,
    [switch]$SoEmpacotar,
    # Saida com nome reservado para revisao da Microsoft Store; ambos os caminhos sao sem monitor.
    # Esta opcao prepara o artefato; nao significa aprovacao da loja.
    [switch]$Loja,
    # Desliga o fragmento de firewall do .wxs, para o caso de a extensao nao estar instalada.
    [switch]$SemFirewall
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Saida)) { $Saida = Join-Path $PSScriptRoot $(if ($Loja) { "saida-loja" } else { "saida" }) }
if ([string]::IsNullOrWhiteSpace($Estagio)) { $Estagio = Join-Path $PSScriptRoot $(if ($Loja) { "estagio-loja" } else { "estagio" }) }
if (Test-Path (Join-Path $Saida "quall-driver.exe")) {
    throw "a pasta contem quall-driver.exe legado; use uma pasta de saida exclusiva para este release"
}

$aqui = $PSScriptRoot
$raiz = (Resolve-Path (Join-Path $aqui "..\..\..\..")).Path
Write-Output "raiz do repositorio: $raiz"
Write-Output "versao: $Versao"
Write-Output "minimo do produto: Windows 11 de 64 bits (build 22000); artefatos x64"

# ------------------------------------------------------------------------------------------------
# 1. Os dois binarios.
# ------------------------------------------------------------------------------------------------
$camera = Join-Path $raiz "integrations\camera-windows"
$targetApp = Join-Path $raiz "apps\windows\target\release-sem-monitor"
$exe = Join-Path $targetApp "release\quall-app.exe"
$dll = Join-Path $camera "target\release\quall_camera_fonte.dll"

if (-not $SoEmpacotar) {
    Write-Output ""
    $featuresApp = "net,loja"
    Write-Output "== cargo build --release --locked --bin quall-app --features $featuresApp --target-dir $targetApp  (apps\windows)"
    Push-Location (Join-Path $raiz "apps\windows")
    try { & cargo build --release --locked --jobs 2 --bin quall-app --features $featuresApp --target-dir $targetApp; if ($LASTEXITCODE -ne 0) { throw "cargo falhou no quall-app" } }
    finally { Pop-Location }

    Write-Output ""
    Write-Output "== cargo build --release -p quall-camera-fonte  (integrations\camera-windows)"
    Push-Location $camera
    try { & cargo build --release --locked --jobs 2 -p quall-camera-fonte; if ($LASTEXITCODE -ne 0) { throw "cargo falhou na DLL da camera" } }
    finally { Pop-Location }
}

foreach ($a in @($exe, $dll)) {
    if (-not (Test-Path $a)) { throw "artefato ausente: $a  (rode sem -SoEmpacotar)" }
}

# Confere a variante real, inclusive em -SoEmpacotar: o mesmo caminho Cargo usado com outra
# feature nao pode produzir um pacote deste release que carregue o driver. Latin-1 preserva cada byte
# (inclusive NUL); ASCII substituiria bytes acima de 127 e deixaria de ser uma comparacao exata.
$encodingBytes = [System.Text.Encoding]::GetEncoding(28591)
$appBytes = [System.IO.File]::ReadAllBytes($exe)
$appTexto = $encodingBytes.GetString($appBytes)
$marcador = "quall-distribuicao: release-sem-monitor-v2"
if (-not $appTexto.Contains($marcador)) { throw "variante do app incorreta: falta $marcador em $exe" }
# A variante publica nao distribui o driver. Nao leia blobs ou certificados externos aqui.
# Estes marcadores detectam uma mistura acidental com o codigo futuro; nao substituem a
# verificacao da receita de build e a revisao do conteudo do pacote final.
foreach ($nome in @("SudoVDA.inf", "SudoVDA.cat", "SudoVDA.dll", "SudoVDA.cer")) {
    if ($appTexto.Contains($nome)) { throw "release recusado: nome de payload de driver presente: $nome" }
}
Write-Output "marcador sem monitor confirmado; nomes de payload do driver ausentes do exe"
foreach ($proibido in @("quall-distribuicao: desenvolvimento-tela-estendida-v1", "CertAddEncodedCertificateToStore", "CertDeleteCertificateFromStore", "UpdateDriverForPlugAndPlayDevicesW", "SwDeviceCreate")) {
    if ($appTexto.Contains($proibido)) { throw "release recusado: entrada de driver presente: $proibido" }
}

# ------------------------------------------------------------------------------------------------
# 2. Area de estagio.
#
# Confere que o .exe e o .dll sao mesmo x64 antes de empacotar. Um MSI marcado `Bitness=always64`
# com um binario de 32 bits dentro instala em Program Files (x64) e o Frame Server -- que e x64 --
# nao carrega a DLL. O sintoma seria a camera aparecer na lista e nunca entregar imagem, que e o
# mesmo sintoma de meia duzia de outras coisas.
# ------------------------------------------------------------------------------------------------
function Arquitetura($caminho) {
    $fs = [System.IO.File]::OpenRead($caminho)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        $fs.Position = $peOff + 4
        $maquina = $br.ReadUInt16()
        switch ($maquina) { 0x8664 { "x64" } 0x14c { "x86" } 0xAA64 { "arm64" } default { ("0x{0:X}" -f $maquina) } }
    } finally { $fs.Dispose() }
}

function Subsistema($caminho) {
    $fs = [System.IO.File]::OpenRead($caminho)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { throw "$caminho sem assinatura PE" }
        # Campo Subsystem a 68 bytes do optional header (PE32 e PE32+), segundo PE Format.
        $fs.Position = $peOff + 24 + 68
        $br.ReadUInt16()
    } finally { $fs.Dispose() }
}
if ((Subsistema $exe) -ne 2) { throw "$exe usa subsistema de console; o produto exige Windows GUI (2)" }

Write-Output ""
Write-Output "== area de estagio: $Estagio"
Remove-Item $Estagio -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Estagio -Force | Out-Null
foreach ($a in @($exe, $dll)) {
    $arq = Arquitetura $a
    Write-Output ("   {0,-28} {1}" -f (Split-Path -Leaf $a), $arq)
    if ($arq -ne "x64") { throw "$a e $arq, nao x64 -- o Frame Server e x64 e nao carregaria a DLL" }
    Copy-Item $a $Estagio
}

# A varredura de remocao entra no estagio TAMBEM, e nao e detalhe de arrumacao.
#
# O `.wxs` a referenciava por caminho relativo (`Source="camera-desinstalar.ps1"`), e o `wix`
# resolve `Source` relativo ao DIRETORIO DE TRABALHO, nao ao `.wxs`. Como este script chama o `wix`
# com o caminho absoluto do `.wxs`, a primeira execucao morreu com
#
#     error WIX0103: Cannot find the File file 'camera-desinstalar.ps1'
#
# (2026-08-30, no Windows de teste, primeira vez que o `wix build` rodou.) Poe-la no estagio junto com os dois
# binarios faz o `$(var.Bin)` valer para os TRES arquivos que o pacote leva -- que ja era a ideia
# declarada no cabecalho deste script.
$varredura = Join-Path $aqui "camera-desinstalar.ps1"
if (-not (Test-Path $varredura)) { throw "artefato ausente: $varredura" }
Copy-Item $varredura $Estagio
Write-Output ("   {0,-28} {1}" -f "camera-desinstalar.ps1", "roteiro")

# Avisos de TODOS os componentes: o inventario completo, inclusive dependencias transitivas,
# acompanha o app tanto na variante avulsa quanto na de revisao da Store.
$avisos = Join-Path $raiz "THIRD_PARTY_NOTICES.txt"
if (-not (Test-Path $avisos)) { throw "artefato ausente: $avisos" }
Copy-Item $avisos $Estagio
Write-Output ("   {0,-28} {1}" -f "THIRD_PARTY_NOTICES.txt", "licencas completas")
foreach ($nomeLicenca in @("LICENSE", "LICENSE-SCOPE.md", "NOTICE.txt")) {
    $fonteLicenca = Join-Path $raiz $nomeLicenca
    if (-not (Test-Path -LiteralPath $fonteLicenca -PathType Leaf) -or (Get-Item -LiteralPath $fonteLicenca).Length -eq 0) {
        throw "licenca propria ausente ou vazia: $nomeLicenca"
    }
    Copy-Item -LiteralPath $fonteLicenca -Destination (Join-Path $Estagio $nomeLicenca)
    Write-Output ("   {0,-28} {1}" -f $nomeLicenca, "licenca propria")
}

# ------------------------------------------------------------------------------------------------
# 3. O WiX.
# ------------------------------------------------------------------------------------------------
$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    throw @"
'wix' nao esta no PATH. O WiX v5+ e uma ferramenta .NET:

    dotnet tool install --global wix --version 5.0.2
    wix extension add -g WixToolset.Util.wixext
    wix extension add -g WixToolset.Firewall.wixext

(Se o .NET SDK nao estiver instalado: https://dotnet.microsoft.com/download)
"@
}

New-Item -ItemType Directory -Path $Saida -Force | Out-Null
$msi = Join-Path $Saida $(if ($Loja) { "Quall-Studio-Loja-$Versao.msi" } else { "Quall-$Versao.msi" })

$args = @(
    "build", (Join-Path $aqui "Quall.wxs"),
    "-d", "Versao=$Versao",
    "-d", "Bin=$Estagio",
    "-arch", "x64",
    # `en-US`, e NAO `pt-BR`. Isto foi medido, nao escolhido.
    #
    # `-culture pt-BR` derrubou o primeiro `wix build` desta pasta (2026-08-30, no Windows de teste) com sete
    #
    #     error WIX0102: The localization variable !(loc.WixSchedFirewallExceptionsInstall)
    #     is unknown
    #
    # As extensoes `Firewall` e `Util` publicam as strings delas so em `en-US`, e o `wix` NAO cai
    # para outra cultura sozinho: com `-culture pt-BR` ele nao acha e para. A lista
    # `pt-BR;en-US` tambem nao resolve -- testada na mesma corrida, ela reprova igual (mudando so
    # de extensao, da `Firewall` para a `Util`). O que funciona e `en-US`, ou nenhuma cultura.
    #
    # E nao se perde nada: este `.wxs` NAO usa nenhum `!(loc.…)`, entao nada nosso e traduzido em
    # cultura nenhuma. O idioma do pacote e o `Language="1046"` do `<Package>`, que continua
    # pt-BR. O `-culture` so escolhe de que catalogo vem o texto de erro padrao das extensoes.
    "-culture", "en-US",
    "-o", $msi,
    "-ext", "WixToolset.Util.wixext"
)
if ($SemFirewall) { $args += @("-d", "SemFirewall=1") }
else              { $args += @("-ext", "WixToolset.Firewall.wixext") }
if ($Loja)        { $args += @("-d", "Loja=1") }

Write-Output ""
Write-Output "== wix $($args -join ' ')"
& wix @args
if ($LASTEXITCODE -ne 0) { throw "wix build falhou com codigo $LASTEXITCODE" }

Write-Output ""
Write-Output "pacote: $msi  ($([math]::Round((Get-Item $msi).Length / 1MB, 1)) MB)"

Write-Output "Release: somente app, sem monitor/tela estendida ou instalador do driver."
Write-Output "Este artefato exige assinatura, teste no Windows e revisao de certificacao; nao foi submetido."
