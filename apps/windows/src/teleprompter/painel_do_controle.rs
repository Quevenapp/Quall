//! **O painel do controle do teleprompter** ("Controlar um teleprompter" e o painel conectado), em
//! valores: onde fica cada controle nativo e o que se pinta em volta, em unidades de 96 dpi (DIP),
//! para uma janela de qualquer largura. Sem Win32: os testes rodam em qualquer máquina.
//!
//! # Por que existe (o relato de 12/10)
//!
//! A tela do controle no Windows saía **branca, menor, com textos uns por cima dos outros e o último
//! botão fora da janela**. As posições eram y fixos em DIP (`tela.rs`, `posicionar` e
//! `pintar_formulario`/`pintar_controle`), casados à mão entre quem põe os controles e quem pinta:
//! uma frase que quebrava em duas linhas (o inglês, o aviso de conexão, a fonte maior) caía em cima
//! da seguinte, e nada rolava quando a janela era mais baixa que 660 DIP — o caso do monitor a
//! 150 %, onde a janela inteira não cabe na área de trabalho.
//!
//! Aqui a disposição **corre de cima para baixo**: cada bloco mede a própria altura (as frases pela
//! largura estimada de `estilo::largura_estimada`, com folga; os botões em fila, que quebram de
//! linha quando não cabem) e o seguinte começa depois dele. O resultado tem a altura total do
//! conteúdo: quando ela passa da janela, a janela rola ([`rolagem_maxima`]). Os mesmos retângulos
//! servem a quem põe os controles no lugar e a quem pinta — a regra da tabela única de
//! `telas-estudio.md` §11.5, para uma janela que muda de tamanho.
//!
//! As frases chegam **já traduzidas** (quem chama usa `idioma::t`): este módulo não tem texto de
//! interface próprio.
//!
//! # O visual
//!
//! O do "Estúdio de bolso" (§2–§4): fundo `fundo`, título de tela, rótulos de seção em caixa alta,
//! campos e cartões de `superficie` com contorno, aviso âmbar, botão principal violeta. Os botões
//! são `BUTTON`s nativos desenhados no `NM_CUSTOMDRAW` pelas peças de `estilo.rs` ([`aparencia`]).

use crate::estilo::{
    self, aviso, botao, caixa, campo, cartao, rotulo, texto, Cor, Fonte, Item, Ret, TipoDeBotao, Tom, ACENTO, AGUARDANDO_TEXTO,
    CONECTADO, CONECTADO_TEXTO, F_BOTAO, F_BOTAO_PEQUENO, F_CORPO, F_LEGENDA, F_LEGENDA_13, F_MONO_12, F_ROTULO, F_TITULO,
    FUNDO, NO_AR, SUPERFICIE_ALTA, TEXTO, TEXTO2, TEXTO3,
};

// =============================================================================================
// As medidas
// =============================================================================================

/// As margens do painel (dos lados, em cima e embaixo).
pub const MARGEM: f32 = 28.0;
pub const TOPO: f32 = 24.0;
pub const PE: f32 = 24.0;
/// Numa janela larga o conteúdo não estica além disto (as frases ficam legíveis, os botões juntos).
pub const LARGURA_MAXIMA_DO_CONTEUDO: f32 = 760.0;
/// O tamanho que a janela do controle pede ao abrir (a área de cliente), se a tela tiver lugar.
pub const LARGURA_PADRAO: f32 = 900.0;
pub const ALTURA_PADRAO: f32 = 660.0;
/// **O mínimo da janela** (a área de cliente): abaixo disto o Windows não deixa encolher — a não
/// ser que a área de trabalho seja menor ([`minimo_que_cabe`]). As telas do controle que não rolam
/// (a lista de roteiros guardados, a pergunta do texto, o modo segurar) cabem nele.
pub const LARGURA_MINIMA: f32 = 640.0;
pub const ALTURA_MINIMA: f32 = 480.0;
/// A altura da lista de prompters (três linhas e meia; ela rola dentro dela).
pub const ALTURA_DA_LISTA: f32 = 112.0;
/// O botão de uma ação da tela (Conectar, Editar…) e o de um comando (Vel +, Margem −…).
pub const ALTURA_DO_BOTAO: f32 = estilo::ALTURA_DO_BOTAO;
pub const ALTURA_DO_COMANDO: f32 = 36.0;
/// O vão entre botões da mesma fila, e entre filas.
pub const VAO: f32 = 8.0;
/// O campo do PIN, ao lado do endereço quando cabe.
pub const LARGURA_DO_PIN: f32 = 160.0;
pub const LARGURA_DO_ENDERECO: f32 = 460.0;
/// Quantas linhas a prévia do roteiro mostra, no máximo.
pub const LINHAS_DA_PREVIA: f32 = 3.0;
/// Uma volta da roda do mouse (120 unidades) rola isto.
pub const PASSO_DA_RODA: f32 = 48.0;

// =============================================================================================
// As cores em `COLORREF` (o GDI das telas que ainda pintam pelo GDI)
// =============================================================================================

/// O `COLORREF` (`0x00BBGGRR`) de uma cor, em `const` (o `Cor::colorref` de `estilo.rs` não é).
pub const fn bgr(c: Cor) -> u32 {
    (c.b as u32) << 16 | (c.g as u32) << 8 | c.r as u32
}

/// O fundo de toda a janela fora do prompter: o `fundo` do §2 (antes, branco).
pub const FUNDO_DO_PAINEL: u32 = bgr(FUNDO);
/// O fundo dos campos e da lista: a `superficie`.
pub const FUNDO_DO_CAMPO: u32 = bgr(estilo::SUPERFICIE);
pub const TINTA: u32 = bgr(TEXTO);
pub const TINTA_FRACA: u32 = bgr(TEXTO2);
/// O violeta claro, para texto e rótulo sobre o escuro.
pub const ACENTO_TEXTO: u32 = bgr(estilo::ACENTO_CLARO);
/// O violeta cheio, para fundo (a barra do progresso, o botão do "segurar" rolando).
pub const ACENTO_CHEIO: u32 = bgr(ACENTO);
/// O traço e o fundo apagado (a moldura das caixas da pergunta, o botão desligado).
pub const RISCO: u32 = bgr(SUPERFICIE_ALTA);
/// Aviso âmbar em texto sobre o escuro.
pub const AVISO_TEXTO: u32 = bgr(AGUARDANDO_TEXTO);
/// "Atualize o app do prompter" (o vermelho do perigo, legível no escuro).
pub const PERIGO_TEXTO: u32 = bgr(estilo::PERIGO_TEXTO);

