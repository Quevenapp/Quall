//! Janela de exibição: cria a janela Win32, a swap chain D3D11 e usa o Video Processor do D3D11
//! (`ID3D11VideoDevice`/`ID3D11VideoContext`) para converter a textura NV12 do decoder para RGB e
//! escalar preservando o aspecto (barras pretas quando a janela não tem o mesmo aspecto do
//! conteúdo) — tudo em hardware, no mesmo dispositivo D3D11 que decodificou.
//!
//! Por que Video Processor e não um shader de conversão de cor escrito à mão: é o mesmo
//! mecanismo que o media engine do próprio Windows usa para NV12→RGB com escala. Evita compilar
//! HLSL e montar um pipeline de render só para um blit, e acerta a matriz de conversão de cor
//! (BT.601/BT.709, faixa limitada/completa) sem eu ter de codificar isso à mão — o que importa
//! aqui porque o contrato do Quall já declarou faixa limitada (`docs/contrato-sidecar.md`) e uma
//! conversão manual errada é exatamente o tipo de defeito visual sutil que esse documento cita.
//!
//! **Mesmo adaptador do início ao fim.** O dispositivo D3D11 passado para [`Presenter::new`] tem
//! de ser o mesmo registrado no `IMFDXGIDeviceManager` do decoder (`decoder.rs`) — é a mesma
//! restrição que o encoder mediu para `MFT_MESSAGE_SET_D3D_MANAGER` (`E_INVALIDARG` num
//! adaptador que não bate), e é o que evita a cópia entre adaptadores que o M1 mediu custar 7,33
//! ms por quadro. Se o decoder ativar na NVIDIA (que não serve a tela deste Dell — ver
//! `docs/windows-acesso.md`), a swap chain criada neste mesmo dispositivo força o DXGI a copiar
//! para o adaptador que serve o monitor por baixo dos panos no `Present` — não medido isolado
//! aqui de propósito nenhum, é o preço que reaparece se o decoder escolher a NVIDIA. Ver
//! README.md para qual adaptador decodificou de fato nesta bancada.

use std::cell::Cell;
use std::mem::ManuallyDrop;
use std::time::Instant;

use windows::core::{w, Interface, Result, BOOL};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_RATIONAL, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::{MonitorFromWindow, MONITOR_DEFAULTTONEAREST, MONITOR_DEFAULTTOPRIMARY};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::geometria_da_exibicao as geo;

/// Uma janela Win32 simples: sem menu, sem toolbar, sem nada além do necessário para hospedar a
/// swap chain — "sem firula", como pedido no escopo.
pub struct Window {
    pub hwnd: HWND,
    /// O que está escrito na barra de título agora. Guardado para não reescrever o mesmo texto:
    /// `SetWindowTextW` repinta a barra e pisca o botão da barra de tarefas, e esta janela é
    /// atualizada uma vez por segundo.
    ultimo_titulo: String,
    /// **A prévia** (12/10): a tela cheia e o botão sobre o vídeo. O endereço vai no
    /// `GWLP_USERDATA` da janela, para o `wndproc` alcançá-lo; `None` na janela da sonda
    /// ([`Window::create`]), que não tem nada disso. A `Exibicao` destrói a janela antes de largar
    /// esta struct, então o `wndproc` nunca vê o endereço solto.
    previa: Option<Box<Previa>>,
}

/// O estado da prévia que o `wndproc` lê e escreve. Tudo em `Cell`: a janela, o `wndproc` e o
/// `pump` estão na mesma thread, e uma chamada do Windows pode entrar no `wndproc` de dentro de
/// outra (o `SetWindowPos` manda `WM_SIZE` na hora).
struct Previa {
    tela_cheia: Cell<geo::TelaCheia>,
    /// O estilo da janela antes da tela cheia (a moldura volta com ele).
    estilo_antes: Cell<isize>,
    /// O último movimento do mouse sobre o vídeo (`None`: saiu). Nasce com a janela, para o botão
    /// aparecer nos primeiros segundos.
    ultimo_movimento: Cell<Option<Instant>>,
    rastreando_a_saida: Cell<bool>,
    /// O botão da tela cheia: um `BUTTON` de verdade (o Narrador o lê, o Enter e o Espaço o
    /// apertam), numa janela própria por cima do vídeo — ver [`criar_o_botao`].
    botao: Cell<HWND>,
    /// A dica do mouse do botão (`tooltips_class32`); inválida se não nasceu.
    dica: Cell<HWND>,
    dica_posta: Cell<bool>,
    botao_a_vista: Cell<bool>,
    /// O rótulo escrito agora: tela cheia ou não, e a versão do idioma.
    rotulo: Cell<Option<(bool, u32)>>,
}


fn previa_de(hwnd: HWND) -> Option<&'static Previa> {
    let p = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *const Previa;
    // SAFETY: o endereço é de um `Box<Previa>` dono da `Window`, posto depois do
    // `CreateWindowExW` e tirado no `WM_NCDESTROY`; a `Window` só é largada depois do
    // `DestroyWindow` (`Exibicao::drop`).
    (!p.is_null()).then(|| unsafe { &*p })
}

/// **O sinal de "a pessoa fechou" sai do `WM_CLOSE`, e não do `WM_DESTROY`.**
///
/// `WM_CLOSE` só chega pelo X, pelo Alt+F4 ou pelo menu da janela — é a pessoa. `WM_DESTROY` chega
/// também quando **o próprio app** destrói a janela (`Drop` da `Exibicao`), e até 10/09/2026 era
/// dele que saía o `WM_QUIT`: um `WM_QUIT` é da thread inteira, e quando o receptor passou a largar
/// a exibição e abrir outra na mesma thread depois de uma queda da GPU, o `pump` da janela nova leu
/// o `WM_QUIT` da velha como "fechada pela pessoa" 70 ms depois de abrir. A janela não é destruída
/// aqui: quem a possui a destrói ao largar.
unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CLOSE => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        // **Per-Monitor V2 não redimensiona sozinho**: arrastada para um monitor de outra escala, a
        // janela recebe o retângulo sugerido e tem de aplicá-lo, senão fica com o tamanho físico do
        // monitor de antes. A swap chain acompanha no quadro seguinte (`Exibicao::bombear` lê o
        // cliente a cada quadro).
        WM_DPICHANGED => {
            // Em tela cheia a janela já é o monitor inteiro: o retângulo sugerido a reescalaria.
            if previa_de(hwnd).is_some_and(|p| p.tela_cheia.get().ligada()) {
                return LRESULT(0);
            }
            let r = unsafe { &*(lparam.0 as *const RECT) };
            let _ = unsafe {
                SetWindowPos(
                    hwnd,
                    None,
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                )
            };
            LRESULT(0)
        }
        _ => match previa_de(hwnd) {
            Some(p) => unsafe { wndproc_da_previa(hwnd, p, msg, wparam, lparam) },
            None => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
        },
    }
}

