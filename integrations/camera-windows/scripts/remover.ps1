# Remove um no de camera virtual -- pela via SUPORTADA, e conferindo tudo que ele publica.
#
# ATENCAO, mudou duas vezes em 2026-08-27. Leia as duas.
#
# 1) O procedimento por registro NAO FUNCIONA. A versao original apagava as tres chaves a mao; as
#    duas formas falham:
#      Remove-Item -Recurse -> "Nao e possivel excluir uma arvore de subchave porque a subchave
#                              nao existe" (a subchave Properties do ramo Enum tem ACL propria)
#      reg delete /f        -> ExitCode 1, mesma causa
#    O ramo HKLM\SYSTEM\CurrentControlSet\Enum e protegido: administrador NAO apaga. O caminho
#    certo e `pnputil /remove-device "SWD\VCAMDEVAPI\<hash>"`.
#
# 2) NAO sao tres lugares, sao CINCO, e a primeira correcao deste script conferiu so tres.
#    MFCreateVirtualCamera publica o no em QUATRO classes de interface:
#      {e5323777-...} VIDEO_CAMERA   {65e8773d-...} CAPTURE
#      {6994ad05-...} VIDEO          {588c8d20-...}
#    Conferir so as duas conhecidas e dizer "removido inteiro" e como se produz o fantasma
#    "AvStream Media Device". Este script agora PROCURA as classes em vez de listar.
#
# E o que ainda nao esta resolvido, dito aqui porque quem usa este script precisa saber:
# **a remocao pode nao sobreviver a um reinicio.** Em 2026-08-27 um no removido por pnputil, com a
# remocao conferida no registro na hora, VOLTOU depois do reboot -- sem FriendlyName, sem
# CustomCaptureSourceClsid, PnP "Desconectado" e fora da enumeracao. Depois de remover, CONFIRA
# DE NOVO apos o proximo reinicio antes de declarar a maquina limpa.
#
# `IMFVirtualCamera::Remove()` continua nao servindo: S_OK em 42 ms e nao remove nada.
#
# EXIGE ADMINISTRADOR.
#
# Uso:
#   remover.ps1 -Hash <hash>                          # remove o no e desfaz a instalacao
#   remover.ps1 -Hash <hash> -SoONo -ManterDll        # so o no (limpeza de duplicidade)
#   remover.ps1 -Hash <hash> -Orfao -SoONo -ManterDll # carcaca sem dono, com as travas do -Orfao
#
# Descubra o hash com inventario-nos.ps1, que diz de QUEM e cada no.
param(
    [Parameter(Mandatory = $true)][string]$Hash,
    [string]$Dll = "C:\Program Files\Quall\quall_camera_fonte.dll",
    [string]$Destino = "C:\Program Files\Quall",
    [string]$Clsid = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}",
    [switch]$ManterDll,
    # Apaga so o no de dispositivo, sem mexer no registro COM nem na DLL. E o modo de limpar
    # DUPLICIDADE: os cadaveres saem, o no vivo e a instalacao ficam.
    [switch]$SoONo,
    # Permite remover um no SEM CustomCaptureSourceClsid -- mas so se ele estiver ausente do PnP.
    # Um no sem fonte nao serve video a ninguem; um no PRESENTE pode ser software vivo do usuario
    # que repoe o valor ao abrir, e esse nao se toca.
    [switch]$Orfao,
    # Passa por cima de TODA conferencia de dono. Ultimo recurso, e nao ha desfazer.
    [switch]$Forcar
)
$ErrorActionPreference = "Stop"

$dc = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses"

function ClassesDoNo($hash) {
    Get-ChildItem $dc -ErrorAction SilentlyContinue | ForEach-Object {
        $n = @(Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like ("*#" + $hash + "#*") }).Count
        if ($n -gt 0) { $_.PSChildName }
    }
}

function ParametrosDoNo($hash) {
    foreach ($classe in (ClassesDoNo $hash)) {
        $iface = Get-ChildItem "$dc\$classe" -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSChildName -like ("*#" + $hash + "#*") } | Select-Object -First 1
        if (-not $iface) { continue }
        $dp = Get-ChildItem $iface.PSPath -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -eq "Device Parameters" } | Select-Object -First 1
        if (-not $dp) { continue }
        $p = Get-ItemProperty -LiteralPath $dp.PSPath -ErrorAction SilentlyContinue
        if ($p -and ($p.CustomCaptureSourceClsid -or $p.FriendlyName)) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------
# DE QUEM E ESTE NO?
#
# A titularidade e conferida por CustomCaptureSourceClsid. Outros fornecedores podem publicar
# nos nesta mesma classe, incluindo a Camera Conectada do Windows. Nao remova seus dispositivos.
# ---------------------------------------------------------------------------------------------
$classes = @(ClassesDoNo $Hash)
$p = ParametrosDoNo $Hash
$dono = $null; $nomeDoNo = $null
if ($p) { $dono = $p.CustomCaptureSourceClsid; $nomeDoNo = $p.FriendlyName }
$pnp = Get-PnpDevice -InstanceId "SWD\VCAMDEVAPI\$Hash" -ErrorAction SilentlyContinue
$estadoPnp = if ($pnp) { $pnp.Status } else { "(ausente)" }
$presente = ($pnp -and ($pnp.Status -eq "OK"))

