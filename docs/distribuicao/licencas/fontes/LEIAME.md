# Fontes incluídos no snapshot

Destino confirmado: [Quevenapp/Quall](https://github.com/Quevenapp/Quall), repositório público
da organização Quevenapp. A seleção foi autorizada para publicação; isso não confirma upload,
release binária, build ou teste em aparelho.

| Material presente | Procedência |
|---|---|
| `datachannel-0.16.1.crate` | Crate oficial, checksum do lock; 19 arquivos regulares examinados. |
| `webrtc-sdp-0.3.14.crate` e `webrtc-sdp-0.3.15.crate` | Crates oficiais, checksums dos locks; 68 arquivos regulares examinados em cada um. |
| `ffmpeg-9.0.1.tar.xz` | Fonte oficial completo, 10.397 arquivos regulares; licenças e referências de testes em texto. |
| `ffmpeg-9.0.1.tar.xz.asc`, `ffmpeg-release.asc` | Assinatura destacada e chave pública upstream. Não são chave privada ou assinatura de app Quall. |
| `manifesto.json` | Hashes dos arquivos presentes e da árvore selecionada do fork. |
| `vendor/datachannel-sys/` na raiz | Fonte MPL modificado, dependências e avisos, com exclusões em `PUBLIC-SOURCE.md`. |

`.crate` é tar.gz com extensão crates.io. Os archives examinados não têm caminhos de extração
absolutos, traversal ou links. Copyrights/emails públicos legítimos upstream foram preservados.
O antigo archive do fork não é incluído: continha assets e containers omitidos. Use a árvore,
locks e patches selecionados. Demais crates são fixados nos locks e obtidos dos registros
públicos indicados pelo inventário, preservando seus termos. Receita FFmpeg canônica:
[apps/android/tools/compila-ffmpeg-dv.sh](../../../../apps/android/tools/compila-ffmpeg-dv.sh).

Este material identifica a seleção de fontes; não comprova correspondência com binários
históricos, build, substituição LGPL testada ou oferta completa de fonte de release futura.
Testes upstream não são oferecidos completos; seus recursos omitidos não são inputs runtime.
