//! **As janelas do teleprompter**, em Win32 puro, como o resto do app (a decisão está no
//! cabeçalho de `janela.rs`).
//!
//! # Uma janela, três telas
//!
//! - **a escolha**: "Mostrar o texto neste computador" ou "Controlar um teleprompter". É o que o
//!   botão "Teleprompter" da janela principal abre — a entrada mínima que não mexe no fluxo de
//!   espelhar e exibir;
//! - **o prompter**: o texto rolando na área do meio (Direct2D, `texto.rs`), a faixa de cima com o
//!   PIN e o endereço (`ip:porta`) — sem link nem QR —, e a barra de baixo com os comandos. Teclado
//!   (`regras::acao_da_tecla`): espaço rola/pausa, ↑↓ movem o texto uma linha (segurada, suave; no
//!   sentido de "Inverter botões"), PgUp/PgDn uma tela, Shift+↑↓ velocidade, ←→ pula 5 %, Home volta
//!   ao começo, M espelho, +/− fonte, [ ] margem, `,` `.` linha de leitura, E edita, H esconde as
//!   faixas, F11 e Esc tela cheia. Com o
//!   mouse: a faixa (ou as setas laranjas) move a linha de leitura; perto de uma borda da coluna, as
//!   setas azuis do **enquadramento**; o botão "Fonte automática" liga e desliga a fonte automática
//!   (os dois últimos são ajustes locais, `docs/teleprompter-ajustes-locais.md`); o ícone da tela
//!   cheia, ao lado do Fechar, entra e sai dela (ver `alternar_tela_cheia`);
//! - **o controle**: a lista de prompters do mDNS (só quem anuncia `papel = teleprompter`), o
//!   endereço (IP puro completa com 7979), o PIN; conectado, os comandos,
//!   a barra de progresso da posição e o editor.
//!
//! # O laço, e por que a janela tem thread própria
//!
//! A rolagem desenha **um quadro por retraço**. Com o DWM, `DwmFlush` segura a thread até a
//! próxima composição e o contador de retraços do DWM (`DWM_TIMING_INFO::cRefresh`) diz, quadro a
//! quadro, se a tela repetiu algum — é a medida de "quadros atrasados" que o Mac fez com o
//! `CADisplayLink` (0 em 1347 a 60 Hz). Sem DWM (a Sessão 0 do SSH), o compasso é um relógio de
//! 60 Hz, e a cadência medida é só a do laço. Um relógio de janela (`WM_TIMER`, ~15,6 ms de
//! resolução) não serve para isto, e o relógio de 100 ms da janela principal menos ainda.
//!
//! # A janela não toca na sessão
//!
//! Ela edita a réplica (`Teleprompter::definir_*`, que manda na hora, desta thread) e lê o
//! [`Painel`] que a thread da sessão publica. O `Ready` do núcleo nunca passa por aqui.
//!
//! # O painel do controle rola, e se dispõe sozinho (12/10)
//!
//! O formulário ("Controlar um teleprompter") e o painel conectado saem de
//! `painel_do_controle.rs`: a disposição corre de cima para baixo, cada bloco com a altura que a
//! frase dele pede, e a janela rola quando o conteúdo passa dela. Antes eram y fixos casados à mão
//! entre `posicionar` e a pintura — o relato de 12/10 (tela branca, menor, textos sobrepostos, o
//! último botão fora da janela). A pergunta do texto, os roteiros guardados, o modo segurar e o
//! editor continuam com a geometria deles, nas cores do estúdio.

use std::path::PathBuf;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use windows::core::{w, Result, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmFlush, DwmGetCompositionTimingInfo, DWM_TIMING_INFO};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, GetKeyState, ReleaseCapture, SetCapture, SetFocus, VK_LBUTTON, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use quall_core::teleprompter::{mudou, resumo, Estado, Teleprompter, TETO_DO_TEXTO};

use super::bancada;
use super::geometria::{Cadencia, Deslize, EscolhaDoAlvo, JanelaDaRolagem, Rolagem, TrocaDoAlvo};
use super::painel_do_controle::{self as pdc, Controle as PecaDoPainel, Lugares};
use super::regras::{self, Acao, AcoesDeBancada, AjustesLocais, Avisos, ComandoDoEditor, Enquadramento, Lado, Rascunho};
use super::sessao::{Ambiente, ConfigDoControle, ConfigDoPrompter, Fase, Painel, Sessao};
use super::texto::{self as texto, Cena, Desenho, Diagramado, Diagramador, FonteAutomatica, PedidoDeDiagrama, PedidoDeFonte};
use crate::{descoberta, enderecos, estilo, identidade, idioma, registro};

/// A tela R5 (o texto com a câmera): as peças, a divisão, a gravação e o controle dela.
#[path = "tela_r5.rs"]
mod r5;
pub use r5::ConfigDaTelaR5;

// =============================================================================================
// A configuração e a entrada
// =============================================================================================

/// Como a janela abre. `Default` é o caminho de produto: a tela de escolha, nada automático.
#[derive(Debug, Clone, Default)]
pub struct ConfigDaTela {
    /// Abrir já num papel (bancada: `--teleprompter=prompter|controle`).
    pub papel: Option<Lado>,
    /// Porta do prompter; `0` é [`regras::porta_do_teleprompter`].
    pub porta: u16,
    /// Bancada: o PIN do prompter, ou o PIN que o controle digita.
    pub pin: Option<String>,
    /// Bancada: o controle conecta sozinho neste endereço (`host` ou `host:porta`; um `quall://`
    /// antigo ainda é entendido por `regras::destino_do_controle`, como tolerância).
    pub prompter: Option<String>,
    pub sem_mdns: bool,
    /// Bancada: o prompter sem sessão nenhuma — só o texto rolando, para medir a rolagem sem abrir
    /// porta (e sem o aviso do firewall na sessão interativa).
    pub sem_sessao: bool,
    /// Bancada: o roteiro inicial, lido deste arquivo e aplicado como edição local.
    pub texto: Option<PathBuf>,
    /// Bancada: `--teleprompter-acoes`.
    pub acoes: Option<String>,
    /// Bancada: onde gravar o relato final em JSON.
    pub relato: Option<PathBuf>,
    /// Bancada: fecha a janela N segundos depois de ela abrir, pelo caminho do Fechar.
    pub sair_apos: Option<u64>,
    /// Bancada: o tamanho da área de cliente, em pixels.
    pub tamanho: Option<(i32, i32)>,
    pub bancada: bool,
    /// **A tela R5** (o texto com a câmera, `docs/teleprompter-com-camera.md` §8.10): abre direto
    /// nela (a bancada: `--teleprompter prompter-camera`). O produto chega pelo botão da escolha.
    pub r5: Option<ConfigDaTelaR5>,
    /// **O cartão "Texto com a câmera" da janela principal** (`docs/telas-estudio.md` §7.3): com
    /// `papel = Prompter`, abre direto na tela R5 pelo caminho de produto — o mesmo do botão da
    /// escolha (`abrir_prompter_com_camera` com a configuração padrão), e não o `r5` da bancada.
    pub com_camera: bool,
}

/// A janela aberta agora (uma por processo). Zero: nenhuma.
static ABERTA: AtomicIsize = AtomicIsize::new(0);

/// **A tela espera outra thread** (o fecho da tela R5, `tela_r5.rs::esperar_bombeando`): as mensagens
/// enviadas à janela nesse meio vão ao `DefWindowProcW`, sem tocar na `Tela`, que está emprestada.
static EM_ESPERA: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// **O botão "Teleprompter" da janela principal chama isto.** Abre a janela numa thread própria;
/// se ela já estiver aberta, só a traz para a frente.
pub fn abrir(cfg: ConfigDaTela) {
    let h = ABERTA.load(Ordering::SeqCst);
    if h != 0 {
        unsafe {
            let hwnd = HWND(h as *mut core::ffi::c_void);
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = SetForegroundWindow(hwnd);
        }
        return;
    }
    let _ = std::thread::Builder::new().name("quall.teleprompter.tela".into()).spawn(move || {
        if let Err(e) = correr(cfg) {
            registro::linha(format!("teleprompter: !! a janela não abriu: {e}"));
        }
    });
}

/// Cria a janela e roda o laço dela **nesta** thread, até ela fechar.
pub fn correr(cfg: ConfigDaTela) -> Result<()> {
    unsafe {
        // Direct2D e DirectWrite não pedem COM; o `CoInitializeEx` é para o que a janela chamar
        // de shell. MTA, como o processo (ver `quall_app.rs`).
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let hwnd = criar(cfg)?;
    ABERTA.store(hwnd.0 as isize, Ordering::SeqCst);
    let mut msg = MSG::default();
    'laco: loop {
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    break 'laco;
                }
                if msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN {
                    if let Some(t) = tela_de(hwnd) {
                        // O bit 30 do `lParam`: a tecla já estava descida — é a repetição
                        // automática do teclado, que o "segurar" ignora.
                        let repeticao = (msg.lParam.0 >> 30) & 1 == 1;
                        if t.tecla(hwnd, msg.wParam.0 as u32, repeticao) {
                            continue;
                        }
                    }
                }
                if msg.message == WM_KEYUP || msg.message == WM_SYSKEYUP {
                    if let Some(t) = tela_de(hwnd) {
                        if t.tecla_solta(hwnd, msg.wParam.0 as u32) {
                            continue;
                        }
                    }
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let Some(t) = tela_de(hwnd) else { break };
        t.tique(hwnd);
        let Some(t) = tela_de(hwnd) else { break };
        if t.precisa_de_quadro() {
            t.quadro(hwnd);
        } else {
            t.parou_de_rolar();
            unsafe {
                let _ = MsgWaitForMultipleObjectsEx(None, 30, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            }
        }
    }
    ABERTA.store(0, Ordering::SeqCst);
    Ok(())
}

/// Há uma janela do teleprompter aberta neste processo? (Os cartões da janela principal esperam a
/// janela nova se registrar antes de aceitar outro clique.)
pub fn aberta() -> bool {
    ABERTA.load(Ordering::SeqCst) != 0
}

/// O papel em que a janela aberta está, publicado pela thread dela a cada troca de tela: 0 a
/// escolha, 1 o prompter, 2 o controle, 3 o prompter com a câmera (a tela R5). Só leitura para
/// quem está fora: os cartões da janela principal (`janela.rs`) só trazem a janela para a frente
/// quando o papel pedido é o que ela já mostra, e fecham e reabrem quando é outro.
static PAPEL: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// O papel da janela aberta.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PapelAberto {
    Escolha,
    Prompter,
    Controle,
    PrompterComCamera,
}

/// O papel da janela do teleprompter aberta, ou `None` sem janela.
pub fn papel_aberto() -> Option<PapelAberto> {
    if !aberta() {
        return None;
    }
    Some(match PAPEL.load(Ordering::SeqCst) {
        1 => PapelAberto::Prompter,
        2 => PapelAberto::Controle,
        3 => PapelAberto::PrompterComCamera,
        _ => PapelAberto::Escolha,
    })
}

/// Fecha a janela do teleprompter, se houver uma aberta, **pelo caminho do Fechar** (a sessão
/// cai pela ordem do fim, a réplica é gravada), e espera até `prazo`. A janela principal chama
/// isto ao fechar: sem ele, o processo sairia com a thread do teleprompter no meio.
pub fn fechar_se_aberta(prazo: Duration) -> bool {
    let h = ABERTA.load(Ordering::SeqCst);
    if h == 0 {
        return true;
    }
    unsafe {
        let _ = PostMessageW(Some(HWND(h as *mut core::ffi::c_void)), WM_CLOSE, WPARAM(0), LPARAM(0));
    }
    let fim = Instant::now() + prazo;
    while ABERTA.load(Ordering::SeqCst) != 0 {
        if Instant::now() >= fim {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

fn tela_de(hwnd: HWND) -> Option<&'static mut Tela> {
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return None;
        }
        let p = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Tela;
        p.as_mut()
    }
}

// =============================================================================================
// Os controles e as cores
// =============================================================================================

const WM_ACORDAR: u32 = WM_APP + 1;
/// O diálogo do "Abrir arquivo .txt…" terminou: o resultado está em [`ARQUIVO_DO_ROTEIRO`].
const WM_ARQUIVO_DO_ROTEIRO: u32 = WM_APP + 2;

const ID_MOSTRAR: usize = 201;
const ID_CONTROLAR: usize = 202;
const ID_LISTA: usize = 203;
const ID_ENDERECO: usize = 204;
const ID_PIN: usize = 205;
const ID_CONECTAR: usize = 206;
const ID_VOLTAR: usize = 207;
/// "Procurar de novo" na lista de prompters (`docs/v3-no-privado.md` §8.9).
const ID_PROCURAR_DE_NOVO: usize = 208;
const ID_ROLAR: usize = 210;
const ID_VEL_MENOS: usize = 211;
const ID_VEL_MAIS: usize = 212;
const ID_FONTE_MENOS: usize = 213;
const ID_FONTE_MAIS: usize = 214;
const ID_MARGEM_MENOS: usize = 215;
const ID_MARGEM_MAIS: usize = 216;
const ID_LINHA_ACIMA: usize = 217;
const ID_LINHA_ABAIXO: usize = 218;
const ID_ESPELHO: usize = 219;
const ID_INICIO: usize = 220;
const ID_PULAR_MENOS: usize = 221;
const ID_PULAR_MAIS: usize = 222;
const ID_EDITAR: usize = 223;
const ID_SAIR: usize = 224;
const ID_ESPERAR_DE_NOVO: usize = 225;
const ID_FONTE_AUTO: usize = 226;
const ID_SEGURAR: usize = 227;
const ID_SAIR_DO_SEGURAR: usize = 228;
const ID_INVERTER: usize = 229;
// A pergunta do texto e os roteiros guardados (§11 do contrato).
const ID_USAR_DO_PROMPTER: usize = 250;
const ID_MANDAR_O_MEU: usize = 251;
const ID_ROTEIROS: usize = 252;
/// "Ver", "Usar este" e "Apagar" de cada um dos até três roteiros guardados: 253 + 3 × item + ação.
const ID_ITEM_DOS_ROTEIROS: usize = 253;
const ID_FECHAR_ROTEIROS: usize = 262;
const ID_CONFIRMA_SIM: usize = 263;
const ID_CONFIRMA_NAO: usize = 264;
const ID_VOLTAR_A_LISTA: usize = 265;
// A tela R5 e o gravar do controle.
const ID_MOSTRAR_COM_CAMERA: usize = 270;
const ID_MICROFONE: usize = 271;
const ID_GRAVAR: usize = 272;
const ID_ESCONDER_PREVIA: usize = 273;
const ID_ESPELHO_PREVIA: usize = 274;
const ID_LADO_DO_TEXTO: usize = 275;
const ID_CAMERA: usize = 276;
const ID_GRAVAR_REMOTO: usize = 277;
const ID_AJUSTES_DA_CAMERA: usize = 278;
/// O botão da tela cheia (o prompter e a tela R5; o pedido de 02/10).
const ID_TELA_CHEIA: usize = 279;
/// O "Editar ou colar o roteiro" do bloco "Roteiro" do controle, com ou sem conexão (02/10).
const ID_EDITAR_ROTEIRO: usize = 280;
/// O "Abrir arquivo .txt…" do editor do roteiro (02/10).
const ID_ABRIR_ARQUIVO: usize = 281;
/// **O código de 4 dígitos na tela R5** (`docs/v3-no-privado.md` §3.6): o "Nenhum destes" na faixa;
/// os três números são `ID_CODIGO_NUMERO + 0..3` (o 284 é o Travar fps).
const ID_CODIGO_RECUSAR: usize = 283;
const ID_CODIGO_NUMERO: usize = 285;
const ID_CODIGO_NUMERO_FIM: usize = ID_CODIGO_NUMERO + 2;
/// O "Travar em 30 fps" da faixa da tela R5 (`controles-de-camera.md` §3.1.1, 12/10).
const ID_TRAVAR_FPS: usize = 284;
/// **"Ajustes da câmera do prompter"** no painel do controle (R9b pelo canal do teleprompter,
/// `docs/controle-remoto-da-camera.md` §17): abre a janela "Ajustes da câmera" em modo remoto.
const ID_CAMERA_DO_PROMPTER: usize = 290;
const EM_SETREADONLY: u32 = 0x00CF;
const ID_TEXTO: usize = 230;
const ID_CONFIRMAR: usize = 231;
const ID_CANCELAR: usize = 232;
const ID_USAR_NOVO: usize = 233;
const ID_MANTER_MEU: usize = 234;

const EM_SETLIMITTEXT: u32 = 0x00C5;
const BST_CHECKED: usize = 1;

// **As cores fora do prompter são as do "Estúdio de bolso"** (`telas-estudio.md` §2): o `fundo`, o texto
// claro, o violeta. Até 12/10 a escolha e o controle eram pintados em branco (`FUNDO_CLARO`
// 0xFFFFFF) com tinta escura, e saíam fora do resto do Quall. Os valores moram em
// `painel_do_controle.rs`, que os confere com os tokens de `estilo.rs` num teste.
const FUNDO_DO_PAINEL: COLORREF = COLORREF(pdc::FUNDO_DO_PAINEL);
/// O fundo dos campos de texto e da lista (`superficie`).
const FUNDO_DO_CAMPO: COLORREF = COLORREF(pdc::FUNDO_DO_CAMPO);
/// O fundo do prompter (o texto rolando): fica como era.
const FUNDO_ESCURO: COLORREF = COLORREF(0x00161616);
const TINTA: COLORREF = COLORREF(pdc::TINTA);
const TINTA_FRACA: COLORREF = COLORREF(pdc::TINTA_FRACA);
const TINTA_CLARA: COLORREF = COLORREF(0x00F0F0F0);
const TINTA_CLARA_FRACA: COLORREF = COLORREF(0x00A8A8A8);
/// O violeta claro: rótulos e mensagens sobre o escuro.
const ACENTO: COLORREF = COLORREF(pdc::ACENTO_TEXTO);
/// O violeta cheio: fundo (o botão grande do "segurar" rolando).
const ACENTO_CHEIO: COLORREF = COLORREF(pdc::ACENTO_CHEIO);
/// O laranja dos avisos no fundo escuro (BGR).
const LARANJA: COLORREF = COLORREF(0x001A9EFF);
/// "Atualize o app do prompter": o texto do perigo, legível no escuro.
const ACENTO_VERMELHO: COLORREF = COLORREF(pdc::PERIGO_TEXTO);
/// Os avisos da pergunta: o âmbar de texto do §2.
const LARANJA_ESCURO: COLORREF = COLORREF(pdc::AVISO_TEXTO);
/// A altura de cada roteiro guardado na lista, em unidades de 96 dpi.
const ALTURA_DO_ROTEIRO: i32 = 124;
/// A moldura das caixas da pergunta e o botão grande do "segurar" solto (`superficieAlta`).
const RISCO: COLORREF = COLORREF(pdc::RISCO);

/// Alturas das faixas do prompter, em unidades de 96 dpi.
const FAIXA_DE_CIMA: i32 = 72;
const BARRA_DE_BAIXO: i32 = 46;
const LARGURA_DO_PROMPTER: i32 = 1100;
const ALTURA_DO_PROMPTER: i32 = 720;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Modo {
    Escolha,
    Prompter,
    Controle,
}

/// O que a caixa da pergunta mostra (e o resumo que a escolha leva).
#[derive(Debug, Clone)]
struct PerguntaMostrada {
    prompter_nome: String,
    resumo_do_prompter: String,
    resumo_meu: String,
    previa_do_prompter: String,
    previa_meu: String,
    palavras_do_prompter: usize,
    palavras_meu: usize,
}

/// A lista de "Roteiros guardados": a lista, um roteiro aberto para ler, ou uma confirmação.
#[derive(Debug, Clone, PartialEq)]
enum VistaDosRoteiros {
    Lista,
    Ver(String),
    ConfirmarUsar(String),
    ConfirmarApagar(String),
}

struct Fontes {
    titulo: HFONT,
    grande: HFONT,
    corpo: HFONT,
    pequeno: HFONT,
    rotulo: HFONT,
    /// A fonte dos ícones (Segoe MDL2 Assets, que o Windows 10 e o 11 trazem): a engrenagem dos
    /// ajustes da câmera na faixa da R5 (R9 §4.1).
    icones: HFONT,
}

struct Controles {
    mostrar: HWND,
    controlar: HWND,
    lista: HWND,
    endereco: HWND,
    pin: HWND,
    conectar: HWND,
    voltar: HWND,
    procurar_de_novo: HWND,
    comandos: Vec<(usize, HWND)>,
    /// "Fonte automática": só no prompter (é ajuste local), um botão que fica apertado.
    fonte_auto: HWND,
    /// "Segurar para rolar": liga o modo, na tela do controle conectado.
    segurar: HWND,
    /// A saída pequena do modo, no canto de cima — longe dos dois botões grandes.
    sair_do_segurar: HWND,
    /// "Inverter botões", ao lado da saída: um botão que fica apertado (ligado).
    inverter: HWND,
    /// Os dois botões da caixa da pergunta do texto.
    usar_do_prompter: HWND,
    mandar_o_meu: HWND,
    /// "Roteiros guardados", na tela do controle, com ou sem conexão.
    roteiros: HWND,
    /// "Ver", "Usar este" e "Apagar" de cada roteiro guardado (até três).
    itens_dos_roteiros: Vec<[HWND; 3]>,
    fechar_roteiros: HWND,
    confirma_sim: HWND,
    confirma_nao: HWND,
    voltar_a_lista: HWND,
    sair: HWND,
    esperar_de_novo: HWND,
    texto: HWND,
    confirmar: HWND,
    cancelar: HWND,
    usar_novo: HWND,
    manter_meu: HWND,
    /// "Abrir arquivo .txt…", à esquerda na linha do Confirmar: o texto do arquivo entra no editor
    /// como se fosse colado, e o Confirmar continua sendo quem aplica.
    abrir_arquivo: HWND,
    // A tela R5 (`tela_r5.rs`).
    mostrar_com_camera: HWND,
    microfone: HWND,
    gravar: HWND,
    esconder_previa: HWND,
    espelho_previa: HWND,
    lado_do_texto: HWND,
    camera: HWND,
    /// Na tela de controle: pedir ao prompter que grave ou pare (§13.8).
    gravar_remoto: HWND,
    /// Na tela R5: abre a janela "Ajustes da câmera", sem prévia (R9, `controles-de-camera.md` §4.1).
    ajustes_da_camera: HWND,
    /// Na tela R5: **"Travar em 30 fps"**, o botão do aviso da pouca luz, no fim da linha dos avisos
    /// da faixa (`controles-de-camera.md` §3.1.1). Só com a câmera que tem a trava de fps.
    travar_fps: HWND,
    /// Na tela de controle: **"Ajustes da câmera do prompter"** (§17 do contrato da câmera), só com
    /// a câmera do prompter R5 em `pronto` ou `nao_permitido`.
    camera_do_prompter: HWND,
    /// Na tela R5: os três números do código de 4 dígitos do vídeo e o "Nenhum destes"
    /// (`docs/v3-no-privado.md` §3.6).
    codigo_numeros: [HWND; 3],
    codigo_recusar: HWND,
    /// **A tela cheia** (o prompter e a tela R5): um ícone na barra de comandos, ao lado do Fechar,
    /// que entra e sai — a saída sem teclado (ver `alternar_tela_cheia`).
    tela_cheia: HWND,
    /// A dica do mouse do botão da tela cheia ("Tela cheia" / "Sair da tela cheia").
    dica_da_tela_cheia: HWND,
    /// **O bloco "Roteiro" do controle**: abre o editor de sempre, conectado ou não (o pedido de
    /// 02/10: antes de conectar não havia onde escrever ou colar o roteiro).
    editar_roteiro: HWND,
}

/// Os comandos, na ordem da barra, com o rótulo (a chave em português; o botão mostra
/// `idioma::t(rótulo)`, ver [`Tela::reescrever_rotulos`]).
const COMANDOS: [(usize, &str); 14] = [
    (ID_EDITAR, "Editar"),              // i18n: chave
    (ID_ROLAR, "Rolar"),                // i18n: chave
    (ID_VEL_MENOS, "Vel −"),            // i18n: chave
    (ID_VEL_MAIS, "Vel +"),             // i18n: chave
    (ID_FONTE_MENOS, "A −"),            // i18n: chave
    (ID_FONTE_MAIS, "A +"),             // i18n: chave
    (ID_MARGEM_MENOS, "Margem −"),      // i18n: chave
    (ID_MARGEM_MAIS, "Margem +"),       // i18n: chave
    (ID_LINHA_ACIMA, "Linha ↑"),        // i18n: chave
    (ID_LINHA_ABAIXO, "Linha ↓"),       // i18n: chave
    (ID_ESPELHO, "Espelho"),            // i18n: chave
    (ID_INICIO, "Início"),              // i18n: chave
    (ID_PULAR_MENOS, "◀ 5%"),
    (ID_PULAR_MAIS, "5% ▶"),
];

// =============================================================================================
// O estado da janela
// =============================================================================================

struct Tela {
    cfg: ConfigDaTela,
    modo: Modo,
    lado: Option<Lado>,
    dpi: u32,
    fontes: Fontes,
    c: Controles,
    fundo_do_painel: HBRUSH,
    fundo_escuro: HBRUSH,
    fundo_do_campo: HBRUSH,
    /// O pintor do "Estúdio de bolso" (`estilo::d2d`): o painel do controle e os botões fora do
    /// prompter. Sem ele (o Direct2D não subiu), o GDI de antes, com as mesmas cores.
    pintor: Option<estilo::d2d::Pintor>,
    falha_do_desenho_dita: bool,
    /// Quanto o painel do controle está rolado para cima, em DIP.
    rolagem_do_painel: f32,
    /// A disposição posta por último (os controles nativos estão nestes lugares): a pintura confere.
    controles_postos: Vec<(PecaDoPainel, estilo::Ret)>,
    /// `posicionar` pode ser chamado de dentro dele (a barra de rolagem que aparece manda `WM_SIZE`):
    /// a chamada de dentro só pede outra volta.
    posicionando: bool,
    posicionar_de_novo: bool,
    nome: String,
    aberta_em: Instant,

    // a réplica e a sessão do papel
    teleprompter: Option<Arc<Teleprompter>>,
    sessao: Option<Arc<Sessao>>,
    ambiente: Option<Arc<Ambiente>>,
    estado: Option<Estado>,
    painel: Option<Painel>,
    avisos: Avisos,
    texto: String,
    texto_utf16: Arc<Vec<u16>>,
    geracao_do_texto: u64,

    // a lista do controle
    busca: Option<Arc<descoberta::Busca>>,
    revisao_da_lista: u64,
    prompters: Vec<descoberta::Aparelho>,

    // **O código de 4 dígitos da sessão do teleprompter** (`docs/v3-no-privado.md` §8.5, §8.6 e §8.8),
    // lido do confirmador da sessão a cada tique: no prompter, os três números (o anfitrião escolhe);
    // no controle, o código do toque (o convidado mostra). `aviso_do_codigo`: no prompter, por que o
    // último não fechou, enquanto outro não começa.
    codigo_da_sessao: Option<crate::conexao::CartaoDoCodigo>,
    aviso_do_codigo: Option<&'static str>,

    // o prompter: layout, rolagem, desenho e medida
    desenho: Option<Desenho>,
    diagramador: Option<Diagramador>,
    diagramado: Diagramado,
    pedido: Option<(u64, u32, i32)>,
    proxima_geracao: u64,
    rolagem: Rolagem,
    posicao_pendente: Option<f64>,
    ultimo_quadro: Option<Instant>,
    ultimo_refresh: Option<u64>,
    proximo_prazo: Option<Instant>,
    dwm: Option<bool>,
    periodo_ms: f64,
    cadencia: Cadencia,
    /// A medida de 10 s que vai ao diário (`geometria::JanelaDaRolagem`), e quando ela abriu.
    janela_da_rolagem: JanelaDaRolagem,
    janela_da_rolagem_desde: Option<Instant>,
    /// O alvo do Direct2D escolhido pela medida (`geometria::EscolhaDoAlvo`).
    escolha_do_alvo: EscolhaDoAlvo,
    /// As setas do teclado levando o texto a um alvo (`geometria::Deslize`), parado ou rolando.
    deslize: Option<Deslize>,
    /// O último salto de seta mandado do controle (a repetição sai a no máximo 10 por segundo).
    ultima_seta_no_controle: Option<Instant>,
    ultimo_relato_de_posicao: Instant,
    saltos_aplicados: u64,
    fim_avisado: bool,
    faixas_ocultas: bool,
    /// Em tela cheia: o estilo e o lugar da janela de antes, para a volta.
    tela_cheia: Option<(WINDOW_STYLE, WINDOWPLACEMENT)>,
    tela_acesa: Option<u32>,
    layouts: Vec<(f64, f64, usize, u64)>,
    maior_intervalo_perto_do_layout_ms: f64,
    layout_aplicado_em: Option<Instant>,
    falhas_de_desenho: u32,
    avisou_software: bool,
    /// A tela acesa está pedida (para soltar ao sair).
    tela_acesa_pedida: bool,
    /// **O quadro de trás**: o Direct2D desenha o texto num DIB nosso, e um `BitBlt` o põe na
    /// janela. Ver `desenhar_texto`.
    tras: Option<bancada::Bitmap>,
    /// `BitBlt` do quadro de trás para a janela que falharam (na Sessão 0, sem monitor, todos).
    copias_falhas: u64,
    /// Os intervalos entre quadros de mais de três períodos, com a hora (os 30 primeiros).
    intervalos_longos: Vec<String>,

    // o arrasto da linha de leitura (as setas laranjas)
    arrastando: bool,
    linha_arrastada: Option<f64>,
    limite_do_arrasto: regras::LimiteDeEnvio,
    arrasto_comecou_em: f64,
    arrastos: Vec<String>,
    arrasto_de_bancada: Option<(Instant, f64, f64, u32)>,

    // os ajustes locais do prompter: o enquadramento e a fonte automática
    ajustes: AjustesLocais,
    /// A seta do enquadramento que a pessoa arrasta agora (`0` = a da esquerda do texto).
    enquadrando: Option<usize>,
    enquadramento_no_comeco: (f64, f64),
    arrastos_do_enquadramento: Vec<String>,
    /// Bancada: `(início, qual seta, de, para, passos feitos)`.
    enquadramento_de_bancada: Option<(Instant, usize, f64, f64, u32)>,
    fonte_automatica: Option<FonteAutomatica>,
    /// O último pedido à fonte automática: `(geração do pedido, geração do texto, largura da
    /// coluna em px, dpi)`.
    pedido_da_fonte: Option<(u64, u64, i32, u32)>,
    proxima_geracao_da_fonte: u64,
    /// "Fonte automática desligada: …", até a pessoa apertar o botão de novo.
    aviso_da_fonte: Option<String>,
    fontes_automaticas: Vec<serde_json::Value>,

    // o "segurar para rolar" do controle (§12 do contrato)
    /// Os contatos sobre os dois botões grandes (dedos, mouse, ↑/↓).
    dedos: regras::Dedos,
    /// O último `segurar` recusado, e por quê (`PROTOCOL`: o prompter não entende).
    recusa_do_segurar: Option<regras::Codigo>,
    /// O mouse desceu num botão grande e está com a captura.
    mouse_no_segurar: bool,
    eventos_do_segurar: Vec<String>,
    /// Bancada: onde o `apertar` pôs o mouse (o `soltar` sobe no mesmo ponto).
    ponto_do_mouse_de_bancada: (i32, i32),

    // a pergunta do texto e os roteiros guardados (§11 do contrato)
    /// **O que a caixa está mostrando** — e a escolha leva o resumo **daqui**, nunca um relido na
    /// hora do clique (§11.4: a escolha só vale contra o que a pessoa viu).
    pergunta_mostrada: Option<PerguntaMostrada>,
    /// A última recusa do `resolver_texto` (`BUSY`, `CLOSED`), até a próxima escolha, a sessão
    /// nova ou a pergunta fechar.
    recusa_da_pergunta: Option<regras::Codigo>,
    /// Bancada: a escolha pedida, que sai quando a caixa abrir com os botões ligados.
    escolha_pendente: Option<bool>,
    /// A lista de "Roteiros guardados" na tela, e o que ela mostra.
    roteiros: Option<VistaDosRoteiros>,
    /// Palavras de cada cópia, pelo resumo (contar 128 KB a cada pintura não).
    palavras_das_copias: std::collections::HashMap<String, usize>,
    eventos_da_pergunta: Vec<String>,

    // o editor
    rascunho: Option<Rascunho>,
    mensagem_do_editor: String,

    // a tela
    chave_das_faixas: String,
    mensagem: String,
    ultimo_tique: Instant,
    ultimo_registro: Instant,
    salvar_em: Option<Instant>,
    acordado: bool,

    // a bancada
    acoes: AcoesDeBancada,
    proxima_acao: usize,
    acoes_executadas: u32,
    capturas: Vec<String>,
    eventos_de_aviso: Vec<String>,
    relato_escrito: bool,
    conexao_automatica_feita: bool,

    // a tela R5 (o texto com a câmera)
    r5: Option<Box<r5::TelaR5>>,

    // **R9b pelo canal do teleprompter** (`docs/controle-remoto-da-camera.md` §17)
    /// O dono da câmera da tela R5, para a sessão do teleprompter bombear o filmador dele.
    dono_da_r5: crate::camera_remota::DonoDaR5,
    /// No controle: o controle da câmera do prompter R5, da sessão de agora.
    camera_do_controle: Option<Arc<crate::camera_remota::CameraDoControle>>,
    /// O botão "Ajustes da câmera do prompter" estava à mostra no último `posicionar`.
    camera_do_prompter_mostrada: bool,

    /// A versão do idioma que os rótulos mostram (`idioma::versao`): mudou, o `tique` os reescreve.
    versao_do_idioma: u32,
}

// =============================================================================================
// Criar a janela
// =============================================================================================

