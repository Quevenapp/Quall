import CoreMediaIO
import Foundation

// A extensão é um executável comum que entrega o processo ao CoreMediaIO. Não há `NSApplication`,
// não há janela e não há usuário: ela é lançada pelo `cmiodalassistants` quando algum app abre a
// câmera, e o único jeito de ver o que acontece aqui dentro é `log stream`.
registro.info("EXT main pid=\(getpid(), privacy: .public)")

let provedor = ProvedorDeCamera(filaDeClientes: nil)
CMIOExtensionProvider.startService(provider: provedor.provider)

CFRunLoopRun()
