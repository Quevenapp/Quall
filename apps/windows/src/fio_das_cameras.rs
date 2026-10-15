//! **O fio das câmeras virtuais** (12/10/2026): o único lugar do app que cria e solta nós de câmera
//! virtual, num apartamento multithread próprio.
//!
//! # Por que um fio, e não a thread da janela
//!
//! Até esta rodada o nó nascia na thread da janela (`baias::atender_pendentes`, a cada pulso de
//! 100 ms), porque `IMFVirtualCamera` não é `Send` e quem cria tem de segurar. Para um `.exe`
//! avulso isso funcionava. Para o Quall **empacotado** a Microsoft escreve o contrário, na página
//! de `MFCreateVirtualCamera`: *"UWP and Packaged Apps must not invoke MFCreateVirtualCamera on
//! their UI thread"* — a verificação de consentimento da câmera do Windows trava ali, e com ela a
//! janela inteira. O Quall da loja (MSIX) cria as câmeras também — com a fonte registrada no
//! sistema pelo instalador da câmera, desde a tarde de 12/10 (`instalador_da_camera.rs`) —, então a
//! criação sai da janela de vez, nos dois jeitos de instalar: um caminho só é um caminho testado.
//!
//! O fio segura os objetos COM do começo ao fim (eles nunca atravessam thread, que é o que o
//! compilador cobrava), recebe só **nomes** ([`FioDasCameras::querer`]) e publica uma
//! [`Andamento`] que a janela lê.
//!
//! # A saída
//!
//! [`FioDasCameras::encerrar`] pede ao fio que solte tudo e **espera no máximo 5 s**. Uma criação
//! presa na pergunta de consentimento não pode segurar o fechamento do app; se o prazo vencer, o
//! processo sai assim mesmo, e a vida `MFVirtualCameraLifetime_Session` leva os nós com ele
//! (medido em §8.58, inclusive com morte à força).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use crate::baia::CameraVirtual;
use crate::registro;
use crate::regras_da_camera_virtual::{classificar, planejar, Falha};

/// O que o fio tem agora, para o cartão dos Ajustes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Andamento {
    pub vivas: Vec<String>,
    pub trabalhando: bool,
    pub falha: Option<Falha>,
}

enum Pedido {
    Querer(Vec<String>),
    Encerrar(mpsc::Sender<()>),
}

pub struct FioDasCameras {
    pedidos: mpsc::Sender<Pedido>,
    andamento: Arc<Mutex<Andamento>>,
    revisao: Arc<AtomicU64>,
    fio: Mutex<Option<JoinHandle<()>>>,
}

impl FioDasCameras {
    pub fn subir() -> FioDasCameras {
        let (tx, rx) = mpsc::channel();
        let andamento = Arc::new(Mutex::new(Andamento::default()));
        let revisao = Arc::new(AtomicU64::new(1));
        let (a, r) = (Arc::clone(&andamento), Arc::clone(&revisao));
        let fio = std::thread::Builder::new()
            .name("cameras-virtuais".into())
            .spawn(move || correr(rx, a, r))
            .ok();
        if fio.is_none() {
            registro::linha("cameras virtuais: o fio não subiu; nenhuma câmera será criada");
        }
        FioDasCameras { pedidos: tx, andamento, revisao, fio: Mutex::new(fio) }
    }

    /// As câmeras que devem existir, por nome. O fio faz a diferença ([`planejar`]).
    pub fn querer(&self, nomes: Vec<String>) {
        let _ = self.pedidos.send(Pedido::Querer(nomes));
    }

