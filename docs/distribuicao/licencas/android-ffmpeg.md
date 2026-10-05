# Dependências Android e FFmpeg

Os inventários portáteis registram coordenadas, versões, POMs oficiais, licenças e hashes da
resolução de referência. Não contêm caminhos de caches privados. Não houve nova resolução,
build ou teste em aparelho nesta revisão do snapshot.

Os módulos Gradle de runtime registrados usam Apache-2.0. CameraX incorpora libyuv BSD:
seu aviso é preservado, mas o POM não identifica a revisão incorporada. JUnit/Hamcrest são
ferramentas de testes. O NDK possui avisos libc++/libc++abi/libunwind/compiler-rt próprios;
nenhum runtime compilado é incluído aqui.

FFmpeg 9.0.1: `fontes/ffmpeg-9.0.1.tar.xz`, SHA256
`cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`, com assinatura destacada
e chave pública upstream. Receita canônica:
[apps/android/tools/compila-ffmpeg-dv.sh](../../../apps/android/tools/compila-ffmpeg-dv.sh).
O archive foi examinado: referências `tests/ref/*.mp4/*.png` são texto, não mídia; o marcador
PRIVATE KEY em `tls_openssl.c` é exemplo com reticências, não chave. Um caminho numa referência
foi publicado pelo upstream, não pertence à bancada Quall.

A receita seleciona bibliotecas dinâmicas sem GPL/nonfree/codecs externos, sob LGPL-2.1-or-later.
O fonte upstream completo conserva os termos dos componentes opcionais. Sua inclusão não
comprova equivalência com binário histórico nem build do snapshot.

Os avisos conservam IJG, Rich Felker, MIPS Technologies, Theodore Ts’o, Boost, Steve Reid e
Aaron Gifford. A revisão-base exata do SHA2 incorporado não foi identificada. Crédito IJG:
**This software is based in part on the work of the Independent JPEG Group.**

Uma release deve oferecer fonte exato/receita, avisos, modificação/engenharia reversa para depurar
a biblioteca e substituição conforme LGPL. Essa troca não foi testada no pacote final nesta
revisão. Copyright não constitui liberação universal de patentes. [FFmpeg](https://ffmpeg.org/legal.html).
