// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
// Mede a **fração de quadros que chega INTEIRA**, por tamanho de quadro em pacotes.
//
// # Por que este instrumento existe, e por que `rajada-udp.py` não bastava
//
// `tools/rajada-udp.py` responde "quantos pacotes chegaram", somando o `Udp: NoPorts` do kernel do
// alvo. É a medida certa para "o enlace perde", e foi ela que achou o penhasco de 50 pacotes em
// 28/08. Mas ela **não sabe dizer se um quadro chegou inteiro**, e é isso — e só isso — que decide
// se um IDR conserta a imagem. Um IDR ao qual falta um pacote não é 98 % de um IDR: é nada.
//
// A diferença não é de precisão, é de pergunta. Numa rajada de 60 pacotes com 4 % de perda:
//
// - o contador do kernel diz "chegaram 57,6 em média";
// - este instrumento diz "de 100 rajadas, X chegaram com os 60".
//
// X é o eixo do produto, e ninguém nesta bancada tinha medido X.
//
// # O que ele NÃO tem dentro
//
// Nada do Quall. Um `UdpSocket` da `std` de cada lado. Sem cargo, sem dependência, sem
// `quall-core`: `rustc` sozinho compila este arquivo para o host e para o Android em segundos, o
// que também é o motivo de ele não ser um subcomando do `quall-probe` — a sonda arrasta
// libdatachannel e OpenSSL, e um instrumento que compartilha a pilha sob suspeita não separa nada.
//
// A carga é sintética (enchimento constante). Nenhum pixel, de nenhuma máquina, atravessa isto.
//
// # Formato do pacote (24 B de cabeçalho + enchimento)
//
//     0..4    b"QRAJ"
//     4..8    corrida  (u32 BE) — separa execuções que se cruzem no ar
//     8..12   quadro   (u32 BE) — o número do quadro/rajada
//     12..16  indice   (u32 BE) — 0..total-1 dentro do quadro
//     16..20  total    (u32 BE) — quantos pacotes tem este quadro
//     20..24  reservado
//
// O `total` viajar em **cada** pacote é deliberado: o receptor sabe o tamanho do quadro mesmo que
// o primeiro pacote dele se perca, que é exatamente o caso que interessa.
//
// # Uso
//
//     rustc -O tools/rajada-completa.rs -o /tmp/rajada
//     /tmp/rajada receber --porta 9911 --saida /tmp/lado-b.tsv
//     /tmp/rajada enviar --destino 192.168.56.159:9911 --tamanhos 3,15,40,60,84 \
//                        --fundo 5 --por-tamanho 40 --cadencia-ms 33
//
// # Aferição (obrigatória antes de qualquer conclusão — ver `docs/regras-de-frente.md`)
//
//     rajada aferir            # roda os dois sentidos em loopback e imprime PASSA/REPROVA

use std::collections::HashMap;
use std::fmt::Write as _;
use std::io::Write as _;
use std::net::UdpSocket;
use std::time::{Duration, Instant};

const MAGICA: &[u8; 4] = b"QRAJ";
const CABECALHO: usize = 24;
/// 1200 B é o tamanho de datagrama que a bancada já usou em `rajada-udp.py`, e é o do nosso fio:
/// `MAX_FRAGMENTO = 1188` de carga + 12 B de cabeçalho RTP.
const TAMANHO_PADRAO: usize = 1200;

// =================================================================================================
// Espera
// =================================================================================================

/// Espera ocupada até um instante. `thread::sleep` tem grão de ~1 ms no macOS e ~15 ms no Windows;
/// o espaçamento que este instrumento precisa produzir tem grão de dezenas de microssegundos.
fn espera_ate(alvo: Instant) {
    while Instant::now() < alvo {
        std::hint::spin_loop();
    }
}

// =================================================================================================
// Emissor
// =================================================================================================

struct Envio {
    destino: String,
    tamanhos: Vec<u32>,
    fundo: u32,
    por_tamanho: u32,
    cadencia_ms: f64,
    espalhar_ms: f64,
    /// Só espalha quadros com pelo menos este tanto de pacotes. `0` (o padrão) espalha todos.
    ///
    /// Existe porque a primeira medição de ritmo espalhava **também** o tráfego de fundo, e a
    /// perda dele subiu 8 a 13 vezes. Com os dois efeitos no mesmo braço não dá para dizer se o
    /// quadro grande piorou por ter sido espalhado ou por o enlace inteiro ter piorado em volta
    /// dele. Um ritmo de verdade só espalharia o quadro grande; este sinalizador mede isso.
    espalhar_minimo: u32,
    bytes: usize,
    corrida: u32,
    sndbuf: Option<usize>,
}

