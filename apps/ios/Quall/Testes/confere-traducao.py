#!/usr/bin/env python3
"""Confere a tradução PT/EN do app iOS (`docs/traducao.md`, seção iOS).

O português é a chave (`tr("Espelhar")`, `Comum/Idioma.swift`) e o inglês mora nas tabelas
`<pasta>/en.lproj/*.strings`. Este roteiro reprova quando:

1. **falta chave**: um `tr("…")` do código sem linha na tabela EN da pasta (ou em `Comum.strings`,
   que entra nos dois alvos); a appex só enxerga `Extensao/` e `Comum/`;
2. **sobra chave**: uma linha da tabela EN que nenhum `tr` usa (a tabela envelhece em silêncio);
3. **placeholder diferente** entre a chave PT e o texto EN (`%@`, `%ld`, `%.1f`; `%1$@` conta pela
   posição), ou um `tr` com número de argumentos diferente dos placeholders;
4. **chave que não é literal**: `tr(variavel)` ou `tr("…\\(x)…")` — a varredura não teria como
   conferir, e a interpolação mudaria a chave a cada valor;
5. **texto de interface ainda literal**: `Text("…")`, `Button("…")`, `titulo: "…"`,
   `.accessibilityLabel("…")` etc. sem `tr`. Exceção: `// sem-traducao` na linha;
6. **permissões**: `InfoPlist.strings` em `en.lproj` e `pt-BR.lproj` do app e da appex, com as
   mesmas chaves e cobrindo as `NS…UsageDescription` do `Info.plist`.

Uso: `confere-traducao.py [raiz do projeto iOS]` (padrão: a pasta acima desta). Saída 0 = aprovado.
"""
import json
import os
import plistlib
import re
import subprocess
import sys

RAIZ = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
PASTAS = ["App", "Receber", "Teleprompter", "Comum", "Extensao"]
# Quem cada pasta enxerga em tempo de execução: o alvo do app junta App, Receber, Teleprompter e
# Comum; a appex, Extensao e Comum. Comum entra nos dois, então as chaves dele moram em Comum.
VISIVEIS = {
    "App": ["App", "Receber", "Teleprompter", "Comum"],
    "Receber": ["App", "Receber", "Teleprompter", "Comum"],
    "Teleprompter": ["App", "Receber", "Teleprompter", "Comum"],
    "Comum": ["Comum"],
    "Extensao": ["Extensao", "Comum"],
}

# Chamadas cujo argumento é texto de interface, e rótulos de argumento que levam texto.
GATILHOS_DE_CHAMADA = {
    "Text", "Button", "Label", "Toggle", "Section", "Picker", "Stepper", "Link", "TextField",
    "SecureField", "Menu", "RotuloDeSecao", "accessibilityLabel", "accessibilityHint",
    "accessibilityValue", "navigationTitle", "alert", "confirmationDialog", "UIAlertController",
    "UIAlertAction", "ProgressView", "DisclosureGroup", "setTitle",
}
ROTULOS = {
    "titulo", "rotulo", "texto", "legenda", "title", "message", "palavra", "nome", "detalhe",
    "subtitulo", "manchete", "frase", "dica", "aviso", "acao", "explicacao", "placeholder",
}

erros = []


def erro(msg):
    erros.append(msg)


# ------------------------------------------------------------------------------------------------
# Um tokenizador pequeno de Swift: o bastante para separar comentário, literal de texto e o resto.
# ------------------------------------------------------------------------------------------------
class Tok:
    __slots__ = ("tipo", "valor", "linha", "cru", "interpola")

    def __init__(self, tipo, valor, linha, cru="", interpola=False):
        self.tipo, self.valor, self.linha, self.cru, self.interpola = tipo, valor, linha, cru, interpola


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\"": "\"", "'": "'", "\\": "\\"}