    pub fn andamento(&self) -> Andamento {
        self.andamento.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Sobe a cada mudança do [`Andamento`]: é por ela que a janela sabe que precisa redesenhar.
    pub fn revisao(&self) -> u64 {
        self.revisao.load(Ordering::Relaxed)
    }

    /// Solta todas as câmeras e termina o fio, esperando no máximo 5 s (ver o cabeçalho).
    /// Chamar duas vezes não faz mal.
    pub fn encerrar(&self) {
        let Some(fio) = self.fio.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
        let (ok, feito) = mpsc::channel();
        if self.pedidos.send(Pedido::Encerrar(ok)).is_err() {
            let _ = fio.join();
            return;
        }
        match feito.recv_timeout(Duration::from_secs(5)) {
            Ok(()) => {
                let _ = fio.join();
            }
            Err(_) => registro::linha(
                "cameras virtuais: o fio não soltou as câmeras em 5 s (consentimento pendente?); \
                 o app sai assim mesmo e a vida de sessão leva os nós",
            ),
        }
    }
}

impl Drop for FioDasCameras {
    fn drop(&mut self) {
        self.encerrar();
    }
}

fn publicar(andamento: &Mutex<Andamento>, revisao: &AtomicU64, mudar: impl FnOnce(&mut Andamento)) {
    let mut a = andamento.lock().unwrap_or_else(|e| e.into_inner());
    let antes = a.clone();
    mudar(&mut a);
    if *a != antes {
        revisao.fetch_add(1, Ordering::Relaxed);
    }
}

fn correr(rx: mpsc::Receiver<Pedido>, andamento: Arc<Mutex<Andamento>>, revisao: Arc<AtomicU64>) {
    // Apartamento multithread: o objeto da câmera vive e morre aqui, e nenhum laço de mensagens é
    // preciso para ele. Falhar aqui é raro (só se alguém já tiver posto este fio em STA, o que não
    // acontece num fio nosso); o registro diz, e as chamadas seguintes dizem o resto.
    let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if com.is_err() {
        registro::linha(format!("cameras virtuais: CoInitializeEx MTA -> {com:?}"));
    }
    let mut vivas: Vec<CameraVirtual> = Vec::new();
    while let Ok(mut pedido) = rx.recv() {
        // Pedidos em fila valem só pelo último: ligar, desligar e ligar de novo em meio segundo
        // é **um** pedido, e criar e soltar no meio seria derrubar a chamada de quem já abriu.
        while let Ok(proximo) = rx.try_recv() {
            if matches!(pedido, Pedido::Encerrar(_)) {
                break;
            }
            pedido = proximo;
        }
        match pedido {
            Pedido::Encerrar(ok) => {
                let n = vivas.len();
                vivas.clear(); // `Stop` + `Shutdown` de cada uma (`baia.rs`).
                registro::linha(format!("cameras virtuais: {n} soltas no encerramento"));
                let _ = ok.send(());
                break;
            }
            Pedido::Querer(desejadas) => {
                let nomes: Vec<String> = vivas.iter().map(|c| c.nome.clone()).collect();
                let plano = planejar(&desejadas, &nomes);
                if plano.vazio() {
                    continue;
                }
                publicar(&andamento, &revisao, |a| {
                    a.trabalhando = true;
                    // Desligar zera a falha antiga: o cartão não acusa o que já não se tenta.
                    if desejadas.is_empty() {
                        a.falha = None;
                    }
                });
                vivas.retain(|c| !plano.soltar.contains(&c.nome));
                if !plano.soltar.is_empty() {
                    registro::linha(format!("cameras virtuais: {} soltas", plano.soltar.len()));
                }
                let mut falha = None;
                for nome in &plano.criar {
                    match CameraVirtual::criar(nome) {
                        Ok(c) => vivas.push(c),
                        Err(erro) => {
                            let codigo = erro.downcast_ref::<windows::core::Error>().map(|w| w.code().0 as u32);
                            falha = Some(codigo.map_or(Falha::Outra(0), classificar));
                            registro::linha(format!("camera virtual (nome omitido): não subiu — {erro:#}"));
                        }
                    }
                }
                let nomes: Vec<String> = vivas.iter().map(|c| c.nome.clone()).collect();
                registro::linha(format!("cameras virtuais: {} de pé", nomes.len()));
                let tentou = !plano.criar.is_empty();
                publicar(&andamento, &revisao, |a| {
                    a.vivas = nomes;
                    a.trabalhando = false;
                    // A falha é a da última tentativa: uma recusa de privacidade consertada nos
                    // Ajustes do Windows some na próxima vez que o interruptor for ligado.
                    if tentou {
                        a.falha = falha;
                    }
                });
            }
        }
    }
    drop(vivas);
    if com.is_ok() {
        unsafe { CoUninitialize() };
    }
}