/// As mensagens da prévia: o mouse que mostra o botão, as teclas e o duplo clique da tela cheia, o
/// clique e o desenho do botão, e o botão que acompanha a janela.
unsafe fn wndproc_da_previa(hwnd: HWND, p: &Previa, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    use windows::Win32::UI::Controls::WM_MOUSELEAVE;
    use windows::Win32::UI::Input::KeyboardAndMouse::{TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT, VK_ESCAPE, VK_F11};
    match msg {
        WM_MOUSEMOVE => {
            p.ultimo_movimento.set(Some(Instant::now()));
            if !p.rastreando_a_saida.get() {
                let mut t = TRACKMOUSEEVENT {
                    cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                    dwFlags: TME_LEAVE,
                    hwndTrack: hwnd,
                    dwHoverTime: 0,
                };
                p.rastreando_a_saida.set(unsafe { TrackMouseEvent(&mut t) }.is_ok());
            }
            atualizar_o_botao(hwnd, p);
            LRESULT(0)
        }
        WM_MOUSELEAVE => {
            p.rastreando_a_saida.set(false);
            p.ultimo_movimento.set(None);
            atualizar_o_botao(hwnd, p);
            LRESULT(0)
        }
        WM_LBUTTONDBLCLK => {
            alternar(hwnd, p, geo::GestoDaTelaCheia::DuploClique);
            LRESULT(0)
        }
        WM_KEYDOWN if wparam.0 == VK_F11.0 as usize => {
            alternar(hwnd, p, geo::GestoDaTelaCheia::F11);
            LRESULT(0)
        }
        WM_KEYDOWN if wparam.0 == VK_ESCAPE.0 as usize => {
            alternar(hwnd, p, geo::GestoDaTelaCheia::Esc);
            LRESULT(0)
        }
        // O botão é reconhecido pelo `HWND` (o `lParam`), e não por id: uma janela `WS_POPUP` não
        // tem id de controle (ver [`criar_o_botao`]).
        WM_COMMAND
            if !p.botao.get().is_invalid()
                && lparam.0 == p.botao.get().0 as isize
                && ((wparam.0 >> 16) & 0xFFFF) as u32 == BN_CLICKED =>
        {
            alternar(hwnd, p, geo::GestoDaTelaCheia::Botao);
            // O clique deu o foco ao botão; as teclas (Esc, F11) são da janela do vídeo.
            let _ = unsafe { SetForegroundWindow(hwnd) };
            let _ = unsafe { windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(hwnd)) };
            LRESULT(0)
        }
        WM_NOTIFY => {
            use windows::Win32::UI::Controls::{CDDS_PREERASE, CDDS_PREPAINT, CDRF_SKIPDEFAULT, NMCUSTOMDRAW, NMHDR, NM_CUSTOMDRAW};
            let hdr = unsafe { &*(lparam.0 as *const NMHDR) };
            if hdr.code == NM_CUSTOMDRAW && hdr.hwndFrom == p.botao.get() {
                let cd = unsafe { &*(lparam.0 as *const NMCUSTOMDRAW) };
                if cd.dwDrawStage == CDDS_PREERASE || cd.dwDrawStage == CDDS_PREPAINT {
                    unsafe { desenhar_o_botao(cd, p.tela_cheia.get().ligada()) };
                    return LRESULT(CDRF_SKIPDEFAULT as isize);
                }
            }
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        WM_SIZE | WM_MOVE => {
            posicionar_o_botao(hwnd, p);
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        WM_NCDESTROY => {
            unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) };
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// **Entra ou sai da tela cheia.** Entrar: o estilo vira `WS_POPUP` (sem moldura) e a janela ocupa
/// o monitor inteiro em que está, por cima da barra de tarefas. Sair: o estilo e o retângulo de
/// antes voltam. A swap chain acompanha no quadro seguinte (`Exibicao::bombear` lê o cliente), e o
/// encaixe põe faixas pretas na proporção do vídeo.
fn alternar(hwnd: HWND, p: &Previa, gesto: geo::GestoDaTelaCheia) {
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITORINFO};
    unsafe {
        let mut agora = RECT::default();
        if GetWindowRect(hwnd, &mut agora).is_err() {
            return;
        }
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return;
        }
        let ret = |r: RECT| (r.left, r.top, r.right, r.bottom);
        let mut t = p.tela_cheia.get();
        let passo = t.gesto(gesto, ret(agora), ret(info.rcMonitor), ret(info.rcWork));
        p.tela_cheia.set(t);
        match passo {
            Some(geo::PassoDaTelaCheia::Entrar(r)) => {
                let estilo = GetWindowLongPtrW(hwnd, GWL_STYLE);
                p.estilo_antes.set(estilo);
                let sem_moldura = (estilo & !(WS_OVERLAPPEDWINDOW.0 as isize)) | WS_POPUP.0 as isize;
                SetWindowLongPtrW(hwnd, GWL_STYLE, sem_moldura);
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOP),
                    r.0,
                    r.1,
                    r.2 - r.0,
                    r.3 - r.1,
                    SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
                );
                crate::registro::linha(format!("janela de vídeo: tela cheia ({gesto:?}) em {}x{}", r.2 - r.0, r.3 - r.1));
            }
            Some(geo::PassoDaTelaCheia::Sair(r)) => {
                SetWindowLongPtrW(hwnd, GWL_STYLE, p.estilo_antes.get());
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    r.0,
                    r.1,
                    r.2 - r.0,
                    r.3 - r.1,
                    SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
                );
                crate::registro::linha(format!("janela de vídeo: fora da tela cheia ({gesto:?}), de volta a {}x{}", r.2 - r.0, r.3 - r.1));
            }
            None => {}
        }
        posicionar_o_botao(hwnd, p);
        rotular_o_botao(hwnd, p);
    }
}

