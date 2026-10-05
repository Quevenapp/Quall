//! `receita_monitor` — **sonda de bancada do monitor virtual no Windows** (frente F2a), não produto.
//!
//! Cria monitores no SudoVDA com a receita pedida, imprime o que o Windows fez com cada um e os
//! solta. É o molde de `tools/tela-estendida/receita-monitor.m` (a sonda da "regra do 2x" do Mac):
//! **série nova a cada medida**, o que o sistema fez lido **de dentro do processo que criou o
//! monitor**, e uma receita por execução. O desenho e as perguntas A–J estão em
//! `docs/monitor-virtual-windows.md` §8; o uso, em §11.
//!
//!     receita_monitor --alvo=2436x1124 --hz=60 --serie=N --placa=intel|nvidia
//!                     [--nome=iPhone-X] [--segundos=10] [--juntos=N] [--ciclos=N [--guid-novo]]
//!                     [--sem-ping | --morrer] [--captura [--captura-hz=N] [--placa-captura=...]]
//!                     [--carga=parada|camadas] [--espera-fina] [--com-outros] [--registro=arquivo]
//!     receita_monitor --so-veredito
//!
//! # O veredito vem antes de qualquer coisa
//!
//! Antes até de validar os argumentos. Sem o adaptador do SudoVDA a sonda sai com código 3 e a
//! frase *"adaptador SudoVDA ausente: ver docs/monitor-virtual-windows.md §9"*, **sem criar nada e
//! sem abrir dispositivo nenhum**. O veredito só lê o PnP (interfaces presentes e os nós da classe
//! Display). `--so-veredito` para ali mesmo, com o driver instalado ou não: é o pré-voo de quem vai
//! medir.
//!
//! # O que ela nunca faz
//!
//! - **Mexer em monitor que não é dela.** Só manda `REMOVE` com os GUIDs que ela mesma criou, e
//!   recusa começar (código 5) se já houver monitor do SudoVDA presente antes da corrida. O
//!   spacedesk do Dell é outro driver e ela não o toca. O `SET_RENDER_ADAPTER` e o ping são do
//!   **adaptador** do SudoVDA, que só a sonda usa.
//! - **Abrir pixel.** A captura (`--captura`) conta quadros pelo carimbo do sistema e fecha cada
//!   quadro sem tocar na superfície. A carga (`--carga`) é uma janela **nossa**, sintética, posta
//!   no monitor virtual — e ela se destrói sozinha se deixar de estar nele, para nunca cobrir a
//!   tela do usuário (`docs/regras-de-frente.md`, "Um vídeo de bancada pode conter a vida do
//!   usuário").
//! - **Deixar a placa para o Windows.** `--placa` é obrigatório: sem o `SET_RENDER_ADAPTER` quem
//!   escolhe a placa que desenha o monitor é o Windows (§5.3), e a medida fica sem dono.
//!
//! # Linhas (as do §8, com campos a mais no fim de cada uma)
//!
//!     RECEITA alvo=… hz=… serie=… …
//!     VEREDITO adaptador SudoVDA: presente|ausente|presente sem interface …
//!     add=ok luid=… target=… em N ms …            | add=FALHOU erro=… em N ms …
//!     online: nome=\\.\DISPLAYn em N ms ativo=sim modo=LxA@Hz escala=…% …
//!     oferecidos: LxA@Hz/Hz … (N modos)
//!     ALVO LxA@Hz: nasceu=SIM|nao oferecido=SIM|nao …
//!     carga: …                                     (com --carga)
//!     captura: quadros=… q/s=… intervalo p50/p95=… …   (com --captura)
//!     soltar=ok em N ms
//!     testemunhas: caminho_ativo=nao em N ms, enum=nao em N ms, pnp_presente=False em N ms, closed=…
//!
//! # Códigos de saída
//!
//! 0 tudo nasceu como pedido e saiu testemunhado · 1 rodou, e algo não nasceu, não saiu ou falhou
//! · 2 argumento recusado · 3 adaptador SudoVDA ausente · 4 adaptador presente mas inutilizável
//! (sem interface, não abre, protocolo diferente) · 5 já havia monitor do SudoVDA antes da corrida
//! · 98 a janela da carga não respondeu e o processo encerrou por segurança · 99 o filho do
//! `--morrer` (o fim abrupto é a medida).
//!
//! # Onde roda
//!
//! Na **sessão interativa**, por tarefa agendada (`apps/windows/scripts/receita-monitor.ps1`). Da
//! Sessão 0 (o SSH) o veredito funciona e a captura não (`docs/app-windows.md`, `0x887A0022`).
//!
//! # A fonte do contrato do driver
//!
//! Os IOCTL e as estruturas foram transcritos do cabeçalho público do SudoVDA,
//! `Common/Include/sudovda-ioctl.h` em SudoMaker/SudoVDA@a4b09fa2 (licença "MIT and CC0 or Public
//! Domain", `README.md:26`), e o comportamento de cada IOCTL foi lido em
//! `Virtual Display Driver (HDR)/SudoVDA/Driver.cpp` do mesmo commit. **Nenhuma linha vem do Apollo
//! nem do Vibepollo** (GPL-3): as ideias de uso que o documento cita deles (ping a um terço do vigia,
//! espera que dobra) foram reescritas aqui a partir da descrição.

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::os::windows::process::CommandExt;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use clap::Parser;
use windows::core::GUID;
use windows::Win32::Foundation::{HWND, LUID};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromWindow, HMONITOR, MONITORINFO, MONITORINFOEXW, MONITOR_DEFAULTTONULL,
};

use quall_capture_probe::device;

/// O arquivo de `--registro`, se houver: cada linha sai no stdout **e** aqui, em UTF-8 cru. Existe
/// porque a tarefa agendada que roda a sonda passa o stdout pelo PowerShell 5.1, que o decodifica
/// pela página de código do console e o regrava — os acentos chegariam trocados no arquivo que o
/// SSH lê.
static REGISTRO: Mutex<Option<std::fs::File>> = Mutex::new(None);

/// `println!` que também escreve no registro, linha a linha e sem buffer (o SSH espia o arquivo
/// com a sonda ainda rodando).
macro_rules! diga {
    ($($t:tt)*) => {{
        let linha = quall_capture_probe::higiene_do_registro::sanitizar_argumentos(&format!($($t)*));
        println!("{linha}");
        if let Ok(mut r) = crate::REGISTRO.lock() {
            if let Some(f) = r.as_mut() {
                use std::io::Write;
                let _ = writeln!(f, "{linha}");
                let _ = f.flush();
            }
        }
    }};
}

// ================================================================================================
// Texto e tempo
// ================================================================================================

fn largo(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn de_utf16(bruto: &[u16]) -> String {
    let fim = bruto.iter().position(|c| *c == 0).unwrap_or(bruto.len());
    String::from_utf16_lossy(&bruto[..fim])
}

/// Uma lista `MULTI_SZ` (cadeias separadas por NUL, fim em NUL duplo), como o CfgMgr devolve.
fn multi_sz(bruto: &[u16]) -> Vec<String> {
    bruto
        .split(|c| *c == 0)
        .filter(|s| !s.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}

/// A mesma lista, vinda num buffer de bytes (propriedades do PnP chegam assim).
fn multi_sz_de_bytes(bruto: &[u8]) -> Vec<String> {
    let u: Vec<u16> = bruto.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    multi_sz(&u)
}

fn guid_texto(g: &GUID) -> String {
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        g.data1, g.data2, g.data3, g.data4[0], g.data4[1], g.data4[2], g.data4[3], g.data4[4],
        g.data4[5], g.data4[6], g.data4[7]
    )
}

fn luid_texto(l: LUID) -> String {
    format!("0x{:08X}:{:08X}", l.HighPart as u32, l.LowPart)
}

fn mesma_luid(a: LUID, b: LUID) -> bool {
    a.LowPart == b.LowPart && a.HighPart == b.HighPart
}

fn ms(d: Duration) -> u64 {
    d.as_millis() as u64
}

/// O relógio da sonda em unidades de 100 ns do contador de desempenho — a escala do
/// `SystemRelativeTime` de um quadro do Windows.Graphics.Capture, para dar para subtrair um do
/// outro. (Que o carimbo do WGC é o QPC em 100 ns é o que a documentação dele diz; se não fosse, a
/// latência da linha `captura:` sairia absurda, e é assim que isso apareceria.)
mod relogio {
    use std::sync::OnceLock;
    use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

    static FREQUENCIA: OnceLock<i64> = OnceLock::new();

    pub fn agora_100ns() -> i64 {
        let f = *FREQUENCIA.get_or_init(|| {
            let mut f = 0i64;
            unsafe {
                let _ = QueryPerformanceFrequency(&mut f);
            }
            f.max(1)
        });
        let mut c = 0i64;
        unsafe {
            let _ = QueryPerformanceCounter(&mut c);
        }
        ((c as i128) * 10_000_000 / (f as i128)) as i64
    }
}

fn percentil(v: &[f64], p: f64) -> f64 {
    if v.is_empty() {
        return f64::NAN;
    }
    let mut o = v.to_vec();
    o.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let i = ((o.len() - 1) as f64 * p).round() as usize;
    o[i.min(o.len() - 1)]
}

// ================================================================================================
// O contrato do SudoVDA
// ================================================================================================

mod sudovda {
    //! Transcrito de `Common/Include/sudovda-ioctl.h` (SudoMaker/SudoVDA@a4b09fa2), linha a linha
    //! citada. O que cada IOCTL faz do lado de lá está em `Driver.cpp`, `SudoVDAIoDeviceControl`
    //! (`:1479` em diante); as armadilhas que importam para quem chama estão nos comentários.

    use std::ffi::c_void;
    use std::mem::size_of;
    use std::sync::atomic::{AtomicI64, Ordering};

    use windows::core::{GUID, PCWSTR};
    use windows::Win32::Foundation::{
        CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, LUID,
    };
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    use windows::Win32::System::IO::DeviceIoControl;

    /// `CTL_CODE` do `winioctl.h`.
    pub const fn ctl_code(dispositivo: u32, funcao: u32, metodo: u32, acesso: u32) -> u32 {
        (dispositivo << 16) | (acesso << 14) | (funcao << 2) | metodo
    }
    const FILE_DEVICE_UNKNOWN: u32 = 0x22;
    const METHOD_BUFFERED: u32 = 0;
    const FILE_ANY_ACCESS: u32 = 0;

    // sudovda-ioctl.h:10-15
    pub const IOCTL_ADD: u32 = ctl_code(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS);
    pub const IOCTL_REMOVE: u32 = ctl_code(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS);
    pub const IOCTL_SET_RENDER_ADAPTER: u32 =
        ctl_code(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS);
    pub const IOCTL_GET_WATCHDOG: u32 = ctl_code(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS);
    pub const IOCTL_PING: u32 = ctl_code(FILE_DEVICE_UNKNOWN, 0x888, METHOD_BUFFERED, FILE_ANY_ACCESS);
    pub const IOCTL_GET_PROTOCOL_VERSION: u32 =
        ctl_code(FILE_DEVICE_UNKNOWN, 0x8FF, METHOD_BUFFERED, FILE_ANY_ACCESS);

    /// sudovda-ioctl.h:25 — a versão do protocolo que este arquivo transcreve. A sonda **recusa**
    /// um driver que responda outra maior ou menor: as estruturas abaixo seriam outras.
    pub const PROTOCOLO: (u8, u8, u8) = (0, 2, 1);
    /// sudovda-ioctl.h:27
    pub const HARDWARE_ID: &str = r"root\sudomaker\sudovda";
    /// sudovda-ioctl.h:33
    pub const INTERFACE: GUID = GUID::from_u128(0xe5bcc234_1e0c_418a_a0d4_ef8b7501414d);
    /// Os monitores do SudoVDA aparecem como `DISPLAY\SMKD1CE\…`: fabricante `SMK` e produto
    /// `0xD1CE` no EDID base (`edid.h:9`, bytes 8–11).
    pub const PREFIXO_DOS_MONITORES: &str = r"DISPLAY\SMKD1CE\";

    /// sudovda-ioctl.h:35-42. `DeviceName` vira o nome do produto no EDID e `SerialNumber` o texto
    /// de série; os dois passam por `strlen` (`edid.h:43`, `:66`), então até **13 bytes + NUL**.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct AddParams {
        pub width: u32,
        pub height: u32,
        /// Em Hz. O driver multiplica por 1000 o que vier abaixo de 1000 (`Driver.cpp:1546-1548`),
        /// então 60 e 60000 dão o mesmo monitor; a sonda só aceita Hz (1–500).
        pub refresh_rate: u32,
        pub monitor_guid: GUID,
        pub device_name: [u8; 14],
        pub serial_number: [u8; 14],
    }

    /// sudovda-ioctl.h:48-51
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct AddOut {
        pub adapter_luid: LUID,
        pub target_id: u32,
    }

    /// sudovda-ioctl.h:44-46
    #[repr(C)]
    pub struct RemoveParams {
        pub monitor_guid: GUID,
    }

    /// sudovda-ioctl.h:53-55
    #[repr(C)]
    pub struct SetRenderAdapterParams {
        pub adapter_luid: LUID,
    }

    /// sudovda-ioctl.h:57-60
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct WatchdogOut {
        pub timeout: u32,
        pub countdown: u32,
    }

    /// sudovda-ioctl.h:17-22 e :62-64. O último campo é um `bool` de C++ (1 byte); lido como `u8`
    /// para não depender de o driver escrever só 0 ou 1.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct ProtocolVersion {
        pub major: u8,
        pub minor: u8,
        pub incremental: u8,
        pub test_build: u8,
    }

    /// **O GUID sai da série, com `Data1` único.** O EDID do SudoVDA leva só `Data1` (32 bits) no
    /// campo de série (`edid.h:38`, chamado em `Driver.cpp:1545`), e o modo preferido é achado
    /// comparando o **EDID inteiro** (`:1079-1087`): dois GUIDs com o mesmo `Data1` e os mesmos
    /// textos dariam o mesmo EDID, e o segundo herdaria o modo do primeiro (§5.3). Por isso
    /// `Data1` **é** a série, e o resto do GUID é um espaço de nomes fixo desta sonda — o GUID é
    /// função só da série, e reusar a série mede a lembrança do Windows, não a receita.
    pub fn guid_da_serie(serie: u32) -> GUID {
        GUID::from_values(serie, 0x9A11, 0x4D31, [0x8E, 0x51, 0x75, 0x61, 0x6C, 0x6C, 0x52, 0x4D])
    }

    /// Um texto do EDID (`DeviceName`/`SerialNumber`): ASCII imprimível, até 13 bytes, com NUL.
    pub fn texto_edid(s: &str) -> Result<[u8; 14], String> {
        if s.is_empty() || s.len() > 13 || !s.bytes().all(|b| (0x20..0x7F).contains(&b)) {
            return Err(format!(
                "'{s}' não serve como texto do EDID: tem de ser ASCII imprimível, de 1 a 13 \
                 caracteres (o driver passa o campo por strlen, edid.h:43)"
            ));
        }
        let mut t = [0u8; 14];
        t[..s.len()].copy_from_slice(s.as_bytes());
        Ok(t)
    }

    /// Quando este processo mandou o último IOCTL que recarrega o vigia (100 ns do QPC; 0 = nenhum).
    /// É o zero verdadeiro da pergunta F: o vigia conta a partir dele, não do instante em que o
    /// ping para.
    pub static ULTIMO_IOCTL: AtomicI64 = AtomicI64::new(0);

    /// O dispositivo de controle do SudoVDA aberto. O fio de ping abre o **seu** (ver `Ping`): E/S
    /// síncrona num mesmo handle sem `OVERLAPPED` é serializada pelo sistema, e um `ADD` demorado
    /// seguraria o ping atrás dele. (Se a fila interna do IddCx também serializa, o fonte do
    /// SudoVDA não diz — `Driver.cpp:477-479` só registra o `EvtIddCxDeviceIoControl`.)
    pub struct Dispositivo {
        h: HANDLE,
    }
    // O handle é um número do kernel; usá-lo de duas threads é o que `DeviceIoControl` síncrono
    // permite. Nada mais neste tipo é compartilhado.
    unsafe impl Send for Dispositivo {}
    unsafe impl Sync for Dispositivo {}

    impl Dispositivo {
        /// A DACL do dispositivo dá leitura e escrita a Todos (`SudoVDA.inf:39`,
        /// `D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;WD)`): o usuário comum abre sem elevação.
        pub fn abrir(caminho: &str) -> windows::core::Result<Self> {
            let largo = super::largo(caminho);
            let h = unsafe {
                CreateFileW(
                    PCWSTR(largo.as_ptr()),
                    GENERIC_READ.0 | GENERIC_WRITE.0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    None,
                )?
            };
            Ok(Self { h })
        }

        /// Um IOCTL com entrada e saída opcionais. Devolve os bytes que o driver disse ter escrito.
        ///
        /// **Todo IOCTL menos o `GET_WATCHDOG` recarrega o vigia** (`Driver.cpp:1488-1491`), venha
        /// de que processo vier. Quem mede a morte do monitor por silêncio (`--sem-ping`,
        /// `--morrer`) não pode chamar nada daqui enquanto testemunha.
        fn ioctl(
            &self,
            codigo: u32,
            entrada: Option<(*const c_void, usize)>,
            saida: Option<(*mut c_void, usize)>,
        ) -> windows::core::Result<u32> {
            let mut devolvidos = 0u32;
            let r = unsafe {
                DeviceIoControl(
                    self.h,
                    codigo,
                    entrada.map(|e| e.0),
                    entrada.map_or(0, |e| e.1 as u32),
                    saida.map(|s| s.0),
                    saida.map_or(0, |s| s.1 as u32),
                    Some(&mut devolvidos as *mut u32),
                    None,
                )
            };
            // O vigia é recarregado na **entrada** do IOCTL, tenha ele dado certo ou não
            // (`Driver.cpp:1488-1491`, antes do `switch`): o instante conta nos dois casos.
            if codigo != IOCTL_GET_WATCHDOG {
                ULTIMO_IOCTL.store(super::relogio::agora_100ns(), Ordering::SeqCst);
            }
            r?;
            Ok(devolvidos)
        }

        /// `GET_PROTOCOL_VERSION`. No driver, o `case` cai no `default` sem `break`
        /// (`Driver.cpp:1628-1641`) com o estado já em sucesso — responde certo.
        pub fn versao(&self) -> windows::core::Result<ProtocolVersion> {
            let mut v = ProtocolVersion::default();
            let n = self.ioctl(
                IOCTL_GET_PROTOCOL_VERSION,
                None,
                Some((&mut v as *mut ProtocolVersion as *mut c_void, size_of::<ProtocolVersion>())),
            )?;
            if (n as usize) < size_of::<ProtocolVersion>() {
                return Err(windows::core::Error::new(
                    windows::Win32::Foundation::E_UNEXPECTED,
                    format!("GET_PROTOCOL_VERSION devolveu {n} bytes"),
                ));
            }
            Ok(v)
        }

        /// `GET_WATCHDOG`: o prazo do vigia em segundos e a contagem de agora. É o único IOCTL que
        /// **não** recarrega o vigia. (O `case` também cai no do ping sem `break`,
        /// `Driver.cpp:1611-1627`, que só põe sucesso.)
        pub fn vigia(&self) -> windows::core::Result<WatchdogOut> {
            let mut w = WatchdogOut::default();
            self.ioctl(
                IOCTL_GET_WATCHDOG,
                None,
                Some((&mut w as *mut WatchdogOut as *mut c_void, size_of::<WatchdogOut>())),
            )?;
            Ok(w)
        }

        pub fn ping(&self) -> windows::core::Result<()> {
            self.ioctl(IOCTL_PING, None, None).map(|_| ())
        }

        /// `SET_RENDER_ADAPTER`. **O retorno não prova nada**: o driver chama
        /// `IddCxAdapterSetRenderAdapter` e ignora o resultado (`Driver.cpp:1596-1610`, `:841-844`).
        /// A testemunha é o `desenha=` da linha `online:`.
        pub fn fixar_placa(&self, luid: LUID) -> windows::core::Result<()> {
            let p = SetRenderAdapterParams { adapter_luid: luid };
            self.ioctl(
                IOCTL_SET_RENDER_ADAPTER,
                Some((&p as *const SetRenderAdapterParams as *const c_void, size_of::<SetRenderAdapterParams>())),
                None,
            )
            .map(|_| ())
        }

        /// `ADD`. Com um GUID que já está vivo o driver **devolve o monitor vivo** em vez de criar
        /// outro (`Driver.cpp:1520-1536`); sem conector livre, `STATUS_TOO_MANY_NODES`
        /// (`:1498-1500`).
        pub fn adicionar(&self, p: &AddParams) -> windows::core::Result<(AddOut, u32)> {
            let mut o = AddOut::default();
            let n = self.ioctl(
                IOCTL_ADD,
                Some((p as *const AddParams as *const c_void, size_of::<AddParams>())),
                Some((&mut o as *mut AddOut as *mut c_void, size_of::<AddOut>())),
            )?;
            Ok((o, n))
        }

        /// `REMOVE` pelo GUID: `IddCxMonitorDeparture` **só daquele** monitor e o conector volta à
        /// fila (`Driver.cpp:1566-1595`). GUID desconhecido: `STATUS_NOT_FOUND`.
        pub fn soltar(&self, guid: GUID) -> windows::core::Result<()> {
            let p = RemoveParams { monitor_guid: guid };
            self.ioctl(
                IOCTL_REMOVE,
                Some((&p as *const RemoveParams as *const c_void, size_of::<RemoveParams>())),
                None,
            )
            .map(|_| ())
        }
    }

    impl Drop for Dispositivo {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.h);
            }
        }
    }
}

// ================================================================================================
// PnP: o veredito, e a presença dos nós — tudo só leitura
// ================================================================================================

mod pnp {
    use windows::core::{GUID, PCWSTR};
    use windows::Win32::Devices::DeviceAndDriverInstallation::{
        CM_Get_DevNode_PropertyW, CM_Get_DevNode_Status, CM_Get_Device_ID_ListW,
        CM_Get_Device_ID_List_SizeW, CM_Get_Device_Interface_ListW,
        CM_Get_Device_Interface_List_SizeW, CM_Get_Device_Interface_PropertyW, CM_Locate_DevNodeW,
        CM_DEVNODE_STATUS_FLAGS, CM_GETIDLIST_FILTER_CLASS, CM_GETIDLIST_FILTER_ENUMERATOR,
        CM_GET_DEVICE_INTERFACE_LIST_PRESENT, CM_LOCATE_DEVNODE_NORMAL, CM_LOCATE_DEVNODE_PHANTOM,
        CM_PROB, CR_BUFFER_SMALL, CR_NO_SUCH_DEVNODE, CR_SUCCESS, DN_HAS_PROBLEM, DN_STARTED,
        GUID_DEVCLASS_DISPLAY,
    };
    use windows::Win32::Devices::Properties::{
        DEVPKEY_Device_HardwareIds, DEVPKEY_Device_InstanceId, DEVPROPTYPE,
    };

    use super::{guid_texto, largo, multi_sz, multi_sz_de_bytes, sudovda};

