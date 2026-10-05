// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
//! A bancada do teleprompter (F6a): **só mensagens, nenhum vídeo**.
//!
//! ```text
//! quall-probe teleprompter --pin 424242 --porta 7979 --segundos 60 --sem-mdns   # hospeda
//! quall-probe controle --ip 192.168.57.20:7979 --pin 424242 --carga 100000       # conecta
//! ```
//!
//! O prompter hospeda com o papel, liga o espelho e relata uma posição que anda enquanto
//! "rola"; o controle manda um roteiro sintético de `--carga` bytes, a velocidade e o rolar, e
//! depois vinte edições, medindo quanto cada uma leva para **voltar confirmada** — o estado do
//! prompter mostrando o carimbo dela. É o mesmo núcleo que as cascas usam
//! (`quall_core::teleprompter::Teleprompter`), com a sessão de verdade e o rádio no meio.
//!
//! O que se mede aqui é **ida e volta de confirmação** (edição → estado do outro lado com ela),
//! no relógio monotônico de um lado só: não depende de relógio sincronizado.

use std::time::{Duration, Instant};

use quall_core::error::{Error, Result};
use quall_core::protocol::Papel;
use quall_core::session::EventoDeSessao;
use quall_core::discovery::PORTA_DO_TELEPROMPTER;
use quall_core::teleprompter::{mudou, resumo, Teleprompter};
use quall_core::transport::Mensageiro;

use crate::Opcoes;

