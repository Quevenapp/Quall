import CoreGraphics

/// **Onde a borda arrastável da divisão pega o toque** (tela R5, "Teleprompter com câmera").
///
/// # O defeito (bancada de 27/09, iPad A16 em paisagem, 1180x820)
///
/// Relato do Pessoa Exemplo: arrastar as setas azuis do enquadramento (as marcas que delimitam a largura da
/// coluna do texto) mudava o tamanho da prévia da câmera. A borda entre o texto e a prévia tinha uma
/// zona de toque de 44 pt **centrada na linha da divisão**: 22 pt dela caíam **dentro do texto**, e
/// ela fica por cima do painel do texto na pilha. As marcas moram justamente na ponta do texto que
/// encosta na prévia (no pé, `EnquadramentoDoTexto.noPe`, ou no alto com o texto embaixo), a
/// ~12 pt da borda, com uma zona de 72 pt de altura: a borda ganhava o toque. Nos lados a lado (o
/// iPhone deitado) a marca da borda da coluna junto da prévia caía na mesma disputa.
///
/// # A regra
///
/// A zona da borda fica **inteira do lado da prévia**, encostada na linha da divisão, e nunca entra
/// no retângulo do texto: no texto, quem pega o toque são as camadas do texto (as marcas do
/// enquadramento, as setas da linha de leitura, o rolador). A alça visível continua na linha.
///
/// Pura (sem SwiftUI nem UIKit): roda em `Testes/rodar.sh`.
enum ZonaDaBordaDaDivisao {
    /// A espessura da zona de toque: 44 pt, o mínimo de alvo de toque da Apple.
    static let espessura: CGFloat = 44

    /// A zona, nas coordenadas da tela da R5, a partir dos **retângulos** do texto e da prévia (os
    /// de `TelaDoPrompterComCamera.divisao`): o lado sai da posição de um em relação ao outro, e a
    /// zona é **recortada pela prévia** — nunca cobre o texto nem a faixa dos controles (no lado a
    /// lado, a faixa mora sob a prévia; a revisão de 27/09 viu arrastos nos vãos dela mudando a
    /// divisão). Desde 30/09, no iPhone deitado, a faixa mora **ao lado** da prévia, na mesma banda
    /// (`DivisaoDaTelaComCamera`): a prévia não inclui a coluna dela, e o recorte basta — a zona
    /// encosta na linha só na largura da prévia. `nil` quando não há prévia onde pôr a zona.
    static func zona(texto: CGRect, previa: CGRect) -> CGRect? {
        let e = espessura
        let bruta: CGRect
        if texto.maxY <= previa.minY {          // texto em cima
            bruta = CGRect(x: previa.minX, y: texto.maxY, width: previa.width, height: e)
        } else if texto.minY >= previa.maxY {   // texto embaixo
            bruta = CGRect(x: previa.minX, y: texto.minY - e, width: previa.width, height: e)
        } else if texto.maxX <= previa.minX {   // texto à esquerda
            bruta = CGRect(x: texto.maxX, y: previa.minY, width: e, height: previa.height)
        } else {                                // texto à direita
            bruta = CGRect(x: texto.minX - e, y: previa.minY, width: e, height: previa.height)
        }
        let z = bruta.intersection(previa)
        return z.isNull || z.width < 1 || z.height < 1 ? nil : z
    }

    /// Em que ponta da zona fica a alça visível: a que encosta no texto.
    enum Ponta { case cima, baixo, esquerda, direita }

    static func pontaDaAlca(texto: CGRect, previa: CGRect) -> Ponta {
        if texto.maxY <= previa.minY { return .cima }
        if texto.minY >= previa.maxY { return .baixo }
        if texto.maxX <= previa.minX { return .esquerda }
        return .direita
    }
}