fn criar(cfg: ConfigDaTela) -> Result<HWND> {
    unsafe {
        let hinstance = GetModuleHandleW(None)?;
        let classe = w!("QuallTeleprompter");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: hinstance.into(),
            lpszClassName: classe,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            ..Default::default()
        };
        let _ = RegisterClassW(&wc);
        // **O tamanho só depois de a janela existir** (o molde de `janela.rs::criar_a_janela`): o DPI
        // que vale é o do monitor em que ela nasce. Até 12/10 a conta era feita antes, com o DPI da
        // janela da área de trabalho (`GetDpiForWindow(GetDesktopWindow())`) e o `AdjustWindowRect`
        // do DPI do sistema, enquanto as fontes e as posições usavam o da janela: com os dois
        // diferentes, a janela saía menor que o conteúdo (o relato de 12/10).
        let estilo = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            classe,
            // O título é posto por `aplicar_titulo` (no idioma de agora), na troca de tela.
            PCWSTR::null(),
            estilo,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            None,
            None,
            Some(hinstance.into()),
            None,
        )?;
        crate::decoracao::aplicar(hwnd);
        let dpi = GetDpiForWindow(hwnd).max(96);
        dimensionar_ao_abrir(hwnd, dpi, &cfg);
        crate::janela::escurecer_a_barra_de_titulo(hwnd);
        // A barra de rolagem do painel do controle, escura como a da lista da janela principal.
        let _ = windows::Win32::UI::Controls::SetWindowTheme(hwnd, w!("DarkMode_Explorer"), PCWSTR::null());
        let fontes = Fontes {
            titulo: fonte(dpi, 20, FW_SEMIBOLD.0 as i32),
            grande: fonte(dpi, 26, FW_BOLD.0 as i32),
            corpo: fonte(dpi, 12, FW_SEMIBOLD.0 as i32),
            pequeno: fonte(dpi, 10, FW_NORMAL.0 as i32),
            rotulo: fonte(dpi, 9, FW_BOLD.0 as i32),
            icones: fonte_de_icones(dpi, 13),
        };
        let botao = |texto: PCWSTR, id: usize| filho(hwnd, w!("BUTTON"), texto, BOTAO, id);
        // **Os rótulos nascem vazios** e são postos logo abaixo, no idioma de agora, por
        // `reescrever_rotulos` — a mesma função que os reescreve quando o idioma muda (o seletor
        // "PT | EN" da janela principal). Os dinâmicos (Rolar/Pausar, Fechar/Desconectar, os da tela
        // R5, o do gravar no prompter) são postos por `posicionar`.
        let vazio = PCWSTR::null();
        let mut comandos = Vec::new();
        for (id, _) in COMANDOS {
            comandos.push((id, botao(vazio, id)?));
        }
        let c = Controles {
            mostrar: botao(vazio, ID_MOSTRAR)?,
            controlar: botao(vazio, ID_CONTROLAR)?,
            lista: filho(hwnd, w!("LISTBOX"), PCWSTR::null(), LISTA, ID_LISTA)?,
            endereco: filho(hwnd, w!("EDIT"), PCWSTR::null(), CAMPO, ID_ENDERECO)?,
            pin: filho(hwnd, w!("EDIT"), PCWSTR::null(), CAMPO, ID_PIN)?,
            conectar: filho(hwnd, w!("BUTTON"), vazio, BOTAO_PADRAO, ID_CONECTAR)?,
            voltar: botao(vazio, ID_VOLTAR)?,
            procurar_de_novo: botao(vazio, ID_PROCURAR_DE_NOVO)?,
            comandos,
            fonte_auto: filho(hwnd, w!("BUTTON"), vazio, BOTAO_QUE_FICA, ID_FONTE_AUTO)?,
            segurar: botao(vazio, ID_SEGURAR)?,
            sair_do_segurar: botao(vazio, ID_SAIR_DO_SEGURAR)?,
            inverter: filho(hwnd, w!("BUTTON"), vazio, BOTAO_QUE_FICA, ID_INVERTER)?,
            usar_do_prompter: botao(vazio, ID_USAR_DO_PROMPTER)?,
            mandar_o_meu: botao(vazio, ID_MANDAR_O_MEU)?,
            roteiros: botao(vazio, ID_ROTEIROS)?,
            itens_dos_roteiros: {
                let mut v = Vec::new();
                for i in 0..quall_core::teleprompter::COPIAS_DO_TEXTO {
                    let base = ID_ITEM_DOS_ROTEIROS + 3 * i;
                    v.push([botao(vazio, base)?, botao(vazio, base + 1)?, botao(vazio, base + 2)?]);
                }
                v
            },
            fechar_roteiros: botao(vazio, ID_FECHAR_ROTEIROS)?,
            confirma_sim: botao(vazio, ID_CONFIRMA_SIM)?,
            confirma_nao: botao(vazio, ID_CONFIRMA_NAO)?,
            voltar_a_lista: botao(vazio, ID_VOLTAR_A_LISTA)?,
            sair: botao(vazio, ID_SAIR)?,
            esperar_de_novo: botao(vazio, ID_ESPERAR_DE_NOVO)?,
            texto: filho(hwnd, w!("EDIT"), PCWSTR::null(), EDITOR, ID_TEXTO)?,
            confirmar: filho(hwnd, w!("BUTTON"), vazio, BOTAO_PADRAO, ID_CONFIRMAR)?,
            cancelar: botao(vazio, ID_CANCELAR)?,
            usar_novo: botao(vazio, ID_USAR_NOVO)?,
            manter_meu: botao(vazio, ID_MANTER_MEU)?,
            abrir_arquivo: botao(vazio, ID_ABRIR_ARQUIVO)?,
            mostrar_com_camera: botao(vazio, ID_MOSTRAR_COM_CAMERA)?,
            microfone: botao(vazio, ID_MICROFONE)?,
            gravar: botao(vazio, ID_GRAVAR)?,
            esconder_previa: filho(hwnd, w!("BUTTON"), vazio, BOTAO_QUE_FICA, ID_ESCONDER_PREVIA)?,
            espelho_previa: filho(hwnd, w!("BUTTON"), vazio, BOTAO_QUE_FICA, ID_ESPELHO_PREVIA)?,
            lado_do_texto: botao(vazio, ID_LADO_DO_TEXTO)?,
            camera: filho(
                hwnd,
                w!("COMBOBOX"),
                PCWSTR::null(),
                WINDOW_STYLE(WS_CHILD.0 | WS_TABSTOP.0 | WS_VSCROLL.0 | CBS_DROPDOWNLIST as u32),
                ID_CAMERA,
            )?,
            gravar_remoto: botao(vazio, ID_GRAVAR_REMOTO)?,
            // **A engrenagem** (U+E713, R9 §4.1): só o ícone, e o nome para o Narrador é dado pelo
            // `IAccPropServices` (logo abaixo). A faixa da R5 do Windows não tem outro botão de
            // ajustes com engrenagem: os do teleprompter são texto ("Espelho", "A +", "Margem +"…).
            ajustes_da_camera: botao(w!("\u{E713}"), ID_AJUSTES_DA_CAMERA)?,
            travar_fps: botao(vazio, ID_TRAVAR_FPS)?,
            camera_do_prompter: botao(vazio, ID_CAMERA_DO_PROMPTER)?,
            codigo_numeros: [botao(vazio, ID_CODIGO_NUMERO)?, botao(vazio, ID_CODIGO_NUMERO + 1)?, botao(vazio, ID_CODIGO_NUMERO + 2)?],
            codigo_recusar: botao(vazio, ID_CODIGO_RECUSAR)?,
            // **A tela cheia**: o glifo da Segoe (`estilo::Icone::TelaCheia`, as setas para fora), o
            // nome para o Narrador e a dica do mouse, trocados a cada entrada e saída.
            editar_roteiro: botao(vazio, ID_EDITAR_ROTEIRO)?,
            tela_cheia: {
                let g: Vec<u16> = regras::icone_da_tela_cheia(false).glifo().to_string().encode_utf16().chain(std::iter::once(0)).collect();
                botao(PCWSTR(g.as_ptr()), ID_TELA_CHEIA)?
            },
            dica_da_tela_cheia: {
                // A classe do tooltip é do comctl32: registrada aqui, antes de criar (sem ela o
                // `CreateWindowExW` falha e o botão fica só com o nome para o Narrador).
                use windows::Win32::UI::Controls::{InitCommonControlsEx, ICC_BAR_CLASSES, INITCOMMONCONTROLSEX};
                let icc = INITCOMMONCONTROLSEX { dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_BAR_CLASSES };
                let _ = InitCommonControlsEx(&icc);
                CreateWindowExW(
                    WS_EX_TOPMOST,
                    windows::Win32::UI::Controls::TOOLTIPS_CLASSW,
                    PCWSTR::null(),
                    WINDOW_STYLE(WS_POPUP.0 | windows::Win32::UI::Controls::TTS_ALWAYSTIP | windows::Win32::UI::Controls::TTS_NOPREFIX),
                    CW_USEDEFAULT,
                    CW_USEDEFAULT,
                    CW_USEDEFAULT,
                    CW_USEDEFAULT,
                    Some(hwnd),
                    None,
                    Some(hinstance.into()),
                    None,
                )
                .unwrap_or_else(|e| {
                    registro::linha(format!("teleprompter: a dica do botão da tela cheia não nasceu ({e}); fica o nome para o Narrador"));
                    HWND::default()
                })
            },
        };
        // A barra de rolagem da lista no escuro (o mesmo da lista da janela principal).
        let _ = windows::Win32::UI::Controls::SetWindowTheme(c.lista, w!("DarkMode_Explorer"), PCWSTR::null());
        // A dica do mouse da tela cheia também (13/10, a mesma da janela do vídeo): no tema claro do
        // Windows ela saía branca.
        if !c.dica_da_tela_cheia.is_invalid() {
            let _ = windows::Win32::UI::Controls::SetWindowTheme(c.dica_da_tela_cheia, w!("DarkMode_Explorer"), PCWSTR::null());
        }
        // O PIN tem seis dígitos; o roteiro, até o teto do núcleo (em caracteres, o dobro cobre).
        SendMessageW(c.pin, EM_SETLIMITTEXT, Some(WPARAM(6)), None);
        // Os nomes do Narrador e a dica são postos por `reescrever_rotulos` (a dica nasce aqui, com a
        // ferramenta, e depois só troca de texto).
        dica_do_botao(c.dica_da_tela_cheia, hwnd, c.tela_cheia, idioma::t(regras::rotulo_da_tela_cheia(false)), true);
        SendMessageW(c.texto, EM_SETLIMITTEXT, Some(WPARAM(TETO_DO_TEXTO * 2)), None);
        let nome = identidade::nome_do_aparelho();
        let tela = Box::new(Tela {
            modo: Modo::Escolha,
            lado: None,
            dpi,
            fontes,
            c,
            fundo_do_painel: CreateSolidBrush(FUNDO_DO_PAINEL),
            fundo_escuro: CreateSolidBrush(FUNDO_ESCURO),
            fundo_do_campo: CreateSolidBrush(FUNDO_DO_CAMPO),
            pintor: match estilo::d2d::Pintor::novo() {
                Ok(p) => Some(p),
                Err(e) => {
                    registro::linha(format!("teleprompter: !! o Direct2D do painel não subiu ({e}); o painel fica no GDI"));
                    None
                }
            },
            falha_do_desenho_dita: false,
            rolagem_do_painel: 0.0,
            controles_postos: Vec::new(),
            posicionando: false,
            posicionar_de_novo: false,
            nome,
            aberta_em: Instant::now(),
            teleprompter: None,
            sessao: None,
            ambiente: None,
            estado: None,
            painel: None,
            avisos: Avisos::default(),
            texto: String::new(),
            texto_utf16: Arc::new(Vec::new()),
            geracao_do_texto: 0,
            busca: None,
            revisao_da_lista: 0,
            prompters: Vec::new(),
            codigo_da_sessao: None,
            aviso_do_codigo: None,
            desenho: None,
            diagramador: None,
            diagramado: Diagramado::vazio(),
            pedido: None,
            proxima_geracao: 1,
            rolagem: Rolagem::default(),
            posicao_pendente: None,
            ultimo_quadro: None,
            ultimo_refresh: None,
            proximo_prazo: None,
            dwm: None,
            periodo_ms: 1000.0 / 60.0,
            cadencia: Cadencia::nova(1000.0 / 60.0),
            janela_da_rolagem: JanelaDaRolagem::nova(1000.0 / 60.0),
            janela_da_rolagem_desde: None,
            escolha_do_alvo: EscolhaDoAlvo::Padrao,
            deslize: None,
            ultima_seta_no_controle: None,
            ultimo_relato_de_posicao: Instant::now(),
            saltos_aplicados: 0,
            fim_avisado: false,
            faixas_ocultas: false,
            tela_cheia: None,
            tela_acesa: None,
            layouts: Vec::new(),
            maior_intervalo_perto_do_layout_ms: 0.0,
            layout_aplicado_em: None,
            falhas_de_desenho: 0,
            avisou_software: false,
            tela_acesa_pedida: false,
            tras: None,
            copias_falhas: 0,
            intervalos_longos: Vec::new(),
            arrastando: false,
            linha_arrastada: None,
            limite_do_arrasto: regras::LimiteDeEnvio::default(),
            arrasto_comecou_em: 0.0,
            arrastos: Vec::new(),
            arrasto_de_bancada: None,
            ajustes: AjustesLocais::default(),
            enquadrando: None,
            enquadramento_no_comeco: (0.0, 1.0),
            arrastos_do_enquadramento: Vec::new(),
            enquadramento_de_bancada: None,
            fonte_automatica: None,
            pedido_da_fonte: None,
            proxima_geracao_da_fonte: 1,
            aviso_da_fonte: None,
            fontes_automaticas: Vec::new(),
            dedos: regras::Dedos::default(),
            recusa_do_segurar: None,
            mouse_no_segurar: false,
            eventos_do_segurar: Vec::new(),
            ponto_do_mouse_de_bancada: (0, 0),
            pergunta_mostrada: None,
            recusa_da_pergunta: None,
            escolha_pendente: None,
            roteiros: None,
            palavras_das_copias: std::collections::HashMap::new(),
            eventos_da_pergunta: Vec::new(),
            rascunho: None,
            mensagem_do_editor: String::new(),
            chave_das_faixas: String::new(),
            mensagem: String::new(),
            ultimo_tique: Instant::now(),
            ultimo_registro: Instant::now(),
            salvar_em: None,
            acordado: true,
            acoes: AcoesDeBancada::default(),
            proxima_acao: 0,
            acoes_executadas: 0,
            capturas: Vec::new(),
            eventos_de_aviso: Vec::new(),
            relato_escrito: false,
            conexao_automatica_feita: false,
            r5: None,
            dono_da_r5: Arc::new(Mutex::new(None)),
            camera_do_controle: None,
            camera_do_prompter_mostrada: false,
            versao_do_idioma: idioma::versao(),
            cfg,
        });
        let ptr = Box::into_raw(tela);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, ptr as isize);
        let t = &mut *ptr;
        t.reescrever_rotulos(hwnd);
        t.aplicar_fontes();
        match t.cfg.papel {
            Some(Lado::Prompter) if t.cfg.r5.is_some() || t.cfg.com_camera => t.abrir_prompter_com_camera(hwnd),
            Some(Lado::Prompter) => t.abrir_prompter(hwnd),
            Some(Lado::Controle) => t.abrir_controle(hwnd),
            None => t.mudar_de_modo(hwnd, Modo::Escolha),
        }
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        t.aplicar_tela_cheia_lembrada(hwnd);
        if let Some(acoes) = t.cfg.acoes.clone() {
            t.acoes = AcoesDeBancada::ler(&acoes, |c| std::fs::read_to_string(c).ok());
            for r in &t.acoes.recusadas {
                registro::linha(format!("teleprompter: !! ação de bancada ilegível: {r}"));
            }
            registro::linha(format!("teleprompter: bancada: {} ação(ões) agendada(s)", t.acoes.acoes.len()));
        }
        let mut cliente = RECT::default();
        let _ = GetClientRect(hwnd, &mut cliente);
        registro::linha(format!(
            "teleprompter: janela aberta handle={} cliente={}x{} dpi={} modo={:?}",
            hwnd.0 as isize,
            cliente.right,
            cliente.bottom,
            dpi,
            t.modo,
        ));
        Ok(hwnd)
    }
}

const BOTAO: WINDOW_STYLE = WINDOW_STYLE(WS_CHILD.0 | WS_TABSTOP.0 | BS_PUSHBUTTON as u32);
const BOTAO_PADRAO: WINDOW_STYLE = WINDOW_STYLE(WS_CHILD.0 | WS_TABSTOP.0 | BS_DEFPUSHBUTTON as u32);
/// Um botão que fica apertado (liga e desliga): a caixa de marcar com cara de botão.
const BOTAO_QUE_FICA: WINDOW_STYLE = WINDOW_STYLE(WS_CHILD.0 | WS_TABSTOP.0 | BS_AUTOCHECKBOX as u32 | BS_PUSHLIKE as u32);
// A lista e os campos sem a borda do Windows: a borda é a do cartão e do campo desenhados em volta
// (`painel_do_controle.rs`), como na janela principal.
const LISTA: WINDOW_STYLE = WINDOW_STYLE(
    WS_CHILD.0 | WS_TABSTOP.0 | WS_VSCROLL.0 | LBS_NOTIFY as u32 | LBS_HASSTRINGS as u32 | LBS_NOINTEGRALHEIGHT as u32,
);
const CAMPO: WINDOW_STYLE = WINDOW_STYLE(WS_CHILD.0 | WS_TABSTOP.0 | ES_AUTOHSCROLL as u32);
const EDITOR: WINDOW_STYLE = WINDOW_STYLE(
    WS_CHILD.0
        | WS_TABSTOP.0
        | WS_BORDER.0
        | WS_VSCROLL.0
        | ES_MULTILINE as u32
        | ES_WANTRETURN as u32
        | ES_AUTOVSCROLL as u32
        | ES_NOHIDESEL as u32,
);

unsafe fn filho(pai: HWND, classe: PCWSTR, texto: PCWSTR, estilo: WINDOW_STYLE, id: usize) -> Result<HWND> {
    unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            classe,
            texto,
            estilo,
            0,
            0,
            10,
            10,
            Some(pai),
            Some(HMENU(id as *mut core::ffi::c_void)),
            None,
            None,
        )
    }
}

fn fonte(dpi: u32, pontos: i32, peso: i32) -> HFONT {
    unsafe {
        CreateFontW(
            -(pontos * dpi as i32) / 72,
            0,
            0,
            0,
            peso,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (FF_DONTCARE.0 | VARIABLE_PITCH.0) as u32,
            w!("Segoe UI"),
        )
    }
}

/// A fonte dos ícones do Windows (os glifos da área de uso privado, como a engrenagem U+E713).
fn fonte_de_icones(dpi: u32, pontos: i32) -> HFONT {
    unsafe {
        CreateFontW(
            -(pontos * dpi as i32) / 72,
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (FF_DONTCARE.0 | VARIABLE_PITCH.0) as u32,
            w!("Segoe MDL2 Assets"),
        )
    }
}

/// **O nome de um botão só de ícone para o Narrador** (o texto da janela dele é o glifo).
fn dar_nome(h: HWND, nome: &str) {
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Accessibility::{CLSID_AccPropServices, IAccPropServices, PROPID_ACC_NAME};
    let servicos: Option<IAccPropServices> = unsafe { CoCreateInstance(&CLSID_AccPropServices, None, CLSCTX_INPROC_SERVER).ok() };
    let Some(s) = servicos else {
        registro::linha(format!("teleprompter: o IAccPropServices não veio; \"{nome}\" fica sem nome para o Narrador"));
        return;
    };
    let largo: Vec<u16> = nome.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let _ = s.SetHwndPropStr(h, OBJID_CLIENT.0 as u32, CHILDID_SELF, PROPID_ACC_NAME, PCWSTR(largo.as_ptr()));
    }
}

/// **A dica do mouse** de um botão só de ícone (a tela cheia): a primeira vez acrescenta a
/// ferramenta (`TTF_SUBCLASS`: o tooltip vê o mouse sobre o botão sozinho), depois só troca o
/// texto. Sem a janela do tooltip (não nasceu), nada — o nome para o Narrador continua.
fn dica_do_botao(dica: HWND, dono: HWND, botao: HWND, texto: &str, primeira: bool) {
    use windows::Win32::UI::Controls::{TTF_IDISHWND, TTF_SUBCLASS, TTM_ADDTOOLW, TTM_UPDATETIPTEXTW, TTTOOLINFOW};
    if dica.is_invalid() {
        return;
    }
    let mut largo: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
    let info = TTTOOLINFOW {
        cbSize: std::mem::size_of::<TTTOOLINFOW>() as u32,
        uFlags: TTF_IDISHWND | TTF_SUBCLASS,
        hwnd: dono,
        uId: botao.0 as usize,
        lpszText: windows::core::PWSTR(largo.as_mut_ptr()),
        ..Default::default()
    };
    unsafe {
        SendMessageW(
            dica,
            if primeira { TTM_ADDTOOLW } else { TTM_UPDATETIPTEXTW },
            None,
            Some(LPARAM(&info as *const TTTOOLINFOW as isize)),
        );
    }
}

fn escala(dpi: u32, v: i32) -> i32 {
    v * dpi as i32 / 96
}

/// DIP em pixels, arredondado (o mesmo de `janela_dos_ajustes.rs`).
fn escala_f(dpi: u32, v: f32) -> i32 {
    (v * dpi as f32 / 96.0).round() as i32
}

/// Um retângulo do painel (DIP) em pixels, borda por borda: dois retângulos que se encostam em DIP
/// continuam se encostando em pixels (`painel_do_controle.rs`, o teste das três escalas).
fn em_pixels(dpi: u32, r: estilo::Ret) -> RECT {
    RECT { left: escala_f(dpi, r.x), top: escala_f(dpi, r.y), right: escala_f(dpi, r.x + r.l), bottom: escala_f(dpi, r.y + r.a) }
}

/// A área de trabalho do monitor da janela: o retângulo em pixels e o tamanho em DIP.
fn area_de_trabalho(hwnd: HWND, dpi: u32) -> Option<(RECT, (f32, f32))> {
    unsafe {
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return None;
        }
        let w = info.rcWork;
        let k = dpi as f32 / 96.0;
        Some((w, ((w.right - w.left) as f32 / k, (w.bottom - w.top) as f32 / k)))
    }
}

/// A moldura da janela (barra de título e bordas) no `dpi`, em DIP: o que a janela tem além da área
/// de cliente.
fn moldura_em_dip(hwnd: HWND, dpi: u32) -> (f32, f32) {
    let mut r = RECT::default();
    unsafe {
        let estilo = WINDOW_STYLE(GetWindowLongPtrW(hwnd, GWL_STYLE) as u32);
        let _ = AdjustWindowRectExForDpi(&mut r, estilo, false, WINDOW_EX_STYLE(0), dpi);
    }
    let k = dpi as f32 / 96.0;
    ((r.right - r.left) as f32 / k, (r.bottom - r.top) as f32 / k)
}

/// A área de cliente `(l, a)` em pixels vira o tamanho da janela, com a moldura do `dpi`.
fn janela_para_o_cliente(hwnd: HWND, dpi: u32, l: i32, a: i32) -> (i32, i32) {
    let mut r = RECT { left: 0, top: 0, right: l, bottom: a };
    unsafe {
        let estilo = WINDOW_STYLE(GetWindowLongPtrW(hwnd, GWL_STYLE) as u32);
        let _ = AdjustWindowRectExForDpi(&mut r, estilo, false, WINDOW_EX_STYLE(0), dpi);
    }
    (r.right - r.left, r.bottom - r.top)
}

/// **O tamanho da janela ao abrir**: o pedido do papel (o prompter, ou o controle e a escolha), mas
/// nunca maior que a área de trabalho do monitor — a 150 % num monitor de 1080 linhas a janela de
/// 660 DIP + a moldura não cabia, e o pé (o último botão) ficava fora da tela. A posição é puxada
/// para dentro da área de trabalho. O `--tamanho` da bancada é em pixels e vale como veio.
fn dimensionar_ao_abrir(hwnd: HWND, dpi: u32, cfg: &ConfigDaTela) {
    let area = area_de_trabalho(hwnd, dpi);
    let (cl, ca) = match cfg.tamanho {
        Some((w, h)) => (w, h),
        None => {
            let pedido = match cfg.papel {
                Some(Lado::Prompter) => (LARGURA_DO_PROMPTER as f32, ALTURA_DO_PROMPTER as f32),
                _ => (pdc::LARGURA_PADRAO, pdc::ALTURA_PADRAO),
            };
            let (l, a) = match &area {
                Some((_, trabalho)) => pdc::cliente_que_cabe(pedido, *trabalho, moldura_em_dip(hwnd, dpi)),
                None => pedido,
            };
            (escala_f(dpi, l), escala_f(dpi, a))
        }
    };
    let (w, h) = janela_para_o_cliente(hwnd, dpi, cl, ca);
    let mut atual = RECT::default();
    unsafe {
        let _ = GetWindowRect(hwnd, &mut atual);
    }
    let (mut x, mut y) = (atual.left, atual.top);
    if let Some((t, _)) = area {
        x = x.min(t.right - w).max(t.left);
        y = y.min(t.bottom - h).max(t.top);
    }
    unsafe {
        let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

fn mostrar(h: HWND, visivel: bool) {
    unsafe {
        let _ = ShowWindow(h, if visivel { SW_SHOW } else { SW_HIDE });
    }
}

fn texto_de(h: HWND) -> String {
    unsafe {
        let n = GetWindowTextLengthW(h).max(0) as usize;
        let mut b = vec![0u16; n + 1];
        let lido = GetWindowTextW(h, &mut b).max(0) as usize;
        String::from_utf16_lossy(&b[..lido.min(n)])
    }
}

fn por_texto(h: HWND, s: &str) {
    let largo = em_utf16(s);
    unsafe {
        let _ = SetWindowTextW(h, PCWSTR(largo.as_ptr()));
    }
}

/// O texto em UTF-16 terminado em zero (o `w!()` só aceita literal; um texto traduzido vem daqui).
fn em_utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// O controle `EDIT` quer `\r\n`; a réplica guarda `\n`.
fn para_o_editor(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\n', "\r\n")
}

fn do_editor(s: &str) -> String {
    s.replace("\r\n", "\n")
}

/// O que o diálogo do "Abrir arquivo .txt…" devolveu.
enum ArquivoDoRoteiro {
    Cancelado,
    /// O diálogo nem abriu (COM, ou o `IFileOpenDialog`).
    SemDialogo(String),
    Lido(PathBuf, std::result::Result<String, regras::RecusaDoArquivo>),
}

/// Um diálogo de abrir por vez (o segundo clique, com ele aberto, não faz nada).
static DIALOGO_DO_ROTEIRO: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// O resultado do diálogo, entregue à thread da janela pelo [`WM_ARQUIVO_DO_ROTEIRO`].
static ARQUIVO_DO_ROTEIRO: std::sync::Mutex<Option<ArquivoDoRoteiro>> = std::sync::Mutex::new(None);

/// O arquivo do disco, pelo teto: acima de [`regras::maior_arquivo_lido`] nem é lido.
fn ler_roteiro_do_disco(caminho: &std::path::Path) -> std::result::Result<String, regras::RecusaDoArquivo> {
    let tamanho = std::fs::metadata(caminho).map_err(|e| regras::RecusaDoArquivo::Leitura(e.to_string()))?.len() as usize;
    if tamanho > regras::maior_arquivo_lido(TETO_DO_TEXTO) {
        return Err(regras::RecusaDoArquivo::Grande(tamanho));
    }
    let bruto = std::fs::read(caminho).map_err(|e| regras::RecusaDoArquivo::Leitura(e.to_string()))?;
    regras::roteiro_do_arquivo(&bruto, TETO_DO_TEXTO)
}

/// O `IFileOpenDialog`, **nesta** thread, que entra em STA só para ele e sai no fim. `Ok(None)` é o
/// Cancelar da pessoa.
fn escolher_arquivo_de_roteiro(dona: HWND) -> std::result::Result<Option<PathBuf>, String> {
    use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE};
    use windows::Win32::UI::Shell::Common::COMDLG_FILTERSPEC;
    use windows::Win32::UI::Shell::{FileOpenDialog, IFileOpenDialog, FOS_FILEMUSTEXIST, FOS_FORCEFILESYSTEM, SIGDN_FILESYSPATH};
    unsafe {
        let com = CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        if com.is_err() {
            return Err(format!("CoInitializeEx(STA): {com:?}"));
        }
        let r = (|| -> windows::core::Result<Option<PathBuf>> {
            let d: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
            // Os nomes dos filtros e o título, no idioma de agora (os vetores vivem até o `Show`).
            let (nome_txt, nome_todos, titulo) =
                (em_utf16(idioma::t("Texto (*.txt)")), em_utf16(idioma::t("Todos os arquivos")), em_utf16(idioma::t("Abrir roteiro")));
            let tipos = [
                COMDLG_FILTERSPEC { pszName: PCWSTR(nome_txt.as_ptr()), pszSpec: w!("*.txt") },
                COMDLG_FILTERSPEC { pszName: PCWSTR(nome_todos.as_ptr()), pszSpec: w!("*.*") },
            ];
            d.SetFileTypes(&tipos)?;
            d.SetTitle(PCWSTR(titulo.as_ptr()))?;
            d.SetOptions(d.GetOptions()? | FOS_FILEMUSTEXIST | FOS_FORCEFILESYSTEM)?;
            if let Err(e) = d.Show(Some(dona)) {
                // `HRESULT_FROM_WIN32(ERROR_CANCELLED)`: a pessoa fechou ou cancelou.
                if e.code() == windows::core::HRESULT(0x800704C7u32 as i32) {
                    return Ok(None);
                }
                return Err(e);
            }
            let item = d.GetResult()?;
            let nome = item.GetDisplayName(SIGDN_FILESYSPATH)?;
            let caminho = nome.to_string();
            CoTaskMemFree(Some(nome.0 as *const core::ffi::c_void));
            Ok(Some(PathBuf::from(caminho.map_err(|_| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))?)))
        })();
        CoUninitialize();
        r.map_err(|e| e.to_string())
    }
}

/// `(x, y)` de um `LPARAM` de mensagem de mouse, com sinal (coordenadas de cliente).
fn xy(lp: LPARAM) -> (i32, i32) {
    ((lp.0 & 0xFFFF) as u16 as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as u16 as i16 as i32)
}

/// Uma casa decimal, com a vírgula do português ou o ponto do inglês.
fn um_decimal(v: f64) -> String {
    idioma::decimal(v, 1)
}

/// A porcentagem do diário e do relato de bancada: sempre "50 %", em qualquer idioma.
fn pct_do_diario(v: f64) -> String {
    format!("{:.0} %", v * 100.0)
}

/// Uma porcentagem: "50 %" em português, "50%" em inglês.
fn pct(v: f64) -> String {
    match idioma::atual() {
        idioma::Idioma::Pt => format!("{:.0} %", v * 100.0),
        idioma::Idioma::En => format!("{:.0}%", v * 100.0),
    }
}

