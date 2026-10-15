//! O registro de baias: **uma câmera virtual por aparelho pareado**.
//!
//! Guarda, em `%APPDATA%\Quall\baias.json`, o par `device_id → nome do aparelho`. É preciso porque
//! o pareamento **não guarda o nome**: `PairedPeers` é `device_id → segredo`, e o nome só existe no
//! instante da conexão (`pronto.peer.display_name`). Sem este arquivo, um aparelho já pareado não
//! teria como ganhar câmera antes de conectar de novo — e o pedido é justamente que a câmera dele
//! esteja lá **antes**, para quem abre o Zoom antes de mexer no celular.
//!
//! # Por que a baia é do pareamento e não da sessão
//!
//! Porque é isso que o consumidor vê. O Zoom lista as câmeras quando **ele** abre, não quando o
//! celular conecta; uma câmera que só existisse durante a sessão simplesmente não estaria na lista
//! na hora em que a pessoa procura. E o cano precisa existir antes por outra razão medida: sem
//! servidor, a fonte entrega o **padrão de bancada**, que quer dizer "o Quall nem está rodando" —
//! informação errada e mais alarmante que a placa de espera.
//!
//! # O que este registro não faz
//!
//! Não renomeia câmera. O nó é chaveado por CLSID **+ nome** (medido em 27/08/2026), então criar
//! com um nome novo **duplica** em vez de renomear. Quando um aparelho muda de nome, a baia nova
//! (com o cano do nome novo) substitui a antiga **na conexão**, antes de a sessão publicar; desde
//! 12/10/2026 o fio das câmeras também solta o nó do nome antigo, que sem o cano dele só mostraria
//! o padrão de bancada. Antes ele ficava na lista até a próxima abertura do app.
//!
//! Nem cria nó: quem cria é `fio_das_cameras.rs`, que recebe daqui só a lista de nomes.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::baia::Baia;
use crate::fio_das_cameras::FioDasCameras;
use crate::registro;
use crate::regras_da_camera_virtual as regras;

fn arquivo() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(PathBuf::from(base).join("Quall").join("baias.json"))
}

/// **O valor de cada aparelho no `baias.json`.** Até 13/10/2026 era só o nome; desde então é o nome
/// e quando o aparelho transmitiu por último (`visto_em`, segundos desde 1970), que a limpeza da
/// abertura usa (`regras::limpar_na_abertura`). Os dois formatos são lidos; grava-se o novo.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
enum Valor {
    Antigo(String),
    Novo {
        nome: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        visto_em: Option<u64>,
    },
}

fn agora() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn ler() -> Vec<regras::Entrada> {
    ler_com_estado().0
}

/// As entradas, e se o arquivo **que existe** pôde ser lido. `(vazio, true)` quando não há arquivo.
fn ler_com_estado() -> (Vec<regras::Entrada>, bool) {
    let Some(p) = arquivo() else { return (Vec::new(), true) };
    let Ok(texto) = std::fs::read_to_string(&p) else { return (Vec::new(), !p.exists()) };
    // **O BOM, e o que ele custava.** Ferramenta de Windows escreve `EF BB BF` na frente de UTF-8
    // (o `Set-Content -Encoding UTF8` do PowerShell 5, o Bloco de Notas antigo), e `serde_json`
    // recusa o arquivo inteiro por causa dele. A recusa virava "nenhum aparelho conhecido" — e a
    // gravação seguinte, que relê e mescla, gravava por cima **só** o aparelho novo. Aconteceu em
    // 10/09/2026, por um roteiro de bancada meu; o arquivo foi salvo antes de o app gravar.
    let texto = texto.strip_prefix('\u{feff}').unwrap_or(&texto);
    match serde_json::from_str::<std::collections::BTreeMap<String, Valor>>(texto) {
        Ok(mapa) => {
            let v = mapa
                .into_iter()
                .map(|(device_id, valor)| match valor {
                    Valor::Antigo(nome) => regras::Entrada { device_id, nome, visto_em: None },
                    Valor::Novo { nome, visto_em } => regras::Entrada { device_id, nome, visto_em },
                })
                .collect();
            (v, true)
        }
        Err(erro) => {
            registro::linha(format!("baias: {} ilegível ({erro})", p.display()));
            (Vec::new(), false)
        }
    }
}

