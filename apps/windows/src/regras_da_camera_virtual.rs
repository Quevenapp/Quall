//! **A câmera virtual embutida no Quall, sem Win32** (12/10/2026): o interruptor "Câmera virtual"
//! dos Ajustes, o que ele guarda, que câmeras devem existir, o que fazer para chegar lá, e a frase
//! do cartão.
//!
//! # O desenho, em quatro frases
//!
//! - **A câmera existe enquanto o Quall estiver aberto.** `MFVirtualCameraLifetime_Session` com
//!   `MFVirtualCameraAccess_CurrentUser` (o que `baia.rs` já fazia): sem administrador, e o nó some
//!   quando o objeto é solto ou o processo morre — o que resolve o nó que sobrava na desinstalação,
//!   porque não há nó de sistema para sobrar.
//! - **O interruptor manda.** Ligado (o padrão, que é o comportamento de antes desta rodada), cada
//!   aparelho pareado ganha a sua câmera; desligado, nenhuma — e a escolha fica guardada em
//!   `camera-virtual.txt` em `%APPDATA%\Quall`, ao lado do `baias.json`.
//! - **Quem cria e solta as câmeras é um fio próprio, em apartamento multithread**
//!   (`fio_das_cameras.rs`), nunca a thread da janela: a Microsoft escreve que app empacotado
//!   **não** pode chamar `MFCreateVirtualCamera` na thread de interface, porque a pergunta de
//!   consentimento da câmera trava ali. Este módulo só diz *o que* o fio faz ([`planejar`]).
//! - **Um CLSID só, o registrado no sistema** (tarde de 12/10/2026): a fonte em `HKLM`, posta pelo
//!   instalador da câmera (`regras_da_instalacao_da_camera.rs`). Sem ela registrada
//!   ([`Situacao::instalada`]), o fio não cria câmera nenhuma: `MFCreateVirtualCamera` com uma classe
//!   que o Frame Server não acha devolve `0x80070003`, o que o Quall do pacote mediu no Dell em 12/10 com o
//!   CLSID declarado só no manifesto MSIX (`docs/camera-virtual.md`, "Câmera embutida no pacote").
//!
//! # O que este módulo não sabe
//!
//! O cartão diz quantas câmeras o Quall **criou**, não quantas entregam quadro: o Windows não
//! conta ao criador quando uma fonte falha dentro do Frame Server.
//!
//! Os textos são chaves da tabela de tradução (`idioma/janela.rs`): quem mostra passa por `t`/`tf`.
//! Assim o módulo fica sem dependência nenhuma e os testes rodam em qualquer máquina, até com
//! `rustc --test` direto neste arquivo.

// =============================================================================================
// O que o interruptor guarda
// =============================================================================================

/// O nome do arquivo em `%APPDATA%\Quall`, ao lado do `baias.json` (`baias.rs`).
pub const ARQUIVO_DA_PREFERENCIA: &str = "camera-virtual.txt";

/// A escolha guardada. Sem arquivo, ou com um que não se entende, **ligada**: é o comportamento
/// de antes do interruptor existir, e quem nunca tocou nele não pode perder a câmera numa
/// atualização.
pub fn ler_preferencia(conteudo: Option<&str>) -> bool {
    let Some(c) = conteudo else { return true };
    let c = c.strip_prefix('\u{feff}').unwrap_or(c).trim();
    !c.eq_ignore_ascii_case("desligada")
}

/// O conteúdo do arquivo para a escolha.
pub fn escrever_preferencia(ligada: bool) -> &'static str {
    if ligada {
        "ligada\n"
    } else {
        "desligada\n"
    }
}

// =============================================================================================
// Que câmeras devem existir, e o que fazer para chegar lá
// =============================================================================================

/// Os nomes das câmeras que **devem** existir agora: uma por aparelho conhecido, se a câmera está
/// permitida nesta abertura (`--sem-cameras-virtuais` tira), **instalada no Windows** (a fonte
/// registrada em `HKLM`, `regras_da_instalacao_da_camera.rs`) e ligada no interruptor. Instalar ou
/// remover com o Quall aberto muda a lista na hora: o fio cria ou solta sem fechar o app.
///
/// Ordenados e sem repetição. Repetição é caso real: dois aparelhos com o mesmo nome dariam dois
/// pedidos do mesmo nó, e o nó é chaveado por CLSID **+ nome** (medido em 27/08/2026) — o segundo
/// `Start` falharia com `MF_E_INVALIDREQUEST`. Uma câmera por nome é o que o Windows aceita.
pub fn desejadas<'a>(permitida: bool, instalada: bool, ligada: bool, conhecidos: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    if !permitida || !instalada || !ligada {
        return Vec::new();
    }
    let mut v: Vec<String> = conhecidos.into_iter().filter(|n| !n.trim().is_empty()).map(str::to_string).collect();
    v.sort();
    v.dedup();
    v
}

