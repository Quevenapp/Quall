//! Sonda de bancada da Frente 7 (câmera virtual, Windows).
//!
//! Faz três coisas, e cada uma existe para responder a uma pergunta do escopo com número em vez
//! de suposição:
//!
//! 1. `listar` — enumera os **dois** espaços de nomes de câmera do Windows: o moderno (Media
//!    Foundation, `MFEnumDeviceSources` sobre `KSCATEGORY_VIDEO_CAMERA`) e o antigo (DirectShow,
//!    `CLSID_VideoInputDeviceCategory` pelo `ICreateDevEnum`). É o único jeito honesto de
//!    responder "o que cada API exclui": rodar antes e depois de criar a câmera virtual e
//!    comparar as duas listas.
//! 2. `suporte` — pergunta ao próprio sistema se `MFVirtualCameraType_SoftwareCameraSource` é
//!    suportado (`MFIsVirtualCameraTypeSupported`), em vez de deduzir da build do Windows.
//! 3. `criar` — cria a câmera virtual apontando para o CLSID de uma fonte de mídia registrada e
//!    segura o objeto vivo por N segundos (ou até um sinal), que é o tempo em que um app de
//!    terceiro pode vê-la.
//!
//! Só compila no Windows.

#![cfg(windows)]

#[path = "../../../../apps/windows/src/higiene_do_registro.rs"]
mod higiene_do_registro;
#[path = "../../../../apps/windows/src/diagnostico_json.rs"]
mod diagnostico_json;
#[path = "../../../../apps/windows/src/diagnostico_rede.rs"]
mod diagnostico_rede;
#[path = "../../../../apps/windows/src/diagnostico_cli.rs"]
mod diagnostico_cli;

macro_rules! eprintln {
    () => { std::eprintln!() };
    ($($t:tt)*) => { std::eprintln!("{}", crate::higiene_do_registro::sanitizar(&format!($($t)*))) };
}

fn diagnostico(valor: &impl serde::Serialize) -> Result<serde_json::Value> {
    let mut valor = serde_json::to_value(valor)?;
    diagnostico_json::redigir(&mut valor);
    Ok(valor)
}

fn resumo_erro(erro: &dyn std::any::Any) -> String {
    let encadeado = erro.downcast_ref::<anyhow::Error>();
    if let Some(erro) = erro.downcast_ref::<quall_core::error::Error>()
        .or_else(|| encadeado.and_then(|e| e.downcast_ref::<quall_core::error::Error>()))
    { format!("classe=NUCLEO status={}", diagnostico_rede::status(erro)) }
    else { diagnostico_cli::mensagem_de_falha(erro) }
}

mod alimentar;
mod carimbo;
mod emitir;
mod ler;
mod medida;
mod nucleo;
mod receber;

// **Os três moraram aqui até 09/09/2026 e agora moram no app** (`apps/windows/src/`), que é quem
// serve o cano no produto. O `pub use` mantém `crate::cano`, `crate::escala` e `crate::placa`
// válidos para o resto desta sonda: a mudança de casa não vira uma varredura de renomeação.
pub use quall_capture_probe::{cano, escala_nv12 as escala, placa};

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use std::ffi::c_void;

use windows::core::{GUID, HSTRING, PCWSTR, PWSTR};
use windows::Win32::Media::MediaFoundation::{
    MFCreateAttributes, MFCreateVirtualCamera, MFEnumDeviceSources, MFIsVirtualCameraTypeSupported,
    MFShutdown, MFStartup, IMFActivate, IMFAttributes, IMFVirtualCamera,
    MFVirtualCameraAccess_AllUsers, MFVirtualCameraAccess_CurrentUser,
    MFVirtualCameraLifetime_Session, MFVirtualCameraLifetime_System,
    MFVirtualCameraType_SoftwareCameraSource, MFSTARTUP_FULL,
    MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, IEnumMoniker, IMoniker,
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};

// Definidos à mão de propósito: são GUIDs estáveis desde o Windows 9x e depender de qual
// `feature` do `windows-rs` os exporta em qual versão é fonte de atrito sem contrapartida.
const CLSID_SYSTEM_DEVICE_ENUM: GUID = GUID::from_u128(0x62be5d10_60eb_11d0_bd3b_00a0c911ce86);
const CLSID_VIDEO_INPUT_DEVICE_CATEGORY: GUID =
    GUID::from_u128(0x860bb310_5d01_11d0_bd3b_00a0c911ce86);
