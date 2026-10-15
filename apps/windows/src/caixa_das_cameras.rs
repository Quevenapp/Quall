//! **A lista das câmeras deste computador** (pedido do Bruno, 13/10/2026: *"mesmo excluindo os
//! pareamentos não tem opção de excluir as câmeras já conectadas"*): o "Gerenciar câmeras" dos
//! Ajustes abre esta caixa. Uma opção por câmera (por nome; "em uso agora" quando um app lê), e os
//! botões "Remover", "Remover todas" e "Fechar". O texto diz que remover não desfaz o pareamento e
//! que a câmera volta quando o aparelho transmitir de novo.
//!
//! Um `TaskDialog`, como as caixas do instalador da câmera: a janela principal é fixa e o cartão
//! dos Ajustes não tem lugar para uma linha por câmera (as telas sem rolagem, R16). A regra (quem
//! sai do `baias.json`, a frase) mora em `regras_da_camera_virtual.rs`; aqui só se pergunta.

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Controls::{
    TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOG_BUTTON, TDF_ALLOW_DIALOG_CANCELLATION, TDF_POSITION_RELATIVE_TO_WINDOW,
};

use crate::idioma::{t, tf};
use crate::registro;
use crate::regras_da_camera_virtual::{self as regras, LinhaDaCamera};

/// O que a pessoa escolheu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Escolha {
    Nada,
    Remover(String),
    RemoverTodas,
}

const ID_REMOVER: i32 = 1000;
const ID_REMOVER_TODAS: i32 = 1001;
const ID_FECHAR: i32 = 1002;
const PRIMEIRA_OPCAO: i32 = 2000;

fn largo(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Abre a caixa e devolve a escolha. Sem câmera nenhuma, nem abre.
pub fn perguntar(hwnd: HWND, linhas: &[LinhaDaCamera]) -> Escolha {
    if linhas.is_empty() {
        return Escolha::Nada;
    }
    let titulo = largo(t(regras::CAMERAS_TITULO));
    let pergunta = largo(t(regras::CAIXA_CAMERAS_PERGUNTA));
    let corpo = largo(t(regras::CAIXA_CAMERAS_CORPO));
    let rotulos: Vec<Vec<u16>> = linhas
        .iter()
        .map(|l| largo(&tf(if l.em_uso { regras::CAIXA_CAMERAS_LINHA_EM_USO } else { regras::CAIXA_CAMERAS_LINHA }, &[&l.nome])))
        .collect();
    let opcoes: Vec<TASKDIALOG_BUTTON> = rotulos
        .iter()
        .enumerate()
        .map(|(i, r)| TASKDIALOG_BUTTON { nButtonID: PRIMEIRA_OPCAO + i as i32, pszButtonText: PCWSTR(r.as_ptr()) })
        .collect();
    let (remover, todas, fechar) =
        (largo(t(regras::CAIXA_CAMERAS_REMOVER)), largo(t(regras::CAIXA_CAMERAS_REMOVER_TODAS)), largo(t(regras::CAIXA_CAMERAS_FECHAR)));
    let botoes = [
        TASKDIALOG_BUTTON { nButtonID: ID_REMOVER, pszButtonText: PCWSTR(remover.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_REMOVER_TODAS, pszButtonText: PCWSTR(todas.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: ID_FECHAR, pszButtonText: PCWSTR(fechar.as_ptr()) },
    ];
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        hwndParent: hwnd,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
        pszWindowTitle: PCWSTR(titulo.as_ptr()),
        pszMainInstruction: PCWSTR(pergunta.as_ptr()),
        pszContent: PCWSTR(corpo.as_ptr()),
        cButtons: botoes.len() as u32,
        pButtons: botoes.as_ptr(),
        // O padrão é Fechar: o Enter sem ler não remove nada.
        nDefaultButton: ID_FECHAR,
        cRadioButtons: opcoes.len() as u32,
        pRadioButtons: opcoes.as_ptr(),
        nDefaultRadioButton: PRIMEIRA_OPCAO,
        ..Default::default()
    };
    let mut botao = 0i32;
    let mut opcao = 0i32;
    match unsafe { TaskDialogIndirect(&config, Some(&mut botao), Some(&mut opcao), None) } {
        Ok(()) => {
            let escolha = match botao {
                ID_REMOVER => usize::try_from(opcao - PRIMEIRA_OPCAO)
                    .ok()
                    .and_then(|i| linhas.get(i))
                    .map_or(Escolha::Nada, |l| Escolha::Remover(l.nome.clone())),
                ID_REMOVER_TODAS => Escolha::RemoverTodas,
                _ => Escolha::Nada,
            };
            registro::linha(format!(
                "cameras virtuais: a lista dos Ajustes — {}",
                match &escolha {
                    Escolha::Nada => "fechada",
                    Escolha::Remover(_) => "remover uma",
                    Escolha::RemoverTodas => "remover todas",
                }
            ));
            escolha
        }
        Err(e) => {
            registro::linha(format!("cameras virtuais: !! a lista não abriu (0x{:08X})", e.code().0 as u32));
            Escolha::Nada
        }
    }
}
