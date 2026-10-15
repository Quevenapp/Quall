//! **As regras da instância única** (13/10/2026): o que fazer quando o Quall é aberto com outra
//! cópia de produto já de pé. Aritmética pura, sem Win32 e sem `crate::`, para os testes rodarem com
//! `rustc --test` direto no arquivo, no Mac também. O Win32 (o mutex, a janela, a caixa, encerrar o
//! processo) é `instancia.rs`.
//!
//! # O defeito que trouxe isto (Dell, 13/10)
//!
//! O Bruno atualizou o MSI 1.0.13 → 1.0.14 com o Quall aberto. O `util:CloseApplication` do MSI
//! mandou `WM_CLOSE`, a janela da 1.0.13 se destruiu (e com ela a marca que a nova procura), o
//! desmonte do `main` não terminou, e o processo ficou de pé segurando o mutex. Cada Quall novo
//! esperava 15 s calado e mostrava "o Quall ainda está fechando a sessão anterior": nunca abria.
//!
//! # O que muda
//!
//! - A espera calada cai para [`ESPERA_CALADA`] (~5 s). Depois dela, uma **pergunta** — "Outra cópia
//!   do Quall está aberta" — com **Mostrar a outra** (só com a janela dela de pé), **Fechar a outra e
//!   abrir esta** e **Cancelar**. Quem cancela sai; nenhuma cópia fica pendurada.
//! - A caixa continua olhando enquanto está aberta: se a outra sair, esta abre sozinha; se a janela
//!   da outra (a mesma versão) aparecer, esta a chama e sai.
//! - **Fechar a outra** pede (`WM_CLOSE`) e espera [`ESPERA_PELO_FECHO`]; se ela não sair, o processo
//!   é encerrado — só um `quall-app.exe` da mesma sessão e do mesmo usuário ([`pode_encerrar`]), e
//!   nunca outra cópia nova que esteja esperando como esta.
//! - **A outra de versão diferente** (outra versão, ou aberta de outra pasta) é dita na caixa, mesmo
//!   com a janela de pé: chamá-la calado deixaria a pessoa na versão velha achando que atualizou.

use std::fmt;
use std::time::Duration;

/// Quanto quem chega espera, calado, uma outra sem janela (abrindo ou fechando) antes de perguntar.
pub const ESPERA_CALADA: Duration = Duration::from_secs(5);

/// Depois de "Fechar a outra e abrir esta": quanto se espera a outra sair pelo pedido antes de
/// encerrar o processo dela.
pub const ESPERA_PELO_FECHO: Duration = Duration::from_secs(5);

/// O nome do executável de produto: só ele pode ser encerrado por "Fechar a outra".
pub const EXECUTAVEL: &str = "quall-app.exe"; // i18n: fora (nome de arquivo)

// --- os textos (em português, como chave da tabela; `instancia.rs` os passa por `t`/`tf`) ---

pub const TITULO: &str = "Outra cópia do Quall está aberta"; // i18n: chave
pub const BOTAO_MOSTRAR: &str = "Mostrar a outra"; // i18n: chave
pub const BOTAO_FECHAR_E_ABRIR: &str = "Fechar a outra e abrir esta"; // i18n: chave
pub const BOTAO_CANCELAR: &str = "Cancelar"; // i18n: chave
pub const CORPO_SEM_RESPOSTA: &str = "Ela não mostrou a janela nem fechou em {} segundos: pode estar fechando ou travada."; // i18n: chave
pub const CORPO_COM_JANELA: &str = "Ela está aberta, e é diferente desta."; // i18n: chave
pub const CORPO_VERSOES: &str = "A outra é a versão {}, e esta é a {}."; // i18n: chave
pub const CORPO_VERSAO_ANTERIOR: &str = "A outra é de uma versão anterior do Quall; esta é a {}."; // i18n: chave
pub const CORPO_OUTRA_PASTA: &str = "A outra foi aberta de outro lugar: {}"; // i18n: chave
pub const CORPO_O_QUE_FAZER: &str = "Duas cópias juntas disputam as câmeras virtuais. Feche a outra para abrir esta."; // i18n: chave
pub const FALHA_ELEVADA: &str = "A outra cópia do Quall foi aberta como administrador, e esta não pode fechá-la. Feche-a pelo ícone da bandeja ou pelo Gerenciador de Tarefas e abra o Quall de novo."; // i18n: chave
pub const FALHA_VARIAS: &str = "Há mais de uma cópia do Quall aberta. Feche-as pelo Gerenciador de Tarefas e abra o Quall de novo."; // i18n: chave
pub const FALHA_GERAL: &str = "Não consegui fechar a outra cópia do Quall. Feche-a pelo ícone da bandeja ou pelo Gerenciador de Tarefas e abra o Quall de novo."; // i18n: chave

