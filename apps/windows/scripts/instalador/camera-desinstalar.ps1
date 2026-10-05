#Requires -Version 5.1
<#
  Varredura de desinstalacao da camera virtual do Quall.

  ------------------------------------------------------------------------------------------------
  POR QUE ESTE ARQUIVO EXISTE, E POR QUE ELE E O PEDACO PERIGOSO DO INSTALADOR
  ------------------------------------------------------------------------------------------------

  O instalador do Quall publica arquivos, chaves COM, um atalho e uma regra de firewall. Ele NAO
  cria a camera virtual: quem cria e o proprio app, em tempo de execucao, chamando
  MFCreateVirtualCamera com Lifetime_System. A camera sobrevive ao fechamento do app e sobrevive a
  um reinicio -- medido em 2026-08-26.

  Isso produz a assimetria que faz este arquivo ser necessario: **a desinstalacao precisa desfazer
  algo que a instalacao nunca fez.** O MSI sabe desfazer o que ele mesmo escreveu; ninguem alem
  deste script sabe desfazer o no de dispositivo.

  E aqui esta a armadilha, medida em 2026-08-27 e registrada em docs/camera-virtual.md:

      MFCreateVirtualCamera publica o no em QUATRO classes de interface, mais o no em
      Enum\SWD\VCAMDEVAPI: CINCO lugares, nao tres.

          {e5323777-f976-4f5b-9b55-b94699c46e44}   KSCATEGORY_VIDEO_CAMERA
          {65e8773d-8f56-11d0-a3b9-00a0c9223196}   KSCATEGORY_CAPTURE
          {6994ad05-93ef-11d0-a3cc-00a0c9223196}   KSCATEGORY_VIDEO
          {588c8d20-c0e3-4fd3-b511-8f2f692156f8}

      Um removedor que confere MENOS do que a criacao publica FABRICA o fantasma que promete
      eliminar: o "AvStream Media Device", uma camera que continua enumerada, sem nome e sem
      fonte, que MFCreateVirtualCamera nao conserta.

  A lista de quatro GUIDs acima esta neste comentario como HISTORIA, e nao como configuracao.
  **O codigo abaixo nao a usa.** Ele PROCURA todas as classes em que o hash aparece. Uma lista
  fixa envelhece em silencio; uma busca, nao. Se a Microsoft publicar numa quinta classe amanha,
  a busca acha e a lista nao -- e a lista continuaria imprimindo "removido inteiro".

  ------------------------------------------------------------------------------------------------
  TRES REGRAS QUE ESTE SCRIPT NAO QUEBRA
  ------------------------------------------------------------------------------------------------

  1. So remove no cujo CustomCaptureSourceClsid seja o NOSSO. Neste Windows de teste existe um no VCAMDEVAPI
     que e a Camera Conectada do proprio Windows (Vincular ao Celular, fonte
     CrossDeviceVirtualCameraSource.dll). Apagar aquele no tira um recurso do usuario, e nao ha
     desfazer.
  2. No de DONO DESCONHECIDO (sem CustomCaptureSourceClsid) e RELATADO, nunca removido. Um
     desinstalador roda sem ninguem olhando; "nao sei de quem e" nao autoriza apagar sozinho. O
     remover.ps1 interativo de integrations/camera-windows tem o modo -Orfao para isso, com uma
     pessoa decidindo.
  3. Confere no REGISTRO, nao no codigo de retorno. Nesta bancada IMFVirtualCamera::Remove()
     devolve S_OK em 42 ms e nao remove nada, e o AVEncVideoForceKeyFrame do M1 fez o mesmo. A
     regra da casa e conferir no artefato.

  ------------------------------------------------------------------------------------------------
  QUANDO ELE NAO CONSEGUE
  ------------------------------------------------------------------------------------------------

  Se sobrar qualquer lugar, o script NAO diz que removeu. Ele grava
  C:\ProgramData\Quall\REMOCAO-INCOMPLETA.txt com o hash e o que sobrou, e o MSI deixa a pasta de
  pe por causa desse arquivo. Uma desinstalacao que mente e pior do que uma que falha em voz alta:
  o fantasma so aparece semanas depois, na lista de cameras de um Zoom, e ninguem liga uma coisa
  na outra.

  E, mesmo quando tudo sai: **um no removido e conferido ja VOLTOU depois de um reinicio nesta
  bancada** (2026-08-27), despido de nome e de fonte. O script diz isso no fim. Nao ha conserto
  conhecido daqui; ha a instrucao de conferir de novo.

  ------------------------------------------------------------------------------------------------
  EXIGE ADMINISTRADOR (pnputil). O MSI o chama como acao adiada, sem representacao.

  Uso avulso:
    powershell -ExecutionPolicy Bypass -NoProfile -File camera-desinstalar.ps1
    powershell -ExecutionPolicy Bypass -NoProfile -File camera-desinstalar.ps1 -SoRelatar
