//! `quall-espera` — **instrumento de bancada**: *quem* registra a espera que vaza?
//!
//! # A pergunta, e de onde ela vem
//!
//! `docs/troca-a-quente.md`, achado 5: cada recriação de encoder deixa para trás **exatamente um**
//! `Event`, **um** `Key` e **um** `WaitCompletionPacket`, sem que nenhum outro tipo de objeto se
//! mova. `Event` + `WaitCompletionPacket` em par é a assinatura de uma **espera registrada** de
//! pool de threads que nunca foi cancelada; `Key` é uma chave do registro aberta e não fechada.
//! Threads e memória já tinham sido descartadas por medida (29–32 threads estáveis, conjunto de
//! trabalho *caindo* de 127 para 86 MB).
//!
//! E o mesmo documento escreve o limite do instrumento que achou isso:
//!
//! > **O que eu NÃO provei**: *quem* registra a espera. (…) Se é o MFT, o driver da Intel por
//! > baixo dele, ou o Media Foundation em nome dos dois, o censo não distingue: ele conta
//! > objetos, não nomeia quem os criou.
//!
//! Esta sonda ataca exatamente essa frase, por três caminhos que se conferem entre si.
//!
//! # 1. O censo passa a guardar o **valor** do handle, não só a contagem
//!
//! `quall-gemeos` conta handles por tipo. Contagem não identifica indivíduo: dois censos com
//! `Event: 78 → 98` não dizem *quais* vinte apareceram. Guardando `{valor do handle → tipo}` a
//! diferença entre dois censos é o **conjunto dos handles novos**, e aí cada um deles é uma coisa
//! concreta que dá para perguntar mais sobre.
//!
//! # 2. Handle novo de tipo `Key` **tem nome**, e o nome é o caminho no registro
//!
//! É a virada. Um `Key` do kernel é uma chave aberta, e `NtQueryObject(ObjectNameInformation)`
//! devolve o caminho dela — `\REGISTRY\MACHINE\SYSTEM\...`. Quem abriu a chave que vaza fica
//! nomeado pelo lugar em que ele abriu: a chave de classe de um driver de vídeo nomeia o
//! fabricante; uma chave do Media Foundation nomeia a plataforma.
//!
//! **E isto é compatível com uma hipótese que explica os três objetos de uma vez só**:
//! `RegNotifyChangeKeyValue` — registrar aviso de mudança numa chave — precisa da chave aberta
//! (`Key`), de um evento (`Event`) e, quando a espera é entregue a um pool de threads, de um
//! `WaitCompletionPacket`. Um de cada, por registro, exatamente como medido. A sonda não afirma
//! isso: ela mede o nome da chave, que é o que separa a hipótese de uma coincidência.
//!
//! ## O `ObjectNameInformation` e a armadilha que `quall-gemeos` evitou
//!
//! Aquele censo usa `ObjectTypeInformation` **de propósito**, porque `ObjectNameInformation` pode
//! **bloquear para sempre** num handle de pipe com E/S pendente — é a armadilha clássica desta
//! técnica. A ressalva continua valendo e por isso esta sonda **só pergunta o nome de tipos que
//! não têm E/S**: `Key`, `Event`, `Mutant`, `Semaphore`, `Section`, `Directory`, `Timer`. Nunca
//! `File`, nunca `IoCompletion`, nunca um tipo desconhecido. A lista é uma permissão, não um
//! filtro: o que não estiver nela não é perguntado.
//!
//! # 3. A decomposição: qual chamada cria o trio
//!
//! Nomear o objeto ainda não nomeia o criador. Por isso a sonda mede **fases separadas**, cada uma
//! com censo próprio:
//!
//! | fase | o que roda | o que a fase responde |
//! |---|---|---|
//! | `enumerar`  | `MFTEnumEx` e larga os `IMFActivate` | é a enumeração? |
//! | `ativar`    | `ActivateObject` + `ShutdownObject`, sem configurar nada | é a ativação nua? |
//! | `configurar`| ativação + `SET_D3D_MANAGER` + tipos + baixa latência + shutdown | é a configuração? |
//!
//! Se o trio aparecer em `ativar` e não em `enumerar`, o criador está dentro do `ActivateObject`
//! do MFT escolhido — que é o que `docs/troca-a-quente.md` suspeita sem ter medido.
//!
//! # 4. O diferencial entre fabricantes, que separa "o MFT" de "o Media Foundation"
//!
//! `--preferir intel` e `--preferir nvidia` rodam as **mesmas** fases com MFTs de fabricantes
//! diferentes. Se só um vaza, o criador está do lado do fabricante; se os dois vazam igual, a
//! suspeita passa para o Media Foundation, que é comum aos dois.
//!
//! **Nomear o MFT não é opcional nesta bancada.** Na Sessão 0 (onde o SSH cai) o `ActivateObject`
//! da NVIDIA funciona e na sessão interativa ele falha; uma sonda sem preferência explícita mede
//! a NVENC e reporta 39 ms onde o produto paga 150. O cabeçalho de cada corrida imprime o nome
//! amigável do MFT que de fato ativou.
//!
//! # O que ela NÃO faz
//!
//! - **Não captura a tela.** Não há origem de vídeo nenhuma aqui: a sonda monta e derruba o
//!   encoder, sem empurrar quadro. Roda na Sessão 0, sem Tarefa Agendada.
//! - **Não toca a rede.** Nada de `quall-core`, nada de sessão, nada de socket.
//! - **Não prova a pilha de chamadas.** Um `!htrace` do WinDbg daria a pilha exata de
//!   `NtCreateEvent`; isto aqui dá o *nome do objeto* e a *chamada* que o cria, que é o que se
//!   consegue sem depurador instalado.
//!
//! # Uso
//!
//!     quall-espera --repeticoes 20 --preferir intel
//!     quall-espera --repeticoes 20 --preferir nvidia
//!     quall-espera --repeticoes 20 --preferir intel --so ativar

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use clap::Parser;
use windows::core::Result;
use windows::Win32::Media::MediaFoundation::{MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use quall_capture_probe::encoder::{ChosenEncoder, EncoderConfig, Preferencia};
use quall_capture_probe::{device, encoder};

#[derive(Parser, Debug)]
#[command(about = "Bancada: quem registra a espera de pool de threads que vaza por recriacao.")]
struct Argumentos {
    /// Repetições por fase. 20 é o número com que `docs/troca-a-quente.md` mediu +3,00.
    #[arg(long, default_value_t = 20)]
    repeticoes: u64,

    /// `intel`, `nvidia` ou `produto`. **Sempre nomeie**: ver o cabeçalho.
    #[arg(long, default_value = "intel")]
    preferir: String,

    /// Roda só uma fase: `enumerar`, `ativar` ou `configurar`.
    #[arg(long, default_value = "tudo")]
    so: String,

    #[arg(long, default_value_t = 1280)]
    largura: u32,
    #[arg(long, default_value_t = 720)]
    altura: u32,
    #[arg(long, default_value_t = 30)]
    fps: u32,
    #[arg(long, default_value_t = 4_000_000)]
    bitrate: u32,

    /// Não pergunta o nome de handle nenhum. Escotilha para o caso de o `ObjectNameInformation`
    /// travar numa máquina diferente desta.
    #[arg(long, default_value_t = false)]
    sem_nomes: bool,
}

// -------------------------------------------------------------------------------------------------
// O censo, agora por indivíduo
// -------------------------------------------------------------------------------------------------
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

    const OBJECT_NAME_INFORMATION: i32 = 1;
    const OBJECT_TYPE_INFORMATION: i32 = 2;

    /// Tipos cujo `ObjectNameInformation` **não** pode bloquear: nenhum deles tem E/S pendente.
    ///
    /// É uma lista de permissão, e a diferença importa: um filtro que dissesse "tudo menos `File`"
    /// deixaria passar o tipo que ninguém previu. `quall-gemeos` evitou este caminho inteiro por
    /// causa dessa armadilha, e a ressalva dele continua certa — o que muda aqui é que o nome só é
    /// perguntado a quem não pode travar.
    const SEGUROS_PARA_NOMEAR: &[&str] = &[
        "Key", "Event", "Mutant", "Semaphore", "Section", "Directory", "Timer", "IRTimer",
    ];

    #[repr(C)]
    struct Alinhado([u64; 512]);

    fn texto_do_unicode_string(bytes: &[u8]) -> Option<String> {
        // `UNICODE_STRING { u16 Length; u16 MaximumLength; /* 4 de padding */ u16* Buffer; }`
        let tam = u16::from_ne_bytes([bytes[0], bytes[1]]) as usize;
        let ptr = usize::from_ne_bytes(bytes[8..16].try_into().ok()?) as *const u16;
        if tam == 0 || ptr.is_null() {
            return None;
        }
        let s = unsafe { std::slice::from_raw_parts(ptr, tam / 2) };
        Some(String::from_utf16_lossy(s))
    }

    fn consultar(h: isize, classe: i32) -> Option<String> {
        let mut buffer = Alinhado([0u64; 512]);
        let bytes =
            unsafe { std::slice::from_raw_parts_mut(buffer.0.as_mut_ptr() as *mut u8, 512 * 8) };
        let mut devolvido = 0u32;
        let st = unsafe {
            NtQueryObject(h, classe, bytes.as_mut_ptr(), bytes.len() as u32, &mut devolvido)
        };
        if st < 0 {
            return None;
        }
        texto_do_unicode_string(bytes)
    }

    /// `{valor do handle → nome do tipo}` de todos os handles vivos deste processo.
    ///
    /// Mesma varredura de `quall-gemeos` (handles do Windows são múltiplos de 4; handle inválido
    /// devolve `STATUS_INVALID_HANDLE` e sai da conta), mas guardando o **valor**. É o que permite
    /// perguntar "quais apareceram?" em vez de só "quantos a mais?".
    pub fn individuos() -> BTreeMap<isize, String> {
        let mut mapa = BTreeMap::new();
        let mut h: isize = 4;
        while h <= 0x40000 {
            if let Some(tipo) = consultar(h, OBJECT_TYPE_INFORMATION) {
                mapa.insert(h, tipo);
            }
            h += 4;
        }
        mapa
    }

    /// O nome do objeto, quando o tipo permite perguntar sem risco de travar.
    pub fn nome(h: isize, tipo: &str) -> Option<String> {
        if !SEGUROS_PARA_NOMEAR.contains(&tipo) {
            return None;
        }
        consultar(h, OBJECT_NAME_INFORMATION)
    }
}