// =============================================================================================
// O que a tela mostra
// =============================================================================================

/// Os controles nativos que o painel põe no lugar. `Comando(id)` é um dos comandos da barra
/// (`tela.rs::COMANDOS`), pelo id dele.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Controle {
    Lista,
    Endereco,
    Pin,
    Conectar,
    Voltar,
    Roteiros,
    EditarRoteiro,
    Sair,
    Segurar,
    GravarRemoto,
    /// "Ajustes da câmera do prompter" (R9b pelo canal do teleprompter, §17 do contrato da câmera).
    CameraDoPrompter,
    /// **"Procurar de novo"** na lista de prompters (`docs/v3-no-privado.md` §8.9).
    ProcurarDeNovo,
    Comando(usize),
}

/// Um botão: quem é, o rótulo de agora (já no idioma) e se é o principal da tela (violeta).
#[derive(Clone, Debug, PartialEq)]
pub struct Botao {
    pub controle: Controle,
    pub rotulo: String,
    pub principal: bool,
}

impl Botao {
    pub fn novo(controle: Controle, rotulo: impl Into<String>) -> Botao {
        Botao { controle, rotulo: rotulo.into(), principal: false }
    }
    pub fn principal(controle: Controle, rotulo: impl Into<String>) -> Botao {
        Botao { controle, rotulo: rotulo.into(), principal: true }
    }
}

/// O bloco "Roteiro" (os dois estados têm): o rótulo, a linha do tamanho e do que acontece com
/// ele, a prévia das primeiras linhas e o botão do editor.
#[derive(Clone, Debug, PartialEq)]
pub struct BlocoDoRoteiro {
    pub rotulo: String,
    pub info: String,
    pub previa: String,
    /// Sem roteiro: a prévia é a frase "Sem roteiro.", em cor apagada.
    pub previa_vazia: bool,
    pub botao: String,
}

/// **Sem conexão**: o formulário.
#[derive(Clone, Debug, PartialEq)]
pub struct Formulario {
    pub titulo: String,
    pub subtitulo: String,
    pub rotulo_da_lista: String,
    /// O rótulo do "Procurar de novo", à direita do rótulo da lista.
    pub procurar_de_novo: String,
    pub cabecalho_da_lista: String,
    pub rotulo_do_endereco: String,
    pub rotulo_do_pin: String,
    pub ajuda_do_pin: String,
    /// A mensagem da última tentativa (vazia: nenhuma), num aviso âmbar.
    pub mensagem: String,
    /// Conectar (o principal), Voltar e "Roteiros guardados", nessa ordem.
    pub botoes: Vec<Botao>,
    pub roteiro: BlocoDoRoteiro,
}

/// **O código do toque** (`docs/v3-no-privado.md` §8.6), o cartão do convidado do Exibir: o prompter
/// mostra três números, e a pessoa toca lá neste.
#[derive(Clone, Debug, PartialEq)]
pub struct CodigoNoControle {
    /// "O pareamento anterior não vale mais…", quando o toque tentou reconectar e o prompter não
    /// reconheceu.
    pub aviso: Option<String>,
    pub titulo: String,
    /// Os quatro dígitos.
    pub codigo: String,
    pub linha: String,
}

/// **Conectado** (ou tentando de novo): o painel de comandar.
#[derive(Clone, Debug, PartialEq)]
pub struct Conectado {
    pub titulo: String,
    /// O código do toque, enquanto o prompter espera a escolha (só na primeira entrada).
    pub codigo: Option<CodigoNoControle>,
    /// O "Desconectar", no alto à direita.
    pub sair: String,
    /// A conexão de pé e tudo confirmado: a bolinha verde.
    pub tudo_certo: bool,
    /// Os avisos, um por caixa (vazio: a linha de `confirmado`).
    pub avisos: Vec<String>,
    pub confirmado: String,
    /// A posição que o prompter relata, de 0 a 1.
    pub posicao: f64,
    pub legenda_da_posicao: String,
    pub valores: String,
    pub resumo: String,
    /// A linha da gravação do prompter (§13.8) e se ele está gravando (vermelho).
    pub gravacao: Option<(String, bool)>,
    /// Os botões em grupos; cada grupo começa numa fila nova e quebra quando não cabe.
    pub grupos: Vec<Vec<Botao>>,
    pub teclado: String,
    pub roteiro: BlocoDoRoteiro,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Tela {
    Formulario(Formulario),
    Conectado(Conectado),
}

/// **O resultado da disposição**: o retângulo de cada controle, o que se pinta, as "folhas" (cada
/// texto e cada controle, os que não podem se cruzar) e a altura total do conteúdo. Tudo já com a
/// rolagem aplicada.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Lugares {
    pub controles: Vec<(Controle, Ret)>,
    pub itens: Vec<Item>,
    pub folhas: Vec<(String, Ret)>,
    /// A altura do conteúdo inteiro (sem a rolagem).
    pub altura: f32,
}

impl Lugares {
    pub fn de(&self, c: Controle) -> Option<Ret> {
        self.controles.iter().find(|(x, _)| *x == c).map(|(_, r)| *r)
    }
}

// =============================================================================================
// As contas
// =============================================================================================

/// A altura de uma linha de texto na fonte `f`.
pub fn altura_da_linha(f: Fonte) -> f32 {
    (f.tamanho * 1.4).ceil()
}

/// **Quantas linhas** uma frase ocupa na largura `l`, pela estimativa de `estilo.rs` com 15 % de
/// folga (a quebra por palavra desperdiça o fim de cada linha). Vazia: zero.
pub fn linhas(s: &str, f: Fonte, l: f32) -> f32 {
    if s.trim().is_empty() {
        return 0.0;
    }
    let total: f32 = s.split('\n').map(|p| ((estilo::largura_estimada(p, f) * 1.15) / l.max(1.0)).ceil().max(1.0)).sum();
    total.max(1.0)
}

/// A altura de uma frase quebrada em linhas na largura `l`.
pub fn altura_do_texto(s: &str, f: Fonte, l: f32) -> f32 {
    linhas(s, f, l) * altura_da_linha(f)
}