/// O botão no canto de baixo à direita do cliente, em coordenadas de tela (ele é uma janela de
/// cima, não uma filha).
fn posicionar_o_botao(hwnd: HWND, p: &Previa) {
    let botao = p.botao.get();
    if botao.is_invalid() {
        return;
    }
    unsafe {
        let mut c = RECT::default();
        if GetClientRect(hwnd, &mut c).is_err() {
            return;
        }
        let dpi = windows::Win32::UI::HiDpi::GetDpiForWindow(hwnd).max(96);
        let b = geo::botao_no_cliente(((c.right - c.left).max(0) as u32, (c.bottom - c.top).max(0) as u32), dpi);
        let mut origem = windows::Win32::Foundation::POINT { x: b.0, y: b.1 };
        let _ = windows::Win32::Graphics::Gdi::ClientToScreen(hwnd, &mut origem);
        let _ = SetWindowPos(
            botao,
            None,
            origem.x,
            origem.y,
            b.2 - b.0,
            b.3 - b.1,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
}

/// Mostra ou esconde o botão pela regra ([`geo::botao_visivel`]). Nunca com a janela do vídeo
/// minimizada ou escondida.
fn atualizar_o_botao(hwnd: HWND, p: &Previa) {
    let botao = p.botao.get();
    if botao.is_invalid() {
        return;
    }
    unsafe {
        let mut cursor = windows::Win32::Foundation::POINT::default();
        let no_botao = GetCursorPos(&mut cursor).is_ok() && WindowFromPoint(cursor) == botao;
        let ms = p.ultimo_movimento.get().map(|t| t.elapsed().as_millis() as u64);
        let ver = geo::botao_visivel(ms, no_botao) && IsWindowVisible(hwnd).as_bool() && !IsIconic(hwnd).as_bool();
        if ver != p.botao_a_vista.get() {
            p.botao_a_vista.set(ver);
            if ver {
                posicionar_o_botao(hwnd, p);
            }
            let _ = ShowWindow(botao, if ver { SW_SHOWNOACTIVATE } else { SW_HIDE });
        }
    }
}

/// **O nome do botão** — o que o Narrador lê e a dica do mouse mostra —, no idioma de agora e no
/// estado de agora: "Tela cheia (F11)" ou "Sair da tela cheia (Esc)". Reescrito só quando muda.
fn rotular_o_botao(hwnd: HWND, p: &Previa) {
    let botao = p.botao.get();
    if botao.is_invalid() {
        return;
    }
    let ligada = p.tela_cheia.get().ligada();
    let agora = (ligada, crate::idioma::versao());
    if p.rotulo.get() == Some(agora) {
        return;
    }
    p.rotulo.set(Some(agora));
    let texto = rotulo_do_botao(ligada);
    let mut largo: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let _ = SetWindowTextW(botao, windows::core::PCWSTR(largo.as_ptr()));
        let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(botao), None, true);
    }
    let dica = p.dica.get();
    if !dica.is_invalid() {
        use windows::Win32::UI::Controls::{TTF_IDISHWND, TTF_SUBCLASS, TTM_ADDTOOLW, TTM_UPDATETIPTEXTW, TTTOOLINFOW};
        let info = TTTOOLINFOW {
            cbSize: std::mem::size_of::<TTTOOLINFOW>() as u32,
            uFlags: TTF_IDISHWND | TTF_SUBCLASS,
            hwnd,
            uId: botao.0 as usize,
            lpszText: windows::core::PWSTR(largo.as_mut_ptr()),
            ..Default::default()
        };
        let primeira = !p.dica_posta.get();
        unsafe {
            SendMessageW(
                dica,
                if primeira { TTM_ADDTOOLW } else { TTM_UPDATETIPTEXTW },
                None,
                Some(LPARAM(&info as *const TTTOOLINFOW as isize)),
            );
        }
        p.dica_posta.set(true);
    }
}

/// O texto do botão: o rótulo da tabela de idioma e a tecla que faz o mesmo.
pub fn rotulo_do_botao(em_tela_cheia: bool) -> String {
    use crate::idioma::t;
    if em_tela_cheia {
        format!("{} (Esc)", t("Sair da tela cheia"))
    } else {
        format!("{} (F11)", t("Tela cheia"))
    }
}

/// O botão desenhado à mão (o `NM_CUSTOMDRAW` do comctl v6, como os da janela principal — nunca
/// `BS_OWNERDRAW`, `docs/telas-estudio.md` §11.5): um quadrado escuro de cantos redondos, mais claro
/// sob o mouse, com o glifo da Segoe Fluent Icons (ou da MDL2, no Windows 10) — tela cheia ou
/// voltar à janela.
unsafe fn desenhar_o_botao(cd: &windows::Win32::UI::Controls::NMCUSTOMDRAW, ligada: bool) {
    use windows::Win32::Graphics::Gdi::*;
    use windows::Win32::UI::Controls::{CDIS_HOT, CDIS_SELECTED};
    let hdc = cd.hdc;
    let r = cd.rc;
    let quente = (cd.uItemState.0 & (CDIS_HOT.0 | CDIS_SELECTED.0)) != 0;
    let dpi = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(cd.hdr.hwndFrom) }.max(96) as i32;
    unsafe {
        // As cores são os tokens do tema (`geo::cores_do_botao`, testadas lá); até 13/10 eram cinzas
        // próprios (28/50/60/F0), fora do "Estúdio de bolso".
        let cores = geo::cores_do_botao(quente);
        let cor = |c: crate::estilo::Cor| windows::Win32::Foundation::COLORREF(c.colorref());
        // O fundo atrás dos cantos: preto, como as faixas do vídeo.
        let preto = CreateSolidBrush(cor(cores.atras));
        FillRect(hdc, &r, preto);
        let _ = DeleteObject(preto.into());
        let pincel = CreateSolidBrush(cor(cores.caixa));
        let caneta = CreatePen(PS_SOLID, (dpi / 96).max(1), cor(cores.borda));
        let velho_pincel = SelectObject(hdc, pincel.into());
        let velha_caneta = SelectObject(hdc, caneta.into());
        let canto = 8 * dpi / 96;
        let _ = RoundRect(hdc, r.left, r.top, r.right, r.bottom, canto, canto);
        SelectObject(hdc, velho_pincel);
        SelectObject(hdc, velha_caneta);
        let _ = DeleteObject(pincel.into());
        let _ = DeleteObject(caneta.into());

        let icone = if ligada { crate::estilo::Icone::SairDaTelaCheia } else { crate::estilo::Icone::TelaCheia };
        let mut glifo: Vec<u16> = icone.glifo().to_string().encode_utf16().collect();
        let mut fonte = HFONT::default();
        for nome in crate::estilo::nomes_da_familia(crate::estilo::Familia::Icones) {
            let largo: Vec<u16> = nome.encode_utf16().chain(std::iter::once(0)).collect();
            fonte = CreateFontW(
                -(16 * dpi / 96),
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY,
                0,
                windows::core::PCWSTR(largo.as_ptr()),
            );
            if !fonte.is_invalid() {
                break;
            }
        }
        let velha_fonte = SelectObject(hdc, fonte.into());
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, cor(cores.glifo));
        let mut caixa = r;
        DrawTextW(hdc, &mut glifo, &mut caixa, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(hdc, velha_fonte);
        let _ = DeleteObject(fonte.into());
    }
}

