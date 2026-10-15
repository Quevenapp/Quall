//! **A geometria do texto diagramado, a rolagem e a cadência** — sem DirectWrite e sem janela,
//! para ser provada por teste de unidade. É o porte de `GeometriaDoTexto` e `Rolagem` do Mac
//! (`QuallTeleprompterKit/GeometriaDoTexto.swift`) e de `Percurso` do Android; as contas são as
//! mesmas nas quatro telas, e é isso que faz "0,5" querer dizer "o meio do percurso" em todas.
//!
//! # A posição do contrato
//!
//! `posicao` é "fração do percurso: 0 = começo na linha de leitura, 1 = fim nela" (§3). Aqui:
//! com deslocamento 0, **o centro da primeira linha** está na linha de leitura; com deslocamento
//! `percurso`, o centro da última. `percurso = (linhas − 1) × altura`.
//!
//! Todas as linhas têm a **mesma altura** — a da fonte do prompter —, que é a unidade da
//! velocidade ("linhas por segundo", §3): velocidade constante em linhas por segundo é velocidade
//! constante em pixels por segundo, e o texto não acelera numa linha em branco.

/// Onde cada linha começa (em unidades UTF-16, a unidade do DirectWrite) e a altura delas, em
/// pixels.
#[derive(Debug, Clone, PartialEq)]
pub struct GeometriaDoTexto {
    pub altura_da_linha: f64,
    pub inicios: Vec<usize>,
    pub comprimento_utf16: usize,
}

impl GeometriaDoTexto {
    pub fn nova(altura_da_linha: f64, inicios: Vec<usize>, comprimento_utf16: usize) -> Self {
        GeometriaDoTexto {
            altura_da_linha: if altura_da_linha.is_finite() { altura_da_linha.max(1.0) } else { 1.0 },
            inicios,
            comprimento_utf16,
        }
    }

    pub fn vazia() -> Self {
        GeometriaDoTexto::nova(1.0, Vec::new(), 0)
    }

    pub fn quantas_linhas(&self) -> usize {
        self.inicios.len()
    }

    pub fn percurso(&self) -> f64 {
        self.inicios.len().saturating_sub(1) as f64 * self.altura_da_linha
    }

    pub fn deslocamento_da_posicao(&self, p: f64) -> f64 {
        if !p.is_finite() {
            return 0.0;
        }
        p.clamp(0.0, 1.0) * self.percurso()
    }

    pub fn posicao_do_deslocamento(&self, d: f64) -> f64 {
        let percurso = self.percurso();
        if percurso <= 0.0 || !d.is_finite() {
            return 0.0;
        }
        (d / percurso).clamp(0.0, 1.0)
    }

    /// A linha cujo centro está mais perto da linha de leitura, com o deslocamento `d`.
    pub fn linha_no_deslocamento(&self, d: f64) -> usize {
        if self.inicios.is_empty() || !d.is_finite() {
            return 0;
        }
        let i = (d / self.altura_da_linha).round();
        (i.max(0.0) as usize).min(self.inicios.len() - 1)
    }

    /// A linha que contém o caractere `c`: a última cujo início é `<= c`.
    pub fn linha_do_caractere(&self, c: usize) -> usize {
        if self.inicios.is_empty() {
            return 0;
        }
        match self.inicios.binary_search(&c) {
            Ok(i) => i,
            Err(0) => 0,
            Err(i) => i - 1,
        }
    }

    /// **O ponto de leitura**: o caractere que abre a linha que está na linha de leitura, e quanto
    /// do caminho até a próxima já foi andado (−0,5 a 0,5). É o que se guarda antes de refazer o
    /// layout, para quem lê não perder o lugar quando a fonte ou a margem mudam.
    pub fn ponto_de_leitura(&self, d: f64) -> (usize, f64) {
        if self.inicios.is_empty() {
            return (0, 0.0);
        }
        let i = self.linha_no_deslocamento(d);
        let fracao = (d / self.altura_da_linha - i as f64).clamp(-0.5, 0.5);
        (self.inicios[i], fracao)
    }

    /// O deslocamento que põe o ponto de leitura de volta na linha de leitura, nesta geometria.
    /// Um caractere além do fim do texto (o texto encolheu) cai na última linha.
    pub fn deslocamento_do_ponto(&self, ponto: (usize, f64)) -> f64 {
        if self.inicios.is_empty() {
            return 0.0;
        }
        let i = self.linha_do_caractere(ponto.0);
        ((i as f64 + ponto.1) * self.altura_da_linha).clamp(0.0, self.percurso())
    }

