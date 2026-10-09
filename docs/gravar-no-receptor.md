# Gravação no receptor

O receptor permite gravar tanto a câmera quanto a tela espelhada. O usuário confirmou os dois
tipos de origem em 09/10/2026. O botão **Gravar** é local ao receptor; **Parar gravação** salva o
arquivo MP4. Encerrar a conexão também encerra o arquivo. No iOS/Android, sair do primeiro plano
fecha a gravação. Uma nova conexão exige um novo toque em Gravar.

Uma tela parada mantém sua última imagem no arquivo até o instante de Parar, com o áudio recebido
durante esse intervalo. O tempo de fechamento do arquivo não é acrescentado à gravação.

O vídeo H.264 recebido é guardado sem outro codificador de vídeo. O arquivo usa a resolução e os
carimbos da transmissão, incluindo as perdas da rede. O áudio recebido é convertido para AAC;
mudo e volume da reprodução não alteram esse áudio. Gravar não liga câmera, microfone ou captura
de tela local. Sem áudio na transmissão, o arquivo pode ter só vídeo.

| Receptor | Destino |
|---|---|
| macOS | Filmes/Quall |
| Windows | Vídeos/Quall |
| iPhone/iPad | Fotos, com permissão de adicionar; se a permissão ou salvamento falhar, o arquivo fica preservado e pode ser exportado |
| Android 10+ | Galeria, Movies/Quall |
| Android 9 | Pasta privada do app; o botão Compartilhar exporta a gravação com uma concessão de leitura apenas para o arquivo selecionado |

O arquivo começa em uma imagem completa (IDR). Perder uma referência ou exceder a fila limitada
faz o gravador aguardar outro IDR; ele pede essa imagem ao emissor. O quadro anterior pode ficar
parado nesse intervalo. Alterar SPS/PPS, resolução ou formato de áudio cria outra parte MP4.
Nenhuma fila espera pelo disco nas threads de áudio/rede; os escritores e codecs rodam em filas
próprias. O Mac usa cópia de memória limitada sob uma trava separada de vídeo; o áudio usa um
anel pré-alocado sem espera no render.

Se a track de áudio chegar depois de iniciar Gravar, o receptor pode fechar a parte sem áudio e
abrir outra com áudio no próximo IDR. Filas e escritores em fechamento têm limites finitos;
armazenamento lento pode provocar pausas na gravação sem bloquear a exibição.

Os carimbos são ligados pelo relógio da sessão. O novo deslocamento bruto é consultado no
supervisor/gravador, sem alterar a guarda da reprodução ao vivo. Antes de medir esse relógio, o
áudio espera até cinco segundos; a falta da medida usa um alinhamento inicial pela chegada.
Essa alternativa preserva os intervalos posteriores dos carimbos, mas não garante sincronia
contra atrasos assimétricos na rede. A gravação herda perdas de áudio que a reprodução já descartou.

O OBS continua gravando pelo botão de gravação do próprio OBS.

## Validação e versão de publicação

Os testes nativos usam imagem e áudio sintéticos. Compilação, contagem de quadros, trilhas,
referências, partes e decodificação são verificações locais; não substituem testes físicos da
versão instalada. Os pacotes históricos Android 9, Apple 6 e Windows 1.0.6.0 não contêm este
recurso. Novos artefatos de desenvolvimento e o status da publicação ficam em recibos locais.

O aviso no emissor de que um receptor está gravando ainda não foi implementado. Ele exige
negociar uma capacidade de sinalização para manter a conexão com os emissores já instalados.
O pedido de gravação pelo emissor ou por controle remoto também não faz parte desta implementação.
Antes de incorporar o recurso aos candidatos das lojas, falta esse aviso negociado e a QA física.