// KSCATEGORY_VIDEO_CAMERA — a categoria em que a pilha moderna registra câmeras, físicas e
// virtuais. É o que `MFEnumDeviceSources` usa por padrão desde o Windows 10.
pub const KSCATEGORY_VIDEO_CAMERA: GUID = GUID::from_u128(0xe5323777_f976_4f5b_9b55_b94699c46e44);
// KSCATEGORY_CAPTURE — a categoria antiga. Uma câmera que só aparece aqui é invisível para a
// pilha moderna, e vice-versa; enumerar as duas é como se mede o que uma escolha exclui.
const KSCATEGORY_CAPTURE: GUID = GUID::from_u128(0x65e8773d_8f56_11d0_a3b9_00a0c9223196);

#[derive(Parser)]
#[command(name = "quall-camera-sonda", about = "Sonda da câmera virtual do Windows (Frente 7)")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Enumera os dois espaços de nomes de câmera.
    Listar {
        /// Escreve o resultado em JSON neste caminho, para comparar antes/depois.
        #[arg(long)]
        json: Option<String>,
    },
    /// Pergunta ao sistema se a câmera virtual por software é suportada.
    Suporte,
    /// Abre a câmera pelo nome e lê N quadros, medindo o caminho inteiro.
    Ler {
        /// Trecho do nome da câmera (sem diferenciar maiúsculas). Com `--so-do-quall`, o nome
        /// **inteiro**.
        #[arg(long, default_value = "Quall")]
        nome: String,
        /// Só uma câmera virtual do Quall, pelo dono lido do registro e pelo nome exato — nunca
        /// "contém" entre todas as câmeras (a prova da D3, `prova-som-receptor.ps1`).
        #[arg(long)]
        so_do_quall: bool,
        #[arg(long, default_value_t = 150)]
        quadros: u32,
        /// Prazo de parede. Sem ele, um `ReadSample` que nunca volta pendura a sonda inteira —
        /// já aconteceu nesta bancada e custou uma corrida.
        #[arg(long, default_value_t = 30)]
        segundos_max: u64,
        /// Cria a fonte de mídia direto por este CLSID, **sem** passar pelo Frame Server.
        #[arg(long)]
        direto: Option<String>,
        #[arg(long)]
        json: Option<String>,
        /// Grava um quadro do meio da corrida em `.bmp` — prova do pixel que o app consumidor
        /// recebeu, sem fotografar a tela de ninguém.
        #[arg(long)]
        salvar: Option<String>,
    },
    /// **Liga a câmera virtual ao núcleo**: conecta a um emissor, decodifica em hardware o que
    /// vier pela track e escreve no cano. É o papel do app do Quall no desktop.
    Receber {
        /// Endereço do emissor — o fallback obrigatório de `docs/fluxo-de-uso.md`.
        #[arg(long)]
        ip: Option<String>,
        /// Procura o emissor por mDNS em vez de usar `--ip`.
        #[arg(long)]
        descobrir: bool,
        /// PIN mostrado na tela do emissor. Obrigatório no primeiro pareamento.
        #[arg(long)]
        pin: Option<String>,
        #[arg(long, default_value_t = 60)]
        segundos: u64,
        #[arg(long)]
        json: Option<String>,
        #[arg(long, default_value = "quall-camera-windows")]
        device_id: String,
        #[arg(long, default_value = "Câmera virtual (Windows)")]
        nome: String,
        /// Não conecta a ninguém: serve só a placa de espera.
        #[arg(long)]
        so_placa: bool,
        /// Nome da **câmera** cujo cano será servido — a mesma string do `criar --nome`. Ver
        /// `Alimentar::camera`.
        #[arg(long)]
        camera: Option<String>,
        /// **Instrumento de bancada.** Escreve o relógio QPC nos pixels do quadro entregue, o
        /// que vira uma marca de 8x8 no canto superior esquerdo do que sai para o Zoom, o Meet ou
        /// o OBS. Desligado por padrão, e é assim que tem de ficar em qualquer corrida que não
        /// seja de medição. Ver `cano::CARIMBO_ARMADO`.
        #[arg(long)]
        carimbo_de_bancada: bool,
    },
    /// Emissor **de medição**: desenha o próprio relógio dentro do vídeo, encoda em hardware e
    /// manda pela track. Ver `emitir.rs` para por que ele existe.
    Emitir {
        #[arg(long, default_value_t = 30)]
        segundos: u64,
        #[arg(long, default_value_t = 0)]
        porta: u16,
        #[arg(long, default_value_t = 30)]
        fps: u32,
        #[arg(long, default_value_t = 1280)]
        largura: u32,
        #[arg(long, default_value_t = 720)]
        altura: u32,
        #[arg(long, default_value_t = 6_000_000)]
        bitrate: u32,
        /// GOP curto: é ele, e não o pedido de IDR, que de fato garante quadro-chave neste
        /// encoder — o M1 mediu `AVEncVideoForceKeyFrame` sendo aceito e ignorado.
        #[arg(long, default_value_t = 30)]
        gop: u32,
        /// Anuncia a track como câmera em vez de tela.
        #[arg(long)]
        camera: bool,
        /// PIN fixo, para uma corrida de bancada não depender de ler número de saída de texto.
        #[arg(long)]
        pin: Option<String>,
        #[arg(long)]
        json: Option<String>,
    },
    /// Serve o cano de quadros com padrão sintético — o modo antigo, mantido porque é ele que
    /// isola o custo da travessia do custo do decode.
    Alimentar {
        #[arg(long, default_value_t = 60)]
        segundos: u64,
        #[arg(long)]
        json: Option<String>,
        /// Nome da **câmera** cujo cano será servido — a mesma string do `criar --nome`.
        ///
        /// Sem ele, serve o cano histórico (`CANO_SEM_NOME`), que é o que todo roteiro anterior a
        /// 09/09/2026 espera. Com ele, serve `cano_do_nome(<nome>)`, que é como duas câmeras
        /// passam a mostrar imagens diferentes.
        #[arg(long)]
        camera: Option<String>,
        /// **Instrumento de bancada.** Escreve o relógio QPC nos pixels do quadro entregue, o
        /// que vira uma marca de 8x8 no canto superior esquerdo do que sai para o Zoom, o Meet ou
        /// o OBS. Desligado por padrão, e é assim que tem de ficar em qualquer corrida que não
        /// seja de medição. Ver `cano::CARIMBO_ARMADO`.
        #[arg(long)]
        carimbo_de_bancada: bool,
    },
    /// Cria a câmera virtual e a mantém viva.
    Criar {
        /// Nome que aparece na lista de câmeras dos apps.
        #[arg(long, default_value = "Quall")]
        nome: String,
        /// CLSID da fonte de mídia registrada, entre chaves.
        #[arg(long)]
        clsid: String,
        /// Quantos segundos manter a câmera viva.
        #[arg(long, default_value_t = 60)]
        segundos: u64,
        #[arg(long, value_enum, default_value_t = Vida::Sessao)]
        vida: Vida,
        #[arg(long, value_enum, default_value_t = Acesso::UsuarioAtual)]
        acesso: Acesso,
        /// Não chamar `Remove()` ao sair — deixa a câmera registrada no sistema.
        #[arg(long)]
        manter: bool,
    },
}