    /// As linhas que aparecem numa vista de `altura_visivel` pixels, com a linha de leitura a
    /// `y_leitura` pixels do topo e o deslocamento `d`. Só essas são desenhadas.
    pub fn linhas_visiveis(&self, d: f64, y_leitura: f64, altura_visivel: f64) -> std::ops::Range<usize> {
        if self.inicios.is_empty() {
            return 0..0;
        }
        let topo = self.topo_do_texto(d, y_leitura);
        let primeira = ((0.0 - topo) / self.altura_da_linha).floor();
        let ultima = ((altura_visivel - topo) / self.altura_da_linha).ceil();
        let n = self.inicios.len() as f64;
        let a = primeira.clamp(0.0, n) as usize;
        let b = ultima.clamp(a as f64, n) as usize;
        a..b
    }

    /// Onde fica o topo da primeira linha, em pixels da vista (y para baixo): o centro da linha 0
    /// fica em `y_leitura` quando `d = 0`.
    pub fn topo_do_texto(&self, d: f64, y_leitura: f64) -> f64 {
        y_leitura - self.altura_da_linha / 2.0 - d
    }
}

/// **A rolagem em velocidade constante.** O integrador de um quadro para o outro, sem relógio
/// próprio: quem chama passa o `dt` medido entre dois quadros de verdade — nunca um passo fixo por
/// quadro, que andaria mais devagar quando um quadro atrasa e mais depressa num monitor de 144 Hz.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rolagem {
    pub deslocamento: f64,
}

impl Rolagem {
    /// Um quadro que chega depois de o computador acordar do repouso não pode arrastar o texto
    /// meia página de uma vez.
    pub const DT_MAXIMO: f64 = 0.25;

    /// Anda `dt` segundos. Devolve `true` quando **acabou de chegar** ao fim (neste passo).
    pub fn avancar(&mut self, dt: f64, linhas_por_segundo: f64, g: &GeometriaDoTexto) -> bool {
        if !(dt.is_finite() && linhas_por_segundo.is_finite()) || dt <= 0.0 || linhas_por_segundo <= 0.0 {
            return false;
        }
        let antes = self.deslocamento;
        let passo = dt.min(Rolagem::DT_MAXIMO) * linhas_por_segundo * g.altura_da_linha;
        self.deslocamento = (self.deslocamento + passo).min(g.percurso());
        g.percurso() > 0.0 && antes < g.percurso() && self.deslocamento >= g.percurso()
    }

    /// **Anda para trás** `dt` segundos, na mesma velocidade (o "segurar para rolar" com
    /// `para_tras`, §12.5 do contrato), e **para no começo** — quem chama não muda `rolando`: o
    /// texto fica parado na posição 0 até o controle soltar. Devolve `true` quando acabou de chegar
    /// ao começo (neste passo).
    pub fn recuar(&mut self, dt: f64, linhas_por_segundo: f64, g: &GeometriaDoTexto) -> bool {
        if !(dt.is_finite() && linhas_por_segundo.is_finite()) || dt <= 0.0 || linhas_por_segundo <= 0.0 {
            return false;
        }
        let antes = self.deslocamento;
        let passo = dt.min(Rolagem::DT_MAXIMO) * linhas_por_segundo * g.altura_da_linha;
        self.deslocamento = (self.deslocamento - passo).max(0.0);
        antes > 0.0 && self.deslocamento <= 0.0
    }

    /// Vai direto a um deslocamento (salto, layout novo), preso ao percurso.
    pub fn ir(&mut self, d: f64, g: &GeometriaDoTexto) {
        if d.is_finite() {
            self.deslocamento = d.clamp(0.0, g.percurso());
        }
    }

    pub fn no_fim(&self, g: &GeometriaDoTexto) -> bool {
        g.percurso() > 0.0 && self.deslocamento >= g.percurso()
    }
}

/// **O texto indo suave até um alvo**: as setas e o PgUp/PgDn do teclado (o pedido de 14/10). Um
/// toque põe o alvo uma linha (ou uma tela) adiante e o texto chega lá em ~[`Deslize::TAU`] × 3, sem
/// pulo; toques rápidos somam. **Segurada** (a repetição do teclado), o alvo nunca passa de um passo à
/// frente de onde o texto está: o texto anda em velocidade constante (≈ um passo por `TAU`), qualquer
/// que seja a cadência de repetição do teclado de quem usa.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Deslize {
    pub alvo: f64,
}

impl Deslize {
    /// A constante de tempo da aproximação, em segundos.
    pub const TAU: f64 = 0.10;
    /// Abaixo disto (px) o texto está no alvo.
    pub const CHEGADA_PX: f64 = 0.25;

    /// Um toque (ou uma repetição) de `delta` pixels a partir de onde o texto está (`d`) ou de onde ele
    /// já ia (`atual`).
    pub fn empurrar(atual: Option<Deslize>, d: f64, delta: f64, repeticao: bool, g: &GeometriaDoTexto) -> Deslize {
        let base = atual.map(|a| a.alvo).unwrap_or(d);
        let mut alvo = base + delta;
        if repeticao {
            // No máximo um passo à frente do texto, no sentido do passo.
            alvo = if delta >= 0.0 { alvo.min(d + delta) } else { alvo.max(d + delta) };
        }
        Deslize { alvo: alvo.clamp(0.0, g.percurso()) }
    }

