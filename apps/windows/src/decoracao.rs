//! Moldura comum das janelas do produto, inclusive teleprompter e controle flutuante.
//! Windows 11/22000 é o piso: usamos apenas os atributos DWM públicos desse sistema.

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_CAPTION_COLOR, DWMWA_TEXT_COLOR, DWMWA_USE_IMMERSIVE_DARK_MODE};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::WindowsAndMessaging::*;

// Ícones privados de tamanhos diferentes não usam LR_SHARED. Conservamos um par por DPI
// e instância até o processo terminar: as classes/janelas podem referenciar os mesmos handles.
static ICONES: OnceLock<Mutex<BTreeMap<(usize, u32), (isize, isize)>>> = OnceLock::new();

pub(crate) fn icones(instancia: HINSTANCE, dpi: u32) -> windows::core::Result<(HICON, HICON)> {
    let mut cache = ICONES.get_or_init(|| Mutex::new(BTreeMap::new())).lock().unwrap_or_else(|e| e.into_inner());
    let chave = (instancia.0 as usize, dpi.max(96));
    if let Some(&(grande, pequeno)) = cache.get(&chave) {
        return Ok((HICON(grande as _), HICON(pequeno as _)));
    }
    unsafe {
        let carregar = |x, y| LoadImageW(Some(instancia), PCWSTR(1usize as *const u16), IMAGE_ICON,
            GetSystemMetricsForDpi(x, chave.1), GetSystemMetricsForDpi(y, chave.1), LR_DEFAULTCOLOR);
        let grande = carregar(SM_CXICON, SM_CYICON)?;
        let pequeno = match carregar(SM_CXSMICON, SM_CYSMICON) {
            Ok(h) => h,
            Err(e) => { let _ = DestroyIcon(HICON(grande.0)); return Err(e); }
        };
        cache.insert(chave, (grande.0 as isize, pequeno.0 as isize));
        Ok((HICON(grande.0), HICON(pequeno.0)))
    }
}

pub(crate) fn aplicar(hwnd: HWND) {
    if let Err(e) = unsafe { GetModuleHandleW(None) }.and_then(|m| aplicar_com_instancia(hwnd, m.into())) {
        crate::registro::linha(format!("janela: !! não foi possível aplicar moldura/ícone (código={})", e.code().0));
    }
}

fn aplicar_com_instancia(hwnd: HWND, instancia: HINSTANCE) -> windows::core::Result<()> {
    let (grande, pequeno) = icones(instancia, unsafe { GetDpiForWindow(hwnd) }.max(96))?;
    unsafe {
        SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(grande.0 as isize)));
        SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(pequeno.0 as isize)));
        let sim: i32 = 1;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &sim as *const _ as _, 4)?;
        // A cor explícita mantém a moldura coerente com o app mesmo quando o sistema usa tema claro.
        let legenda = crate::estilo::BARRA.colorref();
        let tinta = crate::estilo::TEXTO.colorref();
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &legenda as *const _ as _, 4)?;
        DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &tinta as *const _ as _, 4)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::core::w;
    use windows::Win32::System::LibraryLoader::{LoadLibraryExW, LOAD_LIBRARY_AS_DATAFILE};

    unsafe extern "system" fn procedimento(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> windows::Win32::Foundation::LRESULT {
        unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
    }

    #[test]
    fn moldura_nativa_usa_icone_do_app_e_cores_escuras() {
        // Prova opt-in: só janelas ocultas próprias; nenhum app/câmera/registro é iniciado.
        let Some(caminho) = std::env::var_os("QUALL_TESTE_ICONE_EXE") else { return; };
        let largo: Vec<u16> = caminho.to_string_lossy().encode_utf16().chain(Some(0)).collect();
        unsafe {
            let modulo = LoadLibraryExW(PCWSTR(largo.as_ptr()), None, LOAD_LIBRARY_AS_DATAFILE).unwrap();
            let instancia: HINSTANCE = modulo.into();
            let classe = w!("QuallMolduraTestePrivado");
            let wc = WNDCLASSW { lpfnWndProc: Some(procedimento), hInstance: GetModuleHandleW(None).unwrap().into(), lpszClassName: classe, ..Default::default() };
            assert_ne!(RegisterClassW(&wc), 0);
            for estilo in [WINDOW_EX_STYLE(0), WS_EX_TOOLWINDOW, WS_EX_APPWINDOW] {
                let hwnd = CreateWindowExW(estilo, classe, w!("Quall — prova de moldura"), WS_OVERLAPPEDWINDOW,
                    0, 0, 320, 240, None, None, Some(wc.hInstance), None).unwrap();
                aplicar_com_instancia(hwnd, instancia).unwrap();
                let (grande, pequeno) = icones(instancia, GetDpiForWindow(hwnd).max(96)).unwrap();
                assert_eq!(SendMessageW(hwnd, WM_GETICON, Some(WPARAM(ICON_BIG as usize)), None).0, grande.0 as isize);
                assert_eq!(SendMessageW(hwnd, WM_GETICON, Some(WPARAM(ICON_SMALL as usize)), None).0, pequeno.0 as isize);
                // Os três atributos usados pelo helper têm contrato público de Set, não Get.
                // O Result acima só retorna Ok se o DWM aceitar os três setters. A prova visual
                // da moldura pintada continua sendo a execução interativa do app corrigido.
                aplicar_com_instancia(hwnd, instancia).unwrap();
                DestroyWindow(hwnd).unwrap();
            }
            // A instância só sai ao terminar o processo, junto com seu cache de ícones.
        }
    }
}
