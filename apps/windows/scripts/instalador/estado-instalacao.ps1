#Requires -Version 5.1
<#
================================================================================================
O ESTADO DA MAQUINA, ANTES E DEPOIS -- a conferencia que NAO e o codigo de retorno do msiexec
================================================================================================

SEM ACENTO, pelo mesmo motivo dos outros `.ps1` desta pasta.

O README desta pasta fixa a regra: "conferir a desinstalacao no REGISTRO, e nao no codigo de
retorno do `msiexec`". Esta bancada ja pagou tres vezes por confiar em retorno
(`IMFVirtualCamera::Remove()` devolve S_OK sem remover; `ICodecAPI::SetValue` aceita e ignora;
`regsvr32 /s` falha em silencio).

Este roteiro le, num despejo so, as SETE coisas que o pacote publica mais as tres que ele NAO pode
tocar. Rodado antes e depois, a diferenca e a prova.

    powershell -ExecutionPolicy Bypass -File estado-instalacao.ps1 -Sufixo Prova -Clsid "{...}"

`-Sufixo` vazio mede o pacote de verdade (pasta "Quall"); `-Sufixo Prova` mede a gemea
("Quall-Prova"). O CLSID e o da fonte de midia daquele pacote.

O bloco "INTOCAVEL" no fim mede o que ja estava na maquina antes de qualquer agente: a DLL da
bancada, o CLSID dela e os nos de camera virtual. Se qualquer linha dele mudar entre duas corridas,
a instalacao ou a desinstalacao passou por cima do usuario -- e e a unica linha do relatorio que
importa mais do que "instalou".
#>
param(
    [string]$Sufixo = "",
    [string]$Clsid = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}"
)
$ErrorActionPreference = "Continue"
function Diga($t) { [Console]::Out.WriteLine([string]$t) }

$nome = if ($Sufixo) { "Quall-$Sufixo" } else { "Quall" }
$chaveQueven = if ($Sufixo) { "Quall-$Sufixo" } else { "Quall" }

Diga ("== estado de " + $nome + " em " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " (relogio do Windows de teste) ==")
Diga ("   CLSID medido: " + $Clsid)

# 1. arquivos
$pf = "C:\Program Files\$nome"
Diga ""
Diga "1. ARQUIVOS  $pf"
if (Test-Path $pf) {
    Get-ChildItem $pf -Force | ForEach-Object {
        $h = try { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.Substring(0, 16) } catch { "(pasta)" }
        Diga ("   {0,-28} {1,10}  {2}  sha256:{3}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"), $h)
    }
} else { Diga "   (ausente)" }

# 2. registro COM
Diga ""
Diga "2. REGISTRO COM  HKLM\SOFTWARE\Classes\CLSID\$Clsid"
$k = "HKLM:\SOFTWARE\Classes\CLSID\$Clsid"
if (Test-Path $k) {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    Diga ("   (padrao)        = " + $p."(default)")
    $ips = "$k\InprocServer32"
    if (Test-Path $ips) {
        $q = Get-ItemProperty $ips -ErrorAction SilentlyContinue
        Diga ("   InprocServer32  = " + $q."(default)")
        Diga ("   ThreadingModel  = " + $q.ThreadingModel)
    } else { Diga "   InprocServer32  (ausente)" }
} else { Diga "   (ausente)" }

# 3. atalho
Diga ""
Diga "3. ATALHO  Menu Iniciar\$nome"
$menu = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\$nome"
if (Test-Path $menu) {
    Get-ChildItem $menu -Force | ForEach-Object { Diga ("   " + $_.Name) }
} else { Diga "   (ausente)" }

# 4. pasta de diario, com a ACL -- e o item 2 da lista "o que NAO foi provado" do README
Diga ""
Diga "4. DIARIO  C:\ProgramData\$nome"
$pd = "C:\ProgramData\$nome"
if (Test-Path $pd) {
    Get-ChildItem $pd -Force | ForEach-Object { Diga ("   arquivo: " + $_.Name + "  " + $_.Length + " B") }
    $acl = Get-Acl $pd
    Diga ("   dono: " + $acl.Owner)
    foreach ($a in $acl.Access) {
        Diga ("   ACE: {0,-42} {1,-10} herdada={2}" -f $a.IdentityReference, $a.FileSystemRights, $a.IsInherited)
    }
} else { Diga "   (ausente)" }