/// A altura de um aviso (o do §4: 10 em cima e embaixo, texto de 13 a 40 da borda esquerda e 12 da
/// direita).
pub fn altura_do_aviso(s: &str, l: f32) -> f32 {
    20.0 + linhas(s, F_LEGENDA_13, (l - 52.0).max(1.0)) * 18.0
}

/// A largura de um botão para o rótulo: a estimativa da fonte, 28 de folga, e um mínimo.
pub fn largura_do_botao(rotulo: &str, f: Fonte, minimo: f32) -> f32 {
    (estilo::largura_estimada(rotulo, f) + 28.0).ceil().max(minimo)
}

/// A rolagem máxima: o quanto o conteúdo passa da vista (zero quando cabe).
pub fn rolagem_maxima(altura_do_conteudo: f32, altura_da_vista: f32) -> f32 {
    (altura_do_conteudo - altura_da_vista).max(0.0)
}

/// A rolagem pedida, dentro do que dá.
pub fn limitar_rolagem(r: f32, altura_do_conteudo: f32, altura_da_vista: f32) -> f32 {
    if !r.is_finite() {
        return 0.0;
    }
    r.clamp(0.0, rolagem_maxima(altura_do_conteudo, altura_da_vista))
}

/// A rolagem depois de um giro da roda (`delta` em unidades de 120 por volta; positivo = para cima).
pub fn rolagem_da_roda(r: f32, delta: i32, altura_do_conteudo: f32, altura_da_vista: f32) -> f32 {
    limitar_rolagem(r - delta as f32 / 120.0 * PASSO_DA_RODA, altura_do_conteudo, altura_da_vista)
}

/// **A rolagem que mostra `alvo` inteiro** (o controle que ganhou o foco pelo Tab): a de agora se ele
/// já está à vista; senão, a menor mudança que o traz. `alvo` sem a rolagem aplicada.
pub fn rolagem_para_ver(r: f32, alvo: Ret, altura_do_conteudo: f32, altura_da_vista: f32) -> f32 {
    let mut n = r;
    if alvo.baixo() + 8.0 > n + altura_da_vista {
        n = alvo.baixo() + 8.0 - altura_da_vista;
    }
    if alvo.y - 8.0 < n {
        n = alvo.y - 8.0;
    }
    limitar_rolagem(n, altura_do_conteudo, altura_da_vista)
}

/// **O tamanho da área de cliente que cabe na tela**: o pedido, ou o que a área de trabalho deixa
/// (descontada a moldura). Tudo em DIP do monitor onde a janela nasce.
pub fn cliente_que_cabe(pedido: (f32, f32), trabalho: (f32, f32), moldura: (f32, f32)) -> (f32, f32) {
    let livre = ((trabalho.0 - moldura.0).max(200.0), (trabalho.1 - moldura.1).max(160.0));
    (pedido.0.min(livre.0), pedido.1.min(livre.1))
}

/// **O mínimo que a janela aceita**: o [`LARGURA_MINIMA`] × [`ALTURA_MINIMA`], ou menos se a área de
/// trabalho for menor (uma janela mínima maior que a tela teria o pé fora dela para sempre).
pub fn minimo_que_cabe(trabalho: (f32, f32), moldura: (f32, f32)) -> (f32, f32) {
    cliente_que_cabe((LARGURA_MINIMA, ALTURA_MINIMA), trabalho, moldura)
}

/// A coluna do conteúdo numa janela de `largura` DIP: a margem, e no máximo
/// [`LARGURA_MAXIMA_DO_CONTEUDO`].
pub fn coluna(largura: f32) -> (f32, f32) {
    let l = (largura - 2.0 * MARGEM).clamp(120.0, LARGURA_MAXIMA_DO_CONTEUDO);
    (MARGEM, l)
}

/// O cursor da disposição: o y de agora (com a rolagem) e o que já foi posto.
struct Pilha {
    x: f32,
    l: f32,
    y: f32,
    rolagem: f32,
    saida: Lugares,
}

impl Pilha {
    fn texto(&mut self, nome: &str, s: &str, f: Fonte, cor: Cor) {
        let a = altura_do_texto(s, f, self.l);
        if a <= 0.0 {
            return;
        }
        let r = Ret::new(self.x, self.y, self.l, a);
        self.saida.itens.push(texto(r, s, f, cor).quebra().item());
        self.saida.folhas.push((nome.into(), r));
        self.y += a;
    }

    fn rotulo(&mut self, nome: &str, s: &str) {
        // O rótulo de seção é caixa alta e espaçado: a estimativa é sobre a frase como ela sai.
        let a = altura_do_texto(&estilo::caixa_alta(s), F_ROTULO, self.l).max(18.0);
        let r = Ret::new(self.x, self.y, self.l, a);
        let mut item = rotulo(r, s);
        if let Item::Texto(t) = &mut item {
            t.quebra = true;
            t.meio = false;
        }
        self.saida.itens.push(item);
        self.saida.folhas.push((nome.into(), r));
        self.y += a;
    }

    fn aviso(&mut self, nome: &str, s: &str, tom: Tom) {
        let a = altura_do_aviso(s, self.l);
        let r = Ret::new(self.x, self.y, self.l, a);
        self.saida.itens.extend(aviso(r, tom, s));
        self.saida.folhas.push((nome.into(), r));
        self.y += a;
    }

    fn controle(&mut self, c: Controle, r: Ret) {
        self.saida.controles.push((c, r));
        self.saida.folhas.push((format!("{c:?}"), r));
    }

    /// **Uma fila de botões que quebra**: da esquerda para a direita, e uma fila nova quando o
    /// próximo não cabe. Um botão mais largo que a coluna fica com a coluna (o rótulo termina em
    /// reticências no desenho).
    fn fila(&mut self, botoes: &[Botao], altura: f32, fonte: Fonte, minimo: f32) {
        if botoes.is_empty() {
            return;
        }
        let mut x = self.x;
        for b in botoes {
            let w = largura_do_botao(&b.rotulo, fonte, minimo).min(self.l);
            if x > self.x && x + w > self.x + self.l {
                x = self.x;
                self.y += altura + VAO;
            }
            self.controle(b.controle, Ret::new(x, self.y, w, altura));
            x += w + VAO;
        }
        self.y += altura;
    }