#>
param(
    # O CLSID da nossa fonte de midia. Bate com CLSID_TEXTO em
    # integrations/camera-windows/fonte/src/lib.rs. Se um dia mudar la, muda aqui -- e o portao
    # tools/confere-desinstalacao-camera.py acusa a divergencia.
    [string]$Clsid = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}",
    [string]$Diario = "C:\ProgramData\Quall\desinstalacao.log",
    [string]$Marcador = "C:\ProgramData\Quall\REMOCAO-INCOMPLETA.txt",
    # Nao remove nada: so diz o que faria. E o modo de conferir a maquina antes e depois.
    [switch]$SoRelatar
)

$ErrorActionPreference = "Continue"

$enum = "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\VCAMDEVAPI"
$dc   = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses"

function Anotar($texto) {
    $linha = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $texto
    Write-Output $linha
    try {
        $pasta = Split-Path -Parent $Diario
        if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        Add-Content -LiteralPath $Diario -Value $linha -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------------------------------------------
# A BUSCA. Nao ha lista de classes aqui, e e o ponto inteiro do arquivo.
#
# Um hash aparece sob DeviceClasses\<classe>\##?#SWD#VCAMDEVAPI#<hash>#<classe>. Varrer todas as
# classes e perguntar quais contem o hash responde "em quantos lugares este no esta publicado?"
# sem que ninguem precise saber a resposta de antemao.
# ------------------------------------------------------------------------------------------------
function ClassesDoNo($hash) {
    Get-ChildItem $dc -ErrorAction SilentlyContinue | ForEach-Object {
        $n = @(Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like ("*#" + $hash + "#*") }).Count
        if ($n -gt 0) { $_.PSChildName }
    }
}

# O nome e o dono NAO ficam direto sob a interface: ha um nivel a mais, o "reference string"
# (#{FCEBBA03-...}), e so abaixo dele vem "Device Parameters". Por isso aqui nao se CONSTROI
# caminho -- procura-se a chave e usa-se o PSPath dela. Uma versao anterior desta funcao, em
# integrations/camera-windows, montou um caminho que nunca existiu e devolveu "sem FriendlyName"
# para TODOS os nos, o que teria feito o inventario declarar que nenhum era nosso.
# O -ErrorAction SilentlyContinue tambem cobre a subchave "Properties", cuja ACL nega leitura ate
# para administrador.
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

# "Sobrou alguma coisa deste hash?" -- a unica pergunta que decide se a remocao terminou.
# Repare que ela conta o no SWD **e** as classes achadas pela busca; nao ha numero esperado.
function OndeAindaEsta($hash) {
    $lugares = @()
    if (Test-Path "$enum\$hash") { $lugares += "Enum\SWD\VCAMDEVAPI\$hash" }
    foreach ($c in (ClassesDoNo $hash)) { $lugares += "DeviceClasses\$c" }
    return $lugares
}

# ------------------------------------------------------------------------------------------------
# O FIM LIMPO -- esvaziar C:\ProgramData\Quall, e por que isto e o script quem faz e nao o MSI.
#
# O MSI tem um <RemoveFolder>, que so apaga a pasta se ela estiver VAZIA. Essa semantica e
# aproveitada de proposito: quando a remocao FALHA, o marcador REMOCAO-INCOMPLETA.txt fica na
# pasta, o <RemoveFolder> nao faz nada, e o aviso sobrevive a desinstalacao. Quando ela da certo,
# e este bloco que esvazia -- e o MSI remove a casca.
#
# ISTO ERA UM BLOCO NO FIM DO ARQUIVO, E POR ISSO NAO RODAVA NO CASO MAIS COMUM. Medido em
# 2026-08-30, no Windows de teste: numa desinstalacao em que nao havia NENHUM no do Quall para remover -- que e
# o estado de qualquer maquina onde o app nunca espelhou -- o roteiro saia por
# `if ($nossos.Count -eq 0) { ...; exit 0 }`, o bloco do fim nunca era alcancado, e
# `C:\ProgramData\Quall` sobrevivia a desinstalacao com o `desinstalacao.log` dentro.
#
# O estrago nao e o lixo: e que a pasta sobreviver DEIXA DE SIGNIFICAR "algo deu errado". O
# desenho inteiro depende desse sinal -- pasta de pe = ha um REMOCAO-INCOMPLETA.txt para ler. Com
# ela sobrevivendo tambem no caminho feliz, o aviso vira ruido.
#
# O diario nao e apagado: ele e a evidencia do que aconteceu. Ele muda de lugar, para o %TEMP%, e o
# caminho novo sai na ultima linha. Uma desinstalacao que apaga o proprio relato deixa a proxima
# pessoa sem nada para ler quando o fantasma aparecer.
# ------------------------------------------------------------------------------------------------
function FinalizarLimpo {
    if (-not $SoRelatar) {
        try {
            $pasta = Split-Path -Parent $Diario
            if (Test-Path $pasta) {
                $guardado = Join-Path $env:TEMP ("quall-desinstalacao-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
                if (Test-Path $Diario) { Copy-Item -LiteralPath $Diario -Destination $guardado -Force -ErrorAction SilentlyContinue }
                Get-ChildItem -LiteralPath $pasta -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output ("diario guardado em " + $guardado + "; " + $pasta + " esvaziada")
            }
        } catch { }
    }
    exit 0
}

# ------------------------------------------------------------------------------------------------
Anotar "=== varredura de desinstalacao da camera virtual do Quall ==="
Anotar ("CLSID nosso: " + $Clsid + $(if ($SoRelatar) { "   (MODO -SoRelatar: nada sera removido)" } else { "" }))

if (-not (Test-Path $enum)) {
    Anotar "Nao ha nenhum no SWD\VCAMDEVAPI nesta maquina. Nada a fazer."
    FinalizarLimpo
}

$hashes = @(Get-ChildItem $enum -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
Anotar ("nos VCAMDEVAPI encontrados: " + $hashes.Count)

$nossos = @(); $alheios = @(); $desconhecidos = @()
foreach ($h in $hashes) {
    $p = ParametrosDoNo $h
    $fonte = $null; $nome = $null
    if ($p) { $fonte = $p.CustomCaptureSourceClsid; $nome = $p.FriendlyName }
    $classes = @(ClassesDoNo $h)
    $pnp = Get-PnpDevice -InstanceId "SWD\VCAMDEVAPI\$h" -ErrorAction SilentlyContinue
    $reg = [pscustomobject]@{
        Hash = $h
        Nome = $(if ($nome) { $nome } else { "(sem FriendlyName)" })
        Fonte = $(if ($fonte) { $fonte } else { "(sem CustomCaptureSourceClsid)" })
        Classes = $classes
        Pnp = $(if ($pnp) { $pnp.Status } else { "(ausente)" })
    }
    Anotar ("  " + $h)
    Anotar "     nome    : <omitido>"
    Anotar ("     fonte   : " + $reg.Fonte)
    Anotar ("     PnP     : " + $reg.Pnp)
    Anotar ("     publicado em " + $classes.Count + " classe(s) de interface: " + ($classes -join " "))

    if ($fonte -eq $Clsid)      { $nossos += $reg }
    elseif ($fonte)             { $alheios += $reg }
    else                        { $desconhecidos += $reg }
}

Anotar ""
Anotar ("do Quall: " + $nossos.Count + " | de outros donos: " + $alheios.Count + " | dono desconhecido: " + $desconhecidos.Count)

foreach ($a in $alheios) {
    Anotar ("PRESERVADO (nao e nosso): " + $a.Hash + "  '" + $a.Nome + "'  fonte " + $a.Fonte)
}
foreach ($d in $desconhecidos) {
    Anotar ("PRESERVADO (dono desconhecido, decisao humana): " + $d.Hash + "  PnP " + $d.Pnp)
    Anotar ("   Um no sem CustomCaptureSourceClsid nao serve video a ninguem, mas um desinstalador")
    Anotar ("   nao decide isso sozinho. Se for carcaca nossa, use o remover.ps1 interativo:")
    Anotar ("     remover.ps1 -Orfao -SoONo -ManterDll -Hash " + $d.Hash)
}

if ($nossos.Count -eq 0) {
    Anotar ""
    Anotar "Nenhum no do Quall para remover."
    FinalizarLimpo
}

if ($SoRelatar) {
    Anotar ""
    Anotar "-SoRelatar: parando aqui. Removeria os nos do Quall listados acima."
    exit 0
}

# ------------------------------------------------------------------------------------------------
# A remocao. `pnputil /remove-device` e a via SUPORTADA. O caminho por registro NAO FUNCIONA:
# HKLM\SYSTEM\CurrentControlSet\Enum e protegido e administrador nao apaga (Remove-Item devolve
# "nao e possivel excluir uma arvore de subchave", reg delete devolve 1). E
# IMFVirtualCamera::Remove() devolve S_OK sem remover.
# ------------------------------------------------------------------------------------------------
$incompletos = @()
foreach ($n in $nossos) {
    Anotar ""
    Anotar ("--- removendo " + $n.Hash + " ('" + $n.Nome + "'), publicado em " + $n.Classes.Count + " classe(s) ---")

    # Duas tentativas. A primeira costuma bastar; a segunda existe porque o Frame Server pode
    # estar com o dispositivo aberto no instante da primeira, e parar o servico entre elas e
    # barato. Se a segunda tambem nao limpar, o script NAO insiste: relata.
    for ($tentativa = 1; $tentativa -le 2; $tentativa++) {
        $saida = & pnputil /remove-device ("SWD\VCAMDEVAPI\" + $n.Hash) 2>&1
        $codigo = $LASTEXITCODE
        foreach ($l in $saida) { Anotar ("   pnputil: " + $l) }
        Anotar ("   pnputil -> codigo " + $codigo + " (tentativa " + $tentativa + ")")

        $sobrou = @(OndeAindaEsta $n.Hash)
        if ($sobrou.Count -eq 0) { break }

        if ($tentativa -eq 1) {
            Anotar ("   ainda em " + $sobrou.Count + " lugar(es); parando o Frame Server e tentando de novo")
            foreach ($svc in @("FrameServerMonitor", "FrameServer")) {
                $s = Get-Service $svc -ErrorAction SilentlyContinue
                if ($s -and $s.Status -eq "Running") { Stop-Service $svc -Force -ErrorAction SilentlyContinue }
            }
            Start-Sleep -Milliseconds 1200
        }
    }

    # A conferencia. Nao contra o numero que o no tinha antes, e sim contra ZERO -- porque
    # "sumiram duas das quatro" e exatamente o resultado que fabrica o fantasma, e ele passaria
    # numa conferencia que so olhasse a diferenca.
    $sobrou = @(OndeAindaEsta $n.Hash)
    if ($sobrou.Count -eq 0) {
        Anotar ("   CONFERIDO NO REGISTRO: o no e TODAS as " + $n.Classes.Count + " classes sumiram.")
    } else {
        Anotar ("   SOBROU em " + $sobrou.Count + " lugar(es):")
        foreach ($s in $sobrou) { Anotar ("      " + $s) }
        Anotar ("   NAO declarado removido. Um no meio-apagado vira o fantasma 'AvStream Media Device'.")
        $incompletos += $n.Hash
    }
}

# ------------------------------------------------------------------------------------------------
Anotar ""
if ($incompletos.Count -gt 0) {
    $texto = @()
    $texto += "A desinstalacao do Quall NAO conseguiu remover a camera virtual por inteiro."
    $texto += ""
    $texto += "Nos que sobraram (total ou parcialmente):"
    foreach ($h in $incompletos) {
        $texto += ("  " + $h)
        foreach ($s in (OndeAindaEsta $h)) { $texto += ("     ainda em " + $s) }
    }
    $texto += ""
    $texto += "Um no meio-apagado continua enumerado como camera, sem nome e sem fonte -- e o"
    $texto += "fantasma 'AvStream Media Device'. Ele nao entrega imagem e nao se conserta"
    $texto += "reinstalando o Quall."
    $texto += ""
    $texto += "O que fazer, como Administrador:"
    # Aspas simples, e NAO `\"`. Em PowerShell a barra invertida nao escapa aspas -- o escape e a
    # crase. `"... \"SWD..."` fecha a string na segunda aspa e o resto vira comando solto:
    #
    #     Token 'SWD\VCAMDEVAPI\<hash>\""' inesperado na expressao ou instrucao.
    #
    # E o PowerShell analisa o ARQUIVO INTEIRO antes de executar qualquer linha, entao este erro
    # numa mensagem de texto derrubava o roteiro TODO. Medido em 2026-08-30, na primeira vez que
    # alguem o executou: nenhuma linha dele jamais rodou, e a acao adiada do MSI que o chama tem
    # `Return="ignore"` -- ou seja, a desinstalacao dizia que tinha terminado e a camera virtual
    # ficava de pe, que e exatamente o fantasma que este arquivo existe para evitar.
    $texto += '  pnputil /remove-device "SWD\VCAMDEVAPI\<hash>"'
    $texto += "e conferir no registro que o hash sumiu do Enum e de TODAS as classes de interface"
    $texto += "sob HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses -- procurando, nao"
    $texto += "conferindo contra uma lista."
    $texto += ""
    $texto += ("Diario completo: " + $Diario)
    try {
        $pasta = Split-Path -Parent $Marcador
        if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        Set-Content -LiteralPath $Marcador -Value ($texto -join [Environment]::NewLine) -Encoding UTF8
    } catch { }
    Anotar ("REMOCAO INCOMPLETA em " + $incompletos.Count + " no(s). Marcador gravado em " + $Marcador)
    Anotar "A desinstalacao segue (um MSI que se recusa a terminar so leva a remocao a forca), mas"
    Anotar "ela nao mente: o marcador fica, e a pasta ProgramData\Quall fica com ele."
    exit 0
}

Anotar "Todos os nos do Quall foram removidos e conferidos no registro."
Anotar ""
Anotar "AINDA NAO DECLARE A MAQUINA LIMPA. Em 2026-08-27, nesta bancada, um no removido por"
Anotar "pnputil e conferido no registro na hora VOLTOU depois do reinicio -- sem FriendlyName,"
Anotar "sem CustomCaptureSourceClsid, PnP 'Desconectado' e fora da enumeracao. Rode este script"
Anotar "com -SoRelatar depois do proximo boot antes de dizer que sobrou zero."

FinalizarLimpo
