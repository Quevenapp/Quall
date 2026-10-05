# Instala a fonte de mídia da câmera virtual do Quall.
#
# EXIGE ADMINISTRADOR: escreve em C:\Program Files e em HKLM\SOFTWARE\Classes\CLSID.
#
# Uso:  powershell -ExecutionPolicy Bypass -File instalar.ps1 [-Dll <caminho>]
param(
    [string]$Dll = (Join-Path $PSScriptRoot "..\target\release\quall_camera_fonte.dll"),
    [string]$Destino = "C:\Program Files\Quall"
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) { throw "DLL ausente: $Dll" }

$clsid = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}"

# 1. O Frame Server roda como NT AUTHORITY\LocalService e precisa **ler e executar** a DLL. Uma
#    DLL dentro de C:\Users\<alguém> não serve: o perfil de usuário nega acesso a outras contas,
#    e o sintoma é a câmera aparecer na lista e nunca entregar imagem.
New-Item -ItemType Directory -Path $Destino -Force | Out-Null

# 2. Se o Frame Server já carregou uma versão anterior, o arquivo está travado. Parar o serviço é
#    o único jeito de trocar a DLL — e ele sobe sozinho na próxima vez que alguém abrir a câmera.
foreach ($svc in @("FrameServerMonitor", "FrameServer")) {
    if ((Get-Service $svc -ErrorAction SilentlyContinue).Status -eq "Running") {
        Write-Output "parando $svc para poder trocar a DLL"
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Milliseconds 800

Copy-Item -Path $Dll -Destination (Join-Path $Destino "quall_camera_fonte.dll") -Force
Write-Output "DLL copiada para $Destino"

# 3. Pasta do diário. A DLL é carregada por processos de contas diferentes (LocalService,
#    LocalSystem, o usuário) e todas escrevem no mesmo arquivo — daí a ACL frouxa. Isto é
#    decisão de **bancada**, não de produto: no produto o diário some ou vira ETW.
$log = "C:\ProgramData\Quall"
New-Item -ItemType Directory -Path $log -Force | Out-Null
icacls $log /grant "*S-1-1-0:(OI)(CI)M" /T | Out-Null
Write-Output "pasta de diário: $log (Todos: modificar)"

# 4. Registro COM.
$r = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s", "`"$Destino\quall_camera_fonte.dll`"" -Wait -PassThru
Write-Output "regsvr32 -> código $($r.ExitCode)"

$chave = "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32"
if (Test-Path $chave) {
    $v = Get-ItemProperty $chave
    Write-Output "registrado: $($v.'(default)')  ThreadingModel=$($v.ThreadingModel)"
} else {
    Write-Output "REGISTRO NÃO ENCONTRADO — regsvr32 falhou em silêncio"
}
