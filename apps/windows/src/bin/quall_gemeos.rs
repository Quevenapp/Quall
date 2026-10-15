//! `quall-gemeos` — **instrumento de bancada**, não produto.
//!
//! Responde a pergunta que decide a forma da tarefa da troca a quente: **dois MFTs de encode em
//! hardware podem estar vivos ao mesmo tempo no mesmo dispositivo D3D11?**
//!
//! `transmissao::Cadeia::recriar_encoder` escreve, hoje, que a ordem "derruba o velho antes de
//! montar o novo" é deliberada porque *"dois MFTs de hardware vivos ao mesmo tempo no mesmo
//! adaptador é estado que esta bancada nunca mediu"*. Esta sonda mede.
//!
//! # Por que ela não captura tela
//!
//! Duas razões, e as duas valem mais que a conveniência:
//!
//! 1. **Privacidade.** A tela do Dell é a máquina de trabalho do usuário. A origem aqui é uma
//!    textura BGRA preenchida por `ClearRenderTargetView` com uma cor que varia — nada que exista
//!    fora deste processo. Nenhum quadro é gravado, aberto ou renderizado: só contados.
//! 2. **Sessão.** Sem `Windows.Graphics.Capture` a sonda **roda na Sessão 0**, que é onde o SSH
//!    cai (`docs/windows-acesso.md`). Uma pergunta sobre o MFT não precisa de Tarefa Agendada, e
//!    tirar a tarefa do caminho tira junto a classe de erro mais chata desta bancada.
//!
//! O preço, e ele está escrito no relatório: uma textura de cor chapada comprime muito melhor que
//! tela de verdade, então **nenhum número de bitrate ou de tamanho de quadro daqui vale para o
//! produto**. O que vale são os números de *mecanismo*: ativa ou não ativa, quantos handles, e
//! quantos milissegundos cada passo da montagem custa.
//!
//! # Uso
//!
//!     quall-gemeos --quadros 60 --trocas 20

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::time::{Duration, Instant};

use quall_capture_probe::encoder::{ChosenEncoder, EncoderConfig, MftEvent, Preferencia};
use quall_capture_probe::{device, encoder};

use clap::Parser;
use crossbeam_channel::Receiver;
use windows::core::{Interface, Result};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11RenderTargetView, ID3D11Texture2D, D3D11_BIND_RENDER_TARGET,
    D3D11_BIND_SHADER_RESOURCE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Media::MediaFoundation::{
    IMFDXGIDeviceManager, MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION,
};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessHandleCount};

#[derive(Parser, Debug)]
#[command(about = "Bancada: dois MFTs de encode vivos ao mesmo tempo no mesmo dispositivo D3D11.")]
struct Argumentos {
    /// Quantos quadros empurrar em cada fase de alimentação.
    #[arg(long, default_value_t = 60)]
    quadros: u64,

    /// Quantas trocas a quente medir na fase de repetição — é a fase que responde se o encoder de
    /// reserva **dobra** o vazamento de handles em vez de resolvê-lo.
    #[arg(long, default_value_t = 20)]
    trocas: u64,

    /// Quantas recriações do jeito de hoje (derrubar e montar) medir, para decompor os ~150 ms.
    #[arg(long, default_value_t = 10)]
    recriacoes: u64,

    #[arg(long, default_value_t = 1280)]
    largura: u32,

    #[arg(long, default_value_t = 720)]
    altura: u32,

    #[arg(long, default_value_t = 30)]
    fps: u32,

    #[arg(long, default_value_t = 4_000_000)]
    bitrate: u32,

    /// `intel` força o Quick Sync — que é o que o `quall-app` usa **na sessão interativa**, porque
    /// lá o `ActivateObject` da NVIDIA falha. Na Sessão 0 (o SSH) ele funciona, e sem esta opção
    /// esta sonda mede a NVENC enquanto o produto roda no Quick Sync. `produto` é a ordem do app.
    #[arg(long, default_value = "intel")]
    preferir: String,
}

