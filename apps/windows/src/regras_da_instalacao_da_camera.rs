//! **A câmera virtual que o Quall instala no Windows** (decisão do Bruno, 12/10/2026, tarde): as
//! regras puras, sem Win32, testadas em qualquer máquina (`rustc --test` direto neste arquivo).
//!
//! # O molde é o do driver da tela estendida
//!
//! A câmera embutida no MSIX não funciona (medido no Dell em 12/10: `MFCreateVirtualCamera` devolve
//! `0x80070003`, o Frame Server não acha a classe declarada só no pacote; `docs/camera-virtual.md`,
//! "Câmera embutida no pacote"). O caminho que funciona desde agosto é a fonte registrada em `HKLM`,
//! e registrar ali pede administrador. Então a câmera segue o desenho do SudoVDA de 02/10, noite
//! (`regras_do_driver.rs`, `driver_da_tela_estendida.rs`):
//!
//! - **o Quall do site** (MSI ou o `.exe` solto, sem identidade de pacote): o cartão "Instalação da
//!   câmera virtual" dos Ajustes tem o botão "Instalar câmera virtual", que explica numa caixa, pede
//!   o UAC e instala; o mesmo lugar remove. **Nada é instalado sem o clique** — nem pelo MSI;
//! - **o Quall da loja** (MSIX, com identidade de pacote): o MSIX não eleva, e o botão abre a página
//!   [`URL_DA_PAGINA_DA_CAMERA`], de onde se baixa o instalador avulso;
//! - **o instalador avulso** `quall-camera.exe` (manifesto `requireAdministrator`): o mesmo código
//!   de instalar e remover, a DLL dentro dele, um arquivo só para baixar;
//! - **os dois Quall usam a mesma câmera**: a fonte registrada com o [`CLSID`] avulso, criada por
//!   sessão (`MFVirtualCameraLifetime_Session`) pelo fio das câmeras.
//!
//! # O que fica aqui
//!
//! - onde a fonte mora e como é registrada ([`CLSID`], [`NOME_DA_DLL`], [`valores_do_registro`]);
//! - a conferência da DLL embutida ([`conferir_a_dll`]: um PE x64 que é DLL);
//! - o **pedido** que o processo elevado aceita ([`ler_pedido`]): um verbo de uma lista fechada e um
//!   nome de cano no formato que a janela gera, nenhum caminho, nenhum texto livre;
//! - o **protocolo** das linhas do processo elevado para a janela ([`Linha`]), o mesmo do driver;
//! - a **situação** da câmera neste computador e o botão de cada uma ([`Situacao`], [`botao`]);
//! - os **textos** (chaves da tabela de `idioma/camera.rs`).
//!
//! O protocolo, o andamento e o resultado repetem os de `regras_do_driver.rs` de propósito: aquele
//! módulo só compila com `tela-estendida-futura`, fora deste release, e um módulo puro desta casa
//! não depende de outro (é o que deixa o `rustc --test` direto no arquivo).

// =============================================================================================
// Onde a fonte mora
// =============================================================================================

/// O CLSID da fonte de mídia (`CLSID_TEXTO` em `integrations/camera-windows/fonte/src/lib.rs`; o
/// teste `o_clsid_e_o_da_fonte` de `cameras.rs` confere). É o mesmo do `instalar.ps1` de bancada e
/// do MSI de agosto: uma câmera instalada por qualquer um deles é a mesma câmera.
pub const CLSID: &str = "{5C75FE52-9204-45F6-B143-58B1AC8048E5}";
/// A chave do registro COM, debaixo de `HKLM` (vista de 64 bits).
pub const CHAVE_DO_CLSID: &str = r"SOFTWARE\Classes\CLSID\{5C75FE52-9204-45F6-B143-58B1AC8048E5}";
/// O servidor in-proc, debaixo de [`CHAVE_DO_CLSID`].
pub const CHAVE_DO_SERVIDOR: &str = r"SOFTWARE\Classes\CLSID\{5C75FE52-9204-45F6-B143-58B1AC8048E5}\InprocServer32";
/// O nome amigável da classe (o `NOME_AMIGAVEL` da fonte; o mesmo valor que `DllRegisterServer` e o
/// MSI de agosto escreviam).
pub const NOME_DA_CLASSE: &str = "Quall Virtual Camera Source"; // i18n: fora (registro do Windows)
/// `ThreadingModel = Both`: o que a câmera virtual do próprio Windows usa (conferido no Dell).
pub const MODELO_DE_THREADS: &str = "Both"; // i18n: fora (registro do Windows)
/// O arquivo, dentro de `%ProgramFiles%\Quall` (a pasta que o MSI já usa para o app).
pub const NOME_DA_DLL: &str = "quall_camera_fonte.dll";
/// A pasta, dentro de `%ProgramFiles%`. Só administradores escrevem ali: o Frame Server
/// (`LocalService`) lê e executa, e uma DLL num perfil de usuário não serviria (`instalar.ps1`).
pub const PASTA: &str = "Quall";

/// O caminho da DLL, a partir da pasta `Program Files` que o Windows informa.
pub fn caminho_da_dll(program_files: &str) -> String {
    format!(r"{}\{PASTA}\{NOME_DA_DLL}", program_files.trim_end_matches('\\'))
}

/// Os valores que o registro recebe: `(subchave, nome do valor ou None para o padrão, texto)`.
pub fn valores_do_registro(dll: &str) -> [(&'static str, Option<&'static str>, String); 3] {
    [
        (CHAVE_DO_CLSID, None, NOME_DA_CLASSE.to_string()),
        (CHAVE_DO_SERVIDOR, None, dll.to_string()),
        (CHAVE_DO_SERVIDOR, Some("ThreadingModel"), MODELO_DE_THREADS.to_string()), // i18n: fora (registro do Windows)
    ]
}

