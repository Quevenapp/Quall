//! **Um Quall de produto por sessão do Windows** (01/10/2026), só na abertura de produto
//! (`regras_da_bandeja::abertura_de_produto`: o exe aberto sem argumento nenhum).
//!
//! # Por que
//!
//! Com a bandeja, o Quall minimizado some da barra de tarefas, e a pessoa que o procura abre pelo
//! atalho de novo. Antes disto, isso abria um segundo Quall. E isso não é só confuso: **medido no
//! Dell em 01/10, duas instâncias abertas juntas brigaram pelas câmeras virtuais** — a segunda falhou
//! com "MFCreateVirtualCamera: um nó do mesmo nome de uma execução anterior não saiu a tempo", porque
//! cada uma cria um nó por aparelho pareado com o mesmo nome (`baias.rs`), e os dois disputariam
//! também a porta e o anúncio mDNS.
//!
//! # Como
//!
//! - Um mutex nomeado no espaço `Local\` (por sessão: outra conta logada no mesmo PC tem o seu
//!   Quall), com o identificador do app no nome. Quem o cria é a instância de produto, e o segura até
//!   o processo sair (a [`Guarda`] vive até o fim do `main`).
//! - Quem chega e o acha existindo procura a janela principal da outra (a classe da janela, e a
//!   propriedade [`PROPRIEDADE`], que só a janela da instância de produto tem — uma corrida de
//!   bancada aberta ao lado tem a mesma classe), dá a ela o direito de vir para a frente
//!   (`AllowSetForegroundWindow`: quem acabou de ser aberto pelo atalho tem esse direito, e o passa),
//!   manda a mensagem registrada [`MENSAGEM_MOSTRAR`] — que a janela trata como o clique no ícone da
//!   bandeja (`bandeja::restaurar`), escondida ou não —, escreve uma linha no registro e sai com
//!   código 0 **sem abrir nada**: tudo isto roda no começo do `main`, antes do COM, das câmeras
//!   virtuais, do mDNS e da janela.
//! - **A outra sem janela** está abrindo (a janela ainda não nasceu) ou fechando (a janela já se
//!   foi, e o desmonte do `main` ainda roda). Quem chega espera, calado, até
//!   [`regras::ESPERA_CALADA`] (~5 s): se a janela aparecer, chama-a; se o mutex for solto (a outra
//!   saiu), segue como a instância de produto e abre normalmente. Abrir por cima de uma que fecha era
//!   justamente a briga das câmeras.
//! - **Passado o prazo, pergunta** (13/10/2026; o defeito do Dell está em `regras_da_instancia.rs`):
//!   "Outra cópia do Quall está aberta", com Mostrar a outra / Fechar a outra e abrir esta /
//!   Cancelar. Antes disto a caixa só dizia "o Quall ainda está fechando a sessão anterior", e uma
//!   cópia que nunca terminava de fechar deixava o Quall sem abrir para sempre. A caixa segue
//!   olhando: a outra saiu, esta abre; a janela dela (a mesma versão) voltou, esta a chama.
//! - **A outra de versão diferente** (a janela publica a versão em [`PROPRIEDADE_VERSAO`], e o
//!   caminho do executável vem do processo) vai à mesma pergunta, com a janela de pé ou não.
//! - **Fechar a outra** pede (`WM_CLOSE` à janela dela), espera [`regras::ESPERA_PELO_FECHO`] e, se
//!   ela não sair, encerra o processo — só um `quall-app.exe` da mesma sessão e do mesmo usuário
//!   ([`regras::pode_encerrar`]). O mutex dela fica abandonado e passa a esta.
//! - **A outra elevada** (aberta como administrador): o mutex dela não se deixa abrir daqui
//!   (`ERROR_ACCESS_DENIED`), o que também quer dizer "existe". A mensagem de chamar chega mesmo
//!   assim, porque a janela a libera da UIPI (`bandeja::Bandeja::nova`); encerrá-la daqui, não — a
//!   caixa diz isso.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, SetLastError, ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS, ERROR_SUCCESS, HANDLE, HLOCAL, HWND,
    LPARAM, S_OK, WAIT_ABANDONED, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TokenSessionId, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
