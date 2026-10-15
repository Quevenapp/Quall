//! `quall-camera` — **o instalador avulso da câmera virtual do Quall** (decisão do Bruno,
//! 12/10/2026, tarde). Um executável só, para baixar da página do Quall
//! (`regras_da_instalacao_da_camera::URL_DA_PAGINA_DA_CAMERA`), que instala e remove a fonte da
//! câmera que vai dentro dele. É o caminho de quem usa o Quall da Microsoft Store (o MSIX não eleva)
//! e serve também a quem usa o do site.
//!
//! # O molde é o `quall-driver.exe`
//!
//! A mesma janela (`TaskDialog`), os mesmos botões Instalar / Remover / Fechar conforme a situação,
//! a barra do andamento, o rodapé com a frase e "Detalhes" com o diário em memória. E o mesmo
//! código de instalar do botão dos Ajustes (`instalador_da_camera::elevado::rodar_aqui`), sem cópia:
//! uma câmera instalada por este exe é a mesma que o botão instala, e vice-versa.
//!
//! # Elevado pelo manifesto
//!
//! `camera.manifest` (embutido pelo `build.rs`) pede `requireAdministrator`: o UAC vem ao abrir, e
//! nada aqui se relança. Como o processo inteiro é de administrador, **nada é escrito em pasta do
//! usuário**: o diário fica em memória; o idioma só é **lido** do `%APPDATA%\Quall\idioma.txt` do
//! Quall (a escolha do botão PT | EN), senão o do Windows.
//!
//! # A fonte dentro do exe
//!
//! A DLL vem embutida pelo `build.rs` (`QUALL_CAMERA_FONTE_DLL`): o arquivo para baixar é um só.
//! Embutir, e não levar ao lado, é o que o driver faz com o SudoVDA, por dois motivos: o processo
//! elevado não lê nada de uma pasta que o usuário controla (Downloads), e quem baixa recebe um
//! arquivo. Um `quall-camera.exe` compilado sem ela abre e diz "a fonte da câmera não veio dentro
//! deste Quall" no passo 1; `scripts/construir-quall-camera.ps1` confere os bytes dentro do exe
//! antes de ele ir ao site, e `quall-camera.exe --conferir` imprime o tamanho embutido (o UAC vem
//! antes, pelo manifesto).
//!
//! # Ao vivo
//!
//! O Quall aberto ao lado (o da loja inclusive) relê o registro a cada 2 s e na volta do foco: a
//! câmera aparece nos outros apps sem fechar o Quall. Esta janela relê a cada ~2 s parada, para o
//! botão do Quall do site que instalou ou removeu enquanto ela estava aberta.

#![cfg(windows)]
#![windows_subsystem = "windows"]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::sync::Mutex;

use quall_capture_probe::idioma::t;
use quall_capture_probe::instalador_da_camera as camera;
use quall_capture_probe::modelo_da_janela::texto_do_andamento_da_camera;
use quall_capture_probe::regras_da_instalacao_da_camera::{self as regras, Acao, Andamento, Resultado, Situacao};

use windows::core::{HRESULT, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, S_FALSE, S_OK, WPARAM};
use windows::Win32::UI::Controls::{
    TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOG_BUTTON, TASKDIALOG_ELEMENTS, TASKDIALOG_NOTIFICATIONS,
    TDE_EXPANDED_INFORMATION, TDE_FOOTER, TDF_ALLOW_DIALOG_CANCELLATION, TDF_CALLBACK_TIMER, TDF_EXPAND_FOOTER_AREA,
    TDF_SHOW_PROGRESS_BAR, TDM_ENABLE_BUTTON, TDM_SET_ELEMENT_TEXT, TDM_SET_PROGRESS_BAR_POS, TDM_SET_PROGRESS_BAR_STATE,
    TDN_BUTTON_CLICKED, TDN_CREATED, TDN_TIMER, TD_SHIELD_ICON,
};
use windows::Win32::UI::WindowsAndMessaging::{SendMessageW, IDCANCEL};

const ID_INSTALAR: i32 = 1000;
const ID_REMOVER: i32 = 1001;
const ID_FECHAR: i32 = 1002;
/// `PBST_NORMAL` e `PBST_ERROR` do `commctrl.h`.
const BARRA_NORMAL: usize = 1;
const BARRA_ERRO: usize = 2;

/// O que a janela mostra, e os textos que o `TaskDialog` lê por ponteiro (vivos até a troca seguinte).
struct Tela {
    situacao: Situacao,
    versao_vista: u64,
    ticks: u32,
    textos: Vec<Vec<u16>>,
}