/// Dois caminhos do Windows são o mesmo arquivo? Sem diferença de maiúsculas e de barra final.
/// É o que decide se a remoção apaga o arquivo que o registro aponta: **só** o nosso caminho, nunca
/// um que se leu do registro e que poderia ser qualquer coisa.
pub fn mesmo_caminho(a: &str, b: &str) -> bool {
    let n = |s: &str| s.trim().trim_matches('"').replace('/', "\\").trim_end_matches('\\').to_lowercase();
    n(a) == n(b)
}

/// **A DLL embutida confere?** Um PE (`MZ`, `PE\0\0`), de máquina x64 (`0x8664`) e marcado como DLL
/// (`IMAGE_FILE_DLL`). Vazia é a build que não achou a DLL para embutir (`build.rs`).
pub fn conferir_a_dll(b: &[u8]) -> Result<(), &'static str> {
    if b.is_empty() {
        return Err(MOTIVO_SEM_FONTE);
    }
    let u16_em = |i: usize| b.get(i..i + 2).map(|p| u16::from_le_bytes([p[0], p[1]]));
    let u32_em = |i: usize| b.get(i..i + 4).map(|p| u32::from_le_bytes([p[0], p[1], p[2], p[3]]));
    if b.get(..2) != Some(b"MZ") {
        return Err(MOTIVO_FONTE_ESTRANHA);
    }
    let Some(pe) = u32_em(0x3C).map(|v| v as usize) else { return Err(MOTIVO_FONTE_ESTRANHA) };
    if b.get(pe..pe + 4) != Some(b"PE\0\0") {
        return Err(MOTIVO_FONTE_ESTRANHA);
    }
    if u16_em(pe + 4) != Some(0x8664) {
        return Err(MOTIVO_FONTE_ESTRANHA);
    }
    // `Characteristics`, no fim do cabeçalho COFF (20 bytes depois da assinatura).
    match u16_em(pe + 4 + 18) {
        Some(c) if c & 0x2000 != 0 => Ok(()),
        _ => Err(MOTIVO_FONTE_ESTRANHA),
    }
}

// =============================================================================================
// O app tem identidade de pacote?
// =============================================================================================

/// `APPMODEL_ERROR_NO_PACKAGE`: o processo não tem identidade de pacote.
pub const SEM_PACOTE: u32 = 15700;
/// `ERROR_INSUFFICIENT_BUFFER`: a resposta de `GetCurrentPackageFullName` com buffer zero, que só
/// vem com pacote.
pub const BUFFER_CURTO: u32 = 122;

/// O processo veio de um MSIX? Pelo código de `GetCurrentPackageFullName` com buffer de tamanho
/// zero. Um código que ninguém mediu conta como **sem pacote**: o botão de instalar pede o UAC, e
/// o Windows diz se dá; errar para o outro lado seria mandar para a página quem pode instalar.
pub fn tem_pacote_pelo_codigo(codigo: u32) -> bool {
    matches!(codigo, 0 | BUFFER_CURTO)
}

// =============================================================================================
// O pedido ao processo elevado
// =============================================================================================

/// O primeiro argumento do processo elevado (`quall-app.exe --camera-virtual …`). O `main` o
/// procura **antes de tudo**, antes da instância única, do COM, do registro e do `clap`.
pub const ARGUMENTO: &str = "--camera-virtual";
pub const ARGUMENTO_DO_CANO: &str = "--cano";
/// O desinstalador do MSI (ação adiada, como SYSTEM): sem cano, o resultado só pelo código de saída.
/// Só vale com `desinstalar`.
pub const ARGUMENTO_SEM_CANO: &str = "--sem-cano";
/// O prefixo do cano do andamento; depois dele, 32 dígitos hexadecimais minúsculos. Outro prefixo
/// que o dos quadros (`quall-camera-v1-…`, `fonte/src/quadros.rs`): os dois canos não se confundem.
pub const PREFIXO_DO_CANO: &str = r"\\.\pipe\quall-camera-instalador-";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Acao {
    #[default]
    Instalar,
    Desinstalar,
}

impl Acao {
    pub fn verbo(self) -> &'static str {
        match self {
            Acao::Instalar => "instalar",
            Acao::Desinstalar => "desinstalar",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pedido {
    pub acao: Acao,
    /// `None`: o desinstalador do MSI (`--sem-cano`).
    pub cano: Option<String>,
}

pub fn nome_do_cano(aleatorio: u128) -> String {
    format!("{PREFIXO_DO_CANO}{aleatorio:032x}")
}

pub fn cano_valido(s: &str) -> bool {
    s.strip_prefix(PREFIXO_DO_CANO)
        .is_some_and(|r| r.len() == 32 && r.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)))
}

/// Os argumentos (depois do `argv[0]`) são um pedido ao processo elevado? `None`: não são.
/// `Some(Err)`: começam com [`ARGUMENTO`] mas não têm o formato exato — o processo **recusa** e
/// sai sem tocar em nada. Só dois formatos:
///
/// - `--camera-virtual <instalar|desinstalar> --cano <nome>` (o botão dos Ajustes);
/// - `--camera-virtual desinstalar --sem-cano` (o desinstalador do MSI).
pub fn ler_pedido(args: &[String]) -> Option<Result<Pedido, String>> {
    if args.first().map(String::as_str) != Some(ARGUMENTO) {
        return None;
    }
    Some((|| {
        if args.len() == 3 && args[1] == "desinstalar" && args[2] == ARGUMENTO_SEM_CANO {
            return Ok(Pedido { acao: Acao::Desinstalar, cano: None });
        }
        if args.len() != 4 {
            return Err(format!("{} argumentos; o pedido tem exatamente 4", args.len())); // i18n: fora
        }
        let acao = match args[1].as_str() {
            "instalar" => Acao::Instalar,
            "desinstalar" => Acao::Desinstalar,
            outro => return Err(format!("verbo desconhecido: {outro:?}")), // i18n: fora
        };
        if args[2] != ARGUMENTO_DO_CANO {
            return Err(format!("o terceiro argumento é {:?}, e não {ARGUMENTO_DO_CANO}", args[2])); // i18n: fora
        }
        if !cano_valido(&args[3]) {
            return Err("o nome do cano não tem o formato do Quall".into()); // i18n: fora
        }
        Ok(Pedido { acao, cano: Some(args[3].clone()) })
    })())
}

