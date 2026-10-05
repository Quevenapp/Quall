import Foundation
import UIKit

/// O que este aparelho é, em texto, para o relato de uma corrida de recepção.
///
/// # Por que isto é uma extensão, e não um `enum Identidade` próprio
///
/// Até a unificação existiam **duas** identidades em `apps/ios`: a do emissor
/// (`Comum/Identidade.swift`, no App Group, sem UIKit porque é compilada dentro da appex) e a do
/// receptor (`ios-rx-…` / `rx-ios-…`, em `UserDefaults.standard`). Dois apps, dois bundle ids,
/// duas identidades — e o outro lado da rede via o mesmo aparelho físico como duas coisas
/// diferentes, cada uma com o seu pareamento.
///
/// Num app só isso deixa de fazer sentido e vira defeito: `docs/fluxo-de-uso.md` promete "o
/// receptor vê o aparelho uma vez só" e "PIN uma vez por par de aparelhos". Com duas identidades,
/// parear para espelhar não valia para exibir. Agora há **um** `device_id` e **um** nome, os do
/// emissor, e o pareamento é o mesmo arquivo do App Group nos dois papéis.
///
/// O que sobra aqui é só o que precisa de UIKit — e **é por isso que este arquivo mora em
/// `Receber/` e não em `Comum/`**. `Comum/` é compilado dentro da Broadcast Upload Extension,
/// onde a regra medida deste projeto é "nada de UIKit, CoreImage, Metal ou GPU" (o caminho errado
/// de reescalonamento custou 30 MB contra 0,1 MB). `Receber/` entra só no alvo do app.
extension Identidade {

    /// `iPad15,7`, `iPhone10,6` — o identificador de hardware, e não o nome comercial.
    ///
    /// A regra do projeto é que aparelho que não aparece no relato não foi testado, e "iPad" não
    /// identifica aparelho nenhum: esta bancada tem dois modelos de iPad citados nos documentos.
    static func maquina() -> String {
        var sistema = utsname()
        uname(&sistema)
        let bytes: [UInt8] = withUnsafeBytes(of: &sistema.machine) { Array($0) }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Os pixels do painel, em retrato (`nativeBounds` não gira com o aparelho): 1125 × 2436 no
    /// iPhone X, 750 × 1334 no 7. Vão no aperto de mão para a tela estendida do Mac dar ao monitor o
    /// formato desta tela.
    ///
    /// **Medido uma vez, na main**, por `QuallApp.init` — a sessão de recepção corre numa thread
    /// própria, e UIKit não se lê fora da main.
    static private(set) var telaNativa: (largura: UInt32, altura: UInt32) = (0, 0)

    static func medirTelaNativa() {
        let b = UIScreen.main.nativeBounds.size
        telaNativa = (UInt32(max(0, b.width.rounded())), UInt32(max(0, b.height.rounded())))
    }

    static func descricaoDoAparelho() -> String {
        "\(maquina()) — \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    // --- a armadilha da família de alvo -----------------------------------------------------------

    /// A tela **em pontos**, o fator de escala, e se o app está rodando em modo de compatibilidade
    /// de iPhone.
    ///
    /// # Por que isto é uma linha do relato e não um detalhe
    ///
    /// Antes da unificação o app do emissor declarava `TARGETED_DEVICE_FAMILY: "1"` — só iPhone.
    /// Instalado no iPad, o iPadOS o abria numa janela de compatibilidade de iPhone e o app
    /// **reportava 750x1334**, que não é a tela do iPad. A medição de 2026-08-26 registrou
    /// exatamente isso.
    ///
    /// Para quem emite, a família de alvo muda o que se codifica. Para quem **exibe** numa tela
    /// grande, ela muda a única coisa que o produto entrega: em compatibilidade, a imagem de
    /// 720x1280 seria composta contra 375x667 pt e a folga do iPad ficaria preta.
    ///
    /// **Um app só não pode ter duas famílias de alvo**, e a que serve aos dois papéis é `"1,2"` —
    /// é o que o `project.yml` declara agora, no app **e** na appex (uma appex embarcada com
    /// família menor que a do app não instala). Esta linha existe para que a diferença apareça
    /// como **número** na saída de toda corrida, em vez de como suspeita. A heurística de
    /// "compatibilidade": o `userInterfaceIdiom` diz `.phone` num aparelho cujo `machine` começa
    /// com `iPad`. Não há API que responda isso diretamente.
    static func descricaoDaTela() -> String {
        let tela = UIScreen.main.bounds.size
        let escala = UIScreen.main.scale
        let idioma: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: idioma = "phone"
        case .pad: idioma = "pad"
        default: idioma = "outro(\(UIDevice.current.userInterfaceIdiom.rawValue))"
        }
        let ehIpad = maquina().hasPrefix("iPad")
        let compatibilidade = ehIpad && UIDevice.current.userInterfaceIdiom == .phone
        return String(format: "%.0fx%.0f pt @%.0fx = %.0fx%.0f px, idiom=%@%@",
                      tela.width, tela.height, escala,
                      tela.width * escala, tela.height * escala, idioma,
                      compatibilidade ? " **MODO DE COMPATIBILIDADE DE IPHONE**" : "")
    }
}