/// **O censo de handles por tipo — a pergunta que ninguém tinha instrumento para responder.**
///
/// `ShutdownObject` derrubou o vazamento de +13 para +3,05 handles por recriação e ninguém achou
/// o resto. A frente da quinta porta descartou por medida as duas hipóteses gordas — threads
/// (29–32 estáveis enquanto os handles iam a 4.033) e memória (127 → 86 MB) — e escreveu que
/// *nomear o tipo do handle exige enumerar handles por tipo, e nenhuma ferramenta desta bancada
/// faz isso*.
///
/// Faz agora, e sem ferramenta de fora. O truque é que **os handles são nossos**: para os
/// próprios handles do processo não é preciso `SystemHandleInformation` nem duplicar nada —
/// basta varrer os valores possíveis (handles do Windows são múltiplos de 4) e perguntar o tipo
/// de cada um com `NtQueryObject(ObjectTypeInformation)`. Handle inválido devolve
/// `STATUS_INVALID_HANDLE` e sai da conta.
///
/// `ObjectTypeInformation` de propósito, e **não** `ObjectNameInformation`: a segunda pode
/// bloquear indefinidamente em handle de pipe com E/S pendente, que é a armadilha clássica desta
/// técnica. O tipo nunca bloqueia.
mod censo {
    use std::collections::BTreeMap;

    #[link(name = "ntdll")]
    extern "system" {
        fn NtQueryObject(
            handle: isize,
            classe: i32,
            informacao: *mut u8,
            tamanho: u32,
            devolvido: *mut u32,
        ) -> i32;
    }

    const OBJECT_TYPE_INFORMATION: i32 = 2;

    #[repr(C)]
    struct Alinhado([u64; 512]);

    /// Conta os handles vivos deste processo, por nome de tipo.
    ///
    /// O teto de varredura é generoso de propósito: uma sessão com 4.000 handles pode ter valores
    /// bem acima de 4.000×4, porque o gerenciador reaproveita e espalha. 256 Ki cobre com folga e
    /// custa uma chamada barata por valor.
    pub fn por_tipo() -> BTreeMap<String, u32> {
        let mut mapa: BTreeMap<String, u32> = BTreeMap::new();
        let mut buffer = Alinhado([0u64; 512]);
        let bytes = unsafe {
            std::slice::from_raw_parts_mut(buffer.0.as_mut_ptr() as *mut u8, 512 * 8)
        };
        let mut h: isize = 4;
        while h <= 0x40000 {
            let mut devolvido = 0u32;
            let st = unsafe {
                NtQueryObject(h, OBJECT_TYPE_INFORMATION, bytes.as_mut_ptr(), bytes.len() as u32, &mut devolvido)
            };
            if st >= 0 {
                // Os primeiros bytes são um `UNICODE_STRING { Length, MaximumLength, Buffer }`.
                let tam = u16::from_ne_bytes([bytes[0], bytes[1]]) as usize;
                let ptr = usize::from_ne_bytes(bytes[8..16].try_into().unwrap()) as *const u16;
                if tam > 0 && !ptr.is_null() {
                    let s = unsafe { std::slice::from_raw_parts(ptr, tam / 2) };
                    *mapa.entry(String::from_utf16_lossy(s)).or_insert(0) += 1;
                }
            }
            h += 4;
        }
        mapa
    }

    /// Imprime a diferença entre dois censos, do que mais cresceu para o que menos cresceu.
    pub fn diferenca(rotulo: &str, antes: &BTreeMap<String, u32>, depois: &BTreeMap<String, u32>, por: u64) {
        let mut linhas: Vec<(i64, String, u32, u32)> = Vec::new();
        let mut chaves: Vec<&String> = antes.keys().chain(depois.keys()).collect();
        chaves.sort();
        chaves.dedup();
        for k in chaves {
            let a = *antes.get(k).unwrap_or(&0);
            let d = *depois.get(k).unwrap_or(&0);
            if a != d {
                linhas.push((d as i64 - a as i64, k.clone(), a, d));
            }
        }
        linhas.sort_by_key(|(delta, _, _, _)| -delta);
        println!("  censo de handles — {rotulo} ({por} repetições):");
        if linhas.is_empty() {
            println!("    nada mudou de tipo nenhum");
        }
        for (delta, nome, a, d) in linhas {
            let porrep = if por > 0 { delta as f64 / por as f64 } else { 0.0 };
            println!("    {nome:<24} {a:>6} → {d:>6}   {delta:+6}   {porrep:+.2} por repetição");
        }
        let ta: u32 = antes.values().sum();
        let td: u32 = depois.values().sum();
        println!(
            "    {:<24} {ta:>6} → {td:>6}   {:+6}   {:+.2} por repetição",
            "TOTAL",
            td as i64 - ta as i64,
            if por > 0 { (td as i64 - ta as i64) as f64 / por as f64 } else { 0.0 }
        );
    }
}