/// O lado que mostra o texto.
pub fn prompter(op: &Opcoes) -> Result<()> {
    println!(
        "  porta do teleprompter: {} ({})",
        op.porta,
        if op.porta == PORTA_DO_TELEPROMPTER {
            "a 7979"
        } else if op.porta_explicita {
            "a de --porta"
        } else {
            "a 7979 estava ocupada"
        }
    );
    // A réplica, e o roteiro dela, **antes** de hospedar: é o que o prompter já tinha quando o
    // controle chegou.
    let t = Teleprompter::nova(&op.id, Papel::Teleprompter)?;
    if op.texto > 0 {
        let roteiro = roteiro_sintetico_de(op.texto, "Prompter");
        t.definir_texto(&roteiro)?;
        println!("  roteiro     : {} bytes, resumo {} (o do prompter)", roteiro.len(), resumo(&roteiro));
    }
    let mut pronto = crate::subir_emissor(op, Vec::new())?;
    println!("  entrega     : {:?}", pronto.session.entrega_do_canal());
    let m = pronto.session.mensageiro();
    t.definir_espelho(true)?;
    // O "rolar" de mentira abaixo rola para trás com `para_tras` e para quando `rolando` cai: é a
    // tela que entende o "segurar" (§12).
    t.ligar_segurar()?;
    // E finge a tela que grava (§13): aceita os pedidos do controle — ou os recusa, com
    // `--recusar-gravacao` — sem gravar nada. É o que prova o comando, não o arquivo.
    t.ligar_gravacao(true)?;

    let inicio = Instant::now();
    let mut pos = 0.0f64;
    let mut antes = Instant::now();
    // `--descartar-pct P` (§12.3): perda **simulada na chegada** — a mensagem já atravessou o SCTP e é
    // jogada fora aqui, antes da réplica, sem retransmissão; quem repara é o reenvio rápido do
    // segurar e o batimento. Não é perda no enlace: essa pediria mexer no firewall da máquina.
    let mut sorteio = 0x9E37_79B9_7F4A_7C15u64;
    let (mut vistas, mut descartadas) = (0u64, 0u64);
    while inicio.elapsed() < op.segundos {
        let espera = if op.descartar_pct > 0 {
            // Espia a próxima, até 20 ms, e a joga fora com a chance pedida; a que fica, a bombeada lê.
            let mut jogou = false;
            if let Ok(Some(_)) = m.entregar_se(Duration::from_millis(20), |_| {
                sorteio = sorteio.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                jogou = (sorteio >> 33) % 100 < u64::from(op.descartar_pct);
                jogou
            }) {
                vistas += 1;
                descartadas += u64::from(jogou);
            }
            Duration::ZERO
        } else {
            Duration::from_millis(50)
        };
        // As mudanças valem **também** na bombeada que diz que a sessão acabou: a última pausa do
        // controle chega nela.
        let b = t.bombear(&m, espera)?;
        let mud = b.mudancas;
        let e = t.estado()?;
        let s = inicio.elapsed().as_secs_f64();
        if mud & mudou::TEXTO != 0 {
            println!("{s:>8.3} s  texto chegou: {} bytes, resumo {}", e.texto_bytes, resumo(&t.texto()?));
        }
        if mud & mudou::SALTO != 0 {
            if let Some(alvo) = e.salto {
                pos = alvo;
                println!("{s:>8.3} s  salto para {alvo}");
            }
        }
        if mud & mudou::GRAVACAO != 0 {
            if let Some(p) = e.pedido_de_gravacao.as_ref() {
                let o_que = if p.gravar { "gravar" } else { "parar" };
                match &op.recusar_gravacao {
                    Some(motivo) => {
                        t.recusar_gravacao(p.n, motivo)?;
                        println!("{s:>8.3} s  pedido {} ({o_que}): RECUSADO — {motivo}", p.n);
                    }
                    None => {
                        t.definir_gravando(p.gravar)?;
                        println!("{s:>8.3} s  pedido {} ({o_que}): aceito", p.n);
                    }
                }
            }
        }
        if mud & (mudou::ROLANDO | mudou::VELOCIDADE | mudou::SEGURAR) != 0 {
            println!(
                "{s:>8.3} s  rolando={} para_tras={} segurando={} velocidade={} (posição {pos:.4})",
                e.rolando, e.para_tras, e.segurando, e.velocidade
            );
        }
        // Um "rolar" de mentira: a posição anda com a velocidade — para trás com `para_tras`,
        // parando no começo —, e o relato sai a 4 Hz.
        let dt = antes.elapsed().as_secs_f64();
        antes = Instant::now();
        if e.rolando {
            let passo = e.velocidade * dt / 600.0;
            pos = if e.para_tras { (pos - passo).max(0.0) } else { (pos + passo).min(1.0) };
            t.definir_posicao(pos)?;
        }
        if b.fechada || pronto.proximo_evento(Duration::ZERO) != EventoDeSessao::Nenhum {
            // A bombeada final, com prazo zero, antes de dar o par por perdido: o que estava na
            // fila entra (docs/contrato-teleprompter.md §6).
            if !b.fechada {
                let fim = t.bombear(&m, Duration::ZERO)?;
                if fim.mudancas & mudou::ROLANDO != 0 {
                    println!("{s:>8.3} s  rolando={} (na bombeada final)", t.estado()?.rolando);
                }
            }
            let antes_da_queda = t.estado()?;
            let mudou_na_queda = t.perdeu_o_par()?;
            let depois = t.estado()?;
            println!(
                "{s:>8.3} s  a sessão caiu; rolando={} segurando={} → depois da política: rolando={}{}",
                antes_da_queda.rolando,
                antes_da_queda.segurando,
                depois.rolando,
                if mudou_na_queda & mudou::ROLANDO != 0 { " (parou: caiu com o dedo no botão)" } else { "" }
            );
            // §13: a queda não para a gravação.
            println!(
                "{s:>8.3} s  gravando antes da queda: {:?} ms; depois: {:?} ms",
                antes_da_queda.gravando_ha_ms, depois.gravando_ha_ms
            );
            break;
        }
    }
    if op.descartar_pct > 0 {
        println!(
            "  descartadas na chegada (perda simulada): {descartadas} de {vistas} espiadas ({:.1} %)",
            100.0 * descartadas as f64 / vistas.max(1) as f64
        );
    }
    relatar(&t, &m)
}