/// **O botão da tela cheia**: um `BUTTON` comum (o Narrador o lê pelo texto, que é o rótulo; o
/// Enter e o Espaço o apertam), numa janela **de cima, dona da janela do vídeo** (`WS_POPUP` com
/// dono), e não numa filha: a janela do vídeo é inteira da swap chain *flip*, e uma filha por cima
/// dela depende de como o DWM compõe as duas; uma janela própria é composta por cima, sempre, e
/// some junto quando a do vídeo minimiza. Sem foco ao aparecer (`WS_EX_NOACTIVATE`), fora da barra
/// de tarefas e do Alt+Tab (`WS_EX_TOOLWINDOW`). A dica do mouse vem do `tooltips_class32`.
unsafe fn criar_o_botao(hwnd: HWND, hinstance: windows::Win32::Foundation::HINSTANCE) -> (HWND, HWND) {
    use windows::Win32::UI::Controls::{InitCommonControlsEx, ICC_BAR_CLASSES, INITCOMMONCONTROLSEX, TOOLTIPS_CLASSW, TTS_ALWAYSTIP, TTS_NOPREFIX};
    unsafe {
        // **Sem `hMenu`** (13/10, o botão que não nascia no Dell): numa janela que não é
        // `WS_CHILD` o `hMenu` é um menu de verdade, e não o id do controle; o id 1 ia como handle
        // de menu e o `CreateWindowExW` recusava (`ERROR_INVALID_MENU_HANDLE`, 1401). Sem id, o
        // `WM_COMMAND` e o `NM_CUSTOMDRAW` são reconhecidos pelo `HWND` do botão.
        let botao = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("BUTTON"),
            windows::core::PCWSTR::null(),
            WINDOW_STYLE(WS_POPUP.0 | BS_PUSHBUTTON as u32),
            0,
            0,
            36,
            36,
            Some(hwnd),
            None,
            Some(hinstance),
            None,
        ) {
            Ok(b) => b,
            Err(e) => {
                // O `windows` monta o erro com o `GetLastError` da chamada: o código vai ao diário.
                crate::registro::linha(format!(
                    "janela de vídeo: !! o botão da tela cheia não nasceu (GetLastError {} = {:#010x}: {}) — F11, Esc e o duplo clique continuam",
                    e.code().0 & 0xFFFF,
                    e.code().0 as u32,
                    e.message()
                ));
                HWND::default()
            }
        };
        let icc = INITCOMMONCONTROLSEX { dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_BAR_CLASSES };
        let _ = InitCommonControlsEx(&icc);
        let dica = if botao.is_invalid() {
            HWND::default()
        } else {
            CreateWindowExW(
                WS_EX_TOPMOST,
                TOOLTIPS_CLASSW,
                windows::core::PCWSTR::null(),
                WINDOW_STYLE(WS_POPUP.0 | TTS_ALWAYSTIP | TTS_NOPREFIX),
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                Some(hwnd),
                None,
                Some(hinstance),
                None,
            )
            .unwrap_or_default()
        };
        if !dica.is_invalid() {
            // A dica do mouse no escuro, como a lista da janela principal (o tema claro do
            // `tooltips_class32` era a única coisa branca sobre o vídeo).
            let _ = windows::Win32::UI::Controls::SetWindowTheme(dica, w!("DarkMode_Explorer"), windows::core::PCWSTR::null());
        }
        if !botao.is_invalid() {
            crate::registro::linha(format!(
                "janela de vídeo: o botão da tela cheia nasceu (dica do mouse {})",
                if dica.is_invalid() { "não nasceu" } else { "ok" }
            ));
        }
        (botao, dica)
    }
}

impl Window {
    /// Cria e mostra a janela, com o cliente do tamanho pedido (não a janela inteira — a borda e
    /// a barra de título do Windows são descontadas via `AdjustWindowRect`, senão o vídeo fica
    /// menor que a resolução declarada e ninguém percebe por quê).
    pub fn create(title: &str, client_width: u32, client_height: u32) -> Result<Self> {
        unsafe {
            let hinstance = GetModuleHandleW(None)?;
            let class_name = registrar_a_classe(hinstance.into());

            let mut rect = RECT { left: 0, top: 0, right: client_width as i32, bottom: client_height as i32 };
            let style = WS_OVERLAPPEDWINDOW;
            let _ = AdjustWindowRect(&mut rect, style, false);

            let mut title_wide: Vec<u16> = title.encode_utf16().chain(std::iter::once(0)).collect();
            let title_pcwstr = windows::core::PCWSTR(title_wide.as_mut_ptr());

            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                class_name,
                title_pcwstr,
                style,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                rect.right - rect.left,
                rect.bottom - rect.top,
                None,
                None,
                Some(hinstance.into()),
                None,
            )?;

            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);