def ler_literal(src, i, linha):
    """Lê um literal a partir de `src[i]` (aspas). Devolve (Tok, novo i, nova linha)."""
    triplo = src.startswith('"""', i)
    if triplo:
        fim = src.index('"""', i + 3)
        while src[fim - 1] == "\\" and src[fim - 2] != "\\":
            fim = src.index('"""', fim + 1)
        corpo = src[i + 3:fim]
        linhas = corpo.split("\n")[1:]
        recuo = len(linhas[-1]) if linhas else 0
        texto = "\n".join(l[recuo:] for l in linhas[:-1])
        texto = texto.replace("\\\n", "")
        valor, interp = decodificar(texto)
        tok = Tok("lit", valor, linha, corpo, interp)
        return tok, fim + 3, linha + corpo.count("\n")
    j = i + 1
    profundidade = 0
    while True:
        c = src[j]
        if c == "\\":
            if src[j + 1] == "(":
                profundidade += 1
                j += 2
                # pula a expressão interpolada, com parênteses aninhados e literais dentro
                nivel = 1
                while nivel:
                    if src[j] == '"':
                        _, j, _ = ler_literal(src, j, linha)
                        continue
                    if src[j] == "(":
                        nivel += 1
                    elif src[j] == ")":
                        nivel -= 1
                    j += 1
                continue
            j += 2
            continue
        if c == '"':
            break
        if c == "\n":
            raise ValueError(f"literal sem fim na linha {linha}")
        j += 1
    cru = src[i + 1:j]
    valor, interp = decodificar(cru)
    return Tok("lit", valor, linha, cru, interp or profundidade > 0), j + 1, linha


def decodificar(cru):
    out, i, interp = [], 0, False
    while i < len(cru):
        c = cru[i]
        if c == "\\" and i + 1 < len(cru):
            n = cru[i + 1]
            if n == "(":
                interp = True
                out.append("\\(")
                i += 2
                continue
            if n == "u" and cru[i + 2] == "{":
                f = cru.index("}", i)
                out.append(chr(int(cru[i + 3:f], 16)))
                i = f + 1
                continue
            out.append(ESCAPES.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out), interp


def tokens(src):
    toks, i, linha, n = [], 0, 1, len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            linha += 1
            i += 1
        elif c.isspace():
            i += 1
        elif src.startswith("//", i):
            f = src.find("\n", i)
            f = n if f < 0 else f
            toks.append(Tok("com", src[i:f], linha))
            i = f
        elif src.startswith("/*", i):
            nivel, j = 1, i + 2
            while nivel:
                if src.startswith("/*", j):
                    nivel += 1
                    j += 2
                elif src.startswith("*/", j):
                    nivel -= 1
                    j += 2
                else:
                    j += 1
            linha += src[i:j].count("\n")
            i = j
        elif c == '"' or (c == "#" and src.startswith('#"', i)):
            if c == "#":  # literal cru: não é texto de interface neste projeto; pula
                f = src.index('"#', i + 2)
                toks.append(Tok("lit", src[i + 2:f], linha, src[i + 2:f]))
                i = f + 2
                continue
            tok, i, linha = ler_literal(src, i, linha)
            toks.append(tok)
        elif c.isalnum() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            toks.append(Tok("id", src[i:j], linha))
            i = j
        else:
            toks.append(Tok("p", c, linha))
            i += 1
    return toks


# ------------------------------------------------------------------------------------------------
# Placeholders
# ------------------------------------------------------------------------------------------------
RE_PH = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])")


def conferir_formato(texto, onde):
    """Só `%@`, `%ld`/`%d`, `%.Nf`/`%f` e `%%`; sem misturar posicional com sequencial (o `String(format:)`
    lê a memória errada e o app cai, e só na língua que tem o defeito)."""
    pos = seq = 0
    for m in RE_PH.finditer(texto):
        if m.group(2) == "%":
            continue
        if m.group(2) not in "@df":
            erro(f"{onde}: placeholder {m.group(0)!r} fora do conjunto %@ %ld %.Nf em {texto!r}")
        if m.group(1):
            pos += 1
        else:
            seq += 1
    if pos and seq:
        erro(f"{onde}: posicional (%1$@) misturado com sequencial (%@) em {texto!r}")


def placeholders(texto):
    lista, seq = [], 0
    for m in RE_PH.finditer(texto):
        if m.group(2) == "%":
            continue
        tipo = m.group(2)
        tipo = {"D": "d", "i": "d", "u": "d", "U": "d", "F": "f", "e": "f", "E": "f", "g": "f",
                "G": "f", "s": "@", "S": "@"}.get(tipo, tipo)
        if m.group(1):
            pos = int(m.group(1))
        else:
            seq += 1
            pos = seq
        lista.append((pos, tipo))
    return sorted(lista)