// =============================================================================================
// O procedimento da janela
// =============================================================================================

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let ponteiro = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut Tela;
    if ponteiro.is_null() || EM_ESPERA.load(Ordering::SeqCst) {
        return unsafe { DefWindowProcW(hwnd, msg, wp, lp) };
    }
    let t = unsafe { &mut *ponteiro };
    match msg {
        WM_ACORDAR => {
            t.acordado = true;
            LRESULT(0)
        }
        WM_ARQUIVO_DO_ROTEIRO => {
            let r = ARQUIVO_DO_ROTEIRO.lock().ok().and_then(|mut g| g.take());
            if let Some(r) = r {
                t.arquivo_escolhido(hwnd, r);
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            t.comando(hwnd, (wp.0 & 0xFFFF) as usize, ((wp.0 >> 16) & 0xFFFF) as u32);
            LRESULT(0)
        }
        WM_SIZE => {
            if wp.0 as u32 == SIZE_MINIMIZED {
                t.segurar_soltar_todos(hwnd, "a janela foi minimizada"); // i18n: fora (diário)
            }
            t.posicionar(hwnd);
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
            LRESULT(0)
        }
        // **O segundo plano solta o "segurar"**: a janela perdeu o primeiro plano (outra janela,
        // outro app); o botão do mouse ou a tecla podem subir onde esta janela não vê.
        WM_ACTIVATE => {
            if (wp.0 & 0xFFFF) as u32 == WA_INACTIVE {
                t.segurar_soltar_todos(hwnd, "a janela saiu do primeiro plano"); // i18n: fora (diário)
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_ACTIVATEAPP => {
            if wp.0 == 0 {
                t.segurar_soltar_todos(hwnd, "o app saiu do primeiro plano"); // i18n: fora (diário)
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // Um menu (o da janela, Alt+Espaço) ou arrastar a janela pela barra de título tomam o
        // mouse e o teclado: soltam tudo, como perder o foco (a decisão do Mac).
        WM_ENTERMENULOOP | WM_ENTERSIZEMOVE => {
            t.segurar_soltar_todos(
                hwnd,
                if msg == WM_ENTERMENULOOP { "abriu um menu" } else { "a janela está sendo movida" }, // i18n: fora (diário)
            );
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // **Os dedos, no modo "Segurar para rolar"** (`WM_POINTER*` só chega de toque e caneta: o
        // mouse segue pelos `WM_LBUTTON*`). Fora do modo, o sistema os converte em mouse.
        WM_POINTERDOWN | WM_POINTERUPDATE | WM_POINTERUP | WM_POINTERCAPTURECHANGED if t.modo_segurar() => {
            let contato = (wp.0 & 0xFFFF) as u32;
            let mut p = windows::Win32::Foundation::POINT {
                x: (lp.0 & 0xFFFF) as u16 as i16 as i32,
                y: ((lp.0 >> 16) & 0xFFFF) as u16 as i16 as i32,
            };
            unsafe {
                let _ = ScreenToClient(hwnd, &mut p);
            }
            match msg {
                WM_POINTERDOWN => {
                    t.segurar_desceu(hwnd, contato, p.x, p.y, "dedo");
                }
                WM_POINTERUPDATE => t.segurar_moveu(hwnd, contato, p.x, p.y),
                // Subiu, foi cancelado (`POINTER_MESSAGE_FLAG_CANCELED`) ou perdeu a captura:
                // todos soltam do mesmo jeito.
                _ => t.segurar_subiu(hwnd, contato, "dedo"),
            }
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let delta = ((wp.0 >> 16) & 0xFFFF) as u16 as i16;
            // No painel do controle a roda rola o painel; no prompter, o texto.
            if t.painel_visivel() {
                t.rolar_o_painel(hwnd, |r, conteudo, vista| pdc::rolagem_da_roda(r, i32::from(delta), conteudo, vista));
            } else {
                t.roda(hwnd, f64::from(delta) / 120.0);
            }
            LRESULT(0)
        }
        // A barra de rolagem da janela (só o painel do controle a mostra). `lParam` não nulo é a de
        // um controle, que não há.
        WM_VSCROLL if lp.0 == 0 => {
            let codigo = (wp.0 & 0xFFFF) as u32;
            let mut si = SCROLLINFO { cbSize: std::mem::size_of::<SCROLLINFO>() as u32, fMask: SIF_ALL, ..Default::default() };
            unsafe {
                let _ = GetScrollInfo(hwnd, SB_VERT, &mut si);
            }
            let k = t.dpi as f32 / 96.0;
            let linha = pdc::PASSO_DA_RODA;
            t.rolar_o_painel(hwnd, |r, conteudo, vista| {
                let novo = match SCROLLBAR_COMMAND(codigo as i32) {
                    SB_LINEUP => r - linha,
                    SB_LINEDOWN => r + linha,
                    SB_PAGEUP => r - vista * 0.9,
                    SB_PAGEDOWN => r + vista * 0.9,
                    SB_THUMBTRACK | SB_THUMBPOSITION => si.nTrackPos as f32 / k,
                    SB_TOP => 0.0,
                    SB_BOTTOM => conteudo,
                    _ => r,
                };
                pdc::limitar_rolagem(novo, conteudo, vista)
            });
            LRESULT(0)
        }
        // **O mínimo da janela** fora do prompter (`painel_do_controle::minimo_que_cabe`): nunca maior
        // que a área de trabalho.
        WM_GETMINMAXINFO if t.modo != Modo::Prompter => {
            let dpi = t.dpi;
            if let Some((_, trabalho)) = area_de_trabalho(hwnd, dpi) {
                let (l, a) = pdc::minimo_que_cabe(trabalho, moldura_em_dip(hwnd, dpi));
                let (w, h) = janela_para_o_cliente(hwnd, dpi, escala_f(dpi, l), escala_f(dpi, a));
                let mmi = unsafe { &mut *(lp.0 as *mut MINMAXINFO) };
                mmi.ptMinTrackSize.x = w;
                mmi.ptMinTrackSize.y = h;
            }
            LRESULT(0)
        }
        // **Os botões no desenho do estúdio** (fora do prompter): o `NM_CUSTOMDRAW` do comctl v6,
        // nunca `BS_OWNERDRAW` (`telas-estudio.md` §11.5: o owner-draw não responde a `BM_GETCHECK`).
        WM_NOTIFY => {
            let hdr = unsafe { &*(lp.0 as *const windows::Win32::UI::Controls::NMHDR) };
            if hdr.code == windows::Win32::UI::Controls::NM_CUSTOMDRAW && t.desenha_o_botao(hdr.hwndFrom) {
                let cd = unsafe { &*(lp.0 as *const windows::Win32::UI::Controls::NMCUSTOMDRAW) };
                use windows::Win32::UI::Controls::{CDDS_PREERASE, CDDS_PREPAINT, CDRF_DODEFAULT, CDRF_SKIPDEFAULT};
                if cd.dwDrawStage == CDDS_PREERASE || cd.dwDrawStage == CDDS_PREPAINT {
                    t.desenhar_botao(cd);
                    return LRESULT(CDRF_SKIPDEFAULT as isize);
                }
                return LRESULT(CDRF_DODEFAULT as isize);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // As setas da linha de leitura: arrastar a faixa (ou as setas) move a linha. As setas do
        // enquadramento: arrastar perto de uma borda move aquela borda. A faixa tem a vez.
        WM_LBUTTONDOWN => {
            let (x, y) = xy(lp);
            // A borda da tela R5 (entre o texto e a prévia) tem a vez.
            if t.r5_comecar_borda(hwnd, x, y) {
                unsafe {
                    SetCapture(hwnd);
                }
                return LRESULT(0);
            }
            if t.modo_segurar() {
                // Os dois botões grandes: o mouse é um contato como um dedo.
                if t.segurar_desceu(hwnd, regras::CONTATO_DO_MOUSE, x, y, "mouse") {
                    t.mouse_no_segurar = true;
                    unsafe {
                        SetCapture(hwnd);
                    }
                }
            } else if t.comecar_arrasto(hwnd, x, y) || t.comecar_enquadramento(hwnd, x, y) {
                unsafe {
                    SetCapture(hwnd);
                }
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            if t.r5.as_ref().is_some_and(|r| r.arrastando_borda) {
                let (x, y) = xy(lp);
                t.r5_mover_borda(hwnd, x, y);
            } else if t.mouse_no_segurar {
                let (x, y) = xy(lp);
                t.segurar_moveu(hwnd, regras::CONTATO_DO_MOUSE, x, y);
            } else if t.arrastando {
                t.mover_arrasto(hwnd, xy(lp).1);
            } else if t.enquadrando.is_some() {
                t.mover_enquadramento(hwnd, xy(lp).0);
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            if t.r5.as_ref().is_some_and(|r| r.arrastando_borda) {
                t.r5_soltar_borda();
                unsafe {
                    let _ = ReleaseCapture();
                }
            } else if t.mouse_no_segurar {
                // Antes do `ReleaseCapture`: ele manda `WM_CAPTURECHANGED` na hora, e o soltar
                // não pode sair duas vezes.
                t.mouse_no_segurar = false;
                t.segurar_subiu(hwnd, regras::CONTATO_DO_MOUSE, "mouse");
                unsafe {
                    let _ = ReleaseCapture();
                }
            } else if t.arrastando || t.enquadrando.is_some() {
                t.soltar_arrasto(hwnd, Some(xy(lp).1));
                t.soltar_enquadramento(hwnd, Some(xy(lp).0));
                unsafe {
                    let _ = ReleaseCapture();
                }
            }
            LRESULT(0)
        }
        WM_CAPTURECHANGED => {
            t.r5_soltar_borda();
            // Outra janela tomou o mouse no meio do arrasto: o que já estava vale. No "segurar",
            // perder o mouse é soltar.
            if std::mem::take(&mut t.mouse_no_segurar) {
                t.segurar_subiu(hwnd, regras::CONTATO_DO_MOUSE, "mouse (captura perdida)");
            }
            t.soltar_arrasto(hwnd, None);
            t.soltar_enquadramento(hwnd, None);
            LRESULT(0)
        }
        WM_SETCURSOR if (lp.0 & 0xFFFF) as u32 == HTCLIENT => {
            let mut p = windows::Win32::Foundation::POINT::default();
            let dentro = unsafe { GetCursorPos(&mut p).is_ok() && ScreenToClient(hwnd, &mut p).as_bool() };
            let cursor = if dentro && (t.r5.as_ref().is_some_and(|r| r.arrastando_borda) || t.r5_na_borda(hwnd, p.x, p.y)) {
                Some(t.r5_cursor_da_borda())
            } else if dentro && (t.arrastando || t.na_faixa(hwnd, p.x, p.y)) {
                Some(IDC_SIZENS)
            } else if dentro && (t.enquadrando.is_some() || t.na_seta_do_enquadramento(hwnd, p.x, p.y).is_some()) {
                Some(IDC_SIZEWE)
            } else {
                None
            };
            match cursor {
                Some(c) => {
                    unsafe {
                        SetCursor(LoadCursorW(None, c).ok());
                    }
                    LRESULT(1)
                }
                None => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
            }
        }
        WM_THEMECHANGED | WM_SETTINGCHANGE => {
            crate::decoracao::aplicar(hwnd);
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_DPICHANGED => {
            let novo = ((wp.0 >> 16) & 0xFFFF) as u32;
            let sugerido = unsafe { *(lp.0 as *const RECT) };
            t.mudar_dpi(hwnd, novo, sugerido);
            crate::decoracao::aplicar(hwnd);
            LRESULT(0)
        }
        // Os campos, a lista e o editor no escuro, fora do prompter: a `superficie` e o texto claro
        // (antes, branco). O prompter e a tela R5 ficam como eram nesta rodada (o editor dele e a
        // caixa da câmera, que tem a face clara do tema): branco com a tinta escura.
        WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => unsafe {
            let dc = HDC(wp.0 as *mut core::ffi::c_void);
            if t.modo == Modo::Prompter {
                SetBkColor(dc, COLORREF(0x00FF_FFFF));
                SetTextColor(dc, COLORREF(0x0020_1A16));
                LRESULT(GetStockObject(WHITE_BRUSH).0 as isize)
            } else {
                SetBkColor(dc, FUNDO_DO_CAMPO);
                SetTextColor(dc, TINTA);
                LRESULT(t.fundo_do_campo.0 as isize)
            }
        },
        // O `EDIT` só de leitura (um roteiro guardado aberto para ler) também pede por aqui: a tinta
        // clara vale para ele, fora do prompter.
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN => unsafe {
            let escuro = t.modo == Modo::Prompter;
            SetBkColor(HDC(wp.0 as *mut core::ffi::c_void), if escuro { FUNDO_ESCURO } else { FUNDO_DO_PAINEL });
            if !escuro {
                SetTextColor(HDC(wp.0 as *mut core::ffi::c_void), TINTA);
            }
            LRESULT(if escuro { t.fundo_escuro.0 } else { t.fundo_do_painel.0 } as isize)
        },
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = unsafe { BeginPaint(hwnd, &mut ps) };
            t.pintar(hwnd, hdc);
            unsafe {
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        // A captura de bancada (`WM_PRINT` com `PRF_CLIENT`) chega aqui: a janela se desenha no
        // DC que veio.
        WM_PRINTCLIENT => {
            t.pintar(hwnd, HDC(wp.0 as *mut core::ffi::c_void));
            LRESULT(0)
        }
        WM_CLOSE => {
            t.fechar(hwnd);
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_DESTROY => unsafe {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(ponteiro));
            PostQuitMessage(0);
            LRESULT(0)
        },
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

// =============================================================================================
// Os modos
// =============================================================================================

impl Tela {
    fn aplicar_fontes(&self) {
        let pequena = WPARAM(self.fontes.pequeno.0 as usize);
        let mut todos = vec![
            self.c.mostrar,
            self.c.controlar,
            self.c.lista,
            self.c.endereco,
            self.c.pin,
            self.c.conectar,
            self.c.voltar,
            self.c.procurar_de_novo,
            self.c.fonte_auto,
            self.c.segurar,
            self.c.sair_do_segurar,
            self.c.inverter,
            self.c.usar_do_prompter,
            self.c.mandar_o_meu,
            self.c.roteiros,
            self.c.fechar_roteiros,
            self.c.confirma_sim,
            self.c.confirma_nao,
            self.c.voltar_a_lista,
            self.c.editar_roteiro,
            self.c.sair,
            self.c.esperar_de_novo,
            self.c.confirmar,
            self.c.cancelar,
            self.c.usar_novo,
            self.c.manter_meu,
            self.c.abrir_arquivo,
        ];
        todos.extend(self.c.comandos.iter().map(|(_, h)| *h));
        todos.extend(self.c.itens_dos_roteiros.iter().flatten().copied());
        unsafe {
            for h in todos {
                SendMessageW(h, WM_SETFONT, Some(pequena), Some(LPARAM(1)));
            }
            // Os dois botões da pergunta são a decisão da tela: maiores.
            SendMessageW(self.c.usar_do_prompter, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.mandar_o_meu, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.mostrar, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.mostrar_com_camera, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            for h in [self.c.microfone, self.c.gravar, self.c.esconder_previa, self.c.espelho_previa, self.c.lado_do_texto, self.c.camera, self.c.gravar_remoto, self.c.codigo_recusar, self.c.travar_fps, self.c.camera_do_prompter] {
                SendMessageW(h, WM_SETFONT, Some(WPARAM(self.fontes.pequeno.0 as usize)), Some(LPARAM(1)));
            }
            // Os três números, no corpo forte: são o que a pessoa compara com a outra tela.
            for h in self.c.codigo_numeros {
                SendMessageW(h, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            }
            SendMessageW(self.c.ajustes_da_camera, WM_SETFONT, Some(WPARAM(self.fontes.icones.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.tela_cheia, WM_SETFONT, Some(WPARAM(self.fontes.icones.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.controlar, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
            SendMessageW(self.c.texto, WM_SETFONT, Some(WPARAM(self.fontes.corpo.0 as usize)), Some(LPARAM(1)));
        }
    }

    fn mudar_de_modo(&mut self, hwnd: HWND, modo: Modo) {
        self.modo = modo;
        self.publicar_papel();
        self.aplicar_titulo(hwnd);
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// Publica o papel desta janela para quem está fora (ver [`papel_aberto`]).
    pub(super) fn publicar_papel(&self) {
        let p = match self.modo {
            Modo::Escolha => 0,
            Modo::Prompter if self.r5.is_some() => 3,
            Modo::Prompter => 1,
            Modo::Controle => 2,
        };
        PAPEL.store(p, Ordering::SeqCst);
    }

    fn ambiente(&mut self, hwnd: HWND) -> Arc<Ambiente> {
        if let Some(a) = &self.ambiente {
            return Arc::clone(a);
        }
        let alvo = hwnd.0 as isize;
        let a = Arc::new(Ambiente {
            device_id: identidade::device_id(),
            nome: self.nome.clone(),
            pares: Box::new(identidade::pares_conhecidos),
            guardar_pares: Box::new(identidade::guardar_pares),
            guardar_nome_do_par: Box::new(identidade::guardar_nome_do_par),
            registrar: Box::new(|l: &str| registro::linha(l)),
            acordar: Box::new(move || unsafe {
                let _ = PostMessageW(Some(HWND(alvo as *mut core::ffi::c_void)), WM_ACORDAR, WPARAM(0), LPARAM(0));
            }),
            ip_local: Box::new(enderecos::ip_local),
            bancada: self.cfg.bancada,
        });
        self.ambiente = Some(Arc::clone(&a));
        a
    }

    fn preparar_replica(&mut self, lado: Lado) -> bool {
        match super::replica(lado) {
            Ok(t) => {
                self.texto = t.texto().unwrap_or_default();
                self.texto_utf16 = Arc::new(self.texto.encode_utf16().collect());
                self.geracao_do_texto += 1;
                self.estado = t.estado().ok();
                self.teleprompter = Some(t);
                self.lado = Some(lado);
                registro::linha(format!(
                    "teleprompter: tela do {} aberta: texto={} bytes resumo={} estado={}",
                    if lado == Lado::Prompter { "prompter" } else { "controle" },
                    self.texto.len(),
                    resumo(&self.texto),
                    self.estado.as_ref().map(|e| serde_json::to_string(e).unwrap_or_default()).unwrap_or_default()
                ));
                true
            }
            Err(e) => {
                self.mensagem = idioma::tf("Não consegui criar o teleprompter: {}", &[&e]);
                registro::linha(format!("teleprompter: !! {}", self.mensagem));
                false
            }
        }
    }

    /// Bancada: o roteiro do arquivo, aplicado como edição local (o mesmo caminho do Confirmar).
    fn roteiro_de_bancada(&mut self, hwnd: HWND) {
        if let Some(caminho) = self.cfg.texto.clone() {
            match std::fs::read_to_string(&caminho) {
                Ok(t) => {
                    registro::linha(format!("teleprompter: bancada: roteiro de {}", caminho.display()));
                    self.aplicar_texto_local(hwnd, &t);
                }
                Err(e) => registro::linha(format!(
                    "teleprompter: !! --teleprompter-texto {}: não consegui ler ({e})",
                    caminho.display()
                )),
            }
        }
    }

    /// **O prompter**: a réplica, a tela acesa, o desenho, e a espera pelo controle.
    fn abrir_prompter(&mut self, hwnd: HWND) {
        if !self.preparar_replica(Lado::Prompter) {
            self.mudar_de_modo(hwnd, Modo::Escolha);
            return;
        }
        // **Esta tela entende o "segurar para rolar"** (§12.5): com `rolando` e `para_tras` ela
        // rola para trás na velocidade de sempre e para no começo sem mudar `rolando`
        // (`quadro`), relê os dois nos bits `ROLANDO` e `SEGURAR`, e para quando `rolando` cai.
        // Só por isso ela diz que entende — o controle só segura quem diz.
        if let Some(t) = &self.teleprompter {
            match t.ligar_segurar() {
                Ok(()) => registro::linha("teleprompter: o prompter entende \"segurar para rolar\" (ligar_segurar)"),
                Err(e) => registro::linha(format!("teleprompter: !! ligar_segurar falhou: {e}")),
            }
        }
        match Desenho::novo() {
            Ok(d) => self.desenho = Some(d),
            Err(e) => registro::linha(format!("teleprompter: !! Direct2D/DirectWrite não subiu: {e}")),
        }
        let alvo = hwnd.0 as isize;
        self.diagramador = Some(Diagramador::novo(Box::new(move || unsafe {
            let _ = PostMessageW(Some(HWND(alvo as *mut core::ffi::c_void)), WM_ACORDAR, WPARAM(0), LPARAM(0));
        })));
        // Os ajustes deste aparelho no suporte: o enquadramento e a fonte automática.
        self.ajustes = super::ler_ajustes();
        // **A dívida do espelho da tela R5** (o processo morreu com ela aberta): o prompter comum paga.
        if self.ajustes.r5_espelho_devido && self.cfg.r5.is_none() {
            self.editar(hwnd, "espelho=true (a dívida da tela com câmera)", |t| t.definir_espelho(true)); // i18n: fora
            self.ajustes.r5_espelho_devido = false;
            super::gravar_ajustes(&self.ajustes);
        }
        unsafe {
            SendMessageW(
                self.c.fonte_auto,
                BM_SETCHECK,
                Some(WPARAM(if self.ajustes.fonte_automatica { BST_CHECKED } else { 0 })),
                None,
            );
        }
        registro::linha(format!("teleprompter: ajustes locais: {}", self.ajustes.para_json()));
        // **A tela acesa** enquanto o texto está na tela: sem isto o Windows apaga o monitor no
        // meio da leitura. É por thread, e esta é a thread da janela, que vive enquanto ela vive.
        let pedido = ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED;
        let antes = unsafe { SetThreadExecutionState(pedido) };
        self.tela_acesa = Some(antes.0);
        self.tela_acesa_pedida = antes.0 != 0;
        registro::linha(format!(
            "teleprompter: tela acesa: SetThreadExecutionState(CONTINUOUS|DISPLAY|SYSTEM) devolveu 0x{:08X} ({})",
            antes.0,
            if antes.0 == 0 { "FALHOU" } else { "ligada" }
        ));
        self.mudar_de_modo(hwnd, Modo::Prompter);
        self.roteiro_de_bancada(hwnd);
        self.pedir_layout(hwnd);
        if self.cfg.sem_sessao {
            registro::linha("teleprompter: prompter sem sessão (--sem-sessao): só o texto, nenhuma porta aberta");
        } else {
            self.esperar_pelo_controle(hwnd);
        }
    }

    fn esperar_pelo_controle(&mut self, hwnd: HWND) {
        let Some(t) = self.teleprompter.clone() else { return };
        let amb = self.ambiente(hwnd);
        let porta = if self.cfg.porta == 0 { regras::porta_do_teleprompter() } else { self.cfg.porta };
        // §17 do contrato da câmera: o filmador da tela R5 (quando ela abrir) também vai pela sessão do
        // teleprompter. No prompter de texto só, o dono fica vazio e o controle nunca vê
        // `entende_camera` (só a tela R5 liga).
        let camera: Arc<dyn super::sessao::CameraDaSessao> = crate::camera_remota::CameraDoPrompter::nova(Arc::clone(&self.dono_da_r5));
        let s = Sessao::iniciar_prompter_com_camera(
            t,
            amb,
            ConfigDoPrompter { porta, pin: self.cfg.pin.clone(), anunciar: !self.cfg.sem_mdns },
            Some(camera),
        );
        self.sessao = Some(s);
        self.saltos_aplicados = 0;
    }

    /// **O controle**: a lista do mDNS e o formulário.
    fn abrir_controle(&mut self, hwnd: HWND) {
        if !self.preparar_replica(Lado::Controle) {
            self.mudar_de_modo(hwnd, Modo::Escolha);
            return;
        }
        let busca = descoberta::Busca::de_prompters(identidade::device_id());
        busca.comecar();
        self.busca = Some(busca);
        // **A trava da pergunta do texto** (§11.10): esta tela tem a caixa da pergunta, então liga a
        // pergunta na réplica do controle — a cada vida do app, porque ela não vai no salvo.
        if let Some(t) = &self.teleprompter {
            match t.ligar_pergunta_do_texto() {
                Ok(()) => registro::linha("teleprompter: a pergunta do texto está ligada (ligar_pergunta_do_texto)"),
                Err(e) => registro::linha(format!("teleprompter: !! ligar_pergunta_do_texto falhou: {e}")),
            }
        }
        // O modo "Segurar para rolar" é ajuste local do controle, guardado no aparelho.
        self.ajustes = super::ler_ajustes();
        registro::linha(format!("teleprompter: ajustes locais: {}", self.ajustes.para_json()));
        self.mudar_de_modo(hwnd, Modo::Controle);
        if let Some(e) = &self.cfg.prompter {
            por_texto(self.c.endereco, e);
        }
        if let Some(p) = &self.cfg.pin {
            por_texto(self.c.pin, p);
        }
        self.roteiro_de_bancada(hwnd);
    }

    fn conectar(&mut self, hwnd: HWND, endereco: Option<String>) {
        if self.sessao.as_ref().is_some_and(|s| !s.terminou()) {
            return;
        }
        let digitado = endereco.unwrap_or_else(|| texto_de(self.c.endereco));
        let Some(destino) = regras::destino_do_controle(&digitado) else {
            // Guardada em português (a chave) e traduzida ao mostrar: troca junto com o idioma.
            self.mensagem = "Digite o endereço que a tela do prompter mostra (por exemplo 192.168.15.20).".into(); // i18n: chave
            self.posicionar(hwnd);
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
            return;
        };
        let pin = Some(texto_de(self.c.pin)).filter(|p| !p.trim().is_empty());
        let Some(t) = self.teleprompter.clone() else { return };
        // **O prompter reconhecido** do endereço pedido (o item da lista, ou o digitado que é o dele):
        // o toque reconecta só com o vínculo dele, ou pareia de novo pelo código (§8.6).
        let enderecos: Vec<(String, Option<String>)> = self.prompters.iter().map(|p| (p.endereco.to_string(), p.conhecido.clone())).collect();
        let alvo_do_toque = crate::conexao::conhecido_no_endereco(enderecos.iter().map(|(e, c)| (e.as_str(), c.as_deref())), &destino.endereco).map(str::to_string);
        let da_lista = enderecos.iter().any(|(e, _)| *e == destino.endereco.trim());
        registro::linha(format!(
            "teleprompter: controle: conectando em {} {} — {}",
            destino.endereco,
            if da_lista { "(o endereço de um item da lista)" } else { "(o endereço digitado, fora da lista)" },
            crate::conexao::caminho_do_controle(destino.pin.is_some() || pin.is_some(), alvo_do_toque.as_deref()).descricao()
        ));
        self.mensagem.clear();
        // A procura para enquanto a sessão dura (o mDNS não disputa a rede com ela) e volta com o
        // formulário (ver `tique`).
        if let Some(b) = self.busca.take() {
            b.parar();
        }
        let amb = self.ambiente(hwnd);
        // §17 do contrato da câmera: o controle da câmera do prompter R5, pela sessão do teleprompter.
        let alvo = hwnd.0 as isize;
        let camera = crate::camera_remota::CameraDoControle::nova(Box::new(move || unsafe {
            let _ = PostMessageW(Some(HWND(alvo as *mut core::ffi::c_void)), WM_ACORDAR, WPARAM(0), LPARAM(0));
        }));
        self.camera_do_controle = Some(Arc::clone(&camera));
        let camera: Arc<dyn super::sessao::CameraDaSessao> = camera;
        self.sessao = Some(Sessao::iniciar_controle_com_camera(t, amb, ConfigDoControle { destino, pin, alvo: alvo_do_toque }, Some(camera)));
        self.posicionar(hwnd);
    }

    fn fechar(&mut self, hwnd: HWND) {
        // A tela R5 fecha primeiro: a gravação (o arquivo fecha e o controle ainda vê), o vídeo, o
        // microfone, a prévia e a câmera.
        self.r5_fechar(hwnd);
        // O "segurar" solta **antes** de a sessão parar: o soltar sai por ela (a parada bombeia o
        // que ficou pendente), e o prompter para pelo soltar, não pela queda.
        self.segurar_soltar_todos(hwnd, "a tela fechou"); // i18n: fora (diário)
        if let Some(s) = self.sessao.take() {
            s.pedir_parada();
            if !s.esperar(Duration::from_secs(4)) {
                registro::linha("teleprompter: !! a sessão não terminou em 4 s; a janela fecha assim mesmo");
            }
            self.estado = s.teleprompter.estado().ok();
            // O painel de agora (a sessão já acabou): é o que o relato diz como fase final.
            self.painel = Some(s.painel().clone());
            self.sessao = Some(s);
        }
        if let Some(b) = self.busca.take() {
            b.parar();
        }
        // O espelho do texto que a tela R5 desligou volta aqui: com a sessão já parada (o controle não
        // vê a volta) e antes de o salvo ser gravado.
        self.r5_devolver_o_espelho(hwnd);
        if let Some(l) = self.lado {
            super::salvar(l);
        }
        if std::mem::take(&mut self.tela_acesa_pedida) {
            unsafe {
                let _ = SetThreadExecutionState(ES_CONTINUOUS);
            }
            registro::linha("teleprompter: tela acesa: pedido solto");
        }
        self.escrever_relato(hwnd);
        registro::linha("teleprompter: janela fechada");
    }

    // -----------------------------------------------------------------------------------------
    // Os comandos
    // -----------------------------------------------------------------------------------------

    fn comando(&mut self, hwnd: HWND, id: usize, aviso: u32) {
        if self.r5_comando(hwnd, id, aviso) {
            return;
        }
        match (id, aviso) {
            // O código da sessão do teleprompter no prompter de texto (na tela R5, `r5_comando`).
            (ID_CODIGO_RECUSAR, BN_CLICKED) => {
                self.tocar_no_codigo_da_sessao(None);
            }
            (ID_CODIGO_NUMERO..=ID_CODIGO_NUMERO_FIM, BN_CLICKED) => {
                self.tocar_no_codigo_da_sessao(Some(id - ID_CODIGO_NUMERO));
            }
            (ID_MOSTRAR, BN_CLICKED) => {
                self.abrir_prompter(hwnd);
                self.aplicar_tela_cheia_lembrada(hwnd);
            }
            (ID_MOSTRAR_COM_CAMERA, BN_CLICKED) => {
                self.abrir_prompter_com_camera(hwnd);
                self.aplicar_tela_cheia_lembrada(hwnd);
            }
            (ID_GRAVAR_REMOTO, BN_CLICKED) => {
                self.controle_gravar();
                self.posicionar(hwnd);
            }
            (ID_CAMERA_DO_PROMPTER, BN_CLICKED) => match self.camera_do_controle.as_ref().and_then(|c| c.controle()) {
                Some(c) => {
                    registro::linha("teleprompter: controle: abrindo os ajustes da câmera do prompter");
                    crate::janela_dos_ajustes::abrir_remota(c);
                }
                None => registro::linha("teleprompter: controle: sem a câmera do prompter, nada a ajustar"),
            },
            (ID_CONTROLAR, BN_CLICKED) => self.abrir_controle(hwnd),
            // O foco num campo fora da vista (o Tab): o painel rola até ele.
            (ID_ENDERECO, EN_SETFOCUS) => self.mostrar_o_foco(hwnd, PecaDoPainel::Endereco),
            (ID_PIN, EN_SETFOCUS) => self.mostrar_o_foco(hwnd, PecaDoPainel::Pin),
            (ID_LISTA, LBN_SETFOCUS) => self.mostrar_o_foco(hwnd, PecaDoPainel::Lista),
            (ID_CONECTAR, BN_CLICKED) => self.conectar(hwnd, None),
            (ID_LISTA, LBN_SELCHANGE) | (ID_LISTA, LBN_DBLCLK) => {
                let i = unsafe { SendMessageW(self.c.lista, LB_GETCURSEL, None, None) }.0;
                if i >= 0 {
                    if let Some(p) = self.prompters.get(i as usize) {
                        let e = p.endereco.to_string();
                        por_texto(self.c.endereco, &e);
                        if aviso == LBN_DBLCLK {
                            self.conectar(hwnd, Some(e));
                        }
                    }
                }
            }
            (ID_PROCURAR_DE_NOVO, BN_CLICKED) => {
                if let Some(b) = &self.busca {
                    b.procurar_de_novo();
                }
            }
            (ID_VOLTAR, BN_CLICKED) => {
                if let Some(b) = self.busca.take() {
                    b.parar();
                }
                if let Some(l) = self.lado.take() {
                    super::salvar(l);
                }
                self.teleprompter = None;
                self.sessao = None;
                self.mudar_de_modo(hwnd, Modo::Escolha);
            }
            (ID_SAIR, BN_CLICKED) => {
                if self.modo == Modo::Controle && self.sessao.as_ref().is_some_and(|s| !s.terminou()) {
                    // Desconectar: a sessão fecha pela ordem do fim; a tela volta ao formulário.
                    if let Some(s) = &self.sessao {
                        s.pedir_parada();
                    }
                } else {
                    unsafe {
                        let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
                    }
                }
            }
            (ID_ESPERAR_DE_NOVO, BN_CLICKED) => self.esperar_pelo_controle(hwnd),
            (ID_TELA_CHEIA, BN_CLICKED) => self.alternar_tela_cheia(hwnd),
            (ID_EDITAR_ROTEIRO, BN_CLICKED) => self.abrir_editor(hwnd),
            (ID_FONTE_AUTO, BN_CLICKED) => {
                let ligada = marcado(self.c.fonte_auto);
                self.ligar_fonte_automatica(hwnd, ligada);
            }
            (ID_SEGURAR, BN_CLICKED) => self.ligar_modo_segurar(hwnd, true),
            (ID_SAIR_DO_SEGURAR, BN_CLICKED) => self.ligar_modo_segurar(hwnd, false),
            (ID_INVERTER, BN_CLICKED) => {
                let quer = marcado(self.c.inverter);
                self.inverter_botoes(hwnd, quer);
            }
            (ID_USAR_DO_PROMPTER, BN_CLICKED) => self.escolher(hwnd, false),
            (ID_MANDAR_O_MEU, BN_CLICKED) => self.escolher(hwnd, true),
            (ID_ROTEIROS, BN_CLICKED) => self.abrir_roteiros(hwnd, Some(VistaDosRoteiros::Lista)),
            (ID_FECHAR_ROTEIROS, BN_CLICKED) => self.abrir_roteiros(hwnd, None),
            (ID_VOLTAR_A_LISTA, BN_CLICKED) | (ID_CONFIRMA_NAO, BN_CLICKED) => {
                self.abrir_roteiros(hwnd, Some(VistaDosRoteiros::Lista))
            }
            (ID_CONFIRMA_SIM, BN_CLICKED) => self.confirmar_roteiro(hwnd),
            (id, BN_CLICKED)
                if (ID_ITEM_DOS_ROTEIROS..ID_ITEM_DOS_ROTEIROS + 3 * quall_core::teleprompter::COPIAS_DO_TEXTO).contains(&id) =>
            {
                let (item, acao) = ((id - ID_ITEM_DOS_ROTEIROS) / 3, (id - ID_ITEM_DOS_ROTEIROS) % 3);
                let copias = self.estado_ou_padrao().copias_do_texto;
                if let Some(c) = copias.get(item) {
                    let resumo = c.resumo.clone();
                    let vista = match acao {
                        0 => VistaDosRoteiros::Ver(resumo),
                        1 => VistaDosRoteiros::ConfirmarUsar(resumo),
                        _ => VistaDosRoteiros::ConfirmarApagar(resumo),
                    };
                    self.abrir_roteiros(hwnd, Some(vista));
                }
            }
            (ID_ROLAR, BN_CLICKED) => self.rolar_ou_pausar(hwnd),
            (ID_VEL_MENOS, BN_CLICKED) => self.velocidade(hwnd, -1),
            (ID_VEL_MAIS, BN_CLICKED) => self.velocidade(hwnd, 1),
            (ID_FONTE_MENOS, BN_CLICKED) => self.fonte(hwnd, -1),
            (ID_FONTE_MAIS, BN_CLICKED) => self.fonte(hwnd, 1),
            (ID_MARGEM_MENOS, BN_CLICKED) => self.margem(hwnd, -1),
            (ID_MARGEM_MAIS, BN_CLICKED) => self.margem(hwnd, 1),
            (ID_LINHA_ACIMA, BN_CLICKED) => self.linha(hwnd, -1),
            (ID_LINHA_ABAIXO, BN_CLICKED) => self.linha(hwnd, 1),
            (ID_ESPELHO, BN_CLICKED) => self.espelho(hwnd),
            (ID_INICIO, BN_CLICKED) => self.saltar(hwnd, 0.0),
            (ID_PULAR_MENOS, BN_CLICKED) => self.pular(hwnd, -regras::PULO),
            (ID_PULAR_MAIS, BN_CLICKED) => self.pular(hwnd, regras::PULO),
            (ID_EDITAR, BN_CLICKED) => self.abrir_editor(hwnd),
            (ID_CONFIRMAR, BN_CLICKED) => self.confirmar_editor(hwnd),
            (ID_CANCELAR, BN_CLICKED) => self.fechar_editor(hwnd),
            (ID_USAR_NOVO, BN_CLICKED) => self.usar_o_texto_novo(hwnd),
            (ID_MANTER_MEU, BN_CLICKED) => self.manter_o_meu(hwnd),
            (ID_ABRIR_ARQUIVO, BN_CLICKED) => self.abrir_arquivo_no_editor(hwnd),
            _ => {}
        }
    }

    /// O teclado do teleprompter. Devolve se a tecla foi usada (e não segue para o controle que
    /// tem o foco). Nos campos de texto as teclas são dos campos.
    fn tecla(&mut self, hwnd: HWND, vk: u32, repeticao: bool) -> bool {
        // No modo "Segurar para rolar", ↑ e ↓ seguram (no Mac e no Windows); o resto do teclado
        // não comanda nada — o espaço, principalmente, não pode virar play/pausa aqui.
        if self.modo_segurar() {
            return self.tecla_do_segurar(hwnd, vk, repeticao, true);
        }
        let foco = unsafe { GetFocus() };
        if foco == self.c.texto || foco == self.c.endereco || foco == self.c.pin || foco == self.c.lista {
            return false;
        }
        if self.rascunho.is_some() || self.teleprompter.is_none() {
            return false;
        }
        let em_sessao = self.modo == Modo::Prompter || self.sessao.as_ref().is_some_and(|s| !s.terminou());
        if !em_sessao {
            return false;
        }
        // Com a caixa da pergunta ou "Roteiros guardados" na tela, os comandos estão escondidos, e as
        // teclas deles não comandam nada: o espaço não rola o texto por trás da pergunta, nem o E abre
        // o editor. São engolidas (senão iriam para o botão escondido que ficou com o foco); as outras
        // (Alt+F4, Tab) seguem o caminho de sempre. A lista é a do `match` abaixo.
        // A tabela é `regras::acao_da_tecla` (testada): ↑/↓ movem o texto uma linha (segurada, suave)
        // e PgUp/PgDn uma tela, no sentido de "Inverter botões"; Shift+↑/↓ é a velocidade.
        let shift = unsafe { GetKeyState(VK_SHIFT.0 as i32) } < 0;
        let Some(acao) = regras::acao_da_tecla(vk, shift, self.ajustes.inverter_botoes) else { return false };
        use regras::AcaoDaTecla as A;
        if self.caixa_na_tela() || (self.modo == Modo::Controle && self.roteiros.is_some()) {
            return !matches!(acao, A::Faixas | A::TelaCheia | A::SairDaTelaCheia);
        }
        match acao {
            A::RolarOuPausar => self.rolar_ou_pausar(hwnd),
            A::MoverLinhas(_) | A::MoverTela(_) => return self.mover_pela_tecla(hwnd, acao, repeticao),
            A::Velocidade(n) => self.velocidade(hwnd, n),
            A::Pular(d) => self.pular(hwnd, d),
            A::Inicio => self.saltar(hwnd, 0.0),
            A::Espelho => self.espelho(hwnd),
            A::Fonte(n) => self.fonte(hwnd, n),
            A::Margem(n) => self.margem(hwnd, n),
            A::Linha(n) => self.linha(hwnd, n),
            A::Editar => self.abrir_editor(hwnd),
            A::Faixas if self.modo == Modo::Prompter => {
                self.faixas_ocultas = !self.faixas_ocultas;
                self.posicionar(hwnd);
                unsafe {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
            }
            A::TelaCheia if self.modo == Modo::Prompter => self.alternar_tela_cheia(hwnd),
            A::SairDaTelaCheia if self.tela_cheia.is_some() => self.alternar_tela_cheia(hwnd),
            _ => return false,
        }
        true
    }

    /// **↑/↓ e PgUp/PgDn movem o texto** (o pedido de 14/10). No prompter, o texto desliza até o alvo
    /// (`geometria::Deslize`), parado ou rolando, e a posição vai ao controle no relato de sempre. No
    /// controle, é o salto relativo do núcleo (`regras::salto_no_controle`): o controle não sabe as
    /// linhas do prompter; segurada, no máximo um salto a cada 100 ms.
    fn mover_pela_tecla(&mut self, hwnd: HWND, acao: regras::AcaoDaTecla, repeticao: bool) -> bool {
        if self.modo == Modo::Controle {
            let Some(d) = regras::salto_no_controle(acao) else { return false };
            let agora = Instant::now();
            let cedo = self
                .ultima_seta_no_controle
                .is_some_and(|t| agora.duration_since(t).as_secs_f64() < regras::INTERVALO_DA_SETA_NO_CONTROLE_S);
            if repeticao && cedo {
                return true;
            }
            self.ultima_seta_no_controle = Some(agora);
            self.pular(hwnd, d);
            return true;
        }
        if self.modo != Modo::Prompter || self.rascunho.is_some() {
            return false;
        }
        if self.diagramado.geometria.quantas_linhas() == 0 || self.layout_atrasado() {
            return true;
        }
        let area = self.area_do_texto(hwnd);
        let altura = f64::from(area.bottom - area.top);
        let g = &self.diagramado.geometria;
        let delta = match acao {
            regras::AcaoDaTecla::MoverLinhas(n) => n * g.altura_da_linha,
            regras::AcaoDaTecla::MoverTela(n) => n * (altura - g.altura_da_linha).max(g.altura_da_linha),
            _ => return false,
        };
        self.deslize = Some(Deslize::empurrar(self.deslize, self.rolagem.deslocamento, delta, repeticao, g));
        self.acordado = true;
        true
    }

    /// A tecla que subiu: no modo "Segurar para rolar", ↑/↓ soltam. Fora dele, nada.
    fn tecla_solta(&mut self, hwnd: HWND, vk: u32) -> bool {
        if self.modo_segurar() {
            return self.tecla_do_segurar(hwnd, vk, false, false);
        }
        false
    }

    /// ↑ e ↓ no modo "Segurar para rolar": `segurar` quando a tecla desce, `soltar` quando sobe, e
    /// a repetição automática do teclado ignorada. O espaço e o Enter são engolidos (um botão com o
    /// foco os tomaria como clique, e o espaço é o play/pausa, proibido no modo).
    fn tecla_do_segurar(&mut self, hwnd: HWND, vk: u32, repeticao: bool, desceu: bool) -> bool {
        let (contato, botao) = match vk {
            0x26 => (regras::CONTATO_DA_SETA_PARA_CIMA, regras::BotaoDeSegurar::Cima),
            0x28 => (regras::CONTATO_DA_SETA_PARA_BAIXO, regras::BotaoDeSegurar::Baixo),
            0x20 | 0x0D => return true,
            _ => return false,
        };
        if repeticao {
            return true;
        }
        let origem = if botao == regras::BotaoDeSegurar::Cima { "tecla ↑" } else { "tecla ↓" };
        if desceu {
            if !self.disponibilidade_do_segurar().botoes_ligados() {
                return true;
            }
            let c = self.dedos.desceu(contato, botao);
            self.aplicar_segurar(hwnd, c, origem);
        } else {
            let c = self.dedos.subiu(contato);
            self.aplicar_segurar(hwnd, c, origem);
        }
        true
    }

    /// Uma edição na réplica, desta thread, que sai na hora. No prompter a vista é atualizada já
    /// (o bit do núcleo só diz o que veio do outro lado).
    fn editar(&mut self, hwnd: HWND, nome: &str, f: impl FnOnce(&Teleprompter) -> quall_core::error::Result<()>) -> bool {
        let Some(t) = self.teleprompter.clone() else { return false };
        if let Some(s) = &self.sessao {
            s.antes_de_editar();
        }
        let r = f(&t);
        if let Some(s) = &self.sessao {
            s.depois_de_editar();
        }
        if let Err(e) = &r {
            registro::linha(format!("teleprompter: !! edição recusada ({nome}): {e}"));
        } else if self.cfg.bancada {
            registro::linha(format!("teleprompter: edição daqui: {nome}"));
        }
        self.estado = t.estado().ok();
        self.depois_do_estado(hwnd, 0);
        self.salvar_em = Some(Instant::now() + Duration::from_secs(3));
        r.is_ok()
    }

    fn estado_ou_padrao(&self) -> Estado {
        self.estado.clone().unwrap_or(Estado {
            rolando: false,
            velocidade: 1.0,
            fonte: 48.0,
            margem: 0.1,
            linha_de_leitura: 0.3,
            espelho: false,
            posicao: 0.0,
            salto: None,
            texto_bytes: 0,
            par_visto_ha_ms: None,
            sem_confirmacao_ha_ms: None,
            contadores: Default::default(),
            pergunta_do_texto: None,
            copias_do_texto: Vec::new(),
            para_tras: false,
            segurando: false,
            par_entende_segurar: false,
            gravando_ha_ms: None,
            pedido_de_gravacao: None,
            gravacao_recusada: None,
            par_entende_gravar: false,
            par_entende_camera: false,
        })
    }

    /// Rolar ou pausar, pelo estado **da réplica agora** (e não o publicado no último tique, que pode
    /// estar velho). No controle, duas regras da revisão do núcleo (14/09): nunca reafirmar
    /// `definir_rolando(true)` com o texto já rolando, e **nunca** chamá-lo durante o "segurar" —
    /// o play e a pausa saem do modo segurar no núcleo (§12.3), e um `rolando=true` no meio de um
    /// aperto tiraria o `segurando`, e o soltar seguinte não pararia o texto.
    fn rolar_ou_pausar(&mut self, hwnd: HWND) {
        let Some(t) = self.teleprompter.clone() else { return };
        let agora = t.estado().ok().unwrap_or_else(|| self.estado_ou_padrao());
        if self.modo == Modo::Controle && (self.modo_segurar() || agora.segurando) {
            registro::linha("teleprompter: rolar/pausar ignorado: o controle está no \"segurar para rolar\"");
            return;
        }
        let v = !agora.rolando;
        self.editar(hwnd, &format!("rolando={v}"), |t| t.definir_rolando(v));
    }

    /// `rolando = v` pedido de fora do alternar (ação de bancada), com as mesmas duas regras.
    fn definir_rolando(&mut self, hwnd: HWND, v: bool) {
        if self.modo == Modo::Controle {
            let agora = self.teleprompter.as_ref().and_then(|t| t.estado().ok()).unwrap_or_else(|| self.estado_ou_padrao());
            if self.modo_segurar() || agora.segurando {
                registro::linha(format!("teleprompter: rolando={v} ignorado: o controle está no \"segurar para rolar\""));
                return;
            }
            if v && agora.rolando {
                registro::linha("teleprompter: rolando=true não reafirmado: o texto já rola");
                return;
            }
        }
        self.editar(hwnd, &format!("rolando={v}"), |t| t.definir_rolando(v));
    }

    fn velocidade(&mut self, hwnd: HWND, passos: i32) {
        let e = self.estado_ou_padrao();
        let v = regras::passo(e.velocidade, regras::PASSO_DA_VELOCIDADE, passos, regras::FAIXA_DA_VELOCIDADE);
        self.editar(hwnd, &format!("velocidade={v}"), |t| t.definir_velocidade(v));
    }

    fn fonte(&mut self, hwnd: HWND, sentido: i32) {
        // Mudar a fonte à mão desliga a automática (senão ela desfaria a mudança na conta seguinte).
        self.desligar_fonte_automatica("a fonte foi mudada aqui"); // i18n: chave (o motivo do aviso)
        let e = self.estado_ou_padrao();
        let v = regras::passo(e.fonte, regras::PASSO_DA_FONTE, sentido, regras::FAIXA_DA_FONTE);
        self.editar(hwnd, &format!("fonte={v}"), |t| t.definir_fonte(v));
    }

    fn margem(&mut self, hwnd: HWND, sentido: i32) {
        let e = self.estado_ou_padrao();
        let v = regras::passo(e.margem, regras::PASSO_DA_MARGEM, sentido, regras::FAIXA_DA_MARGEM);
        self.editar(hwnd, &format!("margem={v}"), |t| t.definir_margem(v));
    }

    fn linha(&mut self, hwnd: HWND, sentido: i32) {
        let e = self.estado_ou_padrao();
        let v = regras::passo(e.linha_de_leitura, regras::PASSO_DA_LINHA, sentido, regras::FAIXA_DA_LINHA);
        self.editar(hwnd, &format!("linha={v}"), |t| t.definir_linha_de_leitura(v));
    }

    fn espelho(&mut self, hwnd: HWND) {
        let v = !self.estado_ou_padrao().espelho;
        self.editar(hwnd, &format!("espelho={v}"), |t| t.definir_espelho(v));
    }

    /// "Voltar ao começo" é `saltar(0)`; duas vezes são dois saltos (§3).
    fn saltar(&mut self, hwnd: HWND, p: f64) {
        let alvo = p.clamp(0.0, 1.0);
        if self.editar(hwnd, &format!("salto={alvo}"), |t| t.saltar(alvo)) && self.modo == Modo::Prompter {
            if let Some(s) = self.estado.as_ref().and_then(|e| e.salto) {
                self.ir_ao_salto(hwnd, s);
            }
        }
    }

    /// "Pular" é `saltar_relativo` (§3): parte de onde o texto **vai estar**.
    fn pular(&mut self, hwnd: HWND, delta: f64) {
        let d = delta.clamp(-1.0, 1.0);
        if self.editar(hwnd, &format!("pular={d}"), |t| t.saltar_relativo(d)) && self.modo == Modo::Prompter {
            if let Some(s) = self.estado.as_ref().and_then(|e| e.salto) {
                self.ir_ao_salto(hwnd, s);
            }
        }
    }

    /// O salto no prompter: vai até o alvo, relata a posição nele e mantém `rolando` como está.
    ///
    /// **E redesenha o texto parado** (o relato de 14/10: "o botão Início, −5 % e +5 % não fazem
    /// nada"). Com o texto rolando, o quadro seguinte já o mostrava no alvo; parado, o laço de quadros
    /// não roda e nada invalidava a área do texto — a posição mudava (e ia ao controle no relato), e a
    /// tela seguia mostrando a de antes. Valia para os botões daqui, para as teclas e para o salto que
    /// chega do controle.
    fn ir_ao_salto(&mut self, hwnd: HWND, alvo: f64) {
        self.deslize = None;
        if self.diagramado.geometria.quantas_linhas() == 0 || self.layout_atrasado() {
            self.posicao_pendente = Some(alvo);
        } else {
            let g = &self.diagramado.geometria;
            self.rolagem.ir(g.deslocamento_da_posicao(alvo), g);
            self.fim_avisado = self.rolagem.no_fim(g);
        }
        self.ultimo_quadro = None;
        if let Some(t) = &self.teleprompter {
            let _ = t.definir_posicao(alvo.clamp(0.0, 1.0));
        }
        self.repintar_texto_parado(hwnd);
    }

    fn roda(&mut self, hwnd: HWND, linhas: f64) {
        if self.modo != Modo::Prompter || self.rascunho.is_some() {
            return;
        }
        let g = &self.diagramado.geometria;
        if g.quantas_linhas() == 0 {
            return;
        }
        let d = self.rolagem.deslocamento - linhas * g.altura_da_linha;
        self.deslize = None;
        self.rolagem.ir(d, g);
        self.fim_avisado = self.rolagem.no_fim(g);
        self.relatar_posicao(true);
        self.acordado = true;
        // Parado, a roda também não redesenhava o texto (o mesmo defeito do salto).
        self.repintar_texto_parado(hwnd);
    }

    fn aplicar_texto_local(&mut self, hwnd: HWND, t: &str) -> bool {
        let limpo = t.replace('\0', "");
        if limpo.len() > TETO_DO_TEXTO {
            self.mensagem_do_editor = regras::frase_do_teto(limpo.len(), TETO_DO_TEXTO);
            registro::linha(format!("teleprompter: !! roteiro de {} bytes passa do teto", limpo.len()));
            return false;
        }
        let texto = limpo.clone();
        if !self.editar(hwnd, &format!("texto={} bytes", limpo.len()), move |r| r.definir_texto(&texto)) {
            return false;
        }
        self.trocar_texto(hwnd, limpo);
        if let Some(l) = self.lado {
            super::salvar(l);
        }
        registro::linha(format!(
            "teleprompter: texto confirmado aqui: {} bytes resumo={}",
            self.texto.len(),
            resumo(&self.texto)
        ));
        true
    }

    fn trocar_texto(&mut self, hwnd: HWND, novo: String) {
        if novo == self.texto {
            return;
        }
        self.texto_utf16 = Arc::new(novo.encode_utf16().collect());
        self.texto = novo;
        self.geracao_do_texto += 1;
        if self.modo == Modo::Prompter {
            self.pedir_layout(hwnd);
        }
    }

    // -----------------------------------------------------------------------------------------
    // O editor
    // -----------------------------------------------------------------------------------------

    fn abrir_editor(&mut self, hwnd: HWND) {
        if self.teleprompter.is_none() || self.rascunho.is_some() {
            return;
        }
        self.rascunho = Some(Rascunho::novo(&self.texto));
        self.mensagem_do_editor.clear();
        por_texto(self.c.texto, &para_o_editor(&self.texto));
        self.posicionar(hwnd);
        unsafe {
            let _ = SetFocus(Some(self.c.texto));
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
        registro::linha(format!("teleprompter: editor aberto ({} bytes)", self.texto.len()));
    }

    fn sincronizar_rascunho(&mut self) {
        let lido = do_editor(&texto_de(self.c.texto));
        if let Some(r) = &mut self.rascunho {
            r.rascunho = lido;
        }
    }

    fn fechar_editor(&mut self, hwnd: HWND) {
        self.rascunho = None;
        self.mensagem_do_editor.clear();
        self.posicionar(hwnd);
        unsafe {
            let _ = SetFocus(Some(hwnd));
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    fn confirmar_editor(&mut self, hwnd: HWND) {
        self.sincronizar_rascunho();
        let Some(r) = &self.rascunho else { return };
        let Some(t) = r.para_confirmar(&self.texto) else {
            self.fechar_editor(hwnd);
            return;
        };
        if self.aplicar_texto_local(hwnd, &t) {
            self.fechar_editor(hwnd);
        } else {
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }

    fn usar_o_texto_novo(&mut self, hwnd: HWND) {
        self.sincronizar_rascunho();
        let descartado = self.rascunho.as_mut().and_then(|r| r.usar_o_texto_novo());
        if let Some(d) = descartado {
            let copiou = bancada::copiar(hwnd, &d);
            // As frases ficam em português (a chave) e são traduzidas ao mostrar (`pintar_editor`).
            self.mensagem_do_editor = if copiou {
                "O seu rascunho foi para a área de transferência.".into() // i18n: chave
            } else {
                "Não consegui pôr o seu rascunho na área de transferência.".into() // i18n: chave
            };
            registro::linha(format!(
                "teleprompter: editor: a pessoa usou o texto do outro lado (rascunho de {} bytes {} para a área de transferência)",
                d.len(),
                if copiou { "copiado" } else { "NÃO copiado" }
            ));
            if let Some(r) = &self.rascunho {
                por_texto(self.c.texto, &para_o_editor(&r.rascunho));
            }
        }
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    fn manter_o_meu(&mut self, hwnd: HWND) {
        if let Some(r) = &mut self.rascunho {
            r.manter_o_meu();
        }
        registro::linha("teleprompter: editor: a pessoa manteve o rascunho dela contra o texto do outro lado");
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// **"Abrir arquivo .txt…"**: o diálogo de abrir do Windows numa thread **STA** própria (esta
    /// é MTA, como o processo, e o `IFileOpenDialog` pede STA), com esta janela de dona — ela fica
    /// desabilitada enquanto o diálogo está aberto, e o laço daqui continua bombeando mensagens. A
    /// thread lê e decodifica o arquivo e avisa por [`WM_ARQUIVO_DO_ROTEIRO`]; um diálogo de cada vez.
    fn abrir_arquivo_no_editor(&mut self, hwnd: HWND) {
        if self.rascunho.is_none() {
            return;
        }
        if DIALOGO_DO_ROTEIRO.swap(true, Ordering::SeqCst) {
            return;
        }
        let dona = hwnd.0 as isize;
        let r = std::thread::Builder::new().name("quall.abrir-roteiro".into()).spawn(move || {
            let dona = HWND(dona as *mut core::ffi::c_void);
            let r = match escolher_arquivo_de_roteiro(dona) {
                Ok(Some(caminho)) => {
                    let lido = ler_roteiro_do_disco(&caminho);
                    ArquivoDoRoteiro::Lido(caminho, lido)
                }
                Ok(None) => ArquivoDoRoteiro::Cancelado,
                Err(e) => ArquivoDoRoteiro::SemDialogo(e),
            };
            if let Ok(mut g) = ARQUIVO_DO_ROTEIRO.lock() {
                *g = Some(r);
            }
            DIALOGO_DO_ROTEIRO.store(false, Ordering::SeqCst);
            unsafe {
                // A janela pode ter fechado com o diálogo aberto: o aviso cai no vazio, e o
                // resultado fica para ninguém (o próximo diálogo o substitui).
                let _ = PostMessageW(Some(dona), WM_ARQUIVO_DO_ROTEIRO, WPARAM(0), LPARAM(0));
            }
        });
        if let Err(e) = r {
            DIALOGO_DO_ROTEIRO.store(false, Ordering::SeqCst);
            registro::linha(format!("teleprompter: !! a thread do diálogo de abrir não nasceu: {e}"));
            self.mensagem_do_editor = "Não consegui abrir a janela de escolher arquivo.".into(); // i18n: chave
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }

    /// O arquivo escolhido (pelo diálogo ou pela ação de bancada `arquivo-no-editor`): o texto entra
    /// no editor **como se fosse colado** (no cursor, por cima da seleção, com desfazer), e o
    /// Confirmar continua sendo quem aplica; acima do teto, a frase de sempre e nada entra.
    fn arquivo_escolhido(&mut self, hwnd: HWND, r: ArquivoDoRoteiro) {
        if self.rascunho.is_none() {
            registro::linha("teleprompter: editor: o arquivo chegou com o editor fechado — ignorado");
            return;
        }
        match r {
            ArquivoDoRoteiro::Cancelado => return,
            ArquivoDoRoteiro::SemDialogo(e) => {
                registro::linha(format!("teleprompter: !! o diálogo de abrir não abriu: {e}"));
                self.mensagem_do_editor = "Não consegui abrir a janela de escolher arquivo.".into(); // i18n: chave
            }
            ArquivoDoRoteiro::Lido(caminho, Err(recusa)) => {
                registro::linha(format!("teleprompter: editor: o arquivo {} não entrou: {recusa:?}", caminho.display()));
                self.mensagem_do_editor = recusa.frase(TETO_DO_TEXTO);
            }
            ArquivoDoRoteiro::Lido(caminho, Ok(texto)) => {
                let largo: Vec<u16> = para_o_editor(&texto).encode_utf16().chain(std::iter::once(0)).collect();
                unsafe {
                    SendMessageW(self.c.texto, windows::Win32::UI::Controls::EM_REPLACESEL, Some(WPARAM(1)), Some(LPARAM(largo.as_ptr() as isize)));
                    let _ = SetFocus(Some(self.c.texto));
                }
                self.sincronizar_rascunho();
                self.mensagem_do_editor.clear();
                registro::linha(format!(
                    "teleprompter: editor: o arquivo {} entrou no editor ({} bytes; o rascunho tem {} bytes)",
                    caminho.display(),
                    texto.len(),
                    self.rascunho.as_ref().map_or(0, |r| r.rascunho.len())
                ));
            }
        }
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// Chegou texto do outro lado com o editor aberto: a regra de `regras::Rascunho`.
    fn texto_chegou_com_o_editor_aberto(&mut self, hwnd: HWND) {
        self.sincronizar_rascunho();
        let novo = self.texto.clone();
        let Some(r) = &mut self.rascunho else { return };
        let alterado = r.alterado();
        r.chegou(&novo);
        let (conflito, rascunho) = (r.em_conflito(), r.rascunho.clone());
        if !alterado {
            por_texto(self.c.texto, &para_o_editor(&rascunho));
        }
        registro::linha(format!(
            "teleprompter: editor aberto: chegou texto do outro lado ({} bytes) — rascunho {} (conflito={conflito})",
            novo.len(),
            if alterado { "alterado: aviso de conflito, o rascunho fica como está" } else { "sem alteração: o texto novo entrou no editor" }
        ));
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    // -----------------------------------------------------------------------------------------
    // O tique: o que a sessão publicou, as ações de bancada, o salvo
    // -----------------------------------------------------------------------------------------

    /// **O cartão do código da sessão do teleprompter**, lido a cada tique (o núcleo não acorda a janela
    /// quando o código aparece). No prompter, só o do anfitrião (os três números); no controle, só o do
    /// convidado, e só enquanto a sessão não subiu.
    fn ler_o_codigo_da_sessao(&mut self, hwnd: HWND) {
        let atual = self.sessao.as_ref().filter(|s| !s.terminou()).and_then(|s| s.confirmacao());
        let leitura = atual.as_ref().map(|d| crate::conexao::ler(&d.c));
        let anfitriao = self.lado == Some(Lado::Prompter);
        let conectada = self.painel.as_ref().is_some_and(|p| p.fase == Fase::Conectada);
        let cartao = leitura
            .as_ref()
            .and_then(crate::conexao::cartao)
            .filter(|c| c.do_anfitriao() == anfitriao && !(conectada && !anfitriao))
            .zip(atual.as_ref())
            .map(|(c, d)| c.da_espera(d.id));
        let aviso = if anfitriao { leitura.as_ref().and_then(crate::conexao::aviso_do_anfitriao) } else { None };
        if cartao != self.codigo_da_sessao || aviso != self.aviso_do_codigo {
            if self.codigo_da_sessao.is_none() && cartao.is_some() {
                registro::linha(format!(
                    "teleprompter: código na tela ({}), esperando a pessoa",
                    if anfitriao { "três números no prompter" } else { "o do controle" } // i18n: fora (diário)
                ));
            }
            self.codigo_da_sessao = cartao;
            self.aviso_do_codigo = aviso;
            self.posicionar(hwnd);
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }

    /// **O toque num dos três números (ou no "Nenhum destes") do prompter**: vai com a tentativa do
    /// cartão desenhado, e só no confirmador que o produziu (`toque_vale`). Devolve se o cartão era da
    /// sessão do teleprompter (a tela R5 também tem o do vídeo).
    pub(super) fn tocar_no_codigo_da_sessao(&mut self, indice: Option<usize>) -> bool {
        let Some(c) = self.codigo_da_sessao.clone().filter(|c| c.do_anfitriao()) else { return false };
        let atual = self.sessao.as_ref().and_then(|s| s.confirmacao());
        if !crate::conexao::toque_vale(&c, atual.as_ref().map(|d| d.id)) {
            return false;
        }
        let Some(conf) = atual.map(|d| d.c) else { return false };
        let (valeu, o_que) = match indice {
            None => (conf.recusar(c.tentativa), "nenhum destes".to_string()), // i18n: fora (diário)
            Some(i) => {
                let valeu = conf.escolher(c.tentativa, i);
                let errou = valeu && conf.retrato().escolha_errada;
                (valeu, format!("escolha {} de 3{}", i + 1, if errou { ", errada: o código desta espera acabou" } else { "" })) // i18n: fora (diário)
            }
        };
        registro::linha(format!(
            "teleprompter: prompter: código: {o_que} (tentativa {}){}",
            c.tentativa,
            if valeu { "" } else { " — ignorado: a tentativa já mudou" } // i18n: fora (diário)
        ));
        true
    }

    fn tique(&mut self, hwnd: HWND) {
        // O arrasto da linha: o valor que ficou esperando o intervalo sai assim que ele vence (e
        // antes do limite de 50 ms do tique, que atrasaria o envio).
        if self.arrastando {
            if let Some(v) = self.limite_do_arrasto.tique(self.segundos()) {
                self.enviar_linha(hwnd, v);
            }
        }
        self.passo_do_arrasto_de_bancada(hwnd);
        self.passo_do_enquadramento_de_bancada(hwnd);
        let agora = Instant::now();
        if !self.acordado && agora.duration_since(self.ultimo_tique) < Duration::from_millis(50) {
            return;
        }
        self.acordado = false;
        self.ultimo_tique = agora;

        // **O idioma mudou** (o seletor "PT | EN" da janela principal, em outra thread): os rótulos
        // dos controles são reescritos, e a janela inteira repintada (o que é pintado usa `idioma::t`).
        let versao = idioma::versao();
        if versao != self.versao_do_idioma {
            self.versao_do_idioma = versao;
            self.trocar_de_idioma(hwnd);
        }

        // O diagrama que ficou pronto.
        if let Some(d) = self.diagramador.as_ref().and_then(|d| d.pegar()) {
            self.aplicar_diagrama(hwnd, d);
        }
        if let Some(f) = self.diagramador.as_ref().and_then(|d| d.pegar_falha()) {
            registro::linha(format!("teleprompter: !! a quebra do texto falhou: {f}"));
        }
        // A fonte automática que ficou pronta.
        self.aplicar_fonte_automatica(hwnd);

        // O que a sessão publicou.
        let mut bits = 0;
        if let Some(s) = self.sessao.clone() {
            bits = s.tirar_mudancas();
            let p = s.painel().clone();
            let mudou_painel = self.painel.as_ref().map(|a| a.versao) != Some(p.versao);
            if mudou_painel {
                if p.fase == Fase::Conectada && self.painel.as_ref().map(|a| a.fase) != Some(Fase::Conectada) {
                    self.eventos_de_aviso.push(format!("{:.3}s conectada", self.segundos()));
                    // Uma sessão nova pode ser outro prompter: a recusa da anterior não vale — nem
                    // a da pergunta (ela vale por sessão, §11.4).
                    self.recusa_do_segurar = None;
                    self.recusa_da_pergunta = None;
                }
                self.painel = Some(p);
                self.posicionar(hwnd);
            }
        }
        if let Some(t) = &self.teleprompter {
            self.estado = t.estado().ok();
        }
        self.ler_o_codigo_da_sessao(hwnd);
        // Uma cópia nova do roteiro (§11.5): grave o salvo já.
        if bits & mudou::COPIA_DO_TEXTO != 0 {
            if let Some(l) = self.lado {
                super::salvar(l);
                registro::linha("teleprompter: cópia nova do roteiro: salvo gravado");
            }
        }
        self.depois_do_estado(hwnd, bits);
        self.r5_tique(hwnd, bits);
        // §17 do contrato da câmera: o botão da câmera do prompter aparece e some com ela.
        if self.controle_camera_visivel() != self.camera_do_prompter_mostrada {
            self.posicionar(hwnd);
        }

        // Bancada: a escolha pedida sai quando a caixa abrir com os botões ligados, pelo mesmo
        // caminho do clique.
        if let Some(manter_o_meu) = self.escolha_pendente {
            let pronta = matches!(self.estado_da_caixa(), regras::EstadoDaCaixa::Aberta { botoes_ligados: true, .. })
                && self.pergunta_mostrada.is_some();
            if pronta {
                self.escolha_pendente = None;
                registro::linha(format!(
                    "teleprompter: bancada: a caixa abriu; respondendo \"{}\"",
                    if manter_o_meu { regras::PERGUNTA_MANDAR_O_MEU } else { regras::PERGUNTA_USAR_O_DO_PROMPTER }
                ));
                self.comando(hwnd, if manter_o_meu { ID_MANDAR_O_MEU } else { ID_USAR_DO_PROMPTER }, BN_CLICKED);
            }
        }

        // A lista do controle: de volta ao formulário (a sessão acabou), a procura volta.
        let sessao_viva = self.sessao.as_ref().is_some_and(|s| !s.terminou());
        if self.modo == Modo::Controle && self.busca.is_none() && !sessao_viva && self.teleprompter.is_some() {
            let b = descoberta::Busca::de_prompters(identidade::device_id());
            b.comecar();
            self.busca = Some(b);
            self.revisao_da_lista = 0;
        }
        if let Some(b) = &self.busca {
            let (revisao, aparelhos) = {
                let l = b.lista();
                (l.revisao, l.aparelhos.clone())
            };
            if revisao != self.revisao_da_lista {
                self.revisao_da_lista = revisao;
                self.prompters = aparelhos;
                unsafe {
                    SendMessageW(self.c.lista, LB_RESETCONTENT, None, None);
                    for p in &self.prompters {
                        let largo: Vec<u16> = p.linha_do_prompter().encode_utf16().chain(std::iter::once(0)).collect();
                        SendMessageW(self.c.lista, LB_ADDSTRING, None, Some(LPARAM(largo.as_ptr() as isize)));
                    }
                }
                registro::linha(format!(
                    "teleprompter: lista: {} prompter(s){}",
                    self.prompters.len(),
                    self.prompters.iter().map(|p| format!(" — {}", p.linha_do_prompter())).collect::<String>()
                ));
            }
        }

        // Bancada: conectar sozinho, as ações devidas, o prazo.
        if self.modo == Modo::Controle && !self.conexao_automatica_feita {
            if let Some(alvo) = self.cfg.prompter.clone() {
                if self.segundos() >= 0.5 {
                    self.conexao_automatica_feita = true;
                    registro::linha(format!("teleprompter: bancada: conectando em {alvo} sem esperar o dedo de ninguém"));
                    self.conectar(hwnd, Some(alvo));
                }
            }
        }
        while let Some((segundos, acao)) = self.acoes.acoes.get(self.proxima_acao).cloned() {
            if self.segundos() < segundos {
                break;
            }
            self.proxima_acao += 1;
            self.executar(hwnd, acao);
        }
        if let Some(s) = self.cfg.sair_apos {
            if self.segundos() >= s as f64 {
                self.cfg.sair_apos = None;
                registro::linha(format!("teleprompter: bancada: --sair-apos {s} venceu; fechando pelo caminho do Fechar"));
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
                }
            }
        }
        if self.salvar_em.is_some_and(|t| agora >= t) {
            self.salvar_em = None;
            if let Some(l) = self.lado {
                super::salvar(l);
            }
        }
        if self.cfg.bancada && agora.duration_since(self.ultimo_registro) >= Duration::from_secs(2) {
            self.ultimo_registro = agora;
            self.registrar_estado();
        }
    }

    /// Os bits que chegaram e o estado novo: texto, salto, layout, avisos.
    fn depois_do_estado(&mut self, hwnd: HWND, bits: u32) {
        let Some(t) = self.teleprompter.clone() else { return };
        if bits & mudou::TEXTO != 0 {
            if let Ok(novo) = t.texto() {
                self.trocar_texto(hwnd, novo);
                if self.rascunho.is_some() {
                    self.texto_chegou_com_o_editor_aberto(hwnd);
                }
            }
        }
        if self.modo == Modo::Prompter {
            if bits & mudou::FONTE != 0 {
                // "Vale o último que mudou": a fonte do controle vence, e a automática sai (§5).
                self.desligar_fonte_automatica("o controle mudou a fonte"); // i18n: chave (o motivo do aviso)
            }
            if bits & (mudou::FONTE | mudou::MARGEM) != 0 {
                self.pedir_layout(hwnd);
            }
            // Uma edição local de fonte ou margem não traz bit, e a janela pode ter mudado de
            // tamanho: a geometria é conferida contra o estado a cada vez (o pedido só sai quando
            // texto, fonte ou largura mudaram). O mesmo para a fonte automática (texto e coluna).
            self.pedir_layout(hwnd);
            self.pedir_fonte_automatica(hwnd);
            if bits & mudou::SALTO != 0 {
                // Os vistos são lidos **antes** de aplicar: um salto que chegue no meio fica para
                // a volta seguinte, e o relato de posição espera por ele.
                let vistos = self.sessao.as_ref().map(|s| s.saltos_vistos());
                if let Some(alvo) = self.estado.as_ref().and_then(|e| e.salto) {
                    self.ir_ao_salto(hwnd, alvo);
                }
                if let Some(v) = vistos {
                    self.saltos_aplicados = v;
                }
            }
            // `ROLANDO` e `SEGURAR` (§12.5): o quadro relê `rolando` e `para_tras` a cada volta;
            // aqui só o fim. Para trás, o fim não é fim: o texto sai dele.
            if bits & (mudou::ROLANDO | mudou::SEGURAR) != 0 {
                let (rolando, para_tras) = self.estado.as_ref().map(|e| (e.rolando, e.para_tras)).unwrap_or((false, false));
                if bits & mudou::SEGURAR != 0 {
                    registro::linha(format!(
                        "teleprompter: segurar (do controle): rolando={rolando} para_tras={para_tras} segurando={} posicao={:.4}",
                        self.estado.as_ref().is_some_and(|e| e.segurando),
                        self.diagramado.geometria.posicao_do_deslocamento(self.rolagem.deslocamento)
                    ));
                }
                if rolando && !para_tras && self.rolagem.no_fim(&self.diagramado.geometria) {
                    self.fim_avisado = true;
                    self.chegou_ao_fim(hwnd);
                }
            }
        }
        if self.modo == Modo::Controle {
            // **O texto parou com o dedo no botão** (a queda, o silêncio de 2,5 s, a pausa no
            // prompter, o fim do texto): o `segurando` voltou a `false` sem soltar. A tela avisa e
            // não aperta de novo sozinha.
            let (segurando, rolando, posicao) =
                self.estado.as_ref().map(|e| (e.segurando, e.rolando, e.posicao)).unwrap_or((false, false, 0.0));
            if self.dedos.observar(segurando, rolando) {
                let texto = format!(
                    "o texto parou com o dedo no botão (queda, silêncio, pausa ou fim do texto; posição {posicao:.4}): \"{}\"", // i18n: fora (diário)
                    self.dedos.aviso_do_texto_parado(posicao).unwrap_or_default()
                );
                registro::linha(format!("teleprompter: segurar: {texto}"));
                self.eventos_do_segurar.push(format!("{:.3}s {texto}", self.segundos()));
            }
            // A repintura do modo vem da chave das faixas, que leva o estado dele.
            // A pergunta do texto: o que a caixa mostra acompanha o estado (bit `_TEXT_QUESTION`
            // ou não — a comparação é pelos resumos).
            self.atualizar_pergunta_mostrada();
        }
        // Os avisos.
        let ligacao = self.painel.as_ref().map(|p| p.ligacao).unwrap_or(regras::Ligacao::SemSessao);
        if let Some(e) = &self.estado {
            let a = Avisos::calcular(e, ligacao, self.sessao.as_ref().map(|s| s.segundos()).unwrap_or(0.0));
            if a.par_sumido != self.avisos.par_sumido {
                let texto = format!(
                    "aviso {}: {}",
                    if self.modo == Modo::Prompter { "de controle sumido" } else { "de prompter sumido" }, // i18n: fora (diário)
                    if a.par_sumido { "LIGADO" } else { "desligado" }
                );
                registro::linha(format!("teleprompter: {texto}"));
                self.eventos_de_aviso.push(format!("{:.3}s {texto}", self.segundos()));
            }
            if a.sem_confirmacao != self.avisos.sem_confirmacao {
                let texto = format!("aviso de comando que não chegou: {}", if a.sem_confirmacao { "LIGADO" } else { "desligado" }); // i18n: fora (diário)
                registro::linha(format!("teleprompter: {texto}"));
                self.eventos_de_aviso.push(format!("{:.3}s {texto}", self.segundos()));
            }
            self.avisos = a;
        }
        // As faixas só são repintadas quando o que elas dizem mudou.
        let chave = self.chave_das_faixas();
        if chave != self.chave_das_faixas {
            self.chave_das_faixas = chave;
            self.posicionar(hwnd);
            self.invalidar_faixas(hwnd);
        }
    }

    fn executar(&mut self, hwnd: HWND, a: Acao) {
        self.acoes_executadas += 1;
        match &a {
            Acao::Texto(t) => registro::linha(format!("teleprompter: bancada: ação texto={} bytes", t.len())),
            Acao::Rascunho(t) => registro::linha(format!("teleprompter: bancada: ação rascunho+=\"{t}\"")),
            outra => registro::linha(format!("teleprompter: bancada: ação {outra:?}")),
        }
        // Pelo mesmo caminho dos botões.
        match a {
            Acao::Fonte(v) => {
                self.desligar_fonte_automatica("a fonte foi mudada aqui"); // i18n: chave
                self.editar(hwnd, &format!("fonte={v}"), |t| t.definir_fonte(v));
            }
            Acao::Margem(v) => {
                self.editar(hwnd, &format!("margem={v}"), |t| t.definir_margem(v));
            }
            Acao::Linha(v) => {
                self.editar(hwnd, &format!("linha={v}"), |t| t.definir_linha_de_leitura(v));
            }
            Acao::Velocidade(v) => {
                self.editar(hwnd, &format!("velocidade={v}"), |t| t.definir_velocidade(v));
            }
            Acao::Espelho(v) => {
                self.editar(hwnd, &format!("espelho={v}"), |t| t.definir_espelho(v));
            }
            Acao::Rolando(v) => self.definir_rolando(hwnd, v),
            Acao::Salto(v) => self.saltar(hwnd, v),
            Acao::Pular(v) => self.pular(hwnd, v),
            Acao::Texto(t) => {
                self.aplicar_texto_local(hwnd, &t);
            }
            Acao::Acrescentar(l) => {
                let sep = if self.texto.is_empty() || self.texto.ends_with('\n') { "" } else { "\n" };
                let novo = format!("{}{sep}{l}", self.texto);
                self.aplicar_texto_local(hwnd, &novo);
            }
            Acao::ArquivoNoEditor(caminho) => {
                let r = ler_roteiro_do_disco(std::path::Path::new(&caminho));
                self.arquivo_escolhido(hwnd, ArquivoDoRoteiro::Lido(PathBuf::from(caminho), r));
            }
            Acao::Rascunho(l) => {
                if self.rascunho.is_none() {
                    registro::linha("teleprompter: !! rascunho+ com o editor fechado");
                } else {
                    let atual = do_editor(&texto_de(self.c.texto));
                    let sep = if atual.is_empty() || atual.ends_with('\n') { "" } else { "\n" };
                    por_texto(self.c.texto, &para_o_editor(&format!("{atual}{sep}{l}")));
                    self.sincronizar_rascunho();
                }
            }
            Acao::Editor(c) => {
                match c {
                    ComandoDoEditor::Abrir => self.abrir_editor(hwnd),
                    ComandoDoEditor::Confirmar => self.confirmar_editor(hwnd),
                    ComandoDoEditor::Cancelar => self.fechar_editor(hwnd),
                    ComandoDoEditor::UsarNovo => self.usar_o_texto_novo(hwnd),
                    ComandoDoEditor::ManterMeu => self.manter_o_meu(hwnd),
                }
                registro::linha(format!(
                    "teleprompter: editor: {c:?} → aberto={} conflito={} texto={} bytes resumo={}",
                    self.rascunho.is_some(),
                    self.rascunho.as_ref().is_some_and(|r| r.em_conflito()),
                    self.texto.len(),
                    resumo(&self.texto)
                ));
            }
            Acao::Captura(caminho) => {
                // A janela é repintada inteira antes: a captura mostra o estado de agora.
                unsafe {
                    let _ = RedrawWindow(Some(hwnd), None, None, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
                }
                match bancada::capturar_janela(hwnd, std::path::Path::new(&caminho)) {
                    Ok((w, h, pintou)) => {
                        registro::linha(format!(
                            "teleprompter: captura da própria janela: {caminho} ({w}x{h}, {})",
                            if pintou { "com conteúdo" } else { "PRETA — a janela não se pintou" } // i18n: fora (bancada)
                        ));
                        self.capturas.push(format!("{caminho} ({})", if pintou { "com conteúdo" } else { "preta" })); // i18n: fora (bancada)
                    }
                    Err(e) => registro::linha(format!("teleprompter: !! captura falhou: {e}")),
                }
            }
            Acao::ArrastarLinha(v) => {
                let de = self.estado_ou_padrao().linha_de_leitura;
                self.arrasto_de_bancada = Some((Instant::now(), de, v, 0));
            }
            Acao::ArrastarEnquadramento(qual, v) => {
                let par = self.par_do_enquadramento(hwnd);
                let de = if qual == 0 { par.0 } else { par.1 };
                self.enquadramento_de_bancada = Some((Instant::now(), qual, de, v, 0));
            }
            Acao::FonteAutomatica(ligada) => {
                // Pelo mesmo caminho do clique: o botão muda de estado e o comando é o dele.
                unsafe {
                    SendMessageW(self.c.fonte_auto, BM_SETCHECK, Some(WPARAM(if ligada { BST_CHECKED } else { 0 })), None);
                }
                self.comando(hwnd, ID_FONTE_AUTO, BN_CLICKED);
            }
            Acao::ModoSegurar(ligado) => {
                self.comando(hwnd, if ligado { ID_SEGURAR } else { ID_SAIR_DO_SEGURAR }, BN_CLICKED);
            }
            // A resposta à pergunta, pelo método do botão; pendente até a caixa abrir.
            Acao::Escolha(manter_o_meu) => {
                self.escolha_pendente = Some(manter_o_meu);
            }
            // "Roteiros guardados": o clique no botão de cada coisa.
            Acao::Roteiros(c) => {
                use regras::ComandoDosRoteiros as R;
                let id = match c {
                    R::Abrir => ID_ROTEIROS,
                    R::Fechar => ID_FECHAR_ROTEIROS,
                    R::VoltarALista => ID_VOLTAR_A_LISTA,
                    R::Ver(n) => ID_ITEM_DOS_ROTEIROS + 3 * (n - 1),
                    R::Usar(n) => ID_ITEM_DOS_ROTEIROS + 3 * (n - 1) + 1,
                    R::Apagar(n) => ID_ITEM_DOS_ROTEIROS + 3 * (n - 1) + 2,
                    R::Sim => ID_CONFIRMA_SIM,
                    R::Nao => ID_CONFIRMA_NAO,
                };
                self.comando(hwnd, id, BN_CLICKED);
                registro::linha("teleprompter: navegação dos roteiros guardados concluída");
            }
            // Pelo mesmo caminho do clique: a marca do botão muda, e o comando é o dele (que a
            // desfaz se houver um dedo num botão de rolar).
            Acao::InverterBotoes(ligado) => {
                unsafe {
                    SendMessageW(self.c.inverter, BM_SETCHECK, Some(WPARAM(if ligado { BST_CHECKED } else { 0 })), None);
                }
                self.comando(hwnd, ID_INVERTER, BN_CLICKED);
            }
            // O mouse no meio de um botão grande, por mensagens postadas à própria janela: o mesmo
            // `wndproc` (e a mesma captura) da mão.
            Acao::Apertar(b) => {
                let r = self.retangulo_do_botao(hwnd, b);
                let (x, y) = ((r.left + r.right) / 2, (r.top + r.bottom) / 2);
                self.ponto_do_mouse_de_bancada = (x, y);
                let lp = LPARAM((((y as u32) & 0xFFFF) << 16 | ((x as u32) & 0xFFFF)) as isize);
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_LBUTTONDOWN, WPARAM(1), lp);
                }
            }
            Acao::SoltarBotao => {
                let (x, y) = self.ponto_do_mouse_de_bancada;
                let lp = LPARAM((((y as u32) & 0xFFFF) << 16 | ((x as u32) & 0xFFFF)) as isize);
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_LBUTTONUP, WPARAM(0), lp);
                }
            }
            // As teclas, pela fila da thread: o laço as entrega a `tecla`/`tecla_solta`, como as do
            // teclado. A repetição leva o bit 30 do `lParam`, como o Windows a manda.
            Acao::TeclaDesce(b, repeticao) => {
                let vk = if b == regras::BotaoDeSegurar::Cima { 0x26 } else { 0x28 };
                let lp = LPARAM(if repeticao { 1 | (1 << 30) } else { 1 });
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_KEYDOWN, WPARAM(vk), lp);
                }
            }
            Acao::TeclaSobe(b) => {
                let vk = if b == regras::BotaoDeSegurar::Cima { 0x26 } else { 0x28 };
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_KEYUP, WPARAM(vk), LPARAM(1 | (1 << 30) | (1 << 31)));
                }
            }
        }
    }

    fn segundos(&self) -> f64 {
        self.aberta_em.elapsed().as_secs_f64()
    }

    fn registrar_estado(&self) {
        let Some(e) = &self.estado else { return };
        let fase = self.painel.as_ref().map(|p| format!("{:?}", p.fase)).unwrap_or_else(|| "sem sessão".into()); // i18n: fora (diário)
        let mut linha = format!(
            "teleprompter: estado ({}, fase={fase}): rolando={} velocidade={} fonte={} margem={} linha={} espelho={} \
             posicao={} texto={} par_visto_ha_ms={} sem_confirmacao_ha_ms={} aviso_par_sumido={} aviso_sem_confirmacao={}",
            if self.modo == Modo::Prompter { "prompter" } else { "controle" },
            e.rolando,
            e.velocidade,
            e.fonte,
            e.margem,
            e.linha_de_leitura,
            e.espelho,
            e.posicao,
            e.texto_bytes,
            e.par_visto_ha_ms.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
            e.sem_confirmacao_ha_ms.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
            self.avisos.par_sumido,
            self.avisos.sem_confirmacao,
        );
        if self.modo == Modo::Prompter {
            let r = self.cadencia.resumo();
            linha.push_str(&format!(
                " | vista: posicao_mostrada={:.4} linhas={} quadros={} atrasados={} pelo_dwm={} maior_intervalo_ms={:.1} desenho_p99_ms={:.2}",
                self.diagramado.geometria.posicao_do_deslocamento(self.rolagem.deslocamento),
                self.diagramado.geometria.quantas_linhas(),
                r.quadros,
                r.atrasados,
                r.quadros_contados_pelo_dwm,
                r.maior_intervalo_ms,
                r.desenho_p99_ms
            ));
        }
        registro::linha(linha);
    }

    // -----------------------------------------------------------------------------------------
    // O layout do texto
    // -----------------------------------------------------------------------------------------

    fn area_do_texto(&self, hwnd: HWND) -> RECT {
        if let Some(a) = self.r5_area_do_texto(hwnd) {
            return a;
        }
        let mut c = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut c);
        }
        if !self.faixas_ocultas {
            c.top += escala(self.dpi, FAIXA_DE_CIMA);
            c.bottom -= escala(self.dpi, BARRA_DE_BAIXO);
        }
        if c.bottom < c.top {
            c.bottom = c.top;
        }
        c
    }

    /// A fonte em pixels e a largura da coluna de texto que o estado e o enquadramento pedem agora:
    /// a área entre as setas laterais, menos a `margem` (fração **dessa** área) de cada lado.
    fn medidas_pedidas(&self, hwnd: HWND) -> (f32, f32) {
        let e = self.estado_ou_padrao();
        let area = self.area_do_texto(hwnd);
        let largura = (area.right - area.left).max(40) as f64;
        let fonte_px = (e.fonte * f64::from(self.dpi) / 96.0) as f32;
        let (_, coluna) = Enquadramento::coluna(self.par_do_enquadramento(hwnd), largura, e.margem);
        (fonte_px, coluna.max(40.0) as f32)
    }

    /// Pede a quebra se o texto, a fonte ou a largura mudaram desde o último pedido.
    fn pedir_layout(&mut self, hwnd: HWND) {
        let Some(d) = &self.diagramador else { return };
        let (fonte_px, largura_px) = self.medidas_pedidas(hwnd);
        let chave = (self.geracao_do_texto, fonte_px.to_bits(), largura_px as i32);
        if self.pedido == Some(chave) {
            return;
        }
        self.pedido = Some(chave);
        let geracao = self.proxima_geracao;
        self.proxima_geracao += 1;
        d.pedir(PedidoDeDiagrama {
            geracao,
            texto: Arc::clone(&self.texto_utf16),
            bytes: self.texto.len(),
            fonte_px,
            largura_px,
        });
    }

    /// O layout pedido ainda não chegou (a vista mostra o velho).
    fn layout_atrasado(&self) -> bool {
        self.diagramado.texto.len() != self.texto_utf16.len() || !Arc::ptr_eq(&self.diagramado.texto, &self.texto_utf16)
    }

    /// Troca o layout num quadro, **mantendo o lugar de quem lê**: o caractere que estava na linha
    /// de leitura continua nela.
    fn aplicar_diagrama(&mut self, hwnd: HWND, d: Diagramado) {
        let antes = std::mem::replace(&mut self.diagramado, d);
        // A seta a caminho era em pixels do layout velho.
        self.deslize = None;
        let g = &self.diagramado.geometria;
        if let Some(p) = self.posicao_pendente.take() {
            self.rolagem.ir(g.deslocamento_da_posicao(p), g);
        } else if antes.geometria.quantas_linhas() > 0 {
            let ponto = antes.geometria.ponto_de_leitura(self.rolagem.deslocamento);
            self.rolagem.ir(g.deslocamento_do_ponto(ponto), g);
        } else if let Some(e) = &self.estado {
            // A primeira vez: a posição que a réplica tem (um prompter que reabriu no meio).
            self.rolagem.ir(g.deslocamento_da_posicao(e.posicao), g);
        }
        self.fim_avisado = self.rolagem.no_fim(g);
        let (fonte_px, largura_px) = (self.diagramado.fonte_px, self.diagramado.largura_px);
        let custo = self.diagramado.custo_ms;
        let linhas = g.quantas_linhas();
        self.layouts.push((custo, f64::from(fonte_px), linhas, self.diagramado.bytes as u64));
        self.layout_aplicado_em = Some(Instant::now());
        registro::linha(format!(
            "teleprompter: layout: {} linhas de {:.1} px, largura {:.0} px, fonte {:.1} px, {} bytes, {:.1} ms na thread do diagramador",
            linhas,
            g.altura_da_linha,
            largura_px,
            fonte_px,
            self.diagramado.bytes,
            custo
        ));
        self.relatar_posicao(true);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    // -----------------------------------------------------------------------------------------
    // A rolagem: um quadro por retraço
    // -----------------------------------------------------------------------------------------

    /// O texto rolando nesta tela (o que a medida de 10 s conta).
    fn rolando_na_tela(&self) -> bool {
        self.modo == Modo::Prompter && self.estado.as_ref().is_some_and(|e| e.rolando) && self.desenho.is_some()
    }

    /// O laço de quadros roda: o texto rolando, ou uma seta do teclado levando-o a um alvo.
    fn precisa_de_quadro(&self) -> bool {
        self.rolando_na_tela()
            || (self.modo == Modo::Prompter && self.desenho.is_some() && self.deslize.is_some() && self.rascunho.is_none())
    }

    fn parou_de_rolar(&mut self) {
        self.ultimo_quadro = None;
        self.ultimo_refresh = None;
        self.proximo_prazo = None;
        // A janela de 10 s que estava aberta sai já, parcial: a pausa não pode esconder os socos.
        if self.janela_da_rolagem_desde.is_some() {
            self.fechar_a_janela_da_rolagem();
        }
    }

    /// **A linha de 10 s no diário** (`geometria::JanelaDaRolagem`), nas duas telas, e a escolha do
    /// alvo do Direct2D pela medida (`geometria::EscolhaDoAlvo`).
    fn fechar_a_janela_da_rolagem(&mut self) {
        let segundos = self.janela_da_rolagem_desde.take().map(|d| d.elapsed().as_secs_f64()).unwrap_or(0.0);
        self.janela_da_rolagem.periodo_ms = self.periodo_ms;
        let Some(r) = self.janela_da_rolagem.fechar() else { return };
        let tela = if self.r5.is_some() { "r5" } else { "texto" };
        let alvo = self.desenho.as_ref().map(|d| d.tipo_do_alvo()).unwrap_or("sem desenho"); // i18n: fora (diário)
        registro::linha(r.linha(tela, alvo, segundos));
        let (nova, troca) = self.escolha_do_alvo.depois(&r, self.periodo_ms);
        if nova != self.escolha_do_alvo {
            registro::linha(format!("teleprompter: rolagem: alvo do texto {:?} → {nova:?} ({troca:?})", self.escolha_do_alvo));
        }
        self.escolha_do_alvo = nova;
        let software = match troca {
            TrocaDoAlvo::Nada => return,
            TrocaDoAlvo::ParaSoftware => true,
            TrocaDoAlvo::ParaPadrao => false,
        };
        if let Some(d) = self.desenho.as_mut() {
            if !d.usar_software(software) {
                registro::linha("teleprompter: rolagem: o alvo padrão já falhou nesta janela; o texto fica no de software");
            }
        }
    }

    fn quadro(&mut self, hwnd: HWND) {
        let agora = Instant::now();
        let dt = self.ultimo_quadro.map(|t| agora.duration_since(t).as_secs_f64());
        self.ultimo_quadro = Some(agora);
        let velocidade = self.estado.as_ref().map(|e| e.velocidade).unwrap_or(1.0);
        // O "segurar para rolar" para trás (§12.5): a mesma velocidade, no outro sentido, parando
        // no começo sem mudar `rolando` — o texto fica ali até o controle soltar.
        let para_tras = self.estado.as_ref().is_some_and(|e| e.para_tras);
        let rolando = self.rolando_na_tela();
        let antes = self.rolagem.deslocamento;
        let chegou = match dt {
            _ if !rolando => false,
            Some(dt) if para_tras => {
                self.rolagem.recuar(dt, velocidade, &self.diagramado.geometria);
                self.fim_avisado = self.rolagem.no_fim(&self.diagramado.geometria);
                false
            }
            Some(dt) => self.rolagem.avancar(dt, velocidade, &self.diagramado.geometria),
            None => false,
        };
        let passo_px = self.rolagem.deslocamento - antes;
        // As setas do teclado: o alvo anda com o texto que rola, e o texto vai até ele. O primeiro
        // quadro (sem `dt`) conta um período.
        if let Some(mut d) = self.deslize {
            let g = &self.diagramado.geometria;
            d.acompanhar(passo_px, g);
            let chegou_ao_alvo = d.passo(&mut self.rolagem, dt.unwrap_or(self.periodo_ms / 1000.0), g);
            self.fim_avisado = self.rolagem.no_fim(g) && self.fim_avisado;
            self.deslize = (!chegou_ao_alvo).then_some(d);
            if chegou_ao_alvo {
                self.relatar_posicao(true);
            }
        }
        let comeco = Instant::now();
        if self.rascunho.is_none() {
            self.desenhar_texto(hwnd, None);
        }
        let custo_ms = comeco.elapsed().as_secs_f64() * 1000.0;
        unsafe {
            let _ = GdiFlush();
        }
        let retracos = self.esperar_o_retraco();
        if let Some(dt) = dt.filter(|_| rolando) {
            let intervalo_ms = dt * 1000.0;
            self.cadencia.quadro(intervalo_ms, custo_ms, retracos);
            self.janela_da_rolagem.quadro(intervalo_ms, passo_px, custo_ms, retracos);
            let desde = *self.janela_da_rolagem_desde.get_or_insert(agora);
            if desde.elapsed() >= JanelaDaRolagem::DURACAO {
                self.fechar_a_janela_da_rolagem();
            }
            // Os intervalos longos (mais de três períodos) vão para o registro **com a hora**: é o
            // que deixa casar um tranco com o que a janela fazia (uma captura, um layout, uma
            // edição) — o resumo da cadência só diz o tamanho do maior.
            if intervalo_ms > 3.0 * self.periodo_ms && self.intervalos_longos.len() < 30 {
                let texto = format!("{:.3}s {:.1} ms", self.segundos(), intervalo_ms);
                registro::linha(format!("teleprompter: intervalo longo entre quadros: {texto}"));
                self.intervalos_longos.push(texto);
            }
            // O tranco do iPhone: o maior intervalo no segundo seguinte a um layout novo.
            if self.layout_aplicado_em.is_some_and(|t| t.elapsed() < Duration::from_secs(1)) {
                self.maior_intervalo_perto_do_layout_ms = self.maior_intervalo_perto_do_layout_ms.max(intervalo_ms);
            }
        }
        self.relatar_posicao(false);
        if chegou || (self.rolagem.no_fim(&self.diagramado.geometria) && !self.fim_avisado) {
            self.fim_avisado = true;
            self.chegou_ao_fim(hwnd);
        }
    }

    /// Espera o próximo retraço. Com DWM: `DwmFlush` e o contador de retraços, que diz quantos
    /// passaram desde o quadro anterior. Sem DWM: um compasso de 60 Hz sem deriva.
    fn esperar_o_retraco(&mut self) -> Option<u64> {
        if self.dwm != Some(false) {
            let flush = unsafe { DwmFlush() };
            if flush.is_ok() {
                let mut info = DWM_TIMING_INFO { cbSize: std::mem::size_of::<DWM_TIMING_INFO>() as u32, ..Default::default() };
                if unsafe { DwmGetCompositionTimingInfo(HWND::default(), &mut info) }.is_ok() {
                    let refresh = info.cRefresh;
                    let taxa = info.rateRefresh;
                    if self.dwm.is_none() {
                        self.dwm = Some(true);
                        let (n, d) = (taxa.uiNumerator, taxa.uiDenominator);
                        if n > 0 && d > 0 {
                            self.periodo_ms = 1000.0 * f64::from(d) / f64::from(n);
                            self.cadencia.periodo_ms = self.periodo_ms;
                        }
                        registro::linha(format!(
                            "teleprompter: compasso: DWM, {:.3} Hz (período {:.3} ms)",
                            1000.0 / self.periodo_ms,
                            self.periodo_ms
                        ));
                    }
                    let delta = self.ultimo_refresh.map(|u| refresh.saturating_sub(u));
                    self.ultimo_refresh = Some(refresh);
                    return delta;
                }
            }
            if self.dwm.is_none() {
                registro::linha(format!(
                    "teleprompter: compasso: sem DWM ({}); relógio de 60 Hz — a cadência medida é a do laço, não a da tela",
                    flush.err().map(|e| e.to_string()).unwrap_or_else(|| "sem tempo de composição".into())
                ));
            }
            self.dwm = Some(false);
        }
        let periodo = Duration::from_secs_f64(self.periodo_ms / 1000.0);
        let prazo = self.proximo_prazo.map(|p| p + periodo).unwrap_or_else(|| Instant::now() + periodo);
        let agora = Instant::now();
        let prazo = if prazo < agora { agora + periodo } else { prazo };
        std::thread::sleep(prazo.saturating_duration_since(Instant::now()));
        self.proximo_prazo = Some(prazo);
        None
    }

    /// A vista relata onde o texto está, a no máximo 10 Hz — e **nunca** entre um salto que chegou
    /// e a aplicação dele (ver `Sessao::saltos_vistos`).
    fn relatar_posicao(&mut self, agora: bool) {
        if self.modo != Modo::Prompter {
            return;
        }
        if !agora && self.ultimo_relato_de_posicao.elapsed() < Duration::from_millis(100) {
            return;
        }
        if let Some(s) = &self.sessao {
            if s.saltos_vistos() != self.saltos_aplicados {
                return;
            }
        }
        if self.posicao_pendente.is_some() {
            return;
        }
        let g = &self.diagramado.geometria;
        if g.quantas_linhas() == 0 {
            return;
        }
        self.ultimo_relato_de_posicao = Instant::now();
        if let Some(t) = &self.teleprompter {
            let _ = t.definir_posicao(g.posicao_do_deslocamento(self.rolagem.deslocamento));
        }
    }

    /// O texto chegou ao fim rolando: o prompter para ali, e os dois lados veem "parado".
    fn chegou_ao_fim(&mut self, hwnd: HWND) {
        if !self.estado.as_ref().is_some_and(|e| e.rolando) {
            return;
        }
        registro::linha("teleprompter: o texto chegou ao fim rolando: parando");
        self.relatar_posicao(true);
        self.editar(hwnd, "rolando=false (fim do texto)", |t| t.definir_rolando(false)); // i18n: fora (diário)
    }

    /// O texto na área do meio. `hdc` dado (`WM_PAINT`, `WM_PRINTCLIENT`) ou o DC da janela.
    /// **O texto na área do meio, em buffer duplo.** O Direct2D desenha num DIB nosso (o quadro de
    /// trás) e um `BitBlt` o põe na janela — no DC dado (`WM_PAINT`, `WM_PRINTCLIENT`) ou no da
    /// janela (o laço de quadros).
    ///
    /// **Por que não direto no DC da janela**: medido na Sessão 0 em 14/09 — o `EndDraw` de um
    /// `ID2D1DCRenderTarget` ligado ao DC da janela devolvia `E_HANDLE` em todo quadro, no alvo
    /// padrão e no de software (sem monitor, o DC da janela não desenha). Num DIB o GDI desenha
    /// pelo motor de DIB, sem driver de vídeo: o desenho funciona nas duas sessões, e na Sessão 0
    /// só a cópia para a janela falha (contada em `copias_falhas`). É também o buffer duplo que o
    /// GDI pede para não piscar.
    fn desenhar_texto(&mut self, hwnd: HWND, hdc: Option<HDC>) {
        let area = self.area_do_texto(hwnd);
        let (w, h) = (area.right - area.left, area.bottom - area.top);
        if w < 4 || h < 4 {
            return;
        }
        if self.tras.as_ref().map(|t| (t.largura, t.altura)) != Some((w, h)) {
            self.tras = match bancada::Bitmap::novo(w, h) {
                Ok(b) => Some(b),
                Err(e) => {
                    registro::linha(format!("teleprompter: !! o quadro de trás não foi criado ({w}x{h}): {e}"));
                    None
                }
            };
        }
        let e = self.estado_ou_padrao();
        let altura = f64::from(h);
        let largura = f64::from(w);
        let par = self.ajustes.enquadramento.par(largura, altura);
        let sem_roteiro = idioma::t("Sem roteiro. Clique em Editar, ou mande o texto pelo controle.");
        let linha = self.linha_arrastada.unwrap_or(e.linha_de_leitura);
        let rotulo = self.linha_arrastada.map(|l| idioma::tf("Linha de leitura {}", &[&pct(l)]));
        let rotulo_do_enquadramento =
            self.enquadrando.map(|q| idioma::tf("Enquadramento {}", &[&pct(if q == 0 { par.0 } else { par.1 })]));
        let cena = Cena {
            diagramado: &self.diagramado,
            deslocamento: self.rolagem.deslocamento,
            y_leitura: linha * altura,
            setas_px: ((par.0 * largura) as f32, (par.1 * largura) as f32),
            px_por_dip: self.dpi as f32 / 96.0,
            espelho: e.espelho,
            vazio: self.texto.is_empty().then_some(sem_roteiro),
            rotulo_da_linha: rotulo.as_deref(),
            enquadrando: self.enquadrando.zip(rotulo_do_enquadramento.as_deref()),
            // Na tela R5 as guias só aparecem no arrasto: com as faixas à mostra elas ficariam, na
            // altura inteira da borda do texto, entre o texto e a lente (§8.5).
            guias: (self.r5.is_none() && !self.faixas_ocultas) || self.enquadrando.is_some(),
            marcas_no_pe: self.r5.as_ref().is_some_and(|r| r.lado.marcas_no_pe()),
        };
        let (Some(desenho), Some(tras)) = (&mut self.desenho, &self.tras) else { return };
        if let Err(e) = desenho.desenhar(tras.dc, RECT { left: 0, top: 0, right: w, bottom: h }, &cena) {
            self.falhas_de_desenho += 1;
            if self.falhas_de_desenho <= 3 {
                registro::linha(format!("teleprompter: !! o desenho do texto falhou: {e}"));
            }
        }
        if !self.avisou_software {
            if let Some(m) = &desenho.motivo_do_software {
                self.avisou_software = true;
                registro::linha(format!(
                    "teleprompter: o alvo padrão do Direct2D falhou ({m}); desenhando no alvo de software daqui em diante"
                ));
            }
        }
        let (dc, proprio) = match hdc {
            Some(h) => (h, false),
            None => (unsafe { GetDC(Some(hwnd)) }, true),
        };
        let copia = unsafe { BitBlt(dc, area.left, area.top, w, h, Some(tras.dc), 0, 0, SRCCOPY) };
        if copia.is_err() {
            self.copias_falhas += 1;
            if self.copias_falhas == 1 {
                registro::linha(format!(
                    "teleprompter: a cópia do quadro de trás para a janela falhou ({}) — sem monitor (Sessão 0) é o esperado; o desenho segue no quadro de trás",
                    copia.err().map(|e| e.to_string()).unwrap_or_default()
                ));
            }
        }
        if proprio {
            unsafe {
                ReleaseDC(Some(hwnd), dc);
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // As setas da linha de leitura, arrastáveis (pedido do usuário de 14/09)
    // -----------------------------------------------------------------------------------------

    /// `(x, y)`, em coordenadas de cliente, está na faixa da linha de leitura (ou nas setas, que
    /// ficam dentro dela)? Um arrasto que começa em qualquer outro lugar do texto não mexe na linha.
    fn na_faixa(&self, hwnd: HWND, x: i32, y: i32) -> bool {
        if self.modo != Modo::Prompter || self.rascunho.is_some() {
            return false;
        }
        let area = self.area_do_texto(hwnd);
        if x < area.left || x >= area.right || y < area.top || y >= area.bottom {
            return false;
        }
        let linha = self.linha_arrastada.unwrap_or(self.estado_ou_padrao().linha_de_leitura);
        let y_linha = f64::from(area.top) + linha * f64::from(area.bottom - area.top);
        let meia = (f64::from(self.diagramado.altura_px) / 2.0).max(f64::from(escala(self.dpi, 14)));
        (f64::from(y) - y_linha).abs() <= meia
    }

    fn fracao_da_linha(&self, hwnd: HWND, y: i32) -> f64 {
        let area = self.area_do_texto(hwnd);
        let h = f64::from((area.bottom - area.top).max(1));
        // A resolução do contrato é 1/10000; o valor do arrasto já sai nela.
        ((f64::from(y - area.top) / h).clamp(0.0, 1.0) * 10_000.0).round() / 10_000.0
    }

    fn comecar_arrasto(&mut self, hwnd: HWND, x: i32, y: i32) -> bool {
        if !self.na_faixa(hwnd, x, y) {
            return false;
        }
        self.arrastando = true;
        self.limite_do_arrasto = regras::LimiteDeEnvio::default();
        let antes = self.estado_ou_padrao().linha_de_leitura;
        self.arrasto_comecou_em = antes;
        self.mover_arrasto(hwnd, y);
        true
    }

    fn mover_arrasto(&mut self, hwnd: HWND, y: i32) {
        if !self.arrastando {
            return;
        }
        let v = self.fracao_da_linha(hwnd, y);
        self.linha_arrastada = Some(v);
        if let Some(mandar) = self.limite_do_arrasto.mover(self.segundos(), v) {
            self.enviar_linha(hwnd, mandar);
        }
        self.repintar_texto_parado(hwnd);
    }

    fn soltar_arrasto(&mut self, hwnd: HWND, y: Option<i32>) {
        if !self.arrastando {
            return;
        }
        self.arrastando = false;
        let v = match y {
            Some(y) => self.fracao_da_linha(hwnd, y),
            None => self.linha_arrastada.unwrap_or(self.arrasto_comecou_em),
        };
        let final_ = self.limite_do_arrasto.soltar(self.segundos(), v);
        self.enviar_linha(hwnd, final_);
        self.linha_arrastada = None;
        let texto = format!(
            "linha de leitura arrastada: {} → {} em {} envio(s)", // i18n: fora (diário)
            pct_do_diario(self.arrasto_comecou_em),
            pct_do_diario(final_),
            self.limite_do_arrasto.envios
        );
        registro::linha(format!("teleprompter: {texto}"));
        self.arrastos.push(format!("{:.3}s {texto}", self.segundos()));
        self.repintar_texto_parado(hwnd);
    }

    fn enviar_linha(&mut self, hwnd: HWND, v: f64) {
        self.editar(hwnd, &format!("linha={v} (arrasto)"), |t| t.definir_linha_de_leitura(v));
    }

    /// Com o texto parado, o laço de quadros não roda: o arrasto pede o redesenho da área do texto.
    fn repintar_texto_parado(&self, hwnd: HWND) {
        if !self.estado.as_ref().is_some_and(|e| e.rolando) {
            let area = self.area_do_texto(hwnd);
            unsafe {
                let _ = InvalidateRect(Some(hwnd), Some(&area), false);
            }
        }
    }

    /// Bancada: um arrasto de meio segundo, por mensagens de mouse postadas à própria janela — o
    /// mesmo caminho da mão (ver `Acao::ArrastarLinha`).
    fn passo_do_arrasto_de_bancada(&mut self, hwnd: HWND) {
        let Some((inicio, de, para, feitos)) = self.arrasto_de_bancada else { return };
        const PASSOS: u32 = 10;
        let devidos = ((inicio.elapsed().as_millis() / 50) as u32 + 1).min(PASSOS + 2);
        let area = self.area_do_texto(hwnd);
        let altura = f64::from(area.bottom - area.top);
        let x = area.left + escala(self.dpi, 8);
        let y_de = |f: f64| area.top + (f * altura).round() as i32;
        let lparam = |y: i32| LPARAM(((y as u32 & 0xFFFF) << 16 | (x as u32 & 0xFFFF)) as isize);
        let mut feitos_agora = feitos;
        while feitos_agora < devidos {
            let (msg, y) = match feitos_agora {
                0 => (WM_LBUTTONDOWN, y_de(de)),
                n if n <= PASSOS => (WM_MOUSEMOVE, y_de(de + (para - de) * f64::from(n) / f64::from(PASSOS))),
                _ => (WM_LBUTTONUP, y_de(para)),
            };
            unsafe {
                let _ = PostMessageW(Some(hwnd), msg, WPARAM(if msg == WM_LBUTTONUP { 0 } else { 1 }), lparam(y));
            }
            feitos_agora += 1;
        }
        self.arrasto_de_bancada = if feitos_agora > PASSOS + 1 { None } else { Some((inicio, de, para, feitos_agora)) };
    }

    // -----------------------------------------------------------------------------------------
    // O enquadramento: as duas setas laterais, locais (`docs/teleprompter-ajustes-locais.md` §2)
    // -----------------------------------------------------------------------------------------

    /// As setas do enquadramento na área do texto de agora, em fração da largura, na vista do texto
    /// (antes do espelho). A orientação é a da área: mais larga que alta é paisagem.
    fn par_do_enquadramento(&self, hwnd: HWND) -> (f64, f64) {
        let a = self.area_do_texto(hwnd);
        self.ajustes.enquadramento.par(f64::from(a.right - a.left), f64::from(a.bottom - a.top))
    }

    /// `(x, y)` pega uma seta do enquadramento? Qual (`0` = a da esquerda do texto). A área de pegar
    /// é uma coluna de ±16 DIP em volta da borda, na altura toda (o desenho é só o triângulo do
    /// alto) — fora da faixa da linha de leitura, que tem a vez: é lá que ficam as setas laranjas.
    fn na_seta_do_enquadramento(&self, hwnd: HWND, x: i32, y: i32) -> Option<usize> {
        if self.modo != Modo::Prompter || self.rascunho.is_some() || self.na_faixa(hwnd, x, y) {
            return None;
        }
        let area = self.area_do_texto(hwnd);
        if x < area.left || x >= area.right || y < area.top || y >= area.bottom {
            return None;
        }
        let w = (area.right - area.left) as f32;
        let par = self.par_do_enquadramento(hwnd);
        let espelho = self.estado_ou_padrao().espelho;
        let (na_tela_0, na_tela_1) = texto::setas_na_tela(((par.0 as f32) * w, (par.1 as f32) * w), w, espelho);
        let xr = (x - area.left) as f32;
        let alcance = escala(self.dpi, 16) as f32;
        let (d0, d1) = ((xr - na_tela_0).abs(), (xr - na_tela_1).abs());
        // Na tela, a da esquerda é a seta 0 sem espelho, e a 1 com espelho.
        let (esquerda, direita) = if espelho { (1, 0) } else { (0, 1) };
        if d0 <= alcance && d0 <= d1 {
            Some(esquerda)
        } else if d1 <= alcance {
            Some(direita)
        } else {
            None
        }
    }

    /// A fração da largura, na vista do texto, de um x de cliente (com espelho, invertida).
    fn fracao_do_enquadramento(&self, hwnd: HWND, x: i32) -> f64 {
        let area = self.area_do_texto(hwnd);
        let w = f64::from((area.right - area.left).max(1));
        let f = (f64::from(x - area.left) / w).clamp(0.0, 1.0);
        let f = if self.estado_ou_padrao().espelho { 1.0 - f } else { f };
        (f * 10_000.0).round() / 10_000.0
    }

    fn comecar_enquadramento(&mut self, hwnd: HWND, x: i32, y: i32) -> bool {
        let Some(qual) = self.na_seta_do_enquadramento(hwnd, x, y) else { return false };
        self.enquadrando = Some(qual);
        self.enquadramento_no_comeco = self.par_do_enquadramento(hwnd);
        self.mover_enquadramento(hwnd, x);
        true
    }

    fn mover_enquadramento(&mut self, hwnd: HWND, x: i32) {
        let Some(qual) = self.enquadrando else { return };
        let f = self.fracao_do_enquadramento(hwnd, x);
        let area = self.area_do_texto(hwnd);
        self.ajustes
            .enquadramento
            .mover(f64::from(area.right - area.left), f64::from(area.bottom - area.top), qual, f);
        // A coluna mudou: a quebra e a fonte automática são pedidas já (as threads delas ficam só
        // com o pedido mais novo, então arrastar não enfileira quebras).
        self.pedir_layout(hwnd);
        self.pedir_fonte_automatica(hwnd);
        self.repintar_texto_parado(hwnd);
    }

    fn soltar_enquadramento(&mut self, hwnd: HWND, x: Option<i32>) {
        let Some(qual) = self.enquadrando else { return };
        if let Some(x) = x {
            self.mover_enquadramento(hwnd, x);
        }
        self.enquadrando = None;
        super::gravar_ajustes(&self.ajustes);
        let par = self.par_do_enquadramento(hwnd);
        let (antes, depois) = if qual == 0 { (self.enquadramento_no_comeco.0, par.0) } else { (self.enquadramento_no_comeco.1, par.1) };
        let texto = format!(
            "enquadramento: a seta {} foi arrastada de {} para {} (as setas agora em {} e {}, gravadas)", // i18n: fora (diário)
            if qual == 0 { "da esquerda" } else { "da direita" }, // i18n: fora (diário)
            pct_do_diario(antes),
            pct_do_diario(depois),
            pct_do_diario(par.0),
            pct_do_diario(par.1)
        );
        registro::linha(format!("teleprompter: {texto}"));
        self.arrastos_do_enquadramento.push(format!("{:.3}s {texto}", self.segundos()));
        self.repintar_texto_parado(hwnd);
    }

    /// Bancada: o arrasto de uma seta do enquadramento, meio segundo, por mensagens de mouse
    /// postadas à própria janela — o mesmo caminho da mão (ver `Acao::ArrastarEnquadramento`).
    fn passo_do_enquadramento_de_bancada(&mut self, hwnd: HWND) {
        let Some((inicio, qual, de, para, feitos)) = self.enquadramento_de_bancada else { return };
        const PASSOS: u32 = 10;
        let devidos = ((inicio.elapsed().as_millis() / 50) as u32 + 1).min(PASSOS + 2);
        let area = self.area_do_texto(hwnd);
        let w = f64::from(area.right - area.left);
        let e = self.estado_ou_padrao();
        let x_de = |f: f64| area.left + ((if e.espelho { 1.0 - f } else { f }) * w).round() as i32;
        // Longe da faixa da linha de leitura (que tem a vez): no alto, onde fica o triângulo, ou
        // embaixo, se a linha estiver no alto.
        let y = if e.linha_de_leitura > 0.5 { area.top + escala(self.dpi, 12) } else { area.bottom - escala(self.dpi, 12) };
        let lparam = |x: i32| LPARAM((((y as u32) & 0xFFFF) << 16 | ((x as u32) & 0xFFFF)) as isize);
        let mut feitos_agora = feitos;
        while feitos_agora < devidos {
            let (msg, x) = match feitos_agora {
                // O botão desce **dentro** da área (a seta em 100 % fica na última coluna de pixels).
                0 => (WM_LBUTTONDOWN, x_de(de).min(area.right - 1).max(area.left)),
                n if n <= PASSOS => (WM_MOUSEMOVE, x_de(de + (para - de) * f64::from(n) / f64::from(PASSOS))),
                _ => (WM_LBUTTONUP, x_de(para)),
            };
            unsafe {
                let _ = PostMessageW(Some(hwnd), msg, WPARAM(if msg == WM_LBUTTONUP { 0 } else { 1 }), lparam(x));
            }
            feitos_agora += 1;
        }
        self.enquadramento_de_bancada =
            if feitos_agora > PASSOS + 1 { None } else { Some((inicio, qual, de, para, feitos_agora)) };
    }

    // -----------------------------------------------------------------------------------------
    // A fonte automática, local (`docs/teleprompter-ajustes-locais.md` §5)
    // -----------------------------------------------------------------------------------------

    /// O botão "Fonte automática" (ou a ação de bancada `fonte_auto`).
    fn ligar_fonte_automatica(&mut self, hwnd: HWND, ligada: bool) {
        self.ajustes.fonte_automatica = ligada;
        self.aviso_da_fonte = None;
        self.pedido_da_fonte = None;
        unsafe {
            SendMessageW(self.c.fonte_auto, BM_SETCHECK, Some(WPARAM(if ligada { BST_CHECKED } else { 0 })), None);
        }
        super::gravar_ajustes(&self.ajustes);
        let texto = format!("fonte automática {}", if ligada { "ligada" } else { "desligada pelo botão" }); // i18n: fora (diário)
        registro::linha(format!("teleprompter: {texto}"));
        self.eventos_de_aviso.push(format!("{:.3}s {texto}", self.segundos()));
        self.pedir_fonte_automatica(hwnd);
        self.acordado = true;
    }

    /// A fonte automática sai, com o aviso à mostra na faixa de cima até o botão ser apertado de
    /// novo: o controle mudou a fonte (§5), ou a pessoa mudou aqui.
    fn desligar_fonte_automatica(&mut self, motivo: &str) {
        if self.modo != Modo::Prompter || !self.ajustes.fonte_automatica {
            return;
        }
        self.ajustes.fonte_automatica = false;
        self.pedido_da_fonte = None;
        unsafe {
            SendMessageW(self.c.fonte_auto, BM_SETCHECK, Some(WPARAM(0)), None);
        }
        super::gravar_ajustes(&self.ajustes);
        // Guardado em português (o diário e o relato o leem assim); a tela traduz em
        // `aviso_da_fonte_mostrado`.
        let aviso = format!("Fonte automática desligada: {motivo}"); // i18n: fora (o estado; ver aviso_da_fonte_mostrado)
        registro::linha(format!("teleprompter: {aviso}"));
        self.eventos_de_aviso.push(format!("{:.3}s {aviso}", self.segundos()));
        self.aviso_da_fonte = Some(aviso);
        self.acordado = true;
    }

    /// Pede a conta se a fonte automática está ligada e o texto ou a coluna mudaram desde o último
    /// pedido. A coluna já traz o enquadramento, a `margem`, o tamanho da janela (a orientação) e a
    /// escala do monitor.
    fn pedir_fonte_automatica(&mut self, hwnd: HWND) {
        if self.modo != Modo::Prompter || !self.ajustes.fonte_automatica || self.texto_utf16.is_empty() {
            return;
        }
        let (_, largura) = self.medidas_pedidas(hwnd);
        let chave = (self.geracao_do_texto, largura as i32, self.dpi);
        if self.pedido_da_fonte.map(|p| (p.1, p.2, p.3)) == Some(chave) {
            return;
        }
        if self.fonte_automatica.is_none() {
            let alvo = hwnd.0 as isize;
            self.fonte_automatica = Some(FonteAutomatica::nova(Box::new(move || unsafe {
                let _ = PostMessageW(Some(HWND(alvo as *mut core::ffi::c_void)), WM_ACORDAR, WPARAM(0), LPARAM(0));
            })));
        }
        let geracao = self.proxima_geracao_da_fonte;
        self.proxima_geracao_da_fonte += 1;
        self.pedido_da_fonte = Some((geracao, chave.0, chave.1, chave.2));
        if let Some(f) = &self.fonte_automatica {
            f.pedir(PedidoDeFonte {
                geracao,
                texto: Arc::clone(&self.texto_utf16),
                bytes: self.texto.len(),
                largura_px: largura,
                px_por_dip: self.dpi as f32 / 96.0,
            });
        }
    }

    /// A conta que ficou pronta: vale se é a do último pedido e a fonte automática continua ligada.
    /// A fonte vai para o núcleo por `definir_fonte` (o controle vê a fonte que o prompter usa), e a
    /// âncora no caractere segura a leitura na troca (`aplicar_diagrama`).
    fn aplicar_fonte_automatica(&mut self, hwnd: HWND) {
        let Some(r) = self.fonte_automatica.as_ref().and_then(|f| f.pegar()) else { return };
        let vale = self.ajustes.fonte_automatica && self.pedido_da_fonte.is_some_and(|p| p.0 == r.geracao);
        let antes = self.estado_ou_padrao().fonte;
        registro::linha(format!(
            "teleprompter: fonte automática: {} em {} quebra(s) do roteiro inteiro, {:.1} ms na thread dela, {} bytes, coluna de {:.0} px{}{}",
            r.fonte.map(|f| format!("{f} pt")).unwrap_or_else(|| "nenhuma fonte de 8 a 400 cumpre a regra".into()),
            r.perguntas,
            r.custo_ms,
            r.bytes,
            r.largura_px,
            if vale { "" } else { " (descartada: pedido velho ou a automática saiu)" },
            r.falha.as_ref().map(|f| format!(" — falhou: {f}")).unwrap_or_default()
        ));
        self.fontes_automaticas.push(serde_json::json!({
            "t_s": (self.segundos() * 1000.0).round() / 1000.0,
            "fonte": r.fonte,
            "fonte_antes": antes,
            "quebras_do_roteiro_inteiro": r.perguntas,
            "custo_ms": (r.custo_ms * 10.0).round() / 10.0,
            "bytes": r.bytes,
            "largura_da_coluna_px": r.largura_px,
            "valeu": vale,
            "falha": r.falha,
        }));
        if !vale {
            return;
        }
        if let Some(f) = r.fonte {
            if (f - antes).abs() >= 0.05 {
                self.editar(hwnd, &format!("fonte={f} (automática)"), |t| t.definir_fonte(f)); // i18n: fora (diário)
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // "Segurar para rolar", no controle (§12 do contrato; o pedido às telas de 14/09)
    // -----------------------------------------------------------------------------------------

    /// O controle está mostrando o modo: a opção ligada, com uma sessão viva (conectada ou
    /// reconectando). Sem sessão, a tela é o formulário de conectar.
    fn modo_segurar(&self) -> bool {
        self.modo == Modo::Controle
            && self.ajustes.segurar_para_rolar
            && self.rascunho.is_none()
            && self.roteiros.is_none()
            && self.sessao.as_ref().is_some_and(|s| !s.terminou())
            // A pergunta do texto vem antes: com ela aberta, o roteiro não sincroniza.
            && !self.caixa_na_tela()
    }

    fn disponibilidade_do_segurar(&self) -> regras::DisponibilidadeDoSegurar {
        let conectada = self.painel.as_ref().is_some_and(|p| p.fase == Fase::Conectada);
        let e = self.estado_ou_padrao();
        regras::DisponibilidadeDoSegurar::calcular(
            conectada,
            self.avisos.par_sumido,
            e.par_visto_ha_ms.is_some(),
            e.par_entende_segurar,
            self.recusa_do_segurar == Some(regras::Codigo::Protocolo),
        )
    }

    /// A frase do modo sem sessão: o estado da conexão.
    fn estado_da_conexao_do_segurar(&self) -> String {
        let painel = self.painel.as_ref();
        match painel.map(|p| p.fase) {
            Some(Fase::SemPar) => idioma::t("Sem conexão com o prompter — tentando de novo. Os botões voltam com ele.").to_string(),
            Some(Fase::Encerrando) => idioma::t("Desconectando…").to_string(),
            _ => idioma::tf("Conectando em {}…", &[&painel.and_then(|p| p.endereco.clone()).unwrap_or_default()]),
        }
    }

    /// Os dois botões grandes, um em cima do outro, ocupando a tela abaixo da faixa de estado.
    fn retangulo_do_botao(&self, hwnd: HWND, b: regras::BotaoDeSegurar) -> RECT {
        let mut c = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut c);
        }
        let d = self.dpi;
        let (esquerda, direita) = (escala(d, 24), c.right - escala(d, 24));
        // A borda de cima é fixa: as faixas de aviso (y 64 e 88) nunca empurram os botões.
        let (topo, fundo) = (escala(d, 118), c.bottom - escala(d, 16));
        let vao = escala(d, 16);
        let meio = (fundo - topo - vao).max(2) / 2;
        match b {
            regras::BotaoDeSegurar::Cima => RECT { left: esquerda, top: topo, right: direita, bottom: topo + meio },
            regras::BotaoDeSegurar::Baixo => RECT { left: esquerda, top: topo + meio + vao, right: direita, bottom: fundo },
        }
    }

    /// Em que botão grande cai `(x, y)`.
    fn botao_em(&self, hwnd: HWND, x: i32, y: i32) -> Option<regras::BotaoDeSegurar> {
        [regras::BotaoDeSegurar::Cima, regras::BotaoDeSegurar::Baixo].into_iter().find(|b| {
            let r = self.retangulo_do_botao(hwnd, *b);
            x >= r.left && x < r.right && y >= r.top && y < r.bottom
        })
    }

    /// Um contato encostou. Devolve se ele caiu num botão ligado (e passa a ser acompanhado).
    fn segurar_desceu(&mut self, hwnd: HWND, contato: u32, x: i32, y: i32, origem: &str) -> bool {
        let Some(b) = self.botao_em(hwnd, x, y) else { return false };
        if !self.disponibilidade_do_segurar().botoes_ligados() {
            return false;
        }
        let c = self.dedos.desceu(contato, b);
        self.aplicar_segurar(hwnd, c, origem);
        true
    }

    fn segurar_moveu(&mut self, hwnd: HWND, contato: u32, x: i32, y: i32) {
        let em = self.botao_em(hwnd, x, y);
        let c = self.dedos.moveu(contato, em);
        if c != regras::ComandoDeSegurar::Nada {
            self.aplicar_segurar(hwnd, c, "contato saindo do botão"); // i18n: fora (diário)
        }
    }

    fn segurar_subiu(&mut self, hwnd: HWND, contato: u32, origem: &str) {
        let c = self.dedos.subiu(contato);
        self.aplicar_segurar(hwnd, c, origem);
        self.invalidar_segurar(hwnd);
    }

    /// Todos os contatos soltam: o segundo plano, a janela minimizada, a tela fechando, o modo
    /// desligado.
    fn segurar_soltar_todos(&mut self, hwnd: HWND, porque: &str) {
        if std::mem::take(&mut self.mouse_no_segurar) {
            unsafe {
                let _ = ReleaseCapture();
            }
        }
        let c = self.dedos.soltar_todos();
        self.aplicar_segurar(hwnd, c, porque);
    }

    /// Manda ao núcleo o que os contatos decidiram: `segurar(para_tras)` ou `soltar()`.
    fn aplicar_segurar(&mut self, hwnd: HWND, c: regras::ComandoDeSegurar, origem: &str) {
        let Some(t) = self.teleprompter.clone() else { return };
        if let Some(s) = &self.sessao {
            s.antes_de_editar();
        }
        let (nome, r) = match c {
            regras::ComandoDeSegurar::Nada => return,
            regras::ComandoDeSegurar::Segurar(b) => {
                let invertido = self.ajustes.inverter_botoes;
                (
                    format!(
                        "segurar \"{}\" ({}; para_tras={}{})",
                        b.rotulo(),
                        b.legenda(invertido),
                        b.para_tras(invertido),
                        if invertido { ", botões invertidos" } else { "" } // i18n: fora (diário)
                    ),
                    t.segurar(b.para_tras(invertido)),
                )
            }
            regras::ComandoDeSegurar::Soltar => ("soltar".to_string(), t.soltar()),
        };
        if let Some(s) = &self.sessao {
            s.depois_de_editar();
        }
        if matches!(c, regras::ComandoDeSegurar::Segurar(_)) {
            self.dedos.segurou(r.is_ok());
        }
        let resultado = match &r {
            Ok(()) => {
                if matches!(c, regras::ComandoDeSegurar::Segurar(_)) {
                    self.recusa_do_segurar = None;
                }
                String::new()
            }
            Err(e) => {
                let codigo = regras::Codigo::de(e);
                self.recusa_do_segurar = Some(codigo);
                format!(" → recusado: {} ({e})", codigo.nome())
            }
        };
        self.estado = t.estado().ok();
        let posicao = self.estado.as_ref().map(|e| e.posicao).unwrap_or(0.0);
        let texto = format!("{nome} — {origem}{resultado} (posição relatada {posicao:.4})"); // i18n: fora (diário)
        registro::linha(format!("teleprompter: segurar: {texto}"));
        self.eventos_do_segurar.push(format!("{:.3}s {texto}", self.segundos()));
        self.depois_do_estado(hwnd, 0);
        self.invalidar_segurar(hwnd);
    }

    fn ligar_modo_segurar(&mut self, hwnd: HWND, ligado: bool) {
        if !ligado {
            if std::mem::take(&mut self.mouse_no_segurar) {
                unsafe {
                    let _ = ReleaseCapture();
                }
            }
            let c = self.dedos.sair_do_modo();
            self.aplicar_segurar(hwnd, c, "saiu do modo"); // i18n: fora (diário)
        }
        self.ajustes.segurar_para_rolar = ligado;
        super::gravar_ajustes(&self.ajustes);
        let texto = format!("modo \"Segurar para rolar\" {}", if ligado { "ligado" } else { "desligado" }); // i18n: fora (diário)
        registro::linha(format!("teleprompter: {texto}"));
        self.eventos_do_segurar.push(format!("{:.3}s {texto}", self.segundos()));
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
            // O foco sai dos botões pequenos: o espaço num botão com foco seria um clique.
            let _ = SetFocus(Some(hwnd));
        }
    }

    /// **"Inverter botões"** (o pedido de 14/09, à tarde): troca o sentido dos dois botões — e das
    /// teclas ↑ e ↓, que seguem os botões — em `BotaoDeSegurar::para_tras`, o lugar só do
    /// mapeamento. **Com um contato num botão de rolar, a troca não vale**: o botão fica desligado,
    /// e um clique que chegue mesmo assim (a bancada) volta a marca ao que era.
    fn inverter_botoes(&mut self, hwnd: HWND, quer: bool) {
        if !self.dedos.pode_inverter() {
            unsafe {
                SendMessageW(
                    self.c.inverter,
                    BM_SETCHECK,
                    Some(WPARAM(if self.ajustes.inverter_botoes { BST_CHECKED } else { 0 })),
                    None,
                );
            }
            let texto = "\"Inverter botões\" ignorado: há um dedo num botão de rolar (a troca vale depois de soltar)"; // i18n: fora (diário)
            registro::linha(format!("teleprompter: segurar: {texto}"));
            self.eventos_do_segurar.push(format!("{:.3}s {texto}", self.segundos()));
            return;
        }
        self.ajustes.inverter_botoes = quer;
        super::gravar_ajustes(&self.ajustes);
        let texto = format!(
            "\"Inverter botões\" {}: em cima {}, embaixo {}", // i18n: fora (diário)
            if quer { "ligado" } else { "desligado" },
            regras::BotaoDeSegurar::Cima.legenda(quer),
            regras::BotaoDeSegurar::Baixo.legenda(quer)
        );
        registro::linha(format!("teleprompter: segurar: {texto}"));
        self.eventos_do_segurar.push(format!("{:.3}s {texto}", self.segundos()));
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
            let _ = SetFocus(Some(hwnd));
        }
    }

    fn invalidar_segurar(&self, hwnd: HWND) {
        if self.modo_segurar() {
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }

    /// O modo na tela: a faixa de estado (quem, a velocidade), **duas faixas de aviso num espaço de
    /// altura fixa** — um aviso aparecendo ou sumindo não mexe no botão debaixo do mouse (a decisão
    /// do Mac) — e os dois botões grandes.
    fn pintar_segurar(&self, hwnd: HWND, p: &mut Pintor) {
        let e = self.estado_ou_padrao();
        let disp = self.disponibilidade_do_segurar();
        let ligados = disp.botoes_ligados();
        let painel = self.painel.as_ref();
        p.linha(&self.fontes.titulo, TINTA, 10, 30, idioma::t("Segurar para rolar"), DT_LEFT);
        let par = idioma::tr(&painel.map(|p| p.par.clone()).unwrap_or_default());
        let quem = match painel.map(|p| p.fase) {
            Some(Fase::Conectada) if self.avisos.par_sumido => idioma::tf("{} não responde", &[&par]),
            Some(Fase::Conectada) => idioma::tf("Controlando {}", &[&par]),
            Some(Fase::Encerrando) => idioma::t("Saindo…").to_string(),
            _ => idioma::t("Conexão perdida").to_string(),
        };
        let invertidos = if self.ajustes.inverter_botoes { idioma::t("  ·  botões invertidos") } else { "" };
        let velocidade = idioma::decimal(e.velocidade, 2);
        p.linha(
            &self.fontes.corpo,
            TINTA_FRACA,
            40,
            22,
            // A velocidade só se lê aqui; mudá-la é fora do modo.
            &idioma::tf("{}  ·  Velocidade {} linhas/s  ·  ↑ e ↓ também seguram{}", &[&quem, &velocidade, &invertidos]),
            DT_LEFT,
        );
        // As duas faixas de aviso, sempre no mesmo lugar (y 66 e 90), com ou sem texto.
        if let Some(aviso) = self.dedos.aviso_do_texto_parado(e.posicao) {
            p.linha(&self.fontes.corpo, LARANJA, 64, 24, idioma::t(aviso), DT_LEFT);
        }
        if let Some(t) = disp.aviso(&self.estado_da_conexao_do_segurar()) {
            p.linha(&self.fontes.corpo, if disp == regras::DisponibilidadeDoSegurar::PrompterAntigo { ACENTO_VERMELHO } else { LARANJA }, 88, 24, &t, DT_LEFT);
        }
        for b in [regras::BotaoDeSegurar::Cima, regras::BotaoDeSegurar::Baixo] {
            let r = self.retangulo_do_botao(hwnd, b);
            let apertado = ligados && self.dedos.ativo() == Some(b);
            // Rolando (apertado e aceito): o violeta cheio. Apertado sem rolar: o texto parou
            // sozinho — laranja, com a tinta escura. Solto: a `superficieAlta`. Desligado: a
            // `superficie`, com a tinta apagada.
            let (fundo, tinta) = if !ligados {
                (FUNDO_DO_CAMPO, TINTA_FRACA)
            } else if apertado && self.dedos.seguro() {
                (ACENTO_CHEIO, TINTA)
            } else if apertado {
                (LARANJA, FUNDO_DO_PAINEL)
            } else {
                (RISCO, TINTA)
            };
            let seta = if b == regras::BotaoDeSegurar::Cima { "▲" } else { "▼" };
            let meio = (r.top + r.bottom) / 2;
            unsafe {
                let pincel = CreateSolidBrush(fundo);
                FillRect(p.hdc, &r, pincel);
                let _ = DeleteObject(pincel.into());
                SetTextColor(p.hdc, tinta);
                let mut rotulo: Vec<u16> = format!("{seta}   {}   {seta}", idioma::t(b.rotulo())).encode_utf16().collect();
                let mut caixa = RECT { top: meio - escala(self.dpi, 34), bottom: meio + escala(self.dpi, 6), ..r };
                let antiga = SelectObject(p.hdc, self.fontes.grande.into());
                DrawTextW(p.hdc, &mut rotulo, &mut caixa, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
                SelectObject(p.hdc, self.fontes.corpo.into());
                // A legenda troca com "Inverter botões"; o rótulo e a seta, não.
                let mut legenda: Vec<u16> = idioma::t(b.legenda(self.ajustes.inverter_botoes)).encode_utf16().collect();
                let mut caixa = RECT { top: meio + escala(self.dpi, 8), bottom: meio + escala(self.dpi, 36), ..r };
                DrawTextW(p.hdc, &mut legenda, &mut caixa, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
                SelectObject(p.hdc, antiga);
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // A pergunta do texto e os roteiros guardados, no controle (§11 do contrato)
    // -----------------------------------------------------------------------------------------

    /// O estado da caixa agora: a pergunta do estado, o prompter à vista, e a última recusa.
    fn estado_da_caixa(&self) -> regras::EstadoDaCaixa {
        if self.modo != Modo::Controle {
            return regras::EstadoDaCaixa::Nenhuma;
        }
        let e = self.estado_ou_padrao();
        regras::estado_da_caixa(
            e.pergunta_do_texto.as_ref().map(|q| (q.aberta, q.retido_ha_ms)),
            e.par_visto_ha_ms.is_some(),
            self.recusa_da_pergunta,
        )
    }

    /// A caixa está na tela (e toma o lugar dos comandos e do modo segurar).
    fn caixa_na_tela(&self) -> bool {
        self.modo == Modo::Controle
            && self.rascunho.is_none()
            && self.roteiros.is_none()
            && self.estado_da_caixa() != regras::EstadoDaCaixa::Nenhuma
    }

    /// Relê a pergunta do estado e refaz o que a caixa mostra **só quando ela mudou** (os resumos):
    /// as palavras contam o texto inteiro, o do prompter pelo `texto_da_pergunta` e o daqui pelo
    /// `texto`.
    fn atualizar_pergunta_mostrada(&mut self) {
        let Some(t) = self.teleprompter.clone() else { return };
        let pergunta = self.estado.as_ref().and_then(|e| e.pergunta_do_texto.clone());
        match pergunta {
            Some(q) if q.aberta => {
                let Some(dele) = q.do_prompter.clone() else { return };
                let igual = self
                    .pergunta_mostrada
                    .as_ref()
                    .is_some_and(|m| m.resumo_do_prompter == dele.resumo && m.resumo_meu == q.meu.resumo);
                if igual {
                    return;
                }
                let texto_dele = t.texto_da_pergunta().ok().flatten().unwrap_or_default();
                let texto_meu = t.texto().unwrap_or_default();
                let nova = PerguntaMostrada {
                    prompter_nome: q.prompter_nome.clone(),
                    resumo_do_prompter: dele.resumo.clone(),
                    resumo_meu: q.meu.resumo.clone(),
                    previa_do_prompter: dele.previa.clone(),
                    previa_meu: q.meu.previa.clone(),
                    palavras_do_prompter: regras::contar_palavras(&texto_dele),
                    palavras_meu: regras::contar_palavras(&texto_meu),
                };
                let texto = format!(
                    "a pergunta do texto {}: prompter \"{}\" ({} bytes, resumo {}, {}) × este aparelho ({} bytes, resumo {}, {})", // i18n: fora (diário)
                    if self.pergunta_mostrada.is_some() { "mudou" } else { "abriu" },
                    nova.prompter_nome,
                    dele.bytes,
                    dele.resumo,
                    regras::rotulo_de_palavras(nova.palavras_do_prompter),
                    q.meu.bytes,
                    q.meu.resumo,
                    regras::rotulo_de_palavras(nova.palavras_meu)
                );
                registro::linha(format!("teleprompter: {texto}"));
                self.eventos_da_pergunta.push(format!("{:.3}s {texto}", self.segundos()));
                self.pergunta_mostrada = Some(nova);
            }
            Some(_) => {}
            None => {
                if self.pergunta_mostrada.take().is_some() {
                    let texto = "a pergunta do texto fechou"; // i18n: fora (diário)
                    registro::linha(format!("teleprompter: {texto}"));
                    self.eventos_da_pergunta.push(format!("{:.3}s {texto}", self.segundos()));
                }
                self.recusa_da_pergunta = None;
            }
        }
    }

    /// **"Usar o do prompter"** (`manter_o_meu = false`) ou **"Mandar o meu"**: `resolver_texto`
    /// com o resumo **que a caixa mostrou**. OK: grava o salvo na hora (§11.5). `BUSY`: "O roteiro do
    /// prompter mudou. Confira de novo." (a caixa se atualiza com o bit); `CLOSED`: os botões
    /// desligam ("O prompter saiu…").
    fn escolher(&mut self, hwnd: HWND, manter_o_meu: bool) {
        let Some(t) = self.teleprompter.clone() else { return };
        let Some(resumo) = self.pergunta_mostrada.as_ref().map(|m| m.resumo_do_prompter.clone()) else { return };
        if let Some(s) = &self.sessao {
            s.antes_de_editar();
        }
        let r = t.resolver_texto(manter_o_meu, &resumo);
        if let Some(s) = &self.sessao {
            s.depois_de_editar();
        }
        let nome = if manter_o_meu { regras::PERGUNTA_MANDAR_O_MEU } else { regras::PERGUNTA_USAR_O_DO_PROMPTER };
        let texto = match &r {
            Ok(()) => {
                self.recusa_da_pergunta = None;
                super::salvar(Lado::Controle);
                format!("\"{nome}\" (resumo visto {resumo}): OK, salvo gravado")
            }
            Err(e) => {
                let c = regras::Codigo::de(e);
                self.recusa_da_pergunta = Some(c);
                format!("\"{nome}\" (resumo visto {resumo}): {} ({e})", c.nome())
            }
        };
        registro::linha(format!("teleprompter: pergunta: {texto}"));
        self.eventos_da_pergunta.push(format!("{:.3}s {texto}", self.segundos()));
        // "Usar o do prompter" troca o texto daqui (a adoção é local: não vem bit de texto).
        if let Ok(novo) = t.texto() {
            self.trocar_texto(hwnd, novo);
        }
        self.estado = t.estado().ok();
        self.atualizar_pergunta_mostrada();
        self.depois_do_estado(hwnd, 0);
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// Abre (ou fecha, com `None`) a lista de "Roteiros guardados", ou muda o que ela mostra.
    fn abrir_roteiros(&mut self, hwnd: HWND, vista: Option<VistaDosRoteiros>) {
        let lendo = matches!(vista, Some(VistaDosRoteiros::Ver(_)));
        if let Some(VistaDosRoteiros::Ver(resumo)) = &vista {
            let texto = self
                .teleprompter
                .as_ref()
                .and_then(|t| t.copia_do_texto(resumo).ok().flatten())
                .unwrap_or_default();
            por_texto(self.c.texto, &para_o_editor(&texto));
        }
        unsafe {
            // O texto do roteiro guardado é só para ler.
            SendMessageW(self.c.texto, EM_SETREADONLY, Some(WPARAM(usize::from(lendo))), None);
        }
        if !lendo && self.rascunho.is_none() {
            por_texto(self.c.texto, "");
        }
        self.roteiros = vista;
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// "Usar" ou "Apagar", confirmado.
    fn confirmar_roteiro(&mut self, hwnd: HWND) {
        let Some(t) = self.teleprompter.clone() else { return };
        match self.roteiros.clone() {
            Some(VistaDosRoteiros::ConfirmarUsar(resumo)) => {
                if let Ok(Some(texto)) = t.copia_do_texto(&resumo) {
                    let ok = self.aplicar_texto_local(hwnd, &texto);
                    let registro_ = format!("roteiro guardado {resumo} usado: {}", if ok { "OK" } else { "recusado" }); // i18n: fora (diário)
                    registro::linha(format!("teleprompter: {registro_}"));
                    self.eventos_da_pergunta.push(format!("{:.3}s {registro_}", self.segundos()));
                }
                self.abrir_roteiros(hwnd, None);
            }
            Some(VistaDosRoteiros::ConfirmarApagar(resumo)) => {
                let apagou = t.esquecer_copia_do_texto(&resumo).unwrap_or(false);
                super::salvar(Lado::Controle);
                let registro_ = format!("roteiro guardado {resumo} apagado: {apagou}, salvo gravado"); // i18n: fora (diário)
                registro::linha(format!("teleprompter: {registro_}"));
                self.eventos_da_pergunta.push(format!("{:.3}s {registro_}", self.segundos()));
                self.estado = t.estado().ok();
                self.abrir_roteiros(hwnd, Some(VistaDosRoteiros::Lista));
            }
            _ => {}
        }
    }

    /// As palavras de uma cópia, contadas uma vez pelo resumo.
    fn palavras_da_copia(&mut self, resumo: &str) -> usize {
        if let Some(n) = self.palavras_das_copias.get(resumo) {
            return *n;
        }
        let n = self
            .teleprompter
            .as_ref()
            .and_then(|t| t.copia_do_texto(resumo).ok().flatten())
            .map(|t| regras::contar_palavras(&t))
            .unwrap_or(0);
        self.palavras_das_copias.insert(resumo.to_string(), n);
        n
    }

    /// A caixa da pergunta: o título, os dois blocos lado a lado (prévia e palavras), o aviso da
    /// vez, os dois botões (controles filhos) e a linha pequena do fim.
    fn pintar_pergunta(&self, p: &mut Pintor, c: RECT) {
        let d = self.dpi;
        match self.estado_da_caixa() {
            regras::EstadoDaCaixa::Conferindo => {
                p.linha(&self.fontes.titulo, TINTA, 16, 32, idioma::t(regras::PERGUNTA_CONFERINDO), DT_LEFT);
            }
            regras::EstadoDaCaixa::Aberta { aviso, .. } => {
                let Some(m) = &self.pergunta_mostrada else { return };
                p.paragrafo_esquerda(&self.fontes.titulo, TINTA, 12, 40, &regras::titulo_da_pergunta(&m.prompter_nome));
                // Os dois blocos: lado a lado, da faixa de cima até acima dos botões.
                let esquerda = escala(d, 24);
                let largura = c.right - 2 * esquerda;
                let vao = escala(d, 16);
                let meia = (largura - vao) / 2;
                let topo = escala(d, 60);
                let fundo = (c.bottom - escala(d, 150)).max(topo + escala(d, 80));
                for (i, (rotulo, palavras, previa)) in [
                    (regras::PERGUNTA_NO_PROMPTER, m.palavras_do_prompter, &m.previa_do_prompter),
                    (regras::PERGUNTA_NESTE_APARELHO, m.palavras_meu, &m.previa_meu),
                ]
                .into_iter()
                .enumerate()
                {
                    let x = esquerda + i as i32 * (meia + vao);
                    let caixa = RECT { left: x, top: topo, right: x + meia, bottom: fundo };
                    unsafe {
                        let borda = CreateSolidBrush(RISCO);
                        FrameRect(p.hdc, &caixa, borda);
                        let _ = DeleteObject(borda.into());
                    }
                    let mut titulo = RECT { left: x + escala(d, 12), top: topo + escala(d, 8), right: x + meia - escala(d, 12), bottom: topo + escala(d, 32) };
                    desenhar_em(p.hdc, &self.fontes.corpo, TINTA, &mut titulo, idioma::t(rotulo), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
                    let mut conta = RECT { top: topo + escala(d, 30), bottom: topo + escala(d, 50), ..titulo };
                    desenhar_em(p.hdc, &self.fontes.pequeno, TINTA_FRACA, &mut conta, &regras::rotulo_de_palavras(palavras), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
                    let mut texto = RECT { top: topo + escala(d, 56), bottom: fundo - escala(d, 8), ..titulo };
                    desenhar_em(p.hdc, &self.fontes.pequeno, TINTA, &mut texto, previa, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL | DT_NOPREFIX);
                }
                let y_aviso = (c.bottom * 96 / d as i32) - 140;
                if let Some(a) = aviso {
                    p.linha(&self.fontes.corpo, LARANJA_ESCURO, y_aviso, 24, idioma::t(a), DT_LEFT);
                }
                p.linha(&self.fontes.pequeno, TINTA_FRACA, (c.bottom * 96 / d as i32) - 40, 20, idioma::t(regras::PERGUNTA_RODAPE), DT_LEFT);
            }
            regras::EstadoDaCaixa::Nenhuma => {}
        }
    }

    /// "Roteiros guardados": a lista (a mais nova primeiro), um roteiro aberto para ler, ou a
    /// confirmação de usar ou apagar.
    fn pintar_roteiros(&mut self, p: &mut Pintor, c: RECT) {
        let d = self.dpi;
        let copias = self.estado_ou_padrao().copias_do_texto;
        match self.roteiros.clone() {
            Some(VistaDosRoteiros::Lista) => {
                p.linha(&self.fontes.titulo, TINTA, 16, 32, idioma::t(regras::ROTEIROS_GUARDADOS), DT_LEFT);
                if copias.is_empty() {
                    p.linha(&self.fontes.corpo, TINTA_FRACA, 70, 24, idioma::t(regras::ROTEIROS_VAZIOS), DT_LEFT);
                    return;
                }
                for (i, copia) in copias.iter().enumerate().take(quall_core::teleprompter::COPIAS_DO_TEXTO) {
                    let topo = 64 + i as i32 * ALTURA_DO_ROTEIRO;
                    let origem = regras::origem_da_copia(
                        copia.origem == quall_core::teleprompter::OrigemDaCopia::Prompter,
                        &copia.prompter_nome,
                    );
                    let palavras = self.palavras_da_copia(&copia.resumo);
                    p.linha(&self.fontes.corpo, TINTA, topo, 24, &origem, DT_LEFT);
                    p.linha(
                        &self.fontes.pequeno,
                        TINTA_FRACA,
                        topo + 24,
                        18,
                        &format!("{}  ·  {}", hora_local(copia.quando_ms), regras::rotulo_de_palavras(palavras)),
                        DT_LEFT,
                    );
                    let mut previa = RECT {
                        left: escala(d, 24),
                        top: escala(d, topo + 44),
                        right: c.right - escala(d, 24 + 3 * 104),
                        bottom: escala(d, topo + ALTURA_DO_ROTEIRO - 12),
                    };
                    desenhar_em(p.hdc, &self.fontes.pequeno, TINTA, &mut previa, &copia.previa, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL | DT_NOPREFIX);
                }
            }
            Some(VistaDosRoteiros::Ver(resumo)) => {
                let origem = copias
                    .iter()
                    .find(|c| c.resumo == resumo)
                    .map(|c| regras::origem_da_copia(c.origem == quall_core::teleprompter::OrigemDaCopia::Prompter, &c.prompter_nome))
                    .unwrap_or_default();
                p.linha(&self.fontes.titulo, TINTA, 16, 32, &origem, DT_LEFT);
            }
            Some(VistaDosRoteiros::ConfirmarUsar(_)) => {
                p.linha(&self.fontes.titulo, TINTA, 16, 32, idioma::t(regras::ROTEIROS_GUARDADOS), DT_LEFT);
                p.paragrafo_esquerda(&self.fontes.corpo, TINTA, 80, 60, idioma::t(regras::CONFIRMA_USAR_ESTE));
            }
            Some(VistaDosRoteiros::ConfirmarApagar(_)) => {
                p.linha(&self.fontes.titulo, TINTA, 16, 32, idioma::t(regras::ROTEIROS_GUARDADOS), DT_LEFT);
                p.paragrafo_esquerda(&self.fontes.corpo, TINTA, 80, 60, idioma::t(regras::CONFIRMA_APAGAR));
            }
            None => {}
        }
    }

    /// O monitor mudou de escala (a janela foi para outro monitor, ou o monitor girou e o Windows
    /// trocou a escala): fontes e tamanho refeitos na escala nova. O layout do texto se refaz
    /// sozinho, porque a fonte em pixels entra no pedido de quebra.
    fn mudar_dpi(&mut self, hwnd: HWND, novo: u32, sugerido: RECT) {
        if novo == 0 || novo == self.dpi {
            return;
        }
        let velhas = [self.fontes.titulo, self.fontes.grande, self.fontes.corpo, self.fontes.pequeno, self.fontes.rotulo, self.fontes.icones];
        self.dpi = novo;
        self.fontes = Fontes {
            titulo: fonte(novo, 20, FW_SEMIBOLD.0 as i32),
            grande: fonte(novo, 26, FW_BOLD.0 as i32),
            corpo: fonte(novo, 12, FW_SEMIBOLD.0 as i32),
            pequeno: fonte(novo, 10, FW_NORMAL.0 as i32),
            rotulo: fonte(novo, 9, FW_BOLD.0 as i32),
            icones: fonte_de_icones(novo, 13),
        };
        self.aplicar_fontes();
        unsafe {
            for f in velhas {
                let _ = DeleteObject(f.into());
            }
        }
        // Em tela cheia o sugerido é o de uma janela com moldura: a tela cheia cobre o monitor de
        // novo (o de agora).
        if self.tela_cheia.is_none() || !self.cobrir_o_monitor(hwnd) {
            unsafe {
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    sugerido.left,
                    sugerido.top,
                    sugerido.right - sugerido.left,
                    sugerido.bottom - sugerido.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
        }
        registro::linha(format!("teleprompter: escala do monitor mudou: {novo} dpi"));
        self.posicionar(hwnd);
    }

    /// **A tela cheia** (F11, Esc para sair, e o botão da barra de comandos; o prompter e a tela R5):
    /// sem a moldura do Windows (a barra de título com minimizar, maximizar e fechar) e cobrindo o
    /// **monitor inteiro**, a barra de tarefas inclusive (`rcMonitor`, não `rcWork`). As faixas do
    /// Quall ficam — como a tela cheia do Mac, que tira a barra de título e deixa a faixa — e quem
    /// as esconde é o H; assim a saída sem teclado (o botão, ao lado do Fechar) está sempre à mostra
    /// quando a pessoa chegou aqui pelo mouse. A posição de antes volta pelo `WINDOWPLACEMENT` (uma
    /// janela maximizada volta maximizada). A escolha é lembrada por tela (`AjustesLocais`).
    fn alternar_tela_cheia(&mut self, hwnd: HWND) {
        unsafe {
            match self.tela_cheia.take() {
                Some((estilo, lugar)) => {
                    SetWindowLongPtrW(hwnd, GWL_STYLE, estilo.0 as isize);
                    let mut lugar = lugar;
                    if lugar.showCmd == SW_HIDE.0 as u32 {
                        lugar.showCmd = SW_SHOWNORMAL.0 as u32;
                    }
                    let _ = SetWindowPlacement(hwnd, &lugar);
                    let _ = SetWindowPos(
                        hwnd,
                        None,
                        0,
                        0,
                        0,
                        0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
                    );
                }
                None => {
                    let estilo = WINDOW_STYLE(GetWindowLongPtrW(hwnd, GWL_STYLE) as u32);
                    let mut lugar = WINDOWPLACEMENT { length: std::mem::size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
                    if GetWindowPlacement(hwnd, &mut lugar).is_ok() {
                        self.tela_cheia = Some((estilo, lugar));
                        SetWindowLongPtrW(hwnd, GWL_STYLE, ((estilo.0 & !WS_OVERLAPPEDWINDOW.0) | WS_POPUP.0) as isize);
                        if !self.cobrir_o_monitor(hwnd) {
                            // Sem o monitor, a moldura volta: nada de janela sem barra e sem tela cheia.
                            SetWindowLongPtrW(hwnd, GWL_STYLE, estilo.0 as isize);
                            self.tela_cheia = None;
                        }
                    }
                }
            }
        }
        let ligada = self.tela_cheia.is_some();
        registro::linha(format!("teleprompter: tela cheia: {}", if ligada { "entrou" } else { "saiu" }));
        self.atualizar_botao_da_tela_cheia(hwnd);
        if regras::guarda_a_tela_cheia(self.cfg.bancada) && self.ajustes.lembrar_tela_cheia(self.r5.is_some(), ligada) {
            super::gravar_ajustes(&self.ajustes);
        }
        self.posicionar(hwnd);
        self.pedir_layout(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// Põe a janela por cima do monitor em que ela está, inteiro. Devolve se achou o monitor.
    fn cobrir_o_monitor(&self, hwnd: HWND) -> bool {
        unsafe {
            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                return false;
            }
            let m = info.rcMonitor;
            let _ = SetWindowPos(
                hwnd,
                Some(HWND_TOP),
                m.left,
                m.top,
                m.right - m.left,
                m.bottom - m.top,
                SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
            );
            true
        }
    }

    /// O glifo, o nome para o Narrador e a dica do botão, pelo estado de agora.
    fn atualizar_botao_da_tela_cheia(&self, hwnd: HWND) {
        let ligada = self.tela_cheia.is_some();
        let rotulo = idioma::t(regras::rotulo_da_tela_cheia(ligada));
        let g: Vec<u16> = regras::icone_da_tela_cheia(ligada).glifo().to_string().encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = SetWindowTextW(self.c.tela_cheia, PCWSTR(g.as_ptr()));
        }
        dar_nome(self.c.tela_cheia, rotulo);
        dica_do_botao(self.c.dica_da_tela_cheia, hwnd, self.c.tela_cheia, rotulo, false);
    }

    // -----------------------------------------------------------------------------------------
    // O idioma (a tradução EN/PT, `idioma.rs`)
    // -----------------------------------------------------------------------------------------

    /// **Os rótulos fixos dos controles**: `(controle, chave em português)`. Os que mudam com o
    /// estado (Rolar/Pausar, Fechar/Desconectar, "Usar"/"Apagar" da confirmação, os da tela R5 e o
    /// do gravar no prompter) são postos por `posicionar`, também com `idioma::t`.
    fn rotulos_fixos(&self) -> Vec<(HWND, &'static str)> {
        let c = &self.c;
        let mut v = vec![
            (c.mostrar, "Mostrar o texto neste computador"), // i18n: chave
            (c.controlar, "Controlar um teleprompter"), // i18n: chave
            (c.conectar, "Conectar"), // i18n: chave
            (c.voltar, "Voltar"), // i18n: chave
            (c.procurar_de_novo, "Procurar de novo"), // i18n: chave
            (c.fonte_auto, "Fonte automática"), // i18n: chave
            (c.segurar, "Segurar para rolar"), // i18n: chave
            (c.sair_do_segurar, "Sair do modo"), // i18n: chave
            (c.inverter, "Inverter botões"), // i18n: chave
            (c.usar_do_prompter, regras::PERGUNTA_USAR_O_DO_PROMPTER),
            (c.mandar_o_meu, regras::PERGUNTA_MANDAR_O_MEU),
            (c.roteiros, regras::ROTEIROS_GUARDADOS),
            (c.fechar_roteiros, "Fechar"), // i18n: chave
            (c.confirma_nao, "Cancelar"), // i18n: chave
            (c.voltar_a_lista, "Voltar à lista"), // i18n: chave
            (c.esperar_de_novo, "Esperar de novo"), // i18n: chave
            (c.confirmar, "Confirmar"), // i18n: chave
            (c.cancelar, "Cancelar"), // i18n: chave
            (c.usar_novo, "Usar o texto novo"), // i18n: chave
            (c.manter_meu, "Manter o meu"), // i18n: chave
            (c.abrir_arquivo, "Abrir arquivo .txt…"), // i18n: chave
            (c.mostrar_com_camera, "Mostrar o texto com a câmera deste computador"), // i18n: chave
            (c.esconder_previa, "Esconder a câmera"), // i18n: chave
            (c.espelho_previa, "Prévia como espelho"), // i18n: chave
            (c.editar_roteiro, "Editar ou colar o roteiro"), // i18n: chave
            (c.codigo_recusar, "Nenhum destes"), // i18n: chave
        ];
        for (id, h) in &c.comandos {
            if let Some((_, rotulo)) = COMANDOS.iter().find(|(i, _)| i == id) {
                v.push((*h, *rotulo));
            }
        }
        for [ver, usar, apagar] in &c.itens_dos_roteiros {
            v.extend([(*ver, "Ver"), (*usar, "Usar este"), (*apagar, "Apagar")]); // i18n: chave
        }
        v
    }

    /// **Reescreve todos os rótulos no idioma de agora**: na criação (os controles nascem sem
    /// texto) e quando o idioma muda (`trocar_de_idioma`).
    fn reescrever_rotulos(&mut self, hwnd: HWND) {
        for (h, pt) in self.rotulos_fixos() {
            por_texto(h, idioma::t(pt));
        }
        // Os nomes para o Narrador dos botões só de ícone, e a dica da tela cheia. O nome da
        // engrenagem é dos ajustes da câmera (`regras_dos_controles`, outro módulo): traduzido aqui.
        dar_nome(self.c.ajustes_da_camera, idioma::t(crate::regras_dos_controles::ROTULO_DO_ICONE));
        self.atualizar_botao_da_tela_cheia(hwnd);
        self.aplicar_titulo(hwnd);
        // A lista das câmeras da tela R5 ("Câmera: …").
        self.preencher_cameras();
    }

    /// **O idioma mudou** (o seletor "PT | EN" da janela principal): os rótulos, a disposição (os
    /// textos mudam de largura) e a janela inteira repintada — o que é pintado (as faixas, a caixa da
    /// pergunta, o modo "Segurar para rolar", o texto vazio, a faixa da tela R5) usa `idioma::t` na
    /// pintura.
    fn trocar_de_idioma(&mut self, hwnd: HWND) {
        registro::linha(format!("teleprompter: idioma {:?}: rótulos reescritos", idioma::atual()));
        self.reescrever_rotulos(hwnd);
        self.chave_das_faixas.clear();
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, true);
        }
    }

    /// O título da janela, pela tela de agora, no idioma de agora.
    fn aplicar_titulo(&self, hwnd: HWND) {
        let titulo = match self.modo {
            Modo::Escolha => idioma::t("Quall — Teleprompter"),
            Modo::Prompter if self.r5.is_some() => idioma::t("Quall — Teleprompter com câmera"),
            Modo::Prompter => idioma::t("Quall — Teleprompter: mostrando o texto"),
            Modo::Controle => idioma::t("Quall — Teleprompter: controle"),
        };
        por_texto(hwnd, titulo);
    }

    /// O aviso da fonte automática no idioma de agora. O guardado fica em português (o diário e o
    /// relato de bancada o leem assim), com o motivo como chave.
    fn aviso_da_fonte_mostrado(&self) -> Option<String> {
        let a = self.aviso_da_fonte.as_ref()?;
        Some(match a.strip_prefix("Fonte automática desligada: ") { // i18n: fora (o prefixo do estado guardado)
            Some(motivo) => idioma::tf("Fonte automática desligada: {}", &[&idioma::tr(motivo)]),
            None => idioma::tr(a),
        })
    }

    /// **A tela abre como foi deixada**: chamada depois de o prompter ou a tela R5 abrir (e de a
    /// janela aparecer), entra na tela cheia se a pessoa saiu daquela tela nela.
    fn aplicar_tela_cheia_lembrada(&mut self, hwnd: HWND) {
        if self.modo != Modo::Prompter || self.tela_cheia.is_some() {
            return;
        }
        let com_camera = self.r5.is_some();
        if regras::abre_em_tela_cheia(&self.ajustes, com_camera, self.cfg.bancada) {
            registro::linha(format!(
                "teleprompter: a tela {} abre em tela cheia (a escolha lembrada)",
                if com_camera { "com câmera" } else { "do texto" }
            ));
            self.alternar_tela_cheia(hwnd);
        }
    }

    // -----------------------------------------------------------------------------------------
    // A disposição dos controles
    // -----------------------------------------------------------------------------------------

    /// **Põe os controles no lugar** da tela de agora. Pode ser chamado de dentro dele mesmo (a barra
    /// de rolagem do painel que aparece ou some manda `WM_SIZE`): a chamada de dentro só pede outra
    /// volta, com a área de cliente nova.
    fn posicionar(&mut self, hwnd: HWND) {
        if self.rolando_na_tela() {
            self.janela_da_rolagem.disposicoes += 1;
        }
        if self.posicionando {
            self.posicionar_de_novo = true;
            return;
        }
        self.posicionando = true;
        for _ in 0..3 {
            self.posicionar_de_novo = false;
            self.posicionar_uma_vez(hwnd);
            if !self.posicionar_de_novo {
                break;
            }
        }
        self.posicionando = false;
    }

    fn posicionar_uma_vez(&mut self, hwnd: HWND) {
        let mut cliente = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut cliente);
        }
        let d = self.dpi;
        let largura = cliente.right;
        let altura = cliente.bottom;
        let margem = escala(d, 24);
        let editando = self.rascunho.is_some();
        let conflito = self.rascunho.as_ref().is_some_and(|r| r.em_conflito());
        let fase = self.painel.as_ref().map(|p| p.fase);
        let sessao_viva = self.sessao.as_ref().is_some_and(|s| !s.terminou());
        let (escolha, prompter, controle) =
            (self.modo == Modo::Escolha, self.modo == Modo::Prompter, self.modo == Modo::Controle);
        // "Roteiros guardados" e a caixa da pergunta tomam a tela do controle: a lista, quando
        // aberta; senão a caixa, quando há pergunta — ela vem antes do modo segurar e dos comandos
        // (enquanto ela está aberta, o roteiro não sincroniza).
        let roteiros = controle && self.roteiros.is_some();
        let caixa = controle && !roteiros && self.caixa_na_tela();
        let estado_da_caixa = self.estado_da_caixa();
        // O modo "Segurar para rolar" fica **só** com os dois botões grandes (desenhados, não
        // controles) e a saída pequena no canto.
        let segurar = self.modo_segurar();
        // **O painel do controle** (`painel_do_controle.rs`): o formulário sem conexão, os comandos
        // com ela. Fora do editor — até 12/10 o formulário ficava à mostra por baixo do editor aberto
        // sem conexão, e a lista e os campos apareciam por cima do texto —, da lista de roteiros, da
        // pergunta e do modo segurar.
        let painel = controle && !editando && !segurar && !caixa && !roteiros;
        let formulario = painel && !sessao_viva;
        let comandos_visiveis = !editando
            && !segurar
            && !caixa
            && !roteiros
            && ((prompter && !self.faixas_ocultas) || (controle && sessao_viva));

        // A caixa da pergunta: os dois botões, ligados ou não.
        let botoes_da_pergunta = match estado_da_caixa {
            regras::EstadoDaCaixa::Aberta { botoes_ligados, .. } if caixa && self.pergunta_mostrada.is_some() => Some(botoes_ligados),
            _ => None,
        };
        mostrar(self.c.usar_do_prompter, botoes_da_pergunta.is_some());
        mostrar(self.c.mandar_o_meu, botoes_da_pergunta.is_some());
        if let Some(ligados) = botoes_da_pergunta {
            let (w, a) = (escala(d, 230), escala(d, 40));
            let y = altura - escala(d, 100);
            unsafe {
                let _ = MoveWindow(self.c.usar_do_prompter, margem, y, w, a, true);
                let _ = MoveWindow(self.c.mandar_o_meu, margem + w + escala(d, 16), y, w, a, true);
                let _ = EnableWindow(self.c.usar_do_prompter, ligados);
                let _ = EnableWindow(self.c.mandar_o_meu, ligados);
            }
        }
        // "Roteiros guardados" e o bloco "Roteiro" (o botão do editor): no painel, com ou sem conexão.
        // O lugar deles, como o do resto do painel, sai de `posicionar_o_painel`.
        mostrar(self.c.roteiros, painel);
        mostrar(self.c.editar_roteiro, painel);
        // A lista.
        let vista = if roteiros { self.roteiros.clone() } else { None };
        let n_copias = self.estado.as_ref().map(|e| e.copias_do_texto.len()).unwrap_or(0);
        for (i, botoes) in self.c.itens_dos_roteiros.iter().enumerate() {
            let visivel = vista == Some(VistaDosRoteiros::Lista) && i < n_copias;
            for (j, h) in botoes.iter().enumerate() {
                mostrar(*h, visivel);
                if visivel {
                    let x = largura - margem - 3 * escala(d, 104) + j as i32 * escala(d, 104);
                    let y = escala(d, 64 + i as i32 * ALTURA_DO_ROTEIRO + 40);
                    unsafe {
                        let _ = MoveWindow(*h, x, y, escala(d, 96), escala(d, 30), true);
                    }
                }
            }
        }
        mostrar(self.c.fechar_roteiros, vista == Some(VistaDosRoteiros::Lista));
        let lendo = matches!(vista, Some(VistaDosRoteiros::Ver(_)));
        mostrar(self.c.voltar_a_lista, lendo);
        let confirmando = matches!(vista, Some(VistaDosRoteiros::ConfirmarUsar(_)) | Some(VistaDosRoteiros::ConfirmarApagar(_)));
        mostrar(self.c.confirma_sim, confirmando);
        mostrar(self.c.confirma_nao, confirmando);
        unsafe {
            let _ = MoveWindow(self.c.fechar_roteiros, largura - margem - escala(d, 110), escala(d, 16), escala(d, 110), escala(d, 30), true);
            let _ = MoveWindow(self.c.voltar_a_lista, largura - margem - escala(d, 140), altura - escala(d, 50), escala(d, 140), escala(d, 34), true);
            let _ = MoveWindow(self.c.confirma_sim, margem, escala(d, 160), escala(d, 120), escala(d, 34), true);
            let _ = MoveWindow(self.c.confirma_nao, margem + escala(d, 132), escala(d, 160), escala(d, 120), escala(d, 34), true);
        }
        por_texto(
            self.c.confirma_sim,
            if matches!(vista, Some(VistaDosRoteiros::ConfirmarApagar(_))) { idioma::t("Apagar") } else { idioma::t("Usar") },
        );

        mostrar(self.c.segurar, comandos_visiveis && controle);
        mostrar(self.c.sair_do_segurar, segurar);
        mostrar(self.c.inverter, segurar);
        if segurar {
            // Os dois pequenos, no canto de cima, longe dos botões grandes: "Inverter botões" ao
            // lado do "Sair do modo", ligado com a marca de apertado, e **desligado com um dedo num
            // botão de rolar** (a troca não vale até soltar).
            let (w, a) = (escala(d, 110), escala(d, 28));
            let wi = escala(d, 130);
            unsafe {
                let _ = MoveWindow(self.c.sair_do_segurar, largura - margem - w, escala(d, 14), w, a, true);
                let _ = MoveWindow(self.c.inverter, largura - margem - w - escala(d, 8) - wi, escala(d, 14), wi, a, true);
                SendMessageW(
                    self.c.inverter,
                    BM_SETCHECK,
                    Some(WPARAM(if self.ajustes.inverter_botoes { BST_CHECKED } else { 0 })),
                    None,
                );
                let _ = EnableWindow(self.c.inverter, self.dedos.pode_inverter());
            }
        }
        mostrar(self.c.mostrar, escolha);
        mostrar(self.c.controlar, escolha);
        mostrar(self.c.lista, formulario);
        mostrar(self.c.endereco, formulario);
        mostrar(self.c.pin, formulario);
        mostrar(self.c.conectar, formulario);
        mostrar(self.c.voltar, formulario);
        mostrar(self.c.procurar_de_novo, formulario);
        for (_, h) in &self.c.comandos {
            mostrar(*h, comandos_visiveis);
        }
        mostrar(self.c.fonte_auto, comandos_visiveis && prompter);
        // A tela cheia mora na barra de comandos do Quall (não na do Windows): com ela à mostra
        // em janela e em tela cheia; com as faixas ocultas (H), some com o resto.
        mostrar(self.c.tela_cheia, comandos_visiveis && prompter);
        mostrar(self.c.sair, comandos_visiveis || (prompter && fase == Some(Fase::Parada) && !editando));
        mostrar(self.c.esperar_de_novo, prompter && fase == Some(Fase::Parada) && !editando && !self.cfg.sem_sessao);
        mostrar(self.c.texto, editando || lendo);
        if lendo && !editando {
            unsafe {
                let _ = MoveWindow(self.c.texto, margem, escala(d, 60), largura - 2 * margem, altura - escala(d, 60 + 64), true);
            }
        }
        mostrar(self.c.confirmar, editando);
        mostrar(self.c.cancelar, editando);
        mostrar(self.c.abrir_arquivo, editando);
        mostrar(self.c.usar_novo, editando && conflito);
        mostrar(self.c.manter_meu, editando && conflito);

        let rolando = self.estado.as_ref().is_some_and(|e| e.rolando);
        let rotulo_rolar = if rolando { idioma::t("Pausar") } else { idioma::t("Rolar") };
        let rotulo_sair = if controle { idioma::t("Desconectar") } else { idioma::t("Fechar") };
        if let Some((_, h)) = self.c.comandos.iter().find(|(id, _)| *id == ID_ROLAR) {
            por_texto(*h, rotulo_rolar);
        }
        por_texto(self.c.sair, rotulo_sair);
        let mover = |h: HWND, x: i32, y: i32, w: i32, a: i32| unsafe {
            let _ = MoveWindow(h, x, y, w, a, true);
        };
        if escolha {
            let w = escala(d, 360);
            let x = (largura - w) / 2;
            mover(self.c.mostrar, x, escala(d, 150), w, escala(d, 56));
            mover(self.c.controlar, x, escala(d, 222), w, escala(d, 56));
        }
        if comandos_visiveis {
            if prompter {
                // A barra de baixo: os comandos em fila, a "Fonte automática" (que vale por dois:
                // o nome é longo e é literal nas quatro telas), e o Fechar na ponta direita.
                let y = altura - escala(d, BARRA_DE_BAIXO) + escala(d, 7);
                let a = escala(d, 32);
                let n = self.c.comandos.len() as i32 + 3;
                let espaco = escala(d, 4);
                // O ícone da tela cheia tem largura própria (um quadrado), fora da divisão.
                let q = a;
                let w = ((largura - 2 * escala(d, 8) - q - espaco * (n + 2)) / n).clamp(escala(d, 40), escala(d, 96));
                let mut x = escala(d, 8);
                for (_, h) in &self.c.comandos {
                    mover(*h, x, y, w, a);
                    x += w + espaco;
                }
                mover(self.c.fonte_auto, x, y, 2 * w + espaco, a);
                x += 2 * w + 2 * espaco;
                mover(self.c.tela_cheia, x, y, q, a);
                x += q + espaco;
                mover(self.c.sair, x, y, w, a);
            }
            // O controle: os comandos são do painel (`posicionar_o_painel`).
        }
        if prompter && fase == Some(Fase::Parada) && !editando && !comandos_visiveis {
            mover(self.c.sair, largura - margem - escala(d, 130), altura - escala(d, 40), escala(d, 130), escala(d, 32));
        }
        if prompter && fase == Some(Fase::Parada) && !editando {
            mover(self.c.esperar_de_novo, largura - margem - escala(d, 290), escala(d, 20), escala(d, 150), escala(d, 32));
        }
        // A escolha: o terceiro botão (a tela R5).
        mostrar(self.c.mostrar_com_camera, escolha);
        if escolha {
            let w = escala(d, 360);
            mover(self.c.mostrar_com_camera, (largura - w) / 2, escala(d, 294), w, escala(d, 56));
        }
        // A câmera do prompter R5 (§17 do contrato da câmera): só com os controles dela à mostra.
        let camera_do_prompter = self.controle_camera_visivel() && comandos_visiveis;
        self.camera_do_prompter_mostrada = self.controle_camera_visivel();
        mostrar(self.c.camera_do_prompter, camera_do_prompter);
        if camera_do_prompter {
            let rotulo: Vec<u16> = idioma::t("Ajustes da câmera do prompter").encode_utf16().chain(std::iter::once(0)).collect();
            unsafe {
                let _ = SetWindowTextW(self.c.camera_do_prompter, PCWSTR(rotulo.as_ptr()));
            }
        }
        // O gravar do controle (§13.8): só quando o prompter diz que grava.
        let gravar_remoto = self.controle_gravar_visivel() && comandos_visiveis;
        mostrar(self.c.gravar_remoto, gravar_remoto);
        if gravar_remoto {
            let rotulo: Vec<u16> = self.controle_rotulo_de_gravar().encode_utf16().chain(std::iter::once(0)).collect();
            unsafe {
                let _ = SetWindowTextW(self.c.gravar_remoto, PCWSTR(rotulo.as_ptr()));
            }
        }
        if editando {
            // O editor ocupa o meio; os botões ficam embaixo.
            let topo = if prompter { escala(d, FAIXA_DE_CIMA) + escala(d, 8) } else { escala(d, 150) };
            let base = altura - escala(d, 56);
            mover(self.c.texto, margem, topo, largura - 2 * margem, (base - topo - escala(d, if conflito { 44 } else { 8 })).max(escala(d, 60)));
            let y = altura - escala(d, 46);
            mover(self.c.confirmar, largura - margem - escala(d, 130), y, escala(d, 130), escala(d, 34));
            mover(self.c.cancelar, largura - margem - escala(d, 250), y, escala(d, 110), escala(d, 34));
            mover(self.c.abrir_arquivo, margem, y, escala(d, 190), escala(d, 34));
            if conflito {
                let yc = base - escala(d, 38);
                mover(self.c.usar_novo, margem, yc, escala(d, 160), escala(d, 32));
                mover(self.c.manter_meu, margem + escala(d, 170), yc, escala(d, 130), escala(d, 32));
            }
        }
        // O painel do controle, com a rolagem; fora dele, a janela não rola.
        if painel {
            self.posicionar_o_painel(hwnd);
        } else {
            self.esconder_a_rolagem(hwnd);
        }
        // A tela R5 põe a barra e os botões dela na faixa (do lado longe da lente) e a prévia na área
        // dela. Sem a tela R5, esconde os botões dela.
        self.r5_posicionar(hwnd);
        // **O código no prompter de texto** (§8.5): os três números e o "Nenhum destes" na faixa de
        // cima, à direita, no lugar do estado (a frase fica à esquerda, `pintar_prompter`). Os botões
        // são os da tela R5 (lá, o `r5_posicionar` os põe na faixa dela).
        if self.r5.is_none() {
            let cartao = self.codigo_da_sessao.clone().filter(|c| c.do_anfitriao() && !c.confirmado_aqui);
            let visivel = prompter && !editando && !self.faixas_ocultas && cartao.is_some();
            if visivel {
                let (w, wn, a, vao) = (escala(d, 104), escala(d, 128), escala(d, 40), escala(d, 8));
                let y = (escala(d, FAIXA_DE_CIMA) - a) / 2;
                let mut x = largura - escala(d, 16) - wn - 3 * (w + vao);
                for (i, h) in self.c.codigo_numeros.into_iter().enumerate() {
                    if let Some(n) = cartao.as_ref().and_then(|c| c.opcoes.get(i)) {
                        por_texto(h, &crate::conexao::em_grupos(n));
                        dar_nome(h, &idioma::tf(crate::conexao::MOLDE_DA_OPCAO, &[&crate::conexao::para_ler(n), &idioma::t(crate::conexao::posicao(i))]));
                    }
                    mover(h, x, y, w, a);
                    x += w + vao;
                }
                por_texto(self.c.codigo_recusar, idioma::t("Nenhum destes"));
                mover(self.c.codigo_recusar, x, y, wn, a);
            }
            for h in self.c.codigo_numeros {
                mostrar(h, visivel);
            }
            mostrar(self.c.codigo_recusar, visivel);
        }
    }

    // -----------------------------------------------------------------------------------------
    // A pintura
    // -----------------------------------------------------------------------------------------

    fn chave_das_faixas(&self) -> String {
        let e = self.estado_ou_padrao();
        let p = self.painel.as_ref();
        format!(
            "{:?}|{:?}|{}|{}|{}|{}|{:.2}|{:.1}|{:.4}|{:.4}|{}|{}|{}|{:?}|{}|{}|{:.3}|{}|{}",
            self.modo,
            p.map(|p| p.fase),
            p.map(|p| p.pin.clone()).unwrap_or_default(),
            p.map(|p| p.endereco.clone().unwrap_or_default()).unwrap_or_default(),
            p.map(|p| p.par.clone()).unwrap_or_default(),
            p.map(|p| p.mensagem.clone()).unwrap_or_default(),
            e.velocidade,
            e.fonte,
            e.margem,
            e.linha_de_leitura,
            e.espelho,
            e.rolando,
            e.texto_bytes,
            self.avisos,
            self.mensagem,
            self.mensagem_do_editor,
            if self.modo == Modo::Controle { e.posicao } else { 0.0 },
            p.map(|p| p.anunciando).unwrap_or(false),
            self.prompters.len(),
        ) + &format!("|{}|{:?}", self.ajustes.fonte_automatica, self.aviso_da_fonte)
            + &if self.modo == Modo::Controle {
                format!(
                    "|{}|{:?}|{:?}|{}|{:?}|{}|{}|{}|{:?}|{:?}|{:?}|{:?}|{}",
                    self.modo_segurar(),
                    self.disponibilidade_do_segurar(),
                    self.dedos.ativo(),
                    self.dedos.seguro(),
                    self.dedos.aviso_do_texto_parado(e.posicao),
                    e.segurando,
                    self.ajustes.inverter_botoes,
                    self.dedos.pode_inverter(),
                    // a pergunta do texto e os roteiros guardados
                    self.estado_da_caixa(),
                    self.pergunta_mostrada.as_ref().map(|m| (m.resumo_do_prompter.clone(), m.resumo_meu.clone())),
                    self.recusa_da_pergunta,
                    self.roteiros,
                    e.copias_do_texto.iter().map(|c| c.resumo.as_str()).collect::<Vec<_>>().join(",")
                )
            } else {
                String::new()
            }
    }

    fn invalidar_faixas(&self, hwnd: HWND) {
        if self.r5.is_some() {
            self.r5_invalidar(hwnd);
            if !self.estado.as_ref().is_some_and(|e| e.rolando) {
                let area = self.area_do_texto(hwnd);
                unsafe {
                    let _ = InvalidateRect(Some(hwnd), Some(&area), false);
                }
            }
            return;
        }
        unsafe {
            if self.modo == Modo::Prompter {
                let mut c = RECT::default();
                let _ = GetClientRect(hwnd, &mut c);
                let cima = RECT { bottom: escala(self.dpi, FAIXA_DE_CIMA), ..c };
                let baixo = RECT { top: c.bottom - escala(self.dpi, BARRA_DE_BAIXO), ..c };
                let _ = InvalidateRect(Some(hwnd), Some(&cima), false);
                let _ = InvalidateRect(Some(hwnd), Some(&baixo), false);
                if !self.estado.as_ref().is_some_and(|e| e.rolando) {
                    // Parado, o texto só é redesenhado por invalidação (espelho, linha, salto).
                    let area = self.area_do_texto(hwnd);
                    let _ = InvalidateRect(Some(hwnd), Some(&area), false);
                }
            } else {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }

    fn pintar(&mut self, hwnd: HWND, hdc: HDC) {
        let mut c = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut c);
        }
        let escuro = self.modo == Modo::Prompter;
        unsafe {
            FillRect(hdc, &c, if escuro { self.fundo_escuro } else { self.fundo_do_painel });
            SetBkMode(hdc, TRANSPARENT);
        }
        let mut p = Pintor { hdc, dpi: self.dpi, esquerda: escala(self.dpi, 24), largura: c.right - escala(self.dpi, 48) };
        match self.modo {
            Modo::Escolha => self.pintar_escolha(&mut p),
            Modo::Prompter => {
                if self.r5.is_some() {
                    self.r5_pintar(hwnd, hdc);
                } else {
                    self.pintar_prompter(&mut p, c);
                }
                let rolando = self.rolando_na_tela();
                if rolando {
                    self.janela_da_rolagem.pinturas += 1;
                }
                if self.rascunho.is_none() {
                    // **A faixa repintada não redesenha o texto** (14/10): com o texto rolando, uma
                    // pintura só da faixa (os estados da câmera, uma vez por segundo transmitindo ou
                    // gravando) desenhava o texto inteiro de novo fora do laço — um desenho a mais
                    // no mesmo retraço. Só quando a área a pintar encosta no texto.
                    if self.pintura_encosta_no_texto(hwnd, hdc) {
                        if rolando {
                            self.janela_da_rolagem.pinturas_com_texto += 1;
                        }
                        self.desenhar_texto(hwnd, Some(hdc));
                    }
                } else {
                    self.pintar_editor(&mut p, c);
                }
            }
            Modo::Controle => {
                if self.rascunho.is_some() {
                    self.pintar_editor(&mut p, c);
                } else if self.roteiros.is_some() {
                    self.pintar_roteiros(&mut p, c);
                } else if self.caixa_na_tela() {
                    self.pintar_pergunta(&mut p, c);
                } else if self.modo_segurar() {
                    self.pintar_segurar(hwnd, &mut p);
                } else {
                    // O formulário ou os comandos: o painel do estúdio.
                    self.pintar_painel(hwnd, hdc, c);
                }
            }
        }
    }

    /// A área que o `hdc` deixa pintar (o recorte do `BeginPaint`, a região exata, e não a caixa
    /// dela) encosta na do texto? Num DC sem recorte (a captura de bancada, `WM_PRINTCLIENT`), sim.
    fn pintura_encosta_no_texto(&self, hwnd: HWND, hdc: HDC) -> bool {
        let a = self.area_do_texto(hwnd);
        unsafe { RectVisible(hdc, &a) }.as_bool()
    }

    fn pintar_escolha(&self, p: &mut Pintor) {
        p.linha(&self.fontes.titulo, TINTA, 28, 36, idioma::t("Teleprompter"), DT_CENTER);
        p.linha(&self.fontes.pequeno, TINTA_FRACA, 70, 20, &idioma::tf("Este computador aparece na rede como {}", &[&self.nome]), DT_CENTER);
        p.paragrafo(
            &self.fontes.pequeno,
            TINTA_FRACA,
            98,
            44,
            idioma::t("Todo aparelho faz os dois papéis: este computador mostra o texto (atrás do vidro), ou controla o texto que outro aparelho mostra. O texto se edita dos dois lados."),
        );
        if !self.mensagem.is_empty() {
            // A mensagem pode vir de outro módulo (a câmera ocupada pela janela principal): traduzida
            // se for uma frase da tabela.
            p.paragrafo(&self.fontes.pequeno, ACENTO, 300, 60, &idioma::tr(&self.mensagem));
        }
    }

    // -----------------------------------------------------------------------------------------
    // O painel do controle (`painel_do_controle.rs`)
    // -----------------------------------------------------------------------------------------

    /// O painel do controle está na tela (o formulário ou os comandos, sem o editor, a lista de
    /// roteiros, a pergunta nem o modo segurar)?
    fn painel_visivel(&self) -> bool {
        self.modo == Modo::Controle && self.rascunho.is_none() && self.roteiros.is_none() && !self.caixa_na_tela() && !self.modo_segurar()
    }

    /// **O que o painel mostra agora**, com as frases no idioma de agora. Os rótulos dos botões são
    /// os que eles mostram (`texto_de`): Rolar/Pausar e o gravar mudam com o estado.
    fn tela_do_painel(&self) -> Option<pdc::Tela> {
        if !self.painel_visivel() {
            return None;
        }
        let botao = |c: PecaDoPainel, h: HWND| pdc::Botao::novo(c, texto_de(h));
        let roteiro = |frase: &str| pdc::BlocoDoRoteiro {
            rotulo: idioma::t("ROTEIRO").into(),
            info: format!("{} · {}", regras::tamanho_do_roteiro(self.texto.len(), TETO_DO_TEXTO), frase),
            previa: regras::previa_do_roteiro(&self.texto, regras::LETRAS_DA_PREVIA),
            previa_vazia: self.texto.trim().is_empty(),
            botao: texto_de(self.c.editar_roteiro),
        };
        let sessao_viva = self.sessao.as_ref().is_some_and(|s| !s.terminou());
        if !sessao_viva {
            // Uma trava por leitura: duas guardas do mesmo `Mutex` na mesma expressão travariam.
            let (ativa, motivo) = self
                .busca
                .as_ref()
                .map(|b| {
                    let l = b.lista();
                    (l.ativa, l.motivo.clone())
                })
                .unwrap_or((true, String::new()));
            let cabecalho = if !ativa && !motivo.is_empty() {
                // O motivo é da procura (`descoberta.rs`, outro módulo): traduzido se estiver na tabela.
                idioma::tr(&motivo)
            } else if self.prompters.is_empty() {
                idioma::t("Procurando prompters… (no outro aparelho: Quall → Teleprompter → Mostrar o texto)").into()
            } else {
                idioma::tf("{} prompter(s) na rede — clique duas vezes para conectar", &[&self.prompters.len()])
            };
            let mensagem = self.painel.as_ref().map(|p| p.mensagem.clone()).filter(|m| !m.is_empty()).unwrap_or_else(|| self.mensagem.clone());
            return Some(pdc::Tela::Formulario(pdc::Formulario {
                titulo: idioma::t("Controlar um teleprompter").into(),
                subtitulo: idioma::tf("Este computador aparece na rede como {}", &[&self.nome]),
                rotulo_da_lista: idioma::t("NA REDE").into(),
                procurar_de_novo: texto_de(self.c.procurar_de_novo),
                cabecalho_da_lista: cabecalho,
                rotulo_do_endereco: idioma::t("NÃO ACHOU? DIGITE O ENDEREÇO QUE O PROMPTER MOSTRA").into(),
                rotulo_do_pin: "PIN".into(),
                ajuda_do_pin: idioma::t("Deixe vazio se este computador e o prompter já se parearam antes.").into(),
                mensagem: if mensagem.is_empty() { String::new() } else { idioma::tr(&mensagem) },
                botoes: vec![
                    pdc::Botao::principal(PecaDoPainel::Conectar, texto_de(self.c.conectar)),
                    botao(PecaDoPainel::Voltar, self.c.voltar),
                    botao(PecaDoPainel::Roteiros, self.c.roteiros),
                ],
                roteiro: roteiro(idioma::t("vai ao prompter ao conectar; se ele tiver outro, a tela pergunta qual usar.")),
            }));
        }
        let e = self.estado_ou_padrao();
        let painel = self.painel.clone();
        let fase = painel.as_ref().map(|p| p.fase).unwrap_or(Fase::Abrindo);
        let destino = painel.as_ref().and_then(|p| p.endereco.clone()).unwrap_or_default();
        let titulo = match fase {
            Fase::Conectada => idioma::tf("Controlando {}", &[&idioma::tr(&painel.as_ref().map(|p| p.par.clone()).unwrap_or_default())]),
            Fase::SemPar => idioma::tf("Conexão perdida — tentando de novo ({})", &[&destino]),
            Fase::Encerrando => idioma::t("Desconectando…").into(),
            _ => idioma::tf("Conectando em {}…", &[&destino]),
        };
        let mut avisos: Vec<String> = Vec::new();
        if self.avisos.par_sumido && fase == Fase::Conectada {
            avisos.push(idioma::t("O prompter não responde. Os comandos vão quando a conexão voltar.").to_string());
        }
        if self.avisos.sem_confirmacao {
            avisos.push(idioma::t("O comando não chegou ao prompter (sem confirmação há mais de 1,5 s).").into());
        }
        if self.avisos.atualize_o_app {
            avisos.push(idioma::t("O prompter fala outra versão do teleprompter: atualize o app nos dois aparelhos.").into());
        }
        if self.avisos.relogio_errado {
            avisos.push(idioma::t("O relógio de um dos dois aparelhos está mais de um dia errado: edições foram recusadas.").into());
        }
        if self.avisos.texto_nao_passou {
            avisos.push(idioma::t("O roteiro não passou para o prompter (ele o recusou 20 vezes).").into());
        }
        if let Some(m) = painel.as_ref().map(|p| p.mensagem.clone()).filter(|m| !m.is_empty()) {
            avisos.push(idioma::tr(&m));
        }
        let (velocidade, fonte, margem, linha) = (idioma::decimal(e.velocidade, 2), um_decimal(e.fonte), pct(e.margem), pct(e.linha_de_leitura));
        let espelho = if e.espelho { idioma::t("sim") } else { idioma::t("não") };
        let comando = |id: usize| self.c.comandos.iter().find(|(i, _)| *i == id).map(|(_, h)| botao(PecaDoPainel::Comando(id), *h));
        let mut transporte: Vec<pdc::Botao> =
            [ID_ROLAR, ID_INICIO, ID_PULAR_MENOS, ID_PULAR_MAIS, ID_ESPELHO, ID_EDITAR].into_iter().filter_map(comando).collect();
        if let Some(b) = transporte.first_mut() {
            b.principal = true;
        }
        let ajustes: Vec<pdc::Botao> = [ID_VEL_MENOS, ID_VEL_MAIS, ID_FONTE_MENOS, ID_FONTE_MAIS, ID_MARGEM_MENOS, ID_MARGEM_MAIS, ID_LINHA_ACIMA, ID_LINHA_ABAIXO]
            .into_iter()
            .filter_map(comando)
            .collect();
        let mut outros = vec![botao(PecaDoPainel::Segurar, self.c.segurar)];
        if self.controle_gravar_visivel() {
            outros.push(botao(PecaDoPainel::GravarRemoto, self.c.gravar_remoto));
        }
        if self.controle_camera_visivel() {
            outros.push(botao(PecaDoPainel::CameraDoPrompter, self.c.camera_do_prompter));
        }
        outros.push(botao(PecaDoPainel::Roteiros, self.c.roteiros));
        let gravando = self.estado.as_ref().is_some_and(|e| e.gravando_ha_ms.is_some());
        let codigo = self.codigo_da_sessao.as_ref().filter(|c| !c.do_anfitriao()).map(|c| pdc::CodigoNoControle {
            aviso: c.pareamento_anterior.then(|| idioma::t(crate::conexao::FRASE_PAREAMENTO_ANTERIOR).to_string()),
            titulo: idioma::t("Escolha este número no outro aparelho.").into(),
            codigo: c.codigo.clone(),
            linha: idioma::t("Ele mostra três números; só este é o certo.").into(),
        });
        Some(pdc::Tela::Conectado(pdc::Conectado {
            titulo,
            codigo,
            sair: texto_de(self.c.sair),
            tudo_certo: fase == Fase::Conectada && avisos.is_empty(),
            avisos,
            confirmado: idioma::t("Tudo confirmado pelo prompter.").into(),
            posicao: e.posicao,
            legenda_da_posicao: {
                let estado = if e.rolando { idioma::t(" — rolando") } else { idioma::t(" — parado") };
                idioma::tf("Posição no prompter: {}{}", &[&pct(e.posicao), &estado])
            },
            valores: idioma::tf("Velocidade {} linha(s)/s  ·  Fonte {}  ·  Margem {}  ·  Linha de leitura {}  ·  Espelho: {}", &[&velocidade, &fonte, &margem, &linha, &espelho]),
            resumo: idioma::tf("Roteiro: resumo {}", &[&resumo(&self.texto)]),
            gravacao: self.controle_linha_de_gravar().map(|l| (l, gravando)),
            grupos: vec![transporte, ajustes, outros],
            teclado: idioma::t("Teclado: espaço rola/pausa · ↑↓ move o texto 1 % (segure para andar; segue \"Inverter botões\") · PgUp PgDn 10 % · Shift+↑↓ velocidade · ←→ pular 5 % (Shift = 10 %) · Home começo · M espelho · + − fonte · [ ] margem · , . linha · E editar").into(),
            roteiro: roteiro(idioma::t("o texto vai ao prompter ao confirmar no editor.")),
        }))
    }

    /// O controle nativo de cada peça do painel.
    fn controle_da_peca(&self, p: PecaDoPainel) -> Option<HWND> {
        let c = &self.c;
        Some(match p {
            PecaDoPainel::Lista => c.lista,
            PecaDoPainel::Endereco => c.endereco,
            PecaDoPainel::Pin => c.pin,
            PecaDoPainel::Conectar => c.conectar,
            PecaDoPainel::Voltar => c.voltar,
            PecaDoPainel::ProcurarDeNovo => c.procurar_de_novo,
            PecaDoPainel::Roteiros => c.roteiros,
            PecaDoPainel::EditarRoteiro => c.editar_roteiro,
            PecaDoPainel::Sair => c.sair,
            PecaDoPainel::Segurar => c.segurar,
            PecaDoPainel::GravarRemoto => c.gravar_remoto,
            PecaDoPainel::CameraDoPrompter => c.camera_do_prompter,
            PecaDoPainel::Comando(id) => return c.comandos.iter().find(|(i, _)| *i == id).map(|(_, h)| *h),
        })
    }

    /// A área de cliente em DIP: `(largura, altura)`.
    fn cliente_em_dip(&self, hwnd: HWND) -> (f32, f32) {
        let mut c = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut c);
        }
        let k = self.dpi as f32 / 96.0;
        (c.right as f32 / k, c.bottom as f32 / k)
    }

    /// **Põe o painel no lugar**: decide a barra de rolagem (o conteúdo passa da janela?), limita a
    /// rolagem e move cada controle. A barra é decidida pela largura **sem** ela: se o conteúdo cabe
    /// com a barra tirada, ela some; senão fica — a mesma resposta nas duas voltas, sem a barra
    /// piscar no limite.
    fn posicionar_o_painel(&mut self, hwnd: HWND) {
        let Some(tela) = self.tela_do_painel() else { return };
        let dpi = self.dpi;
        let k = dpi as f32 / 96.0;
        let (largura, vista) = self.cliente_em_dip(hwnd);
        let tem_barra = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32 & WS_VSCROLL.0 != 0;
        let barra = unsafe { GetSystemMetricsForDpi(SM_CXVSCROLL, dpi) } as f32 / k;
        let total = largura + if tem_barra { barra } else { 0.0 };
        let estreita = pdc::dispor(&tela, total - barra, 0.0);
        // Em pixels, como o `SetScrollInfo` decide mostrar a barra: em DIP, um conteúdo que passa da
        // vista por menos de meio pixel faria a barra aparecer e sumir a cada volta.
        let precisa = escala_f(dpi, estreita.altura) > escala_f(dpi, vista);
        let conteudo = if precisa { estreita.altura } else { pdc::dispor(&tela, total, 0.0).altura };
        self.rolagem_do_painel = pdc::limitar_rolagem(self.rolagem_do_painel, conteudo, vista);
        unsafe {
            if precisa {
                let si = SCROLLINFO {
                    cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
                    fMask: SIF_RANGE | SIF_PAGE | SIF_POS,
                    nMin: 0,
                    nMax: escala_f(dpi, conteudo) - 1,
                    nPage: escala_f(dpi, vista).max(1) as u32,
                    nPos: escala_f(dpi, self.rolagem_do_painel),
                    nTrackPos: 0,
                };
                let _ = windows::Win32::UI::Controls::SetScrollInfo(hwnd, SB_VERT, &si, true);
            }
            if precisa != tem_barra {
                // A área de cliente muda: o `WM_SIZE` que vem pede outra volta de `posicionar`.
                let _ = windows::Win32::UI::Controls::ShowScrollBar(hwnd, SB_VERT, precisa);
            }
        }
        let (largura, _) = self.cliente_em_dip(hwnd);
        let lugares = pdc::dispor(&tela, largura, self.rolagem_do_painel);
        for (peca, r) in &lugares.controles {
            if let Some(h) = self.controle_da_peca(*peca) {
                let p = em_pixels(dpi, *r);
                unsafe {
                    let _ = MoveWindow(h, p.left, p.top, p.right - p.left, p.bottom - p.top, true);
                }
            }
        }
        self.controles_postos = lugares.controles;
    }

    /// Fora do painel a janela não rola.
    fn esconder_a_rolagem(&mut self, hwnd: HWND) {
        self.rolagem_do_painel = 0.0;
        self.controles_postos.clear();
        let tem_barra = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32 & WS_VSCROLL.0 != 0;
        if tem_barra {
            unsafe {
                let _ = windows::Win32::UI::Controls::ShowScrollBar(hwnd, SB_VERT, false);
            }
        }
    }

    /// **Rola o painel**: `f(rolagem, altura do conteúdo, altura da vista)` dá a rolagem nova.
    fn rolar_o_painel(&mut self, hwnd: HWND, f: impl FnOnce(f32, f32, f32) -> f32) {
        let Some(tela) = self.tela_do_painel() else { return };
        let (largura, vista) = self.cliente_em_dip(hwnd);
        let conteudo = pdc::dispor(&tela, largura, 0.0).altura;
        let nova = f(self.rolagem_do_painel, conteudo, vista);
        if (nova - self.rolagem_do_painel).abs() < 0.01 {
            return;
        }
        self.rolagem_do_painel = nova;
        self.posicionar(hwnd);
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }

    /// Um campo ou a lista ganhou o foco pelo teclado: se ele está fora da vista, o painel rola até
    /// ele. **Pelo mouse, não**: rolar no meio do clique moveria a lista debaixo do ponteiro, e o
    /// segundo clique de um duplo clique cairia noutro prompter (a revisão de 12/10). Os botões não
    /// avisam o foco (sem `BS_NOTIFY`, de propósito: com ele o segundo clique rápido vira
    /// `BN_DOUBLECLICKED` e o "Vel +" perderia toques); a roda e a barra chegam neles.
    fn mostrar_o_foco(&mut self, hwnd: HWND, peca: PecaDoPainel) {
        if unsafe { GetKeyState(VK_LBUTTON.0 as i32) } < 0 {
            return;
        }
        let Some(r) = self.controles_postos.iter().find(|(p, _)| *p == peca).map(|(_, r)| *r) else { return };
        // Os lugares postos já têm a rolagem: o alvo, sem ela.
        let alvo = estilo::Ret { y: r.y + self.rolagem_do_painel, ..r };
        self.rolar_o_painel(hwnd, |rolagem, conteudo, vista| pdc::rolagem_para_ver(rolagem, alvo, conteudo, vista));
    }

    /// **Pinta o painel**: as peças do estúdio pelo Direct2D (o GDI de reserva, sem ele). Se a
    /// disposição de agora não é a que os controles têm (uma linha que mudou de altura sem passar por
    /// `posicionar`, como a da gravação, que conta o tempo), os controles vão para o lugar novo.
    fn pintar_painel(&mut self, hwnd: HWND, hdc: HDC, c: RECT) {
        let Some(tela) = self.tela_do_painel() else { return };
        let dpi = self.dpi;
        let k = dpi as f32 / 96.0;
        let mut lugares: Lugares = pdc::dispor(&tela, c.right as f32 / k, self.rolagem_do_painel);
        let mut c = c;
        if lugares.controles != self.controles_postos {
            self.posicionar(hwnd);
            // `posicionar` pode ter limitado a rolagem ou mexido na barra: este quadro já sai com a
            // disposição nova.
            unsafe {
                let _ = GetClientRect(hwnd, &mut c);
            }
            let Some(tela) = self.tela_do_painel() else { return };
            lugares = pdc::dispor(&tela, c.right as f32 / k, self.rolagem_do_painel);
        }
        match self.pintor.as_mut() {
            Some(p) => {
                if let Err(e) = p.desenhar(hdc, c, dpi, Some(estilo::FUNDO), &lugares.itens, 1.0) {
                    if !self.falha_do_desenho_dita {
                        self.falha_do_desenho_dita = true;
                        registro::linha(format!("teleprompter: !! o desenho do painel falhou: {e}"));
                    }
                }
            }
            None => {
                // O GDI de reserva: as caixas cheias e os textos, sem cantos nem alfa.
                for item in &lugares.itens {
                    match item {
                        estilo::Item::Caixa { ret, fundo, .. } if fundo.a > 0 => unsafe {
                            let pincel = CreateSolidBrush(COLORREF(fundo.colorref()));
                            FillRect(hdc, &em_pixels(dpi, *ret), pincel);
                            let _ = DeleteObject(pincel.into());
                        },
                        estilo::Item::Texto(t) => {
                            let mut r = em_pixels(dpi, t.ret);
                            let formato = if t.quebra {
                                DT_LEFT | DT_WORDBREAK | DT_NOPREFIX
                            } else {
                                DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX
                            };
                            desenhar_em(hdc, &self.fontes.pequeno, COLORREF(t.cor.colorref()), &mut r, &t.texto_corrido(), formato);
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Os botões no desenho do estúdio (`NM_CUSTOMDRAW`)
    // -----------------------------------------------------------------------------------------

    /// Este controle é um botão que a janela desenha? Fora do prompter (a barra dele e a da tela R5
    /// ficam com a cara do sistema nesta rodada), com o Direct2D de pé, e só `BUTTON`s (a dica da
    /// tela cheia também manda `NM_CUSTOMDRAW`).
    fn desenha_o_botao(&self, h: HWND) -> bool {
        if self.modo == Modo::Prompter || self.pintor.is_none() || h == self.c.dica_da_tela_cheia {
            return false;
        }
        let mut classe = [0u16; 16];
        let n = unsafe { GetClassNameW(h, &mut classe) } as usize;
        String::from_utf16_lossy(&classe[..n.min(classe.len())]).eq_ignore_ascii_case("Button") // i18n: fora (a classe de janela)
    }

    /// O papel de cada botão: o principal da tela de agora em violeta, o que apaga ou para em
    /// vermelho, o resto secundário.
    fn papel_do_botao(&self, id: usize) -> pdc::Papel {
        match id {
            ID_CONECTAR | ID_CONFIRMAR => pdc::Papel::Principal,
            ID_ROLAR if self.modo == Modo::Controle => pdc::Papel::Principal,
            ID_CONFIRMA_SIM if matches!(self.roteiros, Some(VistaDosRoteiros::ConfirmarApagar(_))) => pdc::Papel::Perigo,
            ID_GRAVAR_REMOTO if self.estado.as_ref().is_some_and(|e| e.gravando_ha_ms.is_some()) => pdc::Papel::Perigo,
            _ => pdc::Papel::Secundario,
        }
    }

    fn desenhar_botao(&mut self, cd: &windows::Win32::UI::Controls::NMCUSTOMDRAW) {
        use windows::Win32::UI::Controls::{CDIS_DISABLED, CDIS_FOCUS, CDIS_HOT, CDIS_SELECTED, NMCUSTOMDRAW_DRAW_STATE_FLAGS};
        let h = cd.hdr.hwndFrom;
        let s = cd.uItemState;
        let tem = |f: NMCUSTOMDRAW_DRAW_STATE_FLAGS| (s.0 & f.0) != 0;
        let foco_escondido = (unsafe { SendMessageW(h, WM_QUERYUISTATE, None, None) }.0 as u32 & UISF_HIDEFOCUS) != 0;
        let estado = pdc::EstadoDoBotao {
            apertado: tem(CDIS_SELECTED),
            foco: tem(CDIS_FOCUS) && !foco_escondido,
            desligado: tem(CDIS_DISABLED),
            quente: tem(CDIS_HOT),
            marcado: marcado(h),
        };
        let dpi = self.dpi;
        let k = 96.0 / dpi as f32;
        let (l, a) = ((cd.rc.right - cd.rc.left) as f32 * k, (cd.rc.bottom - cd.rc.top) as f32 * k);
        let (itens, opacidade) = pdc::aparencia(self.papel_do_botao(cd.hdr.idFrom), &texto_de(h), l, a, estado);
        // O do roteiro mora dentro do cartão: os cantos mostram a `superficie`.
        let fundo = if cd.hdr.idFrom == ID_EDITAR_ROTEIRO && self.painel_visivel() { estilo::SUPERFICIE } else { estilo::FUNDO };
        if let Some(p) = self.pintor.as_mut() {
            if let Err(e) = p.desenhar(cd.hdc, cd.rc, dpi, Some(fundo), &itens, opacidade) {
                if !self.falha_do_desenho_dita {
                    self.falha_do_desenho_dita = true;
                    registro::linha(format!("teleprompter: !! o desenho de um botão falhou: {e}"));
                }
            }
        }
    }

    fn pintar_prompter(&self, p: &mut Pintor, c: RECT) {
        if self.faixas_ocultas {
            return;
        }
        let e = self.estado_ou_padrao();
        let painel = self.painel.clone();
        let fase = painel.as_ref().map(|p| p.fase);
        let pin = painel.as_ref().map(|p| p.pin.clone()).unwrap_or_default();
        let endereco = painel.as_ref().and_then(|p| p.endereco.clone()).unwrap_or_else(|| idioma::t("sem rede").into());
        let porta = painel.as_ref().map(|p| p.porta).unwrap_or(0);
        p.esquerda = escala(self.dpi, 16);
        p.largura = c.right - escala(self.dpi, 32);
        if self.cfg.sem_sessao {
            p.linha(&self.fontes.corpo, TINTA_CLARA, 8, 24, "Só o texto, sem controle (bancada: --sem-sessao)", DT_LEFT); // i18n: fora (bancada)
        } else if fase == Some(Fase::Parada) {
            let m = idioma::tr(&painel.as_ref().map(|p| p.mensagem.clone()).unwrap_or_default());
            p.paragrafo_esquerda(&self.fontes.pequeno, LARANJA, 8, 56, &idioma::tf("A espera parou. {}", &[&m]));
        } else if let Some(c) = self.codigo_da_sessao.as_ref().filter(|c| c.do_anfitriao() && self.r5.is_none()) {
            // **O código** (§8.5): à esquerda, a pergunta e quem pede; os números estão à direita
            // (`posicionar`). Confirmado aqui, a frase de espera, sem os números.
            let quem = if c.par.is_empty() { idioma::t("Um aparelho").to_string() } else { c.par.clone() };
            let largura = p.largura;
            if !c.confirmado_aqui {
                p.largura = (largura - escala(self.dpi, 128 + 3 * 112 + 24)).max(escala(self.dpi, 120));
            }
            p.linha(&self.fontes.corpo, LARANJA, 4, 26, idioma::t("Qual número o outro aparelho mostra?"), DT_LEFT);
            let segunda = if c.confirmado_aqui {
                idioma::t("Número certo. Conectando…").to_string()
            } else {
                idioma::tf("{} quer conectar", &[&quem])
            };
            p.linha(&self.fontes.pequeno, TINTA_CLARA, 30, 18, &segunda, DT_LEFT);
            p.linha(&self.fontes.pequeno, TINTA_CLARA_FRACA, 50, 18, idioma::t("Errar o número desliga o código nesta espera; o PIN continua valendo."), DT_LEFT);
            p.largura = largura;
            return;
        } else {
            p.linha(&self.fontes.grande, TINTA_CLARA, 4, 36, &format!("PIN {pin}"), DT_LEFT);
            let mut segunda = endereco;
            if porta != 0 && porta != regras::porta_do_teleprompter() {
                segunda.push_str(&idioma::tf("   ·   a porta {} estava ocupada: use a {}", &[&regras::porta_do_teleprompter(), &porta]));
            }
            p.linha(&self.fontes.pequeno, TINTA_CLARA_FRACA, 40, 18, &segunda, DT_LEFT);
            let anuncio = if painel.as_ref().is_some_and(|p| p.anunciando) {
                idioma::tf("Na lista: {}. No outro aparelho: Teleprompter → Controlar.", &[&painel
                    .as_ref()
                    .map(|p| crate::conexao::nome_da_espera_em_linha(&p.nome_da_descoberta, &p.alias_da_descoberta))
                    .unwrap_or_default()])
            } else {
                idioma::t("Sem anúncio na rede: digite o endereço no controle.").to_string()
            };
            let anuncio = match self.aviso_do_codigo {
                Some(a) => idioma::t(a).to_string(),
                None => anuncio,
            };
            p.linha(&self.fontes.pequeno, if self.aviso_do_codigo.is_some() { LARANJA } else { TINTA_CLARA_FRACA }, 56, 16, &anuncio, DT_LEFT);
        }
        // À direita: com quem está, ou o aviso de controle sumido.
        let (cor, estado) = if self.avisos.par_sumido && painel.as_ref().is_some_and(|p| p.ja_houve_sessao) {
            (LARANJA, idioma::t("CONTROLE SUMIDO — o texto continua como estava. Esperando o controle voltar.").to_string())
        } else if fase == Some(Fase::Conectada) {
            (TINTA_CLARA, idioma::tf("Controlado por {}", &[&idioma::tr(&painel.as_ref().map(|p| p.par.clone()).unwrap_or_default())]))
        } else if self.cfg.sem_sessao {
            (TINTA_CLARA_FRACA, String::new())
        } else {
            (TINTA_CLARA_FRACA, idioma::t("Esperando o controle").to_string())
        };
        p.linha(&self.fontes.corpo, cor, 6, 26, &estado, DT_RIGHT);
        let (velocidade, fonte, margem, linha) = (idioma::decimal(e.velocidade, 2), um_decimal(e.fonte), pct(e.margem), pct(e.linha_de_leitura));
        let automatica = if self.ajustes.fonte_automatica { idioma::t(" (automática)") } else { "" };
        let espelho = if e.espelho { idioma::t(" · espelho") } else { "" };
        let mut valores =
            idioma::tf("{} linha/s · fonte {}{} · margem {} · linha {}{}", &[&velocidade, &fonte, &automatica, &margem, &linha, &espelho]);
        if self.avisos.atualize_o_app {
            valores.push_str(idioma::t(" · o controle fala outra versão: atualize o app"));
        }
        if self.avisos.sem_confirmacao {
            valores.push_str(idioma::t(" · a última edição daqui não foi confirmada"));
        }
        p.linha(&self.fontes.pequeno, if self.avisos.atualize_o_app { LARANJA } else { TINTA_CLARA_FRACA }, 36, 18, &valores, DT_RIGHT);
        if let Some(aviso) = self.aviso_da_fonte_mostrado() {
            p.linha(&self.fontes.pequeno, LARANJA, 54, 18, &aviso, DT_RIGHT);
        }
    }

    fn pintar_editor(&self, p: &mut Pintor, c: RECT) {
        let Some(r) = &self.rascunho else { return };
        let (tinta, fraca) = if self.modo == Modo::Prompter { (TINTA_CLARA, TINTA_CLARA_FRACA) } else { (TINTA, TINTA_FRACA) };
        let topo_do_texto = if self.modo == Modo::Prompter { FAIXA_DE_CIMA } else { 150 };
        if self.modo == Modo::Controle {
            p.linha(&self.fontes.titulo, tinta, 16, 32, idioma::t("Roteiro"), DT_LEFT);
            p.linha(&self.fontes.pequeno, fraca, 52, 20, idioma::t("O texto só vai para o outro aparelho ao confirmar."), DT_LEFT);
        }
        let mut info = regras::tamanho_do_roteiro(r.bytes(), TETO_DO_TEXTO);
        if r.atualizado_pelo_outro_lado() && !r.em_conflito() {
            info.push_str(idioma::t(" · o texto foi atualizado pelo outro aparelho"));
        }
        if !self.mensagem_do_editor.is_empty() {
            info.push_str(" · ");
            info.push_str(&idioma::tr(&self.mensagem_do_editor));
        }
        let y_info = ((c.bottom * 96 / self.dpi as i32) - 44).max(topo_do_texto + 8);
        p.linha(&self.fontes.pequeno, fraca, y_info, 30, &info, DT_LEFT);
        if r.em_conflito() {
            p.linha(
                &self.fontes.corpo,
                if self.modo == Modo::Prompter { LARANJA } else { ACENTO },
                (c.bottom * 96 / self.dpi as i32) - 138,
                24,
                idioma::t("O texto mudou no outro aparelho enquanto você editava. Usar o texto novo, ou manter o seu (ao confirmar, o seu vale nos dois)."),
                DT_LEFT,
            );
        }
    }
}

// =============================================================================================
// A bancada: o relato final
// =============================================================================================

impl Tela {
    fn escrever_relato(&mut self, hwnd: HWND) {
        if self.relato_escrito {
            return;
        }
        self.relato_escrito = true;
        let estado = self.teleprompter.as_ref().and_then(|t| t.estado().ok());
        let texto = self.teleprompter.as_ref().and_then(|t| t.texto().ok()).unwrap_or_default();
        let medidas = self.sessao.as_ref().map(|s| s.medidas());
        let painel = self.painel.clone();
        let mut confirmacoes: Vec<f32> =
            medidas.as_ref().map(|m| m.confirmacoes_ms.iter().map(|x| *x as f32).collect()).unwrap_or_default();
        let n_conf = confirmacoes.len();
        let conf_p50 = super::geometria::percentil(&mut confirmacoes, 0.5);
        let conf_p90 = super::geometria::percentil(&mut confirmacoes, 0.9);
        let conf_max = confirmacoes.iter().copied().fold(0.0f32, f32::max);
        let mut custos: Vec<f32> = self.layouts.iter().map(|l| l.0 as f32).collect();
        let maior_layout = custos.iter().copied().fold(0.0f32, f32::max);
        let layout_do_maior_texto = self
            .layouts
            .iter()
            .filter(|l| l.3 >= 90_000)
            .map(|l| serde_json::json!({"custo_ms": (l.0 * 100.0).round() / 100.0, "fonte_px": l.1, "linhas": l.2, "bytes": l.3}))
            .collect::<Vec<_>>();
        let papel = match self.lado {
            Some(Lado::Prompter) => "prompter",
            Some(Lado::Controle) => "controle",
            None => "nenhum",
        };
        let sessao = medidas.as_ref().map(|m| {
            serde_json::json!({
                "sessoes_de_pe": m.sessoes_de_pe,
                "quedas": m.quedas,
                "tentativas_que_falharam": m.tentativas,
                "pins_trocados": m.pins_trocados,
                "ocupados_ouvidos": m.ocupados_ouvidos,
                "entrega": m.entrega,
                "mensageiro_da_ultima_sessao": m.mensageiro,
                "atendidos_durante_a_sessao": m.atendidos_durante_a_sessao,
                "candidatos_descartados": m.candidatos_descartados,
                "falhas": m.falhas,
                "eventos": m.eventos,
            })
        });
        let compasso = match self.dwm {
            Some(true) => "DWM (DwmFlush + cRefresh)",
            Some(false) => "relógio de 60 Hz (sem DWM): a cadência é a do laço, não a da tela", // i18n: fora (relato)
            None => "não rolou", // i18n: fora (relato)
        };
        let rolagem = if self.lado == Some(Lado::Prompter) {
            serde_json::json!({
                "compasso": compasso,
                "cadencia": self.cadencia.resumo(),
                "maior_intervalo_no_segundo_depois_de_um_layout_ms": (self.maior_intervalo_perto_do_layout_ms * 100.0).round() / 100.0,
                "linhas_criadas_na_thread_da_janela": self.desenho.as_ref().map(|d| d.linhas_criadas),
                "alvo_do_direct2d": self.desenho.as_ref().map(|d| d.tipo_do_alvo()),
                "por_que_software": self.desenho.as_ref().and_then(|d| d.motivo_do_software.clone()),
                "falhas_de_desenho": self.falhas_de_desenho,
                "copias_para_a_janela_que_falharam": self.copias_falhas,
                "intervalos_longos": self.intervalos_longos,
                "arrastos_da_linha": self.arrastos,
            })
        } else {
            serde_json::Value::Null
        };
        let tela_acesa = if self.lado == Some(Lado::Prompter) {
            serde_json::json!({ "set_thread_execution_state_devolveu": self.tela_acesa.map(|v| format!("0x{v:08X}")) })
        } else {
            serde_json::Value::Null
        };
        let custo_p50 = super::geometria::percentil(&mut custos, 0.5);
        let amostras = medidas.as_ref().map(|m| m.confirmacoes_ms.clone());
        let ajustes_locais = if self.lado == Some(Lado::Prompter) {
            serde_json::json!({
                "enquadramento": self.ajustes.enquadramento,
                "fonte_automatica_ligada_no_fim": self.ajustes.fonte_automatica,
                "aviso_da_fonte": self.aviso_da_fonte,
                "arrastos_do_enquadramento": self.arrastos_do_enquadramento,
                "contas_da_fonte_automatica": self.fontes_automaticas,
                "coluna_de_texto_px": self.diagramado.largura_px,
            })
        } else {
            serde_json::Value::Null
        };
        let mut valor = serde_json::json!({
            "papel": papel,
            "r5": self.r5_relato(),
            "device_id": identidade::device_id(),
            "nome": self.nome,
            "segundos": (self.segundos() * 1000.0).round() / 1000.0,
            "porta": painel.as_ref().map(|p| p.porta),
            "endereco": painel.as_ref().and_then(|p| p.endereco.clone()),
            "pin": serde_json::Value::Null,
            "par": painel.as_ref().map(|p| p.par.clone()),
            "fase_final": painel.as_ref().map(|p| format!("{:?}", p.fase)),
            "roteiro": { "bytes": texto.len(), "resumo": resumo(&texto) }, // i18n: fora (relato)
            "estado_final": estado,
            "sessao": sessao,
            "confirmacao": {
                "n": n_conf,
                "p50_ms": conf_p50,
                "p90_ms": conf_p90,
                "max_ms": conf_max,
                "amostras_ms": amostras,
            },
            "rolagem": rolagem,
            "layout": {
                "vezes": self.layouts.len(),
                "custo_p50_ms": custo_p50,
                "custo_max_ms": maior_layout,
                "com_roteiro_de_90_kb_ou_mais": layout_do_maior_texto,
            },
            "tela_acesa": tela_acesa, // i18n: fora (relato)
            "ajustes_locais": ajustes_locais,
            "pergunta": {
                "eventos": self.eventos_da_pergunta,
                "recusa": self.recusa_da_pergunta.map(|c| c.nome()),
                "aberta_no_fim": estado.as_ref().map(|e| e.pergunta_do_texto.is_some()),
                "copias": estado.as_ref().map(|e| e.copias_do_texto.iter().map(|c| serde_json::json!({
                    "origem": format!("{:?}", c.origem),
                    "prompter_nome": c.prompter_nome,
                    "bytes": c.bytes,
                    "resumo": c.resumo,
                })).collect::<Vec<_>>()),
            },
            "segurar": {
                "modo_ligado": self.ajustes.segurar_para_rolar,
                "botoes_invertidos": self.ajustes.inverter_botoes,
                "par_entende_segurar": estado.as_ref().map(|e| e.par_entende_segurar),
                "recusa": self.recusa_do_segurar.map(|c| c.nome()),
                "eventos": self.eventos_do_segurar,
            },
            "avisos": self.eventos_de_aviso,
            "acoes": { "agendadas": self.acoes.acoes.len(), "executadas": self.acoes_executadas, "recusadas": self.acoes.recusadas },
            "capturas": self.capturas,
        });
        crate::diagnostico_json::redigir(&mut valor);
        registro::linha(format!("teleprompter: relato: {}", serde_json::to_string(&valor).unwrap_or_default()));
        if let Some(caminho) = &self.cfg.relato {
            match bancada::escrever_json(caminho, &valor) {
                Ok(()) => registro::linha(format!("teleprompter: relato gravado em {}", caminho.display())),
                Err(e) => registro::linha(format!("teleprompter: !! relato não gravado em {}: {e}", caminho.display())),
            }
        }
        let _ = hwnd;
    }
}

// =============================================================================================
// O pintor (GDI), no molde de `janela.rs`
// =============================================================================================

struct Pintor {
    hdc: HDC,
    dpi: u32,
    esquerda: i32,
    largura: i32,
}

impl Pintor {
    fn linha(&mut self, fonte: &HFONT, cor: COLORREF, topo: i32, altura: i32, texto: &str, alinha: DRAW_TEXT_FORMAT) {
        self.desenhar(fonte, cor, topo, altura, texto, alinha | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    }

    fn paragrafo(&mut self, fonte: &HFONT, cor: COLORREF, topo: i32, altura: i32, texto: &str) {
        self.desenhar(fonte, cor, topo, altura, texto, DT_CENTER | DT_WORDBREAK);
    }

    fn paragrafo_esquerda(&mut self, fonte: &HFONT, cor: COLORREF, topo: i32, altura: i32, texto: &str) {
        self.desenhar(fonte, cor, topo, altura, texto, DT_LEFT | DT_WORDBREAK);
    }

    fn desenhar(&mut self, fonte: &HFONT, cor: COLORREF, topo: i32, altura: i32, texto: &str, formato: DRAW_TEXT_FORMAT) {
        if texto.is_empty() {
            return;
        }
        let mut r = RECT {
            left: self.esquerda,
            top: escala(self.dpi, topo),
            right: self.esquerda + self.largura,
            bottom: escala(self.dpi, topo + altura),
        };
        let mut buffer: Vec<u16> = texto.encode_utf16().collect();
        unsafe {
            let anterior = SelectObject(self.hdc, (*fonte).into());
            SetTextColor(self.hdc, cor);
            DrawTextW(self.hdc, &mut buffer, &mut r, formato);
            SelectObject(self.hdc, anterior);
        }
    }
}

/// Texto num retângulo em pixels, com a fonte e a cor dadas.
fn desenhar_em(hdc: HDC, fonte: &HFONT, cor: COLORREF, r: &mut RECT, texto: &str, formato: DRAW_TEXT_FORMAT) {
    if texto.is_empty() {
        return;
    }
    let mut buffer: Vec<u16> = texto.encode_utf16().collect();
    unsafe {
        let anterior = SelectObject(hdc, (*fonte).into());
        SetTextColor(hdc, cor);
        DrawTextW(hdc, &mut buffer, r, formato);
        SelectObject(hdc, anterior);
    }
}

/// A hora local de uma cópia (`quando_ms`, relógio de parede em ms desde 1970): "14/09 18:32".
fn hora_local(quando_ms: u64) -> String {
    use windows::Win32::Foundation::{FILETIME, SYSTEMTIME};
    use windows::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};
    // O FILETIME conta intervalos de 100 ns desde 1601.
    let intervalos = (quando_ms + 11_644_473_600_000).saturating_mul(10_000);
    let ft = FILETIME { dwLowDateTime: intervalos as u32, dwHighDateTime: (intervalos >> 32) as u32 };
    let mut utc = SYSTEMTIME::default();
    let mut local = SYSTEMTIME::default();
    unsafe {
        if FileTimeToSystemTime(&ft, &mut utc).is_err() {
            return String::new();
        }
        if SystemTimeToTzSpecificLocalTime(None, &utc, &mut local).is_err() {
            local = utc;
        }
    }
    regras::hora_da_copia(local.wDay, local.wMonth, local.wHour, local.wMinute)
}

fn marcado(h: HWND) -> bool {
    unsafe { SendMessageW(h, BM_GETCHECK, None, None).0 as usize == BST_CHECKED }
}