/// O que o fio das câmeras faz para ir de `vivas` a `desejadas`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plano {
    /// Soltar primeiro: um aparelho renomeado libera o nome antigo antes de o novo nascer.
    pub soltar: Vec<String>,
    pub criar: Vec<String>,
}

impl Plano {
    pub fn vazio(&self) -> bool {
        self.soltar.is_empty() && self.criar.is_empty()
    }
}

/// A diferença entre o que existe e o que deve existir. Uma câmera viva que continua desejada
/// **não** é recriada: recriar é derrubar a chamada de quem está com ela aberta.
pub fn planejar(desejadas: &[String], vivas: &[String]) -> Plano {
    let soltar = vivas.iter().filter(|v| !desejadas.contains(v)).cloned().collect();
    let mut criar: Vec<String> = desejadas.iter().filter(|d| !vivas.contains(d)).cloned().collect();
    criar.dedup();
    Plano { soltar, criar }
}

// =============================================================================================
// As baias: uma por nome de câmera, nunca uma por aparelho
// =============================================================================================
//
// **O defeito medido no Dell em 13/10/2026** (MSI 1.0.13): com o S24 transmitindo, a câmera
// "SM-S928B" mostrava só a placa de espera (o iPhone 7, a imagem), e o diário repetia quatro falhas
// do cano a cada 300 ms. O nome do cano sai do **nome da câmera** (`cano_do_nome`, FNV do nome), e a
// baia era guardada por **aparelho** (`device_id`). O S24 foi reinstalado e voltou com outra
// identidade e o mesmo nome; o `baias.json` nunca esquece um aparelho, então havia **duas baias no
// mesmo cano** (4 instâncias cada; o cano aceita 8, e da terceira em diante os fios falham sempre).
// O Frame Server lia o cano de uma baia, e a sessão publicava o vídeo noutra: placa na câmera,
// `publicados=0 sem_leitor=…` no fim da sessão. A regra daqui: **uma baia por nome** — o mesmo nome
// que dá o cano e o nó.

/// As baias que a abertura sobe, pelo `baias.json` (`(device_id, nome)`): uma por **nome**,
/// ordenadas, sem nome vazio. Dois aparelhos com o mesmo nome (o reinstalado, ou dois do mesmo
/// modelo) dividem a câmera, como já dividiam o nó.
pub fn baias_da_abertura<'a>(conhecidos: impl IntoIterator<Item = (&'a str, &'a str)>) -> Vec<String> {
    let mut v: Vec<String> = conhecidos.into_iter().map(|(_, n)| n).filter(|n| !n.trim().is_empty()).map(str::to_string).collect();
    v.sort();
    v.dedup();
    v
}

/// O que fazer quando um aparelho conecta com um nome.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AoConectar {
    /// Não há baia com este nome: sobe uma. Com baia, **reaproveita** (nunca duas no mesmo cano).
    pub abrir: bool,
    /// O nome antigo deste aparelho (ele foi renomeado), quando nenhum outro aparelho o usa: a baia
    /// dele sai. Usado por outro, fica.
    pub soltar: Option<String>,
}

/// `aparelhos`: `device_id → nome` de quem já tem câmera; `abertas`: os nomes com baia.
pub fn ao_conectar(aparelhos: &std::collections::BTreeMap<String, String>, abertas: &[String], device_id: &str, nome: &str) -> AoConectar {
    let soltar = aparelhos
        .get(device_id)
        .filter(|antigo| antigo.as_str() != nome)
        .filter(|antigo| !aparelhos.iter().any(|(id, n)| id != device_id && n == *antigo))
        .filter(|antigo| abertas.contains(antigo))
        .cloned();
    AoConectar { abrir: !abertas.iter().any(|a| a == nome), soltar }
}

/// **A espera depois de uma falha do cano**, crescente: 300 ms, 600 ms, 1,2 s… até 5 s. Antes eram
/// 300 ms fixos: uma falha que não passa (o cano lotado) enchia o diário com quatro linhas por volta.
pub fn espera_do_cano(falhas_seguidas: u32) -> std::time::Duration {
    let n = falhas_seguidas.clamp(1, 6) - 1;
    std::time::Duration::from_millis((300u64 << n).min(5_000))
}