static TELA: Mutex<Option<Tela>> = Mutex::new(None);

fn largo(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// O rodapé: o andamento, quando há; senão, a situação.
fn rodape(s: Situacao, a: &Andamento) -> String {
    match (texto_do_andamento_da_camera(a), a) {
        (Some((_, texto)), Andamento::Acabou { acao: Acao::Instalar, resultado: Resultado::Ok }) => {
            format!("{texto} {}", t(regras::INSTALADOR_JA_PODE))
        }
        (Some((_, texto)), _) => texto,
        (None, _) => t(regras::frase_do_instalador(s)).to_string(),
    }
}

fn mandar_texto(h: HWND, tela: &mut Tela, elemento: TASKDIALOG_ELEMENTS, s: &str) {
    let w = largo(s);
    unsafe {
        SendMessageW(h, TDM_SET_ELEMENT_TEXT.0 as u32, Some(WPARAM(elemento.0 as usize)), Some(LPARAM(w.as_ptr() as isize)));
    }
    tela.textos.push(w);
    if tela.textos.len() > 16 {
        tela.textos.remove(0);
    }
}

/// Põe na janela a situação e o andamento de agora: os botões, o rodapé, a barra e "Detalhes".
fn refazer(h: HWND, tela: &mut Tela) {
    let a = camera::andamento();
    let (instalar, remover) = regras::botoes_do_instalador(tela.situacao, &a);
    unsafe {
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_INSTALAR as usize)), Some(LPARAM(instalar as isize)));
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_REMOVER as usize)), Some(LPARAM(remover as isize)));
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_FECHAR as usize)), Some(LPARAM(regras::pode_fechar(&a) as isize)));
    }
    let (pos, erro) = match &a {
        Andamento::Parado => (0, false),
        Andamento::Rodando { acao, passo } => (passo * 100 / regras::passos(*acao).len().max(1), false),
        Andamento::Acabou { resultado: Resultado::Ok | Resultado::OkReiniciar, .. } => (100, false),
        Andamento::Acabou { .. } => (100, true),
    };
    unsafe {
        SendMessageW(h, TDM_SET_PROGRESS_BAR_STATE.0 as u32, Some(WPARAM(if erro { BARRA_ERRO } else { BARRA_NORMAL })), None);
        SendMessageW(h, TDM_SET_PROGRESS_BAR_POS.0 as u32, Some(WPARAM(pos)), None);
    }
    let r = rodape(tela.situacao, &a);
    mandar_texto(h, tela, TDE_FOOTER, &r);
    let diario = camera::diario_local();
    let detalhes = if diario.is_empty() { "—".to_string() } else { diario.join("\n") };
    mandar_texto(h, tela, TDE_EXPANDED_INFORMATION, &detalhes);
}