fn handles() -> u32 {
    let mut n = 0u32;
    unsafe {
        let _ = GetProcessHandleCount(GetCurrentProcess(), &mut n);
    }
    n
}

fn memoria_mb() -> f64 {
    let mut c = PROCESS_MEMORY_COUNTERS::default();
    let tam = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
    unsafe {
        if GetProcessMemoryInfo(GetCurrentProcess(), &mut c, tam).is_err() {
            return 0.0;
        }
    }
    c.WorkingSetSize as f64 / (1024.0 * 1024.0)
}

/// Uma origem de quadros que **não é a tela**: uma textura BGRA que muda de cor a cada chamada.
struct Origem {
    dispositivo: ID3D11Device,
    texturas: Vec<(ID3D11Texture2D, ID3D11RenderTargetView)>,
    n: usize,
}

impl Origem {
    fn nova(dispositivo: &ID3D11Device, largura: u32, altura: u32, quantas: usize) -> Result<Self> {
        // As mesmas bandeiras que `escala.rs` usa na textura que ele entrega ao MFT:
        // `RENDER_TARGET` para poder ser alvo de `ClearRenderTargetView`, `SHADER_RESOURCE` para
        // o MFT poder consumi-la como superfície DXGI.
        let desc = D3D11_TEXTURE2D_DESC {
            Width: largura,
            Height: altura,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut texturas = Vec::new();
        for _ in 0..quantas {
            let mut t: Option<ID3D11Texture2D> = None;
            unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t))? };
            let t = t.expect("CreateTexture2D não devolveu textura");
            let mut v: Option<ID3D11RenderTargetView> = None;
            unsafe { dispositivo.CreateRenderTargetView(&t, None, Some(&mut v))? };
            let v = v.expect("CreateRenderTargetView não devolveu vista");
            texturas.push((t, v));
        }
        Ok(Origem { dispositivo: dispositivo.clone(), texturas, n: 0 })
    }

    /// Devolve a próxima textura, já pintada com uma cor diferente da anterior.
    ///
    /// Um anel de texturas, e não uma só: o MFT segura a textura submetida até terminar de
    /// codificá-la, e repintar a mesma textura na volta seguinte mudaria por baixo dele o quadro
    /// que ele ainda está lendo.
    fn proxima(&mut self) -> ID3D11Texture2D {
        let i = self.n % self.texturas.len();
        self.n += 1;
        let f = (self.n % 60) as f32 / 60.0;
        let cor = [f, 1.0 - f, (f * 2.0) % 1.0, 1.0f32];
        unsafe {
            let ctx = self.dispositivo.GetImmediateContext().expect("contexto imediato");
            ctx.ClearRenderTargetView(&self.texturas[i].1, &cor);
        }
        self.texturas[i].0.clone()
    }
}

/// Um encoder vivo, com o bombeador de eventos e a contabilidade de créditos — o mínimo da
/// `Cadeia` que esta pergunta precisa, sem captura, sem escala e sem track.
struct Motor {
    enc: ChosenEncoder,
    eventos: Receiver<MftEvent>,
    creditos: u32,
    entrada: u64,
    saida: u64,
    idrs: u64,
    bytes: u64,
    rotulo: String,
}

