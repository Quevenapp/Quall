# Assets de exemplo

Este pacote de fontes usa ícones geométricos de exemplo gerados por `gerar.py`.
O ícone de aplicativo é uma grade de quatro quadrados; os controles Android usam
linhas e polígonos simples. São desenhos originais cobertos por MPL-2.0, assim como
o gerador. Não representam a identidade visual aprovada para uma distribuição.

Para recriar PNG, ICO, ICNS, catálogo iOS e vetores Android:

```sh
python3 tools/icones/gerar.py
```

O gerador utiliza apenas a biblioteca padrão do Python 3. Não lê imagens, fontes,
dados do usuário ou arquivos de ícones externos. Os arquivos são determinísticos
para a mesma versão de Python/zlib. Os nomes e tamanhos preservam os contratos das
receitas de compilação; os rótulos de acessibilidade dos controles continuam no
código de interface. Os recursos `ic_q_coelho` e `ic_q_tartaruga` usam setas para
representar os controles de velocidade.

Os vetores `ic_q_*` deste snapshot foram desenhados novamente e não incorporam os
paths dos Material Icons. Licenças e avisos dos outros componentes terceiros
continuam aplicáveis, conforme o inventário geral.
