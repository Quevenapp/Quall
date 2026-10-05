//! `quall-driver` — **o instalador avulso do driver da tela estendida do Quall** (decisão do Pessoa Exemplo,
//! 02/10/2026, noite). Um executável próprio, para baixar da página web do Quall
//! (`regras_da_tela_estendida::URL_DO_INSTALADOR_DO_DRIVER`), que instala e desinstala o SudoVDA que
//! vai dentro dele — o caminho de quem usa o Quall da Microsoft Store, onde o app não instala drivers.
//!
//! # O mesmo código do botão do app
//!
//! Os quatro arquivos (`include_bytes!`), a conferência, a ordem, a marca no HKLM, a propriedade no
//! nó e a regra do SudoVDA posto à mão são os de `driver_da_tela_estendida.rs` e
//! `regras_do_driver.rs`, sem cópia: este exe chama `elevado::rodar_aqui` no próprio processo. Um
//! SudoVDA instalado por este exe é "do Quall" também para o app, e vice-versa.
//!
//! # Elevado pelo manifesto
//!
//! `driver.manifest` (embutido pelo `build.rs`) pede `requireAdministrator`: o UAC vem ao abrir, e
//! nada aqui se relança. Como o processo inteiro é de administrador, **nada é escrito em pasta do
//! usuário**: o diário fica em memória e aparece em "Detalhes"; o idioma só é **lido** do
//! `%APPDATA%\Quall\idioma.txt` do Quall (a escolha do botão PT | EN), senão o do Windows.
//!
//! # A janela
//!
//! Um `TaskDialog` (Common Controls 6, como as caixas do app): o mesmo texto da caixa do app (o que
//! é, o UAC, o certificado do autor), a situação neste computador, os botões Instalar / Desinstalar
//! / Fechar conforme ela (`regras_do_driver::botoes_do_instalador`), a barra do andamento e o
//! resultado. Fechar não fecha no meio de uma instalação. O Quall aberto ao lado (o da loja
//! inclusive) vê o adaptador chegar pelo `WM_DEVICECHANGE` e o ladrilho fica escolhível na hora.

#![cfg(windows)]
#![windows_subsystem = "windows"]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::sync::Mutex;

use quall_capture_probe::driver_da_tela_estendida as driver;
use quall_capture_probe::idioma::{t, tf};
use quall_capture_probe::modelo_da_janela::texto_do_andamento;
use quall_capture_probe::regras_do_driver::{self as regras, Acao, Andamento, Resultado, Situacao};

use windows::core::{HRESULT, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, S_FALSE, S_OK, WPARAM};
use windows::Win32::UI::Controls::{
    TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOG_BUTTON, TASKDIALOG_ELEMENTS, TASKDIALOG_NOTIFICATIONS,
    TDE_CONTENT, TDE_EXPANDED_INFORMATION, TDE_FOOTER, TDF_ALLOW_DIALOG_CANCELLATION, TDF_CALLBACK_TIMER, TDF_EXPAND_FOOTER_AREA,
    TDF_SHOW_PROGRESS_BAR, TDM_ENABLE_BUTTON, TDM_SET_ELEMENT_TEXT, TDM_SET_PROGRESS_BAR_POS, TDM_SET_PROGRESS_BAR_STATE,
    TDN_BUTTON_CLICKED, TDN_CREATED, TDN_TIMER, TD_SHIELD_ICON,
};
use windows::Win32::UI::WindowsAndMessaging::{SendMessageW, IDCANCEL};

const ID_INSTALAR: i32 = 1000;
const ID_DESINSTALAR: i32 = 1001;
const ID_FECHAR: i32 = 1002;
const LICENCAS: &str = include_str!("../../../../docs/distribuicao/licencas/textos/SudoVDA-NOTICES.txt");
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

/// O corpo: o mesmo texto da caixa do app (o que é, o UAC, o certificado), e **antes dele**, quando
/// a situação pede (o SudoVDA de outro programa, com os dois botões apagados), o que significa e o
/// que fazer — no corpo, e não só no rodapé (o achado do Pessoa Exemplo, 02/10, noite).
fn explicacao(s: Situacao) -> String {
    let mut v = Vec::new();
    if let Some(aviso) = regras::aviso_no_corpo_do_instalador(s) {
        v.push(t(aviso).to_string());
    }
    v.extend([
        tf(regras::CAIXA_CORPO_O_QUE_E, &[&regras::VERSAO]),
        t(regras::CAIXA_CORPO_UAC).to_string(),
        tf(regras::CAIXA_CORPO_CERTIFICADO, &[&regras::ASSUNTO_DO_CERTIFICADO]),
    ]);
    v.join("\n\n")
}