/// A versão do produto (a do MSI: `construir-msi.ps1` a passa ao `cargo` em `QUALL_VERSAO`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Versao {
    pub maior: u16,
    pub menor: u16,
    pub correcao: u16,
}

/// O bit que marca uma versão empacotada: sem ele, a 0.0.0 seria 0, que é "sem propriedade".
const MARCA: u64 = 1 << 48;

impl Versao {
    /// "1.0.14" (uma quarta parte, como a do MSIX, é ignorada). `None` para o que não for isso.
    pub fn ler(s: &str) -> Option<Versao> {
        let mut partes = s.trim().split('.');
        let mut parte = || partes.next().and_then(|p| p.parse::<u16>().ok());
        let (maior, menor, correcao) = (parte()?, parte()?, parte()?);
        Some(Versao { maior, menor, correcao })
    }

    /// Num número só, para a propriedade da janela (`SetPropW` guarda um ponteiro).
    pub fn empacotar(self) -> u64 {
        MARCA | (self.maior as u64) << 32 | (self.menor as u64) << 16 | self.correcao as u64
    }

    pub fn desempacotar(v: u64) -> Option<Versao> {
        if v & !((MARCA << 1) - 1) != 0 || v & MARCA == 0 {
            return None;
        }
        Some(Versao { maior: (v >> 32) as u16, menor: (v >> 16) as u16, correcao: v as u16 })
    }
}

impl fmt::Display for Versao {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.maior, self.menor, self.correcao)
    }
}

/// O que se sabe de uma cópia (esta ou a outra).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Copia {
    /// O caminho do executável (`QueryFullProcessImageNameW`), se se deixou ler.
    pub caminho: Option<String>,
    /// A versão: a desta vem da compilação; a da outra, da propriedade da janela dela.
    pub versao: Option<Versao>,
    /// A outra tem a janela de pé (sem janela, a versão dela não tem de onde vir).
    pub com_janela: bool,
}

/// Como a outra se compara com esta.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parentesco {
    /// A mesma versão do mesmo lugar (ou nada que diga o contrário).
    Mesma,
    /// Outra versão ou outro lugar; os campos dizem o que se sabe.
    Diferente { versao_dela: Option<Versao>, caminho_dela: Option<String> },
}

/// Normaliza um caminho do Windows para comparar: sem o `\\?\`, barras invertidas, minúsculas.
fn normalizar(c: &str) -> String {
    let c = c.strip_prefix(r"\\?\").unwrap_or(c); // i18n: fora (prefixo de caminho)
    c.replace('/', "\\").to_lowercase()
}

/// **A outra é diferente desta?** Caminhos conhecidos e diferentes, ou versões conhecidas e
/// diferentes, dizem que sim. A outra com janela e sem versão, com esta versionada, é anterior a
/// 13/10 (a janela publica a versão desde então). Sem nada que diga, é a mesma.
pub fn parentesco(esta: &Copia, outra: &Copia) -> Parentesco {
    let caminho_difere = matches!((&esta.caminho, &outra.caminho), (Some(a), Some(b)) if normalizar(a) != normalizar(b));
    let versao_difere = match (esta.versao, outra.versao) {
        (Some(a), Some(b)) => a != b,
        (Some(_), None) => outra.com_janela,
        _ => false,
    };
    if caminho_difere || versao_difere {
        Parentesco::Diferente {
            versao_dela: outra.versao,
            caminho_dela: if caminho_difere { outra.caminho.clone() } else { None },
        }
    } else {
        Parentesco::Mesma
    }
}

/// Por que a caixa aparece.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Motivo {
    /// A outra está de janela aberta, mas é de outra versão ou de outro lugar.
    OutraVersao,
    /// A outra não mostrou a janela nem saiu em [`ESPERA_CALADA`].
    SemResposta,
}

