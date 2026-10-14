//! A tabela de tradução: a câmera virtual que o Quall instala (ver `idioma.rs` e
//! `regras_da_instalacao_da_camera.rs`). `(português, inglês)`, com os `{}` nas mesmas posições de
//! ordem; o português é o texto que está no código. As frases que o driver da tela estendida também
//! usa ("Esperando a permissão do Windows…", "Instalar") têm aqui a **mesma** tradução de
//! `idioma/driver.rs` (o teste de paridade cobra), porque aquela tabela só entra com
//! `tela-estendida-futura`.

pub const TEXTOS: &[(&str, &str)] = &[
    // o cartão dos Ajustes
    ("Instalação da câmera virtual", "Virtual camera installation"),
    (
        "Não instalada. Instale para os aparelhos aparecerem como câmera no Zoom, no Meet e no OBS.",
        "Not installed. Install it to show your devices as a camera in Zoom, Meet and OBS.",
    ),
    ("Instalada neste computador.", "Installed on this computer."),
    ("Registrada, mas o arquivo da câmera sumiu. Instale de novo.", "Registered, but the camera file is missing. Install it again."),
    (
        "Não instalada. Baixe o instalador da câmera virtual na página do Quall.",
        "Not installed. Download the virtual camera installer from the Quall page.",
    ),
    (
        "Instalada neste computador. Para tirar, use o instalador da câmera virtual.",
        "Installed on this computer. To remove it, use the virtual camera installer.",
    ),
    ("Este Windows não é x64: a câmera virtual não roda nele.", "This Windows isn't x64: the virtual camera doesn't run on it."),
    ("Instalar câmera virtual", "Install virtual camera"),
    ("Remover câmera virtual", "Remove virtual camera"),
    ("Baixar o instalador da câmera", "Download the camera installer"),
    ("Abrir o instalador da câmera", "Open the camera installer"),
    (
        "Instalar câmera virtual: abre uma caixa que explica antes de instalar",
        "Install virtual camera: opens a box that explains before installing",
    ),
    (
        "Remover câmera virtual: abre uma caixa que explica antes de remover",
        "Remove virtual camera: opens a box that explains before removing",
    ),
    (
        "Instalador da câmera virtual: abre a página do Quall no navegador",
        "Virtual camera installer: opens the Quall page in the browser",
    ),
    // a caixa
    ("A câmera virtual precisa ser instalada no Windows", "The virtual camera needs to be installed in Windows"),
    (
        "Para os aparelhos aparecerem como câmera no Zoom, no Meet e no OBS, o Quall põe a fonte da câmera virtual em Arquivos de Programas e a registra no Windows. Ela vem junto com o Quall; nada é baixado.",
        "So your devices show up as a camera in Zoom, Meet and OBS, Quall puts the virtual camera source in Program Files and registers it with Windows. It comes with Quall; nothing is downloaded.",
    ),
    ("O Windows vai pedir permissão de administrador.", "Windows will ask for administrator permission."),
    ("Ela sai quando você remover a câmera virtual por aqui.", "It's removed when you remove the virtual camera here."),
    ("Instalar", "Install"),
    ("Tirar a câmera virtual deste computador?", "Remove the virtual camera from this computer?"),
    (
        "O Quall tira o registro da câmera virtual e o arquivo dela. Os apps que estiverem com a câmera do Quall aberta perdem a imagem.",
        "Quall removes the virtual camera's registration and its file. Apps that have the Quall camera open lose the picture.",
    ),
    ("Remover", "Remove"),
    // o instalador avulso
    ("Instalador da câmera virtual do Quall Studio", "Quall Studio virtual camera installer"),
    ("Fechar", "Close"),
    ("A câmera virtual não está instalada neste computador.", "The virtual camera isn't installed on this computer."),
    ("A câmera virtual está instalada neste computador.", "The virtual camera is installed on this computer."),
    ("Pode fechar: o Quall já vê a câmera virtual, mesmo aberto.", "You can close this: Quall already sees the virtual camera, even while open."),
    ("Detalhes", "Details"),
    // os passos
    ("Conferindo a fonte da câmera", "Checking the camera source"),
    ("Copiando para Arquivos de Programas", "Copying to Program Files"),
    ("Registrando a câmera no Windows", "Registering the camera with Windows"),
    ("Conferindo o registro", "Checking the registration"),
    ("Tirando o registro da câmera", "Removing the camera registration"),
    ("Tirando de Arquivos de Programas", "Removing from Program Files"),
    ("Conferindo que saiu", "Checking it's gone"),
    // os motivos
    ("a fonte da câmera não veio dentro deste Quall", "the camera source didn't come inside this Quall"),
    ("a fonte da câmera dentro do Quall não confere", "the camera source inside Quall doesn't check out"),
    ("este Windows não é x64", "this Windows isn't x64"),
    ("outra instalação da câmera está em andamento", "another camera installation is in progress"),
    ("não deu para preparar a pasta do Quall", "couldn't prepare the Quall folder"),
    ("não deu para copiar a fonte da câmera", "couldn't copy the camera source"),
    ("o Windows não aceitou o registro da câmera", "Windows didn't accept the camera registration"),
    ("o registro da câmera não ficou como devia", "the camera registration didn't end up as expected"),
    ("o registro da câmera não saiu", "the camera registration wasn't removed"),
    ("o arquivo da câmera não saiu", "the camera file wasn't removed"),
    ("o Quall da loja não instala a câmera por dentro", "the Store version of Quall doesn't install the camera from inside"),
    ("o pedido foi recusado", "the request was refused"),
    ("faltou a permissão de administrador", "administrator permission was missing"),
    ("o processo da câmera terminou sem dizer como", "the camera process ended without saying how"),
    ("o Windows não abriu o processo da câmera", "Windows didn't start the camera process"),
    // o andamento e o resultado
    ("Esperando a permissão do Windows…", "Waiting for Windows permission…"),
    ("Instalando a câmera virtual — passo {} de {}: {}…", "Installing the virtual camera — step {} of {}: {}…"),
    ("Removendo a câmera virtual — passo {} de {}: {}…", "Removing the virtual camera — step {} of {}: {}…"),
    (
        "Câmera virtual instalada. Os aparelhos já aparecem como câmera nos outros apps.",
        "Virtual camera installed. Your devices now show up as a camera in other apps.",
    ),
    ("Câmera virtual removida.", "Virtual camera removed."),
    ("Pronto, mas o Windows pede para reiniciar o computador antes de usar.", "Done, but Windows asks to restart the computer before use."),
    ("Instalação cancelada: o Windows não recebeu a permissão. Nada foi instalado.", "Installation canceled: Windows didn't get permission. Nothing was installed."),
    ("Remoção cancelada: o Windows não recebeu a permissão. Nada foi tirado.", "Removal canceled: Windows didn't get permission. Nothing was removed."),
    ("Não deu para instalar a câmera virtual ({}): {}.", "Couldn't install the virtual camera ({}): {}."),
    ("Não deu para remover a câmera virtual ({}): {}.", "Couldn't remove the virtual camera ({}): {}."),
    ("antes de começar", "before starting"),
];
