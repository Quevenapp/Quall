package com.quall.android

/**
 * Espelha `EncodePreset` de `crates/quall-core/src/protocol.rs` (propriedade da Frente 1 —
 * aquele arquivo não é editado por aqui, só lido). Tela é conteúdo estático com mudanças
 * bruscas — prioriza nitidez; câmera é ruído de sensor com movimento contínuo — prioriza
 * fluidez. O valor de [json] precisa ficar minúsculo: é a chave `header.preset` do
 * `docs/contrato-sidecar.md`.
 */
enum class EncodePreset(val json: String) {
    SCREEN("screen"),
    CAMERA("camera"),
}