    /// As interfaces **presentes** de uma classe de interface de dispositivo. O padrão `(buf, cap)`
    /// do CfgMgr: pergunta o tamanho, aloca, e repete se a lista cresceu no meio.
    pub fn interfaces(classe: &GUID) -> Result<Vec<String>, String> {
        for _ in 0..5 {
            let mut n = 0u32;
            let cr = unsafe {
                CM_Get_Device_Interface_List_SizeW(&mut n, classe, PCWSTR::null(), CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
            };
            if cr != CR_SUCCESS {
                return Err(format!("CM_Get_Device_Interface_List_SizeW devolveu CONFIGRET {}", cr.0));
            }
            if n <= 1 {
                return Ok(Vec::new());
            }
            let mut buf = vec![0u16; n as usize];
            let cr = unsafe {
                CM_Get_Device_Interface_ListW(classe, PCWSTR::null(), &mut buf, CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
            };
            if cr == CR_BUFFER_SMALL {
                continue;
            }
            if cr != CR_SUCCESS {
                return Err(format!("CM_Get_Device_Interface_ListW devolveu CONFIGRET {}", cr.0));
            }
            return Ok(multi_sz(&buf));
        }
        Err("a lista de interfaces cresceu entre as duas chamadas cinco vezes seguidas".into())
    }

    /// Os IDs de instância que casam com um filtro do CfgMgr (enumerador, classe…), presentes ou não.
    pub fn ids(filtro: &str, bandeiras: u32) -> Result<Vec<String>, String> {
        let f = largo(filtro);
        for _ in 0..5 {
            let mut n = 0u32;
            let cr = unsafe { CM_Get_Device_ID_List_SizeW(&mut n, PCWSTR(f.as_ptr()), bandeiras) };
            if cr != CR_SUCCESS {
                return Err(format!("CM_Get_Device_ID_List_SizeW devolveu CONFIGRET {}", cr.0));
            }
            if n <= 1 {
                return Ok(Vec::new());
            }
            let mut buf = vec![0u16; n as usize];
            let cr = unsafe { CM_Get_Device_ID_ListW(PCWSTR(f.as_ptr()), &mut buf, bandeiras) };
            if cr == CR_BUFFER_SMALL {
                continue;
            }
            if cr != CR_SUCCESS {
                return Err(format!("CM_Get_Device_ID_ListW devolveu CONFIGRET {}", cr.0));
            }
            return Ok(multi_sz(&buf));
        }
        Err("a lista de nós cresceu entre as duas chamadas cinco vezes seguidas".into())
    }

    fn localizar(instancia: &str, bandeira: windows::Win32::Devices::DeviceAndDriverInstallation::CM_LOCATE_DEVNODE_FLAGS) -> Option<u32> {
        let l = largo(instancia);
        let mut dn = 0u32;
        let cr = unsafe { CM_Locate_DevNodeW(&mut dn, PCWSTR(l.as_ptr()), bandeira) };
        (cr == CR_SUCCESS).then_some(dn)
    }

    /// **A testemunha do `Present` do PnP**: `CM_LOCATE_DEVNODE_NORMAL` só acha nó presente, e
    /// devolve `CR_NO_SUCH_DEVNODE` para o que não está. Qualquer outro código é "não deu para
    /// perguntar", e volta como erro — nunca como "saiu".
    pub fn presenca(instancia: &str) -> Result<bool, u32> {
        let l = largo(instancia);
        let mut dn = 0u32;
        let cr = unsafe { CM_Locate_DevNodeW(&mut dn, PCWSTR(l.as_ptr()), CM_LOCATE_DEVNODE_NORMAL) };
        if cr == CR_SUCCESS {
            Ok(true)
        } else if cr == CR_NO_SUCH_DEVNODE {
            Ok(false)
        } else {
            Err(cr.0)
        }
    }

    pub fn presente(instancia: &str) -> bool {
        presenca(instancia) == Ok(true)
    }

    /// Estado de um nó, presente ou fantasma: (presente, iniciado, problema).
    pub fn estado(instancia: &str) -> Option<(bool, bool, u32)> {
        let dn = localizar(instancia, CM_LOCATE_DEVNODE_PHANTOM)?;
        let mut st = CM_DEVNODE_STATUS_FLAGS(0);
        let mut pb = CM_PROB(0);
        let cr = unsafe { CM_Get_DevNode_Status(&mut st, &mut pb, dn, 0) };
        if cr != CR_SUCCESS {
            // Nó que existe no registro e não está presente devolve CR_NO_SUCH_DEVINST aqui.
            return Some((false, false, 0));
        }
        let problema = if st.0 & DN_HAS_PROBLEM.0 != 0 { pb.0 } else { 0 };
        Some((true, st.0 & DN_STARTED.0 != 0, problema))
    }

    fn hardware_ids(instancia: &str) -> Vec<String> {
        let Some(dn) = localizar(instancia, CM_LOCATE_DEVNODE_PHANTOM) else { return Vec::new() };
        let mut tipo = DEVPROPTYPE(0);
        let mut tam = 0u32;
        let cr = unsafe { CM_Get_DevNode_PropertyW(dn, &DEVPKEY_Device_HardwareIds, &mut tipo, None, &mut tam, 0) };
        if cr != CR_BUFFER_SMALL || tam == 0 {
            return Vec::new();
        }
        let mut buf = vec![0u8; tam as usize];
        let cr = unsafe {
            CM_Get_DevNode_PropertyW(dn, &DEVPKEY_Device_HardwareIds, &mut tipo, Some(buf.as_mut_ptr()), &mut tam, 0)
        };
        if cr != CR_SUCCESS {
            return Vec::new();
        }
        multi_sz_de_bytes(&buf[..(tam as usize).min(buf.len())])
    }

    /// O ID de instância do nó dono de uma interface — do monitor, a partir do `monitorDevicePath`
    /// que o `DisplayConfig` devolve. Tem de ser lido **enquanto o monitor existe**: depois que ele
    /// sai, a interface some e a pergunta não tem mais a quem ser feita.
    pub fn instancia_da_interface(caminho: &str) -> Option<String> {
        let l = largo(caminho);
        let mut tipo = DEVPROPTYPE(0);
        let mut tam = 0u32;
        let cr = unsafe {
            CM_Get_Device_Interface_PropertyW(PCWSTR(l.as_ptr()), &DEVPKEY_Device_InstanceId, &mut tipo, None, &mut tam, 0)
        };
        if cr != CR_BUFFER_SMALL || tam == 0 {
            return None;
        }
        let mut buf = vec![0u8; tam as usize];
        let cr = unsafe {
            CM_Get_Device_Interface_PropertyW(
                PCWSTR(l.as_ptr()),
                &DEVPKEY_Device_InstanceId,
                &mut tipo,
                Some(buf.as_mut_ptr()),
                &mut tam,
                0,
            )
        };
        if cr != CR_SUCCESS {
            return None;
        }
        multi_sz_de_bytes(&buf[..(tam as usize).min(buf.len())]).into_iter().next()
    }

    pub enum Veredito {
        /// Nenhuma interface do SudoVDA e nenhum nó com o hardware ID dele entre os da classe
        /// Display. `nos_lidos` diz quantos nós foram olhados — verde por ausência tem de mostrar
        /// que procurou.
        /// `fantasma`: um nó com o hardware ID dele que existe no registro mas **não está presente**
        /// (instalado um dia e tirado) — para a sonda, é ausente.
        Ausente { nos_lidos: Result<usize, String>, fantasma: Option<String> },
        /// O nó existe e está presente (o driver foi instalado) mas não publica a interface de
        /// controle: driver que não carregou, ou que foi recusado (problema 52 é assinatura).
        SemInterface { instancia: String, iniciado: bool, problema: u32 },
        Presente { instancia: Option<String>, interfaces: Vec<String> },
        Erro(String),
    }

    pub fn veredito() -> Veredito {
        let interfaces = match interfaces(&sudovda::INTERFACE) {
            Ok(v) => v,
            Err(e) => return Veredito::Erro(e),
        };
        let classe = format!("{{{}}}", guid_texto(&GUID_DEVCLASS_DISPLAY).to_uppercase());
        let nos = ids(&classe, CM_GETIDLIST_FILTER_CLASS);
        let do_sudovda: Vec<String> = nos
            .as_ref()
            .map(|v| {
                v.iter()
                    .filter(|n| hardware_ids(n).iter().any(|h| h.eq_ignore_ascii_case(sudovda::HARDWARE_ID)))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if !interfaces.is_empty() {
            let instancia = do_sudovda.first().cloned().or_else(|| instancia_da_interface(&interfaces[0]));
            return Veredito::Presente { instancia, interfaces };
        }
        let mut fantasma = None;
        for no in &do_sudovda {
            match estado(no) {
                Some((true, iniciado, problema)) => {
                    return Veredito::SemInterface { instancia: no.clone(), iniciado, problema };
                }
                _ => fantasma = Some(no.clone()),
            }
        }
        Veredito::Ausente { nos_lidos: nos.map(|v| v.len()), fantasma }
    }

    /// Os nós de monitor do SudoVDA (`DISPLAY\SMKD1CE\…`): os presentes, e quantos fantasmas —
    /// os ausentes que já estiveram ligados, que a pergunta C quer ver acumulando ou não.
    pub fn monitores_sudovda() -> Result<(Vec<String>, usize), String> {
        let todos = ids("DISPLAY", CM_GETIDLIST_FILTER_ENUMERATOR)?;
        let mut presentes = Vec::new();
        let mut ausentes = 0usize;
        for i in todos {
            if !i.to_ascii_uppercase().starts_with(sudovda::PREFIXO_DOS_MONITORES) {
                continue;
            }
            if presente(&i) {
                presentes.push(i);
            } else {
                ausentes += 1;
            }
        }
        Ok((presentes, ausentes))
    }
}

// ================================================================================================
// Monitores do lado do Windows: DisplayConfig, GDI, DPI, modos, DXGI
// ================================================================================================

mod telas {
    use std::mem::size_of;

    use windows::core::{BOOL, PCWSTR};
    use windows::Win32::Devices::Display::{
        DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, SetDisplayConfig,
        DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
        DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SOURCE_DEVICE_NAME,
        DISPLAYCONFIG_TARGET_DEVICE_NAME, DISPLAYCONFIG_TOPOLOGY_CLONE, DISPLAYCONFIG_TOPOLOGY_EXTEND,
        DISPLAYCONFIG_TOPOLOGY_EXTERNAL, DISPLAYCONFIG_TOPOLOGY_ID, DISPLAYCONFIG_TOPOLOGY_INTERNAL, QDC_ALL_PATHS,
        QDC_DATABASE_CURRENT, QDC_ONLY_ACTIVE_PATHS, QUERY_DISPLAY_CONFIG_FLAGS, SDC_ALLOW_CHANGES, SDC_APPLY,
        SDC_USE_SUPPLIED_DISPLAY_CONFIG, SDC_VALIDATE,
    };
    use windows::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS, LPARAM, LUID, RECT};
    use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1};
    use windows::Win32::Graphics::Gdi::{
        EnumDisplayMonitors, EnumDisplaySettingsExW, DEVMODEW, DISPLAYCONFIG_PATH_ACTIVE,
        DISPLAYCONFIG_PATH_MODE_IDX_INVALID, ENUM_CURRENT_SETTINGS, ENUM_DISPLAY_SETTINGS_FLAGS,
        ENUM_DISPLAY_SETTINGS_MODE, HDC, HMONITOR,
    };
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

    use super::{de_utf16, info_do_monitor, largo, mesma_luid};

    /// Os caminhos do `QueryDisplayConfig`. **Erro é erro**, com o código Win32: quem testemunha a
    /// saída de um monitor não pode ler "não consegui perguntar" como "não está mais lá" (com a tela
    /// do Dell bloqueada, a documentação da API diz que ela devolve `ERROR_ACCESS_DENIED`).
    fn caminhos(so_ativos: bool) -> Result<Vec<DISPLAYCONFIG_PATH_INFO>, u32> {
        let flags = if so_ativos { QDC_ONLY_ACTIVE_PATHS } else { QDC_ALL_PATHS };
        caminhos_e_modos(flags).map(|(p, _)| p)
    }

    fn caminhos_e_modos(
        flags: QUERY_DISPLAY_CONFIG_FLAGS,
    ) -> Result<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>), u32> {
        let mut ultimo = ERROR_INSUFFICIENT_BUFFER.0;
        for _ in 0..5 {
            let (mut np, mut nm) = (0u32, 0u32);
            let e = unsafe { GetDisplayConfigBufferSizes(flags, &mut np, &mut nm) };
            if e != ERROR_SUCCESS {
                return Err(e.0);
            }
            let mut p = vec![DISPLAYCONFIG_PATH_INFO::default(); np as usize];
            let mut m = vec![DISPLAYCONFIG_MODE_INFO::default(); nm as usize];
            let e = unsafe { QueryDisplayConfig(flags, &mut np, p.as_mut_ptr(), &mut nm, m.as_mut_ptr(), None) };
            // A topologia pode mudar entre as duas chamadas — é justamente o que esta sonda provoca.
            if e == ERROR_INSUFFICIENT_BUFFER {
                ultimo = e.0;
                continue;
            }
            if e != ERROR_SUCCESS {
                return Err(e.0);
            }
            p.truncate(np as usize);
            m.truncate(nm as usize);
            return Ok((p, m));
        }
        Err(ultimo)
    }

    /// **Pôr na área de trabalho os alvos da sonda que o Windows deixou de fora** (`--ativar`).
    ///
    /// Com a topologia "somente a tela do PC" (a do Dell em 14/09), o monitor novo chega ao
    /// `QueryDisplayConfig` em algum caminho, mas nenhum ativo: sem nome GDI, sem área de trabalho.
    /// Aqui vão os caminhos ativos de agora, intocados, mais um caminho por alvo que falta — o
    /// primeiro que o `QDC_ALL_PATHS` oferece para ele com o alvo disponível e a fonte livre —, com
    /// os índices de modo inválidos para o Windows escolher modo e posição (`SDC_ALLOW_CHANGES`).
    /// **Sem `SDC_SAVE_TO_DATABASE`**: o Win+P da pessoa e a lembrança por combinação não mudam, e o
    /// que o banco guarda volta quando o monitor sai.
    ///
    /// Devolve o pedido montado (`acrescentados == 0` quando todos já estavam ativos), para
    /// [`aplicar`]. `Err` = não deu para perguntar, ou alvo sem caminho livre.
    ///
    /// `base` diz de onde vêm os caminhos devolvidos intocados: os marcados ativos no
    /// `QDC_ALL_PATHS` (`Todos`, o de 14/09 de manhã) ou os do `QDC_ONLY_ACTIVE_PATHS` com os modos
    /// dele (`Ativos`). As duas leituras podem discordar — o `QDC_ALL_PATHS` do Dell marcava **dois**
    /// caminhos ativos na fonte da tela integrada quando o `QDC_ONLY_ACTIVE_PATHS` dava um (§13).
    pub fn montar(alvos: &[(LUID, u32)], base: Base) -> Result<Pedido, String> {
        let (todos, modos_todos) = caminhos_e_modos(QDC_ALL_PATHS).map_err(|e| format!("QueryDisplayConfig={e}"))?;
        let (ativos, modos) = match base {
            Base::Todos => (
                todos.iter().filter(|p| p.flags & DISPLAYCONFIG_PATH_ACTIVE != 0).copied().collect::<Vec<_>>(),
                modos_todos,
            ),
            Base::Ativos => caminhos_e_modos(QDC_ONLY_ACTIVE_PATHS).map_err(|e| format!("QueryDisplayConfig(ativos)={e}"))?,
        };
        let mut pedido = ativos.clone();
        let mut fontes: Vec<(LUID, u32)> = ativos.iter().map(|p| (p.sourceInfo.adapterId, p.sourceInfo.id)).collect();
        let mut acrescentados = 0usize;
        for &(luid, alvo) in alvos {
            let e_dele = |p: &DISPLAYCONFIG_PATH_INFO| mesma_luid(p.targetInfo.adapterId, luid) && p.targetInfo.id == alvo;
            if ativos.iter().any(e_dele) {
                continue;
            }
            let livre = todos.iter().find(|p| {
                e_dele(p)
                    && p.targetInfo.targetAvailable.as_bool()
                    && !fontes.iter().any(|&(l, i)| mesma_luid(l, p.sourceInfo.adapterId) && i == p.sourceInfo.id)
            });
            let Some(p) = livre else {
                let dele: Vec<&DISPLAYCONFIG_PATH_INFO> = todos.iter().filter(|p| e_dele(p)).collect();
                let disponiveis = dele.iter().filter(|p| p.targetInfo.targetAvailable.as_bool()).count();
                let fontes_dele: Vec<String> = dele
                    .iter()
                    .map(|p| format!("{:08X}:{}", p.sourceInfo.adapterId.LowPart, p.sourceInfo.id))
                    .collect();
                return Err(format!(
                    "alvo {alvo}: nenhum caminho com o alvo disponível e a fonte livre (caminhos={} alvo_disponivel={} \
                     fontes=[{}] em_uso=[{}] status_alvo={:#x}) ativos_da_base=[{}]",
                    dele.len(),
                    disponiveis,
                    fontes_dele.join(" "),
                    fontes.iter().map(|(l, i)| format!("{:08X}:{i}", l.LowPart)).collect::<Vec<_>>().join(" "),
                    dele.first().map_or(0, |p| p.targetInfo.statusFlags),
                    ativos.iter().map(curto).collect::<Vec<_>>().join(" | ")
                ));
            };
            let mut c = *p;
            c.flags = DISPLAYCONFIG_PATH_ACTIVE;
            c.sourceInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
            c.targetInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
            fontes.push((c.sourceInfo.adapterId, c.sourceInfo.id));
            pedido.push(c);
            acrescentados += 1;
        }
        Ok(Pedido { caminhos: pedido, modos, acrescentados })
    }

    /// Copia um caminho para um pedido, trazendo junto os modos que ele usa (índices remapeados para
    /// o arranjo `destino`). Dois caminhos que apontam para o mesmo modo (mesmo tipo, adaptador e
    /// id — duas fontes em clone) reusam o índice. Sem `QDC_VIRTUAL_MODE_AWARE` o índice é o
    /// `modeInfoIdx` puro.
    fn copiar_com_modos(
        p: &DISPLAYCONFIG_PATH_INFO,
        origem: &[DISPLAYCONFIG_MODE_INFO],
        destino: &mut Vec<DISPLAYCONFIG_MODE_INFO>,
    ) -> DISPLAYCONFIG_PATH_INFO {
        let mut remapear = |i: u32| -> u32 {
            if i == DISPLAYCONFIG_PATH_MODE_IDX_INVALID || i as usize >= origem.len() {
                return DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
            }
            let m = origem[i as usize];
            if let Some(j) = destino
                .iter()
                .position(|x| x.infoType == m.infoType && x.id == m.id && mesma_luid(x.adapterId, m.adapterId))
            {
                return j as u32;
            }
            destino.push(m);
            (destino.len() - 1) as u32
        };
        let mut c = *p;
        unsafe {
            c.sourceInfo.Anonymous.modeInfoIdx = remapear(p.sourceInfo.Anonymous.modeInfoIdx);
            c.targetInfo.Anonymous.modeInfoIdx = remapear(p.targetInfo.Anonymous.modeInfoIdx);
        }
        c
    }

    fn e_do_alvo(p: &DISPLAYCONFIG_PATH_INFO, (l, a): (LUID, u32)) -> bool {
        mesma_luid(p.targetInfo.adapterId, l) && p.targetInfo.id == a
    }

    /// O `monitorDevicePath` do alvo de um caminho é de um monitor do SudoVDA
    /// (`\\?\DISPLAY#SMKD1CE#…`)? `None` quando o `GET_TARGET_NAME` falha ou vem sem caminho — e
    /// aí quem pergunta **não** pode concluir que não é nosso.
    fn monitor_e_do_sudovda(p: &DISPLAYCONFIG_PATH_INFO) -> Option<bool> {
        match nome_completo(p.targetInfo.adapterId, p.targetInfo.id) {
            Ok((_, _, _, _, cam)) if !cam.is_empty() => Some(cam.to_ascii_uppercase().contains("SMKD1CE")),
            _ => None,
        }
    }

    /// **A tela do usuário no instante do ADD** — a foto com que todo pedido do `limpo` é montado.
    /// Os ativos do `QDC_ONLY_ACTIVE_PATHS` com o alvo disponível, fora do adaptador virtual e cujo
    /// monitor não é do SudoVDA, com os modos deles copiados. Tirada antes de o Windows ter tempo
    /// de clonar o monitor novo (o clone veio a 81–535 ms, §13.1), ela guarda os modos da pessoa
    /// como estavam — o desfazer do clone não pode ler os modos depois do clone, que divide a fonte.
    #[derive(Clone)]
    pub struct TelaDoUsuario {
        pub caminhos: Vec<DISPLAYCONFIG_PATH_INFO>,
        pub modos: Vec<DISPLAYCONFIG_MODE_INFO>,
        /// Caminhos ativos que ficaram fora da foto e por quê (para o registro).
        pub fora: String,
    }

    impl TelaDoUsuario {
        pub fn alvos(&self) -> Vec<(LUID, u32)> {
            self.caminhos.iter().map(|p| (p.targetInfo.adapterId, p.targetInfo.id)).collect()
        }

        pub fn descrever(&self) -> String {
            format!(
                "[{}] modos={}{}",
                self.caminhos.iter().map(curto).collect::<Vec<_>>().join(" | "),
                self.modos.len(),
                if self.fora.is_empty() { String::new() } else { format!(" fora=[{}]", self.fora) }
            )
        }
    }

    pub fn foto_do_usuario(adaptador_virtual: LUID) -> Result<TelaDoUsuario, String> {
        let (ps, ms) = caminhos_e_modos(QDC_ONLY_ACTIVE_PATHS).map_err(|e| format!("QueryDisplayConfig(ativos)={e}"))?;
        let mut caminhos = Vec::new();
        let mut modos = Vec::new();
        let mut fora = Vec::new();
        for p in &ps {
            if !p.targetInfo.targetAvailable.as_bool() {
                fora.push(format!("velho({})", curto(p)));
            } else if mesma_luid(p.targetInfo.adapterId, adaptador_virtual) {
                fora.push(format!("virtual({})", curto(p)));
            } else if monitor_e_do_sudovda(p) == Some(true) {
                fora.push(format!("clone_nosso({})", curto(p)));
            } else {
                // Monitor da pessoa — inclusive quando o `GET_TARGET_NAME` não responde: na foto,
                // a dúvida fica do lado de manter a tela dela.
                caminhos.push(copiar_com_modos(p, &ms, &mut modos));
            }
        }
        Ok(TelaDoUsuario { caminhos, modos, fora: fora.join(" ") })
    }

    /// A tela do usuário agora é a da foto? Compara, caminho a caminho (pelos pares fonte/alvo), o
    /// modo da fonte (tamanho e posição) e o modo do alvo (tamanho ativo e frequência). É a
    /// testemunha de que o pedido não mexeu no que é da pessoa (`SDC_ALLOW_CHANGES` deixaria).
    pub fn conferir_usuario(foto: &TelaDoUsuario) -> String {
        let (ps, ms) = match caminhos_e_modos(QDC_ONLY_ACTIVE_PATHS) {
            Ok(x) => x,
            Err(e) => return format!("? (QueryDisplayConfig={e})"),
        };
        let modo = |arr: &[DISPLAYCONFIG_MODE_INFO], i: u32| -> Option<DISPLAYCONFIG_MODE_INFO> {
            (i != DISPLAYCONFIG_PATH_MODE_IDX_INVALID).then(|| arr.get(i as usize).copied()).flatten()
        };
        let fonte = |m: Option<DISPLAYCONFIG_MODE_INFO>| {
            m.map(|m| unsafe {
                let s = m.Anonymous.sourceMode;
                (s.width, s.height, s.position.x, s.position.y)
            })
        };
        let alvo = |m: Option<DISPLAYCONFIG_MODE_INFO>| {
            m.map(|m| unsafe {
                let v = m.Anonymous.targetMode.targetVideoSignalInfo;
                (v.activeSize.cx, v.activeSize.cy, v.vSyncFreq.Numerator, v.vSyncFreq.Denominator)
            })
        };
        let mut diferencas = Vec::new();
        for f in &foto.caminhos {
            let Some(a) = ps.iter().find(|p| {
                mesma_luid(p.sourceInfo.adapterId, f.sourceInfo.adapterId)
                    && p.sourceInfo.id == f.sourceInfo.id
                    && e_do_alvo(p, (f.targetInfo.adapterId, f.targetInfo.id))
            }) else {
                diferencas.push(format!("sumiu {}", curto(f)));
                continue;
            };
            let (fi, ai) = unsafe { (f.sourceInfo.Anonymous.modeInfoIdx, f.targetInfo.Anonymous.modeInfoIdx) };
            let (fa, aa) = unsafe { (a.sourceInfo.Anonymous.modeInfoIdx, a.targetInfo.Anonymous.modeInfoIdx) };
            let (f0, f1) = (fonte(modo(&foto.modos, fi)), fonte(modo(&ms, fa)));
            if f0 != f1 {
                diferencas.push(format!("fonte {:X}:{} {f0:?}→{f1:?}", f.sourceInfo.adapterId.LowPart, f.sourceInfo.id));
            }
            let (a0, a1) = (alvo(modo(&foto.modos, ai)), alvo(modo(&ms, aa)));
            if a0 != a1 {
                diferencas.push(format!("alvo {:X}:{} {a0:?}→{a1:?}", f.targetInfo.adapterId.LowPart, f.targetInfo.id));
            }
        }
        if diferencas.is_empty() {
            format!("igual ({} caminho(s))", foto.caminhos.len())
        } else {
            format!("DIFERENTE: {}", diferencas.join("; "))
        }
    }

    /// O que `montar_limpo` achou.
    pub enum Limpo {
        /// O pedido: a foto do usuário + os monitores do adaptador virtual já ativos + os alvos que
        /// faltam.
        Estender(Pedido),
        /// Um monitor nosso está ativo **fora** do adaptador virtual (o Windows o pôs em clone): o
        /// pedido sem ele, para desfazer o clone antes de estender.
        DesfazerClone(Pedido, String),
        /// Nada a fazer ainda (o motivo vai no texto).
        Esperar(String),
        /// Todos os alvos já estão ativos no adaptador virtual.
        Pronto,
    }

    /// **O pedido da receita do §13.** Tudo decidido pelo `QDC_ONLY_ACTIVE_PATHS` de agora; o
    /// `QDC_ALL_PATHS` só serve para achar o caminho livre do alvo novo.
    ///
    /// - Os caminhos do usuário vêm da **foto** do instante do ADD, com os modos de então; e só se
    ///   pede quando **todos** os alvos da foto seguem ativos e disponíveis agora — um pedido sem um
    ///   deles apagaria aquela tela da pessoa. Foto vazia: não pede.
    /// - Os monitores do adaptador virtual já ativos (os desta execução e os de outra, `--com-outros`)
    ///   ficam no pedido com os modos que têm agora.
    /// - Um caminho ativo que não é da foto nem do adaptador virtual: se o monitor é do SudoVDA, é o
    ///   clone do Windows (desfazer primeiro); se não dá para saber de quem é, **esperar** — pode
    ///   ser um monitor que a pessoa acabou de ligar, e o pedido o desligaria.
    /// - Um caminho por alvo que falta, o primeiro disponível com a fonte livre. Sem caminho para o
    ///   **primeiro** alvo (o monitor novo), esperar; os outros sem caminho ficam de fora.
    pub fn montar_limpo(alvos: &[(LUID, u32)], foto: &TelaDoUsuario) -> Result<Limpo, String> {
        let Some(&(virtual_, _)) = alvos.first() else { return Ok(Limpo::Pronto) };
        let (on, ms_on) = caminhos_e_modos(QDC_ONLY_ACTIVE_PATHS).map_err(|e| format!("QueryDisplayConfig(ativos)={e}"))?;
        let ativo_agora = |alvo: (LUID, u32)| on.iter().any(|p| p.targetInfo.targetAvailable.as_bool() && e_do_alvo(p, alvo));
        if alvos.iter().all(|&a| ativo_agora(a)) {
            return Ok(Limpo::Pronto);
        }
        if foto.caminhos.is_empty() {
            return Ok(Limpo::Esperar(format!(
                "a foto do usuário não tem caminho nenhum — não peço, para não tirar a tela da pessoa ({})",
                foto.descrever()
            )));
        }
        let faltando: Vec<String> = foto
            .caminhos
            .iter()
            .filter(|f| !ativo_agora((f.targetInfo.adapterId, f.targetInfo.id)))
            .map(curto)
            .collect();
        if !faltando.is_empty() {
            return Ok(Limpo::Esperar(format!(
                "caminho(s) da foto do usuário não ativo(s) agora: [{}] — não peço",
                faltando.join(" | ")
            )));
        }
        let da_foto = foto.alvos();
        let mut clones = Vec::new();
        let mut desconhecidos = Vec::new();
        let mut virtuais = Vec::new();
        for p in &on {
            if !p.targetInfo.targetAvailable.as_bool() || da_foto.iter().any(|&a| e_do_alvo(p, a)) {
                continue;
            }
            if mesma_luid(p.targetInfo.adapterId, virtual_) {
                virtuais.push(*p);
            } else {
                match monitor_e_do_sudovda(p) {
                    Some(true) => clones.push(*p),
                    _ => desconhecidos.push(*p),
                }
            }
        }
        if !desconhecidos.is_empty() {
            return Ok(Limpo::Esperar(format!(
                "caminho ativo que não é da foto nem nosso: [{}] — não peço",
                desconhecidos.iter().map(curto).collect::<Vec<_>>().join(" | ")
            )));
        }
        let mut modos = foto.modos.clone();
        let mut pedido = foto.caminhos.clone();
        for v in &virtuais {
            pedido.push(copiar_com_modos(v, &ms_on, &mut modos));
        }
        if !clones.is_empty() {
            let texto = clones.iter().map(|p| format!("clone_nosso({})", curto(p))).collect::<Vec<_>>().join(" ");
            return Ok(Limpo::DesfazerClone(Pedido { caminhos: pedido, modos, acrescentados: 0 }, texto));
        }
        let (todos, _) = caminhos_e_modos(QDC_ALL_PATHS).map_err(|e| format!("QueryDisplayConfig={e}"))?;
        let mut fontes: Vec<(LUID, u32)> = pedido.iter().map(|p| (p.sourceInfo.adapterId, p.sourceInfo.id)).collect();
        let mut acrescentados = 0usize;
        for (i, &alvo) in alvos.iter().enumerate() {
            if ativo_agora(alvo) {
                continue;
            }
            let livre = todos.iter().find(|p| {
                e_do_alvo(p, alvo)
                    && p.targetInfo.targetAvailable.as_bool()
                    && !fontes.iter().any(|&(l, s)| mesma_luid(l, p.sourceInfo.adapterId) && s == p.sourceInfo.id)
            });
            match livre {
                Some(p) => {
                    let mut c = *p;
                    c.flags = DISPLAYCONFIG_PATH_ACTIVE;
                    c.sourceInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
                    c.targetInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
                    fontes.push((c.sourceInfo.adapterId, c.sourceInfo.id));
                    pedido.push(c);
                    acrescentados += 1;
                }
                None if i == 0 => {
                    return Ok(Limpo::Esperar(format!("alvo {} sem caminho disponível com fonte livre", alvo.1)));
                }
                None => {}
            }
        }
        Ok(Limpo::Estender(Pedido { caminhos: pedido, modos, acrescentados }))
    }

    /// O monitor com este `monitorDevicePath` está ativo e disponível por um adaptador que não é o
    /// virtual? (O clone do Windows, §13.1.)
    pub fn ativo_fora_do_virtual(caminho_do_monitor: &str, adaptador_virtual: LUID) -> bool {
        let Ok(ps) = caminhos(true) else { return false };
        ps.iter().any(|p| {
            p.targetInfo.targetAvailable.as_bool()
                && !mesma_luid(p.targetInfo.adapterId, adaptador_virtual)
                && nome_completo(p.targetInfo.adapterId, p.targetInfo.id)
                    .is_ok_and(|(_, _, _, _, cam)| cam.eq_ignore_ascii_case(caminho_do_monitor))
        })
    }

    /// Os caminhos ativos são só os do usuário — nenhum velho, nenhum do adaptador virtual, nenhum
    /// monitor do SudoVDA? Para `--assentar`. Devolve (sim/não, o que viu fora).
    pub fn so_do_usuario(adaptador_virtual: LUID) -> Result<(bool, String), String> {
        let f = foto_do_usuario(adaptador_virtual)?;
        Ok((f.fora.is_empty(), f.fora))
    }

    /// De onde vêm os caminhos que o pedido devolve intocados (`--pedido`).
    #[derive(Clone, Copy, Debug, PartialEq)]
    pub enum Base {
        Todos,
        Ativos,
    }

    impl Base {
        pub fn nome(self) -> &'static str {
            match self {
                Base::Todos => "todos",
                Base::Ativos => "ativos",
            }
        }
    }