fn escrever(entradas: &[regras::Entrada]) {
    let Some(p) = arquivo() else { return };
    let mapa: std::collections::BTreeMap<&str, Valor> = entradas
        .iter()
        .map(|e| (e.device_id.as_str(), Valor::Novo { nome: e.nome.clone(), visto_em: e.visto_em }))
        .collect();
    if let Some(pasta) = p.parent() {
        let _ = std::fs::create_dir_all(pasta);
    }
    if let Ok(texto) = serde_json::to_string_pretty(&mapa) {
        let _ = std::fs::write(&p, texto);
    }
}

/// Grava relendo e mesclando, **nunca sobrescrevendo com o que está na memória**.
///
/// É a mesma regra de `identidade::guardar_pares` (dívida 23) e pelo mesmo motivo: duas instâncias
/// do app abertas ao mesmo tempo — que é caso real nesta bancada — apagariam uma o aparelho da
/// outra.
///
/// E **não grava por cima de um arquivo que não conseguiu ler**: mesclar com "vazio" seria apagar
/// os aparelhos que estão lá dentro. Melhor a câmera nova não persistir do que as antigas sumirem.
fn gravar(novo: regras::Entrada) {
    mudar_o_arquivo(|todos| {
        todos.retain(|e| e.device_id != novo.device_id);
        todos.push(novo);
    });
}

/// **Relê, muda e grava** (a limpeza, a remoção, o esquecimento) — pela mesma regra de [`gravar`]:
/// relê o disco em vez de gravar a memória, e não toca num arquivo ilegível.
fn mudar_o_arquivo(mudar: impl FnOnce(&mut Vec<regras::Entrada>)) {
    let Some(p) = arquivo() else { return };
    let (mut todos, legivel) = ler_com_estado();
    if !legivel {
        registro::linha(format!(
            "baias: não regravo {} — ele está ilegível, e regravar apagaria os aparelhos dele",
            p.display()
        ));
        return;
    }
    let antes = todos.clone();
    mudar(&mut todos);
    if todos != antes {
        escrever(&todos);
    }
}

/// **Bancada (`--esquecer-par`)**: o aparelho esquecido sai também do `baias.json`, sem app aberto.
pub fn esquecer_aparelho_no_arquivo(device_id: &str) {
    mudar_o_arquivo(|todos| todos.retain(|e| e.device_id != device_id));
}

pub struct Registro {
    /// `--sem-cameras-virtuais` **não** foi passada. Sem permissão, este registro não cria câmera
    /// nenhuma e não escreve arquivo nenhum — é como se a frente não existisse.
    permitida: bool,
    /// **O interruptor "Câmera virtual" dos Ajustes** (12/10/2026), lido de
    /// `camera-virtual.txt` na abertura e gravado a cada toque. Desligado, os canos e as placas
    /// continuam de pé (são Rust puro e não aparecem para ninguém), e o que some são os **nós** —
    /// a câmera na lista do Zoom.
    ligada: AtomicBool,
    /// **A fonte da câmera registrada no Windows** (tarde de 12/10/2026,
    /// `regras_da_instalacao_da_camera.rs`). Sem ela o fio não cria nó nenhum: o Frame Server não
    /// acharia a classe. Lida na abertura e mantida em dia pela janela ([`Registro::definir_instalada`]),
    /// que relê a cada 2 s, na volta do foco e no fim do botão: instalar ou remover com o Quall
    /// aberto, pelo botão ou pelo `quall-camera.exe`, muda as câmeras sem fechar o app.
    instalada: AtomicBool,
    /// As baias, **por nome de câmera** — o nome dá o cano (`cano_do_nome`) e o nó. Até 13/10/2026
    /// eram por `device_id`, e um aparelho reinstalado (outra identidade, o mesmo nome) subia uma
    /// segunda baia no mesmo cano: o vídeo ia para uma, o Frame Server lia a outra. Ver
    /// `regras_da_camera_virtual::ao_conectar`.
    abertas: Mutex<HashMap<String, Arc<Baia>>>,
    /// `device_id → nome` de cada aparelho com câmera (do `baias.json` e das conexões).
    aparelhos: Mutex<BTreeMap<String, String>>,
    /// Quem cria e solta os nós. Sobe na primeira vez que alguém pede câmera (não em `novo`: as
    /// sondas de bancada que montam um `Receptor` sem câmera nenhuma não ganham um fio à toa).
    fio: OnceLock<FioDasCameras>,
    /// Sobe quando o interruptor muda, para a janela redesenhar o cartão antes de o fio responder.
    revisao_local: AtomicU64,
}