    /// O cartão "Roteiro".
    fn roteiro(&mut self, b: &BlocoDoRoteiro) {
        const DENTRO: f32 = 16.0;
        let topo = self.y;
        let (x0, l0) = (self.x, self.l);
        let indice = self.saida.itens.len();
        self.x += DENTRO;
        self.l = (self.l - 2.0 * DENTRO).max(1.0);
        self.y += DENTRO;
        self.rotulo("bloco.rotulo", &b.rotulo);
        self.y += 4.0;
        self.texto("bloco.info", &b.info, F_LEGENDA, TEXTO2);
        self.y += 8.0;
        let a = altura_do_texto(&b.previa, F_CORPO, self.l).min(LINHAS_DA_PREVIA * altura_da_linha(F_CORPO));
        if a > 0.0 {
            let r = Ret::new(self.x, self.y, self.l, a);
            self.saida.itens.push(texto(r, &b.previa, F_CORPO, if b.previa_vazia { TEXTO3 } else { TEXTO }).quebra().item());
            self.saida.folhas.push(("bloco.previa".into(), r));
            self.y += a;
        }
        self.y += 12.0;
        let w = largura_do_botao(&b.botao, F_BOTAO, 120.0).min(self.l);
        self.controle(Controle::EditarRoteiro, Ret::new(self.x, self.y, w, ALTURA_DO_BOTAO));
        self.y += ALTURA_DO_BOTAO + DENTRO;
        // O cartão vai por baixo do que está nele.
        self.saida.itens.insert(indice, cartao(Ret::new(x0, topo, l0, self.y - topo)));
        self.x = x0;
        self.l = l0;
    }
}

/// **Dispõe a tela** numa janela de `largura` DIP, com o conteúdo rolado `rolagem` DIP para cima.
pub fn dispor(tela: &Tela, largura: f32, rolagem: f32) -> Lugares {
    let (x, l) = coluna(largura);
    let mut p = Pilha { x, l, y: TOPO - rolagem, rolagem, saida: Lugares::default() };
    match tela {
        Tela::Formulario(f) => formulario(&mut p, f),
        Tela::Conectado(c) => conectado(&mut p, c),
    }
    p.y += PE;
    p.saida.altura = p.y + p.rolagem;
    p.saida
}

fn formulario(p: &mut Pilha, f: &Formulario) {
    p.texto("titulo", &f.titulo, F_TITULO, TEXTO);
    p.y += 4.0;
    p.texto("subtitulo", &f.subtitulo, F_CORPO, TEXTO2);
    p.y += 20.0;
    // "Procurar de novo" (§8.9) na linha do rótulo, encostado à direita.
    let wp = largura_do_botao(&f.procurar_de_novo, F_BOTAO_PEQUENO, 120.0).min(p.l / 2.0);
    let topo = p.y;
    p.controle(Controle::ProcurarDeNovo, Ret::new(p.x + p.l - wp, topo - 5.0, wp, 28.0));
    // O rótulo fica com o que sobra à esquerda do botão, e a linha tem a altura do botão.
    let largura = p.l;
    p.l = largura - wp - 8.0;
    p.rotulo("rotulo.lista", &f.rotulo_da_lista);
    p.l = largura;
    p.y = p.y.max(topo + 23.0);
    p.y += 4.0;
    p.texto("cabecalho.lista", &f.cabecalho_da_lista, F_LEGENDA_13, TEXTO2);
    p.y += 8.0;
    // A lista nativa dentro de um cartão desenhado (a borda é a do cartão, 1 DIP).
    let caixa_da_lista = Ret::new(p.x, p.y, p.l, ALTURA_DA_LISTA);
    p.saida.itens.push(cartao(caixa_da_lista));
    p.controle(Controle::Lista, caixa_da_lista.dentro(2.0, 2.0));
    p.y += ALTURA_DA_LISTA + 18.0;

    // O endereço e o PIN: lado a lado quando cabem, um embaixo do outro quando não.
    let lado_a_lado = p.l >= 280.0 + 16.0 + LARGURA_DO_PIN;
    if lado_a_lado {
        let le = (p.l - 16.0 - LARGURA_DO_PIN).min(LARGURA_DO_ENDERECO);
        let xp = p.x + le + 16.0;
        let ae = altura_do_texto(&estilo::caixa_alta(&f.rotulo_do_endereco), F_ROTULO, le).max(18.0);
        let ap = altura_do_texto(&estilo::caixa_alta(&f.rotulo_do_pin), F_ROTULO, LARGURA_DO_PIN).max(18.0);
        let a = ae.max(ap);
        // Os dois rótulos encostam embaixo, logo acima do campo deles.
        let re = Ret::new(p.x, p.y + a - ae, le, ae);
        let rp = Ret::new(xp, p.y + a - ap, LARGURA_DO_PIN, ap);
        for (nome, r, s) in [("rotulo.endereco", re, &f.rotulo_do_endereco), ("rotulo.pin", rp, &f.rotulo_do_pin)] {
            let mut item = rotulo(r, s);
            if let Item::Texto(t) = &mut item {
                t.quebra = true;
                t.meio = false;
            }
            p.saida.itens.push(item);
            p.saida.folhas.push((nome.into(), r));
        }
        p.y += a + 6.0;
        let ce = Ret::new(p.x, p.y, le, estilo::ALTURA_DO_CAMPO);
        let cp = Ret::new(xp, p.y, LARGURA_DO_PIN, estilo::ALTURA_DO_CAMPO);
        p.saida.itens.extend(campo(ce, false));
        p.saida.itens.extend(campo(cp, false));
        p.controle(Controle::Endereco, estilo::lugar::edit_no_campo(ce));
        p.controle(Controle::Pin, estilo::lugar::edit_no_campo(cp));
        p.y += estilo::ALTURA_DO_CAMPO;
    } else {
        p.rotulo("rotulo.endereco", &f.rotulo_do_endereco);
        p.y += 6.0;
        let ce = Ret::new(p.x, p.y, p.l.min(LARGURA_DO_ENDERECO), estilo::ALTURA_DO_CAMPO);
        p.saida.itens.extend(campo(ce, false));
        p.controle(Controle::Endereco, estilo::lugar::edit_no_campo(ce));
        p.y += estilo::ALTURA_DO_CAMPO + 12.0;
        p.rotulo("rotulo.pin", &f.rotulo_do_pin);
        p.y += 6.0;
        let cp = Ret::new(p.x, p.y, p.l.min(LARGURA_DO_PIN), estilo::ALTURA_DO_CAMPO);
        p.saida.itens.extend(campo(cp, false));
        p.controle(Controle::Pin, estilo::lugar::edit_no_campo(cp));
        p.y += estilo::ALTURA_DO_CAMPO;
    }
    p.y += 6.0;
    p.texto("ajuda.pin", &f.ajuda_do_pin, F_LEGENDA, TEXTO2);
    if !f.mensagem.trim().is_empty() {
        p.y += 12.0;
        p.aviso("mensagem", &f.mensagem, Tom::Ambar);
    }
    p.y += 18.0;
    p.fila(&f.botoes, ALTURA_DO_BOTAO, F_BOTAO, 96.0);
    p.y += 24.0;
    p.roteiro(&f.roteiro);
}