            Ok(Window { hwnd, ultimo_titulo: title.to_string(), previa: None })
        }
    }

    /// **Cria a prévia do vídeo** (o pedido do Bruno de 12/10: "a janela do Windows precisa ser um
    /// preview apenas, uma janela pequena com botão fullscreen"). O cliente sai de
    /// [`geo::cliente_da_previa`] — o lado maior em 30 % da área útil, entre 360 e 640 DIP, na
    /// proporção do vídeo — e a janela fica no canto de baixo à direita da área útil
    /// ([`geo::canto_da_previa`]); os porquês dos números estão lá.
    ///
    /// **O monitor é o da janela da frente** — a do Quall onde a pessoa clicou em Exibir —, e não o
    /// de `CW_USEDEFAULT`, que é o principal. E a janela **nasce** no lugar e no tamanho finais:
    /// criada num monitor e movida para outro de escala diferente, ela receberia um
    /// `WM_DPICHANGED` que reescalaria o tamanho já calculado.
    pub fn create_previa(title: &str, video: (u32, u32), escala: f64) -> Result<Self> {
        unsafe {
            let hinstance = GetModuleHandleW(None)?;
            let class_name = registrar_a_classe(hinstance.into());

            let monitor = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTOPRIMARY);
            let (area, dpi) = area_util_e_dpi(monitor, None);
            let moldura = moldura_no_dpi(dpi);
            let cliente = geo::cliente_da_previa(video, escala, area, moldura, dpi);
            let r = geo::janela_ancorada(cliente, moldura, area, geo::canto_da_previa(area, dpi));

            let mut title_wide: Vec<u16> = title.encode_utf16().chain(std::iter::once(0)).collect();
            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                class_name,
                windows::core::PCWSTR(title_wide.as_mut_ptr()),
                ESTILO,
                r.0,
                r.1,
                r.2 - r.0,
                r.3 - r.1,
                None,
                None,
                Some(hinstance.into()),
                None,
            )?;
            // **A moldura do resto do app** (13/10, o relato "a janela de preview está clara"): a
            // barra de título escura na cor da legenda do tema e o ícone do Quall, antes do
            // `ShowWindow` — a janela nasce sem `WS_VISIBLE` e nunca aparece clara. Era a única
            // janela independente do produto sem ela.
            crate::decoracao::aplicar(hwnd);
            crate::registro::linha(format!(
                "janela de vídeo: prévia da imagem {}x{} -> cliente {}x{} na área útil {}x{} ({},{}) a {} dpi",
                video.0,
                video.1,
                cliente.0,
                cliente.1,
                area.2 - area.0,
                area.3 - area.1,
                area.0,
                area.1,
                dpi
            ));

            let previa = Box::new(Previa {
                tela_cheia: Cell::new(geo::TelaCheia::default()),
                estilo_antes: Cell::new(ESTILO.0 as isize),
                // O botão aparece nos primeiros segundos, para ser descoberto.
                ultimo_movimento: Cell::new(Some(Instant::now())),
                rastreando_a_saida: Cell::new(false),
                botao: Cell::new(HWND::default()),
                dica: Cell::new(HWND::default()),
                dica_posta: Cell::new(false),
                botao_a_vista: Cell::new(false),
                rotulo: Cell::new(None),
            });
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, &*previa as *const Previa as isize);
            let (botao, dica) = criar_o_botao(hwnd, hinstance.into());
            previa.botao.set(botao);
            previa.dica.set(dica);
            rotular_o_botao(hwnd, &previa);

            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
            atualizar_o_botao(hwnd, &previa);
            Ok(Window { hwnd, ultimo_titulo: title.to_string(), previa: Some(previa) })
        }
    }

    /// **O celular girou** e o fluxo passou de em pé a deitado (ou o contrário): a janela fica com
    /// o mesmo lado maior — a prévia continua pequena, a janela aumentada continua grande — na
    /// proporção nova ([`geo::cliente_girado`]), com o canto de baixo à direita onde estava. Em tela
    /// cheia nada se move agora; quem muda é o retângulo da volta. Maximizada pela pessoa, fica
    /// como está (a imagem ganha faixas).
    pub fn girar(&self, video: (u32, u32)) {
        unsafe {
            if IsZoomed(self.hwnd).as_bool() {
                return;
            }
            let monitor = MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST);
            let (area, dpi) = area_util_e_dpi(monitor, Some(self.hwnd));
            let moldura = moldura_no_dpi(dpi);
            let tela_cheia = self.previa.as_ref().map(|p| p.tela_cheia.get()).filter(|t| t.ligada());
            let (janela, cliente_agora) = match tela_cheia.and_then(|t| t.retorno()) {
                Some(volta) => {
                    let (w, h) = geo::tamanho(volta);
                    (volta, ((w as i32 - moldura.largura()).max(1) as u32, (h as i32 - moldura.altura()).max(1) as u32))
                }
                None => {
                    let mut agora = RECT::default();
                    if GetWindowRect(self.hwnd, &mut agora).is_err() {
                        return;
                    }
                    ((agora.left, agora.top, agora.right, agora.bottom), self.tamanho_do_cliente())
                }
            };
            let cliente = geo::cliente_girado(cliente_agora, video, area, moldura);
            let r = geo::janela_ancorada(cliente, moldura, area, (janela.2, janela.3));
            match (tela_cheia, self.previa.as_ref()) {
                (Some(mut t), Some(p)) => {
                    t.trocar_retorno(r);
                    p.tela_cheia.set(t);
                }
                _ => {
                    let _ = SetWindowPos(self.hwnd, None, r.0, r.1, r.2 - r.0, r.3 - r.1, SWP_NOZORDER | SWP_NOACTIVATE);
                }
            }
            crate::registro::linha(format!(
                "janela de vídeo: o vídeo girou para {}x{} -> cliente {}x{}{} a {} dpi",
                video.0,
                video.1,
                cliente.0,
                cliente.1,
                if tela_cheia.is_some() { " (na volta da tela cheia)" } else { "" },
                dpi
            ));
        }
    }

    /// O tamanho do cliente agora, em pixels físicos. `(0, 0)` minimizada.
    pub fn tamanho_do_cliente(&self) -> (u32, u32) {
        let mut r = RECT::default();
        if unsafe { GetClientRect(self.hwnd, &mut r) }.is_err() {
            return (0, 0);
        }
        ((r.right - r.left).max(0) as u32, (r.bottom - r.top).max(0) as u32)
    }

    /// **Reescreve a barra de título — que nesta casca é a única superfície que a janela do vídeo
    /// tem para dizer alguma coisa.**
    ///
    /// Não é enfeite. `docs/contrato-track.md` exige que os cinco contadores da cadeia de
    /// referência cheguem à **tela**, e esta casca cumpria a letra e não o espírito: o painel com
    /// eles vive na janela principal, e a janela principal **não é a que tem a imagem**. Numa
    /// corrida de 01/09/2026 o usuário fotografou o rastro do quadro quebrado dentro desta janela
    /// aqui, com a janela do painel fora da tela — os números existiam, mediam certo, e não
    /// estavam onde os olhos estavam. É a mesma queixa de 31/08 mudando de casca.
    ///
    /// Aqui não há compositor de sobreposição: a janela hospeda a swap chain e mais nada, e
    /// desenhar por cima do vídeo pediria um segundo passe de render só para isso. A barra de
    /// título é o que existe, custa uma chamada por segundo, e é lida sem tirar os olhos da imagem.
    pub fn titular(&mut self, texto: &str) {
        if self.ultimo_titulo == texto {
            return;
        }
        let mut largo: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
        // Falhar aqui não é motivo para nada: é a barra de título de uma janela de vídeo, e o
        // diário continua tendo os mesmos números.
        let _ = unsafe { SetWindowTextW(self.hwnd, windows::core::PCWSTR(largo.as_mut_ptr())) };
        self.ultimo_titulo = texto.to_string();
    }

    /// Escoa a fila de mensagens sem bloquear. Devolve `false` quando a janela pediu para
    /// fechar (`WM_QUIT`) — é o sinal para o laço principal parar.
    pub fn pump(&self) -> bool {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return false;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        // O botão some 2,5 s depois do último movimento sem mensagem nenhuma chegar: quem o esconde
        // é esta volta, que o laço da sessão dá o tempo todo. E o rótulo acompanha a troca de idioma.
        if let Some(p) = self.previa.as_deref() {
            atualizar_o_botao(self.hwnd, p);
            rotular_o_botao(self.hwnd, p);
        }
        true
    }
}

/// O estilo da janela de vídeo, o mesmo em `create` e no cálculo da moldura.
const ESTILO: WINDOW_STYLE = WS_OVERLAPPEDWINDOW;

/// Registra a classe da janela de vídeo (uma vez por processo; a segunda chamada falha com
/// `ERROR_CLASS_ALREADY_EXISTS` e não importa). `CS_DBLCLKS`: sem ele o duplo clique da tela cheia
/// nunca chega.
unsafe fn registrar_a_classe(hinstance: windows::Win32::Foundation::HINSTANCE) -> windows::core::PCWSTR {
    let class_name = w!("QuallReceiverWindow");
    let wc = WNDCLASSW {
        style: CS_DBLCLKS,
        lpfnWndProc: Some(wndproc),
        hInstance: hinstance,
        lpszClassName: class_name,
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }.unwrap_or_default(),
        // **O preto do vídeo antes do primeiro quadro** (13/10): sem pincel e sem `WM_PAINT`, o
        // cliente ficava com o que o DWM tivesse (claro, no relato do Dell) até a swap chain
        // apresentar, e de novo a cada redimensionar maior que o buffer. O pincel do estoque é o
        // `PRETO_DO_VIDEO` (0x000000), o mesmo das faixas; o `DefWindowProcW` o pinta no
        // `WM_ERASEBKGND`. Com a swap chain *flip* apresentando, o DWM compõe o buffer dela e não
        // este fundo — ele não pisca por cima da imagem.
        hbrBackground: windows::Win32::Graphics::Gdi::HBRUSH(unsafe {
            windows::Win32::Graphics::Gdi::GetStockObject(windows::Win32::Graphics::Gdi::BLACK_BRUSH)
        }.0),
        ..Default::default()
    };
    let _ = unsafe { RegisterClassW(&wc) };
    class_name
}

