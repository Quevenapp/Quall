//! **O Quall instala a câmera virtual** (decisão do Bruno, 12/10/2026, tarde;
//! `docs/camera-virtual.md`, "A câmera virtual como o driver"). As regras puras estão em
//! `regras_da_instalacao_da_camera.rs`; aqui fica o Win32, no molde de `driver_da_tela_estendida.rs`:
//!
//! - [`elevado`]: o que roda **como administrador**, num processo à parte — o próprio
//!   `quall-app.exe` relançado pelo UAC com `--camera-virtual <verbo> --cano <nome>` (ou
//!   `desinstalar --sem-cano`, pelo desinstalador do MSI), ou o `quall-camera.exe` inteiro, que já
//!   abre elevado. A DLL vem de **dentro do exe** ([`DLL_EMBUTIDA`]), e nada do disco do usuário,
//!   das variáveis de ambiente do perfil ou do HKCU entra nas decisões dele;
//! - [`ler_situacao`]: o que a janela lê para o cartão dos Ajustes, sem elevação, só leitura. É uma
//!   chave do registro e um atributo de arquivo: barato o bastante para a janela reler a cada 2 s,
//!   que é o que faz o cartão e as câmeras mudarem **com o Quall aberto** depois de instalar pelo
//!   avulso (o defeito do SudoVDA de 02/10, "a detecção não percebe o driver ao vivo": a câmera não
//!   tem `WM_DEVICECHANGE` que avise, então a janela pergunta);
//! - [`perguntar`] e [`comecar`]: a caixa que explica antes, e o lançamento elevado com o andamento
//!   lido pelo cano.
//!
//! # O que a instalação faz, e o que não faz
//!
//! Escreve `quall_camera_fonte.dll` em `%ProgramFiles%\Quall` e as três chaves do registro COM em
//! `HKLM\SOFTWARE\Classes\CLSID\{5C75FE52-…}` — os mesmos valores do MSI de agosto e do
//! `DllRegisterServer` (o teste `os_valores_sao_os_da_fonte`). Cria `%ProgramData%\Quall`, o diário
//! da fonte, se ele não existir. **Não** cria câmera nenhuma: quem cria é o app, por sessão
//! (`fio_das_cameras.rs`), e não há nó de sistema para sobrar.
//!
//! **A DLL presa.** O Frame Server carrega a fonte e não a solta (`DllCanUnloadNow` é sempre
//! `S_FALSE`, de propósito). Um arquivo carregado não se apaga, mas se **renomeia** no NTFS: a
//! remoção e a reinstalação renomeiam o arquivo preso para `…dll.velha-<hex>` e pedem ao Windows que
//! o apague no próximo reinício (`MOVEFILE_DELAY_UNTIL_REBOOT`). Nenhum serviço é parado: parar o
//! Frame Server derrubaria a câmera de quem estiver numa chamada, com qualquer câmera.
//!
//! # A pasta e o registro são de administrador
//!
//! `%ProgramFiles%` (pelo `SHGetKnownFolderPath`, nunca pela variável de ambiente) só aceita escrita
//! de administrador: o que o Frame Server (`LocalService`) carrega não pode ser trocado por um
//! usuário comum. A pasta `Quall` é a do MSI; se já existe, tem de ser pasta e não ponto de
//! reanálise. A remoção apaga **só** o caminho nosso, nunca o que se leu do registro.

use std::ffi::c_void;
#[cfg(not(feature = "msix"))]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, Ordering};
#[cfg(not(feature = "msix"))]
use std::sync::Arc;
use std::sync::Mutex;
#[cfg(not(feature = "msix"))]
use std::time::{Duration, Instant};

use windows::core::{HSTRING, PCWSTR};
#[cfg(not(feature = "msix"))]
use windows::core::PWSTR;
use windows::Win32::Foundation::{ERROR_MORE_DATA, ERROR_SUCCESS, HWND};
#[cfg(not(feature = "msix"))]
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_CANCELLED, ERROR_FILE_NOT_FOUND,
    ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, HANDLE, HLOCAL, WIN32_ERROR,
};
#[cfg(not(feature = "msix"))]
use windows::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
#[cfg(not(feature = "msix"))]
use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows::Win32::Storage::FileSystem::{GetFileAttributesW, FILE_ATTRIBUTE_DIRECTORY, INVALID_FILE_ATTRIBUTES};
#[cfg(not(feature = "msix"))]
use windows::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, DeleteFileW, MoveFileExW, ReadFile, RemoveDirectoryW, WriteFile,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAGS_AND_ATTRIBUTES,
    FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_NONE, FILE_SHARE_READ,
    MOVEFILE_DELAY_UNTIL_REBOOT, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, OPEN_EXISTING, PIPE_ACCESS_INBOUND,
    SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
#[cfg(not(feature = "msix"))]
use windows::Win32::System::Pipes::{ConnectNamedPipe, CreateNamedPipeW, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT};
use windows::Win32::System::Registry::{
    RegCloseKey, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_LOCAL_MACHINE,
    KEY_READ, KEY_WOW64_64KEY, RRF_RT_REG_SZ,
};
#[cfg(not(feature = "msix"))]
use windows::Win32::System::Registry::{RegCreateKeyExW, RegDeleteTreeW, RegSetValueExW, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ};
use windows::Win32::System::Threading::{GetCurrentProcess, IsWow64Process2};
#[cfg(not(feature = "msix"))]
use windows::Win32::System::Threading::{CreateMutexW, GetExitCodeProcess, WaitForSingleObject, INFINITE};
#[cfg(not(feature = "msix"))]
use windows::Win32::UI::Shell::{
    IsUserAnAdmin, SHGetKnownFolderPath, ShellExecuteExW, FOLDERID_ProgramData, FOLDERID_ProgramFiles, KF_FLAG_DEFAULT,
    SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
};
#[cfg(not(feature = "msix"))]
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

use crate::registro;
use crate::regras_da_instalacao_da_camera::{self as regras, Acao, Andamento, Leitura, Registro, Resultado, Situacao};
#[cfg(not(feature = "msix"))]
use crate::regras_da_instalacao_da_camera::Linha;

// =============================================================================================
// A DLL embutida
// =============================================================================================