/// O lado que controla.
pub fn controle(op: &Opcoes) -> Result<()> {
    let mut pronto = crate::subir_receptor(op)?;
    let t = match &op.salvo {
        Some(arquivo) if arquivo.exists() => {
            let json = std::fs::read_to_string(arquivo)?;
            let t = Teleprompter::de_salvo(&op.id, Papel::ControleRemoto, &json)?;
            println!(
                "  réplica     : do salvo {} (prompter da última vez: {})",
                arquivo.display(),
                ultimo_prompter(&t)?.unwrap_or_else(|| "nenhum".into())
            );
            t
        }
        _ => Teleprompter::nova(&op.id, Papel::ControleRemoto)?,
    };
    let m = pronto.session.mensageiro();
    // `--escolha` é a sonda com "a tela da pergunta": liga a trava (§11.10). Sem ela, vale "o
    // último que mudou", e sobram as cópias.
    if op.escolha.is_some() {
        t.ligar_pergunta_do_texto()?;
    }
    // `--gravar` / `--parar`: a gravação (§13), no lugar das 20 edições.
    if op.gravar || op.parar {
        return gravar(op, &t, &m, &mut pronto);
    }
    // `--segurar MS`: o "segurar para rolar" (§12), no lugar das 20 edições.
    if let Some(ms) = op.segurar_ms {
        return segurar(op, &t, &m, &mut pronto, Duration::from_millis(ms));
    }
    // `--texto` (ou uma réplica que já tem roteiro): a pergunta do texto, no lugar das 20 edições.
    if op.texto > 0 || op.salvo.is_some() {
        if op.texto > 0 {
            let roteiro = roteiro_sintetico_de(op.texto, "Controle");
            t.definir_texto(&roteiro)?;
        }
        let texto = t.texto()?;
        println!("  roteiro     : {} bytes, resumo {} (o do controle, antes da sessão)", texto.len(), resumo(&texto));
        let resultado = pergunta(op, &t, &m, &mut pronto);
        if let Some(arquivo) = &op.salvo {
            std::fs::write(arquivo, t.salvo_json()?)?;
            println!("  salvo       : gravado em {}", arquivo.display());
        }
        resultado?;
        return relatar(&t, &m);
    }
    let carga = if op.carga <= 1200 { 100_000 } else { op.carga };
    let roteiro = roteiro_sintetico(carga);
    // Uma bombeada antes: a réplica fica sabendo da sessão nova.
    t.bombear(&m, Duration::from_millis(10))?;
    println!("  entrega     : {:?}", pronto.session.entrega_do_canal());

    let t0 = Instant::now();
    t.definir_texto(&roteiro)?;
    t.definir_velocidade(2.5)?;
    t.definir_rolando(true)?;
    let primeiro = esperar_confirmacao(&t, &m, Duration::from_secs(30))?;
    println!(
        "roteiro de {} bytes (resumo {}) + velocidade + rolar: confirmados em {:.1} ms",
        roteiro.len(),
        resumo(&roteiro),
        primeiro.as_secs_f64() * 1000.0
    );
    let _ = t0;

    let mut tempos = Vec::new();
    for i in 0..20u32 {
        match i % 3 {
            0 => t.definir_rolando(i % 2 == 0)?,
            1 => t.definir_velocidade(1.0 + f64::from(i) * 0.1)?,
            _ => t.saltar_relativo(0.02)?,
        }
        tempos.push(esperar_confirmacao(&t, &m, Duration::from_secs(10))?);
        // Um respiro entre edições, bombeando: é o que a tela faz.
        let fim = Instant::now() + Duration::from_millis(200);
        while Instant::now() < fim {
            if t.bombear(&m, Duration::from_millis(50))?.fechada {
                return Err(Error::Closed);
            }
        }
        if pronto.proximo_evento(Duration::ZERO) != EventoDeSessao::Nenhum {
            return Err(Error::Closed);
        }
    }
    // `--fonte`: a fonte mudada pelo controle, depois das edições (desliga a fonte automática do prompter).
    if let Some(f) = op.fonte {
        t.definir_fonte(f)?;
        let d = esperar_confirmacao(&t, &m, Duration::from_secs(10))?;
        println!("fonte {f} pelo controle: confirmada em {:.1} ms", d.as_secs_f64() * 1000.0);
    }
    tempos.sort();
    let ms = |d: &Duration| d.as_secs_f64() * 1000.0;
    println!(
        "20 edições: confirmação p50 {:.1} ms, p90 {:.1} ms, máx {:.1} ms",
        ms(&tempos[tempos.len() / 2]),
        ms(&tempos[tempos.len() * 9 / 10]),
        ms(&tempos[tempos.len() - 1])
    );
    // O que o prompter mandou: o espelho dele e a posição que ele relata.
    let e = t.estado()?;
    println!("do prompter : espelho={} posição={} (relato)", e.espelho, e.posicao);
    relatar(&t, &m)
}

