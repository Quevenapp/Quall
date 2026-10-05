#Requires -Version 5.1
<#
PORTAO LOCAL DE COMPILACAO WINDOWS

Windows x64, Rust/MSVC, SDK do Windows, Python e, para o MSI, WiX 5.0.2.
Nao instala o app ou driver, muda ExecutionPolicy, configura host remoto ou cria certificados.
O passo opcional OBS compila com -SemInstalar. Cargo usa --locked, dois jobs e --offline por
padrao; -ComRede permite resolver dependencias via rede. Cabecalhos OBS podem exigir rede.

Uso:
  powershell -NoProfile -File tools\portao.ps1 -Lista
  powershell -NoProfile -File tools\portao.ps1 -So app,camera
  powershell -NoProfile -File tools\portao.ps1 -PararNoPrimeiro

Etapas:
  fronteira   calibracao/checks estaticos e analise de todos os .ps1 pelo parser PowerShell
  app         alvos e testes com net,loja; receptor sem features; artefatos sem monitor
  camera      fonte cdylib e sonda, com testes e conferencia dos artefatos
  instalador  MSI x64 sem driver; precisa do WiX
  obs         plugin compilado sem instalar; somente com -ComObs

A propagacao de codigos de saida e aferida antes de medir. Suites sao conferidas pelo diario;
nao encontrar testes ou binarios obrigatorios reprova a etapa. A feature tela-estendida-futura
nao esta disponivel neste snapshot e nao faz parte deste portao.
#>
param(
    # So imprime os nomes das superficies.
    [switch]$Lista,
    # Roda so as superficies nomeadas.
    [string[]]$So = @(),
    # Para na primeira reprovacao em vez de listar todas.
    [switch]$PararNoPrimeiro,
    # Levanta o --offline do cargo.
    [switch]$ComRede,
    # Liga a superficie do OBS, que baixa os cabecalhos do libobs por git clone.
    [switch]$ComObs,
    # Raiz do repositorio. Por padrao, a pasta acima desta.
    [string]$Raiz
)

$ErrorActionPreference = "Continue"
# O portao nao muda ExecutionPolicy; execute com a politica autorizada do ambiente.

# TODA saida do portao passa por aqui, e nao por `Write-Output`, por um motivo mecanico que ja
# escondeu um erro nesta mesma rodada: em PowerShell o canal de sucesso E o valor de retorno. Um
# `Write-Output` dentro de uma funcao vira parte do que a funcao devolve -- entao a mensagem some
# da tela (fica presa no `if`) e o booleano vira um array, que e sempre verdadeiro. As duas metades
# do defeito empurram para o mesmo lado: o portao fica mudo E aprova.
#
# `[Console]::Out` escreve direto na saida padrao, fora do canal de sucesso. As funcoes voltam a
# devolver so o booleano, e a mensagem aparece.
function Diga($texto) { [Console]::Out.WriteLine([string]$texto) }