// -------------------------------------------------------------------------------------------------
fn por_tipo(mapa: &std::collections::BTreeMap<isize, String>) -> std::collections::BTreeMap<String, u32> {
    let mut fora = std::collections::BTreeMap::new();
    for t in mapa.values() {
        *fora.entry(t.clone()).or_insert(0) += 1;
    }
    fora
}

/// Imprime o que apareceu entre dois censos: por tipo, e **por indivíduo**, com nome quando dá.
fn relatar(
    rotulo: &str,
    antes: &std::collections::BTreeMap<isize, String>,
    depois: &std::collections::BTreeMap<isize, String>,
    repeticoes: u64,
    sem_nomes: bool,
) {
    let ta = por_tipo(antes);
    let td = por_tipo(depois);
    println!("\n  -- {rotulo} ({repeticoes} repeticoes) --");

    let mut chaves: Vec<&String> = ta.keys().chain(td.keys()).collect();
    chaves.sort();
    chaves.dedup();
    let mut mexeu = false;
    for k in chaves {
        let a = *ta.get(k).unwrap_or(&0) as i64;
        let d = *td.get(k).unwrap_or(&0) as i64;
        if a == d {
            continue;
        }
        mexeu = true;
        println!(
            "     {k:<24} {a:>5} -> {d:>5}   {:+5}   {:+.2} por repeticao",
            d - a,
            if repeticoes > 0 { (d - a) as f64 / repeticoes as f64 } else { 0.0 }
        );
    }
    if !mexeu {
        println!("     nenhum tipo se moveu");
    }

    // Os indivíduos novos, com nome. É a parte que `quall-gemeos` não tinha.
    let novos: Vec<(isize, &String)> =
        depois.iter().filter(|(h, _)| !antes.contains_key(h)).map(|(h, t)| (*h, t)).collect();
    if novos.is_empty() {
        println!("     nenhum handle novo");
        return;
    }
    println!("     {} handle(s) novo(s):", novos.len());
    // Agrupa por (tipo, nome) — vinte repetições produzem vinte handles do mesmo lugar, e
    // imprimir vinte linhas iguais esconde o achado em vez de mostrá-lo.
    let mut grupos: std::collections::BTreeMap<(String, String), Vec<isize>> =
        std::collections::BTreeMap::new();
    for (h, tipo) in novos {
        let nome = if sem_nomes {
            "(--sem-nomes)".to_string()
        } else {
            censo::nome(h, tipo).unwrap_or_else(|| "(sem nome)".to_string())
        };
        grupos.entry((tipo.clone(), nome)).or_default().push(h);
    }
    for ((tipo, nome), hs) in grupos {
        println!("        {:>3}x  {:<20} {}", hs.len(), tipo, nome);
    }
}

