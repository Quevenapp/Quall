package com.quall.android.ui

import com.quall.android.core.DeviceIdentity

/**
 * O pouco de estado de **apresentação** que atravessa as telas, no processo (e não em disco):
 *
 * - [diagnosticoLigado]: os sete toques na marca do Início (ou `diagnostico_visivel` da bancada). A
 *   tela de exibir abre o painel de números com ele (`docs/telas-estudio.md` §6.6 e §11.3).
 * - [paresDaVitrine]: só a vitrine de bancada do APK de depuração (`bancada/VitrineDasTelasActivity`)
 *   escreve, para fotografar a espera "com pares" e "sem pares" sem mexer no pareamento de verdade. No
 *   produto é sempre `null` e vale `DeviceIdentity.temParesConhecidos()`.
 * - [placaDaVitrine] e [dvdDaVitrine] (30/09): também só a vitrine escreve — um aparelho de vídeo USB e um
 *   leitor de DVD **de mentira** para as telas da placa e do DVD ([VitrineDaPlaca], [VitrineDoDvd]), para
 *   fotografar sem a placa nem o leitor plugados. Com eles, as telas não tocam no USB, não pedem nada ao
 *   dono da placa nem à sessão do DVD, e os botões não sobem serviço nenhum. No produto, sempre `null`.
 */
object EstadoDasTelas {
    @Volatile
    var diagnosticoLigado = false

    @Volatile
    var paresDaVitrine: Boolean? = null

    @Volatile
    var placaDaVitrine: VitrineDaPlaca? = null

    @Volatile
    var dvdDaVitrine: VitrineDoDvd? = null
}

/**
 * Os ids dos pares conhecidos (`{"pares": {"<device_id>": {...}}}`, `crates/quall-core/src/pairing.rs`),
 * para o selo PAREADO da lista e a contagem da folha de Ajustes. Só de leitura.
 */
fun DeviceIdentity.idsPareados(): Set<String> = runCatching {
    val pares = org.json.JSONObject(knownPeersJson() ?: return emptySet()).optJSONObject("pares") ?: return emptySet()
    pares.keys().asSequence().toSet()
}.getOrDefault(emptySet())