# ------------------------------------------------------------------------------------------------
# Tabelas
# ------------------------------------------------------------------------------------------------
def ler_strings(caminho):
    saida = subprocess.run(["plutil", "-convert", "json", "-o", "-", caminho], capture_output=True)
    if saida.returncode:
        erro(f"{caminho}: não é um .strings válido ({saida.stderr.decode().strip()})")
        return {}
    return json.loads(saida.stdout)


def chaves_duplicadas_no_arquivo(caminho):
    texto = open(caminho, encoding="utf-8").read()
    vistos, dup = set(), []
    for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', texto, re.M):
        k = m.group(1)
        if k in vistos:
            dup.append(k)
        vistos.add(k)
    return dup


tabelas = {}  # pasta -> {chave: (valor, arquivo)}
for pasta in PASTAS:
    d = os.path.join(RAIZ, pasta, "en.lproj")
    tabelas[pasta] = {}
    if not os.path.isdir(d):
        continue
    for nome in sorted(os.listdir(d)):
        if not nome.endswith(".strings") or nome == "InfoPlist.strings":
            continue
        cam = os.path.join(d, nome)
        for k in chaves_duplicadas_no_arquivo(cam):
            erro(f"{pasta}/en.lproj/{nome}: chave repetida no arquivo: {k!r}")
        for k, v in ler_strings(cam).items():
            if k in tabelas[pasta] and tabelas[pasta][k][0] != v:
                erro(f"{pasta}: chave em duas tabelas com textos diferentes: {k!r}")
            tabelas[pasta][k] = (v, nome)

# Dentro de um alvo as tabelas viram um dicionário só (`Idioma.montarTabela`), e a ordem entre elas não
# é garantida: a mesma chave com dois textos EN em pastas que o mesmo alvo enxerga é um sorteio.
for alvo, pastas in (("app", ["App", "Receber", "Teleprompter", "Comum"]), ("appex", ["Extensao", "Comum"])):
    vistos = {}
    for pasta in pastas:
        for k, (v, nome) in tabelas[pasta].items():
            if k in vistos and vistos[k][0] != v:
                erro(f"{alvo}: {k!r} com textos EN diferentes em {vistos[k][1]} e {pasta}/{nome}")
            vistos.setdefault(k, (v, f"{pasta}/{nome}"))

nomes_de_tabela = {}
for pasta in PASTAS:
    d = os.path.join(RAIZ, pasta, "en.lproj")
    if os.path.isdir(d):
        for nome in os.listdir(d):
            if nome.endswith(".strings") and nome != "InfoPlist.strings":
                if nome in nomes_de_tabela:
                    erro(f"tabela {nome} em {pasta} e em {nomes_de_tabela[nome]}: o pacote é plano, "
                         "os nomes precisam ser únicos")
                nomes_de_tabela[nome] = pasta

# ------------------------------------------------------------------------------------------------
# Código
# ------------------------------------------------------------------------------------------------
usadas = {p: {} for p in PASTAS}  # pasta -> {chave: [onde]}
literais = []
total_tr = 0


def tem_letras(texto):
    return len(re.findall(r"[A-Za-zÀ-ÿ]", texto)) >= 2


def linha_isenta(src_linhas, linha):
    return "sem-traducao" in src_linhas[linha - 1]