use windows::Win32::System::Threading::{
    CreateEventW, CreateMutexW, GetCurrentProcessId, OpenEventW, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW, ReleaseMutex, TerminateProcess,
    WaitForSingleObject, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    SYNCHRONIZATION_SYNCHRONIZE,
};
use windows::Win32::UI::Controls::{
    TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOG_BUTTON, TASKDIALOG_NOTIFICATIONS, TDF_ALLOW_DIALOG_CANCELLATION,
    TDF_CALLBACK_TIMER, TDM_CLICK_BUTTON, TDM_ENABLE_BUTTON, TDN_CREATED, TDN_TIMER, TD_WARNING_ICON,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, FindWindowExW, GetPropW, GetWindowThreadProcessId, MessageBoxW, PostMessageW, RegisterWindowMessageW,
    RemovePropW, SendMessageW, SetPropW, MB_ICONINFORMATION, MB_OK, MB_SETFOREGROUND, WM_CLOSE,
};

use crate::registro;
use crate::regras_da_instancia::{self as regras, Alvo, Copia, Eu, Motivo, NaPergunta, Parentesco, Passo, Processo, Recusa, Versao};

/// O mutex da instância de produto, por sessão (`Local\`), com o identificador do app.
const NOME_DO_MUTEX: PCWSTR = w!("Local\\br.com.queven.quall.instancia-de-produto");

/// A classe da janela principal (`janela.rs` a registra com este nome). Mora aqui, e não na janela,
/// para este módulo compilar sem a feature `net`.
pub const CLASSE_DA_JANELA: PCWSTR = w!("QuallAppWindow"); // i18n: fora (classe de janela)

/// A mensagem registrada que pede à janela da instância de produto que volte (`bandeja::restaurar`).
pub const MENSAGEM_MOSTRAR: PCWSTR = w!("Quall-MostrarJanela"); // i18n: fora (nome de mensagem registrada)

/// A propriedade (`SetPropW`) que marca a janela principal da instância de produto.
pub const PROPRIEDADE: PCWSTR = w!("Quall.InstanciaDeProduto"); // i18n: fora (nome de propriedade)

/// A versão da instância de produto, empacotada (`Versao::empacotar`), na janela dela (13/10). Uma
/// janela sem ela é de antes disto.
pub const PROPRIEDADE_VERSAO: PCWSTR = w!("Quall.Versao"); // i18n: fora (nome de propriedade)

/// A versão desta compilação: a do MSI, que `construir-msi.ps1` passa em `QUALL_VERSAO`. Sem ela
/// (uma compilação de bancada), `None`, e só o caminho distingue as cópias.
pub fn versao_desta() -> Option<Versao> {
    option_env!("QUALL_VERSAO").and_then(Versao::ler)
}

/// Este processo é a instância de produto (a janela se marca com [`PROPRIEDADE`]).
static DE_PRODUTO: AtomicBool = AtomicBool::new(false);

pub fn de_produto() -> bool {
    DE_PRODUTO.load(Ordering::SeqCst)
}

/// Marca a janela principal da instância de produto, logo que ela existe: a [`PROPRIEDADE`] e a
/// [`PROPRIEDADE_VERSAO`]. Fora da instância de produto, nada.
pub fn marcar_janela(hwnd: HWND) {
    if !de_produto() {
        return;
    }
    unsafe {
        let _ = SetPropW(hwnd, PROPRIEDADE, Some(HANDLE(1 as *mut core::ffi::c_void)));
        if let Some(v) = versao_desta() {
            let _ = SetPropW(hwnd, PROPRIEDADE_VERSAO, Some(HANDLE(v.empacotar() as usize as *mut core::ffi::c_void)));
        }
    }
}

/// Tira as marcas (no `WM_DESTROY`).
pub fn desmarcar_janela(hwnd: HWND) {
    unsafe {
        let _ = RemovePropW(hwnd, PROPRIEDADE);
        let _ = RemovePropW(hwnd, PROPRIEDADE_VERSAO);
    }
}

/// O mutex, segurado até o fim do `main` (na thread dele: o dono de um mutex é a thread).
pub struct Guarda(Option<HANDLE>);

impl Drop for Guarda {
    fn drop(&mut self) {
        if let Some(h) = self.0.take() {
            unsafe {
                let _ = ReleaseMutex(h);
                let _ = CloseHandle(h);
            }
        }
    }
}