if (-not $Raiz) { $Raiz = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
$Diarios = Join-Path $Raiz "target\portao-windows"

$SUPERFICIES = @("fronteira", "app", "camera", "instalador", "obs")

if ($Lista) { $SUPERFICIES | ForEach-Object { Diga $_ }; exit 0 }

# `-So a,b,c` chega como UMA string quando o roteiro e invocado com `-File`:
# o PowerShell passa os argumentos literais e nao converte a virgula em
# array. Sem esta linha o portao respondia "superficie desconhecida: fronteira,app,camera".
$So = @($So | ForEach-Object { $_ -split "," } | Where-Object { $_ -ne "" })

$Escolhidas = if ($So.Count -gt 0) { $So } else { $SUPERFICIES }
foreach ($n in $Escolhidas) {
    if ($SUPERFICIES -notcontains $n) {
        Diga "superficie desconhecida: $n (use -Lista)"
        exit 2
    }
}

New-Item -ItemType Directory -Path $Diarios -Force | Out-Null
$Offline = if ($ComRede) { @() } else { @("--offline") }
$script:ObsInicio = $null
$script:ObsFim = $null

# ------------------------------------------------------------------------------------------------
# Apoio
# ------------------------------------------------------------------------------------------------

# Roda um comando nativo com o diario EM ARQUIVO e devolve o codigo de saida DO COMANDO.
#
# `& cargo ... | Select-Object -Last 40` devolveria o codigo do cmdlet, nao o do cargo -- a versao
# em PowerShell do `cmd | tail` que o portao do macOS evita com a mesma funcao. `Out-File` e
# cmdlet e nao altera $LASTEXITCODE, mas isso e afirmacao sobre a plataforma: a afericao abaixo a
# mede em vez de confiar nela.
function Correr($diario, $exe, [string[]]$argumentos) {
    ("   $ " + $exe + " " + ($argumentos -join " ")) | Out-File -Append -Encoding utf8 $diario
    & $exe @argumentos 2>&1 | Out-File -Append -Encoding utf8 $diario
    return $LASTEXITCODE
}

function Aferir-Propagacao {
    $d = Join-Path $Diarios "_afericao.log"
    "" | Out-File -Encoding utf8 $d
    $c = Correr $d "cmd.exe" @("/c", "exit 3")
    if ($c -ne 3) {
        Diga "   !! a afericao do proprio portao falhou: um comando que sai com 3 devolveu '$c'."
        Diga "      Com o codigo de saida perdido no cano, TODAS as superficies passariam."
        return $false
    }
    $c = Correr $d "cmd.exe" @("/c", "exit 0")
    if ($c -ne 0) {
        Diga "   !! a afericao do proprio portao falhou: um comando que sai com 0 devolveu '$c'."
        return $false
    }
    Diga "   afericao do portao: codigo de saida atravessa o cano (3 -> 3, 0 -> 0)"
    return $true
}

function Achar-Python {
    foreach ($c in @("python", "python3", "py")) {
        $g = Get-Command $c -ErrorAction SilentlyContinue
        if ($g) { return $g.Source }
    }
    return $null
}

# O `wix` v5 e ferramenta .NET global. Numa instalacao privada do SDK (sem registro global) o
# apphost nao acha o runtime e morre com "You must install .NET to run this application" -- dai o
# DOTNET_ROOT. Medido nesta bancada em 2026-08-30.
function Preparar-Dotnet {
    if (Get-Command wix -ErrorAction SilentlyContinue) { return }
    $priv = Join-Path $env:USERPROFILE ".dotnet"
    if (Test-Path (Join-Path $priv "dotnet.exe")) {
        $env:DOTNET_ROOT = $priv
        $env:PATH = "$priv;$priv\tools;" + $env:PATH
    }
}

function Erros-Do-Diario($diario, $quantas = 24) {
    if (-not (Test-Path $diario)) { return }
    Get-Content $diario |
        Select-String -Pattern "^error|error\[|error:|FALHOU|PROBLEMA|PEGOU|could not compile|test result: FAILED|panicked" |
        Select-Object -First $quantas |
        ForEach-Object { Diga ("       " + $_.Line.Trim()) }
}

function Ecoar($diario, $padrao, $quantas) {
    Get-Content $diario -ErrorAction SilentlyContinue |
        Select-String -Pattern $padrao |
        Select-Object -Last $quantas |
        ForEach-Object { Diga ("   " + $_.Line.Trim()) }
}

# A suite e lida DO ARQUIVO, nunca por cano. Devolve $true se houver pelo menos uma linha
# "test result:" e nenhuma delas for FAILED.
function Suite-Do-Arquivo($diario) {
    $linhas = @(Get-Content $diario | Select-String -SimpleMatch "test result:")
    if ($linhas.Count -eq 0) {
        Diga "   !! nenhuma linha 'test result:' no diario -- a suite nao rodou"
        return $false
    }
    foreach ($l in $linhas) {
        # `-cmatch`, e nao `-match`: o `-match` do PowerShell e INSENSIVEL A CAIXA por padrao, e
        # por isso ele casava "FAILED" dentro de "0 failed" -- reprovando toda suite verde. Custou
        # uma corrida nesta bancada, e e o mesmo formato do defeito que este portao caca: um
        # instrumento que da a resposta errada em silencio.
        if ($l.Line -cmatch "test result: FAILED") {
            Diga ("   !! " + $l.Line.Trim())
            return $false
        }
    }
    $passaram = 0
    foreach ($l in $linhas) { if ($l.Line -match "(\d+) passed") { $passaram += [int]$Matches[1] } }
    Diga ("   suite: " + $linhas.Count + " alvo(s), " + $passaram + " teste(s) passaram (lidos do arquivo)")
    return $true
}

# ------------------------------------------------------------------------------------------------
# As superficies
# ------------------------------------------------------------------------------------------------

function Passo-Fronteira {
    $d = Join-Path $Diarios "fronteira.log"; "" | Out-File -Encoding utf8 $d
    $py = Achar-Python
    if (-not $py) { Diga "   !! nao achei python nesta maquina"; return $false }
    $ok = $true

    # AppleDouble antes de tudo, e com nome proprio.
    #
    # As conferencias abrem cada `.c`/`.m`/`.swift` como UTF-8. Um `._algo.rs` -- o bifurcado de
    # recurso que o rsync do macOS deixa e que a copia de fontes ja registra como lixo de rodada
    # anterior -- nao e texto, e a conferencia morre com um `UnicodeDecodeError` que nao aponta
    # para o arquivo culpado. Foram 330 deles nesta copia do Windows de teste em 2026-08-30, e o sintoma foi
    # exatamente esse: a superficie reprovando sem dizer por que.
    #
    # O portao NAO os apaga: nao e trabalho de portao mexer no disco de ninguem. Ele nomeia o
    # problema e da o comando.
    $lixo = @(Get-ChildItem $Raiz -Recurse -File -Filter "._*" -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notlike "*\target\*" -and $_.FullName -notlike "*\.git\*" })
    if ($lixo.Count -gt 0) {
        Diga ("   !! " + $lixo.Count + " arquivo(s) AppleDouble (._*) nesta arvore. Eles nao sao")
        Diga "      texto, e as conferencias morrem com UnicodeDecodeError sem dizer em qual arquivo."
        Diga ("      Ex.: " + $lixo[0].FullName)
        Diga "      Limpe com:  Get-ChildItem <raiz> -Recurse -File -Filter '._*' | Remove-Item -Force"
        return $false
    }

    # 1. As conferencias do lado de ca, sobre os arquivos que existirem nesta arvore: elas leem o
    #    quall.h e cobram struct de C zerado e o padrao (buf, cap).
    $roteiro = Join-Path $PSScriptRoot "confere-fronteira.py"
    if (Test-Path $roteiro) {
        if ((Correr $d $py @($roteiro, "--calibrar")) -ne 0) {
            Diga "   !! confere-fronteira.py: cega para pelo menos uma regra"
            $ok = $false
        }
        Ecoar $d "^\s+(pegou|N.O PEGOU)" 8
        if ((Correr $d $py @($roteiro)) -ne 0) {
            Diga "   !! confere-fronteira.py reprovou"
            $ok = $false
        }
        Ecoar $d "conferidas|CONFER.NCIA OK|PROBLEMA" 4
    } else {
        # Nao e "pulei": e reprovacao. A arvore que chega ao Windows de teste tem de trazer o roteiro, senao
        # este passo fica verde por ausencia -- o modo de falha que este portao existe para nao
        # repetir.
        Diga "   !! tools\confere-fronteira.py nao esta nesta arvore"
        $ok = $false
    }

    # 2. As mesmas duas ideias, no Rust/Win32 em que o lado Windows esta escrito.
    $win = Join-Path $PSScriptRoot "portao-fronteira-windows.py"
    if (-not (Test-Path $win)) {
        Diga "   !! tools\portao-fronteira-windows.py nao esta nesta arvore"
        return $false
    }
    if ((Correr $d $py @($win, "--calibrar")) -ne 0) {
        Diga "   !! portao-fronteira-windows.py: cega para uma regra, ou acusando demais"
        $ok = $false
    }
    Ecoar $d "^\s+(pegou|N.O PEGOU|ACUSOU|n.o acusou)" 8
    if ((Correr $d $py @($win)) -ne 0) {
        Diga "   !! portao-fronteira-windows.py reprovou"
        $ok = $false
    }
    Ecoar $d "conferidas|CONFER.NCIA OK" 3

    # 3. TODO .ps1 do repositorio TEM DE ANALISAR.
    #
    # Esta conferencia nasceu de um defeito medido, e do pior tipo. `camera-desinstalar.ps1` -- a
    # varredura que o MSI chama para tirar a camera virtual -- tinha, numa mensagem de texto:
    #
    #     $texto += "  pnputil /remove-device \"SWD\...\<hash>\""
    #
    # (o nome da classe de dispositivo esta abreviado de proposito: escrito por extenso ao lado de
    # "remove-device", este comentario faria `tools/confere-desinstalacao-camera.py` acusar ESTE
    # arquivo de ser um removedor de no fora do portao. A heuristica dele e casamento de texto, e
    # nao distingue prosa de codigo -- fica registrado.)
    #
    # Em PowerShell a barra invertida NAO escapa aspas (o escape e a crase), entao a string fecha
    # cedo e o arquivo nao analisa. E o PowerShell analisa o ARQUIVO INTEIRO antes de rodar a
    # primeira linha: o roteiro estava 100% morto. A acao customizada que o chama tem
    # `Return="ignore"`, entao a desinstalacao terminava dizendo que tinha dado certo e a camera
    # ficava de pe -- o fantasma que aquele arquivo existe para evitar.
    #
    # E o formato de defeito desta casa: compila, roda, e mente. So que aqui nem roda -- e ninguem
    # via, porque `.ps1` nao tem compilador e ninguem tinha executado.
    #
    # O analisador do proprio PowerShell responde isso em milissegundos, por arquivo, sem executar
    # nada.
    $ps1 = @(Get-ChildItem $Raiz -Recurse -File -Filter "*.ps1" -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notlike "*\target\*" -and $_.FullName -notlike "*\.git\*" })
    $quebrados = 0
    foreach ($f in $ps1) {
        $errs = $null; $toks = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$toks, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            $quebrados++
            Diga ("   !! " + $f.FullName.Substring($Raiz.Length + 1) + " NAO ANALISA:")
            foreach ($e in ($errs | Select-Object -First 3)) {
                Diga ("      linha " + $e.Extent.StartLineNumber + ": " + $e.Message)
            }
        }
    }
    # Aferir: um roteiro com defeito conhecido tem de ser pego. Uma conferencia de sintaxe que
    # nunca foi vista falhando pode estar verde por nao ter achado arquivo nenhum.
    $iscaCaminho = Join-Path $env:TEMP ("portao-isca-" + $PID + ".ps1")
    Set-Content -LiteralPath $iscaCaminho -Value '$t = "abre \"e nao fecha' -Encoding UTF8
    $errs = $null; $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($iscaCaminho, [ref]$toks, [ref]$errs)
    Remove-Item $iscaCaminho -Force -ErrorAction SilentlyContinue
    if (-not $errs -or $errs.Count -eq 0) {
        Diga "   !! a afericao da analise de .ps1 falhou: a isca com erro de sintaxe passou"
        $ok = $false
    } elseif ($ps1.Count -eq 0) {
        Diga "   !! nenhum .ps1 encontrado nesta arvore -- verde por ausencia, nao por acerto"
        $ok = $false
    } else {
        Diga ("   roteiros: " + $ps1.Count + " arquivo(s) .ps1 analisados, " + $quebrados + " com erro de sintaxe (isca pega)")
    }
    if ($quebrados -gt 0) { $ok = $false }

    # 4. O portao da desinstalacao da camera, que ja existia e nunca esteve em portao nenhum:
    #    "um portao que ninguem roda e um documento com aspiracao" (README do instalador).
    $des = Join-Path $PSScriptRoot "confere-desinstalacao-camera.py"
    if (Test-Path $des) {
        if ((Correr $d $py @($des, "--raiz", $Raiz)) -ne 0) {
            Diga "   !! confere-desinstalacao-camera.py reprovou"
            $ok = $false
        }
        Ecoar $d "^passou:|^REPROVADO:" 1
    } else {
        Diga "   !! tools\confere-desinstalacao-camera.py nao esta nesta arvore"
        $ok = $false
    }

    return $ok
}