    /// Uma configuração pronta para a `SetDisplayConfig`.
    pub struct Pedido {
        pub caminhos: Vec<DISPLAYCONFIG_PATH_INFO>,
        pub modos: Vec<DISPLAYCONFIG_MODE_INFO>,
        pub acrescentados: usize,
    }

    impl Pedido {
        /// Os caminhos do pedido, curtos (os acrescentados são os últimos).
        pub fn descrever(&self) -> String {
            format!(
                "[{}] modos={}",
                self.caminhos.iter().map(curto).collect::<Vec<_>>().join(" | "),
                self.modos.len()
            )
        }
    }

    /// `SetDisplayConfig` com o pedido: `SDC_APPLY` ou só `SDC_VALIDATE` (nada muda na tela), sempre
    /// com `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES` e **sem** `SDC_SAVE_TO_DATABASE`.
    pub fn aplicar(p: &Pedido, so_validar: bool) -> i32 {
        let acao = if so_validar { SDC_VALIDATE } else { SDC_APPLY };
        unsafe {
            SetDisplayConfig(Some(&p.caminhos), Some(&p.modos), acao | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES)
        }
    }

    fn indice(i: u32) -> String {
        if i == DISPLAYCONFIG_PATH_MODE_IDX_INVALID {
            "-".into()
        } else {
            i.to_string()
        }
    }

    /// Um caminho em poucas letras, para a linha do tempo e os diagnósticos: `fonte>alvo` com a
    /// parte baixa do LUID em hexa, `av` = `targetAvailable`, `tst`/`sst` = `statusFlags` do alvo e
    /// da fonte, `fl` = `flags` do caminho, `m` = índices de modo da fonte e do alvo.
    pub fn curto(p: &DISPLAYCONFIG_PATH_INFO) -> String {
        let (mf, ma) = unsafe { (p.sourceInfo.Anonymous.modeInfoIdx, p.targetInfo.Anonymous.modeInfoIdx) };
        format!(
            "{:X}:{}>{:X}:{} av={} tst={:#x} sst={:#x} fl={:#x} m={}/{}",
            p.sourceInfo.adapterId.LowPart,
            p.sourceInfo.id,
            p.targetInfo.adapterId.LowPart,
            p.targetInfo.id,
            p.targetInfo.targetAvailable.as_bool() as u8,
            p.targetInfo.statusFlags,
            p.sourceInfo.statusFlags,
            p.flags,
            indice(mf),
            indice(ma)
        )
    }

    /// Os caminhos de um alvo no `QDC_ALL_PATHS`, curtos — o diagnóstico de quando a
    /// `SetDisplayConfig` falha.
    pub fn caminhos_do_alvo(luid: LUID, alvo: u32) -> String {
        match caminhos(false) {
            Err(e) => format!("QueryDisplayConfig={e}"),
            Ok(ps) => {
                let v: Vec<String> = ps
                    .iter()
                    .filter(|p| mesma_luid(p.targetInfo.adapterId, luid) && p.targetInfo.id == alvo)
                    .map(curto)
                    .collect();
                format!("{} [{}]", v.len(), v.join(" | "))
            }
        }
    }

    /// O `QDC_ONLY_ACTIVE_PATHS`, curto.
    pub fn so_ativos_curto() -> String {
        match caminhos(true) {
            Err(e) => format!("QueryDisplayConfig={e}"),
            Ok(ps) => ps.iter().map(curto).collect::<Vec<_>>().join(" | "),
        }
    }

    /// O que o `QDC_ALL_PATHS` marca ativo, curto.
    pub fn ativos_em_todos() -> String {
        match caminhos(false) {
            Err(e) => format!("QueryDisplayConfig={e}"),
            Ok(ps) => ps
                .iter()
                .filter(|p| p.flags & DISPLAYCONFIG_PATH_ACTIVE != 0)
                .map(curto)
                .collect::<Vec<_>>()
                .join(" | "),
        }
    }

    /// A topologia do banco (o Win+P da pessoa): `QueryDisplayConfig(QDC_DATABASE_CURRENT)`. Só
    /// lê; na sessão interativa.
    pub fn topologia() -> String {
        let flags = QDC_DATABASE_CURRENT;
        let (mut np, mut nm) = (0u32, 0u32);
        let e = unsafe { GetDisplayConfigBufferSizes(flags, &mut np, &mut nm) };
        if e != ERROR_SUCCESS {
            return format!("? (GetDisplayConfigBufferSizes={})", e.0);
        }
        let mut p = vec![DISPLAYCONFIG_PATH_INFO::default(); np as usize];
        let mut m = vec![DISPLAYCONFIG_MODE_INFO::default(); nm as usize];
        let mut t = DISPLAYCONFIG_TOPOLOGY_ID(0);
        let e = unsafe {
            QueryDisplayConfig(flags, &mut np, p.as_mut_ptr(), &mut nm, m.as_mut_ptr(), Some(&mut t as *mut DISPLAYCONFIG_TOPOLOGY_ID))
        };
        if e != ERROR_SUCCESS {
            return format!("? (QueryDisplayConfig={})", e.0);
        }
        let nome = match t {
            DISPLAYCONFIG_TOPOLOGY_INTERNAL => "INTERNAL (somente a tela do PC)",
            DISPLAYCONFIG_TOPOLOGY_CLONE => "CLONE (duplicar)",
            DISPLAYCONFIG_TOPOLOGY_EXTEND => "EXTEND (estender)",
            DISPLAYCONFIG_TOPOLOGY_EXTERNAL => "EXTERNAL (somente a segunda tela)",
            _ => "?",
        };
        format!("{} {nome} (caminhos no banco={})", t.0, np)
    }

    /// O `GET_TARGET_NAME` inteiro de um alvo: `(flags, tecnologia, instância do conector, nome
    /// amigável, monitorDevicePath)`, ou o código do erro.
    pub fn nome_completo(luid: LUID, alvo: u32) -> Result<(u32, i32, u32, String, String), i32> {
        let mut t = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
        t.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        t.header.size = size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
        t.header.adapterId = luid;
        t.header.id = alvo;
        let e = unsafe { DisplayConfigGetDeviceInfo(&mut t.header) };
        if e != ERROR_SUCCESS.0 as i32 {
            return Err(e);
        }
        let flags = unsafe { t.flags.Anonymous.value };
        Ok((
            flags,
            t.outputTechnology.0,
            t.connectorInstance,
            de_utf16(&t.monitorFriendlyDeviceName),
            de_utf16(&t.monitorDevicePath),
        ))
    }

    /// Uma fotografia do que o Windows diz, para a linha do tempo (`--linha-do-tempo`). Cada campo
    /// é um texto; o observador escreve o que mudou.
    #[derive(Default)]
    pub struct Foto {
        pub todos: String,
        pub ativos_todos: String,
        pub so_ativos: String,
        pub alvo: String,
        pub nome: String,
        pub caminho_do_monitor: String,
    }

    pub fn foto(alvo: Option<(LUID, u32)>) -> Foto {
        let mut f = Foto::default();
        match caminhos_e_modos(QDC_ALL_PATHS) {
            Err(e) => f.todos = format!("rc={e}"),
            Ok((ps, ms)) => {
                f.todos = format!("rc=0 caminhos={} modos={}", ps.len(), ms.len());
                f.ativos_todos = ps
                    .iter()
                    .filter(|p| p.flags & DISPLAYCONFIG_PATH_ACTIVE != 0)
                    .map(curto)
                    .collect::<Vec<_>>()
                    .join(" | ");
                if let Some((l, t)) = alvo {
                    let dele: Vec<&DISPLAYCONFIG_PATH_INFO> =
                        ps.iter().filter(|p| mesma_luid(p.targetInfo.adapterId, l) && p.targetInfo.id == t).collect();
                    let disp = dele.iter().filter(|p| p.targetInfo.targetAvailable.as_bool()).count();
                    let st = dele.iter().fold(0u32, |a, p| a | p.targetInfo.statusFlags);
                    let at = dele.iter().filter(|p| p.flags & DISPLAYCONFIG_PATH_ACTIVE != 0).map(|p| curto(p)).collect::<Vec<_>>();
                    f.alvo = format!(
                        "{:X}:{} caminhos={} disp={} tst={:#x} ativo={}",
                        l.LowPart,
                        t,
                        dele.len(),
                        disp,
                        st,
                        if at.is_empty() { "nao".to_string() } else { at.join(" | ") }
                    );
                }
            }
        }
        f.so_ativos = match caminhos(true) {
            Ok(ps) => ps.iter().map(curto).collect::<Vec<_>>().join(" | "),
            Err(e) => format!("rc={e}"),
        };
        if let Some((l, t)) = alvo {
            match nome_completo(l, t) {
                Ok((fl, tec, con, nome, cam)) => {
                    f.nome = format!("rc=0 fl={fl:#x} tec={tec} conector={con} nome=\"{nome}\" dev={}", if cam.is_empty() { "vazio" } else { "sim" });
                    f.caminho_do_monitor = cam;
                }
                Err(e) => f.nome = format!("rc={e}"),
            }
        }
        f
    }

    /// O nome amigável (do EDID) e o `monitorDevicePath` de um alvo, pelo par que o `ADD` devolve.
    /// Funciona com o alvo ativo ou não: é a primeira testemunha de que o monitor chegou, e a
    /// última de que ele saiu. O erro volta com o código de `DisplayConfigGetDeviceInfo`.
    pub fn nome_do_alvo(luid: LUID, alvo: u32) -> Result<(String, String), i32> {
        let mut t = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
        t.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        t.header.size = size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
        t.header.adapterId = luid;
        t.header.id = alvo;
        let e = unsafe { DisplayConfigGetDeviceInfo(&mut t.header) };
        if e != ERROR_SUCCESS.0 as i32 {
            return Err(e);
        }
        Ok((de_utf16(&t.monitorFriendlyDeviceName), de_utf16(&t.monitorDevicePath)))
    }

    fn nome_gdi_da_fonte(luid: LUID, id: u32) -> Option<String> {
        let mut s = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
        s.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        s.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
        s.header.adapterId = luid;
        s.header.id = id;
        if unsafe { DisplayConfigGetDeviceInfo(&mut s.header) } != ERROR_SUCCESS.0 as i32 {
            return None;
        }
        let g = de_utf16(&s.viewGdiDeviceName);
        (!g.is_empty()).then_some(g)
    }

    pub struct Ativo {
        pub gdi: String,
        /// A frequência do alvo como o `DisplayConfig` a guarda (numerador, denominador).
        pub vsync: (u32, u32),
    }

    /// **O casamento pedido no §7**: o caminho ativo cujo alvo é o par `AdapterLuid` + `TargetId`
    /// que o `ADD` devolveu, e o nome GDI da fonte desse caminho. `Ok(None)` = não há caminho ativo
    /// para ele; `Err` = não deu para perguntar (inclusive o nome da fonte que não veio).
    pub fn caminho_ativo(luid: LUID, alvo: u32) -> Result<Option<Ativo>, u32> {
        let ps = caminhos(true)?;
        let Some(p) = ps.iter().find(|p| mesma_luid(p.targetInfo.adapterId, luid) && p.targetInfo.id == alvo) else {
            return Ok(None);
        };
        let gdi = nome_gdi_da_fonte(p.sourceInfo.adapterId, p.sourceInfo.id).ok_or(0u32)?;
        Ok(Some(Ativo { gdi, vsync: (p.targetInfo.refreshRate.Numerator, p.targetInfo.refreshRate.Denominator) }))
    }

    /// (o alvo aparece em algum caminho?, algum desses caminhos tem `targetAvailable`?) — `None`
    /// quando não deu para perguntar.
    pub fn situacao_do_alvo(luid: LUID, alvo: u32) -> (Option<bool>, Option<bool>) {
        match caminhos(false) {
            Err(_) => (None, None),
            Ok(ps) => {
                let dele = ps.iter().filter(|p| mesma_luid(p.targetInfo.adapterId, luid) && p.targetInfo.id == alvo);
                let (mut algum, mut disp) = (false, false);
                for p in dele {
                    algum = true;
                    disp |= p.targetInfo.targetAvailable.as_bool();
                }
                (Some(algum), Some(disp))
            }
        }
    }

    /// O alvo aparece em algum caminho, ativo ou não? `None` se não deu para perguntar.
    pub fn alvo_em_algum_caminho(luid: LUID, alvo: u32) -> Option<bool> {
        caminhos(false)
            .ok()
            .map(|ps| ps.iter().any(|p| mesma_luid(p.targetInfo.adapterId, luid) && p.targetInfo.id == alvo))
    }

    /// Os caminhos ativos de agora, como `\\.\DISPLAYn "nome amigável"` — a linha de base.
    pub fn resumo_dos_ativos() -> String {
        let ps = match caminhos(true) {
            Ok(ps) => ps,
            Err(e) => return format!("(QueryDisplayConfig falhou: {e})"),
        };
        let v: Vec<String> = ps
            .iter()
            .map(|p| {
                let g = nome_gdi_da_fonte(p.sourceInfo.adapterId, p.sourceInfo.id).unwrap_or_else(|| "?".into());
                let n = nome_do_alvo(p.targetInfo.adapterId, p.targetInfo.id).map(|x| x.0).unwrap_or_default();
                format!("{g} \"{n}\"")
            })
            .collect();
        format!("{} [{}]", v.len(), v.join(" | "))
    }

    /// Os monitores na enumeração do GDI: nome, `HMONITOR` e retângulo (pixels físicos, porque o
    /// processo é "per monitor v2"). `None` quando o próprio `EnumDisplayMonitors` falha.
    pub fn monitores_gdi() -> Option<Vec<(String, HMONITOR, RECT)>> {
        let mut achados: Vec<(String, HMONITOR, RECT)> = Vec::new();
        let ok = unsafe {
            EnumDisplayMonitors(
                None,
                None,
                Some(retorno),
                LPARAM(&mut achados as *mut Vec<(String, HMONITOR, RECT)> as isize),
            )
        };
        ok.as_bool().then_some(achados)
    }

    unsafe extern "system" fn retorno(h: HMONITOR, _hdc: HDC, _r: *mut RECT, dados: LPARAM) -> BOOL {
        let lista = unsafe { &mut *(dados.0 as *mut Vec<(String, HMONITOR, RECT)>) };
        if let Some(info) = info_do_monitor(h) {
            lista.push((de_utf16(&info.szDevice), h, info.monitorInfo.rcMonitor));
        }
        BOOL(1)
    }

    /// O monitor pelo nome GDI. Falha da enumeração conta como "não achei" — quem usa isto para
    /// **proteger** (a carga) quer esse lado; quem usa para **testemunhar** chama [`na_enumeracao`].
    pub fn hmonitor_de(gdi: &str) -> Option<(HMONITOR, RECT)> {
        monitores_gdi()?.into_iter().find(|(n, _, _)| n == gdi).map(|(_, h, r)| (h, r))
    }

    /// O nome GDI está na enumeração? `Err` quando a enumeração falhou.
    pub fn na_enumeracao(gdi: &str) -> Result<bool, ()> {
        monitores_gdi().map(|v| v.iter().any(|(n, _, _)| n == gdi)).ok_or(())
    }

    fn modo(gdi: &str, i: ENUM_DISPLAY_SETTINGS_MODE) -> Option<(u32, u32, u32)> {
        let l = largo(gdi);
        let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
        let ok = unsafe { EnumDisplaySettingsExW(PCWSTR(l.as_ptr()), i, &mut dm, ENUM_DISPLAY_SETTINGS_FLAGS(0)) };
        ok.as_bool().then_some((dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency))
    }

    pub fn modo_atual(gdi: &str) -> Option<(u32, u32, u32)> {
        modo(gdi, ENUM_CURRENT_SETTINGS)
    }

    /// Os modos que o Windows oferece para o monitor (`EnumDisplaySettingsExW` sem `EDS_RAWMODE`:
    /// os que a pessoa veria em Configurações), sem repetição.
    pub fn modos_oferecidos(gdi: &str) -> Vec<(u32, u32, u32)> {
        let mut v = Vec::new();
        for i in 0..20_000u32 {
            match modo(gdi, ENUM_DISPLAY_SETTINGS_MODE(i)) {
                Some(m) => {
                    if !v.contains(&m) {
                        v.push(m);
                    }
                }
                None => break,
            }
        }
        v
    }

    /// A escala que o Windows escolheu, em %: o DPI efetivo sobre 96.
    pub fn escala(h: HMONITOR) -> Option<u32> {
        let (mut x, mut y) = (0u32, 0u32);
        unsafe { GetDpiForMonitor(h, MDT_EFFECTIVE_DPI, &mut x, &mut y) }.ok()?;
        Some((x * 100 + 48) / 96)
    }

    pub struct Placa {
        pub descricao: String,
        pub fornecedor: u32,
        pub luid: LUID,
    }

    fn adaptadores() -> Vec<(IDXGIAdapter1, Placa)> {
        let Ok(f) = (unsafe { CreateDXGIFactory1::<IDXGIFactory1>() }) else { return Vec::new() };
        let mut v = Vec::new();
        let mut i = 0u32;
        while let Ok(a) = unsafe { f.EnumAdapters1(i) } {
            if let Ok(d) = unsafe { a.GetDesc1() } {
                v.push((a, Placa { descricao: de_utf16(&d.Description), fornecedor: d.VendorId, luid: d.AdapterLuid }));
            }
            i += 1;
        }
        v
    }

    pub fn placas() -> Vec<Placa> {
        adaptadores().into_iter().map(|(_, p)| p).collect()
    }

    /// **A testemunha da placa que desenha o monitor**, que o retorno do `SET_RENDER_ADAPTER` não
    /// é: o adaptador DXGI sob o qual a saída `\\.\DISPLAYn` do monitor virtual é enumerada. Fábrica
    /// nova a cada pergunta, porque a do DXGI guarda a lista de saídas do instante em que nasceu.
    /// Que um monitor IDD aparece como saída do adaptador que o desenha é o que se espera do
    /// IddCx — **não conferido**; se não aparecer em adaptador nenhum, a linha diz `?`.
    pub fn placa_que_desenha(gdi: &str) -> Option<Placa> {
        for (a, p) in adaptadores() {
            let mut j = 0u32;
            while let Ok(o) = unsafe { a.EnumOutputs(j) } {
                if let Ok(d) = unsafe { o.GetDesc() } {
                    if de_utf16(&d.DeviceName) == gdi {
                        return Some(p);
                    }
                }
                j += 1;
            }
        }
        None
    }
}

fn info_do_monitor(h: HMONITOR) -> Option<MONITORINFOEXW> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    let ok = unsafe { GetMonitorInfoW(h, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) };
    ok.as_bool().then_some(info)
}

/// O monitor em que uma janela está agora, pelo nome GDI.
fn monitor_da_janela(hwnd: HWND) -> Option<String> {
    let h = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL) };
    if h.is_invalid() {
        return None;
    }
    info_do_monitor(h).map(|i| de_utf16(&i.szDevice))
}

// ================================================================================================
// A linha do tempo (`--linha-do-tempo`): o que o Windows diz do alvo, de N em N ms
// ================================================================================================

mod mesa {
    //! O desktop de entrada. Com a sessão bloqueada, o Ctrl+Alt+Del ou a tela segura do UAC, ele
    //! deixa de ser `Default` — e a `SetDisplayConfig` devolve `ERROR_ACCESS_DENIED` a quem não o
    //! alcança (a documentação dela diz isso). FFI direto no `user32` para não acrescentar uma
    //! feature ao crate `windows` só por duas funções.
    use std::ffi::c_void;

    #[link(name = "user32")]
    extern "system" {
        fn OpenInputDesktop(flags: u32, herdar: i32, acesso: u32) -> *mut c_void;
        fn GetUserObjectInformationW(h: *mut c_void, indice: i32, buf: *mut c_void, n: u32, preciso: *mut u32) -> i32;
        fn CloseDesktop(h: *mut c_void) -> i32;
    }
    const UOI_NAME: i32 = 2;
    const DESKTOP_READOBJECTS: u32 = 0x0001;

    pub fn nome() -> String {
        unsafe {
            let h = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS);
            if h.is_null() {
                return format!("? (OpenInputDesktop erro {})", windows::Win32::Foundation::GetLastError().0);
            }
            let mut buf = [0u16; 64];
            let mut n = 0u32;
            let ok = GetUserObjectInformationW(h, UOI_NAME, buf.as_mut_ptr() as *mut c_void, (buf.len() * 2) as u32, &mut n);
            let _ = CloseDesktop(h);
            if ok == 0 {
                return format!("? (GetUserObjectInformationW erro {})", windows::Win32::Foundation::GetLastError().0);
            }
            super::de_utf16(&buf)
        }
    }
}

mod sistema {
    //! Os handles e a memória do `dwm` e dos `WUDFHost` (um deles hospeda o SudoVDA), lidos pela
    //! mesma fonte do `Get-Process` — `NtQuerySystemInformation(SystemProcessInformation)` —, sem
    //! abrir processo nenhum (o `WUDFHost` é do LocalService, na Sessão 0). É o que o §13 pede para
    //! medir a inclinação: quantos handles ficam para trás por monitor criado e tirado.
    //!
    //! O leiaute é o de `SYSTEM_PROCESS_INFORMATION` no x64 (`winternl.h`): `NextEntryOffset` em 0,
    //! `ImageName` (UNICODE_STRING) em 0x38, `UniqueProcessId` em 0x50, `HandleCount` em 0x60,
    //! `WorkingSetSize` em 0x90.
    use std::ffi::c_void;

    #[link(name = "ntdll")]
    extern "system" {
        fn NtQuerySystemInformation(classe: u32, buf: *mut c_void, tam: u32, devolvido: *mut u32) -> i32;
    }
    const SYSTEM_PROCESS_INFORMATION: u32 = 5;
    const STATUS_INFO_LENGTH_MISMATCH: i32 = 0xC000_0004u32 as i32;

    pub struct Processo {
        pub nome: String,
        pub pid: usize,
        pub handles: u32,
        pub ws_mb: f64,
    }

    fn ler<const N: usize>(b: &[u8], i: usize) -> Option<[u8; N]> {
        b.get(i..i + N).and_then(|s| s.try_into().ok())
    }

    pub fn processos() -> Vec<Processo> {
        let mut tam = 1usize << 20;
        loop {
            // u64 para o buffer sair alinhado a 8, como o kernel espera.
            let mut buf = vec![0u64; tam / 8];
            let mut devolvido = 0u32;
            let st = unsafe {
                NtQuerySystemInformation(SYSTEM_PROCESS_INFORMATION, buf.as_mut_ptr() as *mut c_void, tam as u32, &mut devolvido)
            };
            if st == STATUS_INFO_LENGTH_MISMATCH && tam < (64 << 20) {
                tam *= 2;
                continue;
            }
            if st != 0 {
                return Vec::new();
            }
            let b: &[u8] = unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const u8, tam) };
            let mut v = Vec::new();
            let mut off = 0usize;
            while let (Some(prox), Some(len), Some(ptr), Some(pid), Some(h), Some(ws)) = (
                ler::<4>(b, off).map(u32::from_le_bytes),
                ler::<2>(b, off + 0x38).map(u16::from_le_bytes),
                ler::<8>(b, off + 0x40).map(usize::from_le_bytes),
                ler::<8>(b, off + 0x50).map(usize::from_le_bytes),
                ler::<4>(b, off + 0x60).map(u32::from_le_bytes),
                ler::<8>(b, off + 0x90).map(usize::from_le_bytes),
            ) {
                // O nome aponta para dentro do próprio buffer.
                let base = b.as_ptr() as usize;
                let nome = if ptr >= base && ptr + len as usize <= base + tam && len > 0 {
                    let s = unsafe { std::slice::from_raw_parts(ptr as *const u16, len as usize / 2) };
                    String::from_utf16_lossy(s)
                } else {
                    String::new()
                };
                v.push(Processo { nome, pid, handles: h, ws_mb: ws as f64 / 1048576.0 });
                if prox == 0 {
                    break;
                }
                off += prox as usize;
            }
            return v;
        }
    }

    /// `dwm=1307h/139MB wudf=[1500:271 1804:394 …]`.
    pub fn resumo() -> String {
        let ps = processos();
        if ps.is_empty() {
            return "? (NtQuerySystemInformation falhou)".into();
        }
        let dwm: Vec<String> = ps
            .iter()
            .filter(|p| p.nome.eq_ignore_ascii_case("dwm.exe"))
            .map(|p| format!("{}h/{:.0}MB", p.handles, p.ws_mb))
            .collect();
        let wudf: Vec<String> = ps
            .iter()
            .filter(|p| p.nome.eq_ignore_ascii_case("WUDFHost.exe"))
            .map(|p| format!("{}:{}", p.pid, p.handles))
            .collect();
        format!("dwm={} wudf=[{}]", dwm.join(","), wudf.join(" "))
    }
}

