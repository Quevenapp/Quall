//! `quall_catalogo_de_cameras` — a prova da fase 1 da Frente C **sem elevação**
//! (`docs/camera-no-windows.md`, fase 1).
//!
//! Roda o catálogo de câmeras **do produto**, `fontes::cameras()` — a mesma função que o seletor do
//! `quall-app` chama (desde a fase 5 sem bandeira) —, e escreve o que ele devolveu: as linhas que entrariam no seletor e
//! o registro de cada câmera, com o dono e **quem leu o dono**. A pergunta que ela responde é a da
//! revisão adversarial de 18/09: a leitura do `CustomCaptureSourceClsid` funciona num processo **sem
//! elevação**, na sessão do usuário, que é onde o produto roda? A Sessão 0 do SSH entra elevada e
//! não serve de testemunha.
//!
//! **Sem janela e sem console** (`windows_subsystem = "windows"`, nenhuma janela criada): roda por
//! Tarefa Agendada na sessão do usuário sem piscar nada na tela dele — o molde de `placas_dxgi` da
//! Frente D. A saída vai para o arquivo de `--saida`.
//!
//! Não ativa câmera nenhuma (`cameras.rs` nunca chama `ActivateObject`), não cria nó, não escuta
//! rede.
//!
//!     quall_catalogo_de_cameras.exe --saida C:\caminho\relato.txt [--repetir S]
//!
//! `--repetir S` relê o catálogo a cada segundo por S segundos e escreve de novo **só quando a
//! lista muda**: é o que deixa ver uma câmera de bancada criada por outro processo no meio.

#![windows_subsystem = "windows"]
#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::collections::BTreeSet;
use std::io::Write;
use std::time::{Duration, Instant};

use windows::Win32::Media::MediaFoundation::{MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

use quall_capture_probe::fontes;

fn descrever_token() -> String {
    use windows::Win32::Security::{GetTokenInformation, TokenElevation, TokenSessionId, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    unsafe {
        let mut token = windows::Win32::Foundation::HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
            return "(não deu para abrir o token)".into();
        }
        let mut el = TOKEN_ELEVATION::default();
        let mut n = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            Some(&mut el as *mut TOKEN_ELEVATION as *mut core::ffi::c_void),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut n,
        )
        .is_ok();
        let mut sessao = 0u32;
        let _ = GetTokenInformation(
            token,
            TokenSessionId,
            Some(&mut sessao as *mut u32 as *mut core::ffi::c_void),
            4,
            &mut n,
        );
        let _ = windows::Win32::Foundation::CloseHandle(token);
        if ok {
            format!("elevado={} sessão={sessao}", el.TokenIsElevated != 0)
        } else {
            format!("elevação desconhecida, sessão={sessao}")
        }
    }
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let valor = |nome: &str| args.iter().position(|a| a == nome).and_then(|i| args.get(i + 1)).cloned();
    let Some(saida) = valor("--saida") else {
        // Sem console não há onde dizer isto; o código de saída é a única voz.
        std::process::exit(64);
    };
    let repetir: u64 = valor("--repetir").and_then(|v| v.parse().ok()).unwrap_or(0);
    let Ok(mut f) = std::fs::File::create(&saida) else {
        std::process::exit(65);
    };
    let mut diga = |l: String| {
        let l = quall_capture_probe::higiene_do_registro::sanitizar_argumentos(&l);
        let _ = writeln!(f, "{l}");
        let _ = f.flush();
    };
    diga(format!(
        "quall_catalogo_de_cameras: {} pid={} unix={}",
        descrever_token(),
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    ));
    unsafe {
        if let Err(e) = CoInitializeEx(None, COINIT_MULTITHREADED).ok() {
            diga(format!("ERRO: CoInitializeEx: {e}"));
            std::process::exit(1);
        }
        if let Err(e) = MFStartup(MF_VERSION, MFSTARTUP_FULL) {
            diga(format!("ERRO: MFStartup: {e}"));
            std::process::exit(1);
        }
    }
    let comeco = Instant::now();
    let fim = comeco + Duration::from_secs(repetir);
    let mut anterior: Option<BTreeSet<String>> = None;
    loop {
        let (visiveis, registro) = fontes::cameras(None);
        let agora: BTreeSet<String> = registro.iter().cloned().collect();
        if anterior.as_ref() != Some(&agora) {
            diga(format!("--- t={:.1} s: {} no seletor, {} no registro", comeco.elapsed().as_secs_f64(), visiveis.len(), registro.len()));
            for (i, _) in visiveis.iter().enumerate() {
                diga(format!("SELETOR: #{} (nome/identidade omitidos)", i + 1));
            }
            for (i, _) in registro.iter().enumerate() {
                diga(format!("REGISTRO: entrada #{} (identificação omitida)", i + 1));
            }
            anterior = Some(agora);
        }
        if Instant::now() >= fim {
            break;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    unsafe {
        let _ = MFShutdown();
    }
    diga("FIM".into());
}
