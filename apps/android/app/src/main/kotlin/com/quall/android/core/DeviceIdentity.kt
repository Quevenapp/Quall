package com.quall.android.core

import android.content.Context
import android.os.Build
import java.util.UUID

/**
 * Quem este aparelho é para o outro lado, e o que ele já pareou.
 *
 * O `device_id` é o que o pareamento vincula (ver `QuallDeviceDesc` em `quall.h`) — não o nome,
 * que o usuário pode trocar. Ele precisa **sobreviver a reinício do app**, senão cada sessão
 * seria um par novo e o PIN voltaria a ser pedido toda vez, o que quebra a promessa de "parear
 * uma vez" do PROMPT.md.
 *
 * `SharedPreferences` e não arquivo: é o armazenamento privado do app, some na desinstalação
 * (que é o comportamento certo para um segredo de pareamento) e não custa dependência nenhuma.
 */
class DeviceIdentity private constructor(
    private val prefs: android.content.SharedPreferences,
    val deviceId: String,
    val displayName: String,
) {
    companion object {
        private const val ARQUIVO = "quall-identidade"
        private const val CHAVE_ID = "device_id"
        private const val CHAVE_PARES = "known_peers_json"

        fun load(context: Context): DeviceIdentity {
            val prefs = context.applicationContext
                .getSharedPreferences(ARQUIVO, Context.MODE_PRIVATE)
            var id = prefs.getString(CHAVE_ID, null)
            if (id.isNullOrBlank()) {
                // Sorteado uma vez, na primeira execução. `Build.SERIAL` e o ANDROID_ID seriam
                // identificadores de aparelho de verdade — e é justamente por isso que não são
                // usados: o Quall não precisa saber qual celular é este, só distinguir um par do
                // outro dentro da LAN.
                id = "android-" + UUID.randomUUID().toString().take(8)
                prefs.edit().putString(CHAVE_ID, id).apply()
            }
            // `Build.MODEL` é o nome que a pessoa reconhece na lista do outro aparelho
            // ("SM-A107M"). Sem `MANUFACTURER` junto porque em quase todo aparelho da bancada ele
            // já vem embutido no modelo, e o rótulo fica longo à toa.
            val nome = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
            // Prefixo de bancada (vazio em produto): a rede da bancada é compartilhada entre
            // frentes, e sem prefixo dois aparelhos de rodadas diferentes se acham por mDNS.
            return DeviceIdentity(prefs, id, Bancada.prefixoDeNome(context) + nome)
        }
    }

    /** Estado de pareamento persistido, ou `null` na primeira vez. */
    fun knownPeersJson(): String? = prefs.getString(CHAVE_PARES, null)?.takeIf { it.isNotBlank() }

    /**
     * `true` se este aparelho já pareou com **algum** outro antes — nunca "com este", que a
     * casca não sabe até o receptor tentar. É o gatilho da manchete condicional da tela de
     * espera (`docs/ux-m6.md`, tarefa 1): PIN grande quando não há nenhum par conhecido,
     * "aparelhos pareados entram direto" quando há. O formato vem de `PairedPeers::to_json`
     * (`crates/quall-core/src/pairing.rs`): `{"pares": {"<device_id>": {...}, ...}}` — presente e
     * não vazio é o teste, e `org.json` (já usado em `QuallBrowser`/`MirrorService`) evita
     * inventar um parser de string para isso.
     */
    fun temParesConhecidos(): Boolean {
        val json = knownPeersJson() ?: return false
        return runCatching {
            org.json.JSONObject(json).optJSONObject("pares")?.length() ?: 0
        }.getOrDefault(0) > 0
    }

    /** Grava o estado que veio de `quall_session_known_peers_json`. */
    fun saveKnownPeersJson(json: String) {
        if (json.isBlank()) return
        prefs.edit().putString(CHAVE_PARES, json).apply()
    }

    /** Esquece todos os pares: a próxima sessão volta a pedir PIN. */
    fun forgetPeers() {
        prefs.edit().remove(CHAVE_PARES).apply()
    }
}