/// A sequência de quadros de uma corrida: para cada tamanho pedido, `por_tamanho` repetições,
/// separadas por quadros de `fundo` pacotes.
///
/// O fundo não é enfeite. Uma sessão não é uma rajada fria: é um fluxo contínuo de quadros
/// pequenos com um quadro grande de vez em quando. Medir a rajada fria mede a abertura; medir com
/// fundo mede o que o produto faz. `--fundo 0` volta ao caso frio, para casar com 28/08.
fn sequencia(e: &Envio) -> Vec<u32> {
    let mut v = Vec::new();
    // Aquecimento: 30 quadros de fundo antes do primeiro grande, para que o primeiro tamanho da
    // lista não pague sozinho o custo do caminho frio e vire um ponto fora da curva.
    if e.fundo > 0 {
        for _ in 0..30 {
            v.push(e.fundo);
        }
    }
    // Intercalado por rodada, e não em blocos: 40 rajadas de 60 seguidas medem os 60 numa janela
    // de tempo, e 40 de 3 em outra. Se o enlace piorar no meio da corrida, o bloco absorve a piora
    // inteira e ela vira "tamanho 60 é pior". Intercalando, toda célula da curva atravessa a mesma
    // janela de rede.
    for _ in 0..e.por_tamanho {
        for &t in &e.tamanhos {
            v.push(t);
            if e.fundo > 0 {
                for _ in 0..9 {
                    v.push(e.fundo);
                }
            }
        }
    }
    v
}

fn enviar(e: &Envio) -> std::io::Result<()> {
    let s = UdpSocket::bind("0.0.0.0:0")?;
    s.connect(&e.destino)?;
    if let Some(n) = e.sndbuf {
        // Só informativo no relato; a `std` não expõe SO_SNDBUF sem libc, e trocá-lo aqui exigiria
        // uma dependência. Fica registrado que NÃO foi mexido.
        let _ = n;
    }

    let quadros = sequencia(e);
    let mut carga = vec![b'x'; e.bytes.max(CABECALHO)];
    carga[0..4].copy_from_slice(MAGICA);
    carga[4..8].copy_from_slice(&e.corrida.to_be_bytes());

    println!(
        "# emissor plataforma={} destino={} corrida={} quadros={} bytes={} cadencia_ms={} espalhar_ms={} fundo={}",
        std::env::consts::OS,
        e.destino,
        e.corrida,
        quadros.len(),
        e.bytes,
        e.cadencia_ms,
        e.espalhar_ms,
        e.fundo
    );
    if e.espalhar_minimo > 0 {
        println!("# emissor: espalha SÓ quadros de {}+ pacotes", e.espalhar_minimo);
    }

    let inicio = Instant::now();
    let mut enviados: u64 = 0;
    let mut erros: u64 = 0;
    // `ENOBUFS` no `sendto` acontece de verdade nesta bancada quando 163 pacotes de 1200 B saem
    // colados por Wi-Fi: o socket do macOS recusou 8 de 1007 na primeira corrida fria. Um pacote
    // recusado **nunca entra no ar**, e contá-lo como perda do enlace seria atribuir à rede um
    // descarte local — exatamente o formato da dívida 30. Aqui ele é reoferecido por até 500 µs e,
    // se ainda assim não sair, sai do denominador pela linha `recusados`.
    let mut reofertas: u64 = 0;
    for (n, &total) in quadros.iter().enumerate() {
        let devido = inicio + Duration::from_secs_f64(n as f64 * e.cadencia_ms / 1000.0);
        espera_ate(devido);
        let t0 = Instant::now();
        carga[8..12].copy_from_slice(&(n as u32).to_be_bytes());
        carga[16..20].copy_from_slice(&total.to_be_bytes());
        for i in 0..total {
            carga[12..16].copy_from_slice(&i.to_be_bytes());
            let limite = Instant::now() + Duration::from_micros(500);
            loop {
                match s.send(&carga) {
                    Ok(_) => {
                        enviados += 1;
                        break;
                    }
                    Err(_) if Instant::now() < limite => {
                        reofertas += 1;
                        std::hint::spin_loop();
                    }
                    Err(_) => {
                        erros += 1;
                        break;
                    }
                }
            }
            // O espalhamento é sobre o quadro inteiro: o pacote `i` sai em `t0 + i/total * T`.
            // Com `--espalhar-ms 0` (padrão) a rajada sai colada, que é o que a libdatachannel faz
            // hoje com uma unidade de acesso.
            if e.espalhar_ms > 0.0 && total >= e.espalhar_minimo.max(1) && i + 1 < total {
                let dt = e.espalhar_ms / 1000.0 * ((i + 1) as f64 / total as f64);
                espera_ate(t0 + Duration::from_secs_f64(dt));
            }
        }
    }

    // Cauda de fim: cinco marcadores espaçados, para o receptor fechar sem depender de relógio.
    // Cinco porque um pode se perder — e perder o fim faria o receptor esperar o ocioso inteiro,
    // que é apenas lento, nunca errado.
    carga[8..12].copy_from_slice(&u32::MAX.to_be_bytes());
    carga[16..20].copy_from_slice(&0u32.to_be_bytes());
    for i in 0..5u32 {
        carga[12..16].copy_from_slice(&i.to_be_bytes());
        let _ = s.send(&carga);
        espera_ate(Instant::now() + Duration::from_millis(20));
    }

    let dur = inicio.elapsed().as_secs_f64();
    println!(
        "# emissor: pacotes={enviados} recusados={erros} reofertas={reofertas} \
duracao_s={dur:.3} taxa_pac_s={:.1}",
        enviados as f64 / dur.max(1e-9)
    );
    Ok(())
}