    /// O texto rolando andou `passo` px por conta própria: o alvo anda junto.
    pub fn acompanhar(&mut self, passo: f64, g: &GeometriaDoTexto) {
        self.alvo = (self.alvo + passo).clamp(0.0, g.percurso());
    }

    /// Um quadro de `dt` segundos. Devolve `true` quando chegou (o texto fica exatamente no alvo).
    pub fn passo(&self, r: &mut Rolagem, dt: f64, g: &GeometriaDoTexto) -> bool {
        let dt = if dt.is_finite() && dt > 0.0 { dt.min(Rolagem::DT_MAXIMO) } else { 0.0 };
        let falta = self.alvo - r.deslocamento;
        let novo = r.deslocamento + falta * (1.0 - (-dt / Self::TAU).exp());
        if (self.alvo - novo).abs() <= Self::CHEGADA_PX {
            r.ir(self.alvo, g);
            return true;
        }
        r.ir(novo, g);
        false
    }
}

/// **A cadência da rolagem**, contada quadro a quadro — a testemunha de "sem saltos" que não
/// depende de olhar a tela (a mesma ideia do `quadrosAtrasados` da vista do Mac).
///
/// Um quadro é **atrasado** quando a tela mostrou o anterior por mais de um período:
///
/// - com o compositor da área de trabalho (DWM) ligado, pelo **contador de retraços** que o
///   próprio DWM devolve (`DWM_TIMING_INFO::cRefresh`): entre dois quadros nossos passaram mais
///   de um retraço → a tela repetiu um quadro. É o que se vê, e não o que o laço acha;
/// - sem DWM (a Sessão 0 do SSH, sem monitor), pelo intervalo do laço, acima de 1,5 período.
///   Aí o número diz só se o **laço** manteve o compasso — não há tela para errar.
#[derive(Debug, Clone, Default)]
pub struct Cadencia {
    pub periodo_ms: f64,
    pub quadros: u64,
    pub atrasados: u64,
    /// Soma dos retraços perdidos (um quadro que ficou três retraços conta dois).
    pub retracos_perdidos: u64,
    /// Dois quadros nossos no mesmo retraço (o segundo nunca apareceu).
    pub no_mesmo_retraco: u64,
    pub maior_intervalo_ms: f64,
    pub pelo_dwm: u64,
    intervalos: Vec<f32>,
    custos: Vec<f32>,
}

/// O resumo que vai para o relato.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct ResumoDaCadencia {
    pub quadros: u64,
    pub atrasados: u64,
    pub retracos_perdidos: u64,
    pub no_mesmo_retraco: u64,
    pub quadros_contados_pelo_dwm: u64,
    pub periodo_ms: f64,
    pub intervalo_p50_ms: f64,
    pub intervalo_p99_ms: f64,
    pub maior_intervalo_ms: f64,
    pub desenho_p50_ms: f64,
    pub desenho_p99_ms: f64,
    pub desenho_max_ms: f64,
}

/// Até quantas amostras de cada coisa se guardam (uma hora a 60 Hz cabe em 216 mil; o resto só
/// conta).
const TETO_DE_AMOSTRAS: usize = 250_000;

impl Cadencia {
    pub fn nova(periodo_ms: f64) -> Cadencia {
        Cadencia { periodo_ms, ..Cadencia::default() }
    }

    /// Um quadro com o texto rolando. `intervalo_ms` desde o anterior (o primeiro de uma rolagem
    /// não conta), `custo_ms` do desenho, e quantos retraços o DWM contou desde o anterior, se ele
    /// estiver ligado.
    pub fn quadro(&mut self, intervalo_ms: f64, custo_ms: f64, retracos: Option<u64>) {
        self.quadros += 1;
        self.maior_intervalo_ms = self.maior_intervalo_ms.max(intervalo_ms);
        match retracos {
            Some(r) => {
                self.pelo_dwm += 1;
                if r == 0 {
                    self.no_mesmo_retraco += 1;
                } else if r > 1 {
                    self.atrasados += 1;
                    self.retracos_perdidos += r - 1;
                }
            }
            None => {
                if self.periodo_ms > 0.0 && intervalo_ms > self.periodo_ms * 1.5 {
                    self.atrasados += 1;
                }
            }
        }
        if self.intervalos.len() < TETO_DE_AMOSTRAS {
            self.intervalos.push(intervalo_ms as f32);
            self.custos.push(custo_ms as f32);
        }
    }

