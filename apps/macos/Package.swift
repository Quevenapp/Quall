// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuallCapture",
    // O português é o texto-fonte (`docs/traducao.md`, "macOS"); a tabela inglesa é recurso de
    // `QuallIdiomaKit`.
    defaultLocalization: "pt",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Primeira release: só monitores existentes. Os fontes do monitor virtual permanecem
        // no checkout, fora deste grafo. Ver docs/distribuicao/macos-store.md para os vínculos
        // que uma frente futura teria de restaurar; a Store não compila API privada nem auxiliar.
        // **Os dois idiomas** (`docs/traducao.md`, "macOS"): `T("frase em português")` devolve a frase
        // no idioma da vez, e o seletor PT | EN da tela inicial troca na hora. Sem dependência nenhuma,
        // para todo alvo que mostra texto poder usá-lo. O `Localizable.strings` inglês vai num pacote
        // de recursos que `Empacotar/empacotar.sh` copia para dentro do `.app`.
        .target(
            name: "QuallIdiomaKit",
            path: "Sources/QuallIdiomaKit",
            resources: [.process("Recursos")]
        ),
        .target(
            name: "QuallCaptureKit",
            dependencies: ["QuallIdiomaKit"],
            path: "Sources/QuallCaptureKit",
            exclude: ["MonitorVirtual.swift", "MonitorVirtualAuxiliar.swift", "TabelaDeIndices.swift"]
        ),
        .executableTarget(
            name: "quall-capture",
            dependencies: ["QuallCaptureKit"],
            path: "Sources/quall-capture"
        ),
        // Sonda de bancada: que nível de H.264 o `H264Encoder` produz por resolução, lido do
        // Annex-B e não de propriedade de sessão. Origem sintética; não captura tela nenhuma.
        .executableTarget(
            name: "sonda-sps",
            dependencies: ["QuallCaptureKit"],
            path: "Sources/sonda-sps"
        ),
        // Sonda de bancada: empurra uma origem **sintética crua** pelo `H264Encoder` do produto
        // para que o que sai possa ser decodificado e medido em PSNR/SSIM. É o que faltava para
        // o emissor do macOS ser provado em pixels, e não só no nível do bitstream — sem
        // capturar tela nenhuma. Ver `tools/qualidade-de-imagem.py`.
        .executableTarget(
            name: "sonda-qualidade",
            dependencies: ["QuallCaptureKit"],
            path: "Sources/sonda-qualidade"
        ),
        // Sonda de bancada que responde a uma pergunta de arquitetura sem rede e sem aparelho:
        // **um decodificador de plataforma aceita unidade de acesso com fatias faltando?** Liga
        // `kVTCompressionPropertyKey_MaxH264SliceBytes`, confere no bitstream que o botão pegou,
        // trunca o IDR na cabeça e alimenta um `VTDecompressionSession`. Origem sintética; não
        // captura nem abre imagem nenhuma. Ver `docs/idr-pequeno.md`.
        .executableTarget(
            name: "sonda-fatias",
            dependencies: ["QuallCaptureKit"],
            path: "Sources/sonda-fatias"
        ),
        // Empresta `crates/quall-ffi/include/quall.h` para o Swift sem copiá-lo — ver o
        // comentário em `Sources/CQuall/module.modulemap`. Alvo `systemLibrary`: só declara a
        // API, quem linka o `.a` de verdade é o executável que a usa (mesmo padrão que
        // `apps/ios/Quall/project.yml` já usa com `OTHER_LDFLAGS` apontando pro `.a` inteiro).
        .systemLibrary(
            name: "CQuall",
            path: "Sources/CQuall"
        ),
        // A ponte de rede que `apps/macos` nunca teve (M6) — ver `docs/ux-m6.md`, seção 4.
        // `quall-capture`/`QuallCaptureKit` continuam sem depender disto: captura+encode não
        // precisa de rede para ser testado, e não deveria passar a precisar.
        //
        // Desde 2026-08-30 ele tem as **duas** metades: `NucleoDeRede` hospeda e emite,
        // `NucleoReceptor` conecta e recebe. Ver `docs/receptor-macos.md`.
        .target(
            name: "QuallNetKit",
            // `QuallReceptorKit` pela S4 do som: a porta puxada (`PortaDeSom`) entrega slots ao
            // motor (`Tocador`), que mora lá sem depender de `CQuall`.
            dependencies: ["CQuall", "QuallTeleprompterKit", "QuallReceptorKit"],
            path: "Sources/QuallNetKit"
        ),
        // **O teleprompter sem rede e sem janela** (`docs/contrato-teleprompter.md`): o estado lido
        // do JSON do núcleo, o laço da sessão com a ordem do fim, a geometria e a rolagem, a quebra
        // de linhas pelo CoreText e a regra do texto que chega com o editor aberto. Não depende de
        // `CQuall` pela mesma decisão de `QuallReceptorKit`: o que é lógica de tela se testa sem o
        // `.a` existir. A ponte com a fronteira C mora em `QuallNetKit`; as telas, em `QuallApp`.
        .target(
            name: "QuallTeleprompterKit",
            dependencies: ["QuallIdiomaKit"],
            path: "Sources/QuallTeleprompterKit"
        ),
        // Decodificar e exibir. **Não depende de `CQuall`**, e isso é a mesma decisão que mantém
        // `QuallCaptureKit` fora da rede, aplicada ao outro sentido: decode+exibição não precisa
        // de rede para ser testado, e não deveria passar a precisar. O efeito prático é que
        // `QuallReceptorKitTests` roda sem `target/release/libquall.a` existir.
        .target(
            name: "QuallReceptorKit",
            dependencies: ["QuallIdiomaKit"],
            path: "Sources/QuallReceptorKit"
        ),
        // **O ícone na barra de menus** (01/10, `docs/app-macos.md`, "Barra de menus"): a marca desenhada
        // por código, as frases do menu e as duas regras do minimizar (a janela e o Dock). Sem `CQuall`
        // e sem os modelos do app, pela mesma decisão de `QuallReceptorKit`: o que é lógica de tela se
        // testa sem o `.a` existir. Quem lê o `Emissor`, o `Receptor` e o `Teleprompter` e mexe nas
        // janelas é `QuallApp/BarraDeMenus.swift`.
        .target(
            name: "QuallBarraDeMenusKit",
            dependencies: ["QuallIdiomaKit"],
            path: "Sources/QuallBarraDeMenusKit"
        ),
        .executableTarget(
            name: "quall-net-smoke",
            // `QuallCaptureKit` pela prova do controle remoto da câmera (`camera-remota`): as capacidades e o
            // pedido do Mac são puros de lá. Nenhuma captura abre.
            dependencies: ["QuallNetKit", "CQuall", "QuallCaptureKit"],
            path: "Sources/quall-net-smoke",
            linkerSettings: [
                // O arquivo **inteiro**, por caminho — não `-lquall` com `LIBRARY_SEARCH_PATHS`.
                // Mesmo motivo do comentário em `apps/ios/Quall/project.yml`: o `crate-type` do
                // `quall-ffi` inclui `cdylib`, então `cargo` põe `.a` **e** `.dylib` na mesma
                // pasta, e o linker prefere o dinâmico — que carrega um caminho absoluto deste
                // MacBook e não existiria em outra máquina.
                .unsafeFlags([
                    "../../target/release/libquall.a",
                    "-lc++",
                ])
            ]
        ),
        // **O app de produto** (`docs/app-macos.md`). Até o M6 este diretório era biblioteca mais
        // duas CLIs de bancada; esta é a janela que uma pessoa abre. O binário sozinho não serve:
        // ele precisa ser embrulhado num `.app` assinado por `Empacotar/empacotar.sh`, senão o
        // TCC cobra as permissões do processo errado (ver o comentário de tipo em
        // `AplicativoQuall.swift`).
        .executableTarget(
            name: "quall-app",
            dependencies: ["QuallCaptureKit", "QuallNetKit", "QuallReceptorKit", "QuallTeleprompterKit",
                           "QuallBarraDeMenusKit", "QuallIdiomaKit", "CQuall"],
            path: "Sources/QuallApp",
            linkerSettings: [
                // Mesma razão do `quall-net-smoke`: o arquivo **inteiro**, por caminho, porque o
                // `crate-type` do `quall-ffi` inclui `cdylib` e o linker preferiria o `.dylib`
                // ao lado — que carrega um caminho absoluto desta máquina e não existiria em
                // outra.
                .unsafeFlags([
                    "../../target/release/libquall.a",
                    "-lc++",
                ])
            ]
        ),
        // `swift test` roda no próprio Mac, sem aparelho e sem simulador: o que se testa aqui é
        // bitstream, não captura. Ver `Tests/QuallCaptureKitTests`.
        .testTarget(
            name: "QuallCaptureKitTests",
            dependencies: ["QuallCaptureKit"],
            path: "Tests/QuallCaptureKitTests",
            exclude: ["TestesDaTelaEstendida.swift"]
        ),
        // O lado que recebe, testado sem rede e sem `.a`: a régua de blocos, o resumo de perda, o
        // varredor de NALs e — o que importa — **o decodificador do produto contra um H.264 que
        // este mesmo teste codifica**. Ver `Tests/QuallReceptorKitTests`.
        .testTarget(
            name: "QuallReceptorKitTests",
            dependencies: ["QuallReceptorKit"],
            path: "Tests/QuallReceptorKitTests"
        ),
        // O teleprompter testado sem rede e sem `.a`: o estado a partir do JSON literal do
        // contrato, o laço contra uma fronteira falsa que grava a ordem das chamadas (a ordem do
        // fim, o PIN depois de erro), a rolagem em velocidade constante e a regra do editor.
        .testTarget(
            name: "QuallTeleprompterKitTests",
            dependencies: ["QuallTeleprompterKit"],
            path: "Tests/QuallTeleprompterKitTests"
        ),
        // O ícone da barra de menus testado sem app: a geometria da marca contra a do `marca.py`, a imagem
        // desenhada num bitmap (o vão em volta da bolinha, o vermelho, o anel que segue o tema), as frases
        // do menu e as duas regras. Com `QUALL_PNG_DA_BARRA=<pasta>`, grava as variantes em PNG para olhar.
        .testTarget(
            name: "QuallBarraDeMenusKitTests",
            dependencies: ["QuallBarraDeMenusKit"],
            path: "Tests/QuallBarraDeMenusKitTests"
        ),
        // A tradução testada sem app: a tabela inglesa carregada do pacote de recursos, a paridade das
        // lacunas (`%@`) entre as duas línguas, a varredura que acusa texto de tela ainda literal no
        // código e as chaves usadas sem tradução (`Tests/QuallIdiomaKitTests`).
        .testTarget(
            name: "QuallIdiomaKitTests",
            dependencies: ["QuallIdiomaKit"],
            path: "Tests/QuallIdiomaKitTests"
        ),
    ]
)