/// **A pergunta do texto** (§11 do contrato): bombeia até a pergunta abrir, responde com
/// `--escolha`, e espera a convergência — o prompter da última vez gravado. Com `--escolha
/// nenhuma`, sai com a pergunta aberta. Sem pergunta (o mesmo prompter da última vez, ou um lado
/// vazio), espera só a convergência.
fn pergunta(op: &Opcoes, t: &Teleprompter, m: &Mensageiro, pronto: &mut crate::Ready) -> Result<()> {
    let inicio = Instant::now();
    let par = m.par().map(|p| p.id.clone()).unwrap_or_default();
    let ms = |d: Duration| d.as_secs_f64() * 1000.0;
    let (mut abriu, mut escolhida) = (None::<Duration>, false);
    while inicio.elapsed() < Duration::from_secs(30) {
        let b = t.bombear(m, Duration::from_millis(20))?;
        if b.fechada || pronto.proximo_evento(Duration::ZERO) != EventoDeSessao::Nenhum {
            return Err(Error::Closed);
        }
        if b.mudancas & mudou::COPIA_DO_TEXTO != 0 {
            if let Some(arquivo) = &op.salvo {
                std::fs::write(arquivo, t.salvo_json()?)?;
            }
        }
        let e = t.estado()?;
        if let Some(q) = &e.pergunta_do_texto {
            if let (true, None) = (q.aberta, abriu) {
                abriu = Some(inicio.elapsed());
                let dele = q.do_prompter.as_ref();
                println!(
                    "{:>8.1} ms  PERGUNTA do prompter {} ({}): o meu {} bytes, resumo {}; o dele {} bytes, resumo {}",
                    ms(inicio.elapsed()),
                    q.prompter_id,
                    q.prompter_nome,
                    q.meu.bytes,
                    q.meu.resumo,
                    dele.map_or(0, |d| d.bytes),
                    dele.map_or("", |d| d.resumo.as_str()),
                );
            }
            if let (true, Some(dele)) = (q.aberta && !escolhida, q.do_prompter.as_ref()) {
                let manter = match op.escolha.as_deref() {
                    Some("prompter") => Some(false),
                    Some("meu") => Some(true),
                    _ => None,
                };
                match manter {
                    None if inicio.elapsed() - abriu.unwrap_or_default() > Duration::from_secs(2) => {
                        println!("{:>8.1} ms  a pergunta fica aberta (--escolha nenhuma)", ms(inicio.elapsed()));
                        return Ok(());
                    }
                    None => {}
                    Some(manter) => match t.resolver_texto(manter, &dele.resumo) {
                        Ok(()) => {
                            escolhida = true;
                            println!(
                                "{:>8.1} ms  escolha: {}",
                                ms(inicio.elapsed()),
                                if manter { "mandar o meu" } else { "usar o do prompter" }
                            );
                            // A regra da casca (§11.5): grave o salvo logo depois da escolha.
                            if let Some(arquivo) = &op.salvo {
                                std::fs::write(arquivo, t.salvo_json()?)?;
                            }
                        }
                        Err(Error::Ocupado(motivo)) => println!("  ocupado: {motivo} — de novo"),
                        Err(e) => return Err(e),
                    },
                }
            }
        }
        let convergiu = e.pergunta_do_texto.is_none()
            && e.sem_confirmacao_ha_ms.is_none()
            && ultimo_prompter(t)?.as_deref() == Some(par.as_str());
        if convergiu {
            let texto = t.texto()?;
            println!(
                "{:>8.1} ms  convergiu: {} bytes, resumo {}; {}",
                ms(inicio.elapsed()),
                texto.len(),
                resumo(&texto),
                if abriu.is_some() { "depois da pergunta" } else { "sem pergunta" }
            );
            for c in &e.copias_do_texto {
                println!("  cópia       : {:?}, {} bytes, resumo {}, do prompter {}", c.origem, c.bytes, c.resumo, c.prompter_id);
            }
            println!("  prompter da última vez: {par}");
            return Ok(());
        }
    }
    Err(Error::Timeout("a pergunta do texto não terminou em 30 s".into()))
}