function Passo-App {
    $d = Join-Path $Diarios "app.log"; "" | Out-File -Encoding utf8 $d
    $pasta = Join-Path $Raiz "apps\windows"
    if (-not (Test-Path $pasta)) { Diga "   !! nao achei $pasta"; return $false }
    Push-Location $pasta
    try {
        if ((Correr $d "cargo" (@("build", "--locked", "--jobs", "2", "--all-targets", "--features", "net,loja") + $Offline)) -ne 0) {
            return $false
        }
        if ((Correr $d "cargo" (@("test", "--locked", "--jobs", "2", "--features", "net,loja") + $Offline)) -ne 0) {
            # Mesma regra do portao do macOS: repetir uma vez antes de acusar.
            "== REPETICAO ==" | Out-File -Append -Encoding utf8 $d
            Diga "   suite vermelha; repetindo uma vez"
            if ((Correr $d "cargo" (@("test", "--locked", "--jobs", "2", "--features", "net,loja") + $Offline)) -ne 0) { return $false }
        }
        if (-not (Suite-Do-Arquivo $d)) { return $false }

        # O caminho documentado que NAO depende do nucleo: `quall-receiver-probe` sem `quall-core`.
        # `apps/windows/Cargo.toml` promete que ele compila em segundos sem OpenSSL; promessa em
        # comentario que ninguem compila envelhece igual a lista fixa de GUIDs.
        if ((Correr $d "cargo" (@("build", "--locked", "--jobs", "2", "--bin", "quall-receiver-probe", "--no-default-features") + $Offline)) -ne 0) {
            Diga "   !! o caminho --no-default-features nao compila mais"
            return $false
        }

        # Conferir no ARTEFATO. Sem `--features net` o cargo pula os dois binarios de
        # required-features e devolve zero: o portao passaria sem ter compilado o app de produto.
        $exes = @(Get-ChildItem (Join-Path $pasta "target\debug\*.exe") -ErrorAction SilentlyContinue)
        Diga ("   binarios em target\debug: " + (($exes | ForEach-Object { $_.Name }) -join ", "))
        # Alvos deste release: sondas sem driver e o app. Alvos futuros requerem a feature
        # tela-estendida-futura, explicitamente indisponivel neste snapshot.
        foreach ($n in @("quall-app.exe", "quall-quinta-porta.exe", "quall-receiver-probe.exe", "quall-gemeos.exe", "quall-espera.exe", "quall-som-local.exe")) {
            if (@($exes | Where-Object { $_.Name -eq $n }).Count -eq 0) {
                Diga "   !! $n nao saiu do build"
                return $false
            }
        }
        $appExe = Join-Path $pasta "target\debug\quall-app.exe"
        $texto = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($appExe))
        if (-not $texto.Contains("quall-distribuicao: release-sem-monitor-v2")) {
            Diga "   !! quall-app.exe sem o marcador da variante sem monitor"
            return $false
        }
        foreach ($proibido in @("quall-distribuicao: desenvolvimento-tela-estendida-v1", "SudoVDA.inf", "SudoVDA.cat", "SudoVDA.dll", "SudoVDA.cer")) {
            if ($texto.Contains($proibido)) {
                Diga "   !! variante de driver presente no app: $proibido"
                return $false
            }
        }
        return $true
    } finally { Pop-Location }
}