/// Ao lado do `baias.json`, pela mesma regra (`%APPDATA%\Quall`): este módulo compila sem `net`,
/// e `identidade::pasta_de_dados` não.
fn arquivo_da_preferencia() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(PathBuf::from(base).join("Quall").join(regras::ARQUIVO_DA_PREFERENCIA))
}

impl Registro {
    pub fn novo(permitida: bool) -> Arc<Self> {
        let guardada = arquivo_da_preferencia().and_then(|p| std::fs::read_to_string(p).ok());
        let ligada = permitida && regras::ler_preferencia(guardada.as_deref());
        let instalacao = crate::instalador_da_camera::ler_situacao();
        registro::linha(format!("cameras virtuais: instalação {instalacao:?} na abertura"));
        Arc::new(Registro {
            permitida,
            ligada: AtomicBool::new(ligada),
            instalada: AtomicBool::new(instalacao.registrada()),
            abertas: Mutex::new(HashMap::new()),
            aparelhos: Mutex::new(BTreeMap::new()),
            fio: OnceLock::new(),
            revisao_local: AtomicU64::new(0),
        })
    }

    fn fio(&self) -> &FioDasCameras {
        self.fio.get_or_init(FioDasCameras::subir)
    }

    /// Sobe o cano de cada aparelho que este computador já conhece, e pede ao fio as câmeras
    /// (se o interruptor estiver ligado).
    ///
    /// Erro numa não impede as outras: uma câmera que não sobe é uma linha no registro, não o app
    /// sem receptor. Os nós nascem no fio, **não** aqui: esta função volta na hora, e a câmera entra
    /// na lista do Windows logo depois.
    ///
    /// `pareado` diz se um aparelho ainda está no `pares.json`: com ele, a **limpeza da abertura**
    /// (`regras::limpar_na_abertura`, 13/10/2026) tira os aparelhos fora dos pares que não
    /// transmitem há 30 dias e junta as entradas repetidas de um nome, e regrava o arquivo.
    pub fn abrir_conhecidas(&self, pareado: impl Fn(&str) -> bool) {
        if !self.permitida {
            registro::linha("cameras virtuais: desligadas (--sem-cameras-virtuais)");
            return;
        }
        let mut conhecidos = Vec::new();
        mudar_o_arquivo(|todos| {
            let antes = todos.len();
            *todos = regras::limpar_na_abertura(std::mem::take(todos), &pareado, agora());
            if todos.len() < antes {
                registro::linha(format!(
                    "cameras virtuais: limpeza da abertura, {antes} entradas -> {} (repetidas ou velhas fora dos pares)",
                    todos.len()
                ));
            }
            conhecidos = todos.clone();
        });
        let conhecidos: Vec<(String, String)> = conhecidos.into_iter().map(|e| (e.device_id, e.nome)).collect();
        if conhecidos.is_empty() {
            registro::linha(
                "cameras virtuais: nenhum aparelho conhecido ainda — a câmera de um aparelho \
                 aparece depois da primeira conexão dele",
            );
        }
        let nomes = regras::baias_da_abertura(conhecidos.iter().map(|(i, n)| (i.as_str(), n.as_str())));
        if nomes.len() < conhecidos.len() {
            registro::linha(format!(
                "cameras virtuais: {} aparelhos conhecidos, {} câmeras (aparelhos com o mesmo nome dividem a câmera)",
                conhecidos.len(),
                nomes.len()
            ));
        }
        self.aparelhos
            .lock()
            .unwrap()
            .extend(conhecidos.into_iter().filter(|(_, n)| !n.trim().is_empty()));
        for nome in nomes {
            self.abrir(&nome);
        }
        self.sincronizar();
    }

    /// Leva ao fio as câmeras que devem existir agora ([`regras::desejadas`]).
    fn sincronizar(&self) {
        if !self.permitida {
            return;
        }
        let nomes: Vec<String> = self.abertas.lock().unwrap().values().map(|b| b.nome.clone()).collect();
        let d = regras::desejadas(
            self.permitida,
            self.instalada.load(Ordering::Relaxed),
            self.ligada.load(Ordering::Relaxed),
            nomes.iter().map(String::as_str),
        );
        self.fio().querer(d);
    }