pub enum Instancia {
    /// Esta é a instância de produto (sem mutex, se ele não nasceu: o registro diz, e o app abre).
    Primeira(Guarda),
    /// Outra instância de produto está aberta, e foi chamada, ou a pessoa desistiu: sair.
    OutraAberta,
}

/// **Toma a instância de produto, ou resolve com a que já existe.** Só para a abertura de produto.
pub fn tomar() -> Instancia {
    unsafe {
        // O `CreateMutexW` diz "já existia" pelo `GetLastError` de um retorno bem-sucedido: zerado
        // antes, para um erro velho da thread não passar por esse aviso.
        SetLastError(ERROR_SUCCESS);
        let criado = CreateMutexW(None, true, NOME_DO_MUTEX);
        let erro = GetLastError();
        match criado {
            Ok(h) if erro != ERROR_ALREADY_EXISTS => primeira(Some(h), "esta é a instância de produto"), // i18n: fora (diário)
            Ok(h) => resolver(Some(h)),
            Err(e) if e.code() == ERROR_ACCESS_DENIED.to_hresult() => resolver(None),
            Err(e) => {
                registro::linha(format!("instância única: !! o mutex não nasceu ({e}); o app abre sem a guarda"));
                Instancia::Primeira(Guarda(None))
            }
        }
    }
}

fn primeira(mutex: Option<HANDLE>, porque: &str) -> Instancia {
    DE_PRODUTO.store(true, Ordering::SeqCst);
    registro::linha(format!(
        "instância única: {porque} (versão {})",
        versao_desta().map(|v| v.to_string()).unwrap_or_else(|| "sem QUALL_VERSAO".into())
    ));
    Instancia::Primeira(Guarda(mutex))
}

fn fechar(h: Option<HANDLE>) {
    if let Some(h) = h {
        let _ = unsafe { CloseHandle(h) };
    }
}

/// **O mutex passou a ser desta?** Com o handle, uma espera de 0 ms (solto, ou abandonado por uma
/// outra que morreu). Sem ele (a outra é elevada e o dela não se abre daqui), tenta criá-lo de novo:
/// se a outra saiu, ele nasce desta; se ainda existe e agora se deixa abrir, fica o handle.
fn tentar_tomar(mutex: &mut Option<HANDLE>) -> bool {
    unsafe {
        if mutex.is_none() {
            SetLastError(ERROR_SUCCESS);
            match CreateMutexW(None, true, NOME_DO_MUTEX) {
                Ok(h) if GetLastError() != ERROR_ALREADY_EXISTS => {
                    *mutex = Some(h);
                    return true;
                }
                Ok(h) => *mutex = Some(h),
                Err(_) => return false,
            }
        }
        let Some(h) = *mutex else { return false };
        let r = WaitForSingleObject(h, 0);
        r == WAIT_OBJECT_0 || r == WAIT_ABANDONED
    }
}

/// O que se vê da outra agora: a janela (com o processo dela) e o parentesco com esta.
struct Vista {
    janela: Option<(HWND, u32)>,
    outra: Copia,
    parentesco: Parentesco,
}

fn esta() -> Copia {
    Copia {
        caminho: std::env::current_exe().ok().map(|c| c.display().to_string()),
        versao: versao_desta(),
        com_janela: true,
    }
}

fn olhar(esta: &Copia) -> Vista {
    let janela = janela_da_outra();
    let outra = match janela {
        Some((h, pid)) => Copia { caminho: caminho_do_processo(pid), versao: versao_da_janela(h), com_janela: true },
        // Sem janela, o caminho vem do único `quall-app.exe` da sessão além deste (se for um só).
        None => {
            let eu = eu();
            let aptos: Vec<Processo> = processos_do_quall().into_iter().filter(|p| regras::pode_encerrar(p, &eu).is_ok()).collect();
            let caminho = if aptos.len() == 1 { caminho_do_processo(aptos[0].pid) } else { None };
            Copia { caminho, versao: None, com_janela: false }
        }
    };
    let parentesco = regras::parentesco(esta, &outra);
    Vista { janela, outra, parentesco }
}

/// O nome do evento que marca uma cópia esperando (`Local\…esperando-<pid>`): "Fechar a outra" não a
/// confunde com a que segura o Quall.
fn nome_da_espera(pid: u32) -> windows::core::HSTRING {
    windows::core::HSTRING::from(format!("Local\\br.com.queven.quall.esperando-{pid}")) // i18n: fora (nome de objeto)
}

