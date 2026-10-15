//! **As regras do R5 no Windows que não são da gravação** (`docs/teleprompter-com-camera.md`
//! §2.4, §2.5, §4.4 e §8.10): a ordem das placas do dono da captura, a câmera "frontal" do
//! catálogo, e a leitura do consentimento do microfone. Aritmética pura, sem Win32, para os testes
//! rodarem no portão e em qualquer máquina (`rustc --test` sobre este arquivo sozinho).

/// `0x8086`.
pub const VENDOR_INTEL: u32 = 0x8086;
/// `0x10DE`.
pub const VENDOR_NVIDIA: u32 = 0x10DE;

/// **A ordem em que o dono tenta as placas** (§2.4, item 2, e a S-W1 de §8.2): a Intel primeiro — o
/// Quick Sync fez dois H.264 a 30 fps juntos, e o MFT da NVIDIA falhou com `0x8000FFFF` até sozinho
/// —, depois as outras na ordem da DXGI, e a NVIDIA por último. Recebe `(luid, fabricante)` e
/// devolve os LUIDs na ordem.
pub fn ordem_das_placas(placas: &[(u64, u32)]) -> Vec<u64> {
    let posto = |v: u32| match v {
        VENDOR_INTEL => 0u8,
        VENDOR_NVIDIA => 2,
        _ => 1,
    };
    let mut v: Vec<(usize, u64, u32)> = placas.iter().enumerate().map(|(i, (l, f))| (i, *l, *f)).collect();
    v.sort_by_key(|(i, _, f)| (posto(*f), *i));
    v.into_iter().map(|(_, l, _)| l).collect()
}

/// A câmera parece a integrada do notebook? **Pelo nome, e é hipótese** (§8.10): o catálogo não
/// distingue a embutida (o `EnclosureLocation` é do WinRT, e o app não o lê). "Integrated Webcam"
/// (Dell), "Integrated Camera" (Lenovo), "HP TrueVision", "Built-in", "Internal".
pub fn parece_integrada(nome: &str) -> bool {
    let n = nome.to_lowercase();
    ["integrated", "integrada", "built-in", "builtin", "internal", "interna", "truevision", "embutida"]
        .iter()
        .any(|p| n.contains(p))
}

/// **A câmera da tela R5** (§2.5): a lembrada, se ainda está no catálogo; senão a que parece
/// integrada; senão a primeira. Recebe `(id, nome)` das câmeras do seletor.
pub fn camera_inicial(cameras: &[(String, String)], lembrada: Option<&str>) -> Option<usize> {
    if let Some(l) = lembrada {
        if let Some(i) = cameras.iter().position(|(id, _)| id.eq_ignore_ascii_case(l)) {
            return Some(i);
        }
    }
    cameras.iter().position(|(_, nome)| parece_integrada(nome)).or(if cameras.is_empty() { None } else { Some(0) })
}

/// O que o registro diz do consentimento (`...\CapabilityAccessManager\ConsentStore\microphone`,
/// valor `Value`: `Allow` ou `Deny`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Consentimento {
    Permitido,
    Negado,
    /// A chave ou o valor não existem, ou o texto é outro.
    Desconhecido,
}

pub fn ler_consentimento(valor: Option<&str>) -> Consentimento {
    match valor.map(|v| v.trim().to_ascii_lowercase()) {
        Some(v) if v == "allow" => Consentimento::Permitido,
        Some(v) if v == "deny" => Consentimento::Negado,
        _ => Consentimento::Desconhecido,
    }
}

/// A frase da tela quando o Windows não deixa usar o microfone. **Em português, sempre**: a janela
/// a compara (`janela.rs`, `tela_r5.rs`) e a traduz na hora de mostrar (`idioma::tr`).
pub const FRASE_DA_PRIVACIDADE: &str = "O Windows não deixa este app usar o microfone. Ligue em Configurações → Privacidade e segurança → Microfone: \"Acesso ao microfone\" e \"Permitir que aplicativos da área de trabalho acessem o microfone\"."; // i18n: chave