    /// **O interruptor "Câmera virtual"**: guarda a escolha e leva ao fio. Da thread da janela —
    /// que só escreve um arquivo de dez bytes e manda um recado; o trabalho é do fio.
    pub fn definir_ligada(&self, ligada: bool) {
        if !self.permitida {
            return;
        }
        self.ligada.store(ligada, Ordering::Relaxed);
        self.revisao_local.fetch_add(1, Ordering::Relaxed);
        if let Some(p) = arquivo_da_preferencia() {
            if let Some(pasta) = p.parent() {
                let _ = std::fs::create_dir_all(pasta);
            }
            if let Err(e) = std::fs::write(&p, regras::escrever_preferencia(ligada)) {
                registro::linha(format!("cameras virtuais: não guardei a escolha ({e})"));
            }
        }
        registro::linha(format!("cameras virtuais: interruptor {}", if ligada { "ligado" } else { "desligado" }));
        self.sincronizar();
    }

    /// **A instalação mudou** (a fonte entrou ou saiu do registro do Windows): leva ao fio, que cria
    /// ou solta os nós. Só age quando muda; chamar a cada releitura não custa nada.
    pub fn definir_instalada(&self, instalada: bool) {
        if self.instalada.swap(instalada, Ordering::Relaxed) == instalada {
            return;
        }
        self.revisao_local.fetch_add(1, Ordering::Relaxed);
        registro::linha(format!(
            "cameras virtuais: a fonte {} no Windows",
            if instalada { "entrou" } else { "saiu" }
        ));
        self.sincronizar();
    }

    pub fn ligada(&self) -> bool {
        self.permitida && self.ligada.load(Ordering::Relaxed)
    }

    /// O que o cartão dos Ajustes mostra.
    pub fn situacao(&self) -> regras::Situacao {
        let a = self.fio.get().map(FioDasCameras::andamento).unwrap_or_default();
        regras::Situacao {
            permitida: self.permitida,
            instalada: self.instalada.load(Ordering::Relaxed),
            ligada: self.ligada(),
            conhecidos: self.quantas(),
            vivas: a.vivas.len(),
            trabalhando: a.trabalhando,
            falha: a.falha,
        }
    }

    /// Muda quando o cartão precisa ser redesenhado (o interruptor ou o fio).
    pub fn revisao(&self) -> u64 {
        self.revisao_local.load(Ordering::Relaxed) + self.fio.get().map_or(0, FioDasCameras::revisao)
    }

    /// Solta as câmeras **antes** do `MFShutdown` do fim do `main`. Ver `fio_das_cameras.rs`.
    pub fn encerrar(&self) {
        if let Some(f) = self.fio.get() {
            f.encerrar();
        }
    }

    /// A baia deste aparelho, criando-a se ainda não existir. `None` quando proibida ou quando a
    /// criação falhou. O nó (a câmera na lista) vem do fio, se o interruptor estiver ligado.
    pub fn obter_ou_criar(&self, device_id: &str, nome: &str) -> Option<Arc<Baia>> {
        if !self.permitida || nome.is_empty() {
            return None;
        }
        // O nome guardado é o **desta** conexão: se o aparelho mudou de nome, a câmera antiga sai e
        // a nova entra (o fio solta antes de criar). Ver o cabeçalho.
        gravar(regras::Entrada { device_id: device_id.to_string(), nome: nome.to_string(), visto_em: Some(agora()) });
        // **Pelo nome, nunca pelo aparelho** (13/10/2026): o reinstalado e o do mesmo modelo
        // reaproveitam a baia do nome. Ver `regras::ao_conectar`.
        let plano = {
            let aparelhos = self.aparelhos.lock().unwrap();
            let abertas: Vec<String> = self.abertas.lock().unwrap().keys().cloned().collect();
            regras::ao_conectar(&aparelhos, &abertas, device_id, nome)
        };
        self.aparelhos.lock().unwrap().insert(device_id.to_string(), nome.to_string());
        if let Some(antigo) = &plano.soltar {
            // Fora da trava: soltar a baia junta os fios dela.
            let velha = self.abertas.lock().unwrap().remove(antigo);
            drop(velha);
            registro::linha("camera virtual (nome omitido): o aparelho mudou de nome; a câmera do nome antigo saiu");
        }
        if !plano.abrir {
            // A cópia antes: `sincronizar` toma a mesma trava.
            let existente = self.abertas.lock().unwrap().get(nome).cloned();
            if let Some(b) = existente {
                if plano.soltar.is_some() {
                    self.sincronizar();
                }
                return Some(b);
            }
        }
        // Nome novo: o cano sobe **agora** — é Rust puro e pode nascer em qualquer thread — e o nó
        // é pedido ao fio. Sem isto, a câmera de um aparelho recém-pareado só existia na próxima
        // abertura do app — o que Bruno pegou em campo: *"pareado s24 no dell não apareceu como
        // camera virtual"*.
        let baia = self.abrir(nome);
        if baia.is_some() || plano.soltar.is_some() {
            self.sincronizar();
        }
        if baia.is_some() {
            registro::linha("camera virtual (nome omitido): cano de pé; o nó foi pedido ao fio");
        }
        baia
    }

