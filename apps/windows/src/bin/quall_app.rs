//! `quall-app` — o app Windows de produto. Abre uma janela, escolhe o que transmitir, espelha.
//!
//! Ver `docs/app-windows.md` para a decisão de tecnologia, o que foi cortado e o que foi provado.

#![cfg(windows)]
#![windows_subsystem = "windows"]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::time::Duration;
use clap::Parser;

use quall_capture_probe::{
    argumentos::Argumentos, emissor::Emissor, instancia, janela, receptor::Receptor, registro,
    regras_da_bandeja,
};

use windows::Win32::Media::MediaFoundation::{MFStartup, MFShutdown, MFSTARTUP_FULL, MF_VERSION};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    // O produto abre pelo atalho sem um console secundário. Erros que antes só saíam no
    // stderr precisam continuar visíveis, inclusive antes de COM/Media Foundation iniciar.
    // O auxiliar elevado usa seu próprio cano/diário; nunca escreve em pasta do usuário.
    #[cfg(feature = "tela-estendida-futura")]
    let processo_elevado = std::env::args_os().nth(1).is_some_and(|a| a == "--driver-tela-estendida");
    #[cfg(not(feature = "tela-estendida-futura"))]
    let processo_elevado = false;
    if !processo_elevado {
        std::panic::set_hook(Box::new(|falha| {
            let _ = registro::abrir(None);
            let resumo = quall_capture_probe::higiene_do_registro::resumo_panico(falha);
            registro::linha(format!("quall-app: !! falha inesperada: {resumo}"));
            if regras_da_bandeja::abertura_de_produto(std::env::args_os().skip(1)) {
                mostrar_mensagem(&format!("{}\n\n{resumo}", quall_capture_probe::idioma::t("O Quall Studio encontrou uma falha inesperada.")), true);
            }
        }));
    }
    if let Err(erro) = rodar() {
        let _ = registro::abrir(None);
        registro::linha(format!("quall-app: !! não conseguiu iniciar: {erro}"));
        if regras_da_bandeja::abertura_de_produto(std::env::args_os().skip(1)) {
            mostrar_mensagem(&format!("{}\n\n{erro}", quall_capture_probe::idioma::t("O Quall Studio não conseguiu iniciar.")), true);
        }
        std::process::exit(1);
    }
}

fn mostrar_mensagem(texto: &str, falha: bool) {
    use windows::core::{w, PCWSTR};
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_ICONINFORMATION, MB_OK};
    let largo: Vec<u16> = texto.encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(None, PCWSTR(largo.as_ptr()), w!("Quall Studio"), MB_OK | if falha { MB_ICONERROR } else { MB_ICONINFORMATION });
    }
}