/// O cartão do código do toque: o aviso, a frase, os quatro dígitos nas casas do PIN e a linha de baixo.
fn codigo_no_controle(p: &mut Pilha, k: &CodigoNoControle) {
    const DENTRO: f32 = 16.0;
    let topo = p.y;
    let (x0, l0) = (p.x, p.l);
    let indice = p.saida.itens.len();
    p.x += DENTRO;
    p.l = (p.l - 2.0 * DENTRO).max(1.0);
    p.y += DENTRO;
    if let Some(a) = &k.aviso {
        p.texto("codigo.aviso", a, F_CORPO, TEXTO);
        p.y += 8.0;
    }
    p.texto("codigo.titulo", &k.titulo, estilo::F_TITULO_DE_CARTAO, TEXTO);
    p.y += 10.0;
    let casas = Ret::new(p.x + (p.l - estilo::largura_do_codigo()).max(0.0) / 2.0, p.y, estilo::largura_do_codigo().min(p.l), estilo::CASA_A);
    p.saida.itens.extend(estilo::codigo(p.x + p.l / 2.0, p.y, &k.codigo));
    p.saida.folhas.push(("codigo.digitos".into(), casas));
    p.y += estilo::CASA_A + 10.0;
    p.texto("codigo.linha", &k.linha, F_LEGENDA_13, TEXTO2);
    p.y += DENTRO;
    p.saida.itens.insert(indice, cartao(Ret::new(x0, topo, l0, p.y - topo)));
    p.x = x0;
    p.l = l0;
}

fn conectado(p: &mut Pilha, c: &Conectado) {
    // O alto: a luz do estado, o título e o "Desconectar" à direita, na mesma faixa.
    let ws = largura_do_botao(&c.sair, F_BOTAO, 110.0).min(p.l / 2.0);
    let alto = 40.0;
    let luz = 12.0;
    p.saida.itens.push(estilo::Item::Circulo {
        cx: p.x + luz / 2.0,
        cy: p.y + alto / 2.0,
        raio: luz / 2.0,
        cor: if c.tudo_certo { CONECTADO } else { estilo::AGUARDANDO },
    });
    let rt = Ret::new(p.x + luz + 10.0, p.y, (p.l - luz - 10.0 - ws - 16.0).max(1.0), alto);
    p.saida.itens.push(texto(rt, &c.titulo, F_TITULO, TEXTO).meio().item());
    p.saida.folhas.push(("titulo".into(), rt));
    p.controle(Controle::Sair, Ret::new(p.x + p.l - ws, p.y + (alto - ALTURA_DO_BOTAO) / 2.0, ws, ALTURA_DO_BOTAO));
    p.y += alto + 12.0;

    if let Some(k) = &c.codigo {
        codigo_no_controle(p, k);
        p.y += 16.0;
    }

    if c.avisos.is_empty() {
        p.texto("confirmado", &c.confirmado, F_LEGENDA_13, if c.tudo_certo { CONECTADO_TEXTO } else { TEXTO2 });
    } else {
        for (i, a) in c.avisos.iter().enumerate() {
            if i > 0 {
                p.y += 6.0;
            }
            p.aviso(&format!("aviso.{i}"), a, Tom::Ambar);
        }
    }
    p.y += 16.0;
    // A barra do progresso: a posição que o prompter relata (0,5 é o meio do percurso nele).
    let barra = Ret::new(p.x, p.y, p.l, 8.0);
    p.saida.itens.push(caixa(barra, 4.0, SUPERFICIE_ALTA));
    let cheio = (c.posicao.clamp(0.0, 1.0) as f32 * p.l).max(0.0);
    if cheio > 0.5 {
        p.saida.itens.push(caixa(Ret::new(p.x, p.y, cheio.max(8.0), 8.0), 4.0, ACENTO));
    }
    p.saida.folhas.push(("barra".into(), barra));
    p.y += 8.0 + 8.0;
    p.texto("posicao", &c.legenda_da_posicao, F_LEGENDA_13, TEXTO2);
    p.y += 6.0;
    p.texto("valores", &c.valores, F_LEGENDA_13, TEXTO);
    p.y += 4.0;
    p.texto("resumo", &c.resumo, F_MONO_12, TEXTO3);
    if let Some((linha, gravando)) = &c.gravacao {
        p.y += 6.0;
        p.texto("gravacao", linha, F_LEGENDA_13, if *gravando { NO_AR } else { AGUARDANDO_TEXTO });
    }
    p.y += 18.0;
    for (i, g) in c.grupos.iter().filter(|g| !g.is_empty()).enumerate() {
        if i > 0 {
            p.y += 10.0;
        }
        p.fila(g, ALTURA_DO_COMANDO, F_BOTAO_PEQUENO, 76.0);
    }
    p.y += 16.0;
    p.texto("teclado", &c.teclado, F_LEGENDA, TEXTO3);
    p.y += 20.0;
    p.roteiro(&c.roteiro);
}

// =============================================================================================
// O desenho dos botões (o `NM_CUSTOMDRAW` de `tela.rs`)
// =============================================================================================

/// O estado de um botão nativo no `NM_CUSTOMDRAW`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EstadoDoBotao {
    pub apertado: bool,
    pub foco: bool,
    pub desligado: bool,
    pub quente: bool,
    /// O botão que fica apertado (`BS_PUSHLIKE`), ligado.
    pub marcado: bool,
}

/// Que cara o botão tem: o principal da tela, o de perigo, ou o secundário. Um botão que fica
/// apertado, ligado, vira o principal (o violeta diz "ligado").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Papel {
    Principal,
    Secundario,
    Perigo,
}