/// **A fonte da câmera, dentro do exe.** O `build.rs` decide se ela vem (`cfg(fonte_embutida)`):
/// sem ela, a instalação para no passo 1 com "a fonte da câmera não veio dentro deste Quall".
#[cfg(fonte_embutida)]
pub const DLL_EMBUTIDA: &[u8] = include_bytes!(env!("QUALL_CAMERA_FONTE_DLL_EMBUTIDA"));
#[cfg(not(fonte_embutida))]
pub const DLL_EMBUTIDA: &[u8] = &[];

/// O mutex de uma instalação por vez, na máquina inteira (o botão e o avulso juntos, duas sessões).
#[cfg(not(feature = "msix"))]
const MUTEX: &str = r"Global\QuallCameraVirtualInstalador";

#[cfg(not(feature = "msix"))]
fn largo(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn de_largo(b: &[u16]) -> String {
    let fim = b.iter().position(|c| *c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..fim])
}

#[cfg(not(feature = "msix"))]
fn ultimo_erro() -> String {
    let e = unsafe { GetLastError() };
    format!("0x{:08X}", e.0)
}

#[cfg(not(feature = "msix"))]
fn hr(e: &windows::core::Error) -> String {
    format!("0x{:08X}", e.code().0 as u32)
}

#[cfg(not(feature = "msix"))]
fn w32(r: WIN32_ERROR) -> String {
    format!("0x{:08X}", r.0)
}

// =============================================================================================
// A leitura (sem elevação)
// =============================================================================================

/// **Este processo veio de um pacote MSIX?** Lido uma vez: a identidade não muda com o processo de
/// pé. Declarado à mão: a feature do crate `windows` que traz `GetCurrentPackageFullName`
/// (`Win32_Storage_Packaging_Appx`) só entra com `tela-estendida-futura`. A assinatura é a do
/// `appmodel.h`, e `kernel32` a exporta desde o Windows 8.
pub fn tem_pacote() -> bool {
    static CACHE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *CACHE.get_or_init(|| {
        #[link(name = "kernel32")]
        extern "system" {
            fn GetCurrentPackageFullName(comprimento: *mut u32, nome: *mut u16) -> u32;
        }
        let mut comprimento = 0u32;
        let codigo = unsafe { GetCurrentPackageFullName(&mut comprimento, std::ptr::null_mut()) };
        regras::tem_pacote_pelo_codigo(codigo)
    })
}

/// A arquitetura nativa é x64? Num ARM64 o Quall x64 roda emulado, mas o Frame Server é nativo e não
/// carrega a DLL x64.
pub fn x64_nativo() -> bool {
    use windows::Win32::System::SystemInformation::{IMAGE_FILE_MACHINE, IMAGE_FILE_MACHINE_AMD64};
    let mut processo = IMAGE_FILE_MACHINE::default();
    let mut nativa = IMAGE_FILE_MACHINE::default();
    match unsafe { IsWow64Process2(GetCurrentProcess(), &mut processo, Some(&mut nativa)) } {
        Ok(()) => nativa == IMAGE_FILE_MACHINE_AMD64,
        // Sem a função (Windows 10 antigo): só existe x64 e x86 ali, e o exe é x64.
        Err(_) => true,
    }
}

fn atributos(caminho: &str) -> Option<u32> {
    let a = unsafe { GetFileAttributesW(&HSTRING::from(caminho)) };
    (a != INVALID_FILE_ATTRIBUTES).then_some(a)
}

/// O arquivo existe e não é pasta?
fn arquivo_existe(caminho: &str) -> bool {
    atributos(caminho).is_some_and(|a| a & FILE_ATTRIBUTE_DIRECTORY.0 == 0)
}

/// O texto padrão de uma chave de `HKLM` (vista de 64 bits), ou `None`.
fn ler_padrao(subchave: &str) -> Option<String> {
    let mut h = HKEY::default();
    let r = unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, &HSTRING::from(subchave), None, KEY_READ | KEY_WOW64_64KEY, &mut h) };
    if r != ERROR_SUCCESS {
        return None;
    }
    // O padrão `(buf, cap)`: cresce com `ERROR_MORE_DATA` até o teto de caminho longo.
    let mut buf = vec![0u16; 512];
    let texto = loop {
        let mut n = (buf.len() * 2) as u32;
        let r = unsafe { RegGetValueW(h, PCWSTR::null(), PCWSTR::null(), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut c_void), Some(&mut n)) };
        if r == ERROR_SUCCESS {
            break Some(de_largo(&buf));
        }
        if r == ERROR_MORE_DATA && buf.len() < 32_768 {
            buf.resize(buf.len() * 2, 0);
            continue;
        }
        break None;
    };
    unsafe {
        let _ = RegCloseKey(h);
    }
    texto
}

/// **O registro COM da fonte**, como está agora.
pub fn ler_registro() -> Registro {
    match ler_padrao(regras::CHAVE_DO_SERVIDOR) {
        Some(c) if !c.trim().is_empty() => {
            let existe = arquivo_existe(c.trim().trim_matches('"'));
            Registro::Presente { caminho: c, existe }
        }
        _ => Registro::Ausente,
    }
}

/// **A situação de agora** (o pacote, a arquitetura, o registro). Barata: a janela a relê a cada 2 s.
pub fn ler_situacao() -> Situacao {
    regras::situacao(&Leitura { pacote: cfg!(feature = "msix") || tem_pacote(), x64: x64_nativo(), registro: ler_registro() })
}

/// A situação para o **instalador avulso**: um exe à parte, nunca "da loja", mesmo com o Quall da
/// loja instalado e aberto ao lado.
pub fn ler_situacao_do_instalador() -> Situacao {
    regras::situacao(&Leitura { pacote: false, x64: x64_nativo(), registro: ler_registro() })
}

/// Uma pasta conhecida do Windows (`Program Files`, `ProgramData`), pelo shell e não pela variável
/// de ambiente (que o perfil do usuário define).
#[cfg(not(feature = "msix"))]
fn pasta_conhecida(id: &windows::core::GUID) -> Result<String, String> {
    let p = unsafe { SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) }.map_err(|e| format!("SHGetKnownFolderPath: {}", hr(&e)))?;
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { windows::Win32::System::Com::CoTaskMemFree(Some(p.0 as *const c_void)) };
    if s.is_empty() {
        return Err("SHGetKnownFolderPath: vazio".into());
    }
    Ok(s)
}

// =============================================================================================
// O processo elevado
// =============================================================================================

#[cfg(not(feature = "msix"))]
pub mod elevado {
    use super::*;

    /// O cano para a janela (ou, no avulso, o andamento e o diário do próprio processo). Escrever
    /// nunca derruba a instalação: se a janela fechou, o processo segue até o fim sozinho.
    pub(super) struct Cano(Option<HANDLE>, Option<Acao>);