fn rodar() -> windows::core::Result<()> {
    // **O processo elevado do driver da tela estendida** (02/10, noite), antes de tudo: antes da
    // instância única, do COM, do registro e do `clap` (que recusaria os argumentos). Só os dois
    // formatos exatos de `regras_do_driver::ler_pedido`; qualquer outra coisa que comece com
    // `--driver-tela-estendida` sai com 2 sem tocar em nada. Ver `driver_da_tela_estendida.rs`.
    #[cfg(feature = "tela-estendida-futura")]
    {
        use quall_capture_probe::regras_do_driver as rd;
        let brutos: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
        if brutos.first().is_some_and(|a| a == rd::ARGUMENTO) {
            let codigo = match brutos.iter().map(|a| a.to_str().map(str::to_string)).collect::<Option<Vec<String>>>() {
                Some(args) if !cfg!(feature = "loja") => quall_capture_probe::driver_da_tela_estendida::elevado::rodar(&args),
                _ => rd::saida::RECUSADO,
            };
            std::process::exit(codigo as i32);
        }
    }
    let argumentos = match Argumentos::try_parse() {
        Ok(argumentos) => argumentos,
        Err(erro) => {
            let _ = registro::abrir(None);
            let texto = quall_capture_probe::higiene_do_registro::sanitizar_argumentos(&erro.to_string());
            registro::linha(&texto);
            // Mantém stdout/stderr redirecionáveis para a bancada, sem depender de um console.
            if erro.use_stderr() { eprintln!("{texto}"); } else { let _ = erro.print(); }
            std::process::exit(erro.exit_code());
        }
    };

    // **Um Quall de produto por sessão**, e antes de tudo (o COM, as câmeras virtuais, o mDNS, a
    // janela): aberto pelo atalho com outro já rodando — na bandeja, por exemplo —, este chama a
    // janela daquele e sai com 0 sem abrir nada. Duas instâncias juntas brigaram pelas câmeras
    // virtuais no Dell em 01/10 (ver `instancia.rs`). Só na abertura de produto, sem argumentos: os
    // roteiros de bancada passam argumentos e rodam emissor e receptor na mesma máquina. A guarda
    // segura o mutex até o fim do `main`.
    let _instancia = if regras_da_bandeja::abertura_de_produto(std::env::args_os().skip(1)) {
        // Sem argumentos não há `--registro`: o registro é o padrão, e é nele que a linha de quem
        // sai sem abrir fica (aberto de novo mais abaixo, pelo mesmo caminho).
        let _ = registro::abrir(None);
        // O idioma antes da caixa "O Quall ainda está fechando…" de `tomar` (a tradução, 02/10).
        quall_capture_probe::idioma::iniciar(&quall_capture_probe::identidade::pasta_de_dados());
        match instancia::tomar() {
            instancia::Instancia::Primeira(guarda) => Some(guarda),
            instancia::Instancia::OutraAberta => return Ok(()),
        }
    } else {
        None
    };
    // **Bancada, fase 5**: o A/B do desentrelaçamento (o produto sempre desentrelaça).
    quall_capture_probe::captura_de_camera::SEM_DESENTRELACAR
        .store(argumentos.sem_desentrelacar, std::sync::atomic::Ordering::SeqCst);
    // **Bancada, 22/09**: o A/B do desentrelaçador (o padrão é o adapt2).
    quall_capture_probe::captura_de_camera::DESENTRELACADOR_BOB
        .store(argumentos.desentrelacador == "bob", std::sync::atomic::Ordering::SeqCst);
    // **Bancada, 22/09**: a câmera "parada" por janelas (`--pausar-camera`).
    if let Some(pausas) = &argumentos.pausar_camera {
        quall_capture_probe::captura_de_camera::configurar_pausas_de_bancada(pausas.0.clone());
    }
    // **Bancada, R9** (`docs/controles-de-camera.md` §5): a luma média de um quadro a cada 30, o
    // roteiro dos ajustes, a medida do modo compartilhado e a leitura de volta por segundo.
    quall_capture_probe::luma_de_bancada::LIGADA.store(argumentos.luma_media, std::sync::atomic::Ordering::SeqCst);
    if argumentos.ajustes_camera.is_some() || argumentos.ajustes_medir_compartilhada || argumentos.ajustes_leitura {
        quall_capture_probe::ajustes_da_camera::configurar_bancada(quall_capture_probe::ajustes_da_camera::ConfigDeBancada {
            roteiro: argumentos.ajustes_camera.as_ref().map(|r| r.0.clone()),
            medir_compartilhada: argumentos.ajustes_medir_compartilhada,
            leitura: argumentos.ajustes_leitura,
        });
    }

    // **Antes de qualquer coisa ler a identidade**: `--dados` é o `QUALL_PASTA_DE_DADOS` da
    // bancada, e o `device-id.txt` é lido na primeira vez que alguém pergunta.
    if let Some(pasta) = &argumentos.dados {
        std::env::set_var(quall_capture_probe::identidade::VARIAVEL_DA_PASTA, pasta);
    }

    // **Ciente de DPI antes de qualquer janela existir.** Sem isto o Windows escala a janela por
    // cima (borrada), e — o que importa mais num app de captura — as coordenadas de monitor que a
    // enumeração devolve viriam em pixels virtualizados, não nos reais. Um app que captura tela
    // não pode ver a tela por uma lente que o sistema esticou.
    let dpi_ok = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
        .is_ok();

    // **MTA, não STA.** O `Direct3D11CaptureFramePool::CreateFreeThreaded` da captura exige
    // apartamento multithreaded, e o apartamento é do processo. Uma janela Win32 funciona nos dois
    // (só OLE, arrastar-e-soltar e diálogos de shell exigem STA; o único diálogo de shell, o "Abrir
    // arquivo .txt…" do teleprompter, abre numa thread STA própria — `teleprompter/tela.rs`).
    let caminho = registro::abrir(argumentos.registro.as_deref());
    #[cfg(feature = "tela-estendida-futura")]
    registro::linha("quall-distribuicao: desenvolvimento-tela-estendida-v1");
    #[cfg(not(feature = "tela-estendida-futura"))]
    registro::linha("quall-distribuicao: release-sem-monitor-v2");
    if caminho.is_none() && regras_da_bandeja::abertura_de_produto(std::env::args_os().skip(1)) {
        mostrar_mensagem(&quall_capture_probe::idioma::t("O diário de diagnóstico não pôde ser aberto. As falhas de inicialização serão mostradas nesta janela."), true);
    }
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
    }

    // **Bancada.** Listar as saídas de áudio e sair, sem abrir janela nem sessão. Serve para uma
    // corrida escolher um endpoint que **não** é o padrão — a única condição em que o que o
    // loopback captura é provadamente só o que este processo tocou, e não a mistura da máquina.
    if argumentos.listar_saidas_de_audio {
        for linha in quall_capture_probe::audio::listar_saidas() {
            println!("{linha}");
        }
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
        return Ok(());
    }

    // **Bancada.** Esquecer um par só e sair (o passo de remoção da sonda da prova da S6).
    if let Some(id) = argumentos.esquecer_par.as_deref() {
        use quall_capture_probe::identidade::{esquecer_par, Esquecimento};
        // Saída 0: o par não está mais no `pares.json` (esquecido agora, ou já não estava).
        // Saída 1: não se leu ou não se gravou o arquivo, e nada foi esquecido (crítica 15, N3).
        let codigo = match esquecer_par(id) {
            Esquecimento::Esquecido => {
                println!("par solicitado esquecido");
                0
            }
            Esquecimento::NaoEstava => {
                println!("par solicitado não estava no pares.json");
                0
            }
            Esquecimento::Falhou(motivo) => {
                println!("!! par solicitado NÃO esquecido: {}", quall_capture_probe::higiene_do_registro::sanitizar(&motivo));
                1
            }
        };
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
        if codigo != 0 {
            std::process::exit(codigo);
        }
        return Ok(());
    }

    registro::linha(format!(
        "quall-app iniciou — dpi_por_monitor={dpi_ok} registro={} fps={} porta_pedida={} \
         som={} saida_de_audio={} tom_de_prova={}",
        caminho
            .map(|c| c.display().to_string())
            .unwrap_or_else(|| "(só stderr)".into()),
        argumentos.fps,
        argumentos.porta,
        if argumentos.sem_som { "não" } else { "sim" },
        argumentos.saida_de_audio.as_deref().unwrap_or("padrão"),
        argumentos
            .tom_de_prova
            .map(|h| format!("{h} Hz @ {:.3}", argumentos.tom_amplitude))
            .unwrap_or_else(|| "não".into()),
    ));
    // **O throttling de energia do processo, desligado** (`docs/teleprompter-com-camera.md` §8.2, a
    // S-W1: com ele como veio, dois Quick Sync a 21–27 fps na sessão interativa; desligado, 30,00).
    // O processo inteiro: a câmera, a rede, o gravador e o prompter vivem nele.
    registro::linha(quall_capture_probe::energia::desligar_throttling_do_processo());
    if argumentos.gravacao_no_carimbo_real {
        quall_capture_probe::gravador_local::usar_grade(false);
        registro::linha("bancada: a gravação no carimbo real, sem a grade (--gravacao-no-carimbo-real)");
    }

    // **Bancada.** Os retratos da janela e sair — antes de tudo o que abre rede, câmera virtual ou
    // captura: a janela desenha estados de exemplo, fora da tela, e cada um vai para um BMP.
    if let Some(pasta) = argumentos.retratos_de_bancada.as_deref() {
        let codigo = match janela::retratos(pasta) {
            Ok(linhas) => {
                for l in &linhas {
                    println!("{l}");
                }
                if linhas.iter().any(|l| l.contains("!!")) { 1 } else { 0 }
            }
            Err(e) => {
                println!("!! os retratos não saíram: {e}");
                1
            }
        };
        registro::linha("quall-app encerrou (--retratos-de-bancada)");
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
        if codigo != 0 {
            std::process::exit(codigo);
        }
        return Ok(());
    }

    // **O idioma** (a tradução EN/PT, 02/10): a escolha do seletor "PT | EN", guardada na pasta de
    // dados, ou o idioma da interface do Windows. Depois dos retratos, que fazem os dois idiomas
    // por conta própria, e antes de qualquer janela ou aviso.
    let idioma = quall_capture_probe::idioma::iniciar(&quall_capture_probe::identidade::pasta_de_dados());
    registro::linha(format!("idioma: {}", idioma.codigo()));

    // **Bancada.** O catálogo de fontes e sair — **antes** de `Receptor::novo` e de
    // `abrir_conhecidas`, que criariam um nó de câmera virtual por aparelho conhecido na conta de
    // quem está no computador. Nenhuma câmera é ativada: só enumerada, e o dono lido do registro.
    if argumentos.listar_fontes {
        let monitores = quall_capture_probe::fontes::monitores();
        let mut linhas: Vec<String> = monitores
            .iter()
            .map(|f| format!("monitor \"{}\" {}x{} | {}", f.nome, f.largura, f.altura, f.id))
            .collect();
        // As linhas do catálogo (o dono de cada câmera, e se entra), e as que **entram** no seletor —
        // com `--camera-de-bancada`, a câmera de bancada liberada ou a recusa (a fase 4). Com
        // `--sem-cameras` (bancada), **nem a enumeração** (a revisão do código da fase 5, L1: ela
        // rodava e só a linha do seletor sumia), e a linha diz por quê (a revisão da fase 4, m5).
        if argumentos.com_cameras() {
            let t0 = std::time::Instant::now();
            let (no_seletor, linhas_das_cameras) =
                quall_capture_probe::fontes::cameras(argumentos.camera_de_bancada.as_deref());
            linhas.extend(linhas_das_cameras);
            linhas.push(format!("câmeras: o catálogo levou {} ms", t0.elapsed().as_millis()));
            linhas.extend(no_seletor.iter().map(|f| format!("no seletor: câmera \"{}\" | {}", f.nome, f.id)));
        } else {
            linhas.push("--sem-cameras: nenhuma câmera enumerada, e nenhuma vai ao seletor".into());
        }
        for l in &linhas {
            println!("{l}");
        }
        registro::linha("quall-app encerrou (--listar-fontes)");
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
        return Ok(());
    }

    // **Antes de qualquer sessão subir**, e a ordem não é estilo: o crate `datachannel` chama
    // `rtcInitLogger` uma única vez, dentro de `RtcPeerConnection::new`, com o nível lido de
    // `log::max_level()`. Ligar depois disso não tem efeito nenhum, e o sintoma seria um registro
    // vazio com a flag ligada — que é como um lote inteiro se perde.
    if argumentos.registro_da_biblioteca {
        let ligou = quall_core::transport::ativar_registro_da_biblioteca(
            quall_core::transport::NivelDeRegistro::Informacao,
            registro::linha_estatica,
        );
        registro::linha(format!(
            "registro da biblioteca: {}",
            if ligou {
                "LIGADO em Info (Send failed = descarte no socket de saída)"
            } else {
                "NÃO ligou — já havia registrador instalado neste processo"
            }
        ));
    }

    // **Bancada: só o teleprompter.** `--teleprompter=prompter|controle` abre a janela dele
    // direto, sem a janela principal — sem o emissor, o receptor, a procura de vídeo e as câmeras
    // virtuais, que não são desta prova. É a mesma janela que o botão "Teleprompter" abre.
    if let Some(cfg) = argumentos.config_do_teleprompter() {
        registro::linha(format!(
            "quall-app: só o teleprompter ({:?}), sem a janela principal — pasta de dados {}",
            cfg.papel,
            quall_capture_probe::identidade::pasta_de_dados().display()
        ));
        let resultado = quall_capture_probe::teleprompter::correr(cfg);
        std::thread::sleep(Duration::from_millis(300));
        registro::linha("quall-app encerrou");
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
        return resultado;
    }

    let sair_apos = argumentos.sair_apos;
    let esquecer = argumentos.esquecer_pareamentos;
    // **`--espelhar-ja` e `--exibir-ja` juntos não fazem sentido, e o silêncio seria pior.** As
    // duas metades sobem sessões independentes e a interface só oferece uma por vez; disparadas em
    // laço pelo modo de bancada elas correriam uma contra a outra, e a corrida sairia com números
    // de duas sessões misturados. Emitir ganha, e o registro diz que ganhou.
    let auto_exibir = argumentos.exibir_ja.is_some() && !argumentos.espelhar_ja;
    let os_dois_automaticos = argumentos.exibir_ja.is_some() && argumentos.espelhar_ja;
    // **Dois papéis, dois estados, duas threads de sessão — e um `pares.json` só.** O app pode
    // emitir *ou* exibir, nunca os dois ao mesmo tempo: cada um sobe a própria sessão e a interface
    // só oferece um deles por vez. O que eles compartilham é a identidade deste computador
    // (`identidade.rs`), que é a mesma nos dois papéis e não podia ser outra.
    let receptor = Receptor::novo(argumentos.clone());
    let emissor = Emissor::novo(argumentos);

    // **As câmeras virtuais sobem antes da janela, não com a sessão.** Quem abre o Zoom procura a
    // câmera na lista antes de mexer no celular; uma câmera que só existisse durante a sessão não
    // estaria lá na hora em que a pessoa procura. Ver `baias.rs`.
    // O `Vec` é segurado até o fim do `main`: é ele que mantém as câmeras vivas, porque a
    // vida delas é `MFVirtualCameraLifetime_Session` — largar o objeto é remover o nó.
    let cameras_virtuais = receptor.baias.abrir_conhecidas();

    // **Bancada.** A função que o botão "Esquecer pareamentos" chama, exercitada sem clique. É o
    // jeito de separar "o botão nunca foi clicado" de "a função por trás dele nunca rodou" — a
    // segunda é a que pode estar quebrada em silêncio, e é a que dá para provar sem um humano.
    if esquecer {
        let antes = emissor.estado().ha_pares_conhecidos;
        emissor.esquecer_pares();
        let depois = emissor.estado().ha_pares_conhecidos;
        registro::linha(format!(
            "esquecer pareamentos (bancada): ha_pares_conhecidos {antes} -> {depois}"
        ));
    }

    // **Bancada.** Prazo contado do começo do processo, não do começo da transmissão: numa corrida
    // em que ninguém conecta, um prazo contado da transmissão nunca chega e a Tarefa Agendada
    // morre no teto dela — que mata o processo por fora e não prova desligamento nenhum.
    if let Some(segundos) = sair_apos {
        let eu = std::sync::Arc::clone(&emissor);
        let ele = std::sync::Arc::clone(&receptor);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(segundos));
            // O prazo vale para os dois papéis, e encerra pelo mesmo caminho do Cancelar humano em
            // cada um. Só um deles estará de pé; o outro recusa sozinho.
            ele.encerrar();
            eu.pedir_saida();
        });
    }

    // O clique em Espelhar que um agente de bancada não tem como dar. Depois da janela existir —
    // e por isso adiado — porque o desenho é "abrir o app, escolher, espelhar" e uma corrida que
    // pula a janela provaria um caminho que a pessoa nunca percorre.
    {
        let eu = std::sync::Arc::clone(&emissor);
        let repetir = eu.argumentos.repetir_espelhar;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(600));
            eu.talvez_espelhar_sozinho();
            // **Bancada.** A segunda sessão sem reiniciar o processo. `talvez_espelhar_sozinho`
            // recusa sozinho quando a fase não é `Inicial`, então este laço só age quando a sessão
            // anterior de fato terminou e a tela voltou ao começo.
            while repetir {
                std::thread::sleep(Duration::from_millis(500));
                eu.talvez_espelhar_sozinho();
            }
        });
    }

    // **Bancada.** O clique em "Exibir" que um agente não tem como dar. Mesma forma do de
    // Espelhar, e pelo mesmo motivo: uma corrida que pula a janela provaria um caminho que a
    // pessoa nunca percorre.
    if os_dois_automaticos {
        registro::linha(
            "ERRO de uso: --espelhar-ja e --exibir-ja foram dados juntos. Só o de espelhar vai \
             valer — as duas metades sobem sessões independentes e correriam uma contra a outra.",
        );
    }
    if auto_exibir {
        let eu = std::sync::Arc::clone(&receptor);
        let repetir = eu.argumentos.repetir_exibir;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(600));
            eu.talvez_exibir_sozinho();
            while repetir {
                std::thread::sleep(Duration::from_millis(500));
                eu.talvez_exibir_sozinho();
            }
        });
    }

    let resultado = janela::correr(
        std::sync::Arc::clone(&emissor),
        std::sync::Arc::clone(&receptor),
        // A janela passa a segurar as câmeras: é a thread dela que cria as que faltarem, e largar
        // o objeto remove o nó.
        cameras_virtuais,
    );

    // Um cartão do teleprompter em curso termina antes: ele não abre mais nada depois disto, e a
    // janela que ele acabou de abrir entra no fecho de baixo.
    if !janela::esperar_o_cartao(Duration::from_secs(4)) {
        registro::linha("teleprompter: !! o cartão em curso não terminou em 4 s; o processo sai assim mesmo");
    }
    // O teleprompter aberto pelo botão tem thread própria: ele fecha pelo caminho do Fechar (a
    // sessão cai pela ordem do fim, a réplica é gravada) antes de o processo sair.
    if !quall_capture_probe::teleprompter::fechar_se_aberta(Duration::from_secs(6)) {
        registro::linha("teleprompter: !! a janela não fechou em 6 s; o processo sai assim mesmo");
    }

    // Fechar a janela encerra a sessão; esperar aqui é o que dá tempo de o `Bye` sair e de o
    // registro final ser escrito antes de o processo morrer.
    emissor.encerrar();
    // **A câmera comum pelo dono** fecha a gravação inteira antes do `MFShutdown` (o `Finalize` do
    // arquivo; `docs/teleprompter-com-camera.md` §8.10.3).
    // Os prazos internos somam 26 s (a gravação 15, o vídeo 6, a câmera 5).
    if !emissor.esperar_a_camera_comum(Duration::from_secs(30)) {
        registro::linha("câmera comum: !! não fechou em 30 s; o processo sai assim mesmo (a gravação fica como órfã)");
    }
    receptor.encerrar();
    receptor.busca.parar();
    // **Com várias sessões, a espera fixa não basta**: são até oito desmontes (encoders, oficinas,
    // links) e o adeus do mDNS, e um `MFShutdown` com MFT vivo ou uma saída antes do `Bye` é o que
    // a espera existe para evitar (revisão adversarial de 13/09/2026). Espera todas avisarem, com
    // prazo; se o prazo vencer, sai assim mesmo — e sem `cleanup` da libdatachannel, que apagaria
    // ids de uma thread ainda viva. Sem a bandeira, volta na hora — a menos que uma tela estendida
    // tenha posto o coordenador de pé neste processo (R10, 02/10).
    if emissor.com_varias_sessoes() || emissor.coordenador_de_pe() {
        let completo = emissor.esperar_desmonte(Duration::from_secs(12));
        registro::linha(format!(
            "várias sessões: desmonte {} antes da saída",
            if completo { "completo" } else { "INCOMPLETO em 12 s" }
        ));
        // O monitor virtual: o que sobrou (uma sessão presa, um monitor que não confirmou) sai aqui,
        // antes do `MFShutdown` — o ping global o manteria de pé enquanto o processo vivesse.
        #[cfg(feature = "tela-estendida-futura")]
        {
            let n = quall_capture_probe::monitores_virtuais::encerrar_tudo(Duration::from_secs(8));
            if n > 0 { registro::linha(format!("monitor virtual: {n} monitor(es) soltos na saída")); }
        }
    }
    std::thread::sleep(Duration::from_millis(700));
    // A câmera solta o leitor e a fonte fora da sessão (o R4, M51): o `MFShutdown` espera por elas o
    // tempo que for preciso, até 30 s, e sai sem ele se alguma sobrar (a revisão do código da fase 4,
    // m2: com a DLL de 09/09 a soltura leva ~20 s).
    let pode_desligar = quall_capture_probe::captura_de_camera::esperar_solturas_na_saida(Duration::from_secs(30));
    registro::linha("quall-app encerrou");

    if pode_desligar {
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
    }
    resultado
}