/// O evento desta cópia enquanto ela espera; solto na volta de [`resolver`].
struct Espera(Option<HANDLE>);

impl Drop for Espera {
    fn drop(&mut self) {
        fechar(self.0.take());
    }
}

/// Outra instância de produto existe: chama a janela dela, espera ela aparecer ou sair, ou pergunta.
fn resolver(mutex: Option<HANDLE>) -> Instancia {
    let nome = nome_da_espera(unsafe { GetCurrentProcessId() });
    let _espera = Espera(unsafe { CreateEventW(None, true, false, &nome) }.ok());
    resolver_esperando(mutex)
}

fn resolver_esperando(mut mutex: Option<HANDLE>) -> Instancia {
    let esta = esta();
    let inicio = Instant::now();
    let mut avisou_a_espera = false;
    loop {
        if tentar_tomar(&mut mutex) {
            return primeira(mutex, "a instância anterior saiu; esta é a instância de produto agora"); // i18n: fora (diário)
        }
        let vista = olhar(&esta);
        match regras::decidir(vista.janela.is_some(), &vista.parentesco, inicio.elapsed()) {
            Passo::Chamar => {
                if let Some((h, _)) = vista.janela {
                    chamar(h);
                }
                fechar(mutex);
                return Instancia::OutraAberta;
            }
            Passo::Esperar => {
                if !avisou_a_espera {
                    avisou_a_espera = true;
                    registro::linha(format!(
                        "instância única: outra instância de produto está aberta sem janela (abrindo ou fechando); esperando até {} s",
                        regras::ESPERA_CALADA.as_secs()
                    ));
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Passo::Perguntar(motivo) => {
                registro::linha(format!(
                    "instância única: !! {:?} — outra pid={:?} caminho={:?} versão={:?} ({:?}); pergunta à pessoa",
                    motivo,
                    vista.janela.map(|j| j.1),
                    vista.outra.caminho,
                    vista.outra.versao.map(|v| v.to_string()),
                    vista.parentesco
                ));
                return perguntar(motivo, mutex, &esta, &vista);
            }
        }
    }
}

// =============================================================================================
// A caixa
// =============================================================================================

const ID_MOSTRAR: i32 = 1001;
const ID_FECHAR_E_ABRIR: i32 = 1002;
const ID_CANCELAR: i32 = 1003;
/// O Esc e o X da caixa (`TDF_ALLOW_DIALOG_CANCELLATION`).
const IDCANCEL: i32 = 2;

/// O que a caixa resolveu sozinha, pelo relógio.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Sozinha {
    Abriu,
    Chamou(HWND),
}

struct Estado<'a> {
    mutex: Option<HANDLE>,
    esta: &'a Copia,
    janela: Option<(HWND, u32)>,
    mostrar_ligado: bool,
    sozinha: Option<Sozinha>,
}

fn ligar_mostrar(h: HWND, ligado: bool) {
    unsafe {
        SendMessageW(h, TDM_ENABLE_BUTTON.0 as u32, Some(WPARAM(ID_MOSTRAR as usize)), Some(LPARAM(ligado as isize)));
    }
}

/// O relógio da caixa (~200 ms): a outra saiu, a janela dela voltou, o "Mostrar" acende ou apaga.
unsafe extern "system" fn ao_avisar(h: HWND, msg: TASKDIALOG_NOTIFICATIONS, _w: WPARAM, _l: LPARAM, dados: isize) -> windows::core::HRESULT {
    let estado = unsafe { &mut *(dados as *mut Estado) };
    if msg == TDN_CREATED {
        estado.mostrar_ligado = estado.janela.is_some();
        ligar_mostrar(h, estado.mostrar_ligado);
    } else if msg == TDN_TIMER && estado.sozinha.is_none() {
        let tomou = tentar_tomar(&mut estado.mutex);
        let vista = if tomou { None } else { Some(olhar(estado.esta)) };
        let com_janela = vista.as_ref().is_some_and(|v| v.janela.is_some());
        let parentesco = vista.as_ref().map(|v| v.parentesco.clone()).unwrap_or(Parentesco::Mesma);
        match regras::durante_a_pergunta(tomou, com_janela, &parentesco) {
            NaPergunta::AbrirAgora => estado.sozinha = Some(Sozinha::Abriu),
            NaPergunta::ChamarAgora => estado.sozinha = vista.as_ref().and_then(|v| v.janela).map(|(j, _)| Sozinha::Chamou(j)),
            NaPergunta::Seguir => {
                estado.janela = vista.and_then(|v| v.janela);
                if estado.mostrar_ligado != estado.janela.is_some() {
                    estado.mostrar_ligado = estado.janela.is_some();
                    ligar_mostrar(h, estado.mostrar_ligado);
                }
            }
        }
        if estado.sozinha.is_some() {
            // Fecha a caixa pelo botão Cancelar; quem a abriu lê `sozinha` antes do botão.
            unsafe {
                SendMessageW(h, TDM_CLICK_BUTTON.0 as u32, Some(WPARAM(ID_CANCELAR as usize)), Some(LPARAM(0)));
            }
        }
    }
    S_OK
}