/// Diz a falha no diário? A primeira, e depois uma a cada 10 seguidas (com a espera de 5 s, uma
/// linha a cada ~50 s por fio).
pub fn dizer_falha_do_cano(falhas_seguidas: u32) -> bool {
    falhas_seguidas == 1 || falhas_seguidas % 10 == 0
}

// =============================================================================================
// As câmeras deste computador: lembrar, limpar e remover (13/10/2026)
// =============================================================================================
//
// O pedido do Bruno: *"mesmo excluindo os pareamentos não tem opção de excluir as câmeras já
// conectadas"*. O `baias.json` só acrescentava, e o Dell tinha três "SM-S928B". Agora:
//
// - **esquecer os pareamentos** tira as câmeras dos aparelhos esquecidos (`baias.rs`);
// - os Ajustes listam as câmeras e removem uma ou todas, **sem desparear**: a câmera volta quando o
//   aparelho transmitir de novo para este computador;
// - **na abertura**, sai o que é velho ([`limpar_na_abertura`]): o aparelho que não está mais nos
//   pares e não transmite há [`DIAS_PARA_ESQUECER`] dias, e as entradas repetidas de um nome.

/// Os dias sem transmitir, para um aparelho fora dos pares perder a câmera. 30: um mês cobre a
/// pessoa que usa o celular como câmera uma vez por semana e viaja, sem guardar o lixo de um
/// aparelho reinstalado por mais que isso.
pub const DIAS_PARA_ESQUECER: u64 = 30;
const SEGUNDOS_POR_DIA: u64 = 86_400;

/// Uma entrada do `baias.json`: o aparelho, o nome da câmera e quando ele transmitiu por último para
/// este computador (segundos desde 1970). `None`: entrada do formato antigo, sem a data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entrada {
    pub device_id: String,
    pub nome: String,
    pub visto_em: Option<u64>,
}

/// **A limpeza da abertura.** `pareado` diz se o aparelho ainda está no `pares.json`.
///
/// - Entrada sem nome sai.
/// - Entrada sem data (o formato antigo) ganha `agora`: ninguém perde a câmera numa atualização;
///   ela só vence daqui a [`DIAS_PARA_ESQUECER`] dias, se o aparelho não estiver nos pares.
/// - Fora dos pares e sem transmitir há mais de [`DIAS_PARA_ESQUECER`] dias: sai.
/// - **Um nome, uma entrada**: das repetidas, fica a do aparelho pareado, e entre iguais a vista por
///   último (empate: o maior id, para ser determinístico). A câmera é por nome (`ao_conectar`), e o
///   aparelho que perdeu a entrada a ganha de volta quando transmitir.
///
/// Devolve as entradas que ficam, ordenadas por nome.
pub fn limpar_na_abertura(entradas: Vec<Entrada>, pareado: impl Fn(&str) -> bool, agora: u64) -> Vec<Entrada> {
    let limite = DIAS_PARA_ESQUECER * SEGUNDOS_POR_DIA;
    let mut vivas: Vec<(bool, Entrada)> = entradas
        .into_iter()
        .filter(|e| !e.nome.trim().is_empty())
        .map(|mut e| {
            e.visto_em = Some(e.visto_em.unwrap_or(agora));
            (pareado(&e.device_id), e)
        })
        .filter(|(par, e)| *par || agora.saturating_sub(e.visto_em.unwrap_or(agora)) <= limite)
        .collect();
    // A melhor primeiro, dentro de cada nome; depois um por nome.
    vivas.sort_by(|(pa, a), (pb, b)| {
        a.nome
            .cmp(&b.nome)
            .then(pb.cmp(pa))
            .then(b.visto_em.cmp(&a.visto_em))
            .then(b.device_id.cmp(&a.device_id))
    });
    vivas.dedup_by(|(_, b), (_, a)| a.nome == b.nome);
    vivas.into_iter().map(|(_, e)| e).collect()
}

/// As entradas que ficam quando a câmera `nome` é removida (todas as do nome: a câmera é uma só).
pub fn sem_o_nome(entradas: Vec<Entrada>, nome: &str) -> Vec<Entrada> {
    entradas.into_iter().filter(|e| e.nome != nome).collect()
}