// =================================================================================================
// Receptor
// =================================================================================================

struct Recepcao {
    porta: u16,
    saida: Option<String>,
    ocioso_ms: u64,
    limite_s: u64,
    /// Descarte artificial, em partes por mil, para **aferir o instrumento no sentido de achar
    /// perda**. Um contador que nunca viu perda não está provado; ver `aferir`.
    descartar_ppm: u32,
}

struct Quadro {
    total: u32,
    chegados: Vec<bool>,
    recebidos: u32,
}

/// Gerador congruencial de 64 bits (Knuth/MMIX). Determinístico de propósito: o braço de aferição
/// tem de dar o mesmo número duas vezes seguidas, senão não afere nada.
struct Sorteio(u64);
impl Sorteio {
    fn proximo(&mut self) -> u32 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (self.0 >> 33) as u32
    }
}

/// Pede ao kernel um buffer de recepção grande, e devolve o que ele deu de fato.
///
/// **Sem isto o instrumento mente exatamente nas rajadas que importam.** O padrão do Android
/// (`rmem_default`) é 229.376 B — ~190 pacotes de 1200 B. Uma rajada de 369 pacotes (442.800 B)
/// **não cabe por construção**: chega do rádio de 5 GHz em poucos ms, o processo não drena a
/// tempo, e o kernel descarta contando em `Udp: RcvbufErrors` — que o receptor não vê. Em
/// 2026-09-03 isso produziu "42,5 % dos IDR de 369 chegam inteiros" no S24 enquanto o contador do
/// kernel subia 3.897 descartes de buffer: o número era do socket, não do AP. No A10s, no rádio
/// lento de 2,4 GHz, o buffer nunca enchia e o defeito ficava invisível — **o rádio melhor é o que
/// quebrava o instrumento.**
///
/// Sem cargo, sem `libc`: a chamada é declarada à mão. `SOL_SOCKET`/`SO_RCVBUF` diferem entre
/// Linux/Android e macOS. Tenta do maior para o menor, porque o teto (`rmem_max`, ou
/// `kern.ipc.maxsockbuf` no macOS) varia por máquina, e um pedido acima dele é recusado inteiro.
/// O Linux devolve o dobro do pedido em `getsockopt` (contabiliza a sobrecarga); o número
/// impresso é esse, cru, para bater com o que o kernel usa.
#[cfg(unix)]
fn ajustar_rcvbuf(s: &UdpSocket) -> i32 {
    use std::os::fd::AsRawFd;
    extern "C" {
        fn setsockopt(fd: i32, level: i32, name: i32, val: *const u8, len: u32) -> i32;
        fn getsockopt(fd: i32, level: i32, name: i32, val: *mut u8, len: *mut u32) -> i32;
    }
    let linux = cfg!(any(target_os = "linux", target_os = "android"));
    let (sol, opt) = if linux { (1, 8) } else { (0xffff, 0x1002) };
    let fd = s.as_raw_fd();
    for pedido in [16 << 20, 8 << 20, 4 << 20, 2 << 20, 1 << 20] {
        let v: i32 = pedido;
        let ok = unsafe { setsockopt(fd, sol, opt, &v as *const i32 as *const u8, 4) } == 0;
        if ok {
            break;
        }
    }
    let mut atual: i32 = 0;
    let mut len: u32 = 4;
    unsafe { getsockopt(fd, sol, opt, &mut atual as *mut i32 as *mut u8, &mut len) };
    atual
}