/// **O desenho de um botão** no tamanho `l × a` (DIP): as peças de `estilo::botao`, o anel do foco
/// do teclado, e a opacidade do §4 (apertado 90 %, desligado 40 %; o mouse por cima clareia a 94 %
/// o fundo do secundário). Devolve as peças e a opacidade.
pub fn aparencia(papel: Papel, rotulo: &str, l: f32, a: f32, s: EstadoDoBotao) -> (Vec<Item>, f32) {
    let tipo = match papel {
        _ if s.marcado => TipoDeBotao::Principal,
        Papel::Principal => TipoDeBotao::Principal,
        Papel::Secundario | Papel::Perigo => TipoDeBotao::Secundario,
    };
    let fonte = if a < ALTURA_DO_BOTAO { F_BOTAO_PEQUENO } else { F_BOTAO };
    let mut itens = botao(l, a, tipo, rotulo, None, fonte);
    if papel == Papel::Perigo && !s.marcado {
        // As cores do perigo (§4), **sem** o quadradinho de parar do `TipoDeBotao::Perigo`: o
        // "■ Parar a gravação" já o traz no rótulo, o "Apagar" não para nada, e o quadradinho come 22
        // DIP de uma largura medida só para o texto (a revisão de 12/10).
        for item in &mut itens {
            match item {
                Item::Caixa { fundo, .. } => *fundo = estilo::PERIGO_FUNDO,
                Item::Texto(t) => t.cor = estilo::PERIGO_TEXTO,
                _ => {}
            }
        }
    }
    if s.quente && !s.desligado && !s.apertado {
        // O mouse por cima: um véu branco de 6 % sobre o fundo (o jeito do Windows 11).
        itens.insert(1, caixa(Ret::new(0.0, 0.0, l, a), estilo::RAIO_DO_BOTAO, Cor::rgba(0xFFFFFF, 15)));
    }
    if s.foco {
        itens.push(estilo::anel_de_foco(l, a, estilo::RAIO_DO_BOTAO));
    }
    let opacidade = if s.desligado {
        0.4
    } else if s.apertado {
        0.9
    } else {
        1.0
    };
    (itens, opacidade)
}

#[cfg(test)]
mod testes {
    use super::*;

    fn roteiro() -> BlocoDoRoteiro {
        BlocoDoRoteiro {
            rotulo: "Roteiro".into(),
            info: "3 KB de 200 KB · vai ao prompter ao conectar; se ele tiver outro, a tela pergunta qual usar.".into(),
            previa: "Boa noite. Hoje vamos falar de três coisas: a câmera, o som e o roteiro. ".repeat(4),
            previa_vazia: false,
            botao: "Editar ou colar o roteiro".into(),
        }
    }

    fn formulario(mensagem: &str) -> Tela {
        Tela::Formulario(Formulario {
            titulo: "Controlar um teleprompter".into(),
            subtitulo: "Este computador aparece na rede como DESKTOP-G3 de Bruno".into(),
            rotulo_da_lista: "Na rede".into(),
            procurar_de_novo: "Procurar de novo".into(),
            cabecalho_da_lista: "Procurando prompters… (no outro aparelho: Quall → Teleprompter → Mostrar o texto)".into(),
            rotulo_do_endereco: "Não achou? Digite o endereço que o prompter mostra".into(),
            rotulo_do_pin: "PIN".into(),
            ajuda_do_pin: "Deixe vazio se este computador e o prompter já se parearam antes.".into(),
            mensagem: mensagem.into(),
            botoes: vec![
                Botao::principal(Controle::Conectar, "Conectar"),
                Botao::novo(Controle::Voltar, "Voltar"),
                Botao::novo(Controle::Roteiros, "Roteiros guardados"),
            ],
            roteiro: roteiro(),
        })
    }

    fn conectado(avisos: usize, gravacao: bool) -> Tela {
        let comandos = |ids: &[(usize, &str)]| ids.iter().map(|(i, r)| Botao::novo(Controle::Comando(*i), *r)).collect::<Vec<_>>();
        let mut g1 = comandos(&[(220, "Início"), (221, "◀ 5%"), (222, "5% ▶"), (219, "Espelho"), (223, "Editar")]);
        g1.insert(0, Botao::principal(Controle::Comando(210), "Rolar"));
        let g2 = comandos(&[
            (211, "Vel −"),
            (212, "Vel +"),
            (213, "A −"),
            (214, "A +"),
            (215, "Margem −"),
            (216, "Margem +"),
            (217, "Linha ↑"),
            (218, "Linha ↓"),
        ]);
        let mut g3 = vec![Botao::novo(Controle::Segurar, "Segurar para rolar")];
        if gravacao {
            g3.push(Botao::novo(Controle::GravarRemoto, "■ Parar a gravação (00:12)"));
        }
        g3.push(Botao::novo(Controle::Roteiros, "Roteiros guardados"));
        Tela::Conectado(Conectado {
            titulo: "Controlando Galaxy A07 de Bruno".into(),
            codigo: (avisos == 1).then(|| CodigoNoControle {
                aviso: Some("O pareamento anterior não vale mais. Confirme o código para parear de novo.".into()),
                titulo: "Escolha este número no outro aparelho.".into(),
                codigo: "0427".into(),
                linha: "Ele mostra três números; só este é o certo.".into(),
            }),
            sair: "Desconectar".into(),
            tudo_certo: avisos == 0,
            avisos: (0..avisos)
                .map(|i| format!("Aviso {i}: o prompter não responde. Os comandos vão quando a conexão voltar, e isto pode quebrar em duas linhas."))
                .collect(),
            confirmado: "Tudo confirmado pelo prompter.".into(),
            posicao: 0.42,
            legenda_da_posicao: "Posição no prompter: 42 % — rolando".into(),
            valores: "Velocidade 1,50 linha(s)/s  ·  Fonte 64  ·  Margem 10 %  ·  Linha de leitura 35 %  ·  Espelho: não".into(),
            resumo: "Roteiro: resumo 3f9a2c1d8e7b6a5f".into(),
            gravacao: gravacao.then(|| ("● O prompter está gravando há 00:12".to_string(), true)),
            grupos: vec![g1, g2, g3],
            teclado: "Teclado: espaço rola/pausa · ↑↓ move o texto 1 % (segure para andar; segue \"Inverter botões\") · PgUp PgDn 10 % · Shift+↑↓ velocidade · ←→ pular 5 % (Shift = 10 %) · Home começo · M espelho · + − fonte · [ ] margem · , . linha · E editar".into(),
            roteiro: roteiro(),
        })
    }