for pasta in PASTAS:
    for raiz, _, arquivos in os.walk(os.path.join(RAIZ, pasta)):
        for nome in sorted(arquivos):
            if not nome.endswith(".swift"):
                continue
            cam = os.path.join(raiz, nome)
            rel = os.path.relpath(cam, RAIZ)
            src = open(cam, encoding="utf-8").read()
            src_linhas = src.split("\n")
            try:
                ts = [t for t in tokens(src) if t.tipo != "com"]
            except Exception as e:  # noqa: BLE001
                erro(f"{rel}: não consegui ler ({e})")
                continue
            consumidos = set()
            k = 0
            while k < len(ts):
                t = ts[k]
                # ---- tr( "…" [+ "…"]* [, args] )
                if (t.tipo == "id" and t.valor in ("tr", "trSistema") and k + 1 < len(ts) and ts[k + 1].valor == "("
                        and not (k > 0 and ts[k - 1].valor in (".", "func"))):
                    total_tr += 1
                    j = k + 2
                    partes = []
                    while j < len(ts) and ts[j].tipo == "lit":
                        partes.append(ts[j])
                        consumidos.add(j)
                        if j + 1 < len(ts) and ts[j + 1].valor == "+" and j + 2 < len(ts) and ts[j + 2].tipo == "lit":
                            j += 2
                            continue
                        j += 1
                        break
                    if not partes or ts[j].valor not in (",", ")"):
                        erro(f"{rel}:{t.linha}: tr(...) sem chave literal")
                        k += 1
                        continue
                    if any(p.interpola for p in partes):
                        erro(f"{rel}:{t.linha}: tr(...) com \\( ) na chave; use %@")
                    chave = "".join(p.valor for p in partes)
                    # conta os argumentos no nível 1 até fechar
                    nargs, nivel = 0, 1
                    if ts[j].valor == ",":
                        nargs = 1
                        j += 1
                        while j < len(ts) and nivel:
                            v = ts[j].valor if ts[j].tipo == "p" else None
                            if v in ("(", "[", "{"):
                                nivel += 1
                            elif v in (")", "]", "}"):
                                nivel -= 1
                            elif v == "," and nivel == 1:
                                nargs += 1
                            j += 1
                    ph = placeholders(chave)
                    if nargs and len(ph) != nargs:
                        erro(f"{rel}:{t.linha}: {len(ph)} placeholder(s) e {nargs} argumento(s) em {chave!r}")
                    if not nargs and ph:
                        erro(f"{rel}:{t.linha}: placeholder sem argumento em {chave!r} (use %% para um % literal com argumentos)")
                    if not nargs and "%%" in chave:
                        erro(f"{rel}:{t.linha}: %% numa chave sem argumentos sai dobrado na tela: {chave!r}")
                    usadas[pasta].setdefault(chave, []).append(f"{rel}:{t.linha}")
                    k += 1
                    continue
                # ---- UIKit: `.text = "…"`, `.placeholder = "…"`, `.title = "…"`
                if (t.tipo == "id" and t.valor in ("text", "placeholder", "title", "accessibilityLabel",
                                                    "accessibilityHint", "localizedTitle")
                        and k > 0 and ts[k - 1].valor == "." and k + 2 < len(ts) and ts[k + 1].valor == "="
                        and ts[k + 2].tipo == "lit" and tem_letras(ts[k + 2].valor)
                        and not linha_isenta(src_linhas, ts[k + 2].linha)):
                    literais.append(f"{rel}:{ts[k + 2].linha}: .{t.valor} = {ts[k + 2].valor[:70]!r}")
                # ---- texto de interface literal
                gatilho = None
                if t.tipo == "id" and t.valor in GATILHOS_DE_CHAMADA and k + 1 < len(ts) and ts[k + 1].valor == "(":
                    gatilho = (k + 2, t.valor)
                elif (t.tipo == "id" and t.valor in ROTULOS and k + 1 < len(ts) and ts[k + 1].valor == ":"
                      and k > 0 and ts[k - 1].valor in ("(", ",")):
                    gatilho = (k + 2, t.valor + ":")
                if gatilho:
                    j, nivel = gatilho[0], 1
                    rotulo = gatilho[1].endswith(":")
                    while j < len(ts):
                        u = ts[j]
                        if u.tipo == "p" and u.valor in "([{":
                            nivel += 1
                        elif u.tipo == "p" and u.valor in ")]}":
                            nivel -= 1
                            if nivel == 0:
                                break
                        elif u.tipo == "p" and u.valor == "," and nivel == 1 and rotulo:
                            break
                        elif u.tipo == "id" and u.valor in ("verbatim", "systemName", "systemImage", "named", "image"):
                            # `Text(verbatim:)` e nomes de símbolo não são texto
                            if j + 1 < len(ts) and ts[j + 1].valor == ":":
                                j += 3
                                continue
                        elif u.tipo == "lit" and nivel == 1 and j not in consumidos and tem_letras(u.valor):
                            if not linha_isenta(src_linhas, u.linha):
                                literais.append(f"{rel}:{u.linha}: {gatilho[1]} {u.valor[:70]!r}")
                            consumidos.add(j)
                        if u.tipo == "id" and u.valor in ("tr", "trSistema") and j + 1 < len(ts) and ts[j + 1].valor == "(":
                            # o que está dentro do tr já foi (ou será) conferido acima
                            nivel2, j = 1, j + 2
                            while j < len(ts) and nivel2:
                                if ts[j].valor == "(" and ts[j].tipo == "p":
                                    nivel2 += 1
                                elif ts[j].valor == ")" and ts[j].tipo == "p":
                                    nivel2 -= 1
                                j += 1
                            continue
                        j += 1
                k += 1

