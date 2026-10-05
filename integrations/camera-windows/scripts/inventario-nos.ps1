# Inventario dos nos de camera virtual desta maquina -- SOMENTE LEITURA.
#
# Existe porque "ha N nos numa maquina que deveria ter um" e um diagnostico que se prova ou se
# desmente em trinta segundos, e porque a resposta mudou o conserto: nem todo no VCAMDEVAPI e
# nosso. Nesta bancada, um deles e a Camera Conectada do proprio Windows (Vincular ao Celular),
# fonte C:\Windows\System32\CrossDeviceVirtualCameraSource.dll -- confirmado pelo usuario.
# Apagar aquele no tiraria um recurso dele, e a primeira versao do remover.ps1 aceitava o hash sem
# perguntar de quem era.
#
# TRES estados, e nao dois. "Nosso" e "de outros" nao cobrem o caso que apareceu de verdade: um no
# SEM CustomCaptureSourceClsid, em que o criterio de dono nao tem em que se apoiar. Chamar isso de
# "de outros" faz a guarda que protege a camera do usuario proteger tambem o nosso proprio lixo.
# O terceiro estado e DONO DESCONHECIDO, e ele e uma pergunta, nao um veredito.
#
# Nao exige administrador: so le o registro.
#
# Uso:  powershell -ExecutionPolicy Bypass -File inventario-nos.ps1 [-Sonda <caminho do exe>]
param(
    [string]$Clsid = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}",
    [string]$Sonda = ""
)
$ErrorActionPreference = "Continue"

$enum = "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\VCAMDEVAPI"
$dc   = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses"

# ---------------------------------------------------------------------------------------------
# NAO ha lista fixa de classes de interface aqui, e isso custou uma correcao.
#
# A versao anterior deste script (e o remover.ps1) trazia duas classes escritas a mao --
# KSCATEGORY_VIDEO_CAMERA e KSCATEGORY_CAPTURE -- porque era o que o README da frente dizia
# ("os tres lugares do registro"). Medido em 2026-08-27: MFCreateVirtualCamera publica o no em
# QUATRO classes, nao duas:
#
#   {e5323777-f976-4f5b-9b55-b94699c46e44}   KSCATEGORY_VIDEO_CAMERA
#   {65e8773d-8f56-11d0-a3b9-00a0c9223196}   KSCATEGORY_CAPTURE
#   {6994ad05-93ef-11d0-a3cc-00a0c9223196}   KSCATEGORY_VIDEO
#   {588c8d20-c0e3-4fd3-b511-8f2f692156f8}
#
# Sao "cinco lugares", nao tres. Conferir so as duas conhecidas deixa duas para tras e faz a
# ferramenta dizer "removido inteiro" sobre uma remocao pela metade -- que e exatamente como
# nasce o fantasma. Por isso aqui se PROCURA em todas as classes, em vez de listar.
# ---------------------------------------------------------------------------------------------
function ClassesDoNo($hash) {
    Get-ChildItem $dc -ErrorAction SilentlyContinue | ForEach-Object {
        $n = @(Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like ("*#" + $hash + "#*") }).Count
        if ($n -gt 0) { $_.PSChildName }
    }
}

# A chave que guarda o nome e o dono NAO fica direto sob a interface: ha um nivel a mais, o
# "reference string" da interface (#{FCEBBA03-...}), e so abaixo dele vem "Device Parameters".
# Um dump com -Recurse imprime os dois no mesmo nivel e esconde isso -- foi assim que a primeira
# versao desta funcao construiu um caminho que nunca existiu e devolveu "(sem FriendlyName)" para
# TODOS os nos, o que teria feito o inventario declarar que nenhum deles era nosso.
# Por isso aqui nao se CONSTROI caminho: procura-se a chave e usa-se o PSPath dela.
function ParametrosDoNo($hash) {
    foreach ($classe in (ClassesDoNo $hash)) {
        $iface = Get-ChildItem "$dc\$classe" -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSChildName -like ("*#" + $hash + "#*") } | Select-Object -First 1
        if (-not $iface) { continue }
        # -ErrorAction SilentlyContinue tambem cobre a subchave "Properties", cuja ACL nega leitura.
        $dp = Get-ChildItem $iface.PSPath -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -eq "Device Parameters" } | Select-Object -First 1
        if (-not $dp) { continue }
        $p = Get-ItemProperty -LiteralPath $dp.PSPath -ErrorAction SilentlyContinue
        if ($p -and ($p.CustomCaptureSourceClsid -or $p.FriendlyName)) { return $p }
    }
    return $null
}