function Passo-Camera {
    $d = Join-Path $Diarios "camera.log"; "" | Out-File -Encoding utf8 $d
    $pasta = Join-Path $Raiz "integrations\camera-windows"
    if (-not (Test-Path $pasta)) { Diga "   !! nao achei $pasta"; return $false }
    Push-Location $pasta
    try {
        if ((Correr $d "cargo" (@("build", "--locked", "--jobs", "2", "--all-targets") + $Offline)) -ne 0) { return $false }
        if ((Correr $d "cargo" (@("test") + $Offline)) -ne 0) {
            "== REPETICAO ==" | Out-File -Append -Encoding utf8 $d
            Diga "   suite vermelha; repetindo uma vez"
            if ((Correr $d "cargo" (@("test") + $Offline)) -ne 0) { return $false }
        }
        if (-not (Suite-Do-Arquivo $d)) { return $false }
        # A fonte e uma cdylib: se o crate-type mudar sem ninguem ver, o .dll some e o Frame Server
        # nao tem o que carregar. Conferir o artefato, nao o codigo de retorno.
        $dll = Join-Path $pasta "target\debug\quall_camera_fonte.dll"
        if (-not (Test-Path $dll)) {
            Diga "   !! cargo passou mas nao ha $dll"
            return $false
        }
        Diga ("   quall_camera_fonte.dll: " + [math]::Round((Get-Item $dll).Length / 1KB) + " KiB")
        $sonda = Join-Path $pasta "target\debug\quall-camera-sonda.exe"
        if (-not (Test-Path $sonda)) { Diga "   !! nao ha $sonda"; return $false }
        return $true
    } finally { Pop-Location }
}

