# Harness Opus para iOS

Projeto de diagnóstico da biblioteca Opus em processo iOS; não mede por si só a qualidade
acústica ou o comportamento completo de áudio do produto. Piso iOS 15.

Compile `quall-opus` para `aarch64-apple-ios`, mantendo o deployment target iOS 15 e a
configuração Apple de LTO. Prepare `lib/libopus.a` nesta pasta com a saída desse alvo;
o `project.yml` aponta explicitamente para esse arquivo, que não é um binário pré-compilado do snapshot.
Depois gere o projeto com XcodeGen e compile o esquema `PortaoOpus` no Xcode.

Assinatura e execução em aparelho exigem configuração própria e autorização. Scripts de medição
podem instalar/lançar o app e coletar logs: leia e adapte a configuração antes de usar.
Não há resultados privados ou uma promessa de testes aprovados neste snapshot.
Veja [compilação](../../../docs/compilar.md) e [limites](../../../docs/limites.md).
