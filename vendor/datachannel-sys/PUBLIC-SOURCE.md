# Seleção pública do fonte

O snapshot preserva fontes de runtime, headers, receitas, licenças e avisos da libdatachannel
e dependências. Titulares upstream permanecem identificados pelos avisos originais.

Foram omitidos os 19 assets de documentação/testes, dois `Windows_TemporaryKey.pfx` UWP e
`libdatachannel/test/connectivity.cpp`, que incorporava uma chave estática de testes upstream.
Nenhuma chave foi substituída por placeholder; nenhum teste é declarado válido.

**A suíte upstream não é oferecida completa.** As três configurações CMake de `build.rs` usam
`NO_TESTS=ON`; o CMake da seleção adota essa opção por padrão e rejeita a tentativa de habilitar
a suíte omitida com mensagem explícita. Mudanças somente no grafo de testes; runtime preservado.
Não houve build nesta revisão. Para estudar a suíte completa, obtenha separadamente a revisão
upstream e revise seus recursos/keys. Patches runtime: `QUALL-PATCH.md` e `quall.patch`.