    impl Cano {
        fn local(acao: Acao) -> Cano {
            Cano(None, Some(acao))
        }

        fn abrir(nome: Option<&str>) -> Cano {
            let Some(nome) = nome else { return Cano(None, None) };
            let n = HSTRING::from(nome);
            let ate = Instant::now() + Duration::from_secs(5);
            loop {
                // Só escrita, e o servidor só pode **identificar** quem conectou, nunca agir como ele.
                let r = unsafe {
                    CreateFileW(
                        &n,
                        FILE_GENERIC_WRITE.0,
                        FILE_SHARE_NONE,
                        None,
                        OPEN_EXISTING,
                        FILE_FLAGS_AND_ATTRIBUTES(SECURITY_SQOS_PRESENT.0 | SECURITY_IDENTIFICATION.0),
                        None,
                    )
                };
                match r {
                    Ok(h) => return Cano(Some(h), None),
                    Err(e) if Instant::now() < ate && (e.code() == ERROR_PIPE_BUSY.to_hresult() || e.code() == ERROR_FILE_NOT_FOUND.to_hresult()) => {
                        std::thread::sleep(Duration::from_millis(100));
                    }
                    Err(_) => return Cano(None, None),
                }
            }
        }

        pub(super) fn mandar(&mut self, l: Linha) {
            if let Some(acao) = self.1 {
                match l {
                    Linha::Passo(k) => {
                        anotar_local(format!("camera: passo {k}: {}", regras::nome_do_passo(acao, k).unwrap_or("?")));
                        mudar(Andamento::Rodando { acao, passo: k });
                    }
                    Linha::Diario(s) => anotar_local(s),
                    _ => {}
                }
                return;
            }
            let Some(h) = self.0 else { return };
            let s = l.escrever();
            if unsafe { WriteFile(h, Some(s.as_bytes()), None, None) }.is_err() {
                unsafe {
                    let _ = CloseHandle(h);
                }
                self.0 = None;
            }
        }

        pub(super) fn diario(&mut self, s: impl Into<String>) {
            self.mandar(Linha::Diario(s.into()));
        }
    }

    impl Drop for Cano {
        fn drop(&mut self) {
            if let Some(h) = self.0.take() {
                unsafe {
                    let _ = CloseHandle(h);
                }
            }
        }
    }