/// A área útil (`rcWork`, sem a barra de tarefas) e o DPI efetivo de um monitor. Sem resposta do
/// Windows, a área do monitor principal pela métrica do sistema e 96 dpi — a janela nasce, e o
/// diário diz o que foi usado.
unsafe fn area_util_e_dpi(
    monitor: windows::Win32::Graphics::Gdi::HMONITOR,
    janela: Option<HWND>,
) -> (crate::geometria_da_exibicao::Retangulo, u32) {
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITORINFO};
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI};
    let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    let area = if unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
        let w = info.rcWork;
        (w.left, w.top, w.right, w.bottom)
    } else {
        (0, 0, unsafe { GetSystemMetrics(SM_CXSCREEN) }.max(640), unsafe { GetSystemMetrics(SM_CYSCREEN) }.max(480))
    };
    let (mut x, mut y) = (0u32, 0u32);
    let dpi = if unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut x, &mut y) }.is_ok() && x > 0 {
        x
    } else {
        janela.map(|h| unsafe { GetDpiForWindow(h) }).unwrap_or(0).max(96)
    };
    (area, dpi)
}

/// A moldura de [`ESTILO`] no `dpi` dado: o que `AdjustWindowRectExForDpi` soma a um cliente vazio.
unsafe fn moldura_no_dpi(dpi: u32) -> crate::geometria_da_exibicao::Moldura {
    let mut r = RECT::default();
    if unsafe { windows::Win32::UI::HiDpi::AdjustWindowRectExForDpi(&mut r, ESTILO, false, WINDOW_EX_STYLE(0), dpi) }
        .is_err()
    {
        let _ = unsafe { AdjustWindowRect(&mut r, ESTILO, false) };
    }
    crate::geometria_da_exibicao::Moldura::do_ajuste((r.left, r.top, r.right, r.bottom))
}

/// Recorte, dentro de uma área de saída `target_w`×`target_h`, que preserva o aspecto de um
/// conteúdo `content_w`×`content_h` — barras pretas (letterbox/pillarbox) preenchem o resto.
/// Nesta sonda a janela nasce do tamanho exato do conteúdo (ver `main`), então o caso comum é
/// `content` == `target` e isto devolve o retângulo cheio; a função existe para o caso de a
/// janela ser redimensionada, e para não fingir que "aspecto preservado" só vale por acidente.
/// A conta mora em [`geo::destino_na_proporcao`], onde os testes a alcançam.
pub fn aspect_fit(content_w: u32, content_h: u32, target_w: u32, target_h: u32) -> RECT {
    let (left, top, right, bottom) = geo::destino_na_proporcao((content_w, content_h), (target_w, target_h));
    RECT { left, top, right, bottom }
}

/// Uma falha do caminho da apresentação, com a etapa no texto. O `0x80070057` do controle de
/// 21/09 saía só como "Parâmetro incorreto", sem dizer se foi a vista de entrada ou o `Blt`.
fn na_etapa(etapa: &str) -> impl Fn(windows::core::Error) -> windows::core::Error + '_ {
    move |e| windows::core::Error::new(e.code(), format!("{etapa}: {}", e.message()))
}

/// Swap chain + Video Processor D3D11: converte e apresenta um quadro NV12 por vez.
pub struct Presenter {
    device: ID3D11Device,
    swapchain: IDXGISwapChain1,
    context: ID3D11DeviceContext,
    video_context: ID3D11VideoContext,
    video_device: ID3D11VideoDevice,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
    /// A entrada para a qual o **processador** foi montado (o enumerador pede o tamanho). Até
    /// 21/09 era também a origem de todo quadro, e é isso que o G1 consertou: a origem é pedida por
    /// quadro (`present_frame`).
    input_width: u32,
    input_height: u32,
    output_width: u32,
    output_height: u32,
    fps: u32,
}

impl Presenter {
    /// O dispositivo D3D11 desta apresentação.
    ///
    /// Existe porque a câmera virtual precisa converter **a mesma textura** que vai para a janela,
    /// e o `ID3D11VideoProcessor` dela tem de nascer no mesmo dispositivo — a armadilha do
    /// `IMFDXGIDeviceManager` do M1 vale aqui igual: dois dispositivos, e o `CreateVideoProcessor
    /// InputView` recusa a textura com `E_INVALIDARG` sem dizer por quê.
    pub fn device(&self) -> &ID3D11Device {
        &self.device
    }
    pub fn new(
        device: &ID3D11Device,
        hwnd: HWND,
        input_width: u32,
        input_height: u32,
        output_width: u32,
        output_height: u32,
        fps: u32,
        buffers: u32,
    ) -> Result<Self> {
        let context = unsafe { device.GetImmediateContext()? };

        let dxgi_device: IDXGIDevice = device.cast()?;
        let adapter = unsafe { dxgi_device.GetAdapter()? };
        let factory: IDXGIFactory2 = unsafe { adapter.GetParent()? };

        let desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: output_width,
            Height: output_height,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            // **Dois é o mínimo do modelo *flip*, e pode ser o teto do laço inteiro.** Com um
            // buffer na tela (o DWM o segura até o retraço seguinte) e outro na fila, o
            // `VideoProcessorBlt` do quadro seguinte não tem onde escrever e a GPU espera o vsync
            // — e tudo o que vem atrás dele no contexto imediato espera junto, inclusive a cópia
            // da câmera virtual. Apontado pela revisão adversarial de 10/09/2026 como suspeito do
            // teto de 39 a 51 fps; o número vem de quem chama para o A/B ser no mesmo binário.
            BufferCount: buffers.clamp(2, 4),
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            ..Default::default()
        };
        let swapchain = unsafe { factory.CreateSwapChainForHwnd(device, hwnd, &desc, None, None)? };

        let video_device: ID3D11VideoDevice = device.cast()?;
        let video_context: ID3D11VideoContext = context.cast()?;

        let (enumerator, processor) =
            Self::processador(&video_device, input_width, input_height, output_width, output_height, fps)?;