    /// As telas que os testes passam: o formulário sem e com mensagem; conectado sem aviso, com
    /// três avisos e com a gravação.
    fn telas() -> Vec<(&'static str, Tela)> {
        vec![
            ("formulário", formulario("")),
            ("formulário com mensagem", formulario("Ninguém atendeu neste endereço. Confira se o prompter está aberto e se o endereço e a porta estão certos.")),
            ("conectado", conectado(0, false)),
            ("conectado com avisos e gravação", conectado(3, true)),
            ("conectando com o código do toque", conectado(1, false)),
        ]
    }

    /// Um retângulo em pixels, borda por borda (o mesmo arredondamento de `tela.rs::em_pixels`).
    fn em_pixels(r: Ret, k: f32) -> (i32, i32, i32, i32) {
        ((r.x * k).round() as i32, (r.y * k).round() as i32, ((r.x + r.l) * k).round() as i32, ((r.y + r.a) * k).round() as i32)
    }

    fn cruzam_em_pixels(a: (i32, i32, i32, i32), b: (i32, i32, i32, i32)) -> bool {
        a.0 < b.2 && b.0 < a.2 && a.1 < b.3 && b.1 < a.3
    }

    /// **Nada se cruza**, em DIP e em pixels na escala `k`, e tudo fica dentro da coluna.
    fn conferir(nome: &str, l: &Lugares, largura: f32, k: f32) {
        for (i, (na, a)) in l.folhas.iter().enumerate() {
            assert!(a.l > 0.0 && a.a > 0.0, "{nome}: {na} vazio: {a:?}");
            assert!(a.x >= MARGEM - 0.01 && a.direita() <= largura - MARGEM + 0.01, "{nome} (largura {largura}): {na} sai da coluna: {a:?}");
            for (nb, b) in &l.folhas[i + 1..] {
                assert!(!a.cruza(b), "{nome} (largura {largura}): {na} {a:?} cruza {nb} {b:?}");
                assert!(!cruzam_em_pixels(em_pixels(*a, k), em_pixels(*b, k)), "{nome} a {k}x: {na} cruza {nb} em pixels");
            }
        }
    }

    /// As três escalas do Windows e as telas da bancada: 1920 × 1080 (o Dell) e 1366 × 768 (o
    /// notebook comum), com a barra de tarefas de 48 px. A moldura da janela, em DIP: 16 × 39.
    const ESCALAS: [f32; 3] = [1.0, 1.25, 1.5];
    const TELAS_PX: [(f32, f32); 2] = [(1920.0, 1080.0), (1366.0, 768.0)];
    const MOLDURA: (f32, f32) = (16.0, 39.0);

    fn trabalho(tela: (f32, f32), k: f32) -> (f32, f32) {
        (tela.0 / k, (tela.1 - 48.0) / k)
    }

    #[test]
    fn nada_se_cruza_nas_tres_escalas_na_janela_padrao_e_na_minima() {
        for (nome, t) in telas() {
            for k in ESCALAS {
                for tela in TELAS_PX {
                    let (w, h) = cliente_que_cabe((LARGURA_PADRAO, ALTURA_PADRAO), trabalho(tela, k), MOLDURA);
                    let (mw, mh) = minimo_que_cabe(trabalho(tela, k), MOLDURA);
                    for (largura, altura) in [(w, h), (mw, mh)] {
                        let l0 = dispor(&t, largura, 0.0);
                        conferir(nome, &l0, largura, k);
                        let max = rolagem_maxima(l0.altura, altura);
                        conferir(nome, &dispor(&t, largura, max), largura, k);
                    }
                }
            }
        }
    }

    #[test]
    fn nada_se_cruza_em_qualquer_largura() {
        // Do mínimo forçado por uma tela pequena até uma janela maximizada num monitor largo.
        for (nome, t) in telas() {
            let mut largura = 260.0;
            while largura <= 2600.0 {
                conferir(nome, &dispor(&t, largura, 0.0), largura, 1.0);
                largura += 37.0;
            }
        }
    }