/// Onde os milissegundos da montagem vão. É a decomposição que decide **o que** vale tirar do
/// caminho crítico: se o custo estiver quase todo em `desligar`, a troca a quente é exagero — dá
/// para adiar só o desligamento.
#[derive(Default, Clone, Copy)]
struct Passos {
    desligar_us: u64,
    ativar_us: u64,
    configurar_us: u64,
    espacamento_us: u64,
    abrir_fluxo_us: u64,
    bombeador_us: u64,
}

impl Passos {
    fn total_us(&self) -> u64 {
        self.desligar_us
            + self.ativar_us
            + self.configurar_us
            + self.espacamento_us
            + self.abrir_fluxo_us
            + self.bombeador_us
    }
    fn linha(&self) -> String {
        format!(
            "desligar={:.1} ativar={:.1} configurar={:.1} espaçamento={:.1} abrir={:.1} bombeador={:.1} → {:.1} ms",
            self.desligar_us as f64 / 1000.0,
            self.ativar_us as f64 / 1000.0,
            self.configurar_us as f64 / 1000.0,
            self.espacamento_us as f64 / 1000.0,
            self.abrir_fluxo_us as f64 / 1000.0,
            self.bombeador_us as f64 / 1000.0,
            self.total_us() as f64 / 1000.0
        )
    }
}

impl Motor {
    /// Monta um motor **reativando um `IMFActivate` já conhecido** — o caminho da quinta porta.
    fn reativando(
        base: &ChosenEncoder,
        gerenciador: &IMFDXGIDeviceManager,
        cfg: &EncoderConfig,
        rotulo: &str,
    ) -> Result<(Self, Passos)> {
        let mut p = Passos::default();
        let t = Instant::now();
        let enc = encoder::reativar(base)?;
        p.ativar_us = t.elapsed().as_micros() as u64;
        Self::acabar(enc, gerenciador, cfg, rotulo, p)
    }

    /// Monta um motor a partir de uma **enumeração nova** — `IMFActivate` novo em folha.
    fn enumerando(
        pref: Preferencia,
        gerenciador: &IMFDXGIDeviceManager,
        cfg: &EncoderConfig,
        rotulo: &str,
    ) -> Result<(Self, Passos)> {
        let mut p = Passos::default();
        let t = Instant::now();
        let enc = encoder::ativar_h264(pref)?;
        p.ativar_us = t.elapsed().as_micros() as u64;
        Self::acabar(enc, gerenciador, cfg, rotulo, p)
    }

    fn acabar(
        enc: ChosenEncoder,
        gerenciador: &IMFDXGIDeviceManager,
        cfg: &EncoderConfig,
        rotulo: &str,
        mut p: Passos,
    ) -> Result<(Self, Passos)> {
        let t = Instant::now();
        encoder::configure(&enc, gerenciador, cfg)?;
        p.configurar_us = t.elapsed().as_micros() as u64;

        let t = Instant::now();
        let _ = encoder::tentar_espacamento_de_idr(&enc, cfg.gop_frames);
        p.espacamento_us = t.elapsed().as_micros() as u64;

        let t = Instant::now();
        encoder::start_stream(&enc.transform)?;
        p.abrir_fluxo_us = t.elapsed().as_micros() as u64;

        let t = Instant::now();
        let eventos = encoder::spawn_event_pump(enc.events.clone());
        p.bombeador_us = t.elapsed().as_micros() as u64;

        Ok((
            Motor {
                enc,
                eventos,
                creditos: 0,
                entrada: 0,
                saida: 0,
                idrs: 0,
                bytes: 0,
                rotulo: rotulo.to_string(),
            },
            p,
        ))
    }

    fn ponteiro(&self) -> usize {
        self.enc.transform.as_raw() as usize
    }

    /// Drena os eventos que já chegaram, sem esperar.
    fn drenar_eventos(&mut self) {
        while let Ok(ev) = self.eventos.try_recv() {
            match ev {
                MftEvent::NeedInput => self.creditos += 1,
                MftEvent::HaveOutput => self.colher(),
                _ => {}
            }
        }
    }