fn largo(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// **A pergunta**: Mostrar a outra / Fechar a outra e abrir esta / Cancelar.
fn perguntar(motivo: Motivo, mutex: Option<HANDLE>, esta: &Copia, vista: &Vista) -> Instancia {
    use crate::idioma::{t, tf};
    let corpo: Vec<String> = regras::corpo(motivo, &vista.parentesco, esta.versao)
        .into_iter()
        .map(|f| {
            let partes: Vec<&dyn std::fmt::Display> = f.partes.iter().map(|p| p as &dyn std::fmt::Display).collect();
            tf(f.molde, &partes)
        })
        .collect();
    let titulo = largo("Quall"); // i18n: fora (nome do app)
    let (instrucao, corpo) = (largo(t(regras::TITULO)), largo(&corpo.join("\n\n")));
    let mostrar = largo(t(regras::BOTAO_MOSTRAR));
    let fechar_e_abrir = largo(t(regras::BOTAO_FECHAR_E_ABRIR));
    let cancelar = largo(t(regras::BOTAO_CANCELAR));
    let botoes = [
        TASKDIALOG_BUTTON { nButtonID: ID_MOSTRAR, pszButtonText: PCWSTR(mostrar.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_FECHAR_E_ABRIR, pszButtonText: PCWSTR(fechar_e_abrir.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_CANCELAR, pszButtonText: PCWSTR(cancelar.as_ptr()) },
    ];
    let mut estado = Estado { mutex, esta, janela: vista.janela, mostrar_ligado: false, sozinha: None };
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_CALLBACK_TIMER,
        pszWindowTitle: PCWSTR(titulo.as_ptr()),
        Anonymous1: TASKDIALOGCONFIG_0 { pszMainIcon: TD_WARNING_ICON },
        pszMainInstruction: PCWSTR(instrucao.as_ptr()),
        pszContent: PCWSTR(corpo.as_ptr()),
        cButtons: botoes.len() as u32,
        pButtons: botoes.as_ptr(),
        // O padrão é fechar a outra: é o que quer quem abriu o Quall, e a caixa já disse o que acontece.
        nDefaultButton: ID_FECHAR_E_ABRIR,
        pfCallback: Some(ao_avisar),
        lpCallbackData: &mut estado as *mut Estado as isize,
        ..Default::default()
    };
    let mut clicado = 0i32;
    let resultado = unsafe { TaskDialogIndirect(&config, Some(&mut clicado), None, None) };
    let Estado { mutex, janela, sozinha, .. } = estado;
    match (resultado, sozinha) {
        (_, Some(Sozinha::Abriu)) => primeira(mutex, "a outra saiu com a pergunta aberta; esta é a instância de produto agora"), // i18n: fora (diário)
        (_, Some(Sozinha::Chamou(j))) => {
            chamar(j);
            fechar(mutex);
            Instancia::OutraAberta
        }
        (Err(e), None) => {
            registro::linha(format!("instância única: !! a caixa não abriu ({e}); esta sai sem abrir"));
            fechar(mutex);
            avisar(t(regras::FALHA_GERAL));
            Instancia::OutraAberta
        }
        (Ok(()), None) => match clicado {
            ID_MOSTRAR => {
                registro::linha("instância única: a pessoa escolheu Mostrar a outra");
                if let Some((j, _)) = janela {
                    chamar(j);
                }
                fechar(mutex);
                Instancia::OutraAberta
            }
            ID_FECHAR_E_ABRIR => {
                registro::linha("instância única: a pessoa escolheu Fechar a outra e abrir esta");
                fechar_a_outra(mutex, janela)
            }
            _ => {
                registro::linha(format!(
                    "instância única: a pessoa cancelou (botão {clicado}{}); esta sai sem abrir",
                    if clicado == IDCANCEL { ", Esc" } else { "" }
                ));
                fechar(mutex);
                Instancia::OutraAberta
            }
        },
    }
}

fn avisar(frase: &str) {
    let frase = windows::core::HSTRING::from(frase);
    unsafe {
        MessageBoxW(None, PCWSTR(frase.as_ptr()), w!("Quall"), MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND); // i18n: fora (nome do app)
    }
}

/// **Fechar a outra e abrir esta**: o pedido, a espera, e o encerramento como último recurso.
fn fechar_a_outra(mut mutex: Option<HANDLE>, janela: Option<(HWND, u32)>) -> Instancia {
    // O pedido: o mesmo `WM_CLOSE` do X (encerra as sessões e desmonta). Sem janela, ela já está
    // fechando, e só resta esperar.
    if let Some((j, _)) = janela {
        let postou = unsafe { PostMessageW(Some(j), WM_CLOSE, WPARAM(0), LPARAM(0)) }.is_ok();
        registro::linha(format!("instância única: WM_CLOSE à outra {}", if postou { "postado" } else { "!! não foi (UIPI?)" }));
    }
    let fim = Instant::now() + regras::ESPERA_PELO_FECHO;
    while Instant::now() < fim {
        if tentar_tomar(&mut mutex) {
            return primeira(mutex, "a outra fechou a pedido; esta é a instância de produto agora"); // i18n: fora (diário)
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    // O último recurso: encerrar o processo dela.
    let eu = eu();
    let processos = processos_do_quall();
    let alvo = regras::escolher_alvo(janela.map(|j| j.1), &processos, &eu);
    let recusado_por_dono = processos.iter().any(|p| regras::pode_encerrar(p, &eu) == Err(Recusa::OutroDono));
    registro::linha(format!(
        "instância única: a outra não saiu em {} s; alvo {alvo:?} entre {} quall-app.exe",
        regras::ESPERA_PELO_FECHO.as_secs(),
        processos.len()
    ));
    if let Alvo::Um(pid) = alvo {
        if encerrar(pid) {
            // O mutex dela fica abandonado: a espera devolve `WAIT_ABANDONED`, e ele é desta.
            let fim = Instant::now() + Duration::from_secs(3);
            while Instant::now() < fim {
                if tentar_tomar(&mut mutex) {
                    return primeira(mutex, "a outra foi encerrada; esta é a instância de produto agora"); // i18n: fora (diário)
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            registro::linha("instância única: !! a outra foi encerrada e o mutex não veio em 3 s");
        }
    }
    fechar(mutex);
    avisar(crate::idioma::t(regras::falha(alvo, recusado_por_dono)));
    Instancia::OutraAberta
}

/// `TerminateProcess` e a espera do fim (até 5 s).
fn encerrar(pid: u32) -> bool {
    unsafe {
        let h = match OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, false, pid) {
            Ok(h) => h,
            Err(e) => {
                registro::linha(format!("instância única: !! o processo {pid} não se deixou abrir para encerrar ({e})"));
                return false;
            }
        };
        let ok = TerminateProcess(h, 1).is_ok();
        let saiu = ok && WaitForSingleObject(h, 5000) == WAIT_OBJECT_0;
        let _ = CloseHandle(h);
        registro::linha(format!(
            "instância única: TerminateProcess({pid}) {}",
            if saiu {
                "— o processo saiu"
            } else if ok {
                "— !! pedido, e o processo não saiu em 5 s"
            } else {
                "!! falhou"
            }
        ));
        saiu
    }
}

// =============================================================================================
// O Win32 de olhar a outra
// =============================================================================================

/// A janela principal da instância de produto: as janelas de topo da classe do app (escondidas
/// também — a da bandeja está), a que tem a [`PROPRIEDADE`], de outro processo. Com o processo dela.
fn janela_da_outra() -> Option<(HWND, u32)> {
    let eu = unsafe { GetCurrentProcessId() };
    let mut depois: Option<HWND> = None;
    // Um teto, contra uma lista que mudasse debaixo do laço.
    for _ in 0..64 {
        let h = unsafe { FindWindowExW(None, depois, CLASSE_DA_JANELA, PCWSTR::null()) }.ok()?;
        let mut pid = 0u32;
        unsafe {
            GetWindowThreadProcessId(h, Some(&mut pid));
        }
        if pid != eu && !unsafe { GetPropW(h, PROPRIEDADE) }.is_invalid() {
            return Some((h, pid));
        }
        depois = Some(h);
    }
    None
}

fn versao_da_janela(h: HWND) -> Option<Versao> {
    let v = unsafe { GetPropW(h, PROPRIEDADE_VERSAO) };
    Versao::desempacotar(v.0 as usize as u64)
}

/// O caminho do executável de um processo (a consulta limitada se abre até numa cópia elevada).
fn caminho_do_processo(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 1024];
        let mut n = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n);
        let _ = CloseHandle(h);
        r.ok()?;
        Some(String::from_utf16_lossy(&buf[..n as usize]))
    }
}

/// A sessão e o SID do dono de um processo (pelo token; o de uma cópia elevada não se lê daqui).
fn dono(pid: u32) -> (Option<u32>, Option<String>) {
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return (None, None) };
        let mut token = HANDLE::default();
        let aberto = OpenProcessToken(h, TOKEN_QUERY, &mut token).is_ok();
        let _ = CloseHandle(h);
        if !aberto {
            return (None, None);
        }
        let mut n = 0u32;
        let mut id = 0u32;
        let sessao = GetTokenInformation(token, TokenSessionId, Some(&mut id as *mut u32 as *mut core::ffi::c_void), 4, &mut n)
            .ok()
            .map(|_| id);
        let mut buf = vec![0u8; 256];
        let mut usuario = None;
        if GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr() as *mut core::ffi::c_void), buf.len() as u32, &mut n).is_ok() {
            let u = &*(buf.as_ptr() as *const TOKEN_USER);
            let mut s = PWSTR::null();
            if ConvertSidToStringSidW(u.User.Sid, &mut s).is_ok() {
                usuario = s.to_string().ok();
                let _ = LocalFree(Some(HLOCAL(s.0 as *mut core::ffi::c_void)));
            }
        }
        let _ = CloseHandle(token);
        (sessao, usuario)
    }
}