/// `E_ACCESSDENIED`.
pub const HR_ACESSO_NEGADO: u32 = 0x8007_0005;

/// **Por que o microfone não abriu**, para a tela (§4.4): a Privacidade quando a abertura deu
/// acesso negado **ou** o registro diz `Deny` em qualquer das três chaves (a do computador, a do
/// usuário e a dos apps da área de trabalho); senão, a falha como veio. A hipótese do §4.4 é que a
/// abertura falhe com acesso negado; se ela abrir e entregar silêncio, o registro é a testemunha.
pub fn frase_do_microfone(codigo: Option<u32>, maquina: Consentimento, usuario: Consentimento, area_de_trabalho: Consentimento, falha: &str) -> String {
    let negado = [maquina, usuario, area_de_trabalho].contains(&Consentimento::Negado);
    if codigo == Some(HR_ACESSO_NEGADO) || negado {
        FRASE_DA_PRIVACIDADE.to_string()
    } else if falha.is_empty() {
        // Em português: a frase fica guardada no estado do microfone; a janela traduz ao mostrar.
        "O microfone não abriu.".to_string() // i18n: chave
    } else {
        crate::idioma::tf("O microfone não abriu: {}", &[&falha])
    }
}

/// O registro diz, de antemão, que o microfone vai ser negado?
pub fn negado_pelo_registro(maquina: Consentimento, usuario: Consentimento, area_de_trabalho: Consentimento) -> bool {
    [maquina, usuario, area_de_trabalho].contains(&Consentimento::Negado)
}

// ---------------------------------------------------------------------------------------------
// A linha do código de 4 dígitos na faixa da tela R5 (`docs/v3-no-privado.md` §3.6)
// ---------------------------------------------------------------------------------------------

/// Um retângulo da faixa, em DIP, a partir do canto de cima à esquerda dela.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetDaFaixa {
    pub x: i32,
    pub y: i32,
    pub l: i32,
    pub a: i32,
}

impl RetDaFaixa {
    pub fn direita(self) -> i32 {
        self.x + self.l
    }
    pub fn baixo(self) -> i32 {
        self.y + self.a
    }
    pub fn cruza(self, o: RetDaFaixa) -> bool {
        self.x < o.direita() && o.x < self.direita() && self.y < o.baixo() && o.y < self.baixo()
    }
}

/// A altura da faixa da tela R5: os estados (duas linhas), os avisos, a linha do código e as duas
/// fileiras de botões.
pub const FAIXA_R5: i32 = 150;
/// **A linha do código**: entre as duas linhas de estado e os avisos (4 + 2 × 22) e a primeira
/// fileira de botões (150 − 38 − 36 = 76), com 26 de altura.
pub const LINHA_DO_CODIGO_Y: i32 = 49;
pub const ALTURA_DA_LINHA_DO_CODIGO: i32 = 26;
/// Cada um dos três números ("04 27").
pub const LARGURA_DO_NUMERO: i32 = 76;
/// O "Nenhum destes", separado dos três por um espaço maior.
pub const LARGURA_DO_NENHUM: i32 = 130;
const ESPACO_ENTRE_NUMEROS: i32 = 4;
const ESPACO_ATE_O_NENHUM: i32 = 14;
/// O "Travar em 30 fps" da faixa (`controles-de-camera.md` §3.1.1): no fim da linha dos avisos.
pub const LARGURA_DO_TRAVAR_FPS: i32 = 150;

/// **Onde fica cada peça da linha do código**: a frase à esquerda, os três números e o "Nenhum
/// destes" à direita, na ordem do núcleo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinhaDoCodigo {
    pub frase: RetDaFaixa,
    pub numeros: [RetDaFaixa; 3],
    pub nenhum: RetDaFaixa,
}