/// Os parâmetros que a janela passa ao `ShellExecuteExW` (sem o exe).
pub fn parametros(acao: Acao, cano: &str) -> String {
    format!("{ARGUMENTO} {} {ARGUMENTO_DO_CANO} {cano}", acao.verbo())
}

// =============================================================================================
// O protocolo do cano (o mesmo do driver)
// =============================================================================================

pub const PASSOS_DA_INSTALACAO: [&str; 4] = [
    "Conferindo a fonte da câmera",            // i18n: chave
    "Copiando para Arquivos de Programas", // i18n: chave
    "Registrando a câmera no Windows",         // i18n: chave
    "Conferindo o registro",                   // i18n: chave
];

pub const PASSOS_DA_DESINSTALACAO: [&str; 3] = [
    "Tirando o registro da câmera",            // i18n: chave
    "Tirando de Arquivos de Programas", // i18n: chave
    "Conferindo que saiu",                     // i18n: chave
];

pub fn passos(acao: Acao) -> &'static [&'static str] {
    match acao {
        Acao::Instalar => &PASSOS_DA_INSTALACAO,
        Acao::Desinstalar => &PASSOS_DA_DESINSTALACAO,
    }
}

/// Uma linha do processo elevado para a janela. Texto de uma linha, UTF-8, terminada em `\n`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Linha {
    Passo(usize),
    Diario(String),
    Ok,
    OkReiniciar,
    /// `falha N chave<TAB>técnico`.
    Falha(usize, String, String),
}

impl Linha {
    pub fn escrever(&self) -> String {
        let s = match self {
            Linha::Passo(n) => format!("passo {n}"),
            Linha::Diario(t) => format!("diario {}", uma_linha(t)),
            Linha::Ok => "ok".into(),
            Linha::OkReiniciar => "ok-reiniciar".into(),
            Linha::Falha(n, c, t) => format!("falha {n} {}\t{}", uma_linha(c), uma_linha(t)),
        };
        s + "\n"
    }

    pub fn ler(s: &str) -> Option<Linha> {
        let s = s.trim_end_matches(['\r', '\n']);
        let (cabeca, resto) = s.split_once(' ').unwrap_or((s, ""));
        match cabeca {
            "passo" => resto.trim().parse().ok().filter(|n| *n >= 1).map(Linha::Passo),
            "diario" => Some(Linha::Diario(resto.to_string())),
            "ok" if resto.is_empty() => Some(Linha::Ok),
            "ok-reiniciar" if resto.is_empty() => Some(Linha::OkReiniciar),
            "falha" => {
                let (n, t) = resto.split_once(' ').unwrap_or((resto, ""));
                let (chave, tecnico) = t.split_once('\t').unwrap_or((t, ""));
                n.parse().ok().map(|n| Linha::Falha(n, chave.to_string(), tecnico.to_string()))
            }
            _ => None,
        }
    }
}

fn uma_linha(t: &str) -> String {
    t.replace(['\r', '\n', '\t'], " ")
}

pub mod saida {
    pub const OK: u32 = 0;
    pub const FALHA: u32 = 1;
    /// O pedido não tinha o formato, ou o processo tem identidade de pacote: nada foi tocado.
    pub const RECUSADO: u32 = 2;
    pub const SEM_ADMIN: u32 = 3;
    pub const OK_REINICIAR: u32 = 3010;
}

// =============================================================================================
// A situação neste computador, e o botão
// =============================================================================================

/// O registro COM da fonte, como se leu.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum Registro {
    /// Sem a chave `InprocServer32` (ou com ela vazia).
    #[default]
    Ausente,
    /// A chave aponta para `caminho`; `existe`: o arquivo está lá.
    Presente { caminho: String, existe: bool },
}

/// O que se lê do computador para decidir a [`Situacao`].
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Leitura {
    /// Identidade de pacote: o Quall da loja. O instalador avulso nunca está "na loja".
    pub pacote: bool,
    /// A arquitetura nativa é x64 (num ARM64 o Frame Server é ARM64 e não carrega a DLL x64).
    pub x64: bool,
    pub registro: Registro,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Situacao {
    /// Sem a fonte registrada, e o Quall pode instalar (o do site).
    #[default]
    Ausente,
    /// Registrada e com o arquivo no lugar: a câmera funciona.
    Instalada,
    /// Registrada, mas o arquivo sumiu: a câmera aparece e não abre. Instalar de novo conserta.
    Quebrada,
    /// O Quall da loja: o MSIX não eleva. `registrada`: a fonte está no sistema (posta pelo
    /// instalador avulso, por um Quall do site ou pela bancada).
    Loja { registrada: bool },
    /// Este Windows não é x64.
    SemSuporte,
}

impl Situacao {
    /// A câmera funciona? É o que o fio das câmeras precisa saber para criar os nós.
    pub fn registrada(self) -> bool {
        matches!(self, Situacao::Instalada | Situacao::Loja { registrada: true })
    }
}

pub fn situacao(l: &Leitura) -> Situacao {
    let presente = matches!(l.registro, Registro::Presente { existe: true, .. });
    if l.pacote {
        return Situacao::Loja { registrada: presente };
    }
    if !l.x64 {
        return Situacao::SemSuporte;
    }
    match l.registro {
        Registro::Ausente => Situacao::Ausente,
        Registro::Presente { existe: true, .. } => Situacao::Instalada,
        Registro::Presente { existe: false, .. } => Situacao::Quebrada,
    }
}

/// O botão do cartão "Instalação da câmera virtual".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Botao {
    /// A caixa que explica, o UAC e a instalação.
    Instalar,
    /// A caixa, o UAC e a remoção.
    Remover,
    /// A página do instalador avulso no navegador (a loja).
    Pagina,
}