/// Os nomes que perdem a câmera quando estes aparelhos são esquecidos: os deles, menos os que outro
/// aparelho (que fica) ainda usa.
pub fn nomes_que_saem(entradas: &[Entrada], esquecidos: &[String]) -> Vec<String> {
    let mut v: Vec<String> = entradas
        .iter()
        .filter(|e| esquecidos.contains(&e.device_id))
        .map(|e| e.nome.clone())
        .filter(|n| !entradas.iter().any(|o| &o.nome == n && !esquecidos.contains(&o.device_id)))
        .collect();
    v.sort();
    v.dedup();
    v
}

/// Uma câmera na lista dos Ajustes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinhaDaCamera {
    pub nome: String,
    /// Alguém lê o cano agora (um app está com a câmera aberta).
    pub em_uso: bool,
}

pub const CAMERAS_TITULO: &str = "Câmeras deste computador"; // i18n: chave
pub const CAMERAS_NENHUMA: &str = "Nenhuma ainda: a câmera de um aparelho aparece quando ele transmitir para cá."; // i18n: chave
pub const CAMERAS_UMA: &str = "1 câmera: {}."; // i18n: chave
pub const CAMERAS_VARIAS: &str = "{} câmeras: {}."; // i18n: chave
pub const CAMERAS_E_MAIS: &str = "{} e mais {}"; // i18n: chave
pub const CAMERAS_EM_USO: &str = "{} (em uso agora)"; // i18n: chave
pub const CAMERAS_GERENCIAR: &str = "Gerenciar câmeras"; // i18n: chave
pub const CAMERAS_GERENCIAR_ACESSIVEL: &str = "Gerenciar câmeras: abre a lista para remover uma câmera ou todas"; // i18n: chave
/// A caixa da lista.
pub const CAIXA_CAMERAS_PERGUNTA: &str = "Escolha a câmera para remover"; // i18n: chave
pub const CAIXA_CAMERAS_CORPO: &str = "Remover tira a câmera deste computador sem desfazer o pareamento. Ela volta quando o aparelho transmitir de novo para este computador."; // i18n: chave
pub const CAIXA_CAMERAS_REMOVER: &str = "Remover"; // i18n: chave
pub const CAIXA_CAMERAS_REMOVER_TODAS: &str = "Remover todas"; // i18n: chave
pub const CAIXA_CAMERAS_FECHAR: &str = "Fechar"; // i18n: chave
/// A linha de uma câmera na caixa, com o aviso de que volta.
pub const CAIXA_CAMERAS_LINHA: &str = "{} — volta se o aparelho transmitir de novo"; // i18n: chave
pub const CAIXA_CAMERAS_LINHA_EM_USO: &str = "{} — em uso agora; volta se o aparelho transmitir de novo"; // i18n: chave

/// Quantos nomes a frase do cartão mostra antes do "e mais N" (o cartão tem uma linha).
pub const NOMES_NA_FRASE: usize = 2;

/// A frase do cartão: a chave e as partes, **sem traduzir** (os nomes são dos aparelhos; quem mostra
/// passa as chaves por `tf`). `None` nas partes: a frase não tem lacuna.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FraseDasCameras {
    Nenhuma,
    /// `(quantas, lista)`; a lista já com "(em uso agora)" e "e mais N" montados pela função `montar`.
    Lista { quantas: usize, nomes: Vec<(String, bool)>, mais: usize },
}

pub fn frase_das_cameras(linhas: &[LinhaDaCamera]) -> FraseDasCameras {
    if linhas.is_empty() {
        return FraseDasCameras::Nenhuma;
    }
    // As em uso primeiro: é o que a pessoa procura quando abre a lista.
    let mut v: Vec<&LinhaDaCamera> = linhas.iter().collect();
    v.sort_by(|a, b| b.em_uso.cmp(&a.em_uso).then(a.nome.cmp(&b.nome)));
    let nomes = v.iter().take(NOMES_NA_FRASE).map(|l| (l.nome.clone(), l.em_uso)).collect();
    FraseDasCameras::Lista { quantas: linhas.len(), nomes, mais: linhas.len().saturating_sub(NOMES_NA_FRASE) }
}

// =============================================================================================
// Por que uma câmera não subiu
// =============================================================================================

/// `E_ACCESSDENIED`: a privacidade da câmera do Windows nega o app (a própria documentação de
/// `MFCreateVirtualCamera`), ou faltou administrador para um parâmetro que o Quall não usa.
pub const HR_ACESSO_NEGADO: u32 = 0x8007_0005;
/// `MF_E_INVALIDREQUEST`: um nó do mesmo nome, da execução anterior, ainda não saiu (`baia.rs`).
pub const HR_NO_DA_VEZ_ANTERIOR: u32 = 0xC00D_36B2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Falha {
    Privacidade,
    NoDaVezAnterior,
    Outra(u32),
}