    pub fn resumo(&self) -> ResumoDaCadencia {
        let mut i = self.intervalos.clone();
        let mut c = self.custos.clone();
        ResumoDaCadencia {
            quadros: self.quadros,
            atrasados: self.atrasados,
            retracos_perdidos: self.retracos_perdidos,
            no_mesmo_retraco: self.no_mesmo_retraco,
            quadros_contados_pelo_dwm: self.pelo_dwm,
            periodo_ms: arredondar(self.periodo_ms),
            intervalo_p50_ms: arredondar(percentil(&mut i, 0.50)),
            intervalo_p99_ms: arredondar(percentil(&mut i, 0.99)),
            maior_intervalo_ms: arredondar(self.maior_intervalo_ms),
            desenho_p50_ms: arredondar(percentil(&mut c, 0.50)),
            desenho_p99_ms: arredondar(percentil(&mut c, 0.99)),
            desenho_max_ms: arredondar(c.iter().copied().fold(0.0f32, f32::max) as f64),
        }
    }
}

/// **A rolagem medida em janelas de 10 s, para o diário** (o relato de 14/10: "o prompter do Dell
/// está rolando o texto em socos" — só na tela R5, a com câmera). O [`Cadencia`] resume a corrida
/// inteira, e só a bancada o grava; esta janela vai ao diário **em todo uso**, como o `rolagem sem
/// evento` do iOS, para que a próxima prova diga, sem bancada, onde o tempo do quadro foi.
///
/// Por quadro com o texto rolando: o intervalo desde o anterior, o **passo** (quantos pixels o texto
/// andou nele — com a velocidade constante, um passo maior que o normal é o soco que se vê) e o custo
/// do desenho. E, de fora do quadro, quantas vezes a janela se redispôs e se pintou enquanto rolava:
/// é o trabalho que disputa o retraço com o desenho.
#[derive(Debug, Clone, Default)]
pub struct JanelaDaRolagem {
    pub periodo_ms: f64,
    quadros: u64,
    atrasados: u64,
    retracos_perdidos: u64,
    intervalos: Vec<f32>,
    passos: Vec<f32>,
    custos: Vec<f32>,
    /// `posicionar` chamado com o texto rolando (cada um mexe nos controles filhos).
    pub disposicoes: u64,
    /// `WM_PAINT` com o texto rolando; `pinturas_com_texto` são as que redesenharam o texto (o
    /// desenho a mais, fora do laço de quadros).
    pub pinturas: u64,
    pub pinturas_com_texto: u64,
}

/// O resumo de uma janela de [`JanelaDaRolagem`].
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize)]
pub struct ResumoDaJanela {
    pub quadros: u64,
    pub atrasados: u64,
    pub retracos_perdidos: u64,
    pub intervalo_p50_ms: f64,
    pub intervalo_p95_ms: f64,
    pub intervalo_max_ms: f64,
    pub passo_p50_px: f64,
    pub passo_p95_px: f64,
    pub passo_max_px: f64,
    pub desenho_p50_ms: f64,
    pub desenho_p95_ms: f64,
    pub desenho_max_ms: f64,
    pub disposicoes: u64,
    pub pinturas: u64,
    pub pinturas_com_texto: u64,
}

impl JanelaDaRolagem {
    /// A janela fecha a cada 10 s de texto rolando.
    pub const DURACAO: std::time::Duration = std::time::Duration::from_secs(10);

    pub fn nova(periodo_ms: f64) -> JanelaDaRolagem {
        JanelaDaRolagem { periodo_ms, ..JanelaDaRolagem::default() }
    }

    /// Um quadro com o texto rolando (o primeiro de uma rolagem não conta: não tem intervalo).
    /// `retracos`: quantos o DWM contou desde o anterior, se ele estiver ligado — como no
    /// [`Cadencia`], é ele que diz se a tela repetiu um quadro.
    pub fn quadro(&mut self, intervalo_ms: f64, passo_px: f64, custo_ms: f64, retracos: Option<u64>) {
        self.quadros += 1;
        match retracos {
            Some(r) if r > 1 => {
                self.atrasados += 1;
                self.retracos_perdidos += r - 1;
            }
            Some(_) => {}
            None => {
                if self.periodo_ms > 0.0 && intervalo_ms > self.periodo_ms * 1.5 {
                    self.atrasados += 1;
                }
            }
        }
        // Dez segundos a 240 Hz cabem; uma janela que não fecha (o relógio parado) não cresce além.
        if self.intervalos.len() < 4096 {
            self.intervalos.push(intervalo_ms as f32);
            self.passos.push(passo_px.abs() as f32);
            self.custos.push(custo_ms as f32);
        }
    }

    pub fn quadros(&self) -> u64 {
        self.quadros
    }