/// O botão pela situação; `None` sem botão (Windows sem suporte, ou no meio de um andamento).
pub fn botao(s: Situacao, a: &Andamento) -> Option<Botao> {
    if !pode_comecar(a) {
        return None;
    }
    match s {
        Situacao::Ausente | Situacao::Quebrada => Some(Botao::Instalar),
        Situacao::Instalada => Some(Botao::Remover),
        Situacao::Loja { .. } => Some(Botao::Pagina),
        Situacao::SemSuporte => None,
    }
}

/// O rótulo do botão (chave). Na loja, o mesmo botão diz se baixa para instalar ou para remover.
pub fn rotulo(b: Botao, s: Situacao) -> &'static str {
    match (b, s) {
        (Botao::Instalar, _) => BOTAO_INSTALAR,
        (Botao::Remover, _) => BOTAO_REMOVER,
        (Botao::Pagina, Situacao::Loja { registrada: true }) => BOTAO_PAGINA_REMOVER,
        (Botao::Pagina, _) => BOTAO_PAGINA_INSTALAR,
    }
}

/// O nome para o Narrador do botão (chave).
pub fn nome_acessivel(b: Botao, s: Situacao) -> &'static str {
    match (b, s) {
        (Botao::Instalar, _) => ACESSIVEL_INSTALAR,
        (Botao::Remover, _) => ACESSIVEL_REMOVER,
        (Botao::Pagina, _) => ACESSIVEL_PAGINA,
    }
}

/// A frase da situação no cartão dos Ajustes (chave).
pub fn frase_dos_ajustes(s: Situacao) -> &'static str {
    match s {
        Situacao::Ausente => AJUSTES_AUSENTE,
        Situacao::Instalada => AJUSTES_INSTALADA,
        Situacao::Quebrada => AJUSTES_QUEBRADA,
        Situacao::Loja { registrada: false } => AJUSTES_LOJA,
        Situacao::Loja { registrada: true } => AJUSTES_LOJA_INSTALADA,
        Situacao::SemSuporte => AJUSTES_SEM_SUPORTE,
    }
}

// --- o instalador avulso ---

/// A frase do rodapé do instalador avulso (chave).
pub fn frase_do_instalador(s: Situacao) -> &'static str {
    match s {
        Situacao::Ausente | Situacao::Loja { registrada: false } => INSTALADOR_AUSENTE,
        Situacao::Instalada | Situacao::Loja { registrada: true } => INSTALADOR_INSTALADA,
        Situacao::Quebrada => AJUSTES_QUEBRADA,
        Situacao::SemSuporte => AJUSTES_SEM_SUPORTE,
    }
}

/// Os botões do instalador avulso: (Instalar, Remover) habilitados?
pub fn botoes_do_instalador(s: Situacao, a: &Andamento) -> (bool, bool) {
    let livre = pode_comecar(a);
    let instalar = matches!(s, Situacao::Ausente | Situacao::Quebrada | Situacao::Loja { registrada: false });
    let remover = matches!(s, Situacao::Instalada | Situacao::Quebrada | Situacao::Loja { registrada: true });
    (livre && instalar, livre && remover)
}

/// Pode fechar o instalador avulso agora? Não no meio de uma instalação.
pub fn pode_fechar(a: &Andamento) -> bool {
    pode_comecar(a)
}