pub fn classificar(hresult: u32) -> Falha {
    match hresult {
        HR_ACESSO_NEGADO => Falha::Privacidade,
        HR_NO_DA_VEZ_ANTERIOR => Falha::NoDaVezAnterior,
        h => Falha::Outra(h),
    }
}

// =============================================================================================
// O cartão dos Ajustes
// =============================================================================================

/// O que o fio publica e o cartão lê.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Situacao {
    /// `--sem-cameras-virtuais` não foi passada.
    pub permitida: bool,
    /// A fonte da câmera está registrada no Windows (`regras_da_instalacao_da_camera::Situacao::registrada`).
    pub instalada: bool,
    /// O interruptor.
    pub ligada: bool,
    /// Aparelhos conhecidos (o `baias.json`), com ou sem câmera.
    pub conhecidos: usize,
    /// Câmeras que o fio criou e segura agora.
    pub vivas: usize,
    /// O fio ainda tem pedido por fazer (criar leva até ~3,5 s no pior caso, `baia.rs`).
    pub trabalhando: bool,
    /// A última falha de criação desde que o interruptor foi ligado.
    pub falha: Option<Falha>,
}

impl Default for Situacao {
    fn default() -> Situacao {
        Situacao { permitida: true, instalada: true, ligada: true, conhecidos: 0, vivas: 0, trabalhando: false, falha: None }
    }
}

pub const TITULO: &str = "Câmera virtual"; // i18n: chave
pub const FRASE_PROIBIDA: &str = "Desligada nesta abertura (--sem-cameras-virtuais)."; // i18n: chave
pub const FRASE_NAO_INSTALADA: &str = "Precisa da câmera virtual instalada (no cartão de baixo)."; // i18n: chave
pub const FRASE_DESLIGADA: &str = "Ligue para os aparelhos aparecerem como câmera no Zoom e no OBS."; // i18n: chave
pub const FRASE_LIGANDO: &str = "Ligando…"; // i18n: chave
pub const FRASE_SEM_APARELHO: &str = "A câmera de um aparelho aparece depois da primeira conexão."; // i18n: chave
pub const FRASE_UMA: &str = "1 câmera na lista do Zoom, Meet e OBS."; // i18n: chave
pub const FRASE_VARIAS: &str = "{} câmeras na lista do Zoom, Meet e OBS."; // i18n: chave
pub const FRASE_PRIVACIDADE: &str = "O Windows recusou: veja Privacidade > Câmera."; // i18n: chave
pub const FRASE_OUTRA_FALHA: &str = "Uma câmera não subiu; o motivo está no diário."; // i18n: chave
/// O nome para o Narrador do interruptor (o mesmo título).
pub const NOME_ACESSIVEL: &str = "Câmera virtual: os aparelhos pareados como câmera nos outros apps"; // i18n: chave

/// Todas as chaves, para o teste da tabela de tradução.
pub const CHAVES: [&str; 26] = [
    CAMERAS_TITULO,
    CAMERAS_NENHUMA,
    CAMERAS_UMA,
    CAMERAS_VARIAS,
    CAMERAS_E_MAIS,
    CAMERAS_EM_USO,
    CAMERAS_GERENCIAR,
    CAMERAS_GERENCIAR_ACESSIVEL,
    CAIXA_CAMERAS_PERGUNTA,
    CAIXA_CAMERAS_CORPO,
    CAIXA_CAMERAS_REMOVER,
    CAIXA_CAMERAS_REMOVER_TODAS,
    CAIXA_CAMERAS_FECHAR,
    CAIXA_CAMERAS_LINHA,
    CAIXA_CAMERAS_LINHA_EM_USO,
    TITULO,
    FRASE_PROIBIDA,
    FRASE_NAO_INSTALADA,
    FRASE_DESLIGADA,
    FRASE_LIGANDO,
    FRASE_SEM_APARELHO,
    FRASE_UMA,
    FRASE_VARIAS,
    FRASE_PRIVACIDADE,
    FRASE_OUTRA_FALHA,
    NOME_ACESSIVEL,
];

/// A frase do cartão: a chave, o número que entra no `{}` (só em [`FRASE_VARIAS`]), e se é alerta.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Frase {
    pub chave: &'static str,
    pub numero: Option<usize>,
    pub alerta: bool,
}