Write-Output ("no.....: " + $Hash)
Write-Output ("nome...: " + $(if ($nomeDoNo) { $nomeDoNo } else { "(sem FriendlyName)" }))
Write-Output ("fonte..: " + $(if ($dono) { $dono } else { "(sem CustomCaptureSourceClsid)" }))
Write-Output ("PnP....: " + $estadoPnp)
Write-Output ("classes: " + $classes.Count + " -> " + ($classes -join " "))
Write-Output ""

if (-not $Forcar) {
    if ($dono -and ($dono -ne $Clsid)) {
        Write-Output "RECUSADO: este no NAO e do Quall."
        Write-Output ("  a fonte dele e " + $dono + ", nao " + $Clsid + ".")
        Write-Output "  Apagar um no de outro dono tira uma camera do usuario, e nao ha desfazer."
        Write-Output "  Rode inventario-nos.ps1 para ver quem e quem."
        exit 2
    }
    if (-not $dono) {
        if (-not $Orfao) {
            Write-Output "RECUSADO: no sem CustomCaptureSourceClsid -- nao da para dizer de quem e."
            Write-Output "  Um no assim nao serve video a ninguem (o Frame Server nao tem o que"
            Write-Output "  instanciar), mas 'nao sei de quem e' nao autoriza apagar por conta propria."
            Write-Output "  Se ele estiver AUSENTE do PnP, -Orfao libera com as travas conferidas."
            exit 2
        }
        if ($presente) {
            Write-Output "RECUSADO: -Orfao nao se aplica a um no PRESENTE."
            Write-Output ("  PnP diz '" + $estadoPnp + "'. Um no presente e sustentado por software vivo,")
            Write-Output "  que pode ser do usuario. -Orfao so vale para carcaca ausente."
            exit 2
        }
        Write-Output ("-Orfao: no sem dono e ausente do PnP (" + $estadoPnp + "). Seguindo.")
        Write-Output ""
    }
}

Write-Output "--- removendo o dispositivo pela via suportada ---"
& pnputil /remove-device ("SWD\VCAMDEVAPI\" + $Hash) 2>&1 | ForEach-Object { Write-Output ("  " + $_) }
Write-Output ("pnputil -> codigo " + $LASTEXITCODE)

# Conferir no registro, e nao no codigo de retorno. Nesta bancada ja houve API devolvendo sucesso
# sem fazer nada (Remove(), AVEncVideoForceKeyFrame); a regra da casa e conferir no artefato.
# E conferir TODAS as classes, procurando: a lista fixa de duas foi o erro da correcao anterior.
$sobrou = @()
if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\VCAMDEVAPI\$Hash") { $sobrou += "no SWD" }
foreach ($c in (ClassesDoNo $Hash)) { $sobrou += ("interface " + $c) }
if ($sobrou.Count -eq 0) {
    Write-Output "conferido no registro: o no e TODAS as classes de interface sumiram."
    Write-Output ""
    Write-Output "AINDA NAO DECLARE LIMPO: uma remocao conferida assim ja voltou depois de um"
    Write-Output "reinicio nesta bancada (2026-08-27). Rode inventario-nos.ps1 de novo apos o"
    Write-Output "proximo boot antes de dizer que a maquina esta limpa."
} else {
    Write-Output ("SOBROU: " + ($sobrou -join ", "))
    Write-Output "Nao declare removido. Um no meio-apagado vira o fantasma 'AvStream Media Device',"
    Write-Output "que MFCreateVirtualCamera nao conserta."
    exit 3
}

if ($SoONo) {
    Write-Output ""
    Write-Output "-SoONo: o registro COM e a DLL ficam onde estao."
    exit 0
}

# Desfazer o registro COM. regsvr32 /u tambem exige que o FrameServer nao esteja com a DLL
# carregada -- mesma armadilha do instalar.ps1.
foreach ($svc in @("FrameServerMonitor", "FrameServer")) {
    if ((Get-Service $svc -ErrorAction SilentlyContinue).Status -eq "Running") {
        Write-Output "parando $svc para poder desregistrar a DLL"
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Milliseconds 800

if (Test-Path $Dll) {
    $r = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/u", "/s", "`"$Dll`"" -Wait -PassThru
    Write-Output "regsvr32 /u -> codigo $($r.ExitCode)"
} else {
    Write-Output "DLL nao encontrada em $Dll (nada para desregistrar)"
}

$chaveClsid = "HKLM:\SOFTWARE\Classes\CLSID\$Clsid"
if (Test-Path $chaveClsid) { Remove-Item -Path $chaveClsid -Recurse -Force; Write-Output "removido: $chaveClsid" }
else { Write-Output "ja ausente: $chaveClsid" }

if (-not $ManterDll) {
    if (Test-Path $Dll) { Remove-Item -Path $Dll -Force; Write-Output "DLL apagada: $Dll" }
    if ((Test-Path $Destino) -and ((Get-ChildItem $Destino -ErrorAction SilentlyContinue).Count -eq 0)) {
        Remove-Item -Path $Destino -Force; Write-Output "pasta vazia removida: $Destino"
    }
} else {
    Write-Output "DLL mantida por -ManterDll: $Dll"
}

Write-Output ""
Write-Output "Confira com inventario-nos.ps1 (de quem e cada no que sobrou) e com"
Write-Output "'quall-camera-sonda listar' (o que os apps de fato enumeram) -- e de novo depois do"
Write-Output "proximo reinicio."