    /// Uma falha: o passo, a chave do motivo e o técnico.
    pub(super) struct Falha(pub usize, pub &'static str, pub String);

    /// O mutex, tomado **uma vez** por processo e guardado até o fim (o avulso instala e remove no
    /// mesmo processo). `false`: outro processo o tem agora — e só o sucesso fica guardado: o avulso
    /// aberto enquanto o botão do Quall instalava pode tentar de novo depois, sem ser fechado (o
    /// `quall-driver.exe` guarda a recusa também, e precisa ser reaberto).
    fn tomar_o_mutex() -> bool {
        static TOMADO: AtomicBool = AtomicBool::new(false);
        if TOMADO.load(Ordering::SeqCst) {
            return true;
        }
        let m = unsafe { CreateMutexW(None, true, &HSTRING::from(MUTEX)) };
        let ocupado = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        match m {
            // O handle fica aberto até o processo sair: é ele que segura o mutex.
            Ok(_) if !ocupado => {
                TOMADO.store(true, Ordering::SeqCst);
                true
            }
            Ok(h) => {
                unsafe {
                    let _ = CloseHandle(h);
                }
                false
            }
            Err(_) => false,
        }
    }

    /// **O instalador avulso** (`quall-camera.exe`, já elevado pelo manifesto): instala ou remove
    /// **neste processo**, com o mesmo código do processo elevado do app. Bloqueia: chame numa
    /// thread ([`comecar_aqui`](super::comecar_aqui)).
    pub fn rodar_aqui(acao: Acao) -> Resultado {
        let mut cano = Cano::local(acao);
        if !unsafe { IsUserAnAdmin() }.as_bool() {
            return Resultado::Falha(0, regras::MOTIVO_SEM_ADMIN.into(), "IsUserAnAdmin".into());
        }
        if !tomar_o_mutex() {
            return Resultado::Falha(0, regras::MOTIVO_OUTRA.into(), String::new());
        }
        anotar_local(format!("camera: instalador avulso, {} (fonte embutida: {} B)", acao.verbo(), DLL_EMBUTIDA.len()));
        let r = match acao {
            Acao::Instalar => instalar(&mut cano),
            Acao::Desinstalar => desinstalar(&mut cano, false),
        };
        match r {
            Ok(true) => Resultado::OkReiniciar,
            Ok(false) => Resultado::Ok,
            Err(Falha(n, chave, tecnico)) => {
                anotar_local(format!("camera: !! parou no passo {n}: {chave} ({tecnico})"));
                Resultado::Falha(n, chave.into(), tecnico)
            }
        }
    }

    /// **A entrada do processo elevado** do app. Chamada pelo `main` antes de qualquer outra coisa,
    /// quando os argumentos começam com `--camera-virtual`. Devolve o código de saída.
    pub fn rodar(args: &[String]) -> u32 {
        // Nenhuma DLL da pasta do exe carrega daqui para a frente; só as do System32.
        unsafe {
            let _ = windows::Win32::System::LibraryLoader::SetDefaultDllDirectories(
                windows::Win32::System::LibraryLoader::LOAD_LIBRARY_SEARCH_SYSTEM32,
            );
        }
        let pedido = match regras::ler_pedido(args) {
            Some(Ok(p)) => p,
            _ => return regras::saida::RECUSADO,
        };
        let mut cano = Cano::abrir(pedido.cano.as_deref());
        // O Quall da loja não instala por dentro (o MSIX não eleva; um processo com pacote que
        // chegasse aqui elevado seria um jeito de contornar isso, e não se aceita).
        if tem_pacote() {
            cano.mandar(Linha::Falha(0, regras::MOTIVO_PACOTE.into(), "GetCurrentPackageFullName".into()));
            return regras::saida::RECUSADO;
        }
        if !unsafe { IsUserAnAdmin() }.as_bool() {
            cano.mandar(Linha::Falha(0, regras::MOTIVO_SEM_ADMIN.into(), "IsUserAnAdmin".into()));
            return regras::saida::SEM_ADMIN;
        }
        if !tomar_o_mutex() {
            cano.mandar(Linha::Falha(0, regras::MOTIVO_OUTRA.into(), String::new()));
            return regras::saida::FALHA;
        }
        cano.diario(format!(
            "camera: processo elevado, {} ({}; fonte embutida: {} B)",
            pedido.acao.verbo(),
            if pedido.cano.is_some() { "pela janela" } else { "pelo MSI" },
            DLL_EMBUTIDA.len()
        ));
        let r = match pedido.acao {
            Acao::Instalar => instalar(&mut cano),
            Acao::Desinstalar => desinstalar(&mut cano, pedido.cano.is_none()),
        };
        match r {
            Ok(reiniciar) => {
                cano.mandar(if reiniciar { Linha::OkReiniciar } else { Linha::Ok });
                if reiniciar {
                    regras::saida::OK_REINICIAR
                } else {
                    regras::saida::OK
                }
            }
            Err(Falha(n, chave, tecnico)) => {
                cano.diario(format!("camera: !! parou no passo {n}: {chave} ({tecnico})"));
                cano.mandar(Linha::Falha(n, chave.into(), tecnico));
                regras::saida::FALHA
            }
        }
    }

    fn aleatorio_hex() -> String {
        let mut b = [0u8; 8];
        let _ = super::aleatorio(&mut b);
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    /// A pasta `%ProgramFiles%\Quall`: criada se não existe (herda a ACL de `Program Files`, só
    /// administradores escrevem); se existe, tem de ser pasta de verdade, não ponto de reanálise.
    fn garantir_pasta(pasta: &str) -> Result<(), String> {
        match atributos(pasta) {
            None => unsafe { CreateDirectoryW(&HSTRING::from(pasta), None) }.map_err(|e| format!("CreateDirectoryW: {}", hr(&e))),
            Some(a) if a & FILE_ATTRIBUTE_DIRECTORY.0 == 0 => Err(format!("{pasta} existe e não é pasta")), // i18n: fora (diário)
            Some(a) if a & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 => Err(format!("{pasta} é um ponto de reanálise")), // i18n: fora (diário)
            Some(_) => Ok(()),
        }
    }

    /// O diário da fonte (`fonte/src/diario.rs`, `C:\ProgramData\Quall`): a DLL escreve de três
    /// contas (o Frame Server como `LocalService`, o monitor dele como `SYSTEM`, o app que consome
    /// como o usuário). Criada só se não existe, com a DACL dessas três e dos administradores; a
    /// que existe (o MSI de agosto, a bancada) fica como está. Falhar aqui não para a instalação: a
    /// câmera funciona sem diário.
    fn garantir_o_diario(cano: &mut Cano) {
        let Ok(base) = pasta_conhecida(&FOLDERID_ProgramData) else { return };
        let pasta = format!(r"{base}\Quall");
        if atributos(&pasta).is_some() {
            return;
        }
        let mut sd = PSECURITY_DESCRIPTOR::default();
        // Modificar (0x1301bf) para os usuários autenticados; total para SYSTEM, administradores e
        // LocalService. Herdado por arquivos e subpastas.
        let sddl = "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;LS)(A;OICI;0x1301bf;;;AU)";
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(sddl), 1, &mut sd, None) }.is_err() {
            return;
        }
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd.0, bInheritHandle: false.into() };
        let r = unsafe { CreateDirectoryW(&HSTRING::from(pasta.as_str()), Some(&sa)) };
        unsafe {
            let _ = LocalFree(Some(HLOCAL(sd.0)));
        }
        cano.diario(format!("camera: pasta do diário da fonte {pasta}: {}", if r.is_ok() { "criada".to_string() } else { ultimo_erro() }));
    }

    pub(super) fn ler_arquivo(caminho: &str, maximo: usize) -> Result<Vec<u8>, String> {
        let h = unsafe { CreateFileW(&HSTRING::from(caminho), FILE_GENERIC_READ.0, FILE_SHARE_READ, None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None) }
            .map_err(|e| format!("CreateFileW {caminho}: {}", hr(&e)))?;
        let mut v = vec![0u8; maximo];
        let mut total = 0usize;
        loop {
            let mut n = 0u32;
            let r = unsafe { ReadFile(h, Some(&mut v[total..]), Some(&mut n), None) };
            if r.is_err() || n == 0 {
                break;
            }
            total += n as usize;
            if total >= v.len() {
                break;
            }
        }
        unsafe {
            let _ = CloseHandle(h);
        }
        v.truncate(total);
        Ok(v)
    }

    /// **Tira um arquivo do caminho**: apaga; se ele está preso (carregado pelo Frame Server),
    /// renomeia para `…velha-<hex>` e pede ao Windows que o apague no próximo reinício. `Ok(true)`
    /// quando ficou para o reinício.
    fn tirar_do_caminho(caminho: &str, cano: &mut Cano) -> Result<bool, String> {
        if atributos(caminho).is_none() {
            return Ok(false);
        }
        if unsafe { DeleteFileW(&HSTRING::from(caminho)) }.is_ok() {
            return Ok(false);
        }
        let apagar = ultimo_erro();
        let velha = format!("{caminho}.velha-{}", aleatorio_hex());
        unsafe { MoveFileExW(&HSTRING::from(caminho), &HSTRING::from(velha.as_str()), MOVEFILE_WRITE_THROUGH) }
            .map_err(|e| format!("DeleteFileW {apagar}; MoveFileExW: {}", hr(&e)))?;
        let adiada = unsafe { MoveFileExW(&HSTRING::from(velha.as_str()), PCWSTR::null(), MOVEFILE_DELAY_UNTIL_REBOOT) };
        cano.diario(format!(
            "camera: {caminho} estava em uso (DeleteFileW {apagar}); renomeada para {velha}, {}",
            match adiada {
                Ok(()) => "que sai no próximo reinício".to_string(),
                Err(e) => format!("e o apagar no reinício falhou ({})", hr(&e)),
            }
        ));
        Ok(true)
    }

    fn escrever_valor(subchave: &str, nome: Option<&str>, valor: &str) -> Result<(), String> {
        let mut h = HKEY::default();
        let r = unsafe {
            RegCreateKeyExW(
                HKEY_LOCAL_MACHINE,
                &HSTRING::from(subchave),
                None,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_READ | KEY_WRITE | KEY_WOW64_64KEY,
                None,
                &mut h,
                None,
            )
        };
        if r != ERROR_SUCCESS {
            return Err(format!("RegCreateKeyExW {subchave}: {}", w32(r)));
        }
        let w = largo(valor);
        let bytes = unsafe { std::slice::from_raw_parts(w.as_ptr() as *const u8, w.len() * 2) };
        let nome_w = nome.map(largo);
        let pnome = nome_w.as_ref().map_or(PCWSTR::null(), |n| PCWSTR(n.as_ptr()));
        let r = unsafe { RegSetValueExW(h, pnome, None, REG_SZ, Some(bytes)) };
        unsafe {
            let _ = RegCloseKey(h);
        }
        if r != ERROR_SUCCESS {
            return Err(format!("RegSetValueExW {subchave}: {}", w32(r)));
        }
        Ok(())
    }

    fn apagar_o_registro() -> Result<(), String> {
        let r = unsafe { RegDeleteTreeW(HKEY_LOCAL_MACHINE, &HSTRING::from(regras::CHAVE_DO_CLSID)) };
        if r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(format!("RegDeleteTreeW: {}", w32(r)))
        }
    }

    /// **Instala.** `Ok(false)`: pronto. Nunca pede reinício: a versão antiga presa no Frame Server
    /// (uma reinstalação) segue servindo até ele reiniciar, e o diário diz.
    fn instalar(cano: &mut Cano) -> Result<bool, Falha> {
        // 1. A fonte embutida e a plataforma.
        cano.mandar(Linha::Passo(1));
        regras::conferir_a_dll(DLL_EMBUTIDA).map_err(|m| Falha(1, m, format!("{} B", DLL_EMBUTIDA.len())))?;
        if !x64_nativo() {
            return Err(Falha(1, regras::MOTIVO_PLATAFORMA, "IsWow64Process2".into()));
        }
        cano.diario(format!("camera: fonte embutida conferida ({} B, PE x64 de DLL)", DLL_EMBUTIDA.len()));

        // 2. A cópia: um arquivo novo ao lado, conferido byte a byte, e só então no lugar.
        cano.mandar(Linha::Passo(2));
        let pf = pasta_conhecida(&FOLDERID_ProgramFiles).map_err(|e| Falha(2, regras::MOTIVO_PASTA, e))?;
        let pasta = format!(r"{}\{}", pf.trim_end_matches('\\'), regras::PASTA);
        garantir_pasta(&pasta).map_err(|e| Falha(2, regras::MOTIVO_PASTA, e))?;
        let destino = regras::caminho_da_dll(&pf);
        let nova = format!("{destino}.nova-{}", aleatorio_hex());
        let h = unsafe { CreateFileW(&HSTRING::from(nova.as_str()), FILE_GENERIC_WRITE.0, FILE_SHARE_NONE, None, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, None) }
            .map_err(|e| Falha(2, regras::MOTIVO_COPIA, format!("CreateFileW: {}", hr(&e))))?;
        let r = unsafe { WriteFile(h, Some(DLL_EMBUTIDA), None, None) };
        unsafe {
            let _ = CloseHandle(h);
        }
        let apagar_a_nova = || unsafe {
            let _ = DeleteFileW(&HSTRING::from(nova.as_str()));
        };
        if let Err(e) = r {
            apagar_a_nova();
            return Err(Falha(2, regras::MOTIVO_COPIA, format!("WriteFile: {}", hr(&e))));
        }
        match ler_arquivo(&nova, DLL_EMBUTIDA.len() + 1) {
            Ok(lido) if lido == DLL_EMBUTIDA => {}
            Ok(lido) => {
                apagar_a_nova();
                return Err(Falha(2, regras::MOTIVO_COPIA, format!("relida com {} B, diferente da embutida", lido.len())));
            }
            Err(e) => {
                apagar_a_nova();
                return Err(Falha(2, regras::MOTIVO_COPIA, e));
            }
        }
        if let Err(e) = tirar_do_caminho(&destino, cano) {
            apagar_a_nova();
            return Err(Falha(2, regras::MOTIVO_COPIA, e));
        }
        if let Err(e) = unsafe { MoveFileExW(&HSTRING::from(nova.as_str()), &HSTRING::from(destino.as_str()), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) } {
            apagar_a_nova();
            return Err(Falha(2, regras::MOTIVO_COPIA, format!("MoveFileExW: {}", hr(&e))));
        }
        cano.diario(format!("camera: fonte em {destino}"));
        garantir_o_diario(cano);

        // 3. O registro COM. Uma falha no meio desfaz o que entrou (a chave inteira e o arquivo).
        cano.mandar(Linha::Passo(3));
        for (subchave, nome, valor) in regras::valores_do_registro(&destino) {
            if let Err(e) = escrever_valor(subchave, nome, &valor) {
                let _ = apagar_o_registro();
                let _ = tirar_do_caminho(&destino, cano);
                return Err(Falha(3, regras::MOTIVO_REGISTRO, e));
            }
        }
        cano.diario(format!("camera: registrada em HKLM\\{}", regras::CHAVE_DO_CLSID));

        // 4. Confere no registro, e não no código de retorno (a regra da casa: `Remove()` já
        //    devolveu `S_OK` sem remover nada).
        cano.mandar(Linha::Passo(4));
        match ler_registro() {
            Registro::Presente { caminho, existe: true } if regras::mesmo_caminho(&caminho, &destino) => {
                cano.diario("camera: registro conferido");
                Ok(false)
            }
            outro => Err(Falha(4, regras::MOTIVO_CONFERENCIA, format!("{outro:?}"))),
        }
    }

    /// **Remove.** `pelo_msi`: o desinstalador do MSI (SYSTEM, sem cano), só muda o diário.
    fn desinstalar(cano: &mut Cano, pelo_msi: bool) -> Result<bool, Falha> {
        let pf = pasta_conhecida(&FOLDERID_ProgramFiles).map_err(|e| Falha(0, regras::MOTIVO_PASTA, e))?;
        let destino = regras::caminho_da_dll(&pf);

        // 1. O registro primeiro: sem ele, nenhum app cria câmera nova com a fonte, e o Quall aberto
        //    solta as suas na próxima releitura (2 s).
        cano.mandar(Linha::Passo(1));
        let antes = ler_registro();
        cano.diario(format!("camera: registro antes da remoção: {antes:?}{}", if pelo_msi { " (pelo MSI)" } else { "" }));
        apagar_o_registro().map_err(|e| Falha(1, regras::MOTIVO_REGISTRO_FICOU, e))?;

        // 2. O arquivo: **só** o nosso caminho. Um registro que apontava para outro lugar (a bancada)
        //    sai, mas o arquivo de lá não é do Quall e fica.
        cano.mandar(Linha::Passo(2));
        if let Registro::Presente { caminho, .. } = &antes {
            if !regras::mesmo_caminho(caminho, &destino) {
                cano.diario(format!("camera: o registro apontava para {caminho}, que não é o arquivo do Quall; ficou onde está"));
            }
        }
        let preso = tirar_do_caminho(&destino, cano).map_err(|e| Falha(2, regras::MOTIVO_ARQUIVO_FICOU, e))?;
        // A pasta sai se ficou vazia (sem o MSI do app; com ele, o app continua lá).
        let pasta = format!(r"{}\{}", pf.trim_end_matches('\\'), regras::PASTA);
        if !preso && unsafe { RemoveDirectoryW(&HSTRING::from(pasta.as_str())) }.is_ok() {
            cano.diario(format!("camera: pasta vazia removida: {pasta}"));
        }

        // 3. Confere.
        cano.mandar(Linha::Passo(3));
        if ler_registro() != Registro::Ausente {
            return Err(Falha(3, regras::MOTIVO_REGISTRO_FICOU, format!("{:?}", ler_registro())));
        }
        if arquivo_existe(&destino) {
            return Err(Falha(3, regras::MOTIVO_ARQUIVO_FICOU, destino));
        }
        cano.diario("camera: removida e conferida");
        Ok(false)
    }
}