/// A frase, na ordem do que importa à pessoa: proibida > não instalada > desligada > recusa de privacidade (que ela
/// conserta nos Ajustes do Windows) > trabalhando > outra falha > a contagem.
///
/// `NoDaVezAnterior` **não** é alerta: `baia.rs` já espera o nó antigo sair, e quando ele sai a
/// câmera sobe sozinha. Só vira frase de falha se, depois das esperas, nenhuma câmera ficou viva.
pub fn frase(s: &Situacao) -> Frase {
    let simples = |chave| Frase { chave, numero: None, alerta: false };
    if !s.permitida {
        return simples(FRASE_PROIBIDA);
    }
    if !s.instalada {
        return simples(FRASE_NAO_INSTALADA);
    }
    if !s.ligada {
        return simples(FRASE_DESLIGADA);
    }
    if s.falha == Some(Falha::Privacidade) {
        return Frase { chave: FRASE_PRIVACIDADE, numero: None, alerta: true };
    }
    if s.trabalhando {
        return simples(FRASE_LIGANDO);
    }
    if s.conhecidos == 0 {
        return simples(FRASE_SEM_APARELHO);
    }
    if s.falha.is_some() && s.vivas < s.conhecidos {
        return Frase { chave: FRASE_OUTRA_FALHA, numero: None, alerta: true };
    }
    match s.vivas {
        0 => simples(FRASE_LIGANDO),
        1 => simples(FRASE_UMA),
        n => Frase { chave: FRASE_VARIAS, numero: Some(n), alerta: false },
    }
}

/// O interruptor só se mexe quando a câmera é permitida nesta abertura e está instalada.
pub fn interruptor_habilitado(s: &Situacao) -> bool {
    s.permitida && s.instalada
}

#[cfg(test)]
mod testes {
    use super::*;