#[derive(Copy, Clone, ValueEnum)]
enum Vida {
    /// Existe só enquanto este processo segurar o objeto.
    Sessao,
    /// Fica registrada no sistema e sobrevive ao processo (e a reinício).
    Sistema,
}

#[derive(Copy, Clone, ValueEnum)]
enum Acesso {
    UsuarioAtual,
    TodosUsuarios,
}

#[derive(Serialize, Default)]
struct Inventario {
    media_foundation: Vec<Dispositivo>,
    directshow: Vec<Dispositivo>,
}

#[derive(Serialize)]
struct Dispositivo {
    nome: String,
    /// Link simbólico (MF) ou nome de exibição do moniker (DirectShow). É aqui que se vê se o
    /// dispositivo é de software (`ROOT#`, `sw:`) ou de hardware (`USB#`, `pnp:`).
    identidade: String,
    /// Só no DirectShow: o `DevicePath` do repositório de propriedades do moniker. É o que um
    /// app monta no identificador de dispositivo dele — e não é igual ao moniker.
    caminho: Option<String>,
    /// Só no MF: qual categoria KS o listou.
    categoria: Option<String>,
}

fn main() {
    higiene_do_registro::instalar_hook_do_executavel();
    if let Err(erro) = rodar() {
        let resumo = resumo_erro(&erro);
        eprintln!("falha: {resumo}");
        std::process::exit(1);
    }
}