    #[test]
    fn o_ultimo_botao_fica_a_vista_ou_alcancavel_pela_rolagem() {
        for (nome, t) in telas() {
            for k in ESCALAS {
                for tela in TELAS_PX {
                    let tamanhos = [
                        cliente_que_cabe((LARGURA_PADRAO, ALTURA_PADRAO), trabalho(tela, k), MOLDURA),
                        minimo_que_cabe(trabalho(tela, k), MOLDURA),
                        // Uma janela pequena de verdade (a tela de 1366 × 768 a 150 %, sem a moldura).
                        (420.0, 300.0),
                    ];
                    for (largura, altura) in tamanhos {
                        let l0 = dispor(&t, largura, 0.0);
                        // O último controle de cima para baixo é o do roteiro.
                        let ultimo = l0.controles.iter().map(|(_, r)| *r).fold(Ret::default(), |m, r| if r.baixo() > m.baixo() { r } else { m });
                        assert_eq!(l0.de(Controle::EditarRoteiro), Some(ultimo), "{nome}: o último é o do roteiro");
                        assert!(ultimo.baixo() <= l0.altura, "{nome}: o conteúdo mede até o último botão");
                        let max = rolagem_maxima(l0.altura, altura);
                        let lr = dispor(&t, largura, max);
                        let u = lr.de(Controle::EditarRoteiro).unwrap();
                        assert!(u.y >= 0.0 && u.baixo() <= altura, "{nome} a {k}x em {largura}×{altura}: o último botão {u:?} fora da vista rolada ao fim");
                        // Sem rolagem, todos os controles começam abaixo do topo.
                        assert!(l0.controles.iter().all(|(_, r)| r.y >= TOPO - 0.01), "{nome}: um controle acima do topo");
                        if max == 0.0 {
                            assert!(ultimo.baixo() <= altura, "{nome}: cabe e não rola, então o último está à vista");
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_janela_padrao_cabe_na_tela_a_150_por_cento() {
        // O relato: no Dell a 150 % (1920 × 1080, 1032 px úteis = 688 DIP) a janela de 660 DIP + a
        // moldura passava da área de trabalho e o pé ficava fora da tela.
        let t = trabalho((1920.0, 1080.0), 1.5);
        let (w, h) = cliente_que_cabe((LARGURA_PADRAO, ALTURA_PADRAO), t, MOLDURA);
        assert!(h + MOLDURA.1 <= t.1 && w + MOLDURA.0 <= t.0, "{w}×{h} em {t:?}");
        assert_eq!(w, LARGURA_PADRAO);
        // A 100 % cabe inteira.
        assert_eq!(cliente_que_cabe((LARGURA_PADRAO, ALTURA_PADRAO), trabalho((1920.0, 1080.0), 1.0), MOLDURA), (LARGURA_PADRAO, ALTURA_PADRAO));
        // O mínimo nunca passa da tela.
        let m = minimo_que_cabe(trabalho((1366.0, 768.0), 1.5), MOLDURA);
        assert!(m.1 + MOLDURA.1 <= trabalho((1366.0, 768.0), 1.5).1);
        assert_eq!(minimo_que_cabe(trabalho((1920.0, 1080.0), 1.0), MOLDURA), (LARGURA_MINIMA, ALTURA_MINIMA));
    }

    #[test]
    fn a_rolagem_fica_dentro_do_que_da() {
        assert_eq!(rolagem_maxima(500.0, 600.0), 0.0);
        assert_eq!(rolagem_maxima(900.0, 600.0), 300.0);
        assert_eq!(limitar_rolagem(-5.0, 900.0, 600.0), 0.0);
        assert_eq!(limitar_rolagem(1e9, 900.0, 600.0), 300.0);
        assert_eq!(limitar_rolagem(f32::NAN, 900.0, 600.0), 0.0);
        // A roda: para baixo (delta negativo) desce o conteúdo.
        assert_eq!(rolagem_da_roda(0.0, -120, 900.0, 600.0), PASSO_DA_RODA);
        assert_eq!(rolagem_da_roda(0.0, 120, 900.0, 600.0), 0.0);
        assert_eq!(rolagem_da_roda(290.0, -240, 900.0, 600.0), 300.0);
        // O foco num botão abaixo da vista traz o botão; um já à vista não mexe.
        let alvo = Ret::new(28.0, 700.0, 100.0, 40.0);
        assert_eq!(rolagem_para_ver(0.0, alvo, 900.0, 600.0), 148.0);
        assert_eq!(rolagem_para_ver(200.0, alvo, 900.0, 600.0), 200.0);
        assert_eq!(rolagem_para_ver(200.0, Ret::new(28.0, 100.0, 100.0, 40.0), 900.0, 600.0), 92.0);
    }

    #[test]
    fn as_frases_longas_ganham_linhas_e_empurram_o_resto() {
        let curta = dispor(&formulario(""), 700.0, 0.0);
        let longa = dispor(&formulario(&"Uma mensagem bem comprida de conexão. ".repeat(8)), 700.0, 0.0);
        let y = |l: &Lugares| l.de(Controle::Conectar).unwrap().y;
        assert!(y(&longa) > y(&curta) + 40.0, "o aviso empurra o Conectar para baixo");
        // Estreita, a mesma tela fica mais alta (as frases quebram mais).
        assert!(dispor(&formulario(""), 360.0, 0.0).altura > curta.altura);
        assert_eq!(linhas("", F_CORPO, 100.0), 0.0);
        assert!(linhas("a\nb", F_CORPO, 1000.0) >= 2.0);
    }

    #[test]
    fn a_fila_quebra_e_a_rolagem_desloca_tudo_junto() {
        let t = conectado(0, true);
        let larga = dispor(&t, 900.0, 0.0);
        let estreita = dispor(&t, 400.0, 0.0);
        let filas = |l: &Lugares| {
            let mut ys: Vec<i32> = l.controles.iter().filter(|(c, _)| matches!(c, Controle::Comando(_))).map(|(_, r)| r.y as i32).collect();
            ys.dedup();
            ys.len()
        };
        assert!(filas(&estreita) > filas(&larga), "estreita, os comandos quebram em mais filas");
        let rolada = dispor(&t, 900.0, 100.0);
        for ((c0, r0), (c1, r1)) in larga.controles.iter().zip(&rolada.controles) {
            assert_eq!(c0, c1);
            assert!((r0.y - 100.0 - r1.y).abs() < 0.01 && r0.x == r1.x);
        }
        assert_eq!(larga.altura, rolada.altura, "a altura do conteúdo não depende da rolagem");
    }

    #[test]
    fn o_conteudo_nao_estica_numa_janela_larga() {
        let l = dispor(&formulario(""), 2400.0, 0.0);
        assert!(l.folhas.iter().all(|(_, r)| r.direita() <= MARGEM + LARGURA_MAXIMA_DO_CONTEUDO + 0.01));
    }

    #[test]
    fn as_cores_sao_os_tokens_do_estudio() {
        assert_eq!(FUNDO_DO_PAINEL, estilo::FUNDO.colorref());
        assert_eq!(FUNDO_DO_CAMPO, estilo::SUPERFICIE.colorref());
        assert_eq!(TINTA, estilo::TEXTO.colorref());
        assert_eq!(TINTA_FRACA, estilo::TEXTO2.colorref());
        assert_eq!(ACENTO_CHEIO, estilo::ACENTO.colorref());
        assert_eq!(ACENTO_TEXTO, estilo::ACENTO_CLARO.colorref());
        assert_ne!(FUNDO_DO_PAINEL, 0x00FF_FFFF, "nunca mais branco");
    }

    #[test]
    fn o_botao_ligado_e_o_principal_e_o_desligado_apaga() {
        let (itens, o) = aparencia(Papel::Secundario, "Inverter botões", 130.0, 36.0, EstadoDoBotao { marcado: true, ..Default::default() });
        assert_eq!(o, 1.0);
        assert!(matches!(&itens[0], Item::Caixa { fundo, .. } if *fundo == ACENTO));
        let (_, o) = aparencia(Papel::Principal, "Conectar", 130.0, 40.0, EstadoDoBotao { desligado: true, ..Default::default() });
        assert_eq!(o, 0.4);
        let (itens, _) = aparencia(Papel::Perigo, "■ Parar a gravação (00:12)", 220.0, 36.0, EstadoDoBotao::default());
        assert!(matches!(&itens[0], Item::Caixa { fundo, .. } if *fundo == estilo::PERIGO_FUNDO));
        assert_eq!(itens.len(), 2, "o fundo e o rótulo, sem o quadradinho de parar desenhado");
        let (itens, _) = aparencia(Papel::Secundario, "Voltar", 100.0, 40.0, EstadoDoBotao { foco: true, ..Default::default() });
        assert!(matches!(itens.last(), Some(Item::Caixa { borda: Some(_), .. })), "o anel do foco por cima");
    }
}