#[cfg(not(feature = "msix"))]
fn aleatorio(b: &mut [u8]) -> Result<(), String> {
    use windows::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
    let s = unsafe { BCryptGenRandom(None, b, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if s.is_ok() {
        Ok(())
    } else {
        Err(format!("BCryptGenRandom: 0x{:08X}", s.0 as u32))
    }
}

// =============================================================================================
// A janela: a caixa, o lançamento e o andamento
// =============================================================================================

static ANDAMENTO: Mutex<Andamento> = Mutex::new(Andamento::Parado);
/// O diário do instalador avulso, em memória: ele roda inteiro como administrador e não escreve em
/// pasta do usuário. A janela dele mostra as linhas em "Detalhes".
static DIARIO_LOCAL: Mutex<Vec<String>> = Mutex::new(Vec::new());
static VERSAO: AtomicU64 = AtomicU64::new(0);

fn anotar_local(s: String) {
    if let Ok(mut d) = DIARIO_LOCAL.lock() {
        d.push(s);
    }
    VERSAO.fetch_add(1, Ordering::SeqCst);
}

pub fn diario_local() -> Vec<String> {
    DIARIO_LOCAL.lock().map(|d| d.clone()).unwrap_or_default()
}

pub fn andamento() -> Andamento {
    ANDAMENTO.lock().map(|a| a.clone()).unwrap_or_default()
}

/// Sobe a cada mudança do andamento: a janela redesenha quando vê outra.
pub fn versao() -> u64 {
    VERSAO.load(Ordering::SeqCst)
}

fn mudar(a: Andamento) {
    if let Ok(mut g) = ANDAMENTO.lock() {
        *g = a;
    }
    VERSAO.fetch_add(1, Ordering::SeqCst);
}

/// O corpo da caixa de instalar (e do instalador avulso): o que é, o UAC, como sai.
pub fn corpo_de_instalar() -> String {
    use crate::idioma::t;
    [t(regras::CAIXA_CORPO_O_QUE_E), t(regras::CAIXA_CORPO_UAC), t(regras::CAIXA_CORPO_SAI)].join("\n\n")
}

// A edição MSIX conserva a leitura de estado da câmera externa, mas não contém
// o instalador nem o caminho de elevação. Estas recusas também protegem um exe
// de teste iniciado fora do pacote e chamadas futuras feitas pela interface.
#[cfg(feature = "msix")]
pub fn perguntar(_hwnd: HWND, _acao: Acao) -> bool {
    false
}

#[cfg(feature = "msix")]
pub fn comecar(_hwnd: HWND, acao: Acao, ao_acabar: impl FnOnce() + Send + 'static) {
    comecar_aqui(acao);
    ao_acabar();
}

#[cfg(feature = "msix")]
pub fn comecar_aqui(acao: Acao) {
    registro::linha("camera: a edição MSIX usa somente o componente instalado separadamente");
    mudar(Andamento::Acabou {
        acao,
        resultado: Resultado::Falha(0, regras::MOTIVO_PACOTE.into(), "msix".into()),
    });
}

/// **A caixa que explica antes.** `true` só com o clique em Instalar (ou Remover). O botão leva o
/// escudo do UAC; o padrão é Cancelar (o Enter sem ler não instala).
#[cfg(not(feature = "msix"))]
pub fn perguntar(hwnd: HWND, acao: Acao) -> bool {
    use crate::idioma::t;
    use windows::Win32::Foundation::{LPARAM, S_OK, WPARAM};
    use windows::Win32::UI::Controls::{
        TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOG_BUTTON, TASKDIALOG_NOTIFICATIONS, TDCBF_CANCEL_BUTTON,
        TDF_ALLOW_DIALOG_CANCELLATION, TDF_POSITION_RELATIVE_TO_WINDOW, TDM_SET_BUTTON_ELEVATION_REQUIRED_STATE, TDN_CREATED,
        TD_SHIELD_ICON,
    };
    use windows::Win32::UI::WindowsAndMessaging::SendMessageW;

    const ID_SIM: i32 = 1000;
    unsafe extern "system" fn ao_criar(h: HWND, msg: TASKDIALOG_NOTIFICATIONS, _w: WPARAM, _l: LPARAM, _d: isize) -> windows::core::HRESULT {
        if msg == TDN_CREATED {
            unsafe {
                SendMessageW(h, TDM_SET_BUTTON_ELEVATION_REQUIRED_STATE.0 as u32, Some(WPARAM(ID_SIM as usize)), Some(LPARAM(1)));
            }
        }
        S_OK
    }

    let (titulo, pergunta, corpo, sim) = match acao {
        Acao::Instalar => (t(regras::CAIXA_TITULO).to_string(), t(regras::CAIXA_PERGUNTA).to_string(), corpo_de_instalar(), t(regras::CAIXA_INSTALAR).to_string()),
        Acao::Desinstalar => (
            t(regras::CAIXA_REMOVER_TITULO).to_string(),
            t(regras::CAIXA_REMOVER_PERGUNTA).to_string(),
            [t(regras::CAIXA_REMOVER_CORPO), t(regras::CAIXA_CORPO_UAC)].join("\n\n"),
            t(regras::CAIXA_REMOVER).to_string(),
        ),
    };
    let (titulo, pergunta, corpo, sim) = (largo(&titulo), largo(&pergunta), largo(&corpo), largo(&sim));
    let botoes = [TASKDIALOG_BUTTON { nButtonID: ID_SIM, pszButtonText: PCWSTR(sim.as_ptr()) }];
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        hwndParent: hwnd,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
        dwCommonButtons: TDCBF_CANCEL_BUTTON,
        pszWindowTitle: PCWSTR(titulo.as_ptr()),
        Anonymous1: TASKDIALOGCONFIG_0 { pszMainIcon: TD_SHIELD_ICON },
        pszMainInstruction: PCWSTR(pergunta.as_ptr()),
        pszContent: PCWSTR(corpo.as_ptr()),
        cButtons: botoes.len() as u32,
        pButtons: botoes.as_ptr(),
        nDefaultButton: 2, // IDCANCEL
        pfCallback: Some(ao_criar),
        ..Default::default()
    };
    let mut clicado = 0i32;
    match unsafe { TaskDialogIndirect(&config, Some(&mut clicado), None, None) } {
        Ok(()) => {
            let sim = clicado == ID_SIM;
            registro::linha(format!("camera: a caixa de {} — {}", acao.verbo(), if sim { "a pessoa aceitou" } else { "cancelada" }));
            sim
        }
        Err(e) => {
            registro::linha(format!("camera: !! a caixa não abriu ({}); nada foi feito", hr(&e)));
            false
        }
    }
}

/// O SID do usuário deste processo, em texto (para a DACL do cano).
#[cfg(not(feature = "msix"))]
fn sid_do_usuario() -> Option<String> {
    use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows::Win32::System::Threading::OpenProcessToken;
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).ok()?;
        let mut buf = vec![0u8; 256];
        let mut n = 0u32;
        let r = GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr() as *mut c_void), buf.len() as u32, &mut n);
        let _ = CloseHandle(token);
        r.ok()?;
        let usuario = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut s = PWSTR::null();
        ConvertSidToStringSidW(usuario.User.Sid, &mut s).ok()?;
        let texto = s.to_string().ok();
        let _ = LocalFree(Some(HLOCAL(s.0 as *mut c_void)));
        texto
    }
}

