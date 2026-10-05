# Prototipo do pacote MSIX do componente de camera virtual; nao e o pacote do app de produto.
# Apenas empacota: nao assina, instala, altera Modo de Desenvolvedor ou certificados.
# Os caminhos de entrada e saida sao parametros explicitos; o executavel e a sonda.
param(
    [Parameter(Mandatory = $true)][string]$Dll,
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Manifesto,
    [Parameter(Mandatory = $true)][string]$Assets,
    [Parameter(Mandatory = $true)][string]$Saida,
    [string]$ScriptsOrigem = (Split-Path -Parent $Manifesto | Split-Path -Parent | Join-Path -ChildPath "scripts"),
    [string]$Staging = "$env:TEMP\quall-camera-msix-staging"
)
$ErrorActionPreference = "Stop"

# O manifesto fica em integrations/camera-windows/msix: usar o checkout, nao uma copia dos avisos.
# O caminho obrigatorio de -Manifesto identifica explicitamente o checkout.
$pastaMsix = Split-Path -Parent $Manifesto
$raizDoCheckout = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $pastaMsix))
$avisos = Join-Path $raizDoCheckout "THIRD_PARTY_NOTICES.txt"
if (-not (Test-Path -LiteralPath $avisos -PathType Leaf) -or (Get-Item -LiteralPath $avisos).Length -eq 0) {
    throw "THIRD_PARTY_NOTICES.txt ausente ou vazio na raiz do checkout: $avisos"
}

function localizarMakeappx {
    $candidatos = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if (-not $candidatos) {
        throw "makeappx.exe nao encontrado sob Windows Kits. Instale o Windows SDK ou informe o caminho."
    }
    return $candidatos[0].FullName
}

$makeappx = localizarMakeappx
Write-Output "makeappx: $makeappx"

# 1. Area de estagio limpa, com a arvore que o pacote vai conter: manifesto, assets, e o payload
#    (DLL + scripts de instalacao/remocao). O manifesto referencia "quall-camera-sonda.exe" como
#    Application/Executable — ver o comentario no proprio AppxManifest.xml sobre isso ser um
#    placeholder, nao o app de produto.
Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Staging -Force | Out-Null
Copy-Item $Manifesto (Join-Path $Staging "AppxManifest.xml")
Copy-Item $Assets (Join-Path $Staging "Assets") -Recurse
Copy-Item $Dll (Join-Path $Staging "quall_camera_fonte.dll")
Copy-Item $Exe (Join-Path $Staging "quall-camera-sonda.exe")
Copy-Item -LiteralPath $avisos -Destination (Join-Path $Staging "THIRD_PARTY_NOTICES.txt")
foreach ($nomeLicenca in @("LICENSE", "LICENSE-SCOPE.md", "NOTICE.txt")) {
    $fonteLicenca = Join-Path $raizDoCheckout $nomeLicenca
    if (-not (Test-Path -LiteralPath $fonteLicenca -PathType Leaf) -or (Get-Item -LiteralPath $fonteLicenca).Length -eq 0) {
        throw "licenca propria ausente ou vazia: $nomeLicenca"
    }
    Copy-Item -LiteralPath $fonteLicenca -Destination (Join-Path $Staging $nomeLicenca)
}
New-Item -ItemType Directory -Path (Join-Path $Staging "scripts") -Force | Out-Null
Copy-Item (Join-Path $ScriptsOrigem "instalar.ps1") (Join-Path $Staging "scripts\instalar.ps1")
Copy-Item (Join-Path $ScriptsOrigem "remover.ps1") (Join-Path $Staging "scripts\remover.ps1")
Write-Output "area de estagio: $Staging"

# 2. makeappx valida o manifesto contra o schema e os assets referenciados antes de empacotar —
#    e a primeira prova mecanica de que o manifesto e valido, independente de assinatura.
Remove-Item $Saida -Force -ErrorAction SilentlyContinue
& $makeappx pack /d $Staging /p $Saida /o
if ($LASTEXITCODE -ne 0) {
    throw "makeappx falhou com codigo $LASTEXITCODE — o manifesto ou os assets tem um problema; veja a saida acima."
}
Write-Output "pacote gerado: $Saida"

Write-Output ""
Write-Output "NAO ASSINADO. Este prototipo exige validacao nativa e assinatura antes de distribuicao."
Write-Output "Nenhuma instalacao, configuracao de seguranca ou certificado foi alterado."
Write-Output ""
Write-Output "Para remover: Get-AppxPackage Quven.Quall | Remove-AppxPackage"
Write-Output "Isso desinstala o PACOTE, mas nao desfaz o que o instalador dentro dele registrou em"
Write-Output "HKLM (DLL + regsvr32 + no da camera) — para isso, rode scripts\remover.ps1 antes."