        Ok(Self {
            device: device.clone(),
            swapchain,
            context,
            video_context,
            video_device,
            enumerator,
            processor,
            input_width,
            input_height,
            output_width,
            output_height,
            fps,
        })
    }

    fn processador(
        video_device: &ID3D11VideoDevice,
        input_width: u32,
        input_height: u32,
        output_width: u32,
        output_height: u32,
        fps: u32,
    ) -> Result<(ID3D11VideoProcessorEnumerator, ID3D11VideoProcessor)> {
        let content_desc = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
            InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            InputFrameRate: DXGI_RATIONAL { Numerator: fps.max(1), Denominator: 1 },
            InputWidth: input_width,
            InputHeight: input_height,
            OutputFrameRate: DXGI_RATIONAL { Numerator: fps.max(1), Denominator: 1 },
            OutputWidth: output_width,
            OutputHeight: output_height,
            Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
        };
        let enumerator = unsafe { video_device.CreateVideoProcessorEnumerator(&content_desc) }
            .map_err(na_etapa("CreateVideoProcessorEnumerator"))?; // i18n: fora (detalhe técnico)
        let processor = unsafe { video_device.CreateVideoProcessor(&enumerator, 0) }
            .map_err(na_etapa("CreateVideoProcessor"))?; // i18n: fora (detalhe técnico)
        Ok((enumerator, processor))
    }

    /// **A textura do decoder mudou de tamanho no meio da sessão** (o G1 de 21/09): o enumerador e
    /// o processador são refeitos para a entrada nova. A janela e a swap chain ficam: a imagem nova
    /// entra encaixada na janela de sempre. Custa um enumerador e um processador, uma vez por troca.
    pub fn ajustar_entrada(&mut self, input_width: u32, input_height: u32) -> Result<()> {
        if (input_width, input_height) == (self.input_width, self.input_height) {
            return Ok(());
        }
        let (enumerator, processor) = Self::processador(
            &self.video_device,
            input_width,
            input_height,
            self.output_width,
            self.output_height,
            self.fps,
        )?;
        self.enumerator = enumerator;
        self.processor = processor;
        self.input_width = input_width;
        self.input_height = input_height;
        Ok(())
    }

    /// **A janela mudou de tamanho** (a pessoa arrastou a borda, o `WM_DPICHANGED` de outro
    /// monitor, o reencaixe depois de um giro): os buffers da swap chain e o processador passam ao
    /// cliente novo. Até 12/10 a swap chain ficava no tamanho da abertura e o DXGI esticava o
    /// buffer na janela, sem respeitar a proporção. Nenhuma referência ao buffer de trás sobrevive
    /// a [`Self::present_frame`], então o `ResizeBuffers` não encontra nada preso.
    pub fn redimensionar_saida(&mut self, output_width: u32, output_height: u32) -> Result<()> {
        if (output_width, output_height) == (self.output_width, self.output_height) || output_width == 0 || output_height == 0 {
            return Ok(());
        }
        unsafe {
            self.swapchain.ResizeBuffers(
                0,
                output_width,
                output_height,
                windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_UNKNOWN,
                DXGI_SWAP_CHAIN_FLAG(0),
            )
        }
        .map_err(na_etapa("ResizeBuffers"))?; // i18n: fora (detalhe técnico)
        self.output_width = output_width;
        self.output_height = output_height;
        let (enumerator, processor) = Self::processador(
            &self.video_device,
            self.input_width,
            self.input_height,
            output_width,
            output_height,
            self.fps,
        )?;
        self.enumerator = enumerator;
        self.processor = processor;
        Ok(())
    }

    /// Converte (NV12→RGB) e apresenta um quadro decodificado: o retângulo `origem` da textura,
    /// dentro de `dest_rect` (o retângulo de [`aspect_fit`]). Limpa o backbuffer antes: fora de
    /// `dest_rect` fica preto, as barras do letterbox/pillarbox.
    ///
    /// **A origem vem de quem chama, quadro a quadro** (o G1 de 21/09): é a abertura visível do
    /// tipo de saída de agora, recortada à textura (`geometria_da_exibicao::origem_na_textura`).
    /// Fixa no primeiro SPS, ela passava da textura quando o fluxo descia de 854 para 640, e o
    /// `present_frame` falhava com `0x80070057` em todo quadro.
    pub fn present_frame(
        &self,
        texture: &ID3D11Texture2D,
        subresource_index: u32,
        origem: RECT,
        dest_rect: RECT,
        snapshot: Option<&std::path::Path>,
    ) -> Result<()> {
        let backbuffer: ID3D11Texture2D =
            unsafe { self.swapchain.GetBuffer(0) }.map_err(na_etapa("GetBuffer"))?; // i18n: fora (detalhe técnico)

        // `CreateRenderTargetView` é método do *dispositivo*, não do contexto — o contexto só
        // consome a view já criada (`ClearRenderTargetView`). Erro do primeiro `cargo check`
        // nesta bancada: cheguei a escrever `self.context.CreateRenderTargetView`, que nem
        // existe (o compilador sugeriu `ClearRenderTargetView` por semelhança de nome).
        let mut rtv: Option<ID3D11RenderTargetView> = None;
        unsafe { self.device.CreateRenderTargetView(&backbuffer, None, Some(&mut rtv)) }
            .map_err(na_etapa("CreateRenderTargetView"))?; // i18n: fora (detalhe técnico)
        let rtv = rtv.ok_or_else(|| {
            windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "CreateRenderTargetView não devolveu view") // i18n: fora (detalhe técnico)
        })?;
        let preto = geo::cor_do_d3d(geo::PRETO_DO_VIDEO);
        unsafe { self.context.ClearRenderTargetView(&rtv, &preto) };

        let input_view_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
            FourCC: 0,
            ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 {
                Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: subresource_index },
            },
        };
        // `CreateVideoProcessorInputView`/`CreateVideoProcessorOutputView` também não ganharam o
        // invólucro `Result<T>` nesta versão do `windows-rs` (mesmo padrão do
        // `IMFDXGIBuffer::GetResource` em `decoder.rs`) — o último parâmetro é o ponteiro de
        // saída, explícito.
        let mut input_view: Option<ID3D11VideoProcessorInputView> = None;
        unsafe {
            self.video_device.CreateVideoProcessorInputView(
                texture,
                &self.enumerator,
                &input_view_desc,
                Some(&mut input_view),
            )
        }
        .map_err(na_etapa("CreateVideoProcessorInputView"))?; // i18n: fora (detalhe técnico)
        let input_view = input_view.ok_or_else(|| {
            windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "CreateVideoProcessorInputView não devolveu view") // i18n: fora (detalhe técnico)
        })?;

        let output_view_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
            ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 {
                Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 },
            },
        };
        let mut output_view: Option<ID3D11VideoProcessorOutputView> = None;
        unsafe {
            self.video_device.CreateVideoProcessorOutputView(
                &backbuffer,
                &self.enumerator,
                &output_view_desc,
                Some(&mut output_view),
            )
        }
        .map_err(na_etapa("CreateVideoProcessorOutputView"))?; // i18n: fora (detalhe técnico)
        let output_view = output_view.ok_or_else(|| {
            windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "CreateVideoProcessorOutputView não devolveu view") // i18n: fora (detalhe técnico)
        })?;

        let full_output = RECT { left: 0, top: 0, right: self.output_width as i32, bottom: self.output_height as i32 };

        unsafe {
            self.video_context.VideoProcessorSetOutputTargetRect(&self.processor, true, Some(&full_output));
            self.video_context.VideoProcessorSetStreamSourceRect(&self.processor, 0, true, Some(&origem));
            self.video_context.VideoProcessorSetStreamDestRect(&self.processor, 0, true, Some(&dest_rect));
            self.video_context.VideoProcessorSetStreamOutputRate(
                &self.processor,
                0,
                D3D11_VIDEO_PROCESSOR_OUTPUT_RATE_NORMAL,
                false,
                None,
            );
        }

        let stream = D3D11_VIDEO_PROCESSOR_STREAM {
            Enable: BOOL::from(true),
            OutputIndex: 0,
            InputFrameOrField: 0,
            PastFrames: 0,
            FutureFrames: 0,
            ppPastSurfaces: std::ptr::null_mut(),
            // **Cópia sem `AddRef`**, e não `clone()`: o campo é `ManuallyDrop` e nunca solta o
            // que recebe. Com `clone()` cada quadro vazava uma referência à vista — e a vista
            // segura a textura do decoder —, 60 por segundo, até 10/09/2026. `input_view` é solta
            // no fim desta função, e a cópia aqui não conta.
            pInputSurface: unsafe { std::mem::transmute_copy(&input_view) },
            ppFutureSurfaces: std::ptr::null_mut(),
            ppPastSurfacesRight: std::ptr::null_mut(),
            pInputSurfaceRight: ManuallyDrop::new(None),
            ppFutureSurfacesRight: std::ptr::null_mut(),
        };

        unsafe { self.video_context.VideoProcessorBlt(&self.processor, &output_view, 0, &[stream]) }
            .map_err(na_etapa("VideoProcessorBlt"))?; // i18n: fora (detalhe técnico)

        // Prova visual, se pedida: lê o **mesmo objeto** `backbuffer` que acabamos de escrever,
        // *antes* do `Present`. Achado desta bancada, não escondido: a primeira versão disto
        // chamava `GetBuffer(0)` de novo, numa função separada, depois do `Present` — e o
        // resultado ora saía preto (a troca de buffers do modo *flip* faz `GetBuffer(0)` devolver
        // o buffer que ainda **não** foi desenhado nesta rodada, não o que acabou de ir pra tela),
        // ora saía com conteúdo de outra janela do desktop (uma composição do DWM capturada por
        // acidente, não o vídeo). Seguro só existe reaproveitando a referência que este método já
        // tem, escrita por ele mesmo, sem outra chamada a `GetBuffer` no meio.
        if let Some(path) = snapshot {
            if let Err(e) = self.copy_texture_to_bmp(&backbuffer, path) {
                eprintln!("aviso: não salvou o snapshot em {}: {e}", path.display());
            }
        }

        // `Present(0, ...)`: sem espera de vsync — este número mede o custo do próprio pipeline
        // (decode + blt + apresentar o backbuffer), não quanto falta para o próximo retraço. O
        // tempo até o fóton de fato sair da tela inclui até um intervalo de quadro a mais que
        // isto não captura — dito no README.md, não escondido atrás de "medi a latência".
        unsafe { self.swapchain.Present(0, DXGI_PRESENT(0)) }.ok().map_err(na_etapa("Present"))?; // i18n: fora (detalhe técnico)
        Ok(())
    }

    /// Copia o backbuffer (o que acabou de ir pro `Present`) pra um `.bmp` em disco — prova do
    /// pixel de verdade, sem depender de captura de tela do Windows.
    ///
    /// Existiu porque a captura de tela por GDI (`CopyFromScreen`/`BitBlt`, o jeito óbvio de
    /// "printar a tela" por script) devolveu a **mesma imagem, byte a byte, em quatro tentativas
    /// separadas** nesta bancada — sinal de que o DWM não está recompondo quadro novo nenhum
    /// nesta sessão (sessão "Interativa" via Tarefa Agendada, sem ninguém de fato olhando o
    /// monitor físico ou conectado por RDP; o compositor aparenta ficar parado num quadro
    /// congelado quando não há consumidor). Não investiguei a causa raiz a fundo — só medi que
    /// `SetForegroundWindow`/`SetWindowPos(HWND_TOPMOST)` devolveram sucesso (a janela real
    /// mudou de lugar na ordem Z) e mesmo assim a "foto" continuou idêntica, o que aponta pra
    /// captura de tela, não pra apresentação, como a parte quebrada. Ler o backbuffer direto da
    /// GPU contorna o problema inteiro: é o mesmo dado que o `VideoProcessorBlt` acabou de
    /// escrever, half a dependência de o Windows "fotografar a tela" certo.
    fn copy_texture_to_bmp(&self, texture: &ID3D11Texture2D, path: &std::path::Path) -> Result<()> {
        unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            texture.GetDesc(&mut desc);

            let staging_desc = D3D11_TEXTURE2D_DESC {
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
                ..desc
            };
            let mut staging: Option<ID3D11Texture2D> = None;
            self.device.CreateTexture2D(&staging_desc, None, Some(&mut staging))?;
            let staging = staging.ok_or_else(|| {
                windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "CreateTexture2D (staging) não devolveu textura") // i18n: fora (detalhe técnico)
            })?;

            self.context.CopyResource(&staging, texture);

            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;

            let width = desc.Width;
            let height = desc.Height;
            let row_pitch = mapped.RowPitch as usize;
            let total = row_pitch * height as usize;
            let src = std::slice::from_raw_parts(mapped.pData as *const u8, total);

            let resultado = write_bmp_top_down_bgra(path, width, height, src, row_pitch);

            self.context.Unmap(&staging, 0);

            resultado.map_err(|e| {
                windows::core::Error::new(windows::Win32::Foundation::E_FAIL, format!("gravar .bmp: {e}"))
            })?;
        }
        Ok(())
    }
}