// =============================================================================================
// O andamento e o resultado
// =============================================================================================

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Andamento {
    #[default]
    Parado,
    /// Esperando o UAC (passo 0) ou rodando.
    Rodando { acao: Acao, passo: usize },
    Acabou { acao: Acao, resultado: Resultado },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resultado {
    Ok,
    OkReiniciar,
    CanceladoNoUac,
    Falha(usize, String, String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TomDoAviso {
    Info,
    Ambar,
    Vermelho,
}

/// O resultado pelo que chegou: a linha de fim do cano, se veio; senão o código de saída. Sem a
/// linha de fim, nem `exit 0` vira "deu certo": o cano pode ter caído antes do último passo.
pub fn resultado(fim_pelo_cano: Option<&Linha>, ultimo_passo: usize, codigo_de_saida: Option<u32>) -> Resultado {
    match fim_pelo_cano {
        Some(Linha::Ok) => return Resultado::Ok,
        Some(Linha::OkReiniciar) => return Resultado::OkReiniciar,
        Some(Linha::Falha(n, c, t)) => return Resultado::Falha(*n, c.clone(), t.clone()),
        _ => {}
    }
    let f = |n: usize, c: &str, t: String| Resultado::Falha(n, c.to_string(), t);
    match codigo_de_saida {
        Some(saida::RECUSADO) => f(0, MOTIVO_RECUSADO, "exit 2".into()), // i18n: fora
        Some(saida::SEM_ADMIN) => f(0, MOTIVO_SEM_ADMIN, "exit 3".into()), // i18n: fora
        Some(c) => f(ultimo_passo, MOTIVO_SEM_FIM, format!("exit {c}")), // i18n: fora
        None => f(ultimo_passo, MOTIVO_SEM_FIM, "exit ?".into()), // i18n: fora
    }
}

pub fn nome_do_passo(acao: Acao, n: usize) -> Option<&'static str> {
    n.checked_sub(1).and_then(|i| passos(acao).get(i).copied())
}

pub fn pode_comecar(a: &Andamento) -> bool {
    !matches!(a, Andamento::Rodando { .. })
}

/// A frase e o tom de um andamento (chaves); `None` parado.
pub fn frase(a: &Andamento) -> Option<(TomDoAviso, &'static str)> {
    match a {
        Andamento::Parado => None,
        Andamento::Rodando { passo: 0, .. } => Some((TomDoAviso::Info, ESPERANDO_O_UAC)),
        Andamento::Rodando { acao: Acao::Instalar, .. } => Some((TomDoAviso::Info, RODANDO_INSTALAR)),
        Andamento::Rodando { acao: Acao::Desinstalar, .. } => Some((TomDoAviso::Info, RODANDO_DESINSTALAR)),
        Andamento::Acabou { acao, resultado } => Some(match (acao, resultado) {
            (_, Resultado::OkReiniciar) => (TomDoAviso::Ambar, OK_REINICIAR),
            (Acao::Instalar, Resultado::Ok) => (TomDoAviso::Info, OK_INSTALAR),
            (Acao::Desinstalar, Resultado::Ok) => (TomDoAviso::Info, OK_DESINSTALAR),
            (Acao::Instalar, Resultado::CanceladoNoUac) => (TomDoAviso::Ambar, CANCELADO_INSTALAR),
            (Acao::Desinstalar, Resultado::CanceladoNoUac) => (TomDoAviso::Ambar, CANCELADO_DESINSTALAR),
            (Acao::Instalar, Resultado::Falha(..)) => (TomDoAviso::Vermelho, FALHA_INSTALAR),
            (Acao::Desinstalar, Resultado::Falha(..)) => (TomDoAviso::Vermelho, FALHA_DESINSTALAR),
        }),
    }
}

// =============================================================================================
// A página da loja
// =============================================================================================

/// **A página do instalador avulso da câmera** (`quall-camera.exe`): o botão do Quall da loja abre
/// esta página. Mesma casa e mesmo jeito da do driver (`regras_da_tela_estendida::URL_DO_INSTALADOR_DO_DRIVER`,
/// `/quall/#driver`): uma constante só, fácil de trocar. **Ainda não publicada** — a seção `camera`
/// e o download são da frente do site.
pub const URL_DA_PAGINA_DA_CAMERA: &str = "https://queven.com.br/quall/#camera";

// =============================================================================================
// Os textos (chaves da tabela `idioma/camera.rs`)
// =============================================================================================

/// O nome do cartão dos Ajustes.
pub const AJUSTES_NOME: &str = "Instalação da câmera virtual"; // i18n: chave
pub const AJUSTES_AUSENTE: &str = "Não instalada. Instale para os aparelhos aparecerem como câmera no Zoom, no Meet e no OBS."; // i18n: chave
pub const AJUSTES_INSTALADA: &str = "Instalada neste computador."; // i18n: chave
pub const AJUSTES_QUEBRADA: &str = "Registrada, mas o arquivo da câmera sumiu. Instale de novo."; // i18n: chave
pub const AJUSTES_LOJA: &str = "Não instalada. Baixe o instalador da câmera virtual na página do Quall."; // i18n: chave
pub const AJUSTES_LOJA_INSTALADA: &str = "Instalada neste computador. Para tirar, use o instalador da câmera virtual."; // i18n: chave
pub const AJUSTES_SEM_SUPORTE: &str = "Este Windows não é x64: a câmera virtual não roda nele."; // i18n: chave

pub const BOTAO_INSTALAR: &str = "Instalar câmera virtual"; // i18n: chave
pub const BOTAO_REMOVER: &str = "Remover câmera virtual"; // i18n: chave
pub const BOTAO_PAGINA_INSTALAR: &str = "Baixar o instalador da câmera"; // i18n: chave
pub const BOTAO_PAGINA_REMOVER: &str = "Abrir o instalador da câmera"; // i18n: chave
pub const ACESSIVEL_INSTALAR: &str = "Instalar câmera virtual: abre uma caixa que explica antes de instalar"; // i18n: chave
pub const ACESSIVEL_REMOVER: &str = "Remover câmera virtual: abre uma caixa que explica antes de remover"; // i18n: chave
pub const ACESSIVEL_PAGINA: &str = "Instalador da câmera virtual: abre a página do Quall no navegador"; // i18n: chave

/// A caixa de instalar. O corpo em parágrafos separados (sem `\n` dentro das chaves).
pub const CAIXA_TITULO: &str = "Instalar câmera virtual"; // i18n: chave
pub const CAIXA_PERGUNTA: &str = "A câmera virtual precisa ser instalada no Windows"; // i18n: chave
pub const CAIXA_CORPO_O_QUE_E: &str = "Para os aparelhos aparecerem como câmera no Zoom, no Meet e no OBS, o Quall põe a fonte da câmera virtual em Arquivos de Programas e a registra no Windows. Ela vem junto com o Quall; nada é baixado."; // i18n: chave
pub const CAIXA_CORPO_UAC: &str = "O Windows vai pedir permissão de administrador."; // i18n: chave
pub const CAIXA_CORPO_SAI: &str = "Ela sai quando você remover a câmera virtual por aqui."; // i18n: chave
pub const CAIXA_INSTALAR: &str = "Instalar"; // i18n: chave
pub const CAIXA_REMOVER_TITULO: &str = "Remover câmera virtual"; // i18n: chave
pub const CAIXA_REMOVER_PERGUNTA: &str = "Tirar a câmera virtual deste computador?"; // i18n: chave
pub const CAIXA_REMOVER_CORPO: &str = "O Quall tira o registro da câmera virtual e o arquivo dela. Os apps que estiverem com a câmera do Quall aberta perdem a imagem."; // i18n: chave
pub const CAIXA_REMOVER: &str = "Remover"; // i18n: chave

/// O instalador avulso.
pub const INSTALADOR_TITULO: &str = "Instalador da câmera virtual do Quall Studio"; // i18n: chave
pub const INSTALADOR_FECHAR: &str = "Fechar"; // i18n: chave
pub const INSTALADOR_AUSENTE: &str = "A câmera virtual não está instalada neste computador."; // i18n: chave
pub const INSTALADOR_INSTALADA: &str = "A câmera virtual está instalada neste computador."; // i18n: chave
pub const INSTALADOR_JA_PODE: &str = "Pode fechar: o Quall já vê a câmera virtual, mesmo aberto."; // i18n: chave
pub const INSTALADOR_DETALHES: &str = "Detalhes"; // i18n: chave

/// Os motivos de falha (o processo elevado manda a chave; a janela traduz).
pub const MOTIVO_SEM_FONTE: &str = "a fonte da câmera não veio dentro deste Quall"; // i18n: chave
pub const MOTIVO_FONTE_ESTRANHA: &str = "a fonte da câmera dentro do Quall não confere"; // i18n: chave
pub const MOTIVO_PLATAFORMA: &str = "este Windows não é x64"; // i18n: chave
pub const MOTIVO_OUTRA: &str = "outra instalação da câmera está em andamento"; // i18n: chave
pub const MOTIVO_PASTA: &str = "não deu para preparar a pasta do Quall"; // i18n: chave
pub const MOTIVO_COPIA: &str = "não deu para copiar a fonte da câmera"; // i18n: chave
pub const MOTIVO_REGISTRO: &str = "o Windows não aceitou o registro da câmera"; // i18n: chave
pub const MOTIVO_CONFERENCIA: &str = "o registro da câmera não ficou como devia"; // i18n: chave
pub const MOTIVO_REGISTRO_FICOU: &str = "o registro da câmera não saiu"; // i18n: chave
pub const MOTIVO_ARQUIVO_FICOU: &str = "o arquivo da câmera não saiu"; // i18n: chave
pub const MOTIVO_PACOTE: &str = "o Quall da loja não instala a câmera por dentro"; // i18n: chave
pub const MOTIVO_RECUSADO: &str = "o pedido foi recusado"; // i18n: chave
pub const MOTIVO_SEM_ADMIN: &str = "faltou a permissão de administrador"; // i18n: chave
pub const MOTIVO_SEM_FIM: &str = "o processo da câmera terminou sem dizer como"; // i18n: chave
pub const MOTIVO_NAO_ABRIU: &str = "o Windows não abriu o processo da câmera"; // i18n: chave

/// O andamento e o resultado.
pub const ESPERANDO_O_UAC: &str = "Esperando a permissão do Windows…"; // i18n: chave
pub const RODANDO_INSTALAR: &str = "Instalando a câmera virtual — passo {} de {}: {}…"; // i18n: chave
pub const RODANDO_DESINSTALAR: &str = "Removendo a câmera virtual — passo {} de {}: {}…"; // i18n: chave
pub const OK_INSTALAR: &str = "Câmera virtual instalada. Os aparelhos já aparecem como câmera nos outros apps."; // i18n: chave
pub const OK_DESINSTALAR: &str = "Câmera virtual removida."; // i18n: chave
pub const OK_REINICIAR: &str = "Pronto, mas o Windows pede para reiniciar o computador antes de usar."; // i18n: chave
pub const CANCELADO_INSTALAR: &str = "Instalação cancelada: o Windows não recebeu a permissão. Nada foi instalado."; // i18n: chave
pub const CANCELADO_DESINSTALAR: &str = "Remoção cancelada: o Windows não recebeu a permissão. Nada foi tirado."; // i18n: chave
pub const FALHA_INSTALAR: &str = "Não deu para instalar a câmera virtual ({}): {}."; // i18n: chave
pub const FALHA_DESINSTALAR: &str = "Não deu para remover a câmera virtual ({}): {}."; // i18n: chave
pub const ANTES_DE_COMECAR: &str = "antes de começar"; // i18n: chave

#[cfg(test)]
mod testes {
    use super::*;

    fn a(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_chave_do_registro_e_a_do_clsid() {
        assert!(CHAVE_DO_CLSID.ends_with(CLSID));
        assert_eq!(CHAVE_DO_SERVIDOR, format!(r"{CHAVE_DO_CLSID}\InprocServer32"));
        assert_eq!(caminho_da_dll(r"C:\Program Files"), r"C:\Program Files\Quall\quall_camera_fonte.dll");
        assert_eq!(caminho_da_dll(r"D:\Programas\"), r"D:\Programas\Quall\quall_camera_fonte.dll");
        let v = valores_do_registro(r"C:\Program Files\Quall\quall_camera_fonte.dll");
        assert_eq!(v[0], (CHAVE_DO_CLSID, None, "Quall Virtual Camera Source".to_string()));
        assert_eq!(v[1].2, r"C:\Program Files\Quall\quall_camera_fonte.dll");
        assert_eq!(v[2], (CHAVE_DO_SERVIDOR, Some("ThreadingModel"), "Both".to_string()));
    }

    /// **Os valores são os mesmos do MSI de agosto e do `DllRegisterServer`**, conferidos no texto: a
    /// câmera instalada por qualquer caminho é a mesma.
    #[test]
    fn os_valores_sao_os_da_fonte() {
        let fonte = include_str!("../../../integrations/camera-windows/fonte/src/lib.rs");
        assert!(fonte.contains(&format!("pub const CLSID_TEXTO: &str = \"{CLSID}\";")));
        assert!(fonte.contains(&format!("const NOME_AMIGAVEL: &str = \"{NOME_DA_CLASSE}\";")));
        assert!(fonte.contains("Some(\"ThreadingModel\"), \"Both\")"));
        let quadros = include_str!("../../../integrations/camera-windows/fonte/src/quadros.rs");
        assert!(!quadros.contains("quall-camera-instalador-"), "o cano do instalador não pode ser o dos quadros");
    }

    #[test]
    fn mesmo_caminho_ignora_maiusculas_aspas_e_barra() {
        assert!(mesmo_caminho(r"C:\Program Files\Quall\quall_camera_fonte.dll", r#""c:\program files\quall\QUALL_CAMERA_FONTE.DLL""#));
        assert!(mesmo_caminho(r"C:/Program Files/Quall/x.dll", r"C:\Program Files\Quall\x.dll"));
        assert!(!mesmo_caminho(r"C:\Program Files\Quall\quall_camera_fonte.dll", r"C:\Users\x\quall_camera_fonte.dll"));
    }

    /// Um cabeçalho PE mínimo: `MZ`, `e_lfanew` = 0x40, `PE\0\0`, a máquina e as características.
    fn pe(maquina: u16, caracteristicas: u16) -> Vec<u8> {
        let mut b = vec![0u8; 0x40 + 24];
        b[..2].copy_from_slice(b"MZ");
        b[0x3C..0x40].copy_from_slice(&0x40u32.to_le_bytes());
        b[0x40..0x44].copy_from_slice(b"PE\0\0");
        b[0x44..0x46].copy_from_slice(&maquina.to_le_bytes());
        b[0x40 + 4 + 18..0x40 + 4 + 20].copy_from_slice(&caracteristicas.to_le_bytes());
        b
    }

    #[test]
    fn a_dll_embutida_tem_de_ser_um_pe_x64_de_dll() {
        assert_eq!(conferir_a_dll(&pe(0x8664, 0x2022)), Ok(()));
        assert_eq!(conferir_a_dll(&[]), Err(MOTIVO_SEM_FONTE), "a build sem a DLL");
        assert_eq!(conferir_a_dll(&pe(0xAA64, 0x2022)), Err(MOTIVO_FONTE_ESTRANHA), "ARM64");
        assert_eq!(conferir_a_dll(&pe(0x014C, 0x2102)), Err(MOTIVO_FONTE_ESTRANHA), "x86");
        assert_eq!(conferir_a_dll(&pe(0x8664, 0x0022)), Err(MOTIVO_FONTE_ESTRANHA), "um .exe, não uma DLL");
        assert_eq!(conferir_a_dll(b"MZ"), Err(MOTIVO_FONTE_ESTRANHA), "curta");
        let mut ruim = pe(0x8664, 0x2022);
        ruim[0x3C..0x40].copy_from_slice(&0xFFFF_FFF0u32.to_le_bytes());
        assert_eq!(conferir_a_dll(&ruim), Err(MOTIVO_FONTE_ESTRANHA), "e_lfanew fora do arquivo");
    }

    #[test]
    fn o_pacote_sai_do_codigo() {
        assert!(!tem_pacote_pelo_codigo(SEM_PACOTE));
        assert!(tem_pacote_pelo_codigo(BUFFER_CURTO));
        assert!(tem_pacote_pelo_codigo(0));
        assert!(!tem_pacote_pelo_codigo(87), "um código que ninguém mediu pede o UAC");
    }

    #[test]
    fn o_processo_elevado_so_aceita_o_formato_exato() {
        let cano = nome_do_cano(0x0123_4567_89ab_cdef_0011_2233_4455_6677);
        assert_eq!(cano, r"\\.\pipe\quall-camera-instalador-0123456789abcdef0011223344556677");
        assert!(cano_valido(&cano));
        assert_eq!(
            ler_pedido(&a(&["--camera-virtual", "instalar", "--cano", &cano])),
            Some(Ok(Pedido { acao: Acao::Instalar, cano: Some(cano.clone()) }))
        );
        assert_eq!(ler_pedido(&a(&["--camera-virtual", "desinstalar", "--cano", &cano])).unwrap().unwrap().acao, Acao::Desinstalar);
        assert_eq!(ler_pedido(&a(&["--camera-virtual", "desinstalar", "--sem-cano"])), Some(Ok(Pedido { acao: Acao::Desinstalar, cano: None })));
        assert_eq!(ler_pedido(&a(&[])), None);
        assert_eq!(ler_pedido(&a(&["--sem-cameras-virtuais"])), None, "a bandeira do app não é pedido");
        for ruim in [
            a(&["--camera-virtual"]),
            a(&["--camera-virtual", "instalar", "--cano", &cano, "extra"]),
            a(&["--camera-virtual", "INSTALAR", "--cano", &cano]),
            a(&["--camera-virtual", "apagar", "--cano", &cano]),
            a(&["--camera-virtual", "instalar", "--dll", &cano]),
            a(&["--camera-virtual", "instalar", "--cano", r"\\.\pipe\outro"]),
            a(&["--camera-virtual", "instalar", "--cano", r"\\.\pipe\quall-driver-0123456789abcdef0011223344556677"]),
            a(&["--camera-virtual", "instalar", "--cano", r"\\servidor\pipe\quall-camera-instalador-0123456789abcdef0011223344556677"]),
            a(&["--camera-virtual", "instalar", "--cano", r"C:\Users\x\quall_camera_fonte.dll"]),
            a(&["--camera-virtual", "instalar", "--cano", &format!("{cano}0")]),
            a(&["--camera-virtual", "instalar", "--sem-cano"]),
            a(&["--camera-virtual", "desinstalar", "--sem-cano", "x"]),
        ] {
            assert!(matches!(ler_pedido(&ruim), Some(Err(_))), "{ruim:?}");
        }
        assert_eq!(parametros(Acao::Instalar, &cano), format!("--camera-virtual instalar --cano {cano}"));
        let ida: Vec<String> = parametros(Acao::Desinstalar, &cano).split(' ').map(str::to_string).collect();
        assert_eq!(ler_pedido(&ida).unwrap().unwrap().acao, Acao::Desinstalar, "o que a janela manda é o que o elevado aceita");
    }

    #[test]
    fn as_linhas_vao_e_voltam() {
        for l in [
            Linha::Passo(2),
            Linha::Diario("camera: copiada".into()),
            Linha::Ok,
            Linha::OkReiniciar,
            Linha::Falha(3, MOTIVO_REGISTRO.into(), "RegSetValueExW: 0x00000005".into()),
        ] {
            assert_eq!(Linha::ler(&l.escrever()), Some(l.clone()));
        }
        assert_eq!(Linha::ler(&Linha::Diario("a\nb\tc".into()).escrever()), Some(Linha::Diario("a b c".into())));
        assert_eq!(Linha::ler("passo 0"), None);
        assert_eq!(Linha::ler("qualquer"), None);
    }

    #[test]
    fn o_resultado_sem_o_fim_pelo_cano_nunca_e_ok() {
        assert_eq!(resultado(Some(&Linha::Ok), 4, Some(0)), Resultado::Ok);
        assert_eq!(resultado(Some(&Linha::Falha(2, MOTIVO_COPIA.into(), "x".into())), 2, Some(1)), Resultado::Falha(2, MOTIVO_COPIA.into(), "x".into()));
        assert_eq!(resultado(None, 4, Some(0)), Resultado::Falha(4, MOTIVO_SEM_FIM.into(), "exit 0".into()));
        assert_eq!(resultado(None, 0, Some(2)), Resultado::Falha(0, MOTIVO_RECUSADO.into(), "exit 2".into()));
        assert_eq!(resultado(None, 0, Some(3)), Resultado::Falha(0, MOTIVO_SEM_ADMIN.into(), "exit 3".into()));
        assert_eq!(resultado(None, 1, None), Resultado::Falha(1, MOTIVO_SEM_FIM.into(), "exit ?".into()));
    }

    fn le(pacote: bool, x64: bool, registro: Registro) -> Situacao {
        situacao(&Leitura { pacote, x64, registro })
    }

    #[test]
    fn a_situacao_em_cada_computador() {
        let boa = Registro::Presente { caminho: r"C:\Program Files\Quall\quall_camera_fonte.dll".into(), existe: true };
        let sumida = Registro::Presente { caminho: r"C:\Program Files\Quall\quall_camera_fonte.dll".into(), existe: false };
        assert_eq!(le(false, true, Registro::Ausente), Situacao::Ausente);
        assert_eq!(le(false, true, boa.clone()), Situacao::Instalada);
        assert_eq!(le(false, true, sumida.clone()), Situacao::Quebrada);
        assert_eq!(le(false, false, boa.clone()), Situacao::SemSuporte);
        assert_eq!(le(true, true, boa.clone()), Situacao::Loja { registrada: true });
        assert_eq!(le(true, true, sumida), Situacao::Loja { registrada: false });
        assert_eq!(le(true, false, Registro::Ausente), Situacao::Loja { registrada: false }, "a loja manda à página mesmo assim");
        assert!(Situacao::Instalada.registrada());
        assert!(Situacao::Loja { registrada: true }.registrada());
        for s in [Situacao::Ausente, Situacao::Quebrada, Situacao::SemSuporte, Situacao::Loja { registrada: false }] {
            assert!(!s.registrada(), "{s:?}");
        }
    }

    #[test]
    fn o_botao_e_a_frase_de_cada_situacao() {
        let p = Andamento::Parado;
        assert_eq!(botao(Situacao::Ausente, &p), Some(Botao::Instalar));
        assert_eq!(botao(Situacao::Quebrada, &p), Some(Botao::Instalar));
        assert_eq!(botao(Situacao::Instalada, &p), Some(Botao::Remover));
        assert_eq!(botao(Situacao::Loja { registrada: false }, &p), Some(Botao::Pagina));
        assert_eq!(botao(Situacao::Loja { registrada: true }, &p), Some(Botao::Pagina));
        assert_eq!(botao(Situacao::SemSuporte, &p), None);
        let rodando = Andamento::Rodando { acao: Acao::Instalar, passo: 0 };
        assert_eq!(botao(Situacao::Ausente, &rodando), None, "um de cada vez");
        assert_eq!(rotulo(Botao::Pagina, Situacao::Loja { registrada: true }), BOTAO_PAGINA_REMOVER);
        assert_eq!(rotulo(Botao::Pagina, Situacao::Loja { registrada: false }), BOTAO_PAGINA_INSTALAR);
        assert_eq!(rotulo(Botao::Instalar, Situacao::Quebrada), BOTAO_INSTALAR);
        assert_eq!(frase_dos_ajustes(Situacao::Loja { registrada: true }), AJUSTES_LOJA_INSTALADA);
        assert_eq!(frase_dos_ajustes(Situacao::Quebrada), AJUSTES_QUEBRADA);
        // O avulso: nunca "da loja"; remove a quebrada também (tira o registro que aponta para o nada).
        assert_eq!(botoes_do_instalador(Situacao::Ausente, &p), (true, false));
        assert_eq!(botoes_do_instalador(Situacao::Instalada, &p), (false, true));
        assert_eq!(botoes_do_instalador(Situacao::Quebrada, &p), (true, true));
        assert_eq!(botoes_do_instalador(Situacao::SemSuporte, &p), (false, false));
        assert_eq!(botoes_do_instalador(Situacao::Ausente, &rodando), (false, false));
        assert!(!pode_fechar(&rodando));
        assert_eq!(frase_do_instalador(Situacao::Instalada), INSTALADOR_INSTALADA);
    }

    #[test]
    fn as_frases_do_andamento() {
        assert_eq!(frase(&Andamento::Parado), None);
        assert_eq!(frase(&Andamento::Rodando { acao: Acao::Instalar, passo: 0 }), Some((TomDoAviso::Info, ESPERANDO_O_UAC)));
        assert_eq!(frase(&Andamento::Rodando { acao: Acao::Desinstalar, passo: 2 }), Some((TomDoAviso::Info, RODANDO_DESINSTALAR)));
        let acabou = |acao, resultado| frase(&Andamento::Acabou { acao, resultado }).unwrap();
        assert_eq!(acabou(Acao::Instalar, Resultado::Ok), (TomDoAviso::Info, OK_INSTALAR));
        assert_eq!(acabou(Acao::Desinstalar, Resultado::CanceladoNoUac), (TomDoAviso::Ambar, CANCELADO_DESINSTALAR));
        assert_eq!(acabou(Acao::Instalar, Resultado::Falha(1, "x".into(), String::new())), (TomDoAviso::Vermelho, FALHA_INSTALAR));
        assert_eq!(nome_do_passo(Acao::Instalar, 1), Some(PASSOS_DA_INSTALACAO[0]));
        assert_eq!(nome_do_passo(Acao::Instalar, 0), None);
        assert_eq!(nome_do_passo(Acao::Desinstalar, 4), None);
        for chave in [RODANDO_INSTALAR, RODANDO_DESINSTALAR] {
            assert_eq!(chave.matches("{}").count(), 3, "passo, total e nome");
        }
        for chave in [FALHA_INSTALAR, FALHA_DESINSTALAR] {
            assert_eq!(chave.matches("{}").count(), 2, "o passo e o motivo");
        }
    }

    #[test]
    fn a_pagina_e_a_casa_do_driver() {
        assert!(URL_DA_PAGINA_DA_CAMERA.starts_with("https://queven.com.br/quall/#"));
        assert!(URL_DA_PAGINA_DA_CAMERA.ends_with("#camera"));
    }
}