    /// Fecha a janela: o resumo dela, e a janela zerada (o período fica). Sem quadro nenhum, `None`
    /// (e os contadores de fora do quadro também zeram).
    pub fn fechar(&mut self) -> Option<ResumoDaJanela> {
        let periodo = self.periodo_ms;
        let mut j = std::mem::replace(self, JanelaDaRolagem::nova(periodo));
        if j.quadros == 0 {
            return None;
        }
        let maior = |v: &[f32]| v.iter().copied().fold(0.0f32, f32::max) as f64;
        Some(ResumoDaJanela {
            quadros: j.quadros,
            atrasados: j.atrasados,
            retracos_perdidos: j.retracos_perdidos,
            intervalo_max_ms: arredondar(maior(&j.intervalos)),
            intervalo_p50_ms: arredondar(percentil(&mut j.intervalos, 0.50)),
            intervalo_p95_ms: arredondar(percentil(&mut j.intervalos, 0.95)),
            passo_max_px: arredondar(maior(&j.passos)),
            passo_p50_px: arredondar(percentil(&mut j.passos, 0.50)),
            passo_p95_px: arredondar(percentil(&mut j.passos, 0.95)),
            desenho_max_ms: arredondar(maior(&j.custos)),
            desenho_p50_ms: arredondar(percentil(&mut j.custos, 0.50)),
            desenho_p95_ms: arredondar(percentil(&mut j.custos, 0.95)),
            disposicoes: j.disposicoes,
            pinturas: j.pinturas,
            pinturas_com_texto: j.pinturas_com_texto,
        })
    }
}

impl ResumoDaJanela {
    /// A linha do diário. `tela` é `texto` ou `r5`; `alvo`, o do Direct2D.
    pub fn linha(&self, tela: &str, alvo: &str, segundos: f64) -> String {
        format!(
            "teleprompter: rolagem ({tela}, {segundos:.1} s): quadros={} atrasados={} retracos_perdidos={} \
             intervalo p50={:.2} p95={:.2} max={:.2} ms | passo p50={:.2} p95={:.2} max={:.2} px | \
             desenho p50={:.2} p95={:.2} max={:.2} ms ({alvo}) | rolando: disposicoes={} pinturas={} (com o texto {})",
            self.quadros,
            self.atrasados,
            self.retracos_perdidos,
            self.intervalo_p50_ms,
            self.intervalo_p95_ms,
            self.intervalo_max_ms,
            self.passo_p50_px,
            self.passo_p95_px,
            self.passo_max_px,
            self.desenho_p50_ms,
            self.desenho_p95_ms,
            self.desenho_max_ms,
            self.disposicoes,
            self.pinturas,
            self.pinturas_com_texto,
        )
    }
}

/// **Qual alvo do Direct2D desenha o texto, decidido pela medida** (14/10). O alvo padrão do
/// `ID2D1DCRenderTarget` desenha na GPU e **lê o quadro de volta** para o DC a cada `EndDraw`: com a
/// GPU ocupada pela câmera (a conversão da prévia, o codificador da transmissão e o da gravação), essa
/// leitura pode esperar a fila dela, e o custo do desenho fica irregular. Sem a câmera ele é pequeno e
/// o texto corre liso. O alvo de software não toca na GPU, mas gasta CPU em cada quadro.
///
/// A regra: com o padrão, uma janela de 10 s cujo desenho passa de 40 % do período no p95 manda
/// **provar** o software na janela seguinte; ao fim dela fica o que desenhou melhor (o p95 menor, e
/// não mais quadros atrasados), e a escolha não muda mais nesta tela. Um padrão barato nunca troca:
/// se o soco vier de outro lugar, o desenho não é a causa e o software não ajudaria.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum EscolhaDoAlvo {
    #[default]
    Padrao,
    ProvandoSoftware {
        desenho_p95_ms: f64,
        atrasados_por_mil: f64,
    },
    Decidido {
        software: bool,
    },
}

/// O que a janela faz depois de uma decisão.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrocaDoAlvo {
    Nada,
    ParaSoftware,
    ParaPadrao,
}

impl EscolhaDoAlvo {
    /// A fração do período que o desenho pode tomar (p95) antes de o software ser provado.
    pub const LIMITE_DO_DESENHO: f64 = 0.40;
    /// Janelas com menos quadros que isso não decidem (um toque em pausa logo depois do play).
    pub const QUADROS_PARA_DECIDIR: u64 = 120;

    /// A próxima escolha, depois de uma janela fechada.
    pub fn depois(self, r: &ResumoDaJanela, periodo_ms: f64) -> (EscolhaDoAlvo, TrocaDoAlvo) {
        if r.quadros < Self::QUADROS_PARA_DECIDIR || periodo_ms <= 0.0 {
            return (self, TrocaDoAlvo::Nada);
        }
        let por_mil = 1000.0 * r.atrasados as f64 / r.quadros as f64;
        match self {
            EscolhaDoAlvo::Padrao if r.desenho_p95_ms > Self::LIMITE_DO_DESENHO * periodo_ms => (
                EscolhaDoAlvo::ProvandoSoftware { desenho_p95_ms: r.desenho_p95_ms, atrasados_por_mil: por_mil },
                TrocaDoAlvo::ParaSoftware,
            ),
            EscolhaDoAlvo::ProvandoSoftware { desenho_p95_ms, atrasados_por_mil } => {
                // Dez por mil de folga nos atrasados: a janela de prova não é a mesma cena.
                if r.desenho_p95_ms < desenho_p95_ms && por_mil <= atrasados_por_mil + 10.0 {
                    (EscolhaDoAlvo::Decidido { software: true }, TrocaDoAlvo::Nada)
                } else {
                    (EscolhaDoAlvo::Decidido { software: false }, TrocaDoAlvo::ParaPadrao)
                }
            }
            outra => (outra, TrocaDoAlvo::Nada),
        }
    }
}