/// A linha do código numa faixa de `largura` DIP. Os botões encostam na direita (8 da borda); a frase
/// vai de 12 até 12 antes do primeiro número (e corta com reticências se faltar lugar).
pub fn linha_do_codigo(largura: i32) -> LinhaDoCodigo {
    let (y, a) = (LINHA_DO_CODIGO_Y, ALTURA_DA_LINHA_DO_CODIGO);
    let nenhum = RetDaFaixa { x: largura - 8 - LARGURA_DO_NENHUM, y, l: LARGURA_DO_NENHUM, a };
    let mut x = nenhum.x - ESPACO_ATE_O_NENHUM - 3 * LARGURA_DO_NUMERO - 2 * ESPACO_ENTRE_NUMEROS;
    let numeros = [0, 1, 2].map(|_| {
        let r = RetDaFaixa { x, y, l: LARGURA_DO_NUMERO, a };
        x += LARGURA_DO_NUMERO + ESPACO_ENTRE_NUMEROS;
        r
    });
    let frase = RetDaFaixa { x: 12, y, l: (numeros[0].x - 12 - 12).max(0), a };
    LinhaDoCodigo { frase, numeros, nenhum }
}

/// O "Travar em 30 fps", na linha dos avisos (de 26 a 48), numa faixa de `largura`.
pub fn travar_fps_na_faixa(largura: i32) -> RetDaFaixa {
    RetDaFaixa { x: largura - 12 - LARGURA_DO_TRAVAR_FPS, y: 4 + 22, l: LARGURA_DO_TRAVAR_FPS, a: 22 }
}

/// A primeira fileira de botões da faixa (os comandos do prompter), que a linha do código não pode
/// invadir.
pub fn primeira_fileira(largura: i32) -> RetDaFaixa {
    RetDaFaixa { x: 8, y: FAIXA_R5 - 38 - 36, l: largura - 16, a: 30 }
}

#[cfg(test)]
mod testes {
    use super::*;

    /// **Nenhum controle cobre outro** na faixa da R5 com o código na tela, das larguras pequenas às
    /// largas; e os rótulos cabem nos botões, em português e em inglês.
    #[test]
    fn a_linha_do_codigo_na_faixa_nao_cobre_nada() {
        for largura in [640, 720, 900, 1280, 1920, 3840] {
            let l = linha_do_codigo(largura);
            let travar = travar_fps_na_faixa(largura);
            let fileira = primeira_fileira(largura);
            let botoes: Vec<RetDaFaixa> = l.numeros.iter().copied().chain([l.nenhum]).collect();
            for (i, a) in botoes.iter().enumerate() {
                assert!(a.x >= 0 && a.direita() <= largura, "{largura}: {a:?} fora da faixa");
                assert!(!a.cruza(travar) && !a.cruza(fileira) && !a.cruza(l.frase), "{largura}: {a:?}");
                for b in botoes.iter().skip(i + 1) {
                    assert!(!a.cruza(*b), "{largura}: {a:?} cobre {b:?}");
                }
            }
            assert!(!l.frase.cruza(travar) && !l.frase.cruza(fileira));
            assert!(l.numeros[0].direita() < l.numeros[1].x && l.numeros[1].direita() < l.numeros[2].x, "na ordem do núcleo");
            assert!(l.numeros[2].direita() + 8 <= l.nenhum.x, "o Nenhum destes, separado");
            assert!(l.frase.l >= 120, "{largura}: a frase tem lugar ({})", l.frase.l);
            assert!(l.frase.baixo() < fileira.y && travar.baixo() < l.frase.y);
        }
        use crate::estilo::{largura_estimada, F_BOTAO, F_CORPO_FORTE};
        for idioma in [crate::idioma::Idioma::Pt, crate::idioma::Idioma::En] {
            crate::idioma::com_idioma(idioma, || {
                let nenhum = crate::idioma::t("Nenhum destes");
                assert!(largura_estimada(nenhum, F_BOTAO) + 16.0 <= LARGURA_DO_NENHUM as f32, "{idioma:?}: {nenhum:?}");
            });
        }
        assert!(largura_estimada("04 27", F_CORPO_FORTE) + 12.0 <= LARGURA_DO_NUMERO as f32);
    }