function Passo-Instalador {
    $d = Join-Path $Diarios "instalador.log"; "" | Out-File -Encoding utf8 $d
    Preparar-Dotnet
    if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
        Diga "   !! 'wix' nao esta no PATH:  dotnet tool install --global wix --version 5.0.2"
        Diga "      (o WiX v7 exige aceitar a EULA do Open Source Maintenance Fee; o v5 nao)"
        return $false
    }
    $roteiro = Join-Path $Raiz "apps\windows\scripts\instalador\construir-msi.ps1"
    if (-not (Test-Path $roteiro)) { Diga "   !! nao achei $roteiro"; return $false }
    $saida = Join-Path $Diarios "msi"
    $c = Correr $d "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $roteiro,
                                      "-Versao", "0.1.0", "-Saida", $saida)
    if ($c -ne 0) { return $false }
    $msi = @(Get-ChildItem (Join-Path $saida "*.msi") -ErrorAction SilentlyContinue)
    if ($msi.Count -eq 0) { Diga "   !! o wix passou mas nao ha .msi em $saida"; return $false }
    foreach ($m in $msi) {
        Diga ("   " + $m.Name + ": " + [math]::Round($m.Length / 1MB, 1) + " MB")
        if ($m.Length -lt 200KB) {
            Diga "   !! .msi pequeno demais para conter os dois binarios"
            return $false
        }
    }
    if (Test-Path (Join-Path $saida "quall-driver.exe")) {
        Diga "   !! pasta de saida misturada com instalador de driver legado"
        return $false
    }
    return $true
}