fn eu() -> Eu {
    let pid = unsafe { GetCurrentProcessId() };
    let (sessao, usuario) = dono(pid);
    Eu { pid, sessao, usuario }
}

/// Os `quall-app.exe` da máquina (Toolhelp32), com sessão e dono quando se deixam ler.
fn processos_do_quall() -> Vec<Processo> {
    let mut v = Vec::new();
    unsafe {
        let Ok(foto) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return v };
        let mut e = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut ok = Process32FirstW(foto, &mut e).is_ok();
        while ok {
            let fim = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(e.szExeFile.len());
            let nome = String::from_utf16_lossy(&e.szExeFile[..fim]);
            if nome.eq_ignore_ascii_case(regras::EXECUTAVEL) {
                let (sessao, usuario) = dono(e.th32ProcessID);
                let esperando = match OpenEventW(SYNCHRONIZATION_SYNCHRONIZE, false, &nome_da_espera(e.th32ProcessID)) {
                    Ok(h) => {
                        let _ = CloseHandle(h);
                        true
                    }
                    Err(_) => false,
                };
                v.push(Processo { pid: e.th32ProcessID, nome, sessao, usuario, esperando });
            }
            ok = Process32NextW(foto, &mut e).is_ok();
        }
        let _ = CloseHandle(foto);
    }
    v
}

/// Dá à outra o direito de vir para a frente e pede que a janela volte.
fn chamar(janela: HWND) {
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(janela, Some(&mut pid));
        let deu_a_frente = AllowSetForegroundWindow(pid).is_ok();
        let msg = RegisterWindowMessageW(MENSAGEM_MOSTRAR);
        let postou = msg != 0 && PostMessageW(Some(janela), msg, WPARAM(0), LPARAM(0)).is_ok();
        registro::linha(format!(
            "instância única: o Quall já está aberto (processo {pid}); {} — esta abertura sai sem abrir nada{}",
            if postou { "a janela dele foi chamada" } else { "!! a mensagem para a janela dele não foi" },
            if deu_a_frente { "" } else { " (sem AllowSetForegroundWindow: ela pode só piscar na barra)" }
        ));
    }
}