/// Escreve um `.bmp` de 24 bpp (sem canal alfa — a janela não usa transparência) a partir de um
/// buffer BGRA de origem (o formato do backbuffer, `DXGI_FORMAT_B8G8R8A8_UNORM`), respeitando o
/// `RowPitch` de origem (que quase sempre é maior que `width * 4` por alinhamento de GPU) e
/// escrevendo de cima para baixo (`biHeight` negativo — variante padrão de BMP "top-down", assim
/// as linhas não precisam ser invertidas na cópia).
fn write_bmp_top_down_bgra(
    path: &std::path::Path,
    width: u32,
    height: u32,
    src: &[u8],
    src_row_pitch: usize,
) -> std::io::Result<()> {
    use std::io::Write;

    let dst_row_size = ((width * 3 + 3) / 4) * 4;
    let pixel_data_size = dst_row_size * height;
    let file_size = 14 + 40 + pixel_data_size;

    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);

    // BITMAPFILEHEADER (14 bytes)
    f.write_all(b"BM")?;
    f.write_all(&file_size.to_le_bytes())?;
    f.write_all(&0u16.to_le_bytes())?;
    f.write_all(&0u16.to_le_bytes())?;
    f.write_all(&54u32.to_le_bytes())?;

    // BITMAPINFOHEADER (40 bytes)
    f.write_all(&40u32.to_le_bytes())?;
    f.write_all(&(width as i32).to_le_bytes())?;
    f.write_all(&(-(height as i64) as i32).to_le_bytes())?; // negativo: top-down
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&24u16.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?; // BI_RGB
    f.write_all(&pixel_data_size.to_le_bytes())?;
    f.write_all(&0i32.to_le_bytes())?;
    f.write_all(&0i32.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;

    let mut row_buf = vec![0u8; dst_row_size as usize];
    for y in 0..height as usize {
        let src_row = &src[y * src_row_pitch..y * src_row_pitch + (width as usize * 4)];
        for x in 0..width as usize {
            let px = &src_row[x * 4..x * 4 + 4];
            row_buf[x * 3] = px[0]; // B
            row_buf[x * 3 + 1] = px[1]; // G
            row_buf[x * 3 + 2] = px[2]; // R
        }
        for b in row_buf[(width as usize * 3)..].iter_mut() {
            *b = 0;
        }
        f.write_all(&row_buf)?;
    }
    f.flush()
}