/// **"Segurar para rolar"** (§12): espera o prompter dizer que entende, põe a velocidade no máximo
/// (para a posição andar à vista), aperta — para trás a partir do meio, com `--para-tras` —, segura
/// `quanto`, e solta; ou, com `--sair-segurando`, sai do processo com o dedo no botão (a queda).
fn segurar(
    op: &Opcoes,
    t: &Teleprompter,
    m: &Mensageiro,
    pronto: &mut crate::Ready,
    quanto: Duration,
) -> Result<()> {
    let inicio = Instant::now();
    let ms = |d: Duration| d.as_secs_f64() * 1000.0;
    let bombear_por = |d: Duration, pronto: &mut crate::Ready| -> Result<()> {
        let fim = Instant::now() + d;
        while Instant::now() < fim {
            if t.bombear(m, Duration::from_millis(20))?.fechada
                || pronto.proximo_evento(Duration::ZERO) != EventoDeSessao::Nenhum
            {
                return Err(Error::Closed);
            }
        }
        Ok(())
    };
    // O primeiro estado do prompter diz se a tela dele entende.
    let fim = Instant::now() + Duration::from_secs(3);
    while Instant::now() < fim && t.estado()?.par_visto_ha_ms.is_none() {
        bombear_por(Duration::from_millis(20), pronto)?;
    }
    bombear_por(Duration::from_millis(100), pronto)?;
    println!("  o prompter entende segurar: {}", t.estado()?.par_entende_segurar);
    t.definir_velocidade(20.0)?;
    if op.para_tras {
        t.saltar(0.5)?;
    }
    esperar_confirmacao(t, m, Duration::from_secs(10))?;
    bombear_por(Duration::from_millis(300), pronto)?;
    let de = t.estado()?.posicao;
    let mut segurando_em = de;
    let mut soltares = Vec::new();
    for vez in 0..op.vezes {
        let aqui = t.estado()?.posicao;
        let apertou = Instant::now();
        match t.segurar(op.para_tras) {
            Ok(()) => println!(
                "{:>8.1} ms  apertou: segurando {} (a posição do prompter está em {aqui:.4})",
                ms(inicio.elapsed()),
                if op.para_tras { "para trás" } else { "para a frente" }
            ),
            Err(e) => {
                println!("{:>8.1} ms  RECUSADO: {e}", ms(inicio.elapsed()));
                return relatar(t, m);
            }
        }
        let confirmado = esperar_confirmacao(t, m, Duration::from_secs(10))?;
        println!("  o aperto voltou confirmado em {:.1} ms", ms(confirmado));
        bombear_por(quanto.saturating_sub(apertou.elapsed()), pronto)?;
        segurando_em = t.estado()?.posicao;
        if op.sair_segurando {
            println!(
                "{:>8.1} ms  saindo com o dedo no botão (posição {segurando_em:.4}): o prompter tem de parar",
                ms(inicio.elapsed())
            );
            std::process::exit(0);
        }
        t.soltar()?;
        let confirmado = esperar_confirmacao(t, m, Duration::from_secs(10))?;
        soltares.push(ms(confirmado));
        println!(
            "{:>8.1} ms  soltou (posição {segurando_em:.4}); o soltar voltou confirmado em {:.1} ms",
            ms(inicio.elapsed()),
            ms(confirmado)
        );
        if vez + 1 < op.vezes {
            bombear_por(Duration::from_millis(300), pronto)?;
        }
    }
    if soltares.len() > 1 {
        soltares.sort_by(f64::total_cmp);
        let q = |f: usize| soltares[(soltares.len() * f / 100).min(soltares.len() - 1)];
        println!(
            "  o soltar voltou confirmado, em {} vezes: p50 {:.1} ms, p95 {:.1} ms, máx {:.1} ms",
            soltares.len(),
            q(50),
            q(95),
            soltares[soltares.len() - 1]
        );
    }
    bombear_por(Duration::from_millis(600), pronto)?;
    let parado_em = t.estado()?.posicao;
    bombear_por(Duration::from_millis(1_000), pronto)?;
    let um_segundo_depois = t.estado()?.posicao;
    println!(
        "  a posição do prompter: {de:.4} → {segurando_em:.4} segurando; {parado_em:.4} → {um_segundo_depois:.4} no segundo depois de soltar"
    );
    relatar(t, m)
}

