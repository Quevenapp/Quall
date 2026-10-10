# Ícones e marca da distribuição

Os 46 controles `ic_q_*` Android deste pacote são desenhos geométricos próprios,
sem paths dos antigos Material Icons, sob MPL-2.0. O gerador `gerar.py` produz
os placeholders neutros da seleção pública de fontes, inclusive a grade de
quatro quadrados para o launcher.

A distribuição oficial Quall Studio 1.0.0 usa a marca Q branca com luz vermelha
sobre azul-marinho. Seus quatro arquivos Android estão preservados em
`overlays/quall-studio-1.0.0/`, com destinos e hashes no `manifesto.json`.
`marca.py` contém a geometria original aprovada para gerar variantes de tamanho;
seu código tem MPL-2.0. Os direitos da marca e seus assets estão separados em
`DIREITOS-DA-MARCA.txt`; não há concessão automática de marca pelo código aberto.

Para gerar os placeholders e aplicar novamente os assets exatos da distribuição
oficial, executar na raiz do repositório:

```sh
python3 tools/icones/gerar.py
python3 tools/icones/aplicar-marca-oficial.py
```

O segundo comando verifica cada SHA256 antes de copiar somente os três vetores
de launcher e `tools/icones/loja/play-512.png`. Não troca controles de interface.
O PNG fornecido é o insumo exato da versão; desenhar novamente com outra versão
de Pillow/zlib pode mudar a codificação do PNG, embora a geometria seja a mesma.
Para obter uma nova variante quadrada a partir da geometria (Pillow instalado):

```python
import sys
sys.path.insert(0, 'tools/icones')
import marca
marca.desenhar(1024).convert('RGB').save('Quall-1024.png', optimize=True)
```

A marca desta receita é um insumo explícito, não um material privado omitido do
build. As licenças e avisos de terceiros continuam no inventário geral. Usar
arte própria/placeholders ao distribuir uma versão com outra identidade.