/// No Windows o padrão é ainda menor — 64 KB, ~54 pacotes de 1200 B — e o Dell é o receptor de
/// referência da classe computador. Mesmos números de `SOL_SOCKET`/`SO_RCVBUF` do BSD, chamada
/// da `ws2_32`, e o descritor é um `SOCKET` (`usize`), não um `int`.
#[cfg(windows)]
fn ajustar_rcvbuf(s: &UdpSocket) -> i32 {
    use std::os::windows::io::AsRawSocket;
    #[link(name = "ws2_32")]
    extern "system" {
        fn setsockopt(s: usize, level: i32, name: i32, val: *const u8, len: i32) -> i32;
        fn getsockopt(s: usize, level: i32, name: i32, val: *mut u8, len: *mut i32) -> i32;
    }
    let (sol, opt) = (0xffff, 0x1002);
    let fd = s.as_raw_socket() as usize;
    for pedido in [16 << 20, 8 << 20, 4 << 20, 2 << 20, 1 << 20] {
        let v: i32 = pedido;
        if unsafe { setsockopt(fd, sol, opt, &v as *const i32 as *const u8, 4) } == 0 {
            break;
        }
    }
    let mut atual: i32 = 0;
    let mut len: i32 = 4;
    unsafe { getsockopt(fd, sol, opt, &mut atual as *mut i32 as *mut u8, &mut len) };
    atual
}

#[cfg(not(any(unix, windows)))]
fn ajustar_rcvbuf(_s: &UdpSocket) -> i32 {
    -1
}

