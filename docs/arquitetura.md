# Arquitetura

| Caminho | Responsabilidade |
|---|---|
| `crates/quall-core` | Protocolo, descoberta, pareamento, sinalização e sessões. |
| `crates/quall-rtc` | Transporte de mídia com libdatachannel e dependências nativas. |
| `crates/quall-opus` | Áudio Opus. |
| `crates/quall-ffi` | Fronteira C e header gerado em `include/quall.h`. |
| `apps/windows` | Rust/Win32 e APIs Windows de captura/apresentação. |
| `apps/macos` | Swift/SwiftUI/AppKit, ScreenCaptureKit e VideoToolbox. |
| `apps/ios/Quall` | App Swift e extensão ReplayKit. |
| `apps/android` | Kotlin, JNI C e APIs Android de câmera, captura e codecs. |
| `integrations/camera-macos` | Extensão CoreMediaIO e app hospedeiro. |
| `integrations/camera-windows` | Câmera Media Foundation, fonte e sondas. |
| `plugins/obs` | Fonte nativa do OBS distribuída separadamente. |
| `tools` | Conferidores e instrumentos de diagnóstico. |

As interfaces cuidam de captura, permissões e ciclo de vida nativos. App e extensão iOS executam
em processos distintos; dados compartilhados usam o App Group configurado no projeto.

Consumidores devem usar o header correspondente ao núcleo realmente linkado. Mudanças em
estruturas, ownership ou buffers exigem conferir todos os consumidores. Não misture bibliotecas
de arquitetura, plataforma ou perfil diferentes.

Apps/núcleo próprios autorizados usam MPL-2.0. A combinação OBS usa GPL-3.0-or-later, com MPL §3.3
quando aplicável. Preserve terceiros; consulte [escopo](../LICENSE-SCOPE.md) e
[inventário](distribuicao/licencas.md).
