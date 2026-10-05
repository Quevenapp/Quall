# Sondas de gravação e mídia

Instrumentos separados do produto para investigar codecs, gravação, contêineres e sincronização
em `windows`, `ios` e `android`. Cada alvo usa sua toolchain nativa; os resultados de um
instrumento não são testes completos do app.

Use as receitas gerais de [compilação](../../docs/compilar.md) para preparar as toolchains.
O alvo Windows é um workspace Cargo próprio; projetos iOS são gerados de `project.yml`
com XcodeGen; Android tem projeto Gradle próprio. Configure suas identidades de assinatura
somente no ambiente local quando precisar executar.

Este snapshot não inclui automações privadas de aparelhos, binários ou gravações históricas.
Revise argumentos e efeitos antes de instalar, lançar ou capturar. Prefira padrões sintéticos
e mídia autorizada; publique apenas resultados mínimos sem dados pessoais.
Nenhuma execução dessas sondas foi certificada por esta preparação documental.
Veja [limites](../../docs/limites.md) e [contribuição](../../CONTRIBUTING.md).
