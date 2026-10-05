# Corrida de MEDICAO: emissor, host e consumidor na MESMA maquina.
#
# Por que na mesma maquina: e a unica forma de os tres instantes virem do mesmo
# QueryPerformanceCounter. O carimbo viaja dentro dos pixels (ver `carimbo.rs`), atravessa
# encode, RTP, rede, decode, escala, cano e Frame Server, e quem o le e o app consumidor.
#
# O que este numero NAO cobre, e tem de ser dito junto: captura real, o salto de radio (o
# trafego fica na pilha local) e a varredura do painel.
param(
    [int]$Segundos = 45,
    [int]$Quadros = 300,
    [string]$Pin = "424242",
    [int]$Porta = 7877,
    [int]$Largura = 1280,
    [int]$Altura = 720,
    [string]$Saida = (Join-Path $env:TEMP ("quall-laco-" + [guid]::NewGuid().ToString("N"))),
    [string]$Exe = (Join-Path $PSScriptRoot "..\target\release\quall-camera-sonda.exe")
)

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "sonda ausente: $Exe" }
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Saida | Out-Null
Get-ChildItem $Saida -File -ErrorAction SilentlyContinue | Remove-Item -Force

$emissor = Start-Process -FilePath $exe -NoNewWindow -PassThru `
    -ArgumentList "emitir","--segundos",$Segundos,"--porta",$Porta,"--pin",$Pin,"--largura",$Largura,"--altura",$Altura,"--camera","--json","$Saida\emitir.json" `
    -RedirectStandardOutput "$Saida\emitir.out" -RedirectStandardError "$Saida\emitir.err"

Start-Sleep -Seconds 4

$receptor = Start-Process -FilePath $exe -NoNewWindow -PassThru `
    -ArgumentList "receber","--ip","127.0.0.1:$Porta","--pin",$Pin,"--segundos",($Segundos + 10),"--json","$Saida\receber.json" `
    -RedirectStandardOutput "$Saida\receber.out" -RedirectStandardError "$Saida\receber.err"

Start-Sleep -Seconds 10

$consumidor = Start-Process -FilePath $exe -NoNewWindow -PassThru `
    -ArgumentList "ler","--nome","Quall","--quadros",$Quadros,"--segundos-max",60,"--json","$Saida\ler.json","--salvar","$Saida\quadro.bmp" `
    -RedirectStandardOutput "$Saida\ler.out" -RedirectStandardError "$Saida\ler.err"

foreach ($p in @($consumidor, $receptor, $emissor)) {
    $p | Wait-Process -Timeout ($Segundos + 90) -ErrorAction SilentlyContinue
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

"=== emitir.out ==="; Get-Content "$Saida\emitir.out" -ErrorAction SilentlyContinue
"=== emitir.err (ultimas 25) ==="; Get-Content "$Saida\emitir.err" -Tail 25 -ErrorAction SilentlyContinue
"=== receber.out ==="; Get-Content "$Saida\receber.out" -ErrorAction SilentlyContinue
"=== receber.err (ultimas 40) ==="; Get-Content "$Saida\receber.err" -Tail 40 -ErrorAction SilentlyContinue
"=== ler.out ==="; Get-Content "$Saida\ler.out" -ErrorAction SilentlyContinue
"=== ler.err (ultimas 20) ==="; Get-Content "$Saida\ler.err" -Tail 20 -ErrorAction SilentlyContinue