    fn colher(&mut self) {
        if let Ok(quadros) = encoder::drain_output(&self.enc.transform, encoder::OUTPUT_STREAM_ID) {
            for q in quadros {
                self.saida += 1;
                self.bytes += q.bytes.len() as u64;
                if q.is_idr {
                    self.idrs += 1;
                }
            }
        }
    }

    /// Espera um crédito e submete um quadro. Devolve `false` se o crédito não veio no prazo.
    fn empurrar(&mut self, textura: &ID3D11Texture2D, t_100ns: i64, dur_100ns: i64) -> bool {
        let prazo = Instant::now() + Duration::from_millis(500);
        while self.creditos == 0 && Instant::now() < prazo {
            match self.eventos.recv_timeout(Duration::from_millis(20)) {
                Ok(MftEvent::NeedInput) => self.creditos += 1,
                Ok(MftEvent::HaveOutput) => self.colher(),
                Ok(_) => {}
                Err(_) => {}
            }
        }
        if self.creditos == 0 {
            println!("  [{}] crédito não veio em 500 ms", self.rotulo);
            return false;
        }
        let amostra = match encoder::sample_from_texture(textura, 0, t_100ns, dur_100ns) {
            Ok(a) => a,
            Err(e) => {
                println!("  [{}] sample_from_texture falhou: {e}", self.rotulo);
                return false;
            }
        };
        match unsafe { self.enc.transform.ProcessInput(0, &amostra, 0) } {
            Ok(()) => {
                self.creditos -= 1;
                self.entrada += 1;
                self.drenar_eventos();
                true
            }
            Err(e) => {
                println!("  [{}] ProcessInput recusou: {e}", self.rotulo);
                false
            }
        }
    }

    fn linha(&self) -> String {
        format!(
            "{}: entrada={} saída={} idrs={} bytes={} (média {} B/quadro)",
            self.rotulo,
            self.entrada,
            self.saida,
            self.idrs,
            self.bytes,
            if self.saida > 0 { self.bytes / self.saida } else { 0 }
        )
    }
}

fn media(v: &[u64]) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.iter().sum::<u64>() as f64 / v.len() as f64
}

fn mediana(v: &mut Vec<u64>) -> u64 {
    if v.is_empty() {
        return 0;
    }
    v.sort_unstable();
    v[v.len() / 2]
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    quall_capture_probe::diagnostico_cli::concluir(rodar());
}