/// **A gravação pelo controle** (§13): espera o prompter dizer que grava, pede, e mede quanto a
/// resposta leva para voltar — a duração contando, ou a recusa com o motivo. Com `--gravar --parar`,
/// grava por `--gravar-por` e para; com `--sair-gravando`, sai do processo gravando (a queda).
fn gravar(op: &Opcoes, t: &Teleprompter, m: &Mensageiro, pronto: &mut crate::Ready) -> Result<()> {
    let inicio = Instant::now();
    let ms = |d: Duration| d.as_secs_f64() * 1000.0;
    let bombear_ate = |ok: &dyn Fn(&quall_core::teleprompter::Estado) -> bool,
                       prazo: Duration,
                       pronto: &mut crate::Ready|
     -> Result<bool> {
        let fim = Instant::now() + prazo;
        while Instant::now() < fim {
            if t.bombear(m, Duration::from_millis(10))?.fechada
                || pronto.proximo_evento(Duration::ZERO) != EventoDeSessao::Nenhum
            {
                return Err(Error::Closed);
            }
            if ok(&t.estado()?) {
                return Ok(true);
            }
        }
        Ok(false)
    };
    // O primeiro estado do prompter diz se a tela dele grava.
    let _ = bombear_ate(&|e| e.par_visto_ha_ms.is_some(), Duration::from_secs(3), pronto)?;
    let _ = bombear_ate(&|e| e.par_entende_gravar, Duration::from_millis(500), pronto)?;
    println!("  o prompter grava: {}", t.estado()?.par_entende_gravar);
    // Um pedido e a espera da resposta: `Ok(true)` quando o prompter ficou como se pediu.
    let pedir = |gravar: bool, pronto: &mut crate::Ready| -> Result<bool> {
        let o_que = if gravar { "gravar" } else { "parar" };
        let pediu = Instant::now();
        let r = if gravar { t.pedir_gravar() } else { t.pedir_parar() };
        if let Err(e) = r {
            println!("{:>8.1} ms  pedir {o_que}: RECUSADO no controle — {e}", ms(inicio.elapsed()));
            return Ok(false);
        }
        let n = t.estado()?.pedido_de_gravacao.map(|p| p.n).unwrap_or(0);
        println!("{:>8.1} ms  pediu {o_que} (pedido {n})", ms(inicio.elapsed()));
        if !bombear_ate(&|e| e.pedido_de_gravacao.is_none(), Duration::from_secs(10), pronto)? {
            println!("  o pedido {n} não teve resposta em 10 s");
            return Ok(false);
        }
        let e = t.estado()?;
        if let Some(r) = e.gravacao_recusada {
            println!("  o pedido {n} voltou RECUSADO em {:.1} ms: {}", ms(pediu.elapsed()), r.motivo);
            return Ok(false);
        }
        // Aceito: a gravação do prompter aparece (ou some) na mesma resposta.
        let ficou = bombear_ate(&|e| e.gravando_ha_ms.is_some() == gravar, Duration::from_secs(2), pronto)?;
        println!(
            "  o pedido {n} voltou aceito em {:.1} ms; gravando_ha_ms = {:?}",
            ms(pediu.elapsed()),
            t.estado()?.gravando_ha_ms
        );
        Ok(ficou)
    };
    if op.gravar && pedir(true, pronto)? {
        if op.sair_gravando {
            println!(
                "{:>8.1} ms  saindo gravando ({:?} ms): o prompter tem de continuar gravando",
                ms(inicio.elapsed()),
                t.estado()?.gravando_ha_ms
            );
            std::process::exit(0);
        }
        if op.parar {
            let _ = bombear_ate(&|_| false, op.gravar_por, pronto)?;
            println!("{:>8.1} ms  gravando há {:?} ms (visto daqui)", ms(inicio.elapsed()), t.estado()?.gravando_ha_ms);
        }
    }
    if op.parar {
        pedir(false, pronto)?;
    }
    let _ = bombear_ate(&|_| false, Duration::from_millis(300), pronto)?;
    relatar(t, m)
}