# ------------------------------------------------------------------------------------------------
# Paridade
# ------------------------------------------------------------------------------------------------
faltando = 0
for pasta in PASTAS:
    for chave, onde in sorted(usadas[pasta].items()):
        achou = None
        for p in VISIVEIS[pasta]:
            if chave in tabelas[p]:
                achou = (p, tabelas[p][chave][0])
                break
        if not achou:
            faltando += 1
            erro(f"falta EN para {chave!r} ({onde[0]}; a tabela de {pasta} ou Comum)")
            continue
        p, ingles = achou
        conferir_formato(chave, onde[0])
        conferir_formato(ingles, f"{p} (EN)")
        if p != pasta and pasta in ("Comum", "Extensao") and p not in VISIVEIS[pasta]:
            erro(f"{onde[0]}: {chave!r} só existe em {p}, que {pasta} não enxerga")
        if placeholders(chave) != placeholders(ingles):
            erro(f"placeholders diferentes: {chave!r} → {ingles!r}")

todas_usadas = {}
for pasta in PASTAS:
    for chave in usadas[pasta]:
        todas_usadas.setdefault(chave, set()).add(pasta)
for pasta in PASTAS:
    for chave, (_, arq) in sorted(tabelas[pasta].items()):
        quem = todas_usadas.get(chave, set())
        if not quem or not any(pasta in VISIVEIS[q] for q in quem):
            erro(f"{pasta}/en.lproj/{arq}: chave sem uso no código: {chave!r}")

for l in literais:
    erro(f"texto de interface sem tr: {l}")

# ------------------------------------------------------------------------------------------------
# Permissões (InfoPlist.strings)
# ------------------------------------------------------------------------------------------------
for alvo in ("App", "Extensao"):
    with open(os.path.join(RAIZ, alvo, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    pedidas = {k for k in info if k.endswith("UsageDescription")}
    if "CFBundleDisplayName" in info:
        pedidas.add("CFBundleDisplayName")
    conjuntos = {}
    for loc in ("en", "pt-BR"):
        cam = os.path.join(RAIZ, alvo, f"{loc}.lproj", "InfoPlist.strings")
        if not os.path.exists(cam):
            erro(f"{alvo}: falta {loc}.lproj/InfoPlist.strings")
            continue
        conjuntos[loc] = ler_strings(cam)
        if loc == "pt-BR":
            for k in pedidas:
                if k in conjuntos[loc] and k in info and conjuntos[loc][k] != info[k]:
                    erro(f"{alvo}/pt-BR.lproj/InfoPlist.strings: {k} diferente do Info.plist")
        for k in pedidas - set(conjuntos[loc]):
            erro(f"{alvo}/{loc}.lproj/InfoPlist.strings: falta {k}")
    if len(conjuntos) == 2 and set(conjuntos["en"]) != set(conjuntos["pt-BR"]):
        erro(f"{alvo}: InfoPlist.strings com chaves diferentes entre en e pt-BR")

# ------------------------------------------------------------------------------------------------
total_en = sum(len(t) for t in tabelas.values())
print(f"tradução iOS: {total_tr} chamadas tr, {sum(len(u) for u in usadas.values())} chaves no código, "
      f"{total_en} linhas EN em {len(nomes_de_tabela)} tabelas, {faltando} faltando, "
      f"{len(literais)} literais de interface sem tr")
for pasta in PASTAS:
    print(f"  {pasta:13s} {len(usadas[pasta]):5d} chaves no código  {len(tabelas[pasta]):5d} na tabela EN")
if erros:
    for e in erros:
        print("  FALHA " + e)
    print(f"REPROVADO: {len(erros)} problema(s)")
    sys.exit(1)
print("APROVADO")