fn rodar() -> Result<()> {
    let a = quall_capture_probe::diagnostico_cli::interpretar::<Argumentos>();
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
    }

    println!("== quall-gemeos ==");
    println!(
        "origem: textura BGRA {}x{} pintada por ClearRenderTargetView — NÃO é a tela",
        a.largura, a.altura
    );

    // O encoder primeiro, o dispositivo depois: é a ordem obrigatória que `Cadeia::abrir`
    // documenta — um MFT de hardware só aceita `SET_D3D_MANAGER` de um dispositivo do mesmo
    // adaptador que ele.
    let pref = match a.preferir.as_str() {
        "intel" => Preferencia::Intel,
        "produto" => Preferencia::Produto,
        outro => {
            println!("--preferir só aceita 'intel' ou 'produto'; valor recebido omitido");
            return Ok(());
        }
    };
    println!("preferência de MFT: {pref:?}");
    let sonda = encoder::ativar_h264(pref)?;
    println!("encoder: \"{}\" hardware={}", sonda.friendly_name, sonda.is_hardware);
    let vendor = if sonda.friendly_name.to_uppercase().contains("NVIDIA") {
        device::VENDOR_NVIDIA
    } else {
        device::VENDOR_INTEL
    };
    let adaptador = device::create_device(vendor)?;
    println!("adaptador: {} (0x{:04X})", adaptador.description, adaptador.vendor_id);
    let gerenciador = encoder::create_device_manager(&adaptador.device)?;
    encoder::desligar(&sonda);
    drop(sonda);

    let cfg = EncoderConfig {
        entrada: quall_capture_probe::encoder::FormatoDeEntrada::Argb32,
        width: a.largura,
        height: a.altura,
        fps: a.fps,
        bitrate_bps: a.bitrate,
        gop_frames: a.fps,
        // Os botões de `docs/idr-pequeno.md` nascem desligados; ver `EncoderConfig`.
        intra_refresh_frames: 0,
        slice_bytes: 0,
        teto_de_quadro_bits: 0,
    };
    let dur_100ns = 10_000_000i64 / a.fps as i64;
    let mut origem = Origem::nova(&adaptador.device, a.largura, a.altura, 8)?;
    let mut relogio = 0i64;

    let h0 = handles();
    println!("linha de base: handles={h0} memória={:.1} MB", memoria_mb());

    // --- Fase 1: A sozinho -------------------------------------------------------------------
    println!("\n-- fase 1: motor A sozinho, {} quadros --", a.quadros);
    let (mut a_motor, passos_a) = Motor::enumerando(pref, &gerenciador, &cfg, "A")?;
    println!("  montagem de A: {}", passos_a.linha());
    for _ in 0..a.quadros {
        let t = origem.proxima();
        a_motor.empurrar(&t, relogio, dur_100ns);
        relogio += dur_100ns;
    }
    std::thread::sleep(Duration::from_millis(200));
    a_motor.drenar_eventos();
    println!("  {}", a_motor.linha());
    let h1 = handles();
    println!("  handles={h1} (+{}) memória={:.1} MB", h1 as i64 - h0 as i64, memoria_mb());

    // --- Fase 2: A PERGUNTA ------------------------------------------------------------------
    //
    // Duas perguntas empilhadas, e a ordem importa:
    //
    // 1. `IMFActivate::ActivateObject` chamado **de novo**, com o objeto anterior ainda vivo,
    //    devolve um transform NOVO ou o MESMO em cache? Se for o mesmo, a troca a quente não pode
    //    reusar o `IMFActivate` da quinta porta e precisa de dois.
    // 2. Dois transforms de hardware distintos podem coexistir no mesmo `IMFDXGIDeviceManager`?
    println!("\n-- fase 2: montar B com A VIVO (a pergunta que decide a tarefa) --");
    // **Só ativar, nunca configurar.** Se o `IMFActivate` devolver o objeto em cache, o que
    // estiver na mão é o *próprio A* — e `configure` sobre ele reconfiguraria o encoder vivo,
    // que é o que a primeira corrida desta sonda fez sem querer (o A passou a recusar todo
    // `ProcessInput` com `MF_E_NOTACCEPTING` pelo resto da corrida). Comparar ponteiro é
    // suficiente para responder, e não mexe em nada.
    println!("  2a) reativar o MESMO IMFActivate com o objeto anterior vivo (sem configurar):");
    match encoder::reativar(&a_motor.enc) {
        Ok(outro) => {
            let p = outro.transform.as_raw() as usize;
            if p == a_motor.ponteiro() {
                println!(
                    "      ActivateObject devolveu o MESMO transform em cache (0x{p:x}). \
                     Reusar um único IMFActivate NÃO serve para a troca a quente: são precisos dois."
                );
            } else {
                println!(
                    "      ActivateObject devolveu um transform NOVO (0x{p:x} contra 0x{:x}).",
                    a_motor.ponteiro()
                );
            }
            drop(outro);
        }
        Err(e) => println!("      falhou: {e} (código {:?})", e.code()),
    }

    println!("  2b) enumerar de novo (IMFActivate novo em folha) com A vivo:");
    let antes_de_b = Instant::now();
    let b = Motor::enumerando(pref, &gerenciador, &cfg, "B");
    let parede_de_b = antes_de_b.elapsed();
    let (mut b_motor, passos_b) = match b {
        Ok(x) => {
            println!("      RESPOSTA: SIM — dois MFTs de hardware coexistem no mesmo IMFDXGIDeviceManager.");
            x
        }
        Err(e) => {
            println!("      RESPOSTA: NÃO — montar B com A vivo falhou: {e} (código {:?})", e.code());
            println!("      A troca a quente muda de forma. Fim da corrida.");
            encoder::desligar(&a_motor.enc);
            unsafe {
                let _ = MFShutdown();
                CoUninitialize();
            }
            return Ok(());
        }
    };
    println!(
        "      transform de B = 0x{:x} (A = 0x{:x}) | montagem: {} | parede {:.1} ms",
        b_motor.ponteiro(),
        a_motor.ponteiro(),
        passos_b.linha(),
        parede_de_b.as_secs_f64() * 1000.0
    );
    let h2 = handles();
    println!(
        "      custo de um encoder de reserva ocioso: +{} handles, memória={:.1} MB",
        h2 as i64 - h1 as i64,
        memoria_mb()
    );

    // --- Fase 3: os dois produzindo ao mesmo tempo -------------------------------------------
    println!("\n-- fase 3: A e B alimentados ao mesmo tempo, {} quadros cada --", a.quadros);
    let saida_a_antes = a_motor.saida;
    for _ in 0..a.quadros {
        let t = origem.proxima();
        a_motor.empurrar(&t, relogio, dur_100ns);
        b_motor.empurrar(&t, relogio, dur_100ns);
        relogio += dur_100ns;
    }
    std::thread::sleep(Duration::from_millis(300));
    a_motor.drenar_eventos();
    b_motor.drenar_eventos();
    println!("  {}", a_motor.linha());
    println!("  {}", b_motor.linha());
    println!(
        "  A continuou produzindo com B vivo: {} quadros nesta fase",
        a_motor.saida - saida_a_antes
    );
    println!(
        "  B começou por IDR: {}",
        if b_motor.idrs > 0 { "sim" } else { "NÃO — isto derruba a ideia" }
    );

    // --- Fase 4: a troca por ponteiro ---------------------------------------------------------
    println!("\n-- fase 4: a troca por ponteiro, e o desligamento do aposentado --");
    let t = Instant::now();
    std::mem::swap(&mut a_motor, &mut b_motor);
    let troca_us = t.elapsed().as_micros();
    println!("  swap: {troca_us} µs");
    let t = Instant::now();
    let limpo = encoder::desligar(&b_motor.enc);
    let desligar_us = t.elapsed().as_micros() as u64;
    println!("  desligar do aposentado: {:.1} ms (limpo={limpo})", desligar_us as f64 / 1000.0);
    let mut atual = a_motor;
    drop(b_motor);

    // --- Fase 5: o custo de HOJE, decomposto -------------------------------------------------
    println!("\n-- fase 5: o custo de HOJE (derrubar e montar), {} repetições --", a.recriacoes);
    let censo_antes_da_5 = censo::por_tipo();
    let mut totais: Vec<u64> = Vec::new();
    let mut ds: Vec<u64> = Vec::new();
    let mut ats: Vec<u64> = Vec::new();
    let mut cfgs: Vec<u64> = Vec::new();
    let mut abrs: Vec<u64> = Vec::new();
    for i in 0..a.recriacoes {
        for _ in 0..5 {
            let t = origem.proxima();
            atual.empurrar(&t, relogio, dur_100ns);
            relogio += dur_100ns;
        }
        let comeco = Instant::now();
        let t = Instant::now();
        encoder::desligar(&atual.enc);
        let d = t.elapsed().as_micros() as u64;
        let (novo, mut p) = Motor::reativando(&atual.enc, &gerenciador, &cfg, "atual")?;
        p.desligar_us = d;
        let total = comeco.elapsed().as_micros() as u64;
        if i > 0 {
            totais.push(total);
            ds.push(p.desligar_us);
            ats.push(p.ativar_us);
            cfgs.push(p.configurar_us);
            abrs.push(p.abrir_fluxo_us + p.bombeador_us + p.espacamento_us);
        }
        atual = novo;
    }
    println!(
        "  mediana por passo: desligar={:.1} ativar={:.1} configurar={:.1} abrir+bombeador={:.1} → TOTAL {:.1} ms",
        mediana(&mut ds) as f64 / 1000.0,
        mediana(&mut ats) as f64 / 1000.0,
        mediana(&mut cfgs) as f64 / 1000.0,
        mediana(&mut abrs) as f64 / 1000.0,
        mediana(&mut totais) as f64 / 1000.0
    );
    println!("  média do total: {:.1} ms", media(&totais) / 1000.0);
    censo::diferenca(
        "recriação do jeito antigo",
        &censo_antes_da_5,
        &censo::por_tipo(),
        a.recriacoes,
    );

    // --- Fase 6: N trocas a quente, e o que elas fazem com os handles ------------------------
    //
    // O desenho de dois lugares: cada encoder nasce de um `IMFActivate` próprio, e eles se
    // alternam. Quando o aposentado é desligado, o `IMFActivate` dele fica livre para hospedar o
    // sucessor da troca seguinte — então duas vagas bastam e nunca é preciso reenumerar.
    println!("\n-- fase 6: {} trocas a quente (montar a reserva com o atual vivo) --", a.trocas);
    let (mut vaga_livre, _) = Motor::enumerando(pref, &gerenciador, &cfg, "vaga")?;
    encoder::desligar(&vaga_livre.enc);
    let h_antes = handles();
    let censo_antes_da_6 = censo::por_tipo();
    let mem_antes = memoria_mb();
    let mut custos_de_troca: Vec<u64> = Vec::new();
    let mut custos_de_montagem: Vec<u64> = Vec::new();
    let mut falhas = 0u64;
    for _ in 0..a.trocas {
        for _ in 0..5 {
            let t = origem.proxima();
            atual.empurrar(&t, relogio, dur_100ns);
            relogio += dur_100ns;
        }
        let t = Instant::now();
        // A reserva nasce na vaga livre, **com o atual ainda vivo e streaming**.
        let reserva = Motor::reativando(&vaga_livre.enc, &gerenciador, &cfg, "reserva");
        custos_de_montagem.push(t.elapsed().as_micros() as u64);
        match reserva {
            Ok((novo, _)) => {
                let t = Instant::now();
                let aposentado = std::mem::replace(&mut atual, novo);
                custos_de_troca.push(t.elapsed().as_micros() as u64);
                encoder::desligar(&aposentado.enc);
                // O aposentado vira a vaga livre da troca seguinte.
                vaga_livre = aposentado;
            }
            Err(e) => {
                falhas += 1;
                println!("  montagem da reserva falhou: {e}");
            }
        }
    }
    let h_depois = handles();
    println!(
        "  handles: {h_antes} → {h_depois} (+{} em {} trocas = {:.2} por troca)",
        h_depois as i64 - h_antes as i64,
        a.trocas,
        (h_depois as f64 - h_antes as f64) / a.trocas as f64
    );
    println!(
        "  mediana da montagem da reserva: {:.1} ms | mediana do swap: {} µs | falhas: {falhas}",
        mediana(&mut custos_de_montagem) as f64 / 1000.0,
        mediana(&mut custos_de_troca)
    );
    println!("  memória: {:.1} → {:.1} MB", mem_antes, memoria_mb());
    censo::diferenca("troca a quente", &censo_antes_da_6, &censo::por_tipo(), a.trocas);
    println!("  {}", atual.linha());

    // **Largar tudo antes do `MFShutdown`.** A primeira corrida desta sonda saiu com
    // `0xC0000005` depois de imprimir "fim": o `MFShutdown` corria enquanto as threads de
    // bombeamento dos encoders aposentados ainda seguravam `IMFMediaEventGenerator`. Desligar e
    // soltar primeiro é a ordem certa, e é a mesma que `Cadeia::fechar` já usa no produto.
    encoder::desligar(&atual.enc);
    encoder::desligar(&vaga_livre.enc);
    drop(atual);
    drop(vaga_livre);
    drop(origem);
    // As threads de bombeamento saem sozinhas quando o `IMFShutdown` faz o `GetEvent` devolver
    // erro, mas elas saem *depois*. Um respiro antes do `MFShutdown` é o que evita a corrida.
    std::thread::sleep(Duration::from_millis(300));
    println!("\n== fim ==");
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    Ok(())
}