#[cfg(not(feature = "msix"))]
struct Handle(HANDLE);
#[cfg(not(feature = "msix"))]
unsafe impl Send for Handle {}
#[cfg(not(feature = "msix"))]
unsafe impl Sync for Handle {}
#[cfg(not(feature = "msix"))]
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// **Começa** a instalação ou a remoção pelo app: o UAC, o processo elevado e o cano, numa thread.
/// `ao_acabar` roda na thread, no fim.
#[cfg(not(feature = "msix"))]
pub fn comecar(hwnd: HWND, acao: Acao, ao_acabar: impl FnOnce() + Send + 'static) {
    if !regras::pode_comecar(&andamento()) {
        registro::linha("camera: já há uma instalação ou remoção em andamento; o clique fica sem efeito");
        return;
    }
    mudar(Andamento::Rodando { acao, passo: 0 });
    let janela = hwnd.0 as isize;
    let r = std::thread::Builder::new().name("quall.camera-instalador".into()).spawn(move || {
        // O `ShellExecuteExW` pede COM na thread que o chama; STA, como o shell gosta.
        let _ = unsafe { windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_APARTMENTTHREADED) };
        let resultado = lancar(HWND(janela as *mut c_void), acao);
        registro::linha(format!("camera: {} terminou — {resultado:?}", acao.verbo()));
        mudar(Andamento::Acabou { acao, resultado });
        ao_acabar();
    });
    if let Err(e) = r {
        mudar(Andamento::Acabou { acao, resultado: Resultado::Falha(0, regras::MOTIVO_NAO_ABRIU.into(), e.to_string()) });
    }
}