mod observador {
    //! Um fio que fotografa, de N em N ms, o que o Windows diz do alvo corrente — o
    //! `QDC_ALL_PATHS` (caminhos do alvo, quantos disponíveis, os `statusFlags`, o que está marcado
    //! ativo), o `QDC_ONLY_ACTIVE_PATHS`, o `GET_TARGET_NAME`, o nó PnP do monitor e o desktop de
    //! entrada — e escreve **só o que mudou**, numa linha `tl c=<ciclo> +<ms> <campo>: <valor>`. O
    //! eixo é o do ciclo (zero no ADD), o mesmo das linhas `ev` que o fio principal escreve. É o
    //! instrumento do §13: achar o sinal de "pronto" de um nascimento.
    //!
    //! **Nenhum IOCTL** — não recarrega o vigia nem mexe no driver. As leituras de `DisplayConfig`
    //! podem disputar a trava do CCD com a `SetDisplayConfig` do fio principal; por isso ele é
    //! opcional, e toda receita é conferida também sem ele.

    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;
    use std::time::{Duration, Instant};

    use windows::Win32::Foundation::LUID;

    use super::{mesa, pnp, telas};

    /// O ciclo corrente e o instante do ADD dele.
    pub static CICLO: Mutex<Option<(u32, Instant)>> = Mutex::new(None);
    /// O alvo que o observador olha (o do último ADD).
    pub static ALVO: Mutex<Option<(LUID, u32)>> = Mutex::new(None);
    /// O observador está rodando — as linhas `ev` só saem com ele.
    pub static LIGADO: AtomicBool = AtomicBool::new(false);

    /// `c=3 +1234`: o ciclo e os ms desde o ADD dele.
    pub fn marca() -> String {
        match CICLO.lock().ok().and_then(|g| *g) {
            Some((c, t)) => format!("c={c} +{}", t.elapsed().as_millis()),
            None => "c=- +0".into(),
        }
    }

    pub fn novo_ciclo(c: u32) {
        if let Ok(mut g) = CICLO.lock() {
            *g = Some((c, Instant::now()));
        }
    }

    pub fn olhar(luid: LUID, alvo: u32) {
        if let Ok(mut g) = ALVO.lock() {
            *g = Some((luid, alvo));
        }
    }

    pub struct Observador {
        parar: Arc<AtomicBool>,
        fio: Option<JoinHandle<u64>>,
    }

    impl Observador {
        pub fn iniciar(passo: Duration) -> Self {
            let parar = Arc::new(AtomicBool::new(false));
            let p2 = parar.clone();
            LIGADO.store(true, Ordering::SeqCst);
            let fio = std::thread::spawn(move || {
                let mut ultimos: Vec<String> = vec![String::new(); 7];
                let mut caminho_ult = String::new();
                let mut instancia: Option<String> = None;
                let mut fotos = 0u64;
                while !p2.load(Ordering::SeqCst) {
                    let t = Instant::now();
                    let alvo = ALVO.lock().ok().and_then(|g| *g);
                    let f = telas::foto(alvo);
                    if !f.caminho_do_monitor.is_empty() && f.caminho_do_monitor != caminho_ult {
                        caminho_ult = f.caminho_do_monitor.clone();
                        instancia = pnp::instancia_da_interface(&caminho_ult).or(instancia.take());
                    }
                    let estado_pnp = match &instancia {
                        None => "-".to_string(),
                        Some(i) => match pnp::estado(i) {
                            Some((true, iniciado, problema)) => format!(
                                "{i} presente {}{}",
                                if iniciado { "iniciado" } else { "parado" },
                                if problema != 0 { format!(" problema={problema}") } else { String::new() }
                            ),
                            Some((false, _, _)) => format!("{i} ausente"),
                            None => format!("{i} ?"),
                        },
                    };
                    let campos = [
                        ("qdc", f.todos),
                        ("ativos_em_todos", f.ativos_todos),
                        ("so_ativos", f.so_ativos),
                        ("alvo", f.alvo),
                        ("nome", f.nome),
                        ("pnp", estado_pnp),
                        ("mesa", mesa::nome()),
                    ];
                    for (i, (nome, v)) in campos.into_iter().enumerate() {
                        if ultimos[i] != v {
                            diga!("tl {} {nome}: {v}", marca());
                            ultimos[i] = v;
                        }
                    }
                    fotos += 1;
                    if let Some(resto) = passo.checked_sub(t.elapsed()) {
                        std::thread::sleep(resto);
                    }
                }
                fotos
            });
            Self { parar, fio: Some(fio) }
        }

        pub fn parar(&mut self) -> Option<u64> {
            self.parar.store(true, Ordering::SeqCst);
            LIGADO.store(false, Ordering::SeqCst);
            self.fio.take().and_then(|f| f.join().ok())
        }
    }

    impl Drop for Observador {
        fn drop(&mut self) {
            let _ = self.parar();
        }
    }
}

/// Uma linha `ev c=<ciclo> +<ms> …` no eixo da linha do tempo — só com o observador ligado.
macro_rules! evento {
    ($($t:tt)*) => {{
        if crate::observador::LIGADO.load(std::sync::atomic::Ordering::SeqCst) {
            let texto = format!($($t)*);
            diga!("ev {} {}", crate::observador::marca(), texto);
        }
    }};
}

// ================================================================================================
// A captura: Windows.Graphics.Capture contando quadros, sem abrir nenhum
// ================================================================================================

mod captura {
    use std::sync::atomic::{AtomicI64, Ordering};
    use std::sync::{Arc, Mutex};

    use windows::core::{IInspectable, Interface, Result};
    use windows::Foundation::{TimeSpan, TypedEventHandler};
    use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
    use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
    use windows::Graphics::DirectX::DirectXPixelFormat;
    use windows::Win32::Graphics::Direct3D11::ID3D11Device;
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    use windows::Win32::Graphics::Gdi::HMONITOR;
    use windows::Win32::System::WinRT::Direct3D11::CreateDirect3D11DeviceFromDXGIDevice;
    use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

    use super::{percentil, relogio};

    /// Uma captura de monitor que só **conta**. Cada quadro que chega tem o carimbo de composição
    /// (`SystemRelativeTime`) e o instante de chegada anotados, e é fechado na mesma hora — a
    /// superfície nunca é pedida, então nenhum pixel passa por este processo.
    pub struct Captura {
        _item: GraphicsCaptureItem,
        pool: Direct3D11CaptureFramePool,
        sessao: GraphicsCaptureSession,
        /// (composição, chegada), em 100 ns do QPC.
        pub quadros: Arc<Mutex<Vec<(i64, i64)>>>,
        /// Quando o `Closed` do item disparou (0 = não disparou). Em 2026-08 ele **não disparou**
        /// com um monitor físico desligado (`docs/app-windows.md:662`); aqui é medido de novo.
        pub fechado_em: Arc<AtomicI64>,
        pub inicio: i64,
    }

    impl Captura {
        pub fn iniciar(dispositivo: &ID3D11Device, h: HMONITOR, hz_max: Option<u32>) -> Result<Self> {
            let dxgi: IDXGIDevice = dispositivo.cast()?;
            let winrt: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)? }.cast()?;
            let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
            diga!("captura: passo CreateForMonitor");
            let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(h)? };
            diga!("captura: passo pool");
            let tamanho = item.Size()?;
            let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                &winrt,
                DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2,
                tamanho,
            )?;
            let quadros: Arc<Mutex<Vec<(i64, i64)>>> = Arc::new(Mutex::new(Vec::with_capacity(8192)));
            let anotar = quadros.clone();
            pool.FrameArrived(&TypedEventHandler::<Direct3D11CaptureFramePool, IInspectable>::new(
                move |pool, _| {
                    if let Some(pool) = pool.as_ref() {
                        if let Ok(q) = pool.TryGetNextFrame() {
                            let chegada = relogio::agora_100ns();
                            let composicao = q.SystemRelativeTime().map(|t| t.Duration).unwrap_or(0);
                            let _ = q.Close();
                            if let Ok(mut v) = anotar.lock() {
                                v.push((composicao, chegada));
                            }
                        }
                    }
                    Ok(())
                },
            ))?;
            let fechado_em = Arc::new(AtomicI64::new(0));
            let marcar = fechado_em.clone();
            item.Closed(&TypedEventHandler::<GraphicsCaptureItem, IInspectable>::new(move |_, _| {
                marcar.store(relogio::agora_100ns(), Ordering::SeqCst);
                Ok(())
            }))?;
            let sessao = pool.CreateCaptureSession(&item)?;
            // O cursor fora: um quadro por movimento do mouse de quem está no Dell contaminaria a
            // contagem, que é do conteúdo.
            let _ = sessao.SetIsCursorCaptureEnabled(false);
            if let Some(hz) = hz_max {
                if let Err(e) = sessao.SetMinUpdateInterval(TimeSpan { Duration: 10_000_000 / hz.max(1) as i64 }) {
                    diga!("aviso: SetMinUpdateInterval({hz} Hz) falhou: {e} — a captura segue sem teto");
                }
            }
            let inicio = relogio::agora_100ns();
            diga!("captura: passo StartCapture");
            sessao.StartCapture()?;
            Ok(Self { _item: item, pool, sessao, quadros, fechado_em, inicio })
        }

        pub fn parar(&self) {
            let _ = self.sessao.Close();
            let _ = self.pool.Close();
        }

        pub fn copia(&self) -> Vec<(i64, i64)> {
            self.quadros.lock().map(|v| v.clone()).unwrap_or_default()
        }
    }

    /// `captura: quadros=… q/s=… intervalo p50/p95=…` sobre a janela [de, ate] (100 ns do QPC).
    pub fn resumo(q: &[(i64, i64)], de: i64, ate: i64) -> String {
        let sel: Vec<(i64, i64)> = q
            .iter()
            .map(|&(c, r)| (if c > 0 { c } else { r }, r))
            .filter(|&(c, _)| c >= de && c <= ate)
            .collect();
        let segundos = ((ate - de) as f64 / 1e7).max(1e-3);
        let intervalos: Vec<f64> = sel.windows(2).map(|w| (w[1].0 - w[0].0) as f64 / 1e4).collect();
        let latencias: Vec<f64> = sel.iter().map(|&(c, r)| (r - c) as f64 / 1e4).collect();
        let max = intervalos.iter().cloned().fold(f64::NAN, f64::max);
        format!(
            "quadros={} q/s={:.1} intervalo p50/p95={}/{} ms max={} ms latencia p50/p95={}/{} ms em {:.1} s",
            sel.len(),
            sel.len() as f64 / segundos,
            num(percentil(&intervalos, 0.5)),
            num(percentil(&intervalos, 0.95)),
            num(max),
            num(percentil(&latencias, 0.5)),
            num(percentil(&latencias, 0.95)),
            segundos
        )
    }

    /// Um número de milissegundos, ou `-` quando não há amostra.
    fn num(x: f64) -> String {
        if x.is_nan() {
            "-".into()
        } else {
            format!("{x:.1}")
        }
    }

    /// O maior buraco entre quadros perto de um evento (nascer ou sair outro monitor) — a
    /// pergunta E. A janela vai de 100 ms antes a 1,5 s depois do evento.
    pub fn maior_buraco_perto(q: &[(i64, i64)], evento: i64) -> Option<f64> {
        let de = evento - 1_000_000;
        let ate = evento + 15_000_000;
        let c: Vec<i64> = q.iter().map(|&(c, r)| if c > 0 { c } else { r }).collect();
        c.windows(2)
            .filter(|w| w[1] >= de && w[0] <= ate)
            .map(|w| (w[1] - w[0]) as f64 / 1e4)
            .fold(None, |m, x| Some(m.map_or(x, |m: f64| m.max(x))))
    }
}

// ================================================================================================
// A carga: uma janela nossa, sintética, no monitor virtual
// ================================================================================================

mod carga {
    //! A janela é `WS_EX_TOPMOST` e cobre um monitor inteiro: a regra desta sonda é que ela **ou está
    //! no monitor virtual, ou não existe** — nunca sobre um monitor do usuário. Quatro camadas:
    //!
    //! 1. nasce **escondida**, e só aparece depois de conferida (monitor e retângulo) e desenhada;
    //! 2. o procedimento **veta** todo movimento e redimensionamento que não seja dela
    //!    (`WM_WINDOWPOSCHANGING`): quando um monitor sai, o Windows muda as janelas dele para outro —
    //!    esta fica onde está, fora da tela;
    //! 3. **antes de cada quadro** confere que o monitor ainda existe e que a janela ocupa exatamente o
    //!    retângulo dele; se o monitor andou (outro nasceu, pergunta E), ela se esconde, vai para o
    //!    lugar novo e volta; se ele sumiu ou mudou de tamanho, ela é destruída;
    //! 4. se o fio não responder no prazo, **o processo encerra**: a janela morre com ele, antes de o
    //!    vigia do SudoVDA tirar o monitor (2–3 s sem ping).

    use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
    use std::sync::{mpsc, Arc};
    use std::thread::JoinHandle;
    use std::time::{Duration, Instant};

    use windows::core::{w, Interface};
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
    use windows::Win32::Graphics::Direct3D11::{
        ID3D11Device, ID3D11DeviceContext1, ID3D11RenderTargetView, ID3D11Texture2D, ID3D11View,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::Win32::Graphics::Dxgi::{
        IDXGIDevice, IDXGIFactory2, IDXGISwapChain1, DXGI_PRESENT, DXGI_SWAP_CHAIN_DESC1,
        DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_USAGE_RENDER_TARGET_OUTPUT,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetWindowRect,
        PeekMessageW, PostMessageW, PostQuitMessage, RegisterClassExW, SetWindowPos, ShowWindow,
        TranslateMessage, HWND_TOPMOST, MA_NOACTIVATE, MSG, PM_REMOVE, SWP_NOACTIVATE, SWP_NOMOVE,
        SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, WINDOWPOS, WM_CLOSE, WM_DESTROY, WM_DISPLAYCHANGE,
        WM_DPICHANGED, WM_ERASEBKGND, WM_MOUSEACTIVATE, WM_PAINT, WM_QUIT, WM_WINDOWPOSCHANGING,
        WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    };

    use quall_capture_probe::device;

    use super::{monitor_da_janela, relogio, telas};

    #[derive(Clone, Copy, Debug, PartialEq)]
    pub enum Modo {
        /// Desenha uma vez e fica parada: o monitor não muda, e o DWM não tem o que recompor.
        Parada,
        /// Redesenha a cada quadro (um `Present` com espera de retraço por volta) — o caso de uma
        /// rolagem, como o `camadas` da carga do Mac (`tools/tela-estendida/janela-em-movimento.swift`).
        Camadas,
    }

    impl Modo {
        pub fn nome(self) -> &'static str {
            match self {
                Modo::Parada => "parada",
                Modo::Camadas => "camadas",
            }
        }
    }

    #[derive(Default)]
    pub struct Relato {
        pub quadros: u64,
        pub por_segundo: Vec<u32>,
        pub falhas_de_present: u64,
        /// Quantas vezes o monitor andou e a janela foi atrás.
        pub mudancas_de_lugar: u32,
        /// Por que a janela acabou antes de pedirem (o monitor sumiu, mudou de tamanho…), e quando
        /// (100 ns do QPC) — a partir daí os buracos da captura não são mais da carga.
        pub acabou_sozinha: Option<(String, i64)>,
    }

    pub struct Carga {
        fio: Option<JoinHandle<Relato>>,
        parar: Arc<AtomicBool>,
        hwnd: Arc<AtomicIsize>,
    }

    /// Uma carga por processo (só o 1º monitor tem carga), então os sinais do procedimento de
    /// janela para o laço podem ser estáticos.
    static PEDIU_FECHAR: AtomicBool = AtomicBool::new(false);
    static MOVER_PERMITIDO: AtomicBool = AtomicBool::new(true);
    static TOPOLOGIA_MUDOU: AtomicBool = AtomicBool::new(false);

    unsafe extern "system" fn procedimento(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        match msg {
            // O fechar só marca: quem destrói é o laço, com a swap chain já solta.
            WM_CLOSE => {
                PEDIU_FECHAR.store(true, Ordering::SeqCst);
                LRESULT(0)
            }
            WM_DESTROY => {
                unsafe { PostQuitMessage(0) };
                LRESULT(0)
            }
            // **O veto**: ninguém além da própria carga move ou redimensiona a janela. Esconder e
            // mostrar continuam passando (não são movimento).
            WM_WINDOWPOSCHANGING => {
                if !MOVER_PERMITIDO.load(Ordering::SeqCst) {
                    let pos = lp.0 as *mut WINDOWPOS;
                    if !pos.is_null() {
                        unsafe { (*pos).flags |= SWP_NOMOVE | SWP_NOSIZE };
                    }
                }
                unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
            }
            WM_DISPLAYCHANGE | WM_DPICHANGED => {
                TOPOLOGIA_MUDOU.store(true, Ordering::SeqCst);
                LRESULT(0)
            }
            // A pessoa no Dell pode clicar no monitor virtual; a janela não rouba o foco.
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                unsafe {
                    let _ = windows::Win32::Graphics::Gdi::ValidateRect(Some(hwnd), None);
                }
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
        }
    }

    /// Encerra o processo porque a janela da carga não responde. É o último recurso da regra: a
    /// janela morre com o processo, o fio de ping também, e o vigia tira o monitor 2–3 s depois.
    fn encerrar_por_seguranca(motivo: &str) -> ! {
        diga!("carga: {motivo}; encerro o processo por segurança — a janela morre com ele, e o vigia do SudoVDA tira o monitor em 2–3 s");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        unsafe {
            let _ = windows::Win32::System::Threading::TerminateProcess(
                windows::Win32::System::Threading::GetCurrentProcess(),
                98,
            );
        }
        std::process::exit(98);
    }