/// O passo de quem chega, a cada volta do laço (o mutex ainda não foi tomado).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Passo {
    /// Chamar a janela da outra e sair (o que sempre se fez com a mesma versão).
    Chamar,
    /// Esperar mais um pouco, calado.
    Esperar,
    /// Perguntar à pessoa.
    Perguntar(Motivo),
}

pub fn decidir(com_janela: bool, parentesco: &Parentesco, decorrido: Duration) -> Passo {
    match (com_janela, parentesco) {
        (true, Parentesco::Mesma) => Passo::Chamar,
        (true, Parentesco::Diferente { .. }) => Passo::Perguntar(Motivo::OutraVersao),
        (false, _) if decorrido < ESPERA_CALADA => Passo::Esperar,
        (false, _) => Passo::Perguntar(Motivo::SemResposta),
    }
}

/// Enquanto a caixa está aberta (a cada tique do relógio dela).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NaPergunta {
    /// Nada mudou.
    Seguir,
    /// A outra saiu e o mutex é desta: fechar a caixa e abrir.
    AbrirAgora,
    /// A janela da outra (a mesma versão) apareceu: fechar a caixa, chamá-la e sair.
    ChamarAgora,
}

pub fn durante_a_pergunta(tomou_o_mutex: bool, com_janela: bool, parentesco: &Parentesco) -> NaPergunta {
    if tomou_o_mutex {
        NaPergunta::AbrirAgora
    } else if com_janela && *parentesco == Parentesco::Mesma {
        NaPergunta::ChamarAgora
    } else {
        NaPergunta::Seguir
    }
}

/// Uma frase com as partes variáveis: o molde é a chave da tabela (`idioma::tf`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frase {
    pub molde: &'static str,
    pub partes: Vec<String>,
}

fn frase(molde: &'static str, partes: &[String]) -> Frase {
    Frase { molde, partes: partes.to_vec() }
}

/// **O corpo da caixa**, frase a frase (cada uma vira um parágrafo).
pub fn corpo(motivo: Motivo, parentesco: &Parentesco, esta: Option<Versao>) -> Vec<Frase> {
    let mut v = Vec::new();
    match motivo {
        Motivo::SemResposta => v.push(frase(CORPO_SEM_RESPOSTA, &[ESPERA_CALADA.as_secs().to_string()])),
        Motivo::OutraVersao => v.push(frase(CORPO_COM_JANELA, &[])),
    }
    if let Parentesco::Diferente { versao_dela, caminho_dela } = parentesco {
        match (versao_dela, esta) {
            (Some(a), Some(b)) if a != &b => v.push(frase(CORPO_VERSOES, &[a.to_string(), b.to_string()])),
            (None, Some(b)) if caminho_dela.is_none() => v.push(frase(CORPO_VERSAO_ANTERIOR, &[b.to_string()])),
            _ => {}
        }
        if let Some(c) = caminho_dela {
            v.push(frase(CORPO_OUTRA_PASTA, std::slice::from_ref(c)));
        }
    }
    v.push(frase(CORPO_O_QUE_FAZER, &[]));
    v
}

/// Um `quall-app.exe` candidato a ser encerrado por "Fechar a outra".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Processo {
    pub pid: u32,
    /// O nome da imagem (`szExeFile`), ou o fim do caminho.
    pub nome: String,
    pub sessao: Option<u32>,
    /// O SID do dono, em texto; `None` quando o token não se deixou ler (uma cópia elevada).
    pub usuario: Option<String>,
    /// É outra cópia nova esperando, como esta (o evento `esperando-<pid>` dela existe). No Dell,
    /// duas cópias novas ficaram paradas juntas: sem isto, cada uma contaria a outra como candidata,
    /// e "Fechar a outra" acharia duas e não encerraria nenhuma.
    pub esperando: bool,
}

/// Este processo, para comparar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Eu {
    pub pid: u32,
    pub sessao: Option<u32>,
    pub usuario: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Recusa {
    /// É este processo.
    EuMesmo,
    /// Não é o `quall-app.exe`.
    OutroPrograma,
    /// Outra sessão, outro usuário, ou não se soube (o token de uma cópia elevada não se lê).
    OutroDono,
    /// Outra cópia nova esperando, como esta: não é a que segura o Quall.
    Esperando,
}