/// **Começa no próprio processo** (o instalador avulso, já elevado): o mesmo andamento de
/// [`comecar`], sem UAC nem cano.
#[cfg(not(feature = "msix"))]
pub fn comecar_aqui(acao: Acao) {
    if !regras::pode_comecar(&andamento()) {
        return;
    }
    mudar(Andamento::Rodando { acao, passo: 0 });
    let r = std::thread::Builder::new().name("quall.camera-instalador".into()).spawn(move || {
        let resultado = elevado::rodar_aqui(acao);
        anotar_local(format!("camera: {} terminou — {resultado:?}", acao.verbo()));
        mudar(Andamento::Acabou { acao, resultado });
    });
    if let Err(e) = r {
        mudar(Andamento::Acabou { acao, resultado: Resultado::Falha(0, regras::MOTIVO_NAO_ABRIU.into(), e.to_string()) });
    }
}

#[cfg(not(feature = "msix"))]
fn lancar(hwnd: HWND, acao: Acao) -> Resultado {
    let falha = |c: &str, t: String| Resultado::Falha(0, c.to_string(), t);
    // O cano: nome aleatório, uma instância só, só entrada, sem cliente remoto, e a DACL deste
    // usuário, dos Administradores e do SYSTEM (o processo elevado é o mesmo usuário com o token
    // cheio, ou o administrador que digitou a senha no UAC).
    let mut bytes = [0u8; 16];
    if let Err(e) = aleatorio(&mut bytes) {
        return falha(regras::MOTIVO_NAO_ABRIU, e);
    }
    let nome = regras::nome_do_cano(u128::from_be_bytes(bytes));
    let Some(sid) = sid_do_usuario() else { return falha(regras::MOTIVO_NAO_ABRIU, "TokenUser".into()) };
    let mut sd = PSECURITY_DESCRIPTOR::default();
    if let Err(e) = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;{sid})")), 1, &mut sd, None)
    } {
        return falha(regras::MOTIVO_NAO_ABRIU, format!("SDDL do cano: {}", hr(&e)));
    }
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd.0, bInheritHandle: false.into() };
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x0008_0000;
    let h = unsafe {
        CreateNamedPipeW(
            &HSTRING::from(nome.as_str()),
            FILE_FLAGS_AND_ATTRIBUTES(PIPE_ACCESS_INBOUND.0 | FILE_FLAG_FIRST_PIPE_INSTANCE),
            PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            0,
            4096,
            0,
            Some(&sa),
        )
    };
    unsafe {
        let _ = LocalFree(Some(HLOCAL(sd.0)));
    }
    if h.is_invalid() {
        return falha(regras::MOTIVO_NAO_ABRIU, format!("CreateNamedPipeW: {}", ultimo_erro()));
    }
    let cano = Arc::new(Handle(h));

    // O próprio exe, elevado. `SW_HIDE`: o processo não tem janela.
    let exe = match std::env::current_exe() {
        Ok(p) => p.display().to_string(),
        Err(e) => return falha(regras::MOTIVO_NAO_ABRIU, format!("current_exe: {e}")),
    };
    let (exe_w, parametros, verbo) = (largo(&exe), largo(&regras::parametros(acao, &nome)), largo("runas"));
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
        hwnd,
        lpVerb: PCWSTR(verbo.as_ptr()),
        lpFile: PCWSTR(exe_w.as_ptr()),
        lpParameters: PCWSTR(parametros.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    registro::linha(format!("camera: pedindo o UAC para {} ({exe})", acao.verbo()));
    if let Err(e) = unsafe { ShellExecuteExW(&mut info) } {
        if e.code() == ERROR_CANCELLED.to_hresult() {
            registro::linha("camera: o UAC foi recusado; nada foi feito");
            return Resultado::CanceladoNoUac;
        }
        return falha(regras::MOTIVO_NAO_ABRIU, format!("ShellExecuteExW: {}", hr(&e)));
    }
    if info.hProcess.is_invalid() {
        return falha(regras::MOTIVO_NAO_ABRIU, "ShellExecuteExW: hProcess nulo".into());
    }
    let processo = Arc::new(Handle(info.hProcess));

    // Quem espera o processo: quando ele sai sem ter conectado, conecta-se ao próprio cano para
    // soltar o `ConnectNamedPipe` (e a leitura acaba no fim do arquivo).
    let conectou = Arc::new(AtomicBool::new(false));
    let vigia = {
        let (processo, conectou, nome) = (Arc::clone(&processo), Arc::clone(&conectou), nome.clone());
        std::thread::spawn(move || {
            unsafe { WaitForSingleObject(processo.0, INFINITE) };
            if !conectou.load(Ordering::SeqCst) {
                let r = unsafe { CreateFileW(&HSTRING::from(nome.as_str()), FILE_GENERIC_WRITE.0, FILE_SHARE_NONE, None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None) };
                if let Ok(h) = r {
                    unsafe {
                        let _ = CloseHandle(h);
                    }
                }
            }
        })
    };

    let mut ultimo_passo = 0usize;
    let mut fim: Option<Linha> = None;
    let c = unsafe { ConnectNamedPipe(cano.0, None) };
    let ok = c.is_ok() || c.as_ref().is_err_and(|e| e.code() == ERROR_PIPE_CONNECTED.to_hresult());
    conectou.store(true, Ordering::SeqCst);
    if ok {
        let mut resto = String::new();
        let mut buf = [0u8; 1024];
        loop {
            let mut n = 0u32;
            if unsafe { ReadFile(cano.0, Some(&mut buf), Some(&mut n), None) }.is_err() || n == 0 {
                break;
            }
            resto.push_str(&String::from_utf8_lossy(&buf[..n as usize]));
            while let Some(p) = resto.find('\n') {
                let linha: String = resto.drain(..=p).collect();
                match Linha::ler(&linha) {
                    Some(Linha::Passo(k)) => {
                        ultimo_passo = k;
                        registro::linha(format!("camera: passo {k}: {}", regras::nome_do_passo(acao, k).unwrap_or("?")));
                        mudar(Andamento::Rodando { acao, passo: k });
                    }
                    Some(Linha::Diario(s)) => registro::linha(s),
                    Some(l @ (Linha::Ok | Linha::OkReiniciar | Linha::Falha(..))) => fim = Some(l),
                    None => registro::linha(format!("camera: linha fora do protocolo: {:?}", linha.trim_end())),
                }
            }
            if resto.len() > 64 * 1024 {
                resto.clear();
            }
        }
    }
    let _ = vigia.join();
    let mut codigo = 0u32;
    let codigo = unsafe { GetExitCodeProcess(processo.0, &mut codigo) }.ok().map(|_| codigo);
    registro::linha(format!("camera: o processo elevado saiu com {codigo:?}"));
    regras::resultado(fim.as_ref(), ultimo_passo, codigo)
}

