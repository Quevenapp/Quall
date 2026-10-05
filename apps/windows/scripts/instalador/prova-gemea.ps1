#Requires -Version 5.1
<#
================================================================================================
A GEMEA: instalar e desinstalar ESTE MSI numa maquina que ja tem o Quall de verdade
================================================================================================

SEM ACENTO, pelo mesmo motivo dos outros `.ps1` desta pasta: o PowerShell 5.1 le `.ps1` sem BOM
como ANSI e um acento dentro de uma string quebra o arquivo na analise.

------------------------------------------------------------------------------------------------
O PROBLEMA QUE ELA RESOLVE
------------------------------------------------------------------------------------------------

Instalar e desinstalar um pacote sobre uma instalacao preexistente pode remover recursos que
nao foram criados pelo teste. Esta receita troca a identidade de produto, componentes, CLSID e
pastas para preparar um MSI separado. Ela nao instala nem remove recursos automaticamente.

------------------------------------------------------------------------------------------------
O QUE ELA TROCA, E O QUE ELA NAO TROCA
------------------------------------------------------------------------------------------------

Troca so o que faz dois pacotes colidirem:

    UpgradeCode                  identidade do produto entre versoes
    Guid de cada <Component>     identidade do RECURSO. Reusar um GUID de componente em dois
                                 produtos faz o Windows Installer contar referencia junto: a
                                 desinstalacao da gemea mexeria no do produto. E o item mais
                                 importante desta lista.
    ClsidFonte                   o CLSID da fonte de midia -- e com ele o dono dos nos de camera
    Name do <Package>            "Quall (prova de bancada)"
    INSTALLFOLDER / ProgramData / Menu Iniciar     ...-<Sufixo>
    HKLM|HKCU SOFTWARE\Queven\Quall                ...-<Sufixo>
    $Clsid, $Diario e $Marcador de camera-desinstalar.ps1   para casar com o CLSID novo

NAO troca mais nada. As acoes customizadas, a ordem delas, o `util:PermissionEx`, o `<Icon>`, o
`MajorUpgrade`, o `RemoveFolder` e o codigo inteiro da varredura sao os mesmos bytes do produto.

Os GUIDs sao DERIVADOS do sufixo (MD5 de uma semente), e nao sorteados: rodar duas vezes com o
mesmo sufixo produz o mesmo pacote, e o `MajorUpgrade` funciona em vez de deixar duas instalacoes.

------------------------------------------------------------------------------------------------
O FIREWALL FICA DE FORA, E ISSO E DECISAO
------------------------------------------------------------------------------------------------

`-SemFirewall` e passado sempre. Regra de firewall e configuracao de seguranca da maquina do
usuario, e nesta bancada as regras existentes foram criadas pela mao dele. Um roteiro de agente nao
cria nem remove nenhuma. O fragmento continua sendo compilado pelo `wix` no build do pacote de
verdade (que e onde o risco estava: a extensao existir e os atributos casarem); o que fica sem
prova e o efeito dele no runtime, e isso esta escrito no relatorio.

------------------------------------------------------------------------------------------------
O `-Defeito`: confirmar NA EXECUCAO os dois defeitos que a releitura achou
------------------------------------------------------------------------------------------------

Dois defeitos foram achados relendo o `.wxs` e corrigidos antes de qualquer maquina ve-lo:

    <Icon Id="IconeQuall">                     sem o `.exe` no Id
    ExeCommand="... -File [INSTALLFOLDER]..."  propriedade numa acao ADIADA

"Corrigido por releitura" nao e "provado". `-Defeito icone` e `-Defeito installfolder`
REINTRODUZEM cada um deles num pacote gemeo, para que o modo de falha seja medido em vez de
suposto -- a mesma logica do `--calibrar` de `tools/confere-fronteira.py`: uma correcao que nunca
foi vista falhando pode estar certa, ou pode estar consertando coisa nenhuma.

------------------------------------------------------------------------------------------------
USO
------------------------------------------------------------------------------------------------

    powershell -ExecutionPolicy Bypass -File prova-gemea.ps1
    powershell -ExecutionPolicy Bypass -File prova-gemea.ps1 -Defeito installfolder
    powershell -ExecutionPolicy Bypass -File prova-gemea.ps1 -Defeito icone

Ela NAO instala nada. Ela produz o `.msi` e imprime os comandos.
#>
param(
    [string]$Sufixo = "Prova",
    [ValidateSet("nenhum", "icone", "installfolder")][string]$Defeito = "nenhum",
    [string]$Versao = "0.1.0",
    [string]$Saida
)
$ErrorActionPreference = "Stop"