/// **Só um `quall-app.exe` da mesma sessão e do mesmo usuário** pode ser encerrado. O caminho não
/// entra: a cópia que ficou de pé numa atualização roda de um executável que o MSI já trocou (ou
/// renomeou), e é justamente ela que se quer fechar.
pub fn pode_encerrar(p: &Processo, eu: &Eu) -> Result<(), Recusa> {
    if p.pid == eu.pid {
        return Err(Recusa::EuMesmo);
    }
    let nome = p.nome.rsplit(['\\', '/']).next().unwrap_or(&p.nome);
    if !nome.eq_ignore_ascii_case(EXECUTAVEL) {
        return Err(Recusa::OutroPrograma);
    }
    if p.esperando {
        return Err(Recusa::Esperando);
    }
    let mesma_sessao = matches!((p.sessao, eu.sessao), (Some(a), Some(b)) if a == b);
    let mesmo_usuario = matches!((&p.usuario, &eu.usuario), (Some(a), Some(b)) if a.eq_ignore_ascii_case(b));
    if mesma_sessao && mesmo_usuario {
        Ok(())
    } else {
        Err(Recusa::OutroDono)
    }
}

/// Qual processo encerrar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alvo {
    Um(u32),
    /// Nenhum que se possa encerrar (a outra elevada, de outro usuário…).
    Nenhum,
    /// Mais de um candidato e nenhuma janela que diga qual: não se adivinha.
    Varios(usize),
}

/// **O alvo de "Fechar a outra"**: o dono da janela, se ela existe (e se pode); sem janela, o único
/// `quall-app.exe` da sessão e do usuário além deste. Com vários, nenhum: uma corrida de bancada ao
/// lado também é `quall-app.exe`, e matar a errada seria pior que pedir à pessoa.
pub fn escolher_alvo(pid_da_janela: Option<u32>, processos: &[Processo], eu: &Eu) -> Alvo {
    if let Some(pid) = pid_da_janela {
        return match processos.iter().find(|p| p.pid == pid) {
            Some(p) if pode_encerrar(p, eu).is_ok() => Alvo::Um(pid),
            _ => Alvo::Nenhum,
        };
    }
    let aptos: Vec<u32> = processos.iter().filter(|p| pode_encerrar(p, eu).is_ok()).map(|p| p.pid).collect();
    match aptos.len() {
        0 => Alvo::Nenhum,
        1 => Alvo::Um(aptos[0]),
        n => Alvo::Varios(n),
    }
}