fn rodar() -> Result<()> {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(erro) => {
            if erro.use_stderr() { eprintln!("{}", higiene_do_registro::sanitizar_argumentos(&erro.to_string())); }
            else { let _ = erro.print(); }
            std::process::exit(erro.exit_code());
        }
    };
    unsafe {
        // MTA: a fonte de mídia e o frame server trabalham livres de apartamento; o STA só
        // acrescentaria bombeamento de mensagens que esta sonda não tem por que fazer.
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(mf_versao(), MFSTARTUP_FULL).context("MFStartup")?;
    }

    let r = match cli.cmd {
        Cmd::Listar { json } => cmd_listar(json),
        Cmd::Suporte => cmd_suporte(),
        Cmd::Ler { nome, so_do_quall, quadros, segundos_max, direto, json, salvar } => {
            ler::executar(&nome, so_do_quall, quadros, segundos_max, direto, json, salvar)
        }
        Cmd::Alimentar { segundos, json, camera, carimbo_de_bancada } => {
            armar_carimbo(carimbo_de_bancada);
            alimentar::executar(segundos, json, camera)
        }
        Cmd::Receber {
            ip,
            descobrir,
            pin,
            segundos,
            json,
            device_id,
            nome,
            so_placa,
            camera,
            carimbo_de_bancada,
        } => {
            armar_carimbo(carimbo_de_bancada);
            receber::executar(receber::Opcoes {
                ip,
                descobrir,
                pin,
                segundos,
                json,
                device_id,
                display_name: nome,
                so_placa,
                camera,
            })
        }
        Cmd::Emitir {
            segundos,
            porta,
            fps,
            largura,
            altura,
            bitrate,
            gop,
            camera,
            pin,
            json,
        } => emitir::executar(emitir::Opcoes {
            segundos,
            porta,
            fps,
            largura,
            altura,
            bitrate,
            gop,
            camera,
            pin,
            json,
        }),
        Cmd::Criar {
            nome,
            clsid,
            segundos,
            vida,
            acesso,
            manter,
        } => cmd_criar(&nome, &clsid, segundos, vida, acesso, !manter),
    };

    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    r
}

/// Arma (ou não) o carimbo de bancada, e **diz em voz alta qual dos dois**.
///
/// A linha impressa não é enfeite: ela é metade da prova de que o instrumento está fora do
/// caminho normal. A outra metade é `quadros_carimbados` no relatório do consumidor. Sem as duas,
/// "tirei o carimbo" é uma afirmação sobre o código-fonte, não sobre o quadro entregue.
fn armar_carimbo(ligado: bool) {
    if ligado {
        cano::armar_carimbo_de_bancada();
        eprintln!(
            "carimbo de bancada: ARMADO — o quadro entregue leva uma marca de 8x8 no canto \
             superior esquerdo. NÃO use assim fora de uma corrida de medição."
        );
    } else {
        eprintln!("carimbo de bancada: desligado — o quadro entregue é só imagem");
    }
}

/// `MF_VERSION` é `(MF_SDK_VERSION << 16) | MF_API_VERSION`. O `windows-rs` expõe a constante,
/// mas o valor é estável e escrevê-lo aqui evita depender de qual módulo a exporta.
pub fn mf_versao() -> u32 {
    const MF_SDK_VERSION: u32 = 0x0002;
    const MF_API_VERSION: u32 = 0x0070;
    (MF_SDK_VERSION << 16) | MF_API_VERSION
}

fn cmd_suporte() -> Result<()> {
    let hr = unsafe { MFIsVirtualCameraTypeSupported(MFVirtualCameraType_SoftwareCameraSource) };
    match hr {
        Ok(suportado) => println!(
            "MFIsVirtualCameraTypeSupported(SoftwareCameraSource) = {}",
            suportado.as_bool()
        ),
        Err(e) => println!("MFIsVirtualCameraTypeSupported falhou: {}", resumo_erro(&e)),
    }
    Ok(())
}