$aqui = $PSScriptRoot
$raiz = (Resolve-Path (Join-Path $aqui "..\..\..\..")).Path
if (-not $Saida) { $Saida = Join-Path $aqui "saida-gemea" }
$estagio = Join-Path $aqui ("estagio-gemea-" + $Defeito)
$fonteWxs = Join-Path $aqui "Quall.wxs"
$fonteVarredura = Join-Path $aqui "camera-desinstalar.ps1"

function Diga($t) { [Console]::Out.WriteLine([string]$t) }

# GUID derivado, para o pacote ser reproduzivel entre corridas.
function GuidDe([string]$semente) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $b = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($semente))
    return ([guid]::new($b)).ToString().ToUpper()
}

$clsidNovo = "{" + (GuidDe "$Sufixo|clsid|$Defeito") + "}"
$upgradeNovo = GuidDe "$Sufixo|upgrade|$Defeito"
$nomePasta = "Quall-$Sufixo"

Diga "== gemea =="
Diga "  sufixo    : $Sufixo"
Diga "  defeito   : $Defeito"
Diga "  CLSID     : $clsidNovo"
Diga "  Upgrade   : {$upgradeNovo}"
Diga "  pasta     : $nomePasta"

# ------------------------------------------------------------------------------------------------
# 1. O .wxs gemeo
# ------------------------------------------------------------------------------------------------
$wxs = Get-Content -Raw -Encoding UTF8 $fonteWxs