fn receber(r: &Recepcao) -> std::io::Result<()> {
    let s = UdpSocket::bind(("0.0.0.0", r.porta))?;
    let rcvbuf = ajustar_rcvbuf(&s);
    println!("# receptor rcvbuf={} B (~{} pacotes de 1200)", rcvbuf, if rcvbuf > 0 { rcvbuf / 1200 } else { 0 });
    if rcvbuf > 0 && rcvbuf < 1_000_000 {
        println!("# ATENÇÃO: rcvbuf pequeno; rajadas acima de ~{} pacotes podem morrer no socket, não no ar", rcvbuf / 1200);
    }
    s.set_read_timeout(Some(Duration::from_millis(200)))?;
    println!("# receptor plataforma={} porta={}", std::env::consts::OS, r.porta);
    if r.descartar_ppm > 0 {
        println!("# receptor: DESCARTE ARTIFICIAL de {} ppm ligado", r.descartar_ppm);
    }

    let mut buf = vec![0u8; 2048];
    let mut quadros: HashMap<u32, Quadro> = HashMap::new();
    let mut ordem: Vec<u32> = Vec::new();
    let mut corrida: Option<u32> = None;
    let mut recebidos_brutos: u64 = 0;
    let mut descartados: u64 = 0;
    let mut sorteio = Sorteio(0x5eed_1234_abcd_0001);
    let inicio = Instant::now();
    let mut ultimo = Instant::now();
    let mut viu_algo = false;
    let mut fim = false;

    while !fim {
        if inicio.elapsed() > Duration::from_secs(r.limite_s) {
            break;
        }
        if viu_algo && ultimo.elapsed() > Duration::from_millis(r.ocioso_ms) {
            break;
        }
        let n = match s.recv(&mut buf) {
            Ok(n) => n,
            Err(_) => continue,
        };
        if n < CABECALHO || &buf[0..4] != MAGICA {
            continue;
        }
        let c = u32::from_be_bytes(buf[4..8].try_into().unwrap());
        let quadro = u32::from_be_bytes(buf[8..12].try_into().unwrap());
        let indice = u32::from_be_bytes(buf[12..16].try_into().unwrap());
        let total = u32::from_be_bytes(buf[16..20].try_into().unwrap());
        match corrida {
            None => corrida = Some(c),
            Some(v) if v != c => continue, // outra corrida no ar; não é nossa
            _ => {}
        }
        viu_algo = true;
        ultimo = Instant::now();
        if quadro == u32::MAX {
            fim = true;
            continue;
        }
        recebidos_brutos += 1;
        if r.descartar_ppm > 0 && sorteio.proximo() % 1000 < r.descartar_ppm {
            descartados += 1;
            continue;
        }
        let q = quadros.entry(quadro).or_insert_with(|| {
            ordem.push(quadro);
            Quadro {
                total,
                chegados: vec![false; total as usize],
                recebidos: 0,
            }
        });
        if (indice as usize) < q.chegados.len() && !q.chegados[indice as usize] {
            q.chegados[indice as usize] = true;
            q.recebidos += 1;
        }
    }

    // ---- Linhas por quadro (TSV) ----
    ordem.sort_unstable();
    let mut texto = String::new();
    let _ = writeln!(
        texto,
        "# corrida={} quadros_vistos={} pacotes_brutos={} descartados_artificialmente={}",
        corrida.unwrap_or(0),
        ordem.len(),
        recebidos_brutos,
        descartados
    );
    let _ = writeln!(texto, "quadro\ttotal\trecebidos\tinteiro\tpadrao");
    for k in &ordem {
        let q = &quadros[k];
        let inteiro = u32::from(q.recebidos == q.total);
        // O padrão de chegada em RLE: `44+16-` = 44 chegaram, 16 faltaram, nesta ordem. É o que
        // separa "perdeu a cauda" (assinatura de fila cheia) de "perdeu espalhado" (assinatura de
        // ar). Sem ele a curva diria QUANTO se perde e não DE QUE JEITO.
        let mut padrao = String::new();
        let mut i = 0usize;
        while i < q.chegados.len() {
            let v = q.chegados[i];
            let mut j = i;
            while j < q.chegados.len() && q.chegados[j] == v {
                j += 1;
            }
            let _ = write!(padrao, "{}{}", j - i, if v { "+" } else { "-" });
            i = j;
        }
        let _ = writeln!(texto, "{}\t{}\t{}\t{}\t{}", k, q.total, q.recebidos, inteiro, padrao);
    }

    // ---- Resumo por tamanho: A CURVA ----
    let mut por_tamanho: HashMap<u32, (u32, u32, u64, u64)> = HashMap::new();
    for k in &ordem {
        let q = &quadros[k];
        let e = por_tamanho.entry(q.total).or_insert((0, 0, 0, 0));
        e.0 += 1;
        if q.recebidos == q.total {
            e.1 += 1;
        }
        e.2 += u64::from(q.total);
        e.3 += u64::from(q.recebidos);
    }
    let mut tamanhos: Vec<u32> = por_tamanho.keys().copied().collect();
    tamanhos.sort_unstable();
    let _ = writeln!(texto, "\n# CURVA");
    let _ = writeln!(
        texto,
        "tamanho\tquadros\tinteiros\tfracao_inteiros\tpacotes\tchegados\tperda_pct"
    );
    for t in tamanhos {
        let (n, ok, pac, cheg) = por_tamanho[&t];
        let perda = if pac > 0 {
            100.0 * (pac - cheg) as f64 / pac as f64
        } else {
            0.0
        };
        let _ = writeln!(
            texto,
            "{t}\t{n}\t{ok}\t{:.4}\t{pac}\t{cheg}\t{perda:.3}",
            ok as f64 / n.max(1) as f64
        );
    }

    // ---- Os quadros que não têm linha nenhuma, e por que eles precisam ser ditos aqui ----
    //
    // Um quadro que perde **todos** os seus pacotes não gera linha no TSV: o receptor nunca soube
    // que ele existiu. Logo `perda_pct` acima é *"dos pacotes dos quadros que chegaram, quantos
    // faltaram"* — e **não** a taxa de perda da corrida.
    //
    // O viés não é constante, e é por isso que ele engana: ele é enorme para rajada pequena (um
    // quadro de 5 pacotes some inteiro com facilidade) e quase nulo para rajada grande. Medido em
    // 31/08, na mesma bancada e na mesma taxa: um braço de rajada de 5 relatou **4,74 %** aqui e
    // perdeu **9,93 %** de verdade, enquanto o de rajada de 22 relatou 5,41 % contra 7,14 %. Ou
    // seja: o viés **inverte a ordem entre braços**, e o braço que parecia o melhor da matriz era
    // o pior. Ver `docs/perda-sem-dono.md`, "O denominador".
    //
    // O receptor não tem como fechar a conta sozinho — ele não sabe o tamanho de um quadro do qual
    // nada chegou. O que ele **pode** fazer, e faz aqui, é dizer quantos índices de quadro sumiram
    // por inteiro dentro da janela que ele viu, para que ninguém leia a coluna acima como taxa de
    // perda sem saber que há buracos. **O denominador certo é o `pacotes=` do emissor.**
    if let (Some(&primeiro), Some(&ultimo)) = (ordem.first(), ordem.last()) {
        let esperados = (ultimo - primeiro + 1) as usize;
        let ausentes = esperados - ordem.len();
        let _ = writeln!(texto, "\n# QUADROS SEM NENHUM PACOTE");
        let _ = writeln!(
            texto,
            "# entre os índices {primeiro} e {ultimo} faltam {ausentes} quadros por inteiro"
        );
        if ausentes > 0 {
            let _ = writeln!(
                texto,
                "# ATENÇÃO: `perda_pct` acima NÃO é a taxa de perda — ela ignora estes {ausentes} \
quadros.\n# Divida pelo `pacotes=` que o emissor imprimiu. Ver docs/perda-sem-dono.md."
            );
        }
    }

    print!("{texto}");
    if let Some(p) = &r.saida {
        let mut f = std::fs::File::create(p)?;
        f.write_all(texto.as_bytes())?;
        println!("# escrito em {p}");
    }
    Ok(())
}

