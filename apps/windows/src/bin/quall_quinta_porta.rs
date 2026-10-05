//! `quall-quinta-porta` — **instrumento de bancada**, não produto.
//!
//! Mede a quinta porta do controle de IDR no MFT de Quick Sync: **derrubar o transform do encoder
//! e montar outro no meio da sessão**. As quatro anteriores foram todas de configuração e todas
//! fecharam (`encoder.rs`, bloco do achado 7). Esta não pede nada ao driver.
//!
//! # Por que uma sonda própria, e não só a flag no `quall-app`
//!
//! A flag existe também (`--idr-por-recriacao`) e é o que prova a porta **ponta a ponta**, com um
//! receptor real do outro lado. Mas ela só age quando um receptor pede quadro-chave, e um receptor
//! pede pouco: a sessão de 28/08 pediu 17 vezes em três minutos. As perguntas que decidem se a
//! porta vive — *quanto custa em milissegundos*, *o conjunto de parâmetros muda*, *aguenta 20
//! repetições sem vazar* — precisam de repetição controlada, e não de esperar a rede colaborar.
//!
//! Esta sonda faz exatamente isso: sobe a mesma `Cadeia` do produto, recria o encoder num ritmo
//! fixo, e conta.
//!
//! # A regra de privacidade, e como ela é obedecida aqui
//!
//! A fonte é a tela de trabalho do usuário do Dell. Esta sonda **não tem caminho para arquivo de
//! vídeo e não existe opção para criar um** — a mesma decisão de `transmissao.rs`, pelo mesmo
//! motivo. Os quadros que saem da `Cadeia` são contados e largados na mesma volta do laço. O único
//! blob que chega ao registro é o conjunto de parâmetros (SPS+PPS), que descreve o formato do
//! fluxo e não contém amostra de imagem nenhuma.
//!
//! # Uso
//!
//!     quall-quinta-porta --segundos 90 --a-cada 4 --registro C:\Users\pessoa-exemplo\quinta-porta.log
//!
//! Precisa da **sessão interativa**: `Windows.Graphics.Capture` devolve `0x80070424` na Sessão 0,
//! que é onde o SSH cai (`docs/windows-acesso.md`). Vai por Tarefa Agendada, como todo o resto.

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use quall_capture_probe::{fontes, registro, transmissao::Cadeia};

use clap::Parser;
use windows::Win32::Media::MediaFoundation::{MFStartup, MFShutdown, MFSTARTUP_FULL, MF_VERSION};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessHandleCount};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};

#[derive(Parser, Debug)]
#[command(about = "Bancada: mede a quinta porta do IDR — recriar a sessão do encoder.")]
struct Argumentos {
    /// Quanto tempo medir, no total.
    #[arg(long, default_value_t = 90)]
    segundos: u64,

    /// Recriar o encoder a cada N segundos. 0 desliga a recriação — é o braço de controle, o mesmo
    /// executável sem a variável, que é o que separa "a porta faz isso" de "a cadeia faz isso".
    #[arg(long, default_value_t = 4)]
    a_cada: u64,

    /// Teto de recriações. A pergunta 4 da frente é sobre repetição: 20 é o número que ela pede.
    #[arg(long, default_value_t = 20)]
    recriacoes: u64,

    #[arg(long, default_value_t = 30)]
    fps: u32,

    /// Nome do monitor (`\\.\DISPLAY1` ou o nome amigável). Vazio = o primário.
    #[arg(long, default_value = "")]
    fonte: String,

    #[arg(long)]
    registro: Option<PathBuf>,
}

fn handles() -> u32 {
    let mut n = 0u32;
    unsafe {
        let _ = GetProcessHandleCount(GetCurrentProcess(), &mut n);
    }
    n
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    quall_capture_probe::diagnostico_cli::concluir(rodar());
}

