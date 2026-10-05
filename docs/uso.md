# Uso do Quall Studio

1. Abra Quall Studio nos aparelhos e permita a comunicação entre eles na rede.
2. No emissor, escolha tela existente ou câmera e inicie o compartilhamento: uma origem por sessão.
3. No receptor, use Exibir e escolha o emissor; informe o endereço quando a descoberta não funcionar.
4. Use o PIN apresentado para o primeiro pareamento. Pares conhecidos podem ser retomados.
5. Encerre a sessão pela interface ao terminar. Tela, câmera e microfone dependem das permissões do sistema.

Descoberta e acesso direto dependem da rede e da plataforma. Firewall, isolamento de clientes e
topologia podem impedir a conexão. Não há garantia de funcionamento em qualquer rede.
No iOS/iPadOS, compartilhar tela usa ReplayKit e exige a interação prevista pelo controle de
transmissão do sistema. Câmera e áudio seguem o ciclo de vida do app e podem ser interrompidos.

O teleprompter usa texto local e controle remoto, com composição de câmera conforme o fluxo.
A gravação própria fica no emissor; o receptor não grava por si. Confirme o destino e as
permissões de armazenamento e capture apenas conteúdo autorizado.

Câmera virtual e OBS são componentes separados. Consulte [câmera macOS](../integrations/camera-macos/README.md),
[câmera Windows](../integrations/camera-windows/README.md) e [OBS](../plugins/obs/README.md).
Instalação, ativação e registro têm efeitos no sistema. Gravação/composição no OBS pertencem ao OBS.

USB/DVD são exceções [Android](../apps/android/README.md), com Android 11+, arm64, acessórios
e formatos compatíveis. Monitor/Tela estendida, sudoVda, crop e video wall ficam fora da primeira release.
Permissões e capacidades variam entre aparelhos; veja [limites](limites.md).