// =================================================================================================
// Aferição — o instrumento contra caso conhecido, NOS DOIS SENTIDOS
// =================================================================================================
//
// `docs/regras-de-frente.md`: instrumento não aferido contra caso conhecido não é instrumento.
// Aqui os dois casos conhecidos são:
//
//   A. **Sem perda** (loopback): a fração de quadros inteiros tem de ser 1,0000 em todo tamanho.
//      Um instrumento que inventa perda reprova aqui.
//   B. **Com perda conhecida** (descarte artificial de p, independente por pacote): a fração de
//      quadros inteiros de tamanho N tem de bater com (1-p)^N. Um instrumento que engole perda
//      reprova aqui.
//
// O caso B é o mais importante dos dois, e é o que quase nunca se faz: um contador que só foi
// testado no caso limpo passa por bom enquanto perde metade do que devia contar.

fn aferir() -> std::io::Result<()> {
    println!("== Aferição de `rajada-completa` — loopback, dois sentidos ==\n");
    let tamanhos = vec![3u32, 15, 40, 60, 84];
    let mut reprovou = false;

    for (rotulo, ppm) in [("A. sem perda", 0u32), ("B. perda conhecida de 3,0 %", 30u32)] {
        println!("-- {rotulo} --");
        let porta = 19_900 + u16::from(ppm > 0);
        let r = Recepcao {
            porta,
            saida: Some(
                std::env::temp_dir()
                    .join(format!("rajada-afericao-{ppm}.tsv"))
                    .to_string_lossy()
                    .into_owned(),
            ),
            ocioso_ms: 900,
            limite_s: 120,
            descartar_ppm: ppm,
        };
        let tam = tamanhos.clone();
        let filho = std::thread::spawn(move || receber(&r));
        std::thread::sleep(Duration::from_millis(300));
        enviar(&Envio {
            destino: format!("127.0.0.1:{porta}"),
            tamanhos: tam,
            fundo: 0,
            por_tamanho: 200,
            cadencia_ms: 2.0,
            espalhar_ms: 0.0,
            espalhar_minimo: 0,
            bytes: TAMANHO_PADRAO,
            corrida: 7,
            sndbuf: None,
        })?;
        let _ = filho.join();

        let texto = std::fs::read_to_string(
            std::env::temp_dir().join(format!("rajada-afericao-{ppm}.tsv")),
        )?;
        let p = f64::from(ppm) / 1000.0;
        for linha in texto.lines() {
            let campos: Vec<&str> = linha.split('\t').collect();
            if campos.len() != 7 || campos[0] == "tamanho" || linha.starts_with('#') {
                continue;
            }
            let (Ok(t), Ok(n), Ok(f)) = (
                campos[0].parse::<u32>(),
                campos[1].parse::<u32>(),
                campos[3].parse::<f64>(),
            ) else {
                continue;
            };
            let esperado = (1.0 - p).powi(t as i32);
            // Tolerância: 3 desvios binomiais + 1 ponto de folga para o n desta aferição.
            let sigma = (esperado * (1.0 - esperado) / f64::from(n.max(1))).sqrt();
            let tol = 3.0 * sigma + 0.01;
            let ok = (f - esperado).abs() <= tol;
            if !ok {
                reprovou = true;
            }
            println!(
                "   tamanho {t:>3}: medido {f:.4}  esperado {esperado:.4}  (±{tol:.4})  {}",
                if ok { "ok" } else { "REPROVA" }
            );
        }
        println!();
    }

    if reprovou {
        println!("REPROVA — o instrumento não bate com o caso conhecido; nenhum número dele vale.");
        std::process::exit(1);
    }
    println!("PASSA — sem perda dá 1,0000 e com 3,0 % dá (1-p)^N nos cinco tamanhos.");
    Ok(())
}