fn cmd_listar(json: Option<String>) -> Result<()> {
    let mut inv = Inventario::default();

    for (rotulo, categoria) in [
        ("KSCATEGORY_VIDEO_CAMERA", KSCATEGORY_VIDEO_CAMERA),
        ("KSCATEGORY_CAPTURE", KSCATEGORY_CAPTURE),
    ] {
        match enumerar_mf(categoria) {
            Ok(mut v) => {
                for d in v.iter_mut() {
                    d.categoria = Some(rotulo.to_string());
                }
                inv.media_foundation.extend(v);
            }
            Err(e) => eprintln!("enumeração MF em {rotulo} falhou: {}", crate::resumo_erro(&e)),
        }
    }

    match enumerar_directshow() {
        Ok(v) => inv.directshow = v,
        Err(e) => eprintln!("enumeração DirectShow falhou: {}", crate::resumo_erro(&e)),
    }

    println!("=== Media Foundation ({} entradas) ===", inv.media_foundation.len());
    for (i, d) in inv.media_foundation.iter().enumerate() {
        println!(
            "  #{} [{}] (nome/link omitidos)",
            i + 1,
            d.categoria.as_deref().unwrap_or("?"),
        );
    }
    println!("\n=== DirectShow ({} entradas) ===", inv.directshow.len());
    for (i, d) in inv.directshow.iter().enumerate() {
        println!("  #{} (nome/moniker omitidos)", i + 1);
        if d.caminho.is_some() {
            println!("      DevicePath: presente");
        }
    }

    if let Some(caminho) = json {
        std::fs::write(&caminho, serde_json::to_vec_pretty(&diagnostico(&inv)?)?)?;
        println!("\ninventário diagnóstico gravado (caminho omitido)");
    }
    Ok(())
}

fn enumerar_mf(categoria: GUID) -> Result<Vec<Dispositivo>> {
    unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2)?;
        let attrs = attrs.ok_or_else(|| anyhow!("MFCreateAttributes devolveu nulo"))?;
        attrs.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )?;
        attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY, &categoria)?;

        let mut ativadores: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n: u32 = 0;
        MFEnumDeviceSources(&attrs, &mut ativadores, &mut n)?;

        let mut saida = Vec::new();
        if !ativadores.is_null() {
            let fatia = std::slice::from_raw_parts(ativadores, n as usize);
            for a in fatia.iter().flatten() {
                let nome = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME)
                    .unwrap_or_else(|| "(sem nome)".into());
                let link = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK)
                    .unwrap_or_else(|| "(sem link)".into());
                saida.push(Dispositivo {
                    nome,
                    identidade: link,
                    caminho: None,
                    categoria: None,
                });
            }
            // Os ativadores foram alocados com CoTaskMemAlloc; soltar as referências acontece no
            // `Drop` de cada `IMFActivate`, mas o vetor em si é nosso para liberar.
            for a in std::slice::from_raw_parts_mut(ativadores, n as usize) {
                let _ = a.take();
            }
            CoTaskMemFree(Some(ativadores as *const c_void));
        }
        Ok(saida)
    }
}

pub fn string_de(a: &IMFActivate, chave: &GUID) -> Option<String> {
    unsafe {
        let mut p = PWSTR::null();
        let mut n = 0u32;
        if a.GetAllocatedString(chave, &mut p, &mut n).is_err() {
            return None;
        }
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const c_void));
        s
    }
}

fn enumerar_directshow() -> Result<Vec<Dispositivo>> {
    use windows::Win32::Media::DirectShow::ICreateDevEnum;
    unsafe {
        let dev_enum: ICreateDevEnum =
            CoCreateInstance(&CLSID_SYSTEM_DEVICE_ENUM, None, CLSCTX_INPROC_SERVER)?;
        let mut e: Option<IEnumMoniker> = None;
        // Devolve S_FALSE (não é erro) quando a categoria está vazia — daí o `Option`.
        dev_enum.CreateClassEnumerator(&CLSID_VIDEO_INPUT_DEVICE_CATEGORY, &mut e, 0)?;
        let Some(e) = e else { return Ok(Vec::new()) };

        let mut saida = Vec::new();
        loop {
            let mut m: [Option<IMoniker>; 1] = [None];
            let mut lidos = 0u32;
            if e.Next(&mut m, Some(&mut lidos)).is_err() || lidos == 0 {
                break;
            }
            let Some(m) = m[0].take() else { break };
            let identidade = m
                .GetDisplayName(None, None)
                .ok()
                .and_then(|p| {
                    let s = p.to_string().ok();
                    CoTaskMemFree(Some(p.0 as *const c_void));
                    s
                })
                .unwrap_or_else(|| "(sem moniker)".into());
            let nome = prop_dshow(&m, windows::core::w!("FriendlyName"))
                .unwrap_or_else(|| "(sem nome)".into());
            // `DevicePath` **não** é o mesmo que o nome de exibição do moniker: o moniker vem com
            // o prefixo `@device:pnp:` e o `DevicePath` não. Quem consome a lista pela API do
            // DirectShow (o OBS, por exemplo) monta o identificador com o `DevicePath`; passar o
            // moniker faz o OBS responder `data.GetDevice failed` — medido nesta bancada.
            let caminho = prop_dshow(&m, windows::core::w!("DevicePath"));
            saida.push(Dispositivo {
                nome,
                identidade,
                caminho,
                categoria: None,
            });
        }
        Ok(saida)
    }
}