/// O rodapé: o andamento, quando há; senão, a situação.
fn rodape(s: Situacao, a: &Andamento) -> String {
    match (texto_do_andamento(a), a) {
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
    // O `TaskDialog` lê o texto na hora; guardado mesmo assim, por garantia, até a troca seguinte.
    tela.textos.push(w);
    if tela.textos.len() > 16 {
        tela.textos.remove(0);
    }
}

/// Põe na janela a situação e o andamento de agora: os botões, o rodapé, a barra e "Detalhes".
fn refazer(h: HWND, tela: &mut Tela) {
    let a = driver::andamento();
    let (instalar, desinstalar) = regras::botoes_do_instalador(tela.situacao, &a);
    unsafe {
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_INSTALAR as usize)), Some(LPARAM(instalar as isize)));
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_DESINSTALAR as usize)), Some(LPARAM(desinstalar as isize)));
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
    let diario = driver::diario_local();
    let detalhes = if diario.is_empty() { "—".to_string() } else { diario.join("\n") };
    mandar_texto(h, tela, TDE_EXPANDED_INFORMATION, &detalhes);
}

unsafe extern "system" fn ao_avisar(h: HWND, msg: TASKDIALOG_NOTIFICATIONS, w: WPARAM, _l: LPARAM, _d: isize) -> HRESULT {
    // `try_lock`: um `SendMessageW` de dentro do aviso pode trazer outro aviso na mesma thread.
    let Ok(mut guarda) = TELA.try_lock() else { return S_OK };
    let Some(tela) = guarda.as_mut() else { return S_OK };
    match msg {
        TDN_CREATED => {
            let e = explicacao(tela.situacao);
            mandar_texto(h, tela, TDE_CONTENT, &e);
            refazer(h, tela);
            S_OK
        }
        TDN_TIMER => {
            tela.ticks = tela.ticks.wrapping_add(1);
            let v = driver::versao();
            let parado = regras::pode_comecar(&driver::andamento());
            // Relê o computador no fim de cada instalação, e a cada ~2 s parado (o adaptador
            // ligado ou desligado no Gerenciador, o Quall que instalou pelo botão dele).
            let reler = (v != tela.versao_vista && matches!(driver::andamento(), Andamento::Acabou { .. })) || (parado && tela.ticks % 10 == 0);
            if reler {
                let s = driver::ler_situacao_do_instalador();
                if s != tela.situacao {
                    let corpo_mudou = regras::aviso_no_corpo_do_instalador(s) != regras::aviso_no_corpo_do_instalador(tela.situacao);
                    tela.situacao = s;
                    tela.versao_vista = u64::MAX;
                    if corpo_mudou {
                        let e = explicacao(s);
                        mandar_texto(h, tela, TDE_CONTENT, &e);
                    }
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
            let a = driver::andamento();
            match id {
                ID_INSTALAR | ID_DESINSTALAR => {
                    let (instalar, desinstalar) = regras::botoes_do_instalador(tela.situacao, &a);
                    if id == ID_INSTALAR && instalar {
                        driver::comecar_aqui(Acao::Instalar);
                    } else if id == ID_DESINSTALAR && desinstalar {
                        driver::comecar_aqui(Acao::Desinstalar);
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
    // Consulta explícita: somente stdout, sem ler/mudar estado de driver ou certificados.
    // O manifesto requireAdministrator continua fazendo o Windows pedir UAC antes do main.
    if std::env::args_os().skip(1).eq([std::ffi::OsString::from("--licencas")]) {
        use std::io::Write;
        if let Err(erro) = std::io::stdout().lock().write_all(LICENCAS.as_bytes()) {
            eprintln!("Quall Studio: não consegui escrever as licenças: {erro}");
            std::process::exit(1);
        }
        return;
    }
    // Nenhuma DLL da pasta de onde o exe foi baixado (Downloads, de quem quer que seja) carrega daqui
    // para a frente; só as do System32.
    unsafe {
        let _ = windows::Win32::System::LibraryLoader::SetDefaultDllDirectories(windows::Win32::System::LibraryLoader::LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    // O idioma: a escolha guardada pelo Quall, se houver; senão, o do Windows. Só leitura.
    let pasta = std::env::var_os("APPDATA").map(std::path::PathBuf::from).unwrap_or_default().join("Quall");
    quall_capture_probe::idioma::iniciar(&pasta);

    let situacao = driver::ler_situacao_do_instalador();
    if let Ok(mut g) = TELA.lock() {
        *g = Some(Tela { situacao, versao_vista: driver::versao(), ticks: 0, textos: Vec::new() });
    }

    let titulo = largo(t(regras::INSTALADOR_TITULO));
    let pergunta = largo(t(regras::CAIXA_PERGUNTA));
    let conteudo = largo(&explicacao(situacao));
    let rodape_inicial = largo(&rodape(situacao, &Andamento::Parado));
    let detalhes = largo("—");
    let rotulo_detalhes = largo(t("Detalhes"));
    let (instalar, desinstalar, fechar) = (largo(t(regras::CAIXA_INSTALAR)), largo(t(regras::CAIXA_DESINSTALAR)), largo(t(regras::INSTALADOR_FECHAR)));
    let botoes = [
        TASKDIALOG_BUTTON { nButtonID: ID_INSTALAR, pszButtonText: PCWSTR(instalar.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_DESINSTALAR, pszButtonText: PCWSTR(desinstalar.as_ptr()) },
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