# 5. chaves proprias
Diga ""
Diga "5. CHAVES  SOFTWARE\Queven\$chaveQueven"
foreach ($r in @("HKLM:\SOFTWARE\Queven\$chaveQueven", "HKCU:\Software\Queven\$chaveQueven")) {
    if (Test-Path $r) {
        $p = Get-ItemProperty $r
        $vals = ($p.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object { $_.Name + "=" + $_.Value }) -join " "
        Diga ("   $r : $vals")
    } else { Diga "   $r : (ausente)" }
}

# 6. Programas e Recursos, com o icone -- e aqui que o Id do <Icon> aparece ou nao
Diga ""
Diga "6. PROGRAMAS E RECURSOS"
$achou = $false
foreach ($raiz in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
    Get-ChildItem $raiz -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -like "*Quall*") {
            $achou = $true
            Diga ("   " + $p.DisplayName + "   versao=" + $p.DisplayVersion)
            Diga ("      chave        : " + $_.PSChildName)
            Diga ("      InstallLocation: " + $p.InstallLocation)
            Diga ("      DisplayIcon  : " + $(if ($p.DisplayIcon) { $p.DisplayIcon } else { "(NENHUM)" }))
            if ($p.DisplayIcon) {
                $arq = ($p.DisplayIcon -split ",")[0]
                Diga ("      icone existe : " + (Test-Path $arq))
            }
        }
    }
}
if (-not $achou) { Diga "   (nenhuma entrada com 'Quall')" }

# 7. firewall -- SO LEITURA. Este roteiro nao cria nem remove regra nenhuma.
Diga ""
Diga "7. FIREWALL (so leitura)"
$rs = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Quall*" })
if ($rs.Count -eq 0) { Diga "   (nenhuma regra com 'Quall')" }
foreach ($r in $rs) {
    $ap = try { ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program } catch { "" }
    Diga ("   {0,-46} {1,-8} {2,-8} {3}" -f $r.DisplayName, $r.Direction, $r.Action, $ap)
}

# ------------------------------------------------------------------------------------------------
Diga ""
Diga "== INTOCAVEL: o que ja estava na maquina antes =="
Diga "   (se qualquer linha daqui mudar entre duas corridas, alguem passou por cima do usuario)"
$dllBancada = "C:\Program Files\Quall\quall_camera_fonte.dll"
if (Test-Path $dllBancada) {
    $f = Get-Item $dllBancada
    Diga ("   DLL da bancada : " + $f.Length + " B  " + $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") +
          "  sha256:" + (Get-FileHash $dllBancada -Algorithm SHA256).Hash.Substring(0, 16))
} else { Diga "   DLL da bancada : AUSENTE" }
$kb = "HKLM:\SOFTWARE\Classes\CLSID\{5C75FE52-9204-45F6-B143-58B1AC8048E5}\InprocServer32"
if (Test-Path $kb) {
    Diga ("   CLSID bancada  : " + (Get-ItemProperty $kb)."(default)")
} else { Diga "   CLSID bancada  : AUSENTE" }

$enum = "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\VCAMDEVAPI"
$dc = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses"
if (Test-Path $enum) {
    $hs = @(Get-ChildItem $enum -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    Diga ("   nos VCAMDEVAPI : " + $hs.Count)
    foreach ($h in $hs) {
        $classes = @()
        Get-ChildItem $dc -ErrorAction SilentlyContinue | ForEach-Object {
            if (@(Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue |
                  Where-Object { $_.PSChildName -like ("*#" + $h + "#*") }).Count -gt 0) { $classes += $_.PSChildName }
        }
        $nome2 = "(sem FriendlyName)"; $fonte = "(sem fonte)"
        foreach ($c in $classes) {
            $iface = Get-ChildItem "$dc\$c" -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSChildName -like ("*#" + $h + "#*") } | Select-Object -First 1
            if (-not $iface) { continue }
            $dp = Get-ChildItem $iface.PSPath -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.PSChildName -eq "Device Parameters" } | Select-Object -First 1
            if (-not $dp) { continue }
            $pp = Get-ItemProperty -LiteralPath $dp.PSPath -ErrorAction SilentlyContinue
            if ($pp -and ($pp.CustomCaptureSourceClsid -or $pp.FriendlyName)) {
                if ($pp.FriendlyName) { $nome2 = $pp.FriendlyName }
                if ($pp.CustomCaptureSourceClsid) { $fonte = $pp.CustomCaptureSourceClsid }
                break
            }
        }
        Diga ("      " + $h.Substring(0, 12) + "...  classes=" + $classes.Count + "  '" + $nome2 + "'  fonte=" + $fonte)
    }
} else { Diga "   nos VCAMDEVAPI : nenhum" }
