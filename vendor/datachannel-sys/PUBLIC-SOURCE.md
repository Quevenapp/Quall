# Seleção pública do fonte

O snapshot preserva fontes de runtime, headers, receitas, licenças e avisos da libdatachannel
e dependências. Titulares upstream permanecem identificados pelos avisos originais.

Foram omitidos os 19 assets de documentação/testes, dois `Windows_TemporaryKey.pfx` UWP e
`libdatachannel/test/connectivity.cpp`, que incorporava uma chave estática de testes upstream.
Nenhuma chave foi substituída por placeholder; nenhum teste é declarado válido.

**A suíte upstream não é oferecida completa.** As três configurações CMake de `build.rs` usam
`NO_TESTS=ON`; o CMake da seleção adota essa opção por padrão e rejeita a tentativa de habilitar
a suíte omitida com mensagem explícita. Essa seleção inicial modificou o grafo de testes.
Para estudar a suíte completa, obtenha separadamente a revisão
upstream e revise seus recursos/keys. Patches runtime: `QUALL-PATCH.md` e `quall.patch`.

Na preparação 1.0.0, `build.rs` usa a receita Apple de OpenSSL sem I/O de arquivos,
e `tls.cpp` desliga configuração automática nesse alvo. A dependência `openssl-src`
foi fixada em 400.0.2+4.0.3 para incorporar as correções oficiais de segurança,
incluindo a correção DTLS de 29 de setembro de 2026. `dtlstransport.cpp` impõe
DTLS 1.2 como mínimo e falha se essa configuração não for aceita. As alterações
estão no histórico e nos fontes correspondentes da revisão; os binários anteriores
não comprovam esses comportamentos. A validação final exige novas builds e mídia real.