unsafe extern "system" fn ao_avisar(h: HWND, msg: TASKDIALOG_NOTIFICATIONS, w: WPARAM, _l: LPARAM, _d: isize) -> HRESULT {
    // `try_lock`: um `SendMessageW` de dentro do aviso pode trazer outro aviso na mesma thread.
    let Ok(mut guarda) = TELA.try_lock() else { return S_OK };
    let Some(tela) = guarda.as_mut() else { return S_OK };
    match msg {
        TDN_CREATED => {
            refazer(h, tela);
            S_OK
        }
        TDN_TIMER => {
            tela.ticks = tela.ticks.wrapping_add(1);
            let v = camera::versao();
            let a = camera::andamento();
            let parado = regras::pode_comecar(&a);
            // Relê o computador no fim de cada instalação, e a cada ~2 s parado (o Quall do site
            // que instalou ou removeu pelo botão dele com esta janela aberta).
            let reler = (v != tela.versao_vista && matches!(a, Andamento::Acabou { .. })) || (parado && tela.ticks % 10 == 0);
            if reler {
                let s = camera::ler_situacao_do_instalador();
                if s != tela.situacao {
                    tela.situacao = s;
                    tela.versao_vista = u64::MAX;
                }
            }
            if v != tela.versao_vista {
                tela.versao_vista = v;
                refazer(h, tela);
            }
            S_OK
        }
        TDN_BUTTON_CLICKED => {
            let id = w.0 as i32;
            let a = camera::andamento();
            match id {
                ID_INSTALAR | ID_REMOVER => {
                    let (instalar, remover) = regras::botoes_do_instalador(tela.situacao, &a);
                    if id == ID_INSTALAR && instalar {
                        camera::comecar_aqui(Acao::Instalar);
                    } else if id == ID_REMOVER && remover {
                        camera::comecar_aqui(Acao::Desinstalar);
                    }
                    refazer(h, tela);
                    // S_FALSE: a janela fica aberta.
                    S_FALSE
                }
                // Fechar (o botão, o X ou o Esc): não no meio de uma instalação.
                x if x == ID_FECHAR || x == IDCANCEL.0 => {
                    if regras::pode_fechar(&a) {
                        S_OK
                    } else {
                        S_FALSE
                    }
                }
                _ => S_FALSE,
            }
        }
        _ => S_OK,
    }
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    // `--conferir`: o tamanho da fonte embutida, para o roteiro de construção (`0` recusa o exe).
    // O manifesto pede o UAC antes do `main` mesmo assim.
    if std::env::args_os().skip(1).eq([std::ffi::OsString::from("--conferir")]) {
        use std::io::Write;
        let conferida = regras::conferir_a_dll(camera::DLL_EMBUTIDA);
        let linha = format!("fonte embutida: {} B ({})\n", camera::DLL_EMBUTIDA.len(), conferida.err().unwrap_or("PE x64 de DLL")); // i18n: fora (bancada)
        if let Err(erro) = std::io::stdout().lock().write_all(linha.as_bytes()) {
            eprintln!("Quall Studio: não consegui escrever: {erro}");
        }
        std::process::exit(if conferida.is_ok() { 0 } else { 1 });
    }
    // Nenhuma DLL da pasta de onde o exe foi baixado (Downloads, de quem quer que seja) carrega daqui
    // para a frente; só as do System32.
    unsafe {
        let _ = windows::Win32::System::LibraryLoader::SetDefaultDllDirectories(windows::Win32::System::LibraryLoader::LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    // O idioma: a escolha guardada pelo Quall, se houver; senão, o do Windows. Só leitura.
    let pasta = std::env::var_os("APPDATA").map(std::path::PathBuf::from).unwrap_or_default().join("Quall");
    quall_capture_probe::idioma::iniciar(&pasta);

    let situacao = camera::ler_situacao_do_instalador();
    if let Ok(mut g) = TELA.lock() {
        *g = Some(Tela { situacao, versao_vista: camera::versao(), ticks: 0, textos: Vec::new() });
    }

    let titulo = largo(t(regras::INSTALADOR_TITULO));
    let pergunta = largo(t(regras::CAIXA_PERGUNTA));
    let conteudo = largo(&camera::corpo_de_instalar());
    let rodape_inicial = largo(&rodape(situacao, &Andamento::Parado));
    let detalhes = largo("—");
    let rotulo_detalhes = largo(t(regras::INSTALADOR_DETALHES));
    let (instalar, remover, fechar) = (largo(t(regras::CAIXA_INSTALAR)), largo(t(regras::CAIXA_REMOVER)), largo(t(regras::INSTALADOR_FECHAR)));
    let botoes = [
        TASKDIALOG_BUTTON { nButtonID: ID_INSTALAR, pszButtonText: PCWSTR(instalar.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_REMOVER, pszButtonText: PCWSTR(remover.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_FECHAR, pszButtonText: PCWSTR(fechar.as_ptr()) },
    ];
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_CALLBACK_TIMER | TDF_SHOW_PROGRESS_BAR | TDF_EXPAND_FOOTER_AREA,
        pszWindowTitle: PCWSTR(titulo.as_ptr()),
        Anonymous1: TASKDIALOGCONFIG_0 { pszMainIcon: TD_SHIELD_ICON },
        pszMainInstruction: PCWSTR(pergunta.as_ptr()),
        pszContent: PCWSTR(conteudo.as_ptr()),
        cButtons: botoes.len() as u32,
        pButtons: botoes.as_ptr(),
        nDefaultButton: ID_FECHAR,
        pszExpandedInformation: PCWSTR(detalhes.as_ptr()),
        pszExpandedControlText: PCWSTR(rotulo_detalhes.as_ptr()),
        pszCollapsedControlText: PCWSTR(rotulo_detalhes.as_ptr()),
        pszFooter: PCWSTR(rodape_inicial.as_ptr()),
        pfCallback: Some(ao_avisar),
        ..Default::default()
    };
    let _ = unsafe { TaskDialogIndirect(&config, None, None, None) };
}