    fn esperar_o_fio(fio: &JoinHandle<Relato>, prazo: Duration) -> bool {
        let t = Instant::now();
        while !fio.is_finished() {
            if t.elapsed() >= prazo {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    /// Abre a carga no monitor `gdi`, desenhando na placa `fornecedor`. Devolve depois de a janela
    /// existir, **estar no monitor certo** e ter o primeiro quadro; se ela cair em outro, é
    /// destruída sem aparecer.
    pub fn iniciar(modo: Modo, gdi: &str, fornecedor: u32) -> Result<(Carga, String), String> {
        PEDIU_FECHAR.store(false, Ordering::SeqCst);
        TOPOLOGIA_MUDOU.store(false, Ordering::SeqCst);
        let parar = Arc::new(AtomicBool::new(false));
        let hwnd = Arc::new(AtomicIsize::new(0));
        let (tx, rx) = mpsc::channel::<Result<String, String>>();
        let (p2, h2, g2) = (parar.clone(), hwnd.clone(), gdi.to_string());
        let fio = std::thread::Builder::new()
            .name("carga".into())
            .spawn(move || fio(modo, &g2, fornecedor, p2, h2, tx))
            .map_err(|e| format!("carga: não consegui criar o fio: {e}"))?;
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(linha)) => Ok((Carga { fio: Some(fio), parar, hwnd }, linha)),
            Ok(Err(e)) => {
                let _ = fio.join();
                Err(e)
            }
            Err(_) => {
                let mut c = Carga { fio: Some(fio), parar, hwnd };
                c.pedir_fim();
                let saiu = c.fio.as_ref().is_some_and(|f| esperar_o_fio(f, Duration::from_secs(3)));
                if !saiu {
                    encerrar_por_seguranca("a janela não ficou pronta em 5 s e o fio não saiu em mais 3");
                }
                if let Some(f) = c.fio.take() {
                    let _ = f.join();
                }
                Err("carga: a janela não ficou pronta em 5 s (o fio saiu sem ela)".into())
            }
        }
    }

    impl Carga {
        fn pedir_fim(&self) {
            self.parar.store(true, Ordering::SeqCst);
            let h = self.hwnd.load(Ordering::SeqCst);
            if h != 0 {
                unsafe {
                    let _ = PostMessageW(Some(HWND(h as *mut _)), WM_CLOSE, WPARAM(0), LPARAM(0));
                }
            }
        }

        /// Fecha a janela e devolve o relato. Chamado **antes** de soltar o monitor. Se o fio não
        /// sair em 5 s, o processo encerra (a regra da janela vale mais que a medida).
        pub fn parar(mut self) -> Relato {
            self.pedir_fim();
            let Some(f) = self.fio.take() else { return Relato::default() };
            if !esperar_o_fio(&f, Duration::from_secs(5)) {
                encerrar_por_seguranca("o fio da carga não saiu em 5 s depois do pedido");
            }
            f.join().unwrap_or_default()
        }
    }

    impl Drop for Carga {
        fn drop(&mut self) {
            if let Some(f) = self.fio.take() {
                self.pedir_fim();
                if !esperar_o_fio(&f, Duration::from_secs(5)) {
                    encerrar_por_seguranca("o fio da carga não saiu em 5 s na saída");
                }
                let _ = f.join();
            }
        }
    }

    /// As listras que andam: 24 faixas de cor, deslocadas `t` quadros, e uma segunda banda de
    /// barras que sobem — o bastante para a tela inteira mudar a cada quadro.
    fn desenhar(ctx: &ID3D11DeviceContext1, vista: &ID3D11View, w: i32, h: i32, t: u64) {
        unsafe {
            ctx.ClearView(vista, &[0.95, 0.95, 0.95, 1.0], None);
            let alto = (h as f32 * 0.35) as i32;
            for i in 0..24i32 {
                let x = ((i as i64 * 80 + t as i64 * 8) % (w as i64 + 80)) as i32 - 80;
                let r = RECT { left: x.max(0), top: 0, right: (x + 36).min(w), bottom: alto };
                if r.right <= r.left {
                    continue;
                }
                let matiz = i as f32 / 24.0;
                ctx.ClearView(vista, &cor(matiz), Some(&[r]));
            }
            let passo = 16i32;
            let desloc = (t as i32 * 3) % passo;
            let mut y = alto + 8 - desloc;
            let mut n = 0i32;
            while y < h {
                let largura = (w / 3) + ((n * 37 + t as i32) % (w / 2).max(1));
                let r = RECT { left: 12, top: y.max(alto), right: (12 + largura).min(w), bottom: (y + 10).min(h) };
                if r.bottom > r.top && r.right > r.left {
                    ctx.ClearView(vista, &[0.1, 0.1, 0.1, 1.0], Some(&[r]));
                }
                y += passo;
                n += 1;
            }
        }
    }

    fn cor(matiz: f32) -> [f32; 4] {
        // HSV com saturação 0,6 e brilho 0,95, como a carga do Mac.
        let (s, v) = (0.6f32, 0.95f32);
        let h6 = matiz * 6.0;
        let f = h6 - h6.floor();
        let (p, q, t) = (v * (1.0 - s), v * (1.0 - s * f), v * (1.0 - s * (1.0 - f)));
        let (r, g, b) = match h6 as i32 % 6 {
            0 => (v, t, p),
            1 => (q, v, p),
            2 => (p, v, t),
            3 => (p, q, v),
            4 => (t, p, v),
            _ => (v, p, q),
        };
        [r, g, b, 1.0]
    }

    fn retangulo(hwnd: HWND) -> Option<RECT> {
        let mut r = RECT::default();
        unsafe { GetWindowRect(hwnd, &mut r) }.ok()?;
        Some(r)
    }

    fn mesmo(a: &RECT, b: &RECT) -> bool {
        a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom
    }

    enum Conferencia {
        Certa,
        /// O monitor andou, do mesmo tamanho: a janela vai atrás.
        Andou(RECT),
        /// O monitor sumiu, mudou de tamanho, ou a janela não está nele por outro motivo.
        Errada(String),
    }

    fn conferir(hwnd: HWND, gdi: &str, w: i32, h: i32) -> Conferencia {
        let Some((_, alvo)) = telas::hmonitor_de(gdi) else {
            return Conferencia::Errada(format!("o monitor {gdi} sumiu"));
        };
        if alvo.right - alvo.left != w || alvo.bottom - alvo.top != h {
            return Conferencia::Errada(format!(
                "o monitor mudou de tamanho ({}x{} → {}x{})",
                w,
                h,
                alvo.right - alvo.left,
                alvo.bottom - alvo.top
            ));
        }
        match retangulo(hwnd) {
            Some(r) if mesmo(&r, &alvo) => {
                if monitor_da_janela(hwnd).as_deref() == Some(gdi) {
                    Conferencia::Certa
                } else {
                    Conferencia::Errada("a janela ocupa o retângulo mas o sistema a dá a outro monitor".into())
                }
            }
            Some(_) => Conferencia::Andou(alvo),
            None => Conferencia::Errada("GetWindowRect falhou".into()),
        }
    }

    fn mover(hwnd: HWND, r: &RECT) -> bool {
        MOVER_PERMITIDO.store(true, Ordering::SeqCst);
        let ok = unsafe {
            SetWindowPos(hwnd, Some(HWND_TOPMOST), r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE)
        }
        .is_ok();
        MOVER_PERMITIDO.store(false, Ordering::SeqCst);
        ok
    }

    fn fio(
        modo: Modo,
        gdi: &str,
        fornecedor: u32,
        parar: Arc<AtomicBool>,
        hwnd_fora: Arc<AtomicIsize>,
        pronto: mpsc::Sender<Result<String, String>>,
    ) -> Relato {
        let mut relato = Relato::default();
        let Some((_, r)) = telas::hmonitor_de(gdi) else {
            let _ = pronto.send(Err(format!("carga: o monitor {gdi} não está na enumeração")));
            return relato;
        };
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        let placa = match device::create_device(fornecedor) {
            Ok(p) => p,
            Err(e) => {
                let _ = pronto.send(Err(format!("carga: criar o dispositivo D3D11 falhou: {e}")));
                return relato;
            }
        };
        // A janela nasce **sem** `WS_VISIBLE`: nada aparece até a conferência e o primeiro quadro.
        MOVER_PERMITIDO.store(true, Ordering::SeqCst);
        let criada = unsafe {
            match GetModuleHandleW(None) {
                Err(e) => Err(e),
                Ok(inst) => {
                    let classe = WNDCLASSEXW {
                        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                        lpfnWndProc: Some(procedimento),
                        hInstance: inst.into(),
                        lpszClassName: w!("QuallReceitaMonitorCarga"),
                        ..Default::default()
                    };
                    // Já registrada (segunda carga no mesmo processo) não é erro que importe.
                    let _ = RegisterClassExW(&classe);
                    CreateWindowExW(
                        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                        w!("QuallReceitaMonitorCarga"),
                        w!("Quall - carga sintetica da receita_monitor"),
                        WS_POPUP,
                        r.left,
                        r.top,
                        w,
                        h,
                        None,
                        None,
                        Some(inst.into()),
                        None,
                    )
                }
            }
        };
        MOVER_PERMITIDO.store(false, Ordering::SeqCst);
        let hwnd = match criada {
            Ok(h) => h,
            Err(e) => {
                let _ = pronto.send(Err(format!("carga: criar a janela falhou: {e}")));
                return relato;
            }
        };
        hwnd_fora.store(hwnd.0 as isize, Ordering::SeqCst);
        let destruir_e_recusar = |motivo: String| {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            let _ = pronto.send(Err(format!("carga: {motivo}; destruída sem aparecer")));
        };
        match conferir(hwnd, gdi, w, h) {
            Conferencia::Certa => {}
            Conferencia::Andou(_) => {
                destruir_e_recusar(format!("a janela não nasceu no retângulo de {gdi}"));
                return relato;
            }
            Conferencia::Errada(e) => {
                destruir_e_recusar(e);
                return relato;
            }
        }

        let montar = || -> windows::core::Result<(IDXGISwapChain1, ID3D11DeviceContext1, ID3D11View)> {
            let dispositivo: &ID3D11Device = &placa.device;
            let fabrica: IDXGIFactory2 = unsafe { dispositivo.cast::<IDXGIDevice>()?.GetAdapter()?.GetParent()? };
            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Width: w as u32,
                Height: h as u32,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                ..Default::default()
            };
            let cadeia = unsafe { fabrica.CreateSwapChainForHwnd(dispositivo, hwnd, &desc, None, None)? };
            let fundo: ID3D11Texture2D = unsafe { cadeia.GetBuffer(0)? };
            let mut rtv: Option<ID3D11RenderTargetView> = None;
            unsafe { dispositivo.CreateRenderTargetView(&fundo, None, Some(&mut rtv))? };
            let vista: ID3D11View = rtv.expect("CreateRenderTargetView sem vista").cast()?;
            let ctx: ID3D11DeviceContext1 = placa.context.cast()?;
            Ok((cadeia, ctx, vista))
        };
        let (cadeia, ctx, vista) = match montar() {
            Ok(x) => x,
            Err(e) => {
                destruir_e_recusar(format!("swap chain: {e}"));
                return relato;
            }
        };
        // O primeiro quadro antes de aparecer; e a conferência de novo, logo antes do `ShowWindow`.
        desenhar(&ctx, &vista, w, h, 0);
        if unsafe { cadeia.Present(1, DXGI_PRESENT(0)) }.is_err() {
            relato.falhas_de_present += 1;
        }
        relato.quadros += 1;
        if !matches!(conferir(hwnd, gdi, w, h), Conferencia::Certa) {
            drop(cadeia);
            destruir_e_recusar(format!("{gdi} mudou entre montar e mostrar"));
            return relato;
        }
        let _ = unsafe { ShowWindow(hwnd, SW_SHOWNOACTIVATE) };
        let _ = pronto.send(Ok(format!(
            "carga: modo={} janela={}x{} em ({},{}) no_monitor=sim placa={} (0x{:04X})",
            modo.nome(),
            w,
            h,
            r.left,
            r.top,
            placa.description,
            placa.vendor_id
        )));

        let mut cadeia = Some(cadeia);
        let mut t = 1u64;
        let mut segundo = Instant::now();
        let mut neste_segundo = 1u32;
        let mut destruida = false;
        loop {
            let mut msg = MSG::default();
            while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
                if msg.message == WM_QUIT {
                    return relato;
                }
                unsafe {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            if destruida {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
            let pedido = parar.load(Ordering::SeqCst) || PEDIU_FECHAR.load(Ordering::SeqCst);
            let mut acabar: Option<String> = None;
            if !pedido {
                TOPOLOGIA_MUDOU.store(false, Ordering::SeqCst);
                match conferir(hwnd, gdi, w, h) {
                    Conferencia::Certa => {}
                    Conferencia::Andou(novo) => {
                        // Esconde já, vai para o lugar novo, confere, e só então volta a aparecer.
                        let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
                        if mover(hwnd, &novo) && matches!(conferir(hwnd, gdi, w, h), Conferencia::Certa) {
                            let _ = unsafe { ShowWindow(hwnd, SW_SHOWNOACTIVATE) };
                            relato.mudancas_de_lugar += 1;
                        } else {
                            acabar = Some("o monitor andou e a janela não conseguiu ir atrás".into());
                        }
                    }
                    Conferencia::Errada(e) => {
                        let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
                        acabar = Some(e);
                    }
                }
            }
            if pedido || acabar.is_some() {
                if let Some(motivo) = acabar {
                    relato.acabou_sozinha = Some((motivo, relogio::agora_100ns()));
                }
                // A swap chain sai antes da janela.
                cadeia = None;
                unsafe {
                    let _ = DestroyWindow(hwnd);
                }
                destruida = true;
                continue;
            }
            let Some(c) = cadeia.as_ref() else { continue };
            match modo {
                Modo::Camadas => {
                    desenhar(&ctx, &vista, w, h, t);
                    if unsafe { c.Present(1, DXGI_PRESENT(0)) }.is_err() {
                        relato.falhas_de_present += 1;
                    }
                    t += 1;
                    relato.quadros += 1;
                    neste_segundo += 1;
                }
                Modo::Parada => std::thread::sleep(Duration::from_millis(10)),
            }
            if segundo.elapsed() >= Duration::from_secs(1) {
                relato.por_segundo.push(neste_segundo);
                neste_segundo = 0;
                segundo = Instant::now();
            }
        }
    }
}

// ================================================================================================
// Linha de comando
// ================================================================================================

#[derive(Parser, Debug)]
#[command(
    name = "receita_monitor",
    about = "Bancada: cria monitores no SudoVDA com a receita pedida e diz o que o Windows fez com eles."
)]
struct Argumentos {
    /// Formato do monitor, LxA; vários separados por vírgula valem para `--juntos` (o monitor i
    /// usa o formato i, dando a volta na lista).
    #[arg(long, value_delimiter = ',')]
    alvo: Vec<String>,
    /// Frequência em Hz (1–500).
    #[arg(long, default_value_t = 60)]
    hz: u32,
    /// **Série nova a cada medida.** Vira o `Data1` do GUID e a série do EDID; com `--juntos` e
    /// `--guid-novo`, a série cresce de um em um a partir daqui.
    #[arg(long)]
    serie: Option<u32>,
    /// Nome do produto no EDID (ASCII, até 13). Sem ele: `Q<série>`.
    #[arg(long)]
    nome: Option<String>,
    /// Quanto tempo cada monitor fica de pé depois de nascer.
    #[arg(long, default_value_t = 10.0)]
    segundos: f64,
    /// Quantos monitores ao mesmo tempo (pergunta D). Com `--captura`, o 1º é capturado enquanto
    /// os outros nascem e saem (pergunta E).
    #[arg(long, default_value_t = 1)]
    juntos: u32,
    /// Criar e soltar N vezes no mesmo processo (pergunta C).
    #[arg(long, default_value_t = 1)]
    ciclos: u32,
    /// Com `--ciclos`: série (e GUID) nova a cada volta. Sem ele, o mesmo GUID todas as vezes.
    #[arg(long)]
    guid_novo: bool,
    /// Placa que desenha o monitor virtual: intel|nvidia. **Obrigatório.**
    #[arg(long)]
    placa: Option<String>,
    /// Placa do dispositivo D3D11 da captura (intel|nvidia). Sem ele, a mesma de `--placa`.
    #[arg(long)]
    placa_captura: Option<String>,
    /// Depois de `--segundos`, o fio de ping para e o processo fica vivo e calado (pergunta F).
    #[arg(long)]
    sem_ping: bool,
    /// Depois de `--segundos`, fim abrupto do processo que criou o monitor (pergunta F). Um
    /// processo pai testemunha a saída sem mandar IOCTL nenhum.
    #[arg(long)]
    morrer: bool,
    /// Captura o 1º monitor pelo Windows.Graphics.Capture, contando quadros (perguntas E, H, I, J).
    #[arg(long)]
    captura: bool,
    /// Teto da captura em Hz (`MinUpdateInterval`). Sem ele, sem teto.
    #[arg(long)]
    captura_hz: Option<u32>,
    /// Janela sintética nossa no 1º monitor: parada|camadas.
    #[arg(long)]
    carga: Option<String>,
    /// Esperar o nome GDI de 10 em 10 ms até 5 s, em vez da espera que dobra até ~1,3 s — para
    /// medir o tempo de nascer com resolução de 10 ms (pergunta B).
    #[arg(long)]
    espera_fina: bool,
    /// Ativar o caminho do monitor pela `SetDisplayConfig` quando o Windows não o põe na área de
    /// trabalho sozinho — é o caso com a topologia "somente a tela do PC" (medido no Dell em 14/09).
    /// Sem `SDC_SAVE_TO_DATABASE`: o Win+P da pessoa e o banco de configurações não mudam.
    /// `--ativar` = `--ativar=limpo`, a receita do §13: só os caminhos do usuário + o nosso, pedido
    /// assim que o alvo aparece, e o clone que o Windows fizer é desfeito. `--ativar=cedo` é o de
    /// 14/09 de manhã (devolve o que o `QDC_ALL_PATHS` marca ativo, depois de 300 ms), para
    /// reproduzir a falha; `--ativar=validar` pede antes com `SDC_VALIDATE`.
    #[arg(long, num_args = 0..=1, default_missing_value = "limpo")]
    ativar: Option<String>,
    /// Com `--ativar`: o mínimo depois do ADD antes da primeira tentativa, em ms (padrão 300; com
    /// outro monitor da sonda já ativo, 1500).
    #[arg(long)]
    folga: Option<u64>,
    /// Com `--ativar`: o alvo tem de estar disponível (`targetAvailable`) sem interrupção por este
    /// tanto de ms antes de a sonda pedir (padrão 0).
    #[arg(long, default_value_t = 0)]
    estavel: u64,
    /// Com `--ativar`: de onde vêm os caminhos que a sonda devolve intocados — `todos` (os marcados
    /// ativos no `QDC_ALL_PATHS`, o comportamento de 14/09 de manhã) ou `ativos` (os do
    /// `QDC_ONLY_ACTIVE_PATHS`, com os modos dele).
    #[arg(long, default_value = "todos")]
    pedido: String,
    /// Linha do tempo: um fio que lê a cada N ms o que o Windows diz do alvo (`QDC_ALL_PATHS`,
    /// `QDC_ONLY_ACTIVE_PATHS`, `GET_TARGET_NAME`, o nó PnP, o desktop de entrada) e escreve cada
    /// mudança numa linha `tl`, no mesmo eixo das linhas `ev` (§13).
    #[arg(long)]
    linha_do_tempo: Option<u64>,
    /// Com `--ciclos`: o que fazer antes de cada ADD — `nada`, `placa` (manda de novo o
    /// `SET_RENDER_ADAPTER`, mesma placa) ou `reabrir` (fecha os dois handles, para o ping, abre de
    /// novo e fixa a placa: tudo o que um processo novo faz).
    #[arg(long, default_value = "nada")]
    antes_de_cada: String,
    /// Com `--ciclos`: o que fazer depois de um ciclo que não nasceu — `nada`, `placa`, `reabrir`
    /// ou `pausa:S` (segundos).
    #[arg(long, default_value = "nada")]
    recuperar: String,
    /// Com `--ciclos`: quantas vezes refazer um monitor que não nasceu (REMOVE, espera, ADD do
    /// mesmo GUID) antes de dar o ciclo por perdido.
    #[arg(long, default_value_t = 0)]
    refazer: u32,
    /// Com `--refazer`: a espera entre o REMOVE e o novo ADD, em ms.
    #[arg(long, default_value_t = 1000)]
    refazer_espera: u64,
    /// Com `--ciclos`: pausa entre um ciclo e o seguinte (depois das testemunhas), em segundos.
    #[arg(long, default_value_t = 0.0)]
    pausa: f64,
    /// Com `--ciclos`: antes de cada ADD, esperar que os caminhos ativos sejam só os do usuário
    /// (nenhum monitor nosso, nenhum caminho velho do monitor que saiu) e continuem assim por este
    /// tanto de ms (até 15 s). 0 = não espera (§13).
    #[arg(long, default_value_t = 0)]
    assentar: u64,
    /// Só o veredito do adaptador, sem abrir o dispositivo nem criar nada.
    #[arg(long)]
    so_veredito: bool,
    /// Aceita monitores do SudoVDA já presentes antes da corrida — os de outra execução desta
    /// sonda de pé de propósito (pergunta G: A, B e C juntos, soltar só o B). Esta continua
    /// soltando só os dela.
    #[arg(long)]
    com_outros: bool,
    /// Cada linha também vai para este arquivo, em UTF-8 cru (o `receita-monitor.ps1` usa). O
    /// filho do `--morrer` não escreve nele: quem repete as linhas do filho é o pai.
    #[arg(long)]
    registro: Option<String>,
    /// Interno do `--morrer`: o processo que cria o monitor e morre.
    #[arg(long, hide = true)]
    filho: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum PlacaPedida {
    Intel,
    Nvidia,
}

impl PlacaPedida {
    fn de(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "intel" => Some(Self::Intel),
            "nvidia" => Some(Self::Nvidia),
            _ => None,
        }
    }
    fn fornecedor(self) -> u32 {
        match self {
            Self::Intel => device::VENDOR_INTEL,
            Self::Nvidia => device::VENDOR_NVIDIA,
        }
    }
    fn nome(self) -> &'static str {
        match self {
            Self::Intel => "intel",
            Self::Nvidia => "nvidia",
        }
    }
}

#[derive(Debug)]
struct Receita {
    alvos: Vec<(u32, u32)>,
    hz: u32,
    serie: u32,
    nome: Option<String>,
    segundos: f64,
    juntos: u32,
    ciclos: u32,
    guid_novo: bool,
    placa: PlacaPedida,
    placa_captura: PlacaPedida,
    sem_ping: bool,
    morrer: bool,
    captura: bool,
    captura_hz: Option<u32>,
    carga: Option<carga::Modo>,
    espera_fina: bool,
    ativar: Option<Ativacao>,
    folga: Option<u64>,
    estavel: u64,
    pedido: telas::Base,
    linha_do_tempo: Option<u64>,
    antes_de_cada: Acao,
    recuperar: Acao,
    refazer: u32,
    refazer_espera: u64,
    pausa: f64,
    assentar: u64,
    com_outros: bool,
    filho: bool,
}

/// Como a sonda põe o alvo na área de trabalho (`--ativar`).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Ativacao {
    /// Assim que o alvo aparece num caminho com `targetAvailable`, depois da folga.
    Cedo,
    /// Pede a mesma configuração com `SDC_VALIDATE` e só aplica quando ela passa.
    Validar,
    /// O pedido do §13: só os caminhos do usuário + o nosso; desfaz antes o clone que o Windows
    /// tenha feito com o monitor.
    Limpo,
}

/// O que fazer com o dispositivo entre ciclos (`--antes-de-cada`, `--recuperar`).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Acao {
    Nada,
    /// `SET_RENDER_ADAPTER` de novo, com a mesma placa, no mesmo handle.
    Placa,
    /// Fecha os dois handles (o do ping também), abre de novo, versão, vigia e placa.
    Reabrir,
    /// Espera tantos segundos.
    Pausa(f64),
}

impl Acao {
    fn de(s: &str) -> Option<Self> {
        match s {
            "nada" => Some(Self::Nada),
            "placa" => Some(Self::Placa),
            "reabrir" => Some(Self::Reabrir),
            _ => s
                .strip_prefix("pausa:")
                .and_then(|x| x.parse::<f64>().ok())
                .filter(|x| (0.0..=600.0).contains(x))
                .map(Self::Pausa),
        }
    }
    fn nome(self) -> String {
        match self {
            Self::Nada => "nada".into(),
            Self::Placa => "placa".into(),
            Self::Reabrir => "reabrir".into(),
            Self::Pausa(s) => format!("pausa:{s}"),
        }
    }
}

const RECUSA_SEM_PLACA: &str = "recusa: falta --placa=intel|nvidia. Sem ela a sonda não manda o \
SET_RENDER_ADAPTER, e quem escolhe a placa que desenha o monitor virtual é o Windows \
(docs/monitor-virtual-windows.md §5.3) — a medida ficaria sem dono.";

fn par(s: &str) -> Option<(u32, u32)> {
    let (a, b) = s.to_ascii_lowercase().split_once('x').map(|(a, b)| (a.to_string(), b.to_string()))?;
    let (l, h) = (a.trim().parse::<u32>().ok()?, b.trim().parse::<u32>().ok()?);
    (l > 0 && h > 0 && l <= 16384 && h <= 16384).then_some((l, h))
}

fn validar(a: &Argumentos) -> Result<Receita, String> {
    let placa = match a.placa.as_deref() {
        None => return Err(RECUSA_SEM_PLACA.into()),
        Some(p) => PlacaPedida::de(p).ok_or_else(|| format!("recusa: --placa={p}: só intel ou nvidia"))?,
    };
    let placa_captura = match a.placa_captura.as_deref() {
        None => placa,
        Some(p) => PlacaPedida::de(p).ok_or_else(|| format!("recusa: --placa-captura={p}: só intel ou nvidia"))?,
    };
    if a.alvo.is_empty() {
        return Err("recusa: falta --alvo=LxA".into());
    }
    let mut alvos = Vec::new();
    for s in &a.alvo {
        alvos.push(par(s).ok_or_else(|| format!("recusa: --alvo={s} não é LxA (de 1 a 16384)"))?);
    }
    if !(1..=500).contains(&a.hz) {
        return Err(format!("recusa: --hz={} fora de 1–500 (o driver lê abaixo de 1000 como Hz)", a.hz));
    }
    let serie = match a.serie {
        None | Some(0) => {
            return Err("recusa: falta --serie=N (N > 0) — série nova a cada medida: reusar mede a lembrança do \
                        Windows, não a receita"
                .into())
        }
        Some(s) => s,
    };
    if !(1..=16).contains(&a.juntos) {
        return Err(format!("recusa: --juntos={} fora de 1–16", a.juntos));
    }
    if !(1..=1000).contains(&a.ciclos) {
        return Err(format!("recusa: --ciclos={} fora de 1–1000", a.ciclos));
    }
    if a.ciclos > 1 && a.juntos > 1 {
        return Err("recusa: --ciclos e --juntos são perguntas diferentes (C e D); uma por execução".into());
    }
    let consumo = if a.ciclos > 1 && a.guid_novo { a.ciclos } else { a.juntos };
    if serie.checked_add(consumo).is_none() {
        return Err(format!("recusa: a série {serie} + {consumo} passa de 32 bits"));
    }
    if !(a.segundos >= 0.0 && a.segundos <= 3600.0) {
        return Err(format!("recusa: --segundos={} fora de 0–3600", a.segundos));
    }
    if a.sem_ping && a.morrer {
        return Err("recusa: --sem-ping e --morrer são dois jeitos de testar a mesma saída; um por vez".into());
    }
    if (a.sem_ping || a.morrer) && (a.ciclos > 1 || a.juntos > 1) {
        return Err("recusa: --sem-ping e --morrer valem para um monitor, um ciclo".into());
    }
    if a.ciclos > 1 && (a.captura || a.carga.is_some()) {
        return Err("recusa: --ciclos não leva --captura nem --carga".into());
    }
    if let Some(n) = &a.nome {
        sudovda::texto_edid(n).map_err(|e| format!("recusa: --nome: {e}"))?;
    }
    let carga = match a.carga.as_deref() {
        None => None,
        Some("parada") => Some(carga::Modo::Parada),
        Some("camadas") => Some(carga::Modo::Camadas),
        Some(o) => return Err(format!("recusa: --carga={o}: só parada ou camadas")),
    };
    if let Some(hz) = a.captura_hz {
        if !a.captura || !(1..=500).contains(&hz) {
            return Err("recusa: --captura-hz pede --captura e um valor de 1–500".into());
        }
    }
    let ativar = match a.ativar.as_deref() {
        None => None,
        Some("cedo") => Some(Ativacao::Cedo),
        Some("validar") => Some(Ativacao::Validar),
        Some("limpo") => Some(Ativacao::Limpo),
        Some(o) => return Err(format!("recusa: --ativar={o}: só cedo, validar ou limpo")),
    };
    if a.assentar > 0 && a.ciclos < 2 {
        return Err("recusa: --assentar é de --ciclos".into());
    }
    let pedido = match a.pedido.as_str() {
        "todos" => telas::Base::Todos,
        "ativos" => telas::Base::Ativos,
        o => return Err(format!("recusa: --pedido={o}: só todos ou ativos")),
    };
    let antes_de_cada = Acao::de(&a.antes_de_cada)
        .filter(|x| !matches!(x, Acao::Pausa(_)))
        .ok_or_else(|| format!("recusa: --antes-de-cada={}: só nada, placa ou reabrir", a.antes_de_cada))?;
    let recuperar = Acao::de(&a.recuperar)
        .ok_or_else(|| format!("recusa: --recuperar={}: só nada, placa, reabrir ou pausa:S", a.recuperar))?;
    let so_ciclos = antes_de_cada != Acao::Nada || recuperar != Acao::Nada || a.refazer > 0 || a.pausa > 0.0;
    if so_ciclos && a.ciclos < 2 {
        return Err("recusa: --antes-de-cada, --recuperar, --refazer e --pausa são de --ciclos".into());
    }
    if (a.folga.is_some() || a.estavel > 0 || a.pedido != "todos") && ativar.is_none() {
        return Err("recusa: --folga, --estavel e --pedido são de --ativar".into());
    }
    if (a.estavel > 0 || a.pedido != "todos") && ativar == Some(Ativacao::Limpo) {
        return Err("recusa: --estavel e --pedido não valem com --ativar=limpo (ele monta o pedido com a foto do usuário e pede assim que o alvo aparece)".into());
    }
    if let Some(p) = a.linha_do_tempo {
        if !(1..=1000).contains(&p) {
            return Err("recusa: --linha-do-tempo=N pede N de 1 a 1000 ms".into());
        }
    }
    if !(0.0..=600.0).contains(&a.pausa) {
        return Err(format!("recusa: --pausa={} fora de 0–600 s", a.pausa));
    }
    Ok(Receita {
        alvos,
        hz: a.hz,
        serie,
        nome: a.nome.clone(),
        segundos: a.segundos,
        juntos: a.juntos,
        ciclos: a.ciclos,
        guid_novo: a.guid_novo,
        placa,
        placa_captura,
        sem_ping: a.sem_ping,
        morrer: a.morrer,
        captura: a.captura,
        captura_hz: a.captura_hz,
        carga,
        espera_fina: a.espera_fina,
        ativar,
        folga: a.folga,
        estavel: a.estavel,
        pedido,
        linha_do_tempo: a.linha_do_tempo,
        antes_de_cada,
        recuperar,
        refazer: a.refazer,
        refazer_espera: a.refazer_espera,
        pausa: a.pausa,
        assentar: a.assentar,
        com_outros: a.com_outros,
        filho: a.filho,
    })
}

impl Receita {
    fn linha(&self) -> String {
        let alvos: Vec<String> = self.alvos.iter().map(|(l, a)| format!("{l}x{a}")).collect();
        format!(
            "RECEITA alvo={} hz={} serie={} nome={} juntos={} ciclos={} guid_novo={} placa={} placa_captura={} \
             ping={} morrer={} captura={} captura_hz={} carga={} segundos={} espera={}{}{}{}{}{}",
            alvos.join(","),
            self.hz,
            self.serie,
            nome_edid(self, self.serie),
            self.juntos,
            self.ciclos,
            sim_nao(self.guid_novo),
            self.placa.nome(),
            self.placa_captura.nome(),
            if self.sem_ping { "para-depois" } else { "sim" },
            sim_nao(self.morrer),
            sim_nao(self.captura),
            self.captura_hz.map_or("sem-teto".to_string(), |h| h.to_string()),
            self.carga.map_or("nenhuma", |m| m.nome()),
            self.segundos,
            if self.espera_fina { "fina" } else { "dobra" },
            match self.ativar {
                None => String::new(),
                Some(m) => format!(
                    " ativar={} folga={} estavel={} pedido={}",
                    match m {
                        Ativacao::Cedo => "cedo",
                        Ativacao::Validar => "validar",
                        Ativacao::Limpo => "limpo",
                    },
                    self.folga.map_or("padrao".to_string(), |f| f.to_string()),
                    self.estavel,
                    self.pedido.nome()
                ),
            },
            if self.ciclos > 1 {
                format!(
                    " antes_de_cada={} recuperar={} refazer={} refazer_espera={} pausa={} assentar={}",
                    self.antes_de_cada.nome(),
                    self.recuperar.nome(),
                    self.refazer,
                    self.refazer_espera,
                    self.pausa,
                    self.assentar
                )
            } else {
                String::new()
            },
            self.linha_do_tempo.map_or(String::new(), |p| format!(" linha_do_tempo={p}ms")),
            if self.com_outros { " com_outros=sim" } else { "" },
            if self.filho { " filho=sim" } else { "" }
        )
    }
}

fn sim_nao(b: bool) -> &'static str {
    if b {
        "sim"
    } else {
        "nao"
    }
}

// ================================================================================================
// O monitor, do nascimento à saída
// ================================================================================================

struct Monitor {
    n: u32,
    guid: GUID,
    alvo: (u32, u32),
    hz: u32,
    luid: LUID,
    target: u32,
    /// O alvo respondeu ao `GET_TARGET_NAME` pelo menos uma vez, ou teve caminho ativo. Sem isso
    /// não há o que testemunhar sair: um monitor nunca visto não "sai em 0 ms".
    visto_vivo: bool,
    gdi: Option<String>,
    instancia: Option<String>,
    nasceu: bool,
    solto: bool,
    /// Por que não nasceu (`sdc87`, `sdc5`, `sem_disponivel`, `sem_caminho`, `sdc0_sem_ativo`…).
    falha: Option<String>,
    /// Quanto levou a `SetDisplayConfig` que deu certo, e em quanto o monitor ficou ativo.
    sdc_ms: Option<u64>,
    online_ms: Option<u64>,
    /// Quantas vezes o `--ativar=limpo` desfez um clone que o Windows fez com este monitor.
    clones_desfeitos: u32,
}

/// O nome que vai no EDID: `--nome`, ou `Q<série>` — até 11 caracteres, cabe nos 13 do campo sem
/// cortar. (`Quall-<série>` cortava as séries de 10 dígitos, as do relógio, e dava o mesmo nome a
/// monitores diferentes.)
fn nome_edid(r: &Receita, serie: u32) -> String {
    r.nome.clone().unwrap_or_else(|| format!("Q{serie}"))
}

/// O fio de ping: mais curto que o vigia (um terço do prazo, no máximo 1 s). Se ele morrer, os
/// monitores do SudoVDA saem todos juntos 2–3 s depois (§5.3); se o processo travar com ele de pé,
/// ficam.
struct Ping {
    parar: Arc<AtomicBool>,
    fio: Option<JoinHandle<(u64, u64, u64)>>,
}