function Passo-Obs {
    $d = Join-Path $Diarios "obs.log"; "" | Out-File -Encoding utf8 $d
    $pasta = Join-Path $Raiz "plugins\obs"
    if (-not (Test-Path $pasta)) { Diga "   !! nao achei $pasta nesta arvore"; return $false }
    $roteiro = Join-Path $pasta "construir.ps1"
    if (-not (Test-Path $roteiro)) { Diga "   !! nao achei $roteiro"; return $false }
    if (-not (Test-Path (Join-Path $pasta ".libobs\obs-studio\libobs\obs-module.h"))) {
        $script:ObsInicio = Get-Date
        Diga ("   BAIXANDO os cabecalhos do libobs (git clone), inicio " + $script:ObsInicio.ToString("HH:mm:ss"))
    }
    $c = Correr $d "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $roteiro, "-SemInstalar")
    if ($script:ObsInicio) {
        $script:ObsFim = Get-Date
        Diga ("   fim " + $script:ObsFim.ToString("HH:mm:ss"))
    }
    return ($c -eq 0)
}

# ------------------------------------------------------------------------------------------------
# Laco
# ------------------------------------------------------------------------------------------------
$Inicio = Get-Date
Diga ("PORTAO DE COMPILACAO (Windows) -- " + $Inicio.ToString("yyyy-MM-dd HH:mm:ss zzz"))
Diga ("maquina: " + $env:COMPUTERNAME + "   sessao: " + (Get-Process -Id $PID).SessionId)
Diga "raiz: $Raiz"
Diga "diarios: $Diarios"
if (-not $ComRede) { Diga "cargo em modo offline (use -ComRede para levantar)" }
Diga ""