/// A frase de quando "Fechar a outra" não deu certo.
pub fn falha(alvo: Alvo, algum_recusado_por_dono: bool) -> &'static str {
    match alvo {
        Alvo::Varios(_) => FALHA_VARIAS,
        Alvo::Nenhum if algum_recusado_por_dono => FALHA_ELEVADA,
        _ => FALHA_GERAL,
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    fn v(s: &str) -> Versao {
        Versao::ler(s).unwrap()
    }

    #[test]
    fn a_versao_le_empacota_e_volta() {
        assert_eq!(v("1.0.14"), Versao { maior: 1, menor: 0, correcao: 14 });
        assert_eq!(v("1.0.14.0"), v("1.0.14"));
        assert_eq!(Versao::ler("1.0"), None);
        assert_eq!(Versao::ler("abc"), None);
        assert_eq!(Versao::ler(""), None);
        for s in ["0.0.0", "1.0.14", "65535.65535.65535"] {
            assert_eq!(Versao::desempacotar(v(s).empacotar()), Some(v(s)));
        }
        // 0 é "sem propriedade", e 1 é a marca antiga da janela (`HANDLE(1)`): nenhum é versão.
        assert_eq!(Versao::desempacotar(0), None);
        assert_eq!(Versao::desempacotar(1), None);
        assert_eq!(Versao::desempacotar(u64::MAX), None);
        assert_eq!(v("1.0.14").to_string(), "1.0.14");
    }

    fn copia(caminho: Option<&str>, versao: Option<&str>, com_janela: bool) -> Copia {
        Copia { caminho: caminho.map(String::from), versao: versao.map(v), com_janela }
    }

    const PF: &str = r"C:\Program Files\Quall\quall-app.exe"; // i18n: fora

    #[test]
    fn o_parentesco_pelo_caminho_e_pela_versao() {
        let esta = copia(Some(PF), Some("1.0.15"), false);
        // Mesma versão, mesmo lugar (com o `\\?\` e outra caixa): a mesma.
        let igual = copia(Some(r"\\?\c:\program files\quall\QUALL-APP.EXE"), Some("1.0.15"), true);
        assert_eq!(parentesco(&esta, &igual), Parentesco::Mesma);
        // Outra versão com janela.
        let velha = copia(Some(PF), Some("1.0.14"), true);
        assert_eq!(parentesco(&esta, &velha), Parentesco::Diferente { versao_dela: Some(v("1.0.14")), caminho_dela: None });
        // A 1.0.13 do Dell: com janela e sem versão publicada é anterior a esta regra.
        let antiga = copia(Some(PF), None, true);
        assert_eq!(parentesco(&esta, &antiga), Parentesco::Diferente { versao_dela: None, caminho_dela: None });
        // Sem janela, a versão não tem de onde vir: não se conclui nada só por ela.
        let sem_janela = copia(Some(PF), None, false);
        assert_eq!(parentesco(&esta, &sem_janela), Parentesco::Mesma);
        // Outro lugar (o executável que o MSI renomeou, ou uma cópia de desenvolvimento).
        let outro = copia(Some(r"C:\Config.Msi\3f1a2.rbf"), None, false);
        assert_eq!(
            parentesco(&esta, &outro),
            Parentesco::Diferente { versao_dela: None, caminho_dela: Some(r"C:\Config.Msi\3f1a2.rbf".into()) }
        );
        // Esta sem versão (compilação de bancada) e a outra sem: o caminho decide.
        let dev = copia(Some(PF), None, false);
        assert_eq!(parentesco(&dev, &copia(Some(PF), None, true)), Parentesco::Mesma);
        // Caminho que não se leu não diz nada.
        assert_eq!(parentesco(&esta, &copia(None, Some("1.0.15"), true)), Parentesco::Mesma);
    }

    #[test]
    fn decidir_espera_5_s_e_depois_pergunta() {
        let mesma = Parentesco::Mesma;
        let dif = Parentesco::Diferente { versao_dela: Some(v("1.0.13")), caminho_dela: None };
        assert_eq!(decidir(true, &mesma, Duration::ZERO), Passo::Chamar);
        assert_eq!(decidir(true, &dif, Duration::ZERO), Passo::Perguntar(Motivo::OutraVersao));
        assert_eq!(decidir(false, &mesma, Duration::from_millis(4900)), Passo::Esperar);
        assert_eq!(decidir(false, &mesma, ESPERA_CALADA), Passo::Perguntar(Motivo::SemResposta));
        assert_eq!(decidir(false, &dif, Duration::from_secs(60)), Passo::Perguntar(Motivo::SemResposta));
        assert!(ESPERA_CALADA <= Duration::from_secs(5));
    }

    #[test]
    fn a_caixa_aberta_segue_a_outra() {
        let mesma = Parentesco::Mesma;
        let dif = Parentesco::Diferente { versao_dela: None, caminho_dela: None };
        assert_eq!(durante_a_pergunta(true, true, &dif), NaPergunta::AbrirAgora);
        assert_eq!(durante_a_pergunta(false, true, &mesma), NaPergunta::ChamarAgora);
        // A janela de uma versão diferente não fecha a pergunta: é ela que a pergunta mostra.
        assert_eq!(durante_a_pergunta(false, true, &dif), NaPergunta::Seguir);
        assert_eq!(durante_a_pergunta(false, false, &mesma), NaPergunta::Seguir);
    }

    #[test]
    fn o_corpo_diz_a_versao_e_o_lugar() {
        let moldes = |f: &[Frase]| f.iter().map(|x| x.molde).collect::<Vec<_>>();
        let c = corpo(Motivo::SemResposta, &Parentesco::Mesma, Some(v("1.0.15")));
        assert_eq!(moldes(&c), [CORPO_SEM_RESPOSTA, CORPO_O_QUE_FAZER]);
        assert_eq!(c[0].partes, ["5"]);

        let dif = Parentesco::Diferente { versao_dela: Some(v("1.0.13")), caminho_dela: None };
        let c = corpo(Motivo::OutraVersao, &dif, Some(v("1.0.14")));
        assert_eq!(moldes(&c), [CORPO_COM_JANELA, CORPO_VERSOES, CORPO_O_QUE_FAZER]);
        assert_eq!(c[1].partes, ["1.0.13", "1.0.14"]);

        let anterior = Parentesco::Diferente { versao_dela: None, caminho_dela: None };
        let c = corpo(Motivo::OutraVersao, &anterior, Some(v("1.0.15")));
        assert_eq!(moldes(&c), [CORPO_COM_JANELA, CORPO_VERSAO_ANTERIOR, CORPO_O_QUE_FAZER]);

        let pasta = Parentesco::Diferente { versao_dela: None, caminho_dela: Some(r"D:\x\quall-app.exe".into()) };
        let c = corpo(Motivo::SemResposta, &pasta, Some(v("1.0.15")));
        assert_eq!(moldes(&c), [CORPO_SEM_RESPOSTA, CORPO_OUTRA_PASTA, CORPO_O_QUE_FAZER]);
        assert_eq!(c[1].partes, [r"D:\x\quall-app.exe"]);
    }

    fn eu() -> Eu {
        Eu { pid: 10, sessao: Some(1), usuario: Some("S-1-5-21-1".into()) }
    }

    fn proc(pid: u32, nome: &str, sessao: u32, usuario: Option<&str>) -> Processo {
        Processo { pid, nome: nome.into(), sessao: Some(sessao), usuario: usuario.map(String::from), esperando: false }
    }

    #[test]
    fn so_o_quall_da_mesma_sessao_e_usuario_se_encerra() {
        let e = eu();
        assert_eq!(pode_encerrar(&proc(20, "quall-app.exe", 1, Some("S-1-5-21-1")), &e), Ok(()));
        assert_eq!(pode_encerrar(&proc(20, "QUALL-APP.EXE", 1, Some("s-1-5-21-1")), &e), Ok(()));
        assert_eq!(pode_encerrar(&proc(20, r"C:\Program Files\Quall\quall-app.exe", 1, Some("S-1-5-21-1")), &e), Ok(()));
        assert_eq!(pode_encerrar(&proc(10, "quall-app.exe", 1, Some("S-1-5-21-1")), &e), Err(Recusa::EuMesmo));
        assert_eq!(pode_encerrar(&proc(20, "quall-camera.exe", 1, Some("S-1-5-21-1")), &e), Err(Recusa::OutroPrograma));
        assert_eq!(pode_encerrar(&proc(20, "quall-app.exe", 2, Some("S-1-5-21-1")), &e), Err(Recusa::OutroDono));
        assert_eq!(pode_encerrar(&proc(20, "quall-app.exe", 1, Some("S-1-5-21-2")), &e), Err(Recusa::OutroDono));
        assert_eq!(pode_encerrar(&proc(20, "quall-app.exe", 1, None), &e), Err(Recusa::OutroDono));
    }

    #[test]
    fn o_alvo_e_o_dono_da_janela_ou_o_unico() {
        let e = eu();
        let a = proc(20, "quall-app.exe", 1, Some("S-1-5-21-1"));
        let b = proc(30, "quall-app.exe", 1, Some("S-1-5-21-1"));
        let elevada = proc(40, "quall-app.exe", 1, None);
        let eu_mesmo = proc(10, "quall-app.exe", 1, Some("S-1-5-21-1"));
        assert_eq!(escolher_alvo(None, &[eu_mesmo.clone(), a.clone()], &e), Alvo::Um(20));
        assert_eq!(escolher_alvo(None, &[eu_mesmo.clone(), a.clone(), b.clone()], &e), Alvo::Varios(2));
        assert_eq!(escolher_alvo(Some(30), &[a.clone(), b.clone()], &e), Alvo::Um(30));
        assert_eq!(escolher_alvo(Some(40), &[a.clone(), elevada.clone()], &e), Alvo::Nenhum);
        assert_eq!(escolher_alvo(None, &[eu_mesmo, elevada], &e), Alvo::Nenhum);
        assert_eq!(escolher_alvo(None, &[], &e), Alvo::Nenhum);
        // O caso do Dell: a velha sem janela e outra cópia nova esperando ao lado. A nova não conta.
        let nova = Processo { esperando: true, ..b.clone() };
        assert_eq!(pode_encerrar(&nova, &e), Err(Recusa::Esperando));
        assert_eq!(escolher_alvo(None, &[a.clone(), nova], &e), Alvo::Um(20));
        assert_eq!(falha(Alvo::Varios(2), false), FALHA_VARIAS);
        assert_eq!(falha(Alvo::Nenhum, true), FALHA_ELEVADA);
        assert_eq!(falha(Alvo::Um(20), false), FALHA_GERAL);
    }
}