    #[test]
    fn a_intel_primeiro_e_a_nvidia_por_ultimo() {
        let placas = [(1, VENDOR_NVIDIA), (2, VENDOR_INTEL), (3, 0x1002)];
        assert_eq!(ordem_das_placas(&placas), vec![2, 3, 1]);
        assert_eq!(ordem_das_placas(&[(9, VENDOR_NVIDIA)]), vec![9], "só a NVIDIA: ela mesma");
        assert!(ordem_das_placas(&[]).is_empty());
        // duas Intel (o SudoVDA não entra: `placas_de_hardware` já pula as indiretas) mantêm a ordem
        assert_eq!(ordem_das_placas(&[(5, VENDOR_INTEL), (4, VENDOR_INTEL)]), vec![5, 4]);
    }

    #[test]
    fn a_camera_da_tela() {
        let c = |v: &[(&str, &str)]| v.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect::<Vec<_>>();
        let lista = c(&[("usb#canon", "Canon EOS"), ("usb#int", "Integrated Webcam"), ("usb#gs", "Panasonic GS500")]);
        assert_eq!(camera_inicial(&lista, None), Some(1), "a integrada, sem lembrada");
        assert_eq!(camera_inicial(&lista, Some("USB#GS")), Some(2), "a lembrada, sem caixa");
        assert_eq!(camera_inicial(&lista, Some("sumiu")), Some(1), "a lembrada que saiu cai na integrada");
        let sem = c(&[("a", "Canon EOS"), ("b", "Logitech C920")]);
        assert_eq!(camera_inicial(&sem, None), Some(0));
        assert_eq!(camera_inicial(&[], None), None);
        assert!(parece_integrada("HP TrueVision HD Camera"));
        assert!(!parece_integrada("Logitech BRIO"));
    }

    #[test]
    fn o_consentimento_e_a_frase() {
        use Consentimento::*;
        assert_eq!(ler_consentimento(Some("Allow")), Permitido);
        assert_eq!(ler_consentimento(Some(" deny ")), Negado);
        assert_eq!(ler_consentimento(Some("Prompt")), Desconhecido);
        assert_eq!(ler_consentimento(None), Desconhecido);
        assert_eq!(frase_do_microfone(Some(HR_ACESSO_NEGADO), Desconhecido, Desconhecido, Desconhecido, "x"), FRASE_DA_PRIVACIDADE);
        assert_eq!(frase_do_microfone(None, Permitido, Permitido, Negado, "x"), FRASE_DA_PRIVACIDADE);
        assert_eq!(frase_do_microfone(Some(1), Permitido, Permitido, Permitido, "x"), "O microfone não abriu: x");
        assert!(negado_pelo_registro(Negado, Permitido, Permitido));
        assert!(!negado_pelo_registro(Desconhecido, Permitido, Desconhecido));
    }

    /// Em inglês: a frase com a falha nasce traduzida; a da privacidade fica a chave em português
    /// (comparada pela janela) e tem o par na tabela.
    #[test]
    fn a_frase_do_microfone_em_ingles() {
        use Consentimento::*;
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            assert_eq!(frase_do_microfone(Some(1), Permitido, Permitido, Permitido, "x"), "The microphone didn't open: x");
            assert_eq!(frase_do_microfone(None, Negado, Permitido, Permitido, "x"), FRASE_DA_PRIVACIDADE);
            assert!(crate::idioma::tr(FRASE_DA_PRIVACIDADE).starts_with("Windows isn't letting this app use the microphone."));
        });
    }
}