/// O percentil `p` (0..1) por posição, sem interpolação. Vazio: 0.
pub fn percentil(v: &mut [f32], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    let i = ((v.len() - 1) as f64 * p.clamp(0.0, 1.0)).round() as usize;
    v[i] as f64
}

fn arredondar(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

#[cfg(test)]
mod testes {
    use super::*;

    fn geo(linhas: usize) -> GeometriaDoTexto {
        GeometriaDoTexto::nova(80.0, (0..linhas).map(|i| i * 40).collect(), linhas * 40)
    }

    #[test]
    fn o_percurso_vai_do_centro_da_primeira_ao_centro_da_ultima() {
        let g = geo(11);
        assert_eq!(g.percurso(), 800.0);
        assert_eq!(g.deslocamento_da_posicao(0.5), 400.0);
        assert_eq!(g.posicao_do_deslocamento(400.0), 0.5);
        assert_eq!(g.deslocamento_da_posicao(2.0), 800.0);
        assert_eq!(g.posicao_do_deslocamento(-5.0), 0.0);
        // Uma linha só: percurso zero, a posição não anda.
        let um = geo(1);
        assert_eq!(um.percurso(), 0.0);
        assert_eq!(um.posicao_do_deslocamento(10.0), 0.0);
        assert_eq!(GeometriaDoTexto::vazia().linhas_visiveis(0.0, 100.0, 500.0), 0..0);
    }

    #[test]
    fn o_ponto_de_leitura_sobrevive_ao_layout_novo() {
        // Linhas de 40 caracteres a 80 px; rolado até o meio da linha 5 (um quarto além).
        let antes = geo(20);
        let ponto = antes.ponto_de_leitura(5.25 * 80.0);
        assert_eq!(ponto.0, 200);
        assert!((ponto.1 - 0.25).abs() < 1e-9);
        // Fonte maior: linhas de 20 caracteres a 120 px. O caractere 200 está na linha 10.
        let depois = GeometriaDoTexto::nova(120.0, (0..40).map(|i| i * 20).collect(), 800);
        let d = depois.deslocamento_do_ponto(ponto);
        assert!((d - 10.25 * 120.0).abs() < 1e-9, "{d}");
        // O texto encolheu: o caractere além do fim cai na última linha.
        let curto = geo(3);
        assert_eq!(curto.deslocamento_do_ponto((10_000, 0.0)), curto.percurso());
    }

    #[test]
    fn a_linha_do_caractere_e_a_ultima_que_comeca_antes_dele() {
        let g = geo(5);
        assert_eq!(g.linha_do_caractere(0), 0);
        assert_eq!(g.linha_do_caractere(39), 0);
        assert_eq!(g.linha_do_caractere(40), 1);
        assert_eq!(g.linha_do_caractere(10_000), 4);
    }

    #[test]
    fn so_as_linhas_que_aparecem_sao_desenhadas() {
        let g = geo(1000);
        // Vista de 600 px, linha de leitura a 180 px, no começo: o topo do texto está em 140.
        let r = g.linhas_visiveis(0.0, 180.0, 600.0);
        assert_eq!(r, 0..6);
        // No meio: 400 linhas acima, e o mesmo punhado visível.
        let d = g.deslocamento_da_posicao(0.5);
        let r = g.linhas_visiveis(d, 180.0, 600.0);
        assert!(r.len() <= 9 && r.contains(&g.linha_no_deslocamento(d)), "{r:?}");
    }

    #[test]
    fn a_rolagem_anda_pelo_tempo_e_nao_pelo_quadro() {
        let g = geo(100);
        let mut a = Rolagem::default();
        let mut b = Rolagem::default();
        // 60 quadros de 1/60 s contra 30 de 1/30 s: o mesmo segundo, o mesmo lugar.
        for _ in 0..60 {
            a.avancar(1.0 / 60.0, 2.0, &g);
        }
        for _ in 0..30 {
            b.avancar(1.0 / 30.0, 2.0, &g);
        }
        assert!((a.deslocamento - 160.0).abs() < 1e-6);
        assert!((a.deslocamento - b.deslocamento).abs() < 1e-6);
        // Um quadro de 3 s (o computador acordando) anda no máximo 0,25 s.
        let mut c = Rolagem::default();
        c.avancar(3.0, 1.0, &g);
        assert!((c.deslocamento - 20.0).abs() < 1e-9);
    }

    #[test]
    fn para_tras_anda_na_mesma_velocidade_e_para_no_comeco() {
        let g = geo(100);
        let mut r = Rolagem::default();
        r.ir(400.0, &g);
        // Um segundo para trás, a 2 linhas/s de 80 px: 160 px, o mesmo que para a frente.
        for _ in 0..60 {
            r.recuar(1.0 / 60.0, 2.0, &g);
        }
        assert!((r.deslocamento - 240.0).abs() < 1e-6, "{}", r.deslocamento);
        // Até o começo, e para ali: avisa uma vez, e não passa de 0.
        let mut chegadas = 0;
        for _ in 0..1000 {
            if r.recuar(0.1, 20.0, &g) {
                chegadas += 1;
            }
        }
        assert_eq!(chegadas, 1);
        assert_eq!(r.deslocamento, 0.0);
        assert!(!r.recuar(0.1, 20.0, &g), "parado no começo, nada chega de novo");
    }

    #[test]
    fn a_rolagem_para_no_fim_e_avisa_uma_vez() {
        let g = geo(3);
        let mut r = Rolagem::default();
        let mut chegadas = 0;
        for _ in 0..1000 {
            if r.avancar(0.1, 20.0, &g) {
                chegadas += 1;
            }
        }
        assert_eq!(chegadas, 1);
        assert!(r.no_fim(&g));
        assert_eq!(r.deslocamento, g.percurso());
        r.ir(-10.0, &g);
        assert_eq!(r.deslocamento, 0.0);
        r.ir(f64::NAN, &g);
        assert_eq!(r.deslocamento, 0.0);
    }

    #[test]
    fn a_cadencia_conta_pelo_retraco_quando_ha_dwm() {
        let mut c = Cadencia::nova(1000.0 / 60.0);
        for _ in 0..100 {
            c.quadro(16.7, 2.0, Some(1));
        }
        c.quadro(33.4, 2.0, Some(2));
        c.quadro(50.1, 2.0, Some(3));
        c.quadro(5.0, 1.0, Some(0));
        let r = c.resumo();
        assert_eq!(r.quadros, 103);
        assert_eq!(r.atrasados, 2);
        assert_eq!(r.retracos_perdidos, 3);
        assert_eq!(r.no_mesmo_retraco, 1);
        assert_eq!(r.quadros_contados_pelo_dwm, 103);
        assert_eq!(r.maior_intervalo_ms, 50.1);
    }

    #[test]
    fn sem_dwm_a_cadencia_conta_pelo_intervalo_do_laco() {
        let mut c = Cadencia::nova(1000.0 / 60.0);
        c.quadro(16.0, 1.0, None);
        c.quadro(25.1, 1.0, None);
        c.quadro(24.9, 1.0, None);
        let r = c.resumo();
        assert_eq!(r.atrasados, 1);
        assert_eq!(r.quadros_contados_pelo_dwm, 0);
    }

    #[test]
    fn o_percentil_e_por_posicao() {
        let mut v: Vec<f32> = (1..=100).map(|x| x as f32).collect();
        assert_eq!(percentil(&mut v, 0.5), 51.0);
        assert_eq!(percentil(&mut v, 0.99), 99.0);
        assert_eq!(percentil(&mut [], 0.5), 0.0);
    }

    #[test]
    fn a_seta_leva_o_texto_suave_e_segurada_anda_em_velocidade_constante() {
        let g = geo(100); // linhas de 80 px
        let mut r = Rolagem::default();
        r.ir(400.0, &g);
        // Um toque: uma linha adiante, sem pulo (nenhum quadro anda mais que metade do caminho).
        let d = Deslize::empurrar(None, r.deslocamento, 80.0, false, &g);
        assert_eq!(d.alvo, 480.0);
        let mut antes = r.deslocamento;
        let mut quadros = 0;
        while !d.passo(&mut r, 1.0 / 60.0, &g) {
            assert!(r.deslocamento - antes < 40.0 && r.deslocamento > antes, "anda sempre, e pouco por quadro");
            antes = r.deslocamento;
            quadros += 1;
            assert!(quadros < 120, "chega em menos de 2 s");
        }
        assert_eq!(r.deslocamento, 480.0);
        // Toques rápidos somam: dois para trás antes de chegar = duas linhas.
        let d1 = Deslize::empurrar(None, r.deslocamento, -80.0, false, &g);
        let d2 = Deslize::empurrar(Some(d1), r.deslocamento, -80.0, false, &g);
        assert_eq!(d2.alvo, 320.0);
        // Segurada: o alvo nunca passa de um passo à frente do texto, por mais repetições que cheguem.
        let mut s = Deslize::empurrar(None, 400.0, 80.0, false, &g);
        for _ in 0..30 {
            s = Deslize::empurrar(Some(s), 400.0, 80.0, true, &g);
        }
        assert_eq!(s.alvo, 480.0);
        let mut v = Deslize::empurrar(None, 400.0, -80.0, false, &g);
        for _ in 0..30 {
            v = Deslize::empurrar(Some(v), 400.0, -80.0, true, &g);
        }
        assert_eq!(v.alvo, 320.0);
        // Preso ao percurso nas duas pontas.
        assert_eq!(Deslize::empurrar(None, 10.0, -80.0, false, &g).alvo, 0.0);
        assert_eq!(Deslize::empurrar(None, g.percurso(), 80.0, false, &g).alvo, g.percurso());
        // Rolando, o alvo acompanha o texto.
        let mut a = Deslize { alvo: 500.0 };
        a.acompanhar(3.0, &g);
        assert_eq!(a.alvo, 503.0);
    }

    #[test]
    fn a_janela_da_rolagem_resume_e_zera() {
        let mut j = JanelaDaRolagem::nova(1000.0 / 60.0);
        assert!(j.fechar().is_none(), "sem quadro, sem linha");
        // 99 quadros lisos de 1 retraço e um soco de 3 retraços: o passo dele é o triplo.
        for _ in 0..99 {
            j.quadro(16.7, 2.0, 1.5, Some(1));
        }
        j.quadro(50.1, 6.0, 9.0, Some(3));
        j.disposicoes = 10;
        j.pinturas = 10;
        j.pinturas_com_texto = 10;
        let r = j.fechar().expect("houve quadros");
        assert_eq!(r.quadros, 100);
        assert_eq!(r.atrasados, 1);
        assert_eq!(r.retracos_perdidos, 2);
        assert_eq!(r.intervalo_p50_ms, 16.7);
        assert_eq!(r.intervalo_max_ms, 50.1);
        assert_eq!(r.passo_p50_px, 2.0);
        assert_eq!(r.passo_max_px, 6.0);
        assert_eq!(r.desenho_max_ms, 9.0);
        assert_eq!(r.disposicoes, 10);
        let linha = r.linha("r5", "padrão", 10.0);
        assert!(linha.contains("rolagem (r5, 10.0 s): quadros=100 atrasados=1"), "{linha}");
        assert!(linha.contains("passo p50=2.00 p95=2.00 max=6.00 px"), "{linha}");
        assert!(linha.contains("disposicoes=10 pinturas=10 (com o texto 10)"), "{linha}");
        // Zerada, com o período.
        assert_eq!(j.quadros(), 0);
        assert_eq!(j.periodo_ms, 1000.0 / 60.0);
        assert_eq!(j.disposicoes, 0);
        // Sem DWM: atrasado é o intervalo acima de 1,5 período.
        j.quadro(30.0, 1.0, 1.0, None);
        j.quadro(16.0, 1.0, 1.0, None);
        assert_eq!(j.fechar().unwrap().atrasados, 1);
    }

    fn resumo(quadros: u64, atrasados: u64, desenho_p95_ms: f64) -> ResumoDaJanela {
        ResumoDaJanela { quadros, atrasados, desenho_p95_ms, ..ResumoDaJanela::default() }
    }

    #[test]
    fn o_alvo_so_troca_quando_o_desenho_pesa_e_fica_o_que_mediu_melhor() {
        let p = 1000.0 / 60.0;
        // Barato: nunca troca, mesmo com quadros atrasados (a causa não é o desenho).
        assert_eq!(EscolhaDoAlvo::Padrao.depois(&resumo(600, 60, 3.0), p), (EscolhaDoAlvo::Padrao, TrocaDoAlvo::Nada));
        // Poucos quadros não decidem.
        assert_eq!(EscolhaDoAlvo::Padrao.depois(&resumo(50, 0, 15.0), p), (EscolhaDoAlvo::Padrao, TrocaDoAlvo::Nada));
        // Caro: prova o software.
        let (e, t) = EscolhaDoAlvo::Padrao.depois(&resumo(600, 30, 9.0), p);
        assert_eq!(t, TrocaDoAlvo::ParaSoftware);
        assert_eq!(e, EscolhaDoAlvo::ProvandoSoftware { desenho_p95_ms: 9.0, atrasados_por_mil: 50.0 });
        // O software desenhou melhor: fica, e não muda mais.
        let (d, t2) = e.depois(&resumo(600, 6, 4.0), p);
        assert_eq!((d, t2), (EscolhaDoAlvo::Decidido { software: true }, TrocaDoAlvo::Nada));
        assert_eq!(d.depois(&resumo(600, 300, 16.0), p), (d, TrocaDoAlvo::Nada));
        // O software desenhou pior (ou atrasou mais): volta ao padrão, decidido.
        assert_eq!(
            e.depois(&resumo(600, 6, 12.0), p),
            (EscolhaDoAlvo::Decidido { software: false }, TrocaDoAlvo::ParaPadrao)
        );
        assert_eq!(
            e.depois(&resumo(600, 120, 4.0), p),
            (EscolhaDoAlvo::Decidido { software: false }, TrocaDoAlvo::ParaPadrao)
        );
        // A janela de prova curta (a pessoa pausou) espera a próxima.
        assert_eq!(e.depois(&resumo(10, 0, 1.0), p), (e, TrocaDoAlvo::Nada));
    }
}