$wxs = $wxs -replace 'UpgradeCode="[0-9A-Fa-f-]{36}"', ("UpgradeCode=`"$upgradeNovo`"")
$wxs = $wxs -replace '\$\(var\.ClsidFonte\)', $clsidNovo
$wxs = $wxs -replace '<\?define ClsidFonte = "\{[0-9A-Fa-f-]+\}" \?>', ("<?define ClsidFonte = `"$clsidNovo`" ?>")

# Cada componente ganha um GUID proprio, derivado do Id dele. Sem isto os dois produtos
# compartilhariam a contagem de referencia do recurso.
$wxs = [regex]::Replace($wxs, '<Component Id="(\w+)" Guid="[0-9A-Fa-f-]{36}"', {
    param($m)
    '<Component Id="' + $m.Groups[1].Value + '" Guid="' + (GuidDe "$Sufixo|comp|$Defeito|$($m.Groups[1].Value)") + '"'
})

$wxs = $wxs -replace '<Package Name="Quall Studio"', ("<Package Name=`"Quall Studio (prova de bancada $Sufixo)`"")
$wxs = $wxs -replace '<Directory Id="INSTALLFOLDER" Name="Quall" />', ("<Directory Id=`"INSTALLFOLDER`" Name=`"$nomePasta`" />")
$wxs = $wxs -replace '<Directory Id="MenuQuall" Name="Quall" />', ("<Directory Id=`"MenuQuall`" Name=`"$nomePasta`" />")
$wxs = $wxs -replace '<Directory Id="DadosQuall" Name="Quall" />', ("<Directory Id=`"DadosQuall`" Name=`"$nomePasta`" />")
$wxs = $wxs -replace 'Key="Software\\Queven\\Quall"', ("Key=`"Software\Queven\$nomePasta`"")
$wxs = $wxs -replace 'Key="SOFTWARE\\Queven\\Quall"', ("Key=`"SOFTWARE\Queven\$nomePasta`"")
$wxs = $wxs -replace 'Name="Quall Studio"\r?\n(\s*)Description="Espelhe', ("Name=`"Quall Studio ($Sufixo)`"`r`n`$1Description=`"Espelhe")

switch ($Defeito) {
    "icone" {
        # O Id do <Icon> sem a extensao. E pela extensao do Id -- nao pela do arquivo de origem --
        # que o Windows Installer decide como extrair o icone.
        $wxs = $wxs -replace '<Icon Id="IconeQuall\.exe"', '<Icon Id="IconeQuall"'
        $wxs = $wxs -replace 'Value="IconeQuall\.exe"', 'Value="IconeQuall"'
    }
    "installfolder" {
        # Propriedade da sessao dentro de um ExeCommand de acao ADIADA. Uma acao adiada nao enxerga
        # propriedade nenhuma: ela so recebe `CustomActionData`.
        $wxs = $wxs -replace '(-ExecutionPolicy Bypass -File )camera-desinstalar\.ps1', '$1[INSTALLFOLDER]camera-desinstalar.ps1'
    }
}

# ------------------------------------------------------------------------------------------------
# 2. A varredura gemea: mesmo codigo, outro dono e outro diario
#
# O CLSID e o que decide de quem e cada no de camera. Se a gemea carregasse a varredura com o CLSID
# do produto, a desinstalacao dela removeria o no "Quall-bancada" -- que e exatamente o que ela
# existe para nao fazer.
# ------------------------------------------------------------------------------------------------
$varredura = Get-Content -Raw -Encoding UTF8 $fonteVarredura
$antes = $varredura
$varredura = $varredura -replace '(\[string\]\$Clsid\s*=\s*)"\{[0-9A-Fa-f-]+\}"', ('$1"' + $clsidNovo + '"')
$varredura = $varredura -replace 'C:\\ProgramData\\Quall\\', ("C:\ProgramData\$nomePasta\")
if ($varredura -eq $antes) { throw "nao consegui trocar o CLSID/diario da varredura -- o formato mudou?" }
if ($varredura -notmatch [regex]::Escape($clsidNovo)) { throw "o CLSID novo nao entrou na varredura" }

# ------------------------------------------------------------------------------------------------
# 3. Estagio
# ------------------------------------------------------------------------------------------------
$exe = Join-Path $raiz "apps\windows\target\release-sem-monitor\release\quall-app.exe"
$dll = Join-Path $raiz "integrations\camera-windows\target\release\quall_camera_fonte.dll"
foreach ($a in @($exe, $dll)) { if (-not (Test-Path $a)) { throw "artefato ausente: $a (rode construir-msi.ps1 antes)" } }
$textoApp = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($exe))
if (-not $textoApp.Contains("quall-distribuicao: release-sem-monitor-v2")) { throw "variante incorreta: falta marcador sem monitor" }
foreach ($proibido in @("quall-distribuicao: desenvolvimento-tela-estendida-v1", "SudoVDA.inf", "SudoVDA.cat", "SudoVDA.dll", "SudoVDA.cer")) {
    if ($textoApp.Contains($proibido)) { throw "variante incorreta: entrada de driver $proibido" }
}

Remove-Item $estagio -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $estagio -Force | Out-Null
Copy-Item $exe $estagio
Copy-Item $dll $estagio
foreach ($aviso in @("LICENSE", "LICENSE-SCOPE.md", "NOTICE.txt", "THIRD_PARTY_NOTICES.txt")) {
    $fonteAviso = Join-Path $raiz $aviso
    if (-not (Test-Path -LiteralPath $fonteAviso -PathType Leaf) -or (Get-Item -LiteralPath $fonteAviso).Length -eq 0) { throw "aviso ausente ou vazio: $aviso" }
    Copy-Item -LiteralPath $fonteAviso -Destination (Join-Path $estagio $aviso)
}
Set-Content -LiteralPath (Join-Path $estagio "camera-desinstalar.ps1") -Value $varredura -Encoding UTF8
$wxsGemeo = Join-Path $estagio "Quall-gemea.wxs"
Set-Content -LiteralPath $wxsGemeo -Value $wxs -Encoding UTF8

# ------------------------------------------------------------------------------------------------
# 4. wix
# ------------------------------------------------------------------------------------------------
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    $priv = Join-Path $env:USERPROFILE ".dotnet"
    if (Test-Path (Join-Path $priv "dotnet.exe")) {
        $env:DOTNET_ROOT = $priv
        $env:PATH = "$priv;$priv\tools;" + $env:PATH
    }
}
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) { throw "'wix' nao esta no PATH" }

New-Item -ItemType Directory -Path $Saida -Force | Out-Null
$msi = Join-Path $Saida ("Quall-$Sufixo-$Defeito-$Versao.msi")

# `-SemFirewall` SEMPRE. Ver o cabecalho: regra de firewall e configuracao de seguranca da maquina
# do usuario, e este roteiro nao cria nenhuma.
$argumentos = @(
    "build", $wxsGemeo,
    "-d", "Versao=$Versao",
    "-d", "Bin=$estagio",
    "-d", "SemFirewall=1",
    "-arch", "x64",
    "-culture", "en-US",
    "-o", $msi,
    "-ext", "WixToolset.Util.wixext"
)
Diga ""
Diga ("== wix " + ($argumentos -join " "))
& wix @argumentos
if ($LASTEXITCODE -ne 0) { throw "wix build falhou com codigo $LASTEXITCODE" }

Diga ""
Diga ("pacote: $msi  (" + [math]::Round((Get-Item $msi).Length / 1MB, 1) + " MB)")
Diga ""
Diga "Instalar (Administrador):"
Diga "  msiexec /i `"$msi`" /qn /l*v `"$Saida\instalar-$Defeito.log`""
Diga "Desinstalar (Administrador):"
Diga "  msiexec /x `"$msi`" /qn /l*v `"$Saida\desinstalar-$Defeito.log`""
Diga ""
Diga "Confira no REGISTRO, nao no codigo de retorno do msiexec."