// =================================================================================================
// Linha de comando
// =================================================================================================

fn ajuda() {
    eprintln!(
        "uso:
  rajada-completa receber --porta 9911 [--saida a.tsv] [--ocioso-ms 1500] [--limite-s 600]
                          [--descartar-ppm 0]
  rajada-completa enviar  --destino IP:PORTA --tamanhos 3,15,40,60,84
                          [--fundo 5] [--por-tamanho 40] [--cadencia-ms 33]
                          [--espalhar-ms 0] [--espalhar-minimo 0] [--bytes 1200] [--corrida N]
  rajada-completa aferir"
    );
}

fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        ajuda();
        std::process::exit(2);
    }
    let pega = |chave: &str| -> Option<String> {
        args.iter()
            .position(|a| a == chave)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    match args[1].as_str() {
        "aferir" => aferir(),
        "receber" => receber(&Recepcao {
            porta: pega("--porta").and_then(|v| v.parse().ok()).unwrap_or(9911),
            saida: pega("--saida"),
            ocioso_ms: pega("--ocioso-ms").and_then(|v| v.parse().ok()).unwrap_or(1500),
            limite_s: pega("--limite-s").and_then(|v| v.parse().ok()).unwrap_or(600),
            descartar_ppm: pega("--descartar-ppm").and_then(|v| v.parse().ok()).unwrap_or(0),
        }),
        "enviar" => {
            let Some(destino) = pega("--destino") else {
                ajuda();
                std::process::exit(2);
            };
            enviar(&Envio {
                destino,
                tamanhos: pega("--tamanhos")
                    .unwrap_or_else(|| "3,15,40,60,84".into())
                    .split(',')
                    .filter_map(|v| v.trim().parse().ok())
                    .collect(),
                fundo: pega("--fundo").and_then(|v| v.parse().ok()).unwrap_or(5),
                por_tamanho: pega("--por-tamanho").and_then(|v| v.parse().ok()).unwrap_or(40),
                cadencia_ms: pega("--cadencia-ms").and_then(|v| v.parse().ok()).unwrap_or(33.0),
                espalhar_ms: pega("--espalhar-ms").and_then(|v| v.parse().ok()).unwrap_or(0.0),
                espalhar_minimo: pega("--espalhar-minimo")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                bytes: pega("--bytes").and_then(|v| v.parse().ok()).unwrap_or(TAMANHO_PADRAO),
                corrida: pega("--corrida").and_then(|v| v.parse().ok()).unwrap_or_else(|| {
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.subsec_nanos())
                        .unwrap_or(1)
                }),
                sndbuf: None,
            })
        }
        _ => {
            ajuda();
            std::process::exit(2);
        }
    }
}
