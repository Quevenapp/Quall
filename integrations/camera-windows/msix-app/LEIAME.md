# Receita MSIX da edição Microsoft Store

Esta edição conserva Mirror, recepção de vídeo, câmeras físicas, teleprompter e
gravação. Não inclui nem ativa a câmera virtual do Quall para outros apps.
Uma integração externa exige componente externo, que não acompanha esta edição.
O caminho desktop completo permanece no fonte, compilado sem `loja`.

Fontes próprios desta receita: MPL-2.0, conforme LICENSE e LICENSE-SCOPE.md na raiz.
Os insumos originais em brand/windows conservam os direitos reservados e a permissão
de reprodução técnica para compilar, testar e relinkar esta versão documentados
nessa pasta. Isso não identifica versões modificadas como oficiais nem altera
direitos de terceiros. Fixtures são dados de teste, nunca insumos de release.

A receita lê um executável Store x64 nativo da revisão identificada, seu hash e
os avisos legais da raiz. Cria uma pasta nova e pode executar MakeAppx do SDK
Windows existente, preservando saídas em caso de erro. Não assina, instala,
registra COM, muda ACLs, carrega binários ou envia a serviços.

## Construção e insumos

Usar um checkout da revisão correspondente, MSVC x64 e SDK Windows existentes.
Registrar revisão, inventário de mudanças, rustc/cargo/MSVC/SDK, locks, configuração
e logs efetivos. `rust-toolchain.toml` usa stable; não se promete igualdade binária
entre builds. O cache offline deve conter as versões fixadas nos locks; num
checkout novo, executar `cargo fetch --locked --manifest-path apps/windows/Cargo.toml`.

```powershell
cargo build --manifest-path apps/windows/Cargo.toml --release --locked --offline --jobs 2 --target x86_64-pc-windows-msvc --no-default-features --features net,loja --bin quall-app --target-dir $BuildNovo
```

Copiar somente o `quall-app.exe` produzido para uma pasta payload nova. A dependência
Rust que compartilha constantes do IPC pode produzir uma DLL auxiliar no diretório
Cargo: essa DLL não entra no payload MSIX. A feature `loja` exclui a chamada
`MFCreateVirtualCamera`, bloqueia as baias/IPC da câmera virtual e recusa a ativação
COM interna da fonte. O registro força esse recurso desligado mesmo se argumentos
pedirem. Os testes nativos dessa feature precisam passar antes da aprovação.

Registrar hashes e inventários reais em JSON conforme ORIGEM-ARTEFATOS.schema.json,
com `edition=store-without-virtual-camera`, `cargo_features=["net","loja"]` e
`security_protocol_version=3`. O schema não é recibo de build. O executável deve
conter o marcador dessa edição e nenhum import de ativação virtual; a receita
recusa executável desktop, DLL ou outro arquivo na entrada binária.

`apps/windows/quall.ico` deve coincidir com `brand/windows/quall.ico`. Cargo e
recursos PE usam versão 1.0.0; proposta MSIX 1.0.0.0. Confirmar o histórico do
produto antes de distribuir. Esta fonte usa sinalização segura v3 e OpenSSL 4.0.3;
binários anteriores com protocolo v2/OpenSSL 3.6.3 são históricos e não servem como
artefatos correspondentes à revisão atual.

```powershell
python integrations/camera-windows/msix-app/testar_preparo.py
python integrations/camera-windows/msix-app/preparar_msix.py --manifesto integrations/camera-windows/msix-app/AppxManifest.xml --payload $PayloadNovo --assets brand/windows --icone-esperado brand/windows/quall.ico --fonte . --origem-artefatos $OrigemReal --versao 1.0.0.0 --max-version-tested $WindowsVerificado --saida $SaidaNova --makeappx $MakeAppxExistente
```

Requer Python 3 e sua biblioteca padrão. Saída absoluta inexistente, fora dos
repositórios e Desktop. Os verificadores PE/CRT são estáticos. `verificar_crt.py`
compara imports diretos com o framework efetivo, sem provar carregamento transitivo.
O manifesto declara Microsoft.VCLibs.140.00.UWPDesktop mínimo 14.0.33728.0 em vez
de copiar DLLs do sistema. MakeAppx valida schema sem `/nv`. Diagnósticos ficam
fora do payload. Remover caminhos pessoais/dados de ambiente de recibos públicos.

## Identidade e limites

Identidade existente Quven.Quall, produto Microsoft Store 9P8G0RLXSJH3; publisher
CN=4EAB9D59-8495-46DE-A09A-46666F12757F. Mínimo Windows 11 build 22000. O manifesto
declara somente runFullTrust, webcam e microphone, sem driver, registro COM ou
capacidade de compatibilidade elevada. `AppxManifest.com-usuario-experimental.xml`
é fixture histórica recusada pela receita atual, mesmo com seleção explícita.

O [contrato COM de pacotes](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-com4-extension)
não demonstra ativação de DLL de pacote comum pelo FrameServer/LocalService.
Por isso a edição da Store não depende dessa integração. Schema/guardas aprovados
não provam runtime, consentimento, atualização/remoção ou certificação WACK/Store.
Os recibos permanecem `store_submission_ready=false`; assinatura, testes de produto,
revisão da ficha e envio final são etapas separadas.

Antes de distribuir, disponibilizar os fontes cobertos correspondentes e suas
modificações em https://github.com/Quevenapp/Quall, mantendo avisos e dependências.
A base 3172b188c29a010cd161c56bbeeb2cbcefbb220a sozinha não representa o binário novo.