/// O prompter da última vez que a réplica guarda, lido do salvo (é diagnóstico: a tela não precisa).
fn ultimo_prompter(t: &Teleprompter) -> Result<Option<String>> {
    let salvo: serde_json::Value = serde_json::from_str(&t.salvo_json()?)?;
    Ok(salvo.get("ultimo_prompter_id").and_then(|v| v.as_str()).map(str::to_string))
}

/// Bombeia até o estado do outro lado mostrar todas as edições daqui. Devolve quanto levou.
fn esperar_confirmacao(t: &Teleprompter, m: &Mensageiro, prazo: Duration) -> Result<Duration> {
    let comeco = Instant::now();
    while comeco.elapsed() < prazo {
        if t.bombear(m, Duration::from_millis(5))?.fechada {
            return Err(Error::Closed);
        }
        if t.estado()?.sem_confirmacao_ha_ms.is_none() {
            return Ok(comeco.elapsed());
        }
    }
    Err(Error::Timeout(format!("a edição não voltou confirmada em {prazo:?}")))
}

fn relatar(t: &Teleprompter, m: &Mensageiro) -> Result<()> {
    let e = t.estado()?;
    let texto = t.texto()?;
    println!();
    println!("texto final : {} bytes, resumo {}", texto.len(), resumo(&texto));
    println!("estado final: {}", serde_json::to_string(&e).unwrap_or_default());
    println!("mensagens   : {}", serde_json::to_string(&m.contadores()).unwrap_or_default());
    Ok(())
}

/// Um roteiro sintético, com acento e emoji, de ~`bytes` bytes.
fn roteiro_sintetico(bytes: usize) -> String {
    roteiro_sintetico_de(bytes, "Linha")
}

/// O mesmo, com `marca` no começo de cada linha: dois lados com o mesmo tamanho têm roteiros
/// diferentes, e o resumo diz de quem é cada um.
fn roteiro_sintetico_de(bytes: usize, marca: &str) -> String {
    let mut s = String::with_capacity(bytes + 64);
    let mut i = 0u32;
    while s.len() < bytes {
        s.push_str(&format!("{marca} {i}: boa noite, ação e emoção no teleprompter. 🎬\n"));
        i += 1;
    }
    while s.len() > bytes {
        s.pop();
    }
    s
}