fn rodar() -> windows::core::Result<()> {
    let a = quall_capture_probe::diagnostico_cli::interpretar::<Argumentos>();

    let dpi_ok = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
        .is_ok();
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
    }

    let caminho = registro::abrir(a.registro.as_deref());
    registro::linha(format!(
        "quall-quinta-porta iniciou — dpi_por_monitor={dpi_ok} registro={} segundos={} \
         a_cada={}s teto_de_recriacoes={} fps={}",
        caminho.map(|c| c.display().to_string()).unwrap_or_else(|| "(só stderr)".into()),
        a.segundos,
        a.a_cada,
        a.recriacoes,
        a.fps,
    ));

    let monitores = fontes::monitores();
    let fonte = match monitores.iter().find(|f| {
        a.fonte.is_empty() && f.primario || (!a.fonte.is_empty() && (f.id == a.fonte || f.nome == a.fonte))
    }) {
        Some(f) => f.clone(),
        None => {
            registro::linha(format!("nenhum monitor casou com \"{}\"; nada a medir", a.fonte));
            return Ok(());
        }
    };
    let Some(hmonitor) = fontes::achar_hmonitor(&fonte.id) else {
        registro::linha(format!("o monitor {} sumiu entre a escolha e a captura", fonte.id));
        return Ok(());
    };

    let origem = Instant::now();
    // `None` na porta de taxa de entrega: esta sonda mede o custo de recriar o encoder, e uma
    // porta no caminho do quadro mudaria o que ela cronometra.
    // Piso 0 e bitrate **cravado nos 4 Mbps históricos**: esta sonda mede o custo de recriar o
    // encoder, e as duas coisas que ela não pode mudar são quantas recriações acontecem e o que o
    // encoder foi mandado produzir. Desde 02/09/2026 o padrão do produto vem do teto de resolução
    // (1080p30 pede 9 Mbps); deixar `None` aqui trocaria o número no meio da série histórica que
    // esta sonda existe para continuar.
    let mut cadeia = Cadeia::abrir(
        // O último `false` é a troca a quente: esta sonda mede a recriação **do jeito
        // antigo**, que é o que ela sempre mediu. Comparar as duas é trabalho do
        // `quall-app`, com receptor de verdade do outro lado.
        &fonte, hmonitor, a.fps, origem, false, false, None, 0, Some(4_000_000), false, false,
    )?;
    registro::linha(format!(
        "cadeia aberta: {}x{} encoder=\"{}\" hardware={} adaptador={} | handles={}",
        cadeia.largura,
        cadeia.altura,
        cadeia.nome_do_encoder,
        cadeia.encoder_e_hardware,
        cadeia.adaptador,
        handles(),
    ));

    let fim = Instant::now() + Duration::from_secs(a.segundos);
    let mut proxima_recriacao = Instant::now() + Duration::from_secs(a.a_cada.max(1));
    let mut ultimo_relato = Instant::now();
    // Contados aqui e não na `Cadeia`: o que interessa nesta sonda é **quantos bytes o produto
    // teria mandado**, não os bytes. Eles são somados e o `Vec` morre nesta mesma volta.
    let mut quadros: u64 = 0;
    let mut bytes: u64 = 0;
    let mut idrs: u64 = 0;
    let mut handles_por_recriacao: Vec<u32> = vec![handles()];

    while Instant::now() < fim {
        for quadro in cadeia.bombear(Duration::from_millis(20)) {
            quadros += 1;
            bytes += quadro.bytes.len() as u64;
            if quadro.idr {
                idrs += 1;
            }
            // O quadro morre aqui. Não há para onde mandá-lo, e é de propósito.
        }

        if a.a_cada > 0
            && cadeia.recriacoes() < a.recriacoes
            && Instant::now() >= proxima_recriacao
        {
            proxima_recriacao = Instant::now() + Duration::from_secs(a.a_cada);
            if let Err(e) = cadeia.recriar_encoder() {
                registro::linha(format!("a recriação falhou: {e} — encerrando a medição"));
                break;
            }
            handles_por_recriacao.push(handles());
        }

        if ultimo_relato.elapsed() >= Duration::from_secs(5) {
            ultimo_relato = Instant::now();
            let c = cadeia.contadores;
            let decorrido = origem.elapsed().as_secs_f64().max(0.001);
            registro::linha(format!(
                "t={decorrido:.1}s | capturados={} encodados={} idrs={} quadros={quadros} \
                 bytes={bytes} | fps_capturado={:.1} fps_encodado={:.1} | handles={} | {}",
                c.capturados,
                c.encodados,
                c.idrs,
                c.capturados as f64 / decorrido,
                c.encodados as f64 / decorrido,
                handles(),
                cadeia.perfil().linha(),
            ));
        }
    }

    cadeia.fechar();
    let c = cadeia.contadores;
    let decorrido = origem.elapsed().as_secs_f64().max(0.001);
    registro::linha(format!(
        "FIM {decorrido:.1}s | capturados={} encodados={} idrs={} quadros_para_a_track={quadros} \
         bytes={bytes} idrs_na_saida={idrs} recusados={} parametros_injetados={} \
         saidas_so_de_parametros={}",
        c.capturados,
        c.encodados,
        c.idrs,
        c.recusados_pelo_encoder,
        c.parametros_injetados,
        c.saidas_so_de_parametros,
    ));
    registro::linha(format!(
        "FIM fps: capturado={:.2} encodado={:.2} (pedido {})",
        c.capturados as f64 / decorrido,
        c.encodados as f64 / decorrido,
        a.fps
    ));
    registro::linha(format!("FIM {}", cadeia.linha_dos_degraus()));
    registro::linha(format!("FIM idr no fluxo: {}", cadeia.medida_de_idr()));
    registro::linha(format!("FIM quinta porta: {}", cadeia.relato_de_recriacao()));
    registro::linha(format!(
        "FIM controle de taxa:\n{}",
        cadeia.medida_do_controle_de_taxa()
    ));
    registro::linha(format!("FIM perfil do laço: {}", cadeia.perfil().linha()));
    registro::linha(format!("FIM handles por recriação: {handles_por_recriacao:?}"));
    match cadeia.resumo_sps() {
        Some(r) => registro::linha(format!("FIM sps: {}", r.linha())),
        None => registro::linha("FIM sps: nenhum SPS foi visto"),
    }

    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    Ok(())
}