if (-not (Aferir-Propagacao)) {
    Diga ""
    Diga "O PORTAO NAO SE AFERE. Nao vou medir com instrumento quebrado."
    exit 2
}

$Vereditos = @()
$FalhouAlguma = $false

foreach ($nome in $Escolhidas) {
    if ($nome -eq "obs" -and -not $ComObs) {
        $Vereditos += ,@("obs", "PULADA", "sem -ComObs")
        continue
    }
    Diga ""
    Diga ("== " + $nome + " ==")
    $t0 = Get-Date
    $ok = switch ($nome) {
        "fronteira"  { Passo-Fronteira }
        "app"        { Passo-App }
        "camera"     { Passo-Camera }
        "instalador" { Passo-Instalador }
        "obs"        { Passo-Obs }
    }
    # `switch` devolve TUDO o que o bloco escreveu no canal de sucesso, nao so o `return`. Um
    # Diga de dentro do passo viraria parte do resultado, e um array nao vazio e sempre
    # verdadeiro -- ou seja, o portao aprovaria tudo. Pegar o ultimo elemento recupera o booleano.
    if ($ok -is [array]) { $ok = $ok[-1] }
    $dt = [int]((Get-Date) - $t0).TotalSeconds
    if ($ok -eq $true) {
        Diga ("   OK ({0} s)" -f $dt)
        $Vereditos += ,@($nome, "OK", "$dt s")
    } else {
        Diga ("   FALHOU ({0} s) -- {1}" -f $dt, (Join-Path $Diarios "$nome.log"))
        Erros-Do-Diario (Join-Path $Diarios "$nome.log")
        $Vereditos += ,@($nome, "FALHOU", "$dt s")
        $FalhouAlguma = $true
        if ($PararNoPrimeiro) { break }
    }
}

Diga ""
Diga "== VEREDITO =="
foreach ($v in $Vereditos) {
    Diga ("  {0,-12} {1,-8} {2,8}  {3}" -f $v[0], $v[1], $v[2], (Join-Path $Diarios ($v[0] + ".log")))
}
Diga ("  {0,-12} {1} s" -f "total", [int]((Get-Date) - $Inicio).TotalSeconds)

if ($script:ObsInicio) {
    Diga ""
    Diga "== TRAFEGO NA WI-FI =="
    Diga ("  O clone dos cabecalhos do libobs ocupou a Wi-Fi entre " +
                  $script:ObsInicio.ToString("HH:mm:ss") + " e " + $script:ObsFim.ToString("HH:mm:ss") +
                  " (horario local).")
}

if ($FalhouAlguma) {
    Diga ""
    Diga "O PORTAO REPROVOU. Os diarios estao em $Diarios"
    exit 1
}
Diga ""
Diga "TUDO COMPILA (lado Windows)."
exit 0