#[cfg(all(test, feature = "msix"))]
mod testes_msix {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;

    /// Exercita o limite da edição fora do pacote: nenhum clique pode depender da identidade
    /// instalada para impedir uma instalação. O teste só lê o registro real da câmera.
    #[test]
    fn msix_recusa_instalar_e_remover_sem_embutir_a_fonte() {
        assert!(DLL_EMBUTIDA.is_empty(), "a edição MSIX não pode transportar a DLL do instalador");
        let registro_antes = ler_registro();
        let estado_antes = andamento();
        let versao_antes = versao();

        for acao in [Acao::Instalar, Acao::Desinstalar] {
            assert!(!perguntar(HWND::default(), acao), "a edição MSIX não deve abrir confirmação administrativa");
        }
        assert_eq!(andamento(), estado_antes, "perguntar não deve iniciar trabalho");
        assert_eq!(versao(), versao_antes);

        for acao in [Acao::Instalar, Acao::Desinstalar] {
            let retornos = Arc::new(AtomicUsize::new(0));
            let retornos_do_clique = Arc::clone(&retornos);
            comecar(HWND::default(), acao, move || {
                retornos_do_clique.fetch_add(1, Ordering::SeqCst);
            });
            assert_eq!(retornos.load(Ordering::SeqCst), 1, "a recusa precisa concluir o pedido da interface");
            let recusado = Andamento::Acabou {
                acao,
                resultado: Resultado::Falha(0, regras::MOTIVO_PACOTE.into(), "msix".into()),
            };
            assert_eq!(andamento(), recusado);
            assert_eq!(ler_registro(), registro_antes, "a tentativa MSIX não pode mudar o registro da fonte");

            comecar_aqui(acao);
            assert_eq!(andamento(), recusado, "a entrada direta também precisa recusar");
            assert_eq!(ler_registro(), registro_antes);
        }
        // Mantém o estado compartilhado do teste para não afetar verificações posteriores.
        *ANDAMENTO.lock().expect("andamento do teste MSIX") = estado_antes;
        VERSAO.store(versao_antes, Ordering::SeqCst);
    }
}