/// Lê uma propriedade do `IPropertyBag` do moniker (`FriendlyName`, `DevicePath`).
fn prop_dshow(m: &IMoniker, chave: PCWSTR) -> Option<String> {
    use windows::Win32::System::Com::StructuredStorage::IPropertyBag;
    use windows::Win32::System::Variant::{VariantClear, VARIANT};
    unsafe {
        let bag: IPropertyBag = m.BindToStorage(None, None).ok()?;
        let mut v = VARIANT::default();
        bag.Read(chave, &mut v, None).ok()?;
        let s = variant_para_string(&v);
        let _ = VariantClear(&mut v);
        s
    }
}

fn variant_para_string(v: &windows::Win32::System::Variant::VARIANT) -> Option<String> {
    use windows::Win32::System::Variant::VT_BSTR;
    unsafe {
        let a = &v.Anonymous.Anonymous;
        if a.vt != VT_BSTR {
            return None;
        }
        Some(a.Anonymous.bstrVal.to_string())
    }
}

fn cmd_criar(
    nome: &str,
    clsid: &str,
    segundos: u64,
    vida: Vida,
    acesso: Acesso,
    remover_ao_sair: bool,
) -> Result<()> {
    let vida_mf = match vida {
        Vida::Sessao => MFVirtualCameraLifetime_Session,
        Vida::Sistema => MFVirtualCameraLifetime_System,
    };
    let acesso_mf = match acesso {
        Acesso::UsuarioAtual => MFVirtualCameraAccess_CurrentUser,
        Acesso::TodosUsuarios => MFVirtualCameraAccess_AllUsers,
    };

    let nome_h = HSTRING::from(nome);
    let clsid_h = HSTRING::from(clsid);

    let cam: IMFVirtualCamera = unsafe {
        MFCreateVirtualCamera(
            MFVirtualCameraType_SoftwareCameraSource,
            vida_mf,
            acesso_mf,
            &nome_h,
            &clsid_h,
            None,
        )
    }
    .context("MFCreateVirtualCamera")?;
    println!("MFCreateVirtualCamera: ok  (nome omitido, clsid={clsid})");

    unsafe { cam.Start(None) }.context("IMFVirtualCamera::Start")?;
    println!("Start: ok — a câmera deve aparecer na lista agora");

    std::thread::sleep(std::time::Duration::from_secs(segundos));

    // Ordem deliberada: Stop antes de Remove antes de Shutdown. Cada uma é cronometrada e
    // impressa **antes e depois**, porque na primeira corrida uma delas pendurou o processo e,
    // sem marca de entrada, não dava para dizer qual.
    passo("Stop", || unsafe { cam.Stop() });
    if remover_ao_sair {
        passo("Remove", || unsafe { cam.Remove() });
    }
    passo("Shutdown", || unsafe { cam.Shutdown() });
    println!("encerrada");
    Ok(())
}

fn passo(nome: &str, f: impl FnOnce() -> windows::core::Result<()>) {
    use std::io::Write as _;
    print!("  {nome}: entrando... ");
    let _ = std::io::stdout().flush();
    let t = std::time::Instant::now();
    let r = f();
    println!("saiu em {:.1} ms -> {r:?}", t.elapsed().as_secs_f64() * 1000.0);
    let _ = std::io::stdout().flush();
}