    fn nomes(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn sem_arquivo_a_camera_fica_ligada_como_antes() {
        assert!(ler_preferencia(None));
        assert!(ler_preferencia(Some("")));
        assert!(ler_preferencia(Some("qualquer coisa")));
        assert!(ler_preferencia(Some("ligada\n")));
        assert!(!ler_preferencia(Some("desligada\n")));
        assert!(!ler_preferencia(Some("\u{feff}Desligada\r\n")), "o BOM do PowerShell 5 não pode religar");
        for ligada in [true, false] {
            assert_eq!(ler_preferencia(Some(escrever_preferencia(ligada))), ligada);
        }
    }

    #[test]
    fn desligada_proibida_ou_sem_instalar_nao_quer_camera_nenhuma() {
        assert!(desejadas(true, true, false, ["S24"]).is_empty());
        assert!(desejadas(false, true, true, ["S24"]).is_empty());
        assert!(desejadas(true, false, true, ["S24"]).is_empty(), "sem a fonte registrada, nada");
        assert_eq!(desejadas(true, true, true, ["S24", "", "  ", "A07", "S24"]), nomes(&["A07", "S24"]));
    }

    #[test]
    fn o_plano_nao_recria_o_que_ja_esta_vivo() {
        let p = planejar(&nomes(&["A07", "S24"]), &nomes(&["S24"]));
        assert_eq!(p, Plano { soltar: vec![], criar: nomes(&["A07"]) });
        assert!(planejar(&nomes(&["S24"]), &nomes(&["S24"])).vazio());
    }

    #[test]
    fn desligar_solta_todas_e_renomear_solta_antes_de_criar() {
        assert_eq!(planejar(&[], &nomes(&["A07", "S24"])), Plano { soltar: nomes(&["A07", "S24"]), criar: vec![] });
        let p = planejar(&nomes(&["Galaxy S24"]), &nomes(&["S24"]));
        assert_eq!(p.soltar, nomes(&["S24"]));
        assert_eq!(p.criar, nomes(&["Galaxy S24"]));
    }

    #[test]
    fn as_falhas_que_a_frase_distingue() {
        assert_eq!(classificar(0x8007_0005), Falha::Privacidade);
        assert_eq!(classificar(0xC00D_36B2), Falha::NoDaVezAnterior);
        assert_eq!(classificar(0x8000_4005), Falha::Outra(0x8000_4005));
    }

    #[test]
    fn a_frase_do_cartao_em_cada_estado() {
        let base = Situacao { conhecidos: 2, vivas: 2, ..Situacao::default() };
        assert_eq!(frase(&base), Frase { chave: FRASE_VARIAS, numero: Some(2), alerta: false });
        assert_eq!(frase(&Situacao { vivas: 1, conhecidos: 1, ..base.clone() }).chave, FRASE_UMA);
        assert_eq!(frase(&Situacao { permitida: false, ..base.clone() }).chave, FRASE_PROIBIDA);
        assert_eq!(frase(&Situacao { ligada: false, ..base.clone() }).chave, FRASE_DESLIGADA);
        let sem = frase(&Situacao { instalada: false, ligada: false, ..base.clone() });
        assert_eq!((sem.chave, sem.alerta), (FRASE_NAO_INSTALADA, false), "sem instalar vence o desligado");
        assert_eq!(frase(&Situacao { instalada: false, permitida: false, ..base.clone() }).chave, FRASE_PROIBIDA);
        assert_eq!(frase(&Situacao { conhecidos: 0, vivas: 0, ..base.clone() }).chave, FRASE_SEM_APARELHO);
        assert_eq!(frase(&Situacao { trabalhando: true, vivas: 0, ..base.clone() }).chave, FRASE_LIGANDO);
        let negada = frase(&Situacao { falha: Some(Falha::Privacidade), vivas: 0, trabalhando: true, ..base.clone() });
        assert_eq!((negada.chave, negada.alerta), (FRASE_PRIVACIDADE, true), "a recusa vence o \"ligando\"");
        let outra = frase(&Situacao { falha: Some(Falha::Outra(1)), vivas: 1, ..base.clone() });
        assert_eq!((outra.chave, outra.alerta), (FRASE_OUTRA_FALHA, true));
        // Todas subiram depois de uma falha: a contagem vale mais que a falha velha.
        assert_eq!(frase(&Situacao { falha: Some(Falha::NoDaVezAnterior), ..base.clone() }).chave, FRASE_VARIAS);
    }

    /// **O S24 reinstalado** (13/10/2026): outro `device_id`, o mesmo nome. Uma baia só, e a sessão
    /// nova reaproveita a que a abertura subiu.
    #[test]
    fn o_aparelho_reinstalado_e_o_mesmo_modelo_nao_abrem_outra_baia() {
        use std::collections::BTreeMap;
        let conhecidos = [("android-velho", "SM-S928B"), ("android-novo", "SM-S928B"), ("ios", "Iphone 7"), ("x", "")];
        assert_eq!(baias_da_abertura(conhecidos), nomes(&["Iphone 7", "SM-S928B"]));
        let aparelhos: BTreeMap<String, String> =
            conhecidos.iter().filter(|(_, n)| !n.is_empty()).map(|(i, n)| (i.to_string(), n.to_string())).collect();
        let abertas = nomes(&["Iphone 7", "SM-S928B"]);
        // O id novo, o velho, ou um id que ninguém viu (outro aparelho do mesmo modelo): reaproveita.
        for id in ["android-novo", "android-velho", "outro-s24"] {
            assert_eq!(ao_conectar(&aparelhos, &abertas, id, "SM-S928B"), AoConectar { abrir: false, soltar: None }, "{id}");
        }
        // Um aparelho novo de verdade: abre.
        assert_eq!(ao_conectar(&aparelhos, &abertas, "pixel", "Pixel 8"), AoConectar { abrir: true, soltar: None });
    }

    #[test]
    fn renomear_solta_o_nome_antigo_so_quando_ninguem_mais_o_usa() {
        use std::collections::BTreeMap;
        let mut aparelhos: BTreeMap<String, String> = BTreeMap::new();
        aparelhos.insert("a".into(), "S24".into());
        let abertas = nomes(&["S24"]);
        assert_eq!(ao_conectar(&aparelhos, &abertas, "a", "Galaxy S24"), AoConectar { abrir: true, soltar: Some("S24".into()) });
        aparelhos.insert("b".into(), "S24".into());
        assert_eq!(ao_conectar(&aparelhos, &abertas, "a", "Galaxy S24"), AoConectar { abrir: true, soltar: None }, "o b ainda usa S24");
    }

    #[test]
    fn a_espera_do_cano_cresce_ate_5_s_e_o_diario_nao_enche() {
        let ms: Vec<u128> = (1..=8).map(|n| espera_do_cano(n).as_millis()).collect();
        assert_eq!(ms, [300, 600, 1200, 2400, 4800, 5000, 5000, 5000]);
        assert_eq!(espera_do_cano(0).as_millis(), 300);
        let ditas = (1..=100).filter(|n| dizer_falha_do_cano(*n)).count();
        assert_eq!(ditas, 11);
    }

    fn e(id: &str, nome: &str, visto: Option<u64>) -> Entrada {
        Entrada { device_id: id.into(), nome: nome.into(), visto_em: visto }
    }

    /// **O Dell de 13/10**: três "SM-S928B" (o S24 reinstalado duas vezes), um iPhone, um MacBook e
    /// um A07, tudo no formato antigo, sem data.
    #[test]
    fn a_abertura_junta_o_nome_repetido_e_nao_perde_camera_do_formato_antigo() {
        let agora = 2_000_000_000;
        let antes = vec![
            e("s24-1", "SM-S928B", None),
            e("s24-2", "SM-S928B", None),
            e("s24-3", "SM-S928B", None),
            e("ios", "Iphone 7", None),
            e("mac", "MacBook Air", None),
            e("a07", "SM-A075M", None),
            e("vazio", " ", None),
        ];
        let pareados = ["s24-3", "ios", "mac"];
        let depois = limpar_na_abertura(antes, |id| pareados.contains(&id), agora);
        let nomes: Vec<(&str, &str)> = depois.iter().map(|x| (x.device_id.as_str(), x.nome.as_str())).collect();
        assert_eq!(nomes, [("ios", "Iphone 7"), ("mac", "MacBook Air"), ("a07", "SM-A075M"), ("s24-3", "SM-S928B")]);
        assert!(depois.iter().all(|x| x.visto_em == Some(agora)), "sem data, ganha a de agora");
    }

    #[test]
    fn fora_dos_pares_e_sem_transmitir_ha_30_dias_sai() {
        let agora = 2_000_000_000;
        let dia = 86_400;
        let antes = vec![
            e("velho", "Pixel 6", Some(agora - 31 * dia)),
            e("recente", "Pixel 7", Some(agora - 29 * dia)),
            e("pareado-velho", "iPad", Some(agora - 400 * dia)),
        ];
        let depois = limpar_na_abertura(antes, |id| id == "pareado-velho", agora);
        let nomes: Vec<&str> = depois.iter().map(|x| x.nome.as_str()).collect();
        assert_eq!(nomes, ["Pixel 7", "iPad"]);
    }

    #[test]
    fn das_repetidas_fica_a_vista_por_ultimo_quando_nenhuma_esta_pareada() {
        let agora = 2_000_000_000;
        let depois = limpar_na_abertura(vec![e("a", "S24", Some(agora - 10)), e("b", "S24", Some(agora - 5))], |_| false, agora);
        assert_eq!(depois, vec![e("b", "S24", Some(agora - 5))]);
    }

    #[test]
    fn esquecer_e_remover() {
        let todas = vec![e("a", "S24", None), e("b", "S24", None), e("c", "Iphone 7", None)];
        assert_eq!(nomes_que_saem(&todas, &["a".into()]), Vec::<String>::new(), "o b ainda usa S24");
        assert_eq!(nomes_que_saem(&todas, &["a".into(), "b".into()]), nomes(&["S24"]));
        assert_eq!(nomes_que_saem(&todas, &["a".into(), "b".into(), "c".into()]), nomes(&["Iphone 7", "S24"]));
        assert_eq!(sem_o_nome(todas, "S24"), vec![e("c", "Iphone 7", None)]);
    }

    #[test]
    fn a_frase_das_cameras_mostra_as_em_uso_primeiro() {
        assert_eq!(frase_das_cameras(&[]), FraseDasCameras::Nenhuma);
        let l = |n: &str, u: bool| LinhaDaCamera { nome: n.into(), em_uso: u };
        let f = frase_das_cameras(&[l("A07", false), l("S24", true), l("Iphone 7", false), l("Mac", false)]);
        assert_eq!(
            f,
            FraseDasCameras::Lista { quantas: 4, nomes: vec![("S24".into(), true), ("A07".into(), false)], mais: 2 }
        );
        assert_eq!(frase_das_cameras(&[l("S24", false)]), FraseDasCameras::Lista { quantas: 1, nomes: vec![("S24".into(), false)], mais: 0 });
    }

    #[test]
    fn o_interruptor_so_se_mexe_quando_permitido() {
        assert!(interruptor_habilitado(&Situacao::default()));
        assert!(!interruptor_habilitado(&Situacao { permitida: false, ..Situacao::default() }));
        assert!(!interruptor_habilitado(&Situacao { instalada: false, ..Situacao::default() }));
    }
}