# Quem a enumeracao REALMENTE entrega. Um no pode existir no registro e nao aparecer para app
# nenhum -- e essa e a diferenca entre "N nos" e "N cameras", que foi o cerne do diagnostico
# errado. Sem a sonda, cai para o Get-PnpDevice, que responde presente/ausente mas nao diz o nome
# que o app ve.
$vistos = @()
$temSonda = $false
if ($Sonda -and (Test-Path $Sonda)) {
    $temSonda = $true
    $saida = & $Sonda listar 2>&1 | Out-String
    $vistos = [regex]::Matches($saida, "swd#vcamdevapi#([0-9a-fA-F]{64})#") |
              ForEach-Object { $_.Groups[1].Value.ToUpper() } | Select-Object -Unique
}

$nos = @()
Get-ChildItem $enum -ErrorAction SilentlyContinue | ForEach-Object {
    $hash = $_.PSChildName
    $p = ParametrosDoNo $hash
    $fonte = $null; $nome = $null
    if ($p) { $fonte = $p.CustomCaptureSourceClsid; $nome = $p.FriendlyName }
    $pnp = Get-PnpDevice -InstanceId "SWD\VCAMDEVAPI\$hash" -ErrorAction SilentlyContinue
    $estado = if ($fonte -eq $Clsid) { "NOSSO" } elseif ($fonte) { "DE OUTROS" } else { "DONO DESCONHECIDO" }
    $nos += [pscustomobject]@{
        Hash      = $hash
        Nome      = $(if ($nome) { $nome } else { "(sem FriendlyName de interface)" })
        Fonte     = $(if ($fonte) { $fonte } else { "(sem CustomCaptureSourceClsid)" })
        Estado    = $estado
        Pnp       = $(if ($pnp) { $pnp.Status } else { "(ausente)" })
        Classes   = @(ClassesDoNo $hash).Count
        Enumerado = $(if ($temSonda) { $vistos -contains $hash.ToUpper() } else { "?" })
    }
}

Write-Output ("Nos SWD\VCAMDEVAPI: " + $nos.Count)
Write-Output ""
foreach ($n in $nos) {
    Write-Output ("  " + $n.Hash)
    Write-Output ("     estado                : " + $n.Estado)
    Write-Output ("     nome visto pelos apps : " + $n.Nome)
    Write-Output ("     fonte (CLSID)         : " + $n.Fonte)
    Write-Output ("     PnP                   : " + $n.Pnp)
    Write-Output ("     classes de interface  : " + $n.Classes)
    Write-Output ("     aparece na enumeracao : " + $n.Enumerado)
    Write-Output ""
}

$nossos  = @($nos | Where-Object { $_.Estado -eq "NOSSO" })
$alheios = @($nos | Where-Object { $_.Estado -eq "DE OUTROS" })
$orfaos  = @($nos | Where-Object { $_.Estado -eq "DONO DESCONHECIDO" })

Write-Output "----- resumo -----"
Write-Output ("  do Quall          : " + $nossos.Count)
Write-Output ("  de outros donos   : " + $alheios.Count + "   <- NAO APAGUE. Veja o CLSID de cada um.")
Write-Output ("  dono desconhecido : " + $orfaos.Count)

if ($orfaos.Count -gt 0) {
    Write-Output ""
    Write-Output "SOBRE OS DE DONO DESCONHECIDO -- leia antes de apagar qualquer um:"
    Write-Output "  Sem CustomCaptureSourceClsid o Frame Server nao tem o que instanciar, entao um no"
    Write-Output "  assim NAO SERVE VIDEO A NINGUEM. Ele nao e uma camera de alguem: e uma carcaca."
    Write-Output "  Mesmo assim, 'nao sei de quem e' nao autoriza apagar por conta propria -- o dono"
    Write-Output "  pode ser um software do usuario que repoe o valor ao abrir. Confira se o PnP diz"
    Write-Output "  'Desconectado'/'Unknown' E se ele nao aparece na enumeracao; so entao use"
    Write-Output "  'remover.ps1 -Orfao', que exige as duas condicoes e recusa qualquer no presente."
    foreach ($n in $orfaos) {
        Write-Output ("  carcaca: " + $n.Hash + "  (PnP " + $n.Pnp + ", enumera " + $n.Enumerado + ")")
        Write-Output ("     powershell -ExecutionPolicy Bypass -File remover.ps1 -Orfao -SoONo -ManterDll -Hash " + $n.Hash)
    }
}

if ($nossos.Count -gt 1) {
    Write-Output ""
    Write-Output "DUPLICIDADE do Quall: mais de um no com o nosso CLSID."
    Write-Output "O vivo e o que aparece na enumeracao; os outros sao cadaveres de rodadas anteriores."
    Write-Output "Lembre que MFCreateVirtualCamera com o mesmo CLSID e um NOME NOVO cria no novo:"
    Write-Output "renomear sem remover antes nao renomeia, duplica."
    foreach ($n in $nossos) {
        if ($n.Enumerado -eq $false) {
            Write-Output ("  cadaver: " + $n.Hash + "  (" + $n.Nome + ")")
            Write-Output ("     powershell -ExecutionPolicy Bypass -File remover.ps1 -ManterDll -SoONo -Hash " + $n.Hash)
        }
    }
}