    /// Sobe **o cano e a placa** da câmera deste nome (não o nó — ver `abrir_conhecidas`). Com a
    /// trava tomada do começo ao fim: duas conexões do mesmo nome ao mesmo tempo não sobem duas
    /// baias no mesmo cano; a segunda recebe a da primeira.
    fn abrir(&self, nome: &str) -> Option<Arc<Baia>> {
        let mut abertas = self.abertas.lock().unwrap();
        if let Some(b) = abertas.get(nome) {
            return Some(Arc::clone(b));
        }
        match Baia::abrir(nome) {
            Ok(b) => {
                let b = Arc::new(b);
                abertas.insert(nome.to_string(), Arc::clone(&b));
                Some(b)
            }
            Err(erro) => {
                registro::linha(format!("camera virtual (nome omitido): não subiu — {erro:#}"));
                None
            }
        }
    }

    /// **As câmeras deste computador**, para os Ajustes: uma por nome, e se alguém lê agora.
    pub fn linhas(&self) -> Vec<regras::LinhaDaCamera> {
        let mut v: Vec<regras::LinhaDaCamera> = self
            .abertas
            .lock()
            .map(|a| a.iter().map(|(nome, b)| regras::LinhaDaCamera { nome: nome.clone(), em_uso: b.alguem_lendo() }).collect())
            .unwrap_or_default();
        v.sort_by(|a, b| a.nome.cmp(&b.nome));
        v
    }

    /// **Remove a câmera `nome`** (os Ajustes, 13/10/2026): sai do `baias.json` (todas as entradas
    /// do nome), a baia sai e o fio solta o nó — some do app Câmera na hora. **Não** desfaz o
    /// pareamento: o aparelho que transmitir de novo para cá ganha a câmera de volta
    /// (`obter_ou_criar`).
    pub fn remover(&self, nome: &str) {
        mudar_o_arquivo(|todos| *todos = regras::sem_o_nome(std::mem::take(todos), nome));
        self.aparelhos.lock().unwrap().retain(|_, n| n != nome);
        let velha = self.abertas.lock().unwrap().remove(nome);
        drop(velha);
        self.revisao_local.fetch_add(1, Ordering::Relaxed);
        registro::linha("cameras virtuais: uma câmera removida pelos Ajustes (o pareamento fica)");
        self.sincronizar();
    }

    /// **Remove todas as câmeras** (o "Remover todas" dos Ajustes, e o "Esquecer pareamentos": sem
    /// pares, nenhum aparelho tem câmera).
    pub fn remover_todas(&self, porque: &str) {
        mudar_o_arquivo(|todos| todos.clear());
        self.aparelhos.lock().unwrap().clear();
        let velhas: Vec<Arc<Baia>> = self.abertas.lock().unwrap().drain().map(|(_, b)| b).collect();
        let n = velhas.len();
        drop(velhas);
        self.revisao_local.fetch_add(1, Ordering::Relaxed);
        registro::linha(format!("cameras virtuais: {n} câmeras removidas ({porque})"));
        self.sincronizar();
    }

    pub fn quantas(&self) -> usize {
        self.abertas.lock().unwrap().len()
    }

    /// **Alguma câmera do Quall está em uso agora?** Alguém lendo o cano de qualquer baia — o
    /// servidor de quadros do Windows só abre o cano quando um app abre a câmera. É a D3 do
    /// `docs/som-no-receptor.md` §12.1 no Windows: o receptor cala o som enquanto isto for
    /// verdade, para o som do cômodo não vazar para a chamada, a menos que a pessoa marque "tocar
    /// mesmo com a câmera em uso". Proibida (`--sem-cameras-virtuais`), nunca.
    pub fn alguma_em_uso(&self) -> bool {
        self.permitida
            && self
                .abertas
                .lock()
                .map(|a| a.values().any(|b| b.alguem_lendo()))
                .unwrap_or(false)
    }
}