// -------------------------------------------------------------------------------------------------
fn preferencia(texto: &str) -> Option<Preferencia> {
    match texto {
        "intel" => Some(Preferencia::Intel),
        "produto" | "nvidia" => Some(Preferencia::Produto),
        _ => None,
    }
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    quall_capture_probe::diagnostico_cli::concluir(rodar());
}

fn rodar() -> Result<()> {
    let a = quall_capture_probe::diagnostico_cli::interpretar::<Argumentos>();
    let Some(pref) = preferencia(&a.preferir) else {
        println!("--preferir aceita 'intel', 'nvidia' ou 'produto'; valor recebido omitido");
        return Ok(());
    };

    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
    }

    println!("== quall-espera ==");
    println!("preferencia pedida: {} ({:?})", a.preferir, pref);

    // Uma ativação de sondagem, só para **nomear o MFT** e escolher o adaptador. Ela é feita antes
    // de qualquer censo, de propósito: o que ela vazar entra na linha de base e não na medida.
    let sonda = encoder::ativar_h264(pref)?;
    println!("MFT ativado: \"{}\"  hardware={}", sonda.friendly_name, sonda.is_hardware);
    if a.preferir == "nvidia" && !sonda.friendly_name.to_uppercase().contains("NVIDIA") {
        println!("!! pedi NVIDIA e ativou \"{}\" -- a medida abaixo NAO e da NVENC", sonda.friendly_name);
    }
    let vendor = if sonda.friendly_name.to_uppercase().contains("NVIDIA") {
        device::VENDOR_NVIDIA
    } else {
        device::VENDOR_INTEL
    };
    let adaptador = device::create_device(vendor)?;
    println!("adaptador: {} (0x{:04X})", adaptador.description, adaptador.vendor_id);
    let gerenciador = encoder::create_device_manager(&adaptador.device)?;

    let cfg = EncoderConfig {
        entrada: quall_capture_probe::encoder::FormatoDeEntrada::Argb32,
        width: a.largura,
        height: a.altura,
        fps: a.fps,
        bitrate_bps: a.bitrate,
        gop_frames: a.fps,
        // Este binário mede espera, não tamanho de quadro: os botões de `docs/idr-pequeno.md`
        // ficam desligados aqui para não misturar duas medidas.
        intra_refresh_frames: 0,
        slice_bytes: 0,
        teto_de_quadro_bits: 0,
    };

    // Aquecer: a primeira volta de qualquer fase carrega DLLs e abre chaves que **não** vazam por
    // repetição. Sem o aquecimento, a primeira repetição contamina a média com a montagem única do
    // ambiente — o mesmo cuidado que `quall-gemeos` toma descartando a primeira recriacao.
    let quente = encoder::ativar_h264(pref)?;
    encoder::configure(&quente, &gerenciador, &cfg)?;
    encoder::desligar(&quente);
    drop(quente);
    encoder::desligar(&sonda);

    let todas = a.so == "tudo";

    if todas || a.so == "enumerar" {
        let antes = censo::individuos();
        for _ in 0..a.repeticoes {
            // Enumerar e largar. `ativar_h264` enumera **e** ativa, então esta fase usa a
            // enumeração crua para separar as duas coisas: o que ela deixar para trás é da
            // enumeração, não da ativação.
            let e = encoder::ativar_h264(pref)?;
            encoder::desligar(&e);
            drop(e);
        }
        relatar("enumerar + ativar + desligar (o caminho inteiro)", &antes, &censo::individuos(), a.repeticoes, a.sem_nomes);
    }

    if todas || a.so == "ativar" {
        let base: ChosenEncoder = encoder::ativar_h264(pref)?;
        encoder::desligar(&base);
        let antes = censo::individuos();
        let mut atual = base;
        for _ in 0..a.repeticoes {
            // `reativar` usa o **mesmo** `IMFActivate` e não reenumera. Se o trio aparecer aqui,
            // ele nasce dentro do `ActivateObject`, e não da varredura do registro de MFTs.
            let novo = encoder::reativar(&atual)?;
            encoder::desligar(&novo);
            atual = novo;
        }
        let depois = censo::individuos();
        drop(atual);
        relatar("ActivateObject + ShutdownObject, sem configurar", &antes, &depois, a.repeticoes, a.sem_nomes);
    }

    if todas || a.so == "configurar" {
        let base: ChosenEncoder = encoder::ativar_h264(pref)?;
        encoder::desligar(&base);
        let antes = censo::individuos();
        let mut atual = base;
        for _ in 0..a.repeticoes {
            let novo = encoder::reativar(&atual)?;
            encoder::configure(&novo, &gerenciador, &cfg)?;
            encoder::desligar(&novo);
            atual = novo;
        }
        let depois = censo::individuos();
        drop(atual);
        relatar("ActivateObject + configure + ShutdownObject", &antes, &depois, a.repeticoes, a.sem_nomes);
    }

    println!("\nleitura: um `Key` com nome de chave do registro, ao lado de um `Event` e de um");
    println!("`WaitCompletionPacket`, e a assinatura de um aviso de mudanca de chave registrado num");
    println!("pool de threads e nunca cancelado. O nome do `Key` diz em que chave, e a chave diz de");
    println!("quem. Se o trio nao aparecer em nenhuma fase, o vazamento nao esta neste caminho.");

    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    Ok(())
}