impl Ping {
    /// O fio abre o **seu** handle do dispositivo (ver `sudovda::Dispositivo`); se não conseguir,
    /// divide o da thread principal e diz.
    fn iniciar(interface: &str, reserva: Arc<sudovda::Dispositivo>, periodo: Duration) -> Self {
        let disp = match sudovda::Dispositivo::abrir(interface) {
            Ok(d) => Arc::new(d),
            Err(e) => {
                diga!("aviso: o fio de ping não abriu handle próprio ({e}); divide o da thread principal, e um ADD demorado pode segurá-lo");
                reserva
            }
        };
        let parar = Arc::new(AtomicBool::new(false));
        let p2 = parar.clone();
        let fio = std::thread::spawn(move || {
            let (mut n, mut falhas, mut maior) = (0u64, 0u64, 0u64);
            let mut ultimo = Instant::now();
            while !p2.load(Ordering::SeqCst) {
                match disp.ping() {
                    Ok(()) => {
                        n += 1;
                        maior = maior.max(ms(ultimo.elapsed()));
                        ultimo = Instant::now();
                    }
                    Err(e) => {
                        falhas += 1;
                        if falhas <= 3 {
                            diga!("aviso: ping falhou: {e}");
                        }
                    }
                }
                // Dormir em fatias, para parar logo quando pedirem.
                let t = Instant::now();
                while t.elapsed() < periodo && !p2.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            (n, falhas, maior)
        });
        Self { parar, fio: Some(fio) }
    }

    fn parar(&mut self) -> Option<(u64, u64, u64)> {
        self.parar.store(true, Ordering::SeqCst);
        self.fio.take().and_then(|f| f.join().ok())
    }
}

impl Drop for Ping {
    fn drop(&mut self) {
        let _ = self.parar();
    }
}

/// Há quanto tempo foi o último IOCTL que recarregou o vigia — o zero de verdade da pergunta F.
fn desde_ultimo_ioctl() -> String {
    let u = sudovda::ULTIMO_IOCTL.load(Ordering::SeqCst);
    if u == 0 {
        "?".into()
    } else {
        format!("{}", (relogio::agora_100ns() - u) / 10_000)
    }
}

/// Cria um monitor e imprime a linha `add=`.
fn criar(disp: &sudovda::Dispositivo, r: &Receita, n: u32, serie: u32) -> Option<Monitor> {
    let alvo = r.alvos[((n - 1) as usize) % r.alvos.len()];
    let guid = sudovda::guid_da_serie(serie);
    let nome = nome_edid(r, serie);
    let p = sudovda::AddParams {
        width: alvo.0,
        height: alvo.1,
        refresh_rate: r.hz,
        monitor_guid: guid,
        device_name: sudovda::texto_edid(&nome).unwrap_or_default(),
        serial_number: sudovda::texto_edid(&format!("QL{serie}")).unwrap_or_default(),
    };
    // Com o GUID ainda vivo (criado aqui e não visto sair), o driver devolve o monitor que já
    // existe em vez de criar outro (`Driver.cpp:1520-1536`): o `add=ok` não diria a diferença.
    let ja_vivo = criado_e_vivo(guid);
    // Lembrado **antes** do ADD: se o `IddCxMonitorArrival` falhar, o contexto já entrou na lista do
    // driver (o construtor o põe lá, `Driver.cpp:906-911`) e só um REMOVE com este GUID o tira.
    lembrar(guid);
    let t = Instant::now();
    match disp.adicionar(&p) {
        Ok((o, bytes)) => {
            let em = ms(t.elapsed());
            observador::olhar(o.adapter_luid, o.target_id);
            evento!("add target={} luid={}", o.target_id, luid_texto(o.adapter_luid));
            let zerado = o.adapter_luid.LowPart == 0 && o.adapter_luid.HighPart == 0 && o.target_id == 0;
            // O adaptador do IddCx aparece no DXGI com a descrição da placa que o desenha: é a
            // testemunha de a que placa ele está preso neste instante (§12.3).
            let dxgi = telas::placas()
                .into_iter()
                .find(|p| mesma_luid(p.luid, o.adapter_luid))
                .map_or("?".to_string(), |p| p.descricao);
            diga!(
                "add=ok luid={} target={} em {} ms n={} serie={} guid={{{}}} alvo={}x{}@{} nome={} dxgi_do_virtual=\"{}\"{}{}{}",
                luid_texto(o.adapter_luid),
                o.target_id,
                em,
                n,
                serie,
                guid_texto(&guid),
                alvo.0,
                alvo.1,
                r.hz,
                nome,
                dxgi,
                if ja_vivo { " ja_vivo=sim (o driver devolve o monitor que já existe)" } else { "" },
                if zerado { " !! luid e target zerados: o monitor não chegou ao Windows (IddCxMonitorArrival falhou?)" } else { "" },
                if bytes as usize != std::mem::size_of::<sudovda::AddOut>() {
                    format!(" !! o driver devolveu {bytes} bytes")
                } else {
                    String::new()
                }
            );
            Some(Monitor {
                n,
                guid,
                alvo,
                hz: r.hz,
                luid: o.adapter_luid,
                target: o.target_id,
                visto_vivo: false,
                gdi: None,
                instancia: None,
                nasceu: false,
                solto: false,
                falha: None,
                sdc_ms: None,
                online_ms: None,
                clones_desfeitos: 0,
            })
        }
        Err(e) => {
            diga!(
                "add=FALHOU erro=0x{:08X} ({}) em {} ms n={} serie={} alvo={}x{}@{}",
                e.code().0 as u32,
                e.message(),
                ms(t.elapsed()),
                n,
                serie,
                alvo.0,
                alvo.1,
                r.hz
            );
            None
        }
    }
}

/// Espera o monitor ganhar nome GDI e caminho ativo, e imprime `online:`, `pnp:`, `oferecidos` e
/// `ALVO`.
///
/// Com `ativar` (`--ativar`), o alvo que aparece num caminho e não fica ativo em 300 ms é posto na
/// área de trabalho pela [`telas::ativar`] — ele e os `outros` monitores desta sonda, porque a
/// chegada de um monitor pode fazer o Windows reaplicar a topologia e tirar os anteriores. Até oito
/// tentativas, a 300 ms uma da outra; cada uma vira uma linha `ativar:`, com o diagnóstico quando
/// não dá para pedir (a pergunta C de 14/09, com GUID novo a cada ciclo, parou aí).
fn esperar_online(m: &mut Monitor, r: &Receita, outros: &[(LUID, u32)]) {
    let limpo = r.ativar == Some(Ativacao::Limpo);
    // O `limpo` lê em passo fixo de 10 ms: o pedido tem de sair antes de o Windows clonar o monitor
    // (81–535 ms, §13.1), e a espera que dobra deixaria buracos de até 640 ms.
    let fina = r.espera_fina || limpo;
    let placa = r.placa;
    let t0 = Instant::now();
    // A foto da tela do usuário no instante do ADD, com os modos de então: todo pedido do `limpo`
    // é montado com ela (§13.3).
    let foto = if limpo {
        match telas::foto_do_usuario(m.luid) {
            Ok(f) => {
                diga!("ativar: foto do usuário n={} {}", m.n, f.descrever());
                Some(f)
            }
            Err(e) => {
                diga!("ativar: foto do usuário n={} FALHOU ({e}) — sem ela o limpo não pede", m.n);
                None
            }
        }
    } else {
        None
    };
    let mut alvo_visto: Option<u64> = None;
    let mut amigavel = String::new();
    let mut caminho_do_monitor = String::new();
    let mut ultimo_erro: Option<String> = None;
    let mut ativo: Option<(telas::Ativo, u64)> = None;
    // A espera que dobra (20, 40 … 640 ms: ~1,3 s somados) é a do §7; a fina, 10 ms até 5 s.
    let mut espera = if fina { 10u64 } else { 20u64 };
    let teto = match r.ativar {
        Some(Ativacao::Limpo) => 8000u64,
        Some(_) => 5000,
        None if fina => 5000,
        None => 1260,
    };
    let mut dormido = 0u64;
    let mut tentativas = 0u32;
    let mut validacoes = 0u32;
    let mut esperas = 0u32;
    let mut ultima_tentativa: Option<Instant> = None;
    let mut disponivel_desde: Option<Instant> = None;
    let mut em_caminho: Option<u64> = None;
    let mut disponivel_em: Option<u64> = None;
    // O novo ativo com um dos outros fora (só no `limpo`): se o prazo vencer assim, ele conta como
    // nascido, com a falha `tirou_outro` anotada.
    let mut ativo_parcial: Option<(telas::Ativo, u64)> = None;
    loop {
        // Relido até vir o `monitorDevicePath`: a primeira resposta pode chegar sem ele, e sem ele
        // não há instância PnP para a testemunha de saída.
        if caminho_do_monitor.is_empty() {
            match telas::nome_do_alvo(m.luid, m.target) {
                Ok((a, c)) => {
                    alvo_visto.get_or_insert(ms(t0.elapsed()));
                    amigavel = a;
                    caminho_do_monitor = c;
                }
                Err(e) => ultimo_erro = Some(format!("GET_TARGET_NAME={e}")),
            }
        }
        match telas::caminho_ativo(m.luid, m.target) {
            Ok(Some(a)) => {
                // Com o `limpo`, o novo só está pronto quando os outros nossos também seguem na área
                // de trabalho: a chegada do 2º fez o Windows tirar o 1º (pergunta E, 14/09 11:25),
                // e aí o pedido limpo sai de novo com todos.
                let fora: Vec<u32> = outros
                    .iter()
                    .filter(|&&(l, t)| !matches!(telas::caminho_ativo(l, t), Ok(Some(_))))
                    .map(|&(_, t)| t)
                    .collect();
                if !limpo || fora.is_empty() {
                    ativo = Some((a, ms(t0.elapsed())));
                    break;
                }
                if ativo_parcial.is_none() {
                    diga!(
                        "ativar: n={} ativo em +{} ms, mas o(s) alvo(s) {fora:?} saíram da área de trabalho — peço de novo com todos",
                        m.n,
                        ms(t0.elapsed())
                    );
                    m.falha.get_or_insert("tirou_outro".to_string());
                }
                ativo_parcial = Some((a, ms(t0.elapsed())));
            }
            Ok(None) => {}
            Err(e) => ultimo_erro = Some(format!("QueryDisplayConfig={e}")),
        }
        // O que o QDC_ALL_PATHS diz do alvo agora: num caminho? disponível? (Para a estabilidade
        // pedida em `--estavel` e para o resumo do ciclo.)
        let (no_caminho, disponivel) = telas::situacao_do_alvo(m.luid, m.target);
        if no_caminho == Some(true) {
            em_caminho.get_or_insert(ms(t0.elapsed()));
        }
        if disponivel == Some(true) {
            disponivel_em.get_or_insert(ms(t0.elapsed()));
            disponivel_desde.get_or_insert_with(Instant::now);
        } else {
            disponivel_desde = None;
        }
        // Com outro monitor da sonda já ativo, a topologia em vigor é estendida e o Windows costuma
        // estender o novo sozinho (89 ms na pergunta D de 14/09); ativar por cima dele, cedo, fez o
        // 1º sumir da enumeração por um instante (pergunta E). Então, com `outros`, 1,5 s de folga.
        // O `limpo` pede já (0 ms) quando é o único: é o pedido feito cedo que chega antes de o
        // Windows clonar o monitor (§13). Com outro nosso ativo, a folga de 1,5 s continua — é a da
        // pergunta E como foi pedida —, mas com a receita limpa ela **não foi medida** (§13.4, 6).
        // Com outros nossos ativos, o `limpo` também pede já: o Windows, deixado sozinho, ativou o
        // 2º na posição do 1º e tirou o 1º (pergunta E, 14/09 11:25).
        let folga = r.folga.unwrap_or(match (outros.is_empty(), limpo) {
            (_, true) => 0,
            (true, false) => 300,
            (false, false) => 1500,
        });
        // A validação é barata e não muda nada: repete a cada 100 ms; a aplicação, a cada 300. O
        // `limpo` só lê enquanto espera: a cada 50 ms.
        let intervalo = match r.ativar {
            Some(Ativacao::Validar) if tentativas == 0 => 100,
            Some(Ativacao::Limpo) => 50,
            _ => 300,
        };
        let na_hora = t0.elapsed() >= Duration::from_millis(folga)
            && ultima_tentativa.is_none_or(|t| t.elapsed() >= Duration::from_millis(intervalo));
        // Sem `--estavel`, o critério de 14/09: o alvo em algum caminho (a `montar` diz se há um
        // disponível). Com ele, disponível sem interrupção por tanto tempo.
        let pronto = if r.estavel == 0 {
            no_caminho == Some(true)
        } else {
            disponivel_desde.is_some_and(|d| d.elapsed() >= Duration::from_millis(r.estavel))
        };
        if let Some(foto) = foto.as_ref().filter(|_| limpo && tentativas < 8 && na_hora && no_caminho == Some(true)) {
            ultima_tentativa = Some(Instant::now());
            let mut alvos = vec![(m.luid, m.target)];
            alvos.extend_from_slice(outros);
            let t = Instant::now();
            match telas::montar_limpo(&alvos, foto) {
                Err(e) => {
                    esperas += 1;
                    if esperas <= 3 {
                        diga!("ativar: limpo em +{} ms n={} não montei: {e}", ms(t0.elapsed()), m.n);
                    }
                }
                Ok(telas::Limpo::Pronto) => {}
                Ok(telas::Limpo::Esperar(motivo)) => {
                    esperas += 1;
                    if esperas <= 3 || esperas % 20 == 0 {
                        diga!("ativar: limpo espera {esperas} em +{} ms n={} {motivo}", ms(t0.elapsed()), m.n);
                    }
                }
                Ok(telas::Limpo::DesfazerClone(p, clone)) => {
                    tentativas += 1;
                    evento!("desfazer_ini");
                    let tt = Instant::now();
                    let e = telas::aplicar(&p, false);
                    evento!("desfazer_fim rc={e}");
                    if e == 0 {
                        m.clones_desfeitos += 1;
                    } else {
                        m.falha.get_or_insert(format!("desfazer{e}"));
                    }
                    diga!(
                        "ativar: tentativa {} em +{} ms n={} o Windows pôs o monitor em clone ({clone}); desfaço com os caminhos do usuário: SetDisplayConfig={e} ({} ms) pedido={} tela_do_usuario={}",
                        tentativas,
                        ms(t0.elapsed()),
                        m.n,
                        ms(tt.elapsed()),
                        p.descrever(),
                        telas::conferir_usuario(foto)
                    );
                }
                Ok(telas::Limpo::Estender(p)) => {
                    tentativas += 1;
                    if tentativas == 1 || m.clones_desfeitos > 0 {
                        diga!("ativar: pedido n={} {}", m.n, p.descrever());
                    }
                    evento!("sdc_ini tentativa={tentativas}");
                    let tt = Instant::now();
                    let e = telas::aplicar(&p, false);
                    let dur = ms(tt.elapsed());
                    evento!("sdc_fim tentativa={tentativas} rc={e} em {dur} ms");
                    diga!(
                        "ativar: tentativa {} em +{} ms n={} SetDisplayConfig={e}{} alvos_pedidos={} ({dur} ms) tela_do_usuario={}",
                        tentativas,
                        ms(t0.elapsed()),
                        m.n,
                        if e != 0 { " (FALHOU)" } else { "" },
                        p.acrescentados,
                        telas::conferir_usuario(foto)
                    );
                    if e == 0 {
                        m.sdc_ms.get_or_insert(dur);
                    } else {
                        m.falha.get_or_insert(format!("sdc{e}"));
                        let v = telas::aplicar(&p, true);
                        diga!(
                            "ativar: diagnostico n={} validar_depois={v} mesa={} pedido={} alvo_agora={} so_ativos=[{}]",
                            m.n,
                            mesa::nome(),
                            p.descrever(),
                            telas::caminhos_do_alvo(m.luid, m.target),
                            telas::so_ativos_curto()
                        );
                    }
                }
            }
            let _ = t;
        } else if let Some(modo) = r.ativar.filter(|x| *x != Ativacao::Limpo && tentativas < 8 && na_hora && pronto) {
            ultima_tentativa = Some(Instant::now());
            let mut alvos = vec![(m.luid, m.target)];
            alvos.extend_from_slice(outros);
            let t = Instant::now();
            match telas::montar(&alvos, r.pedido) {
                Err(e) => {
                    tentativas += 1;
                    diga!("ativar: tentativa {} em +{} ms n={} não pedi: {e} ({} ms)", tentativas, ms(t0.elapsed()), m.n, ms(t.elapsed()));
                    if tentativas == 1 {
                        diga!(
                            "ativar: diagnostico n={} mesa={} alvo_agora={} so_ativos=[{}]",
                            m.n,
                            mesa::nome(),
                            telas::caminhos_do_alvo(m.luid, m.target),
                            telas::so_ativos_curto()
                        );
                    }
                }
                Ok(p) if p.acrescentados == 0 => {
                    tentativas += 1;
                    diga!("ativar: tentativa {} em +{} ms n={} nada a fazer: todos já ativos", tentativas, ms(t0.elapsed()), m.n);
                }
                Ok(p) => {
                    let validado = if modo == Ativacao::Validar { telas::aplicar(&p, true) } else { 0 };
                    if validado != 0 {
                        validacoes += 1;
                        if validacoes <= 3 || validacoes % 10 == 0 {
                            diga!(
                                "ativar: validacao {} em +{} ms n={} SDC_VALIDATE={validado} — não aplico ({} ms)",
                                validacoes,
                                ms(t0.elapsed()),
                                m.n,
                                ms(t.elapsed())
                            );
                        }
                    } else {
                        tentativas += 1;
                        if tentativas == 1 {
                            diga!("ativar: pedido n={} {}", m.n, p.descrever());
                        }
                        evento!("sdc_ini tentativa={tentativas}");
                        let tt = Instant::now();
                        let e = telas::aplicar(&p, false);
                        let dur = ms(tt.elapsed());
                        evento!("sdc_fim tentativa={tentativas} rc={e} em {dur} ms");
                        diga!(
                            "ativar: tentativa {} em +{} ms n={} SetDisplayConfig={e}{} alvos_pedidos={}{} ({dur} ms)",
                            tentativas,
                            ms(t0.elapsed()),
                            m.n,
                            if e != 0 { " (FALHOU)" } else { "" },
                            p.acrescentados,
                            if validacoes > 0 { format!(" depois de {validacoes} validações") } else { String::new() }
                        );
                        if e == 0 {
                            m.sdc_ms.get_or_insert(dur);
                        } else {
                            m.falha.get_or_insert(format!("sdc{e}"));
                            // O mesmo pedido, só validado, logo depois da falha: o pedido em si é
                            // inválido agora, ou a falha foi do instante?
                            let v = telas::aplicar(&p, true);
                            diga!(
                                "ativar: diagnostico n={} validar_depois={v} mesa={} pedido={} alvo_agora={} ativos_em_todos=[{}] so_ativos={}",
                                m.n,
                                mesa::nome(),
                                p.descrever(),
                                telas::caminhos_do_alvo(m.luid, m.target),
                                telas::ativos_em_todos(),
                                telas::resumo_dos_ativos()
                            );
                        }
                    }
                }
            }
        }
        // O prazo é pelo relógio: as `SetDisplayConfig` (0,5–1,5 s cada) contam. (Antes somava só o
        // tempo dormido, e com oito pedidos o prazo real passava de 15 s.)
        if dormido >= teto || ms(t0.elapsed()) >= teto {
            break;
        }
        std::thread::sleep(Duration::from_millis(espera));
        dormido += espera;
        if !fina {
            espera = (espera * 2).min(640);
        }
    }
    if caminho_do_monitor.is_empty() {
        if let Ok((a, c)) = telas::nome_do_alvo(m.luid, m.target) {
            alvo_visto.get_or_insert(ms(t0.elapsed()));
            amigavel = a;
            caminho_do_monitor = c;
        }
    }
    if !caminho_do_monitor.is_empty() {
        m.instancia = pnp::instancia_da_interface(&caminho_do_monitor);
    }
    m.visto_vivo = alvo_visto.is_some() || ativo.is_some();
    let visto = alvo_visto.map_or("nunca".to_string(), |t| format!("{t} ms"));
    let quando = format!(
        "em_caminho={} disponivel={}",
        em_caminho.map_or("nunca".to_string(), |t| format!("+{t} ms")),
        disponivel_em.map_or("nunca".to_string(), |t| format!("+{t} ms"))
    );
    let ativo = ativo.or(ativo_parcial);
    let Some((a, em)) = ativo else {
        // Terminou em clone? (O monitor ativo por outro adaptador — o Windows o pôs em clone e ele
        // ficou assim.) É a falha do §13, e ganha nome próprio.
        if !caminho_do_monitor.is_empty() && telas::ativo_fora_do_virtual(&caminho_do_monitor, m.luid) {
            m.falha = Some("clone".to_string());
        }
        if m.falha.is_none() {
            m.falha = Some(
                if em_caminho.is_none() {
                    "sem_caminho"
                } else if disponivel_em.is_none() {
                    "sem_disponivel"
                } else if tentativas == 0 {
                    "sem_tentativa"
                } else if m.sdc_ms.is_none() {
                    // Disponível num instante e indisponível quando a sonda foi pedir: alguém
                    // (o Windows) mexeu no alvo antes.
                    "indisponivel_ao_pedir"
                } else {
                    "sdc0_sem_ativo"
                }
                .to_string(),
            );
        }
        diga!(
            "online: nome=? em {} ms ativo=nao n={} alvo_visto={} em_algum_caminho={} amigavel=\"{}\" {quando} falha={}{}",
            ms(t0.elapsed()),
            m.n,
            visto,
            match telas::alvo_em_algum_caminho(m.luid, m.target) {
                Some(true) => "sim",
                Some(false) => "nao",
                None => "?",
            },
            amigavel,
            m.falha.as_deref().unwrap_or("?"),
            ultimo_erro.map(|e| format!(" ultimo_erro={e}")).unwrap_or_default()
        );
        imprimir_pnp(m);
        diga!("ALVO {}x{}@{}: nasceu=nao oferecido=? n={} (sem caminho ativo)", m.alvo.0, m.alvo.1, m.hz, m.n);
        return;
    };
    m.online_ms = Some(em);
    evento!("ativo em {em} ms");
    m.gdi = Some(a.gdi.clone());
    // O HMONITOR pode chegar um pouco depois do caminho: até 1 s, de 10 em 10 ms.
    let t1 = Instant::now();
    let mut hm = telas::hmonitor_de(&a.gdi);
    while hm.is_none() && t1.elapsed() < Duration::from_secs(1) {
        std::thread::sleep(Duration::from_millis(10));
        hm = telas::hmonitor_de(&a.gdi);
    }
    let modo = telas::modo_atual(&a.gdi);
    let escala = hm.and_then(|(h, _)| telas::escala(h));
    let desenha = telas::placa_que_desenha(&a.gdi);
    let confere = match &desenha {
        Some(p) if p.fornecedor == placa.fornecedor() => "ok".to_string(),
        Some(_) => "DIFERENTE".to_string(),
        None => "?".to_string(),
    };
    diga!(
        "online: nome={} em {} ms ativo=sim modo={} escala={} n={} pos={} vsync={}/{} alvo_visto={} amigavel=\"{}\" \
         desenha={} (pedido {}: {}) {quando}",
        a.gdi,
        em,
        modo.map_or("?".to_string(), |(l, h, f)| format!("{l}x{h}@{f}")),
        escala.map_or("?".to_string(), |e| format!("{e}%")),
        m.n,
        hm.map_or("?".to_string(), |(_, r)| format!("{},{}", r.left, r.top)),
        a.vsync.0,
        a.vsync.1,
        visto,
        amigavel,
        desenha.as_ref().map_or("?".to_string(), |p| format!("{} luid={}", p.descricao, luid_texto(p.luid))),
        placa.nome(),
        confere
    );
    imprimir_pnp(m);
    let oferecidos = telas::modos_oferecidos(&a.gdi);
    diga!("oferecidos: {} ({} modos)", modos_compactos(&oferecidos), oferecidos.len());
    let oferecido = oferecidos.iter().any(|&(l, h, f)| (l, h) == m.alvo && f.abs_diff(m.hz) <= 1);
    m.nasceu = modo.is_some_and(|(l, h, f)| (l, h) == m.alvo && f.abs_diff(m.hz) <= 1);
    if m.nasceu {
        // Uma falha de uma tentativa anterior do mesmo monitor não conta se ele nasceu.
        m.falha = None;
    } else {
        m.falha.get_or_insert("modo_diferente".to_string());
    }
    diga!(
        "ALVO {}x{}@{}: nasceu={} oferecido={} n={}",
        m.alvo.0,
        m.alvo.1,
        m.hz,
        if m.nasceu { "SIM" } else { "nao" },
        if oferecido { "SIM" } else { "nao" },
        m.n
    );
}

fn imprimir_pnp(m: &Monitor) {
    match &m.instancia {
        Some(i) => diga!(
            "pnp: instancia={} presente={} n={}",
            i,
            match pnp::presenca(i) {
                Ok(true) => "True".to_string(),
                Ok(false) => "False".to_string(),
                Err(c) => format!("? (CONFIGRET {c})"),
            },
            m.n
        ),
        None => diga!("pnp: instancia=? (o monitorDevicePath não levou a um nó) n={}", m.n),
    }
}

/// `2436x1124@60/120 1827x843@60/120 …`, do maior para o menor.
fn modos_compactos(v: &[(u32, u32, u32)]) -> String {
    let mut por: Vec<((u32, u32), Vec<u32>)> = Vec::new();
    for &(l, h, f) in v {
        match por.iter_mut().find(|(k, _)| *k == (l, h)) {
            Some((_, fs)) => {
                if !fs.contains(&f) {
                    fs.push(f)
                }
            }
            None => por.push(((l, h), vec![f])),
        }
    }
    por.sort_by(|a, b| (b.0 .0 as u64 * b.0 .1 as u64).cmp(&(a.0 .0 as u64 * a.0 .1 as u64)).then(b.0.cmp(&a.0)));
    por.iter()
        .map(|((l, h), fs)| {
            let mut fs = fs.clone();
            fs.sort_unstable();
            format!("{l}x{h}@{}", fs.iter().map(|f| f.to_string()).collect::<Vec<_>>().join("/"))
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// O que uma testemunha viu até agora.
#[derive(Clone, Copy, PartialEq)]
enum Visto {
    /// Ainda vê o monitor (ou ainda não conseguiu perguntar).
    Ainda,
    /// Viu o monitor fora, neste instante (ms desde o zero).
    Fora(u64),
    /// Não se aplica: nunca teve o que olhar (sem nome GDI, sem instância).
    NaoAplica,
}

/// As testemunhas de saída, cada uma com o seu tempo desde `t0`. **Nenhum IOCTL aqui**: é o que
/// deixa usar a mesma função no silêncio do `--sem-ping` e depois da morte do `--morrer`.
///
/// Duas regras que a revisão adversarial de 13/09 cobrou: **leitura que falha não é saída** (conta
/// em `leituras_com_erro`), e **monitor nunca visto vivo não tem saída a testemunhar**.
/// `captura` = (o `fechado_em` da captura, o instante do evento, o início da captura), todos em
/// 100 ns do QPC.
fn testemunhar(m: &Monitor, t0: Instant, prazo: Duration, captura: Option<(&AtomicI64, i64, i64)>) -> (String, bool) {
    if !m.visto_vivo {
        return (
            format!(
                "testemunhas: - o monitor nunca foi visto vivo (nem o alvo nem um caminho responderam): nada a testemunhar n={}",
                m.n
            ),
            false,
        );
    }
    let gdi = m.gdi.clone().unwrap_or_default();
    let inst = m.instancia.clone().unwrap_or_default();
    let mut alvo = Visto::Ainda;
    let mut alvo_codigo = 0i32;
    let mut caminho = if m.gdi.is_some() { Visto::Ainda } else { Visto::NaoAplica };
    let mut enumeracao = caminho;
    let mut presente = if m.instancia.is_some() { Visto::Ainda } else { Visto::NaoAplica };
    let mut erros = 0u32;
    let mut fechado: Option<i64> = None;
    loop {
        let agora = ms(t0.elapsed());
        if alvo == Visto::Ainda {
            match telas::nome_do_alvo(m.luid, m.target) {
                Ok(_) => {}
                // ERROR_ACCESS_DENIED: não deu para perguntar (tela bloqueada, por exemplo).
                Err(5) => erros += 1,
                Err(c) => {
                    alvo = Visto::Fora(agora);
                    alvo_codigo = c;
                }
            }
        }
        if caminho == Visto::Ainda {
            match telas::caminho_ativo(m.luid, m.target) {
                Ok(None) => caminho = Visto::Fora(agora),
                Ok(Some(_)) => {}
                Err(_) => erros += 1,
            }
        }
        if enumeracao == Visto::Ainda {
            match telas::na_enumeracao(&gdi) {
                Ok(false) => enumeracao = Visto::Fora(agora),
                Ok(true) => {}
                Err(()) => erros += 1,
            }
        }
        if presente == Visto::Ainda {
            match pnp::presenca(&inst) {
                Ok(false) => presente = Visto::Fora(agora),
                Ok(true) => {}
                Err(_) => erros += 1,
            }
        }
        if let Some((f, _, _)) = captura {
            let v = f.load(Ordering::SeqCst);
            if fechado.is_none() && v != 0 {
                fechado = Some(v);
            }
        }
        // O `alvo` fica de fora: é o **conector** do adaptador, e o `GET_TARGET_NAME` continua
        // respondendo por ele depois da saída do monitor (medido no Dell em 14/09: "alvo=SIM ainda
        // em 10000 ms" nas 16 receitas da pergunta B, com o PnP fora em 6–8 ms). Esperá-lo
        // segurava cada saída 10 s e dava código 1 a toda corrida. Ele segue na linha, informativo.
        let todas = [caminho, enumeracao, presente].iter().all(|v| *v != Visto::Ainda);
        if (todas && (captura.is_none() || fechado.is_some())) || t0.elapsed() >= prazo {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let total = ms(prazo);
    let linha = |nome: &str, v: Visto, fora: &str, dentro: &str, sem: &str| match v {
        Visto::Fora(t) => format!("{nome}={fora} em {t} ms"),
        Visto::Ainda => format!("{nome}={dentro} ainda em {total} ms"),
        Visto::NaoAplica => format!("{nome}=- ({sem})"),
    };
    let c = linha("caminho_ativo", caminho, "nao", "SIM", "nunca esteve ativo");
    let e = linha("enum", enumeracao, "nao", "SIM", "nunca teve nome GDI");
    let p = linha("pnp_presente", presente, "False", "True", "instância não lida");
    let f = match (captura, fechado) {
        (None, _) => "closed=- (sem captura)".to_string(),
        (Some(_), None) => format!("closed=nao em {total} ms"),
        (Some((_, base, inicio)), Some(v)) if v < base => {
            format!("closed=sim ANTES do evento (+{} ms desde o início da captura)", (v - inicio) / 10_000)
        }
        (Some((_, base, _)), Some(v)) => format!("closed=sim em {} ms", (v - base) / 10_000),
    };
    let a = match alvo {
        Visto::Fora(t) => format!("alvo=nao em {t} ms (codigo {alvo_codigo})"),
        _ => format!("alvo=SIM ainda em {} ms (conector, não testemunha)", ms(t0.elapsed())),
    };
    let err = if erros > 0 { format!(", leituras_com_erro={erros}") } else { String::new() };
    let saiu = [caminho, enumeracao, presente].iter().all(|v| *v != Visto::Ainda);
    (format!("testemunhas: {c}, {e}, {p}, {f}, {a}{err} n={}", m.n), saiu)
}

/// `REMOVE` e as testemunhas. Devolve se o monitor saiu testemunhado.
fn soltar(disp: &sudovda::Dispositivo, m: &mut Monitor, captura: Option<&captura::Captura>) -> bool {
    let t = Instant::now();
    let base = relogio::agora_100ns();
    evento!("remove");
    let r = disp.soltar(m.guid);
    match &r {
        Ok(()) => {
            m.solto = true;
            esquecer(m.guid);
            diga!("soltar=ok em {} ms n={}", ms(t.elapsed()), m.n);
        }
        Err(e) => diga!("soltar=FALHOU erro=0x{:08X} ({}) em {} ms n={}", e.code().0 as u32, e.message(), ms(t.elapsed()), m.n),
    }
    let (linha, saiu) =
        testemunhar(m, t, Duration::from_secs(10), captura.map(|c| (&*c.fechado_em, base, c.inicio)));
    diga!("{linha}");
    evento!("testemunhas_fim");
    r.is_ok() && saiu
}

/// Os recursos do processo e os nós do SudoVDA — a pergunta C.
fn recursos() -> String {
    use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
    use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessHandleCount};
    let mut n = 0u32;
    let mut c = PROCESS_MEMORY_COUNTERS::default();
    unsafe {
        let _ = GetProcessHandleCount(GetCurrentProcess(), &mut n);
        let _ = GetProcessMemoryInfo(GetCurrentProcess(), &mut c, std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32);
    }
    let nos = match pnp::monitores_sudovda() {
        Ok((p, a)) => format!("nos_smkd1ce presentes={} ausentes={a}", p.len()),
        Err(e) => format!("nos_smkd1ce=? ({e})"),
    };
    format!("handles={n} memoria={:.1} MB {nos}", c.WorkingSetSize as f64 / 1048576.0)
}

// ================================================================================================
// O fluxo
// ================================================================================================

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    let codigo = principal();
    std::process::exit(codigo);
}

fn principal() -> i32 {
    let a = match Argumentos::try_parse() {
        Ok(a) => a,
        Err(e) => {
            if e.use_stderr() {
                eprintln!("{}", quall_capture_probe::higiene_do_registro::sanitizar_argumentos(&e.to_string()));
            } else { let _ = e.print(); }
            return if e.use_stderr() { 2 } else { 0 };
        }
    };
    if let (Some(caminho), false) = (&a.registro, a.filho) {
        match std::fs::File::create(caminho) {
            Ok(f) => {
                if let Ok(mut r) = REGISTRO.lock() {
                    *r = Some(f);
                }
            }
            Err(e) => {
                eprintln!("recusa: não consigo escrever o registro em {caminho}: {e}");
                return 2;
            }
        }
    }

    // --- O veredito, antes de qualquer coisa ------------------------------------------------------
    //
    // Antes até de validar os argumentos: sem o driver a resposta é sempre a mesma frase, com o
    // mesmo código, e ela não depende do que foi pedido. Só lê o PnP.
    let interface = match imprimir_veredito() {
        Ok(i) => i,
        Err(c) => return c,
    };
    if a.so_veredito {
        return 0;
    }
    let r = match validar(&a) {
        Ok(r) => r,
        Err(msg) => {
            diga!("{msg}");
            return 2;
        }
    };
    diga!("{}", r.linha());

    // Pixels físicos em todo lugar: retângulos, modos e DPI efetivo de cada monitor. (Pelo SSH, na
    // Sessão 0, esta chamada falha — medido em 13/09; na sessão interativa é onde ela importa.)
    if let Err(e) = unsafe {
        windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(
            windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        )
    } {
        diga!("aviso: SetProcessDpiAwarenessContext(per monitor v2) falhou ({e}): a escala e os retângulos podem sair virtualizados");
    }
    unsafe {
        let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
    }

    // --- Condições da corrida, antes de qualquer IOCTL ------------------------------------------
    //
    // Antes de abrir o dispositivo: qualquer IOCTL recarrega o vigia e manteria vivos por mais 3 s
    // os monitores de uma corrida anterior que estivessem saindo.
    if let Some(c) = conferir_antes(r.filho, r.com_outros) {
        return c;
    }

    if r.morrer && !r.filho {
        return pai_do_morrer(&r);
    }

    let placas = telas::placas();
    diga!(
        "placas: {}",
        placas
            .iter()
            .map(|p| format!("{} (0x{:04X}) luid={}", p.descricao, p.fornecedor, luid_texto(p.luid)))
            .collect::<Vec<_>>()
            .join(" | ")
    );
    let Some(placa) = placas.iter().find(|p| p.fornecedor == r.placa.fornecedor()) else {
        diga!("recusa: a placa pedida ({}) não está entre os adaptadores DXGI", r.placa.nome());
        return 2;
    };

    // --- O dispositivo ---------------------------------------------------------------------------
    let disp = match sudovda::Dispositivo::abrir(&interface) {
        Ok(d) => Arc::new(d),
        Err(e) => {
            diga!("adaptador SudoVDA presente mas não abre ({e}): ver docs/monitor-virtual-windows.md §9");
            return 4;
        }
    };
    match disp.versao() {
        Ok(v) => {
            diga!("protocolo={}.{}.{} teste={}", v.major, v.minor, v.incremental, sim_nao(v.test_build != 0));
            if (v.major, v.minor) != (sudovda::PROTOCOLO.0, sudovda::PROTOCOLO.1) {
                diga!(
                    "recusa: o driver fala o protocolo {}.{}.{} e esta sonda transcreveu o {}.{}.{} \
                     (sudovda-ioctl.h:25): as estruturas podem ser outras",
                    v.major, v.minor, v.incremental, sudovda::PROTOCOLO.0, sudovda::PROTOCOLO.1, sudovda::PROTOCOLO.2
                );
                return 4;
            }
        }
        Err(e) => {
            diga!("recusa: GET_PROTOCOL_VERSION falhou ({e}): não sei que driver é este");
            return 4;
        }
    }
    let vigia = match disp.vigia() {
        Ok(w) => {
            diga!("vigia: timeout={} s contagem={}", w.timeout, w.countdown);
            w.timeout
        }
        Err(e) => {
            diga!("aviso: GET_WATCHDOG falhou ({e}); assumo o padrão de 3 s (Driver.cpp:44)");
            3
        }
    };
    match disp.fixar_placa(placa.luid) {
        Ok(()) => diga!(
            "fixar_placa=ok {} luid={} (o retorno não prova nada; a testemunha é o desenha= do online:)",
            placa.descricao,
            luid_texto(placa.luid)
        ),
        Err(e) => {
            diga!("fixar_placa=FALHOU ({e}): sem ele a placa é do Windows; recuso seguir");
            return 1;
        }
    }
    let periodo = (vigia > 0).then(|| Duration::from_millis((vigia as u64 * 1000 / 3).clamp(100, 1000)));
    let mut ping = match periodo {
        Some(periodo) => {
            diga!("ping: a cada {} ms (vigia de {vigia} s), num handle próprio", ms(periodo));
            Some(Ping::iniciar(&interface, disp.clone(), periodo))
        }
        None => {
            diga!("ping: nenhum — o vigia está desligado no registro (watchdog=0): os monitores só saem pelo REMOVE");
            None
        }
    };

    diga!("topologia antes: {}", telas::topologia());
    diga!("antes: ativos_em_todos [{}]", telas::ativos_em_todos());
    diga!("antes: mesa={}", mesa::nome());
    let mut observador = r.linha_do_tempo.map(|p| {
        diga!("linha do tempo: a cada {p} ms (linhas tl e ev; eixo: ms desde o ADD do ciclo)");
        observador::Observador::iniciar(Duration::from_millis(p))
    });

    let codigo = if r.ciclos > 1 {
        let mut c = Conexao { disp, ping: ping.take(), interface: interface.clone(), placa: placa.luid, periodo };
        let codigo = correr_ciclos(&mut c, &r);
        ping = c.ping.take();
        codigo
    } else {
        correr_juntos(&disp, &r, &mut ping, vigia)
    };

    if let Some(mut o) = observador.take() {
        // Um respiro para o observador ver a última saída assentar.
        std::thread::sleep(Duration::from_millis(500));
        if let Some(n) = o.parar() {
            diga!("linha do tempo: {n} fotografias");
        }
    }
    if let Some(mut p) = ping.take() {
        if let Some((n, falhas, maior)) = p.parar() {
            diga!("ping: {n} pings, {falhas} falhas, maior intervalo {maior} ms (vigia {vigia} s)");
        }
    }
    diga!("topologia depois: {}", telas::topologia());
    diga!("depois: caminhos ativos {}", telas::resumo_dos_ativos());
    codigo
}

/// Imprime o veredito e devolve o caminho da interface de controle (ou o código de saída).
fn imprimir_veredito() -> Result<String, i32> {
    match pnp::veredito() {
        pnp::Veredito::Presente { instancia, interfaces } => {
            diga!(
                "VEREDITO adaptador SudoVDA: presente instancia={} interfaces={}",
                instancia.as_deref().unwrap_or("?"),
                interfaces.join(" | ")
            );
            if interfaces.len() > 1 {
                diga!("recusa: {} adaptadores SudoVDA — não sei qual é o da sonda", interfaces.len());
                return Err(4);
            }
            Ok(interfaces[0].clone())
        }
        pnp::Veredito::Ausente { nos_lidos, fantasma } => {
            diga!(
                "VEREDITO adaptador SudoVDA: ausente (interface {{{}}}: nenhuma; classe Display: {}{})",
                guid_texto(&sudovda::INTERFACE),
                match nos_lidos {
                    Ok(n) => format!("{n} nós lidos, nenhum presente com {}", sudovda::HARDWARE_ID),
                    Err(e) => format!("não li os nós ({e})"),
                },
                fantasma.map(|f| format!("; nó fantasma de uma instalação antiga: {f}")).unwrap_or_default()
            );
            diga!("adaptador SudoVDA ausente: ver docs/monitor-virtual-windows.md §9");
            Err(3)
        }
        pnp::Veredito::SemInterface { instancia, iniciado, problema } => {
            diga!(
                "VEREDITO adaptador SudoVDA: presente sem interface instancia={instancia} iniciado={} problema={problema}",
                sim_nao(iniciado)
            );
            diga!(
                "adaptador SudoVDA instalado mas sem a interface de controle (problema {problema}; 52 é assinatura): \
                 ver docs/monitor-virtual-windows.md §9 e a pergunta A do §8"
            );
            Err(4)
        }
        pnp::Veredito::Erro(e) => {
            diga!("VEREDITO adaptador SudoVDA: não consegui ler o PnP ({e})");
            Err(4)
        }
    }
}

/// Nenhum monitor do SudoVDA presente antes da corrida (espera até 6 s o vigia de uma corrida
/// anterior), e a linha de base dos caminhos ativos. Com `--com-outros` os presentes são aceitos
/// (pergunta G: outra execução desta sonda com o monitor dela de pé) — e continuam não sendo
/// soltos por esta.
fn conferir_antes(filho: bool, com_outros: bool) -> Option<i32> {
    let t = Instant::now();
    loop {
        match pnp::monitores_sudovda() {
            Ok((p, a)) if p.is_empty() => {
                diga!("antes: monitores SudoVDA presentes=0 ausentes={a}");
                break;
            }
            Ok((p, a)) if com_outros => {
                diga!("antes: monitores SudoVDA presentes={} ausentes={a} (aceitos: --com-outros): {}", p.len(), p.join(" | "));
                break;
            }
            Ok(_) if t.elapsed() < Duration::from_secs(6) && !filho => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Ok((p, a)) => {
                diga!("antes: monitores SudoVDA presentes={} ausentes={a}: {}", p.len(), p.join(" | "));
                diga!(
                    "recusa: já há monitor do SudoVDA presente antes da corrida — não é desta sonda e ela não o \
                     solta; o monitor anterior tem de sair testemunhado primeiro (ou --com-outros, se é outra \
                     execução desta sonda de propósito)"
                );
                return Some(5);
            }
            Err(e) => {
                diga!("antes: não li os nós de monitor ({e}); sigo sem essa conferência");
                break;
            }
        }
    }
    diga!("antes: caminhos ativos {}", telas::resumo_dos_ativos());
    None
}

/// O dispositivo de uma corrida de `--ciclos`: o handle principal e o do ping podem ser trocados no
/// meio (`reabrir`), então andam juntos com o que é preciso para abri-los de novo.
struct Conexao {
    disp: Arc<sudovda::Dispositivo>,
    ping: Option<Ping>,
    interface: String,
    placa: LUID,
    periodo: Option<Duration>,
}

impl Conexao {
    /// `--antes-de-cada` e `--recuperar`. Nenhuma delas mexe em monitor: rodam entre ciclos, com
    /// nenhum monitor desta sonda de pé.
    fn agir(&mut self, a: Acao, quando: &str) {
        match a {
            Acao::Nada => {}
            Acao::Placa => {
                evento!("placa ({quando})");
                let t = Instant::now();
                let r = self.disp.fixar_placa(self.placa);
                diga!(
                    "acao: placa ({quando}) SET_RENDER_ADAPTER={} luid={} em {} ms",
                    match r {
                        Ok(()) => "ok".to_string(),
                        Err(e) => format!("FALHOU ({e})"),
                    },
                    luid_texto(self.placa),
                    ms(t.elapsed())
                );
            }
            Acao::Reabrir => {
                evento!("reabrir ({quando})");
                let t = Instant::now();
                if let Some(mut p) = self.ping.take() {
                    let _ = p.parar();
                }
                let novo = match sudovda::Dispositivo::abrir(&self.interface) {
                    Ok(d) => d,
                    Err(e) => {
                        diga!("acao: reabrir ({quando}) FALHOU ao abrir ({e}); sigo com o handle antigo");
                        if let Some(p) = self.periodo {
                            self.ping = Some(Ping::iniciar(&self.interface, self.disp.clone(), p));
                        }
                        return;
                    }
                };
                // Só a conexão segura o handle principal (a `Guarda` do `--ciclos` não o guarda):
                // trocar o `Arc` fecha o antigo.
                let fortes = Arc::strong_count(&self.disp);
                self.disp = Arc::new(novo);
                let versao = self.disp.versao().map(|v| format!("{}.{}.{}", v.major, v.minor, v.incremental));
                let placa = self.disp.fixar_placa(self.placa);
                if let Some(p) = self.periodo {
                    self.ping = Some(Ping::iniciar(&self.interface, self.disp.clone(), p));
                }
                diga!(
                    "acao: reabrir ({quando}) em {} ms: handle antigo {} (referências={fortes}), protocolo={} placa={} ping={}",
                    ms(t.elapsed()),
                    if fortes == 1 { "fechado" } else { "AINDA ABERTO por outra referência" },
                    versao.unwrap_or_else(|e| format!("FALHOU ({e})")),
                    match placa {
                        Ok(()) => "ok".to_string(),
                        Err(e) => format!("FALHOU ({e})"),
                    },
                    if self.ping.is_some() { "de novo" } else { "nenhum" }
                );
            }
            Acao::Pausa(s) => {
                evento!("pausa {s} s ({quando})");
                diga!("acao: pausa ({quando}) {s} s");
                std::thread::sleep(Duration::from_secs_f64(s));
            }
        }
    }
}

/// Uma linha do resumo do `--ciclos`.
struct Ciclo {
    k: u32,
    target: u32,
    nasceu: bool,
    falha: String,
    online_ms: Option<u64>,
    sdc_ms: Option<u64>,
    refeitos: u32,
}

fn correr_ciclos(c: &mut Conexao, r: &Receita) -> i32 {
    let _guarda = Guarda { disp: None, interface: c.interface.clone() };
    let mut ok = true;
    let mut resumo: Vec<Ciclo> = Vec::new();
    let base = recursos();
    diga!("recursos antes: {base}");
    // O LUID do adaptador virtual, que o primeiro ADD diz (o `--assentar` precisa dele).
    let mut adaptador_virtual: Option<LUID> = None;
    for k in 0..r.ciclos {
        let serie = if r.guid_novo { r.serie + k } else { r.serie };
        // Com vários `--alvo`, o ciclo k usa o formato k, dando a volta: um receptor sai e chega
        // outro, de outro formato.
        let n_formato = (k % r.alvos.len() as u32) + 1;
        diga!("-- ciclo {}/{} serie={serie} --", k + 1, r.ciclos);
        c.agir(r.antes_de_cada, "antes do ADD");
        if r.assentar > 0 {
            if let Some(v) = adaptador_virtual {
                assentar(v, r.assentar);
            }
        }
        // O estado que o monitor novo encontra: um caminho velho ainda marcado ativo aqui é o que
        // a SetDisplayConfig vai receber de volta no pedido.
        diga!("antes do ADD: ativos_em_todos=[{}] so_ativos=[{}]", telas::ativos_em_todos(), telas::so_ativos_curto());
        diga!("sistema antes c={}: {}", k + 1, sistema::resumo());
        observador::novo_ciclo(k + 1);
        let mut refeitos = 0u32;
        let mut atual: Option<Monitor> = None;
        while let Some(mut m) = criar(&c.disp, r, n_formato, serie) {
            adaptador_virtual.get_or_insert(m.luid);
            esperar_online(&mut m, r, &[]);
            if m.nasceu || refeitos >= r.refazer {
                atual = Some(m);
                break;
            }
            refeitos += 1;
            diga!(
                "refazer: {refeitos}/{} — o monitor não nasceu ({}); solto, espero {} ms e crio de novo o mesmo GUID",
                r.refazer,
                m.falha.as_deref().unwrap_or("?"),
                r.refazer_espera
            );
            let _ = soltar(&c.disp, &mut m, None);
            std::thread::sleep(Duration::from_millis(r.refazer_espera));
            c.agir(r.recuperar, "antes de refazer");
            // O monitor refeito tem o seu zero: o eixo da linha do tempo recomeça no novo ADD.
            observador::novo_ciclo(k + 1);
        }
        let Some(mut m) = atual else {
            ok = false;
            resumo.push(Ciclo { k: k + 1, target: 0, nasceu: false, falha: "add".into(), online_ms: None, sdc_ms: None, refeitos });
            continue;
        };
        ok &= m.nasceu;
        diga!("sistema criado c={}: {}", k + 1, sistema::resumo());
        if m.nasceu {
            std::thread::sleep(Duration::from_secs_f64(r.segundos));
        }
        ok &= soltar(&c.disp, &mut m, None);
        diga!("sistema tirado c={}: {}", k + 1, sistema::resumo());
        diga!("recursos ciclo {}: {}", k + 1, recursos());
        resumo.push(Ciclo {
            k: k + 1,
            target: m.target,
            nasceu: m.nasceu,
            falha: m.falha.clone().unwrap_or_default(),
            online_ms: m.online_ms,
            sdc_ms: m.sdc_ms,
            refeitos,
        });
        if !m.nasceu {
            c.agir(r.recuperar, "depois da falha");
        }
        if r.pausa > 0.0 && k + 1 < r.ciclos {
            evento!("pausa {} s", r.pausa);
            std::thread::sleep(Duration::from_secs_f64(r.pausa));
        }
    }
    diga!("recursos depois: {}", recursos());
    imprimir_resumo(&resumo);
    if ok {
        0
    } else {
        1
    }
}

/// `--assentar`: espera os caminhos ativos serem só os do usuário por `ms` seguidos (até 15 s), e
/// diz quanto esperou e o que viu fora — o caminho velho do monitor que saiu, ou um clone nosso.
fn assentar(adaptador_virtual: LUID, ms_estavel: u64) {
    let t = Instant::now();
    let mut limpo_desde: Option<Instant> = None;
    let mut primeiro_fora: Option<String> = None;
    let mut erro: Option<String> = None;
    loop {
        match telas::so_do_usuario(adaptador_virtual) {
            Ok((true, _)) => {
                limpo_desde.get_or_insert_with(Instant::now);
            }
            Ok((false, fora)) => {
                limpo_desde = None;
                primeiro_fora.get_or_insert(fora);
            }
            Err(e) => {
                limpo_desde = None;
                erro.get_or_insert(e);
            }
        }
        if limpo_desde.is_some_and(|d| d.elapsed() >= Duration::from_millis(ms_estavel)) {
            break;
        }
        if t.elapsed() >= Duration::from_secs(15) {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    evento!("assentado em {} ms", ms(t.elapsed()));
    diga!(
        "assentar: {} em {} ms (pedido {ms_estavel} ms só com os caminhos do usuário){}{}",
        if limpo_desde.is_some_and(|d| d.elapsed() >= Duration::from_millis(ms_estavel)) { "ok" } else { "PRAZO" },
        ms(t.elapsed()),
        primeiro_fora.map(|f| format!(" — viu fora: {f}")).unwrap_or_default(),
        erro.map(|e| format!(" — erro: {e}")).unwrap_or_default()
    );
}

/// `RESUMO`: quantos nasceram, a sequência (`+` nasceu, `x` não, `r` nasceu depois de refazer), as
/// falhas por tipo, a primeira falha, e os tempos dos que nasceram.
fn imprimir_resumo(v: &[Ciclo]) {
    let nasceram = v.iter().filter(|c| c.nasceu).count();
    let seq: String = v
        .iter()
        .map(|c| match (c.nasceu, c.refeitos) {
            (true, 0) => '+',
            (true, _) => 'r',
            (false, _) => 'x',
        })
        .collect();
    let mut tipos: Vec<(String, usize)> = Vec::new();
    for c in v.iter().filter(|c| !c.nasceu) {
        match tipos.iter_mut().find(|(t, _)| *t == c.falha) {
            Some((_, n)) => *n += 1,
            None => tipos.push((c.falha.clone(), 1)),
        }
    }
    let online: Vec<f64> = v.iter().filter_map(|c| c.online_ms).map(|x| x as f64).collect();
    let sdc: Vec<f64> = v.iter().filter_map(|c| c.sdc_ms).map(|x| x as f64).collect();
    let fmt = |x: &[f64]| {
        if x.is_empty() {
            "-".to_string()
        } else {
            format!(
                "p50={:.0} p95={:.0} max={:.0} ms",
                percentil(x, 0.5),
                percentil(x, 0.95),
                x.iter().cloned().fold(f64::MIN, f64::max)
            )
        }
    };
    diga!(
        "RESUMO ciclos={} nasceram={} seq={} falhas=[{}] primeira_falha={} refeitos={}",
        v.len(),
        nasceram,
        seq,
        tipos.iter().map(|(t, n)| format!("{t}:{n}")).collect::<Vec<_>>().join(" "),
        v.iter().find(|c| !c.nasceu).map_or("-".to_string(), |c| format!("ciclo {} alvo {}", c.k, c.target)),
        v.iter().map(|c| c.refeitos).sum::<u32>()
    );
    diga!("RESUMO tempos: online {} · SetDisplayConfig {}", fmt(&online), fmt(&sdc));
}

fn correr_juntos(disp: &Arc<sudovda::Dispositivo>, r: &Receita, ping: &mut Option<Ping>, vigia: u32) -> i32 {
    let mut ok = true;
    let mut monitores: Vec<Monitor> = Vec::new();
    // Qualquer saída desta função solta o que ela criou, e só isso — menos no fim abrupto do
    // `--morrer`, que é a medida.
    let guarda = Guarda { disp: Some(disp.clone()), interface: String::new() };

    observador::novo_ciclo(1);
    let Some(mut primeiro) = criar(disp, r, 1, r.serie) else { return 1 };
    esperar_online(&mut primeiro, r, &[]);
    ok &= primeiro.nasceu;
    let gdi1 = primeiro.gdi.clone();
    monitores.push(primeiro);

    // A carga primeiro, a captura depois: a captura começa com o monitor já em movimento.
    let mut carga: Option<carga::Carga> = None;
    if let Some(modo) = r.carga {
        match gdi1.as_deref() {
            None => {
                diga!("carga: não sobe — o 1º monitor não tem nome GDI (sem caminho ativo)");
                ok = false;
            }
            Some(g) => match carga::iniciar(modo, g, r.placa.fornecedor()) {
                Ok((c, linha)) => {
                    diga!("{linha}");
                    carga = Some(c);
                }
                Err(e) => {
                    diga!("{e}");
                    ok = false;
                }
            },
        }
    }
    let mut cap: Option<captura::Captura> = None;
    // No `--morrer` quem captura é o pai: a captura tem de sobreviver à morte para ver o `Closed`.
    if r.captura && !(r.morrer && r.filho) {
        match iniciar_captura(r, gdi1.as_deref()) {
            Ok(c) => cap = Some(c),
            Err(e) => {
                diga!("captura: FALHOU {e}");
                ok = false;
            }
        }
    }
    let inicio_medida = cap.as_ref().map_or_else(relogio::agora_100ns, |c| c.inicio);
    let mut eventos: Vec<(String, i64)> = Vec::new();

    // Os outros monitores: com captura, nascem com o 1º já sendo contado (pergunta E).
    if r.juntos > 1 {
        if cap.is_some() {
            std::thread::sleep(Duration::from_secs_f64((r.segundos / 4.0).min(2.0)));
        }
        for n in 2..=r.juntos {
            eventos.push((format!("nasce n={n}"), relogio::agora_100ns()));
            match criar(disp, r, n, r.serie + n - 1) {
                Some(mut m) => {
                    let outros: Vec<(LUID, u32)> = monitores.iter().map(|x| (x.luid, x.target)).collect();
                    esperar_online(&mut m, r, &outros);
                    ok &= m.nasceu;
                    monitores.push(m);
                }
                None => {
                    ok = false;
                    break;
                }
            }
        }
    }

    std::thread::sleep(Duration::from_secs_f64(if cap.is_some() && r.juntos > 1 { r.segundos / 2.0 } else { r.segundos }));

    // Com captura, os outros saem enquanto o 1º ainda é contado.
    if cap.is_some() && monitores.len() > 1 {
        while monitores.len() > 1 {
            let mut m = monitores.pop().expect("há mais de um");
            eventos.push((format!("sai n={}", m.n), relogio::agora_100ns()));
            ok &= soltar(disp, &mut m, None);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    let fim_medida = relogio::agora_100ns();

    if r.morrer && r.filho {
        // O fim abrupto: sem REMOVE, sem destrutor, sem fechar o handle à mão, e a carga (se houver)
        // morre junto com o processo — o sistema destrói a janela dele antes de o vigia tirar o
        // monitor, 2–3 s depois. Quem testemunha é o processo pai.
        diga!(
            "FILHO: fim abrupto agora (TerminateProcess) desde_ultimo_ioctl={} ms — o vigia é que tem de tirar o monitor",
            desde_ultimo_ioctl()
        );
        use std::io::Write;
        let _ = std::io::stdout().flush();
        std::mem::forget(guarda);
        std::mem::forget(carga);
        unsafe {
            let _ = windows::Win32::System::Threading::TerminateProcess(
                windows::Win32::System::Threading::GetCurrentProcess(),
                99,
            );
        }
        return 99;
    }

    let mut carga_acabou: Option<(String, i64)> = None;
    if let Some(c) = carga.take() {
        let rel = c.parar();
        diga!(
            "carga: fim quadros={} por_segundo=[{}] mudancas_de_lugar={} acabou_sozinha={} falhas_de_present={}",
            rel.quadros,
            rel.por_segundo.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" "),
            rel.mudancas_de_lugar,
            rel.acabou_sozinha
                .as_ref()
                .map_or("nao".to_string(), |(m, t)| format!("\"{m}\" em +{} ms", (t - inicio_medida) / 10_000)),
            rel.falhas_de_present
        );
        if rel.acabou_sozinha.is_some() {
            ok = false;
        }
        carga_acabou = rel.acabou_sozinha;
        // Um respiro para o DWM tirar a janela antes de o monitor sair.
        std::thread::sleep(Duration::from_millis(200));
    }

    if r.sem_ping {
        // Vivo e calado: o fio de ping para, e nada mais sai daqui para o driver.
        if let Some(mut p) = ping.take() {
            if let Some((n, falhas, maior)) = p.parar() {
                diga!("ping: parado de propósito depois de {n} pings ({falhas} falhas, maior intervalo {maior} ms)");
            }
        }
        let m = &mut monitores[0];
        let t = Instant::now();
        let base = relogio::agora_100ns();
        diga!(
            "sem-ping: calado desde agora; último IOCTL há {} ms — o vigia de {vigia} s conta a partir dele, não daqui",
            desde_ultimo_ioctl()
        );
        let (linha, saiu) =
            testemunhar(m, t, Duration::from_secs(15), cap.as_ref().map(|c| (&*c.fechado_em, base, c.inicio)));
        diga!("{linha}");
        if saiu {
            m.solto = true;
            esquecer(m.guid);
            diga!("soltar=nao-precisou (o vigia tirou) n={}", m.n);
        } else {
            diga!("sem-ping: o monitor não saiu testemunhado em 15 s de silêncio; solto por REMOVE (limpeza)");
            ok = false;
            let _ = soltar(disp, m, cap.as_ref());
        }
    } else {
        while let Some(mut m) = monitores.pop() {
            let c = if m.n == 1 { cap.as_ref() } else { None };
            ok &= soltar(disp, &mut m, c);
        }
    }

    if let Some(c) = cap.take() {
        c.parar();
        let q = c.copia();
        diga!("captura: {} placa={}", captura::resumo(&q, inicio_medida, fim_medida), r.placa_captura.nome());
        for (nome, t) in &eventos {
            // A carga que acabou sozinha deixa o monitor parado: daí em diante um buraco entre
            // quadros é a carga parada, não o outro monitor.
            let invalida = match &carga_acabou {
                Some((motivo, fim)) if *fim <= t + 15_000_000 => format!(
                    " (NÃO VALE: a carga acabou em +{} ms — {motivo})",
                    (fim - inicio_medida) / 10_000
                ),
                _ => String::new(),
            };
            match captura::maior_buraco_perto(&q, *t) {
                Some(b) => diga!(
                    "perturbacao: {nome} em +{} ms: maior intervalo no n=1 = {b:.1} ms{invalida}",
                    (t - inicio_medida) / 10_000
                ),
                None => diga!("perturbacao: {nome}: sem quadros no n=1 perto do evento (use --carga=camadas){invalida}"),
            }
        }
    }
    drop(guarda);
    if ok {
        0
    } else {
        1
    }
}

/// Os GUIDs que **este processo** mandou num `ADD` e ainda não viu sair. É a única lista que a
/// limpeza usa: a sonda nunca manda `REMOVE` com um GUID que não saiu de um `ADD` dela.
static CRIADOS: Mutex<Vec<GUID>> = Mutex::new(Vec::new());

fn lembrar(g: GUID) {
    if let Ok(mut v) = CRIADOS.lock() {
        if !v.contains(&g) {
            v.push(g);
        }
    }
}

fn esquecer(g: GUID) {
    if let Ok(mut v) = CRIADOS.lock() {
        v.retain(|x| *x != g);
    }
}

fn criado_e_vivo(g: GUID) -> bool {
    CRIADOS.lock().map(|v| v.contains(&g)).unwrap_or(false)
}

/// Solta, na saída de uma corrida por qualquer caminho (inclusive pânico), os monitores desta
/// sonda que ainda estiverem de pé — menos no fim abrupto do `--morrer`, que é a medida.
///
/// Com `disp: None` (o `--ciclos`, que pode trocar de handle no meio pelo `reabrir`), ela abre um
/// handle próprio na hora de soltar — o `REMOVE` é pelo GUID e vale de qualquer handle.
struct Guarda {
    disp: Option<Arc<sudovda::Dispositivo>>,
    interface: String,
}

impl Drop for Guarda {
    fn drop(&mut self) {
        let pendentes: Vec<GUID> = CRIADOS.lock().map(|mut v| v.drain(..).collect()).unwrap_or_default();
        if pendentes.is_empty() {
            return;
        }
        let disp = match &self.disp {
            Some(d) => d.clone(),
            None => match sudovda::Dispositivo::abrir(&self.interface) {
                Ok(d) => Arc::new(d),
                Err(e) => {
                    diga!("soltar=limpeza: não abri o dispositivo ({e}); o vigia tira os monitores em 2–3 s");
                    return;
                }
            },
        };
        for g in pendentes {
            match disp.soltar(g) {
                Ok(()) => diga!("soltar=limpeza guid={{{}}}", guid_texto(&g)),
                // NOT_FOUND é o esperado quando o monitor já saiu (vigia, ou um ADD que falhou).
                Err(e) => diga!("soltar=limpeza guid={{{}}} ({})", guid_texto(&g), e.message()),
            }
        }
    }
}

fn iniciar_captura(r: &Receita, gdi: Option<&str>) -> Result<captura::Captura, String> {
    let gdi = gdi.ok_or("o monitor não tem nome GDI: não há o que capturar")?;
    // Marcas de passo: em 14/09, 10:11, uma abertura de captura prendeu 600 s depois da carga
    // subir, com o `dwm` em ~8000 handles (§13.5). Elas dizem onde.
    let t = Instant::now();
    diga!("captura: passo hmonitor");
    let (h, _) = telas::hmonitor_de(gdi).ok_or("o monitor não está na enumeração")?;
    diga!("captura: passo D3D11 em +{} ms", ms(t.elapsed()));
    let placa = device::create_device(r.placa_captura.fornecedor()).map_err(|e| format!("D3D11: {e}"))?;
    diga!("captura: passo WGC em +{} ms", ms(t.elapsed()));
    if placa.vendor_id != r.placa_captura.fornecedor() {
        return Err(format!(
            "a placa da captura saiu {} (0x{:04X}) e não a pedida ({})",
            placa.description,
            placa.vendor_id,
            r.placa_captura.nome()
        ));
    }
    let c = captura::Captura::iniciar(&placa.device, h, r.captura_hz).map_err(|e| format!("WGC: {e}"))?;
    diga!("captura: iniciada em {gdi} placa={} (0x{:04X})", placa.description, placa.vendor_id);
    Ok(c)
}

// ------------------------------------------------------------------------------------------------
// `--morrer`: o pai testemunha, o filho cria e morre
// ------------------------------------------------------------------------------------------------

/// O pai **não abre o dispositivo**: um IOCTL daqui recarregaria o vigia e esconderia a medida. Ele
/// lança a si mesmo com `--filho`, lê as linhas do filho (e as repete), e testemunha a saída do
/// monitor a partir do instante em que o filho morreu.
///
/// Só dá 0 quando tudo fecha: o monitor nasceu como pedido (`ALVO … nasceu=SIM`), o filho chegou ao
/// fim abrupto (`FILHO: fim abrupto` e código 99), ele **não** mandou REMOVE antes (nenhuma linha
/// `soltar=` dele), e o monitor saiu testemunhado.
fn pai_do_morrer(r: &Receita) -> i32 {
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(e) => {
            diga!("recusa: não sei o caminho deste executável ({e})");
            return 2;
        }
    };
    let mut filho = match Command::new(exe)
        .creation_flags(windows::Win32::System::Threading::CREATE_NO_WINDOW.0)
        .args(std::env::args().skip(1))
        .arg("--filho")
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(f) => f,
        Err(e) => {
            diga!("morrer: não consegui lançar o filho ({e})");
            return 1;
        }
    };
    let saida = filho.stdout.take().expect("stdout do filho");
    let (tx, rx) = mpsc::channel::<String>();
    let leitor = std::thread::spawn(move || {
        for l in BufReader::new(saida).lines().map_while(Result::ok) {
            let _ = tx.send(l);
        }
    });
    let mut m: Option<Monitor> = None;
    let mut cap: Option<captura::Captura> = None;
    let mut inicio_medida = 0i64;
    let (mut nasceu, mut fim_abrupto, mut filho_soltou, mut captura_ok) = (false, false, false, true);
    for l in rx {
        diga!("{l}");
        if let Some((luid, target)) = ler_add(&l) {
            m = Some(Monitor {
                n: 1,
                guid: sudovda::guid_da_serie(r.serie),
                alvo: r.alvos[0],
                hz: r.hz,
                luid,
                target,
                visto_vivo: false,
                gdi: None,
                instancia: None,
                nasceu: false,
                solto: false,
                falha: None,
                sdc_ms: None,
                online_ms: None,
                clones_desfeitos: 0,
            });
        }
        if let Some(mm) = m.as_mut() {
            if l.starts_with("online: ") && l.contains(" alvo_visto=") && !l.contains(" alvo_visto=nunca") {
                mm.visto_vivo = true;
            }
            if let Some(g) = ler_campo(&l, "online: nome=") {
                if g != "?" {
                    mm.gdi = Some(g.clone());
                    mm.visto_vivo = true;
                    if r.captura {
                        match iniciar_captura(r, Some(&g)) {
                            Ok(c) => {
                                inicio_medida = c.inicio;
                                cap = Some(c);
                            }
                            Err(e) => {
                                diga!("captura: FALHOU (no pai) {e}");
                                captura_ok = false;
                            }
                        }
                    }
                }
            }
            if let Some(i) = ler_campo(&l, "pnp: instancia=") {
                if i != "?" {
                    mm.instancia = Some(i);
                }
            }
        }
        if l.starts_with("ALVO ") && l.contains("nasceu=SIM") {
            nasceu = true;
        }
        if l.starts_with("FILHO: fim abrupto") {
            fim_abrupto = true;
        }
        if l.starts_with("soltar=") {
            filho_soltou = true;
        }
    }
    let _ = leitor.join();
    let status = filho.wait();
    let t = Instant::now();
    let base = relogio::agora_100ns();
    let codigo_filho = status.as_ref().ok().and_then(|s| s.code());
    diga!("morte: o filho saiu com código {}", codigo_filho.map_or("?".to_string(), |c| c.to_string()));
    let parar_captura = |cap: Option<captura::Captura>| {
        if let Some(c) = cap {
            c.parar();
            diga!(
                "captura: {} placa={} (no pai, até o fim das testemunhas)",
                captura::resumo(&c.copia(), inicio_medida, relogio::agora_100ns()),
                r.placa_captura.nome()
            );
        }
    };
    if !fim_abrupto || codigo_filho != Some(99) {
        diga!("morte: o filho não chegou ao fim abrupto — não há morte a testemunhar (se ele tinha criado monitor, a guarda dele o soltou)");
        parar_captura(cap.take());
        // Os códigos de recusa do filho (2 a 5) passam adiante; o resto vira 1.
        return codigo_filho.filter(|c| (2..=5).contains(c)).unwrap_or(1);
    }
    let Some(mut m) = m else {
        diga!("morte: o filho não criou monitor; nada a testemunhar");
        parar_captura(cap.take());
        return 1;
    };
    let (linha, saiu) =
        testemunhar(&m, t, Duration::from_secs(15), cap.as_ref().map(|c| (&*c.fechado_em, base, c.inicio)));
    diga!("{linha}");
    parar_captura(cap.take());
    if saiu && !filho_soltou {
        diga!("soltar=nao-precisou (o vigia tirou depois da morte) n=1");
        return if nasceu && captura_ok { 0 } else { 1 };
    }
    if filho_soltou {
        diga!("morte: o filho mandou REMOVE antes de morrer — a saída não é do vigia");
        return 1;
    }
    // Não saiu: limpeza pelo REMOVE com o GUID desta receita — e só se o alvo que o filho relatou
    // ainda responde. Se não responde, não há o que soltar daqui.
    if telas::nome_do_alvo(m.luid, m.target).is_err() {
        diga!("morte: o alvo não responde mais ao DisplayConfig; não mando REMOVE");
        return 1;
    }
    diga!("morte: o monitor não saiu testemunhado em 15 s; solto por REMOVE (limpeza)");
    if let Ok(i) = imprimir_veredito() {
        if let Ok(d) = sudovda::Dispositivo::abrir(&i) {
            let _ = soltar(&d, &mut m, None);
        }
    }
    1
}

/// `add=ok luid=0xHHHHHHHH:LLLLLLLL target=N …` → (LUID, target).
fn ler_add(l: &str) -> Option<(LUID, u32)> {
    let resto = l.strip_prefix("add=ok luid=0x")?;
    let (luid, resto) = resto.split_once(' ')?;
    let (alto, baixo) = luid.split_once(':')?;
    let alvo = resto.strip_prefix("target=")?.split(' ').next()?;
    Some((
        LUID { HighPart: u32::from_str_radix(alto, 16).ok()? as i32, LowPart: u32::from_str_radix(baixo, 16).ok()? },
        alvo.parse().ok()?,
    ))
}

/// O valor depois de um prefixo, até o primeiro espaço.
fn ler_campo(l: &str, prefixo: &str) -> Option<String> {
    l.strip_prefix(prefixo).and_then(|r| r.split(' ').next()).map(|s| s.to_string())
}

#[cfg(test)]
mod testes {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn os_ioctl_sao_os_do_cabecalho() {
        // CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800…, METHOD_BUFFERED, FILE_ANY_ACCESS), à mão.
        assert_eq!(sudovda::IOCTL_ADD, 0x0022_2000);
        assert_eq!(sudovda::IOCTL_REMOVE, 0x0022_2004);
        assert_eq!(sudovda::IOCTL_SET_RENDER_ADAPTER, 0x0022_2008);
        assert_eq!(sudovda::IOCTL_GET_WATCHDOG, 0x0022_200C);
        assert_eq!(sudovda::IOCTL_PING, 0x0022_2220);
        assert_eq!(sudovda::IOCTL_GET_PROTOCOL_VERSION, 0x0022_23FC);
    }

    #[test]
    fn as_estruturas_tem_o_tamanho_do_c() {
        assert_eq!(size_of::<sudovda::AddParams>(), 56);
        assert_eq!(offset_of!(sudovda::AddParams, monitor_guid), 12);
        assert_eq!(offset_of!(sudovda::AddParams, device_name), 28);
        assert_eq!(offset_of!(sudovda::AddParams, serial_number), 42);
        assert_eq!(size_of::<sudovda::AddOut>(), 12);
        assert_eq!(size_of::<sudovda::RemoveParams>(), 16);
        assert_eq!(size_of::<sudovda::SetRenderAdapterParams>(), 8);
        assert_eq!(size_of::<sudovda::WatchdogOut>(), 8);
        assert_eq!(size_of::<sudovda::ProtocolVersion>(), 4);
    }

    #[test]
    fn o_guid_e_funcao_da_serie_com_data1_unico() {
        let a = sudovda::guid_da_serie(20737);
        let b = sudovda::guid_da_serie(20738);
        assert_eq!(a.data1, 20737);
        assert_ne!(a.data1, b.data1);
        assert_eq!((a.data2, a.data3, a.data4), (b.data2, b.data3, b.data4));
        assert_eq!(a, sudovda::guid_da_serie(20737));
    }

    #[test]
    fn texto_do_edid_ate_13_ascii_com_nul() {
        let t = sudovda::texto_edid("iPhone-X").unwrap();
        assert_eq!(&t[..8], b"iPhone-X");
        assert!(t[8..].iter().all(|b| *b == 0));
        assert!(sudovda::texto_edid("1234567890123").is_ok());
        assert!(sudovda::texto_edid("12345678901234").is_err());
        assert!(sudovda::texto_edid("tela-estendída").is_err());
        assert!(sudovda::texto_edid("").is_err());
    }

    fn args(v: &[&str]) -> Argumentos {
        Argumentos::try_parse_from(std::iter::once("receita_monitor").chain(v.iter().copied())).unwrap()
    }

    #[test]
    fn sem_placa_recusa_e_diz_por_que() {
        let e = validar(&args(&["--alvo=2436x1124", "--hz=60", "--serie=5"])).unwrap_err();
        assert!(e.contains("--placa"), "{e}");
        assert!(e.contains("Windows"), "{e}");
        assert!(validar(&args(&["--alvo=2436x1124", "--serie=5", "--placa=amd"])).is_err());
        let r = validar(&args(&["--alvo=2436x1124", "--serie=5", "--placa=Intel"])).unwrap();
        assert_eq!(r.placa, PlacaPedida::Intel);
        assert_eq!(r.placa_captura, PlacaPedida::Intel);
    }

    #[test]
    fn combinacoes_recusadas() {
        let base = ["--alvo=1920x1200", "--serie=9", "--placa=nvidia"];
        let com = |extra: &[&str]| {
            let mut v: Vec<&str> = base.to_vec();
            v.extend_from_slice(extra);
            validar(&args(&v))
        };
        assert!(com(&["--sem-ping", "--morrer"]).is_err());
        assert!(com(&["--ciclos=3", "--juntos=2"]).is_err());
        assert!(com(&["--morrer", "--juntos=2"]).is_err());
        assert!(com(&["--ciclos=3", "--captura"]).is_err());
        assert!(com(&["--carga=girando"]).is_err());
        assert!(com(&["--captura-hz=30"]).is_err());
        assert!(com(&["--hz=0"]).is_err());
        assert!(com(&["--nome=Nome-comprido-demais"]).is_err());
        assert!(validar(&args(&["--alvo=1920x1200", "--placa=intel"])).is_err());
        assert!(com(&["--captura", "--captura-hz=30", "--carga=camadas", "--juntos=2"]).is_ok());
        // As opções do §13: as de ciclo pedem --ciclos; as de ativação pedem --ativar.
        assert!(com(&["--recuperar=placa"]).is_err());
        assert!(com(&["--pausa=2"]).is_err());
        assert!(com(&["--assentar=500"]).is_err());
        assert!(com(&["--folga=0"]).is_err());
        assert!(com(&["--ativar=turbo"]).is_err());
        assert!(com(&["--ciclos=3", "--antes-de-cada=pausa:1"]).is_err());
        assert!(com(&["--ciclos=3", "--recuperar=pausa:x"]).is_err());
        assert!(com(&["--linha-do-tempo=0"]).is_err());
        assert!(com(&["--ciclos=3", "--guid-novo", "--ativar=cedo", "--recuperar=pausa:5", "--assentar=500"]).is_ok());
    }

    #[test]
    fn o_ativar_puro_e_a_receita_limpa() {
        let r = validar(&args(&["--alvo=1920x1200", "--serie=9", "--placa=intel", "--ativar"])).unwrap();
        assert_eq!(r.ativar, Some(Ativacao::Limpo));
        let r = validar(&args(&["--alvo=1920x1200", "--serie=9", "--placa=intel", "--ativar=cedo"])).unwrap();
        assert_eq!(r.ativar, Some(Ativacao::Cedo));
        let r = validar(&args(&["--alvo=1920x1200", "--serie=9", "--placa=intel"])).unwrap();
        assert_eq!(r.ativar, None);
        assert_eq!(Acao::de("pausa:2.5"), Some(Acao::Pausa(2.5)));
        assert_eq!(Acao::de("reabrir"), Some(Acao::Reabrir));
        assert_eq!(Acao::de("pausa:9999"), None);
    }

    #[test]
    fn o_nome_padrao_cabe_no_edid_e_distingue_series_do_relogio() {
        let r = validar(&args(&["--alvo=1920x1200", "--serie=1757790000", "--placa=intel", "--juntos=3"])).unwrap();
        let a = nome_edid(&r, 1_757_790_000);
        let b = nome_edid(&r, 1_757_790_001);
        assert_ne!(a, b);
        assert!(sudovda::texto_edid(&nome_edid(&r, u32::MAX)).is_ok());
        assert!(r.linha().contains(&format!("nome={a} ")), "{}", r.linha());
    }

    #[test]
    fn alvo_em_lista_e_formatos() {
        let r = validar(&args(&["--alvo=1920x1200,2436X1125", "--serie=1", "--placa=intel", "--juntos=3"])).unwrap();
        assert_eq!(r.alvos, vec![(1920, 1200), (2436, 1125)]);
        assert!(par("0x10").is_none());
        assert!(par("abc").is_none());
        assert!(par("1920").is_none());
    }

    #[test]
    fn a_linha_do_add_se_le_de_volta() {
        let luid = LUID { LowPart: 0x0001_A2B3, HighPart: 0 };
        let l = format!("add=ok luid={} target=4352 em 12 ms n=1 serie=7", luid_texto(luid));
        let (lido, alvo) = ler_add(&l).unwrap();
        assert!(mesma_luid(lido, luid));
        assert_eq!(alvo, 4352);
        assert_eq!(ler_campo(r"online: nome=\\.\DISPLAY5 em 300 ms", "online: nome=").as_deref(), Some(r"\\.\DISPLAY5"));
        assert!(ler_add("add=FALHOU erro=0x8007…").is_none());
    }

    #[test]
    fn multi_sz_e_percentil() {
        let v: Vec<u16> = "a\0bc\0\0".encode_utf16().collect();
        assert_eq!(multi_sz(&v), vec!["a".to_string(), "bc".to_string()]);
        assert_eq!(percentil(&[3.0, 1.0, 2.0], 0.5), 2.0);
        assert!(percentil(&[], 0.5).is_nan());
    }

    #[test]
    fn modos_agrupados_do_maior_para_o_menor() {
        let s = modos_compactos(&[(1280, 720, 60), (2436, 1124, 60), (2436, 1124, 120), (1280, 720, 30)]);
        assert_eq!(s, "2436x1124@60/120 1280x720@30/60");
    }

    #[test]
    fn buraco_perto_do_evento() {
        // Quadros a cada 16,7 ms, com um buraco de 200 ms logo depois do evento em t=1 s.
        let mut q = Vec::new();
        let mut t = 0i64;
        while t < 10_000_000 {
            q.push((t, t + 20_000));
            t += 166_667;
        }
        q.push((10_000_000 + 2_000_000, 0));
        let b = captura::maior_buraco_perto(&q, 10_000_000).unwrap();
        assert!(b > 190.0 && b < 260.0, "{b}");
    }
}
