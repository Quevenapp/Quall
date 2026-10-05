#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""As conferências da fronteira C que o compilador não faz.

O portão (`tools/portao.sh`) compila todas as cascas. Isso pega o defeito que quebra o build —
o `audio_codec` que três cascas Swift não acompanharam — e **não pega** os dois que compilam:

1. **Struct da fronteira C montado em C sem zerar.** O `quall_jni.c` montava `QuallTrackDesc`
   campo a campo. Quando a rodada de áudio acrescentou `audio_codec`, o Swift quebrou o build e
   alguém viu; em C o mesmo descuido compila, roda, e manda **lixo de pilha** para o núcleo.
   A conferência lê `crates/quall-ffi/include/quall.h`, sabe quantos campos cada struct tem, e
   cobra: ou `memset` logo depois da declaração, ou um inicializador que nomeia **todos** os
   campos. Um inicializador parcial passa hoje (o C zera o resto) e vira lixo no dia em que a
   declaração virar `Quall… x; x.a = …;` — que é como o defeito do JNI nasceu.

2. **Padrão `(buf, cap)` consumido com buffer fixo.** O contrato do header é: chame com `buf`
   nulo para perguntar o tamanho, aloque, chame de novo. Buffer pequeno demais **não devolve
   negativo** — devolve o tamanho necessário e não escreve nada. Quem trata isso como sucesso lê
   um buffer zerado e recebe string vazia, sem erro em lugar nenhum. Foi o que parou de gravar o
   pareamento do app do macOS em 26/08, quando o `pares.json` passou de 256 bytes.

   Buffer fixo é permitido **quando o conteúdo é genuinamente limitado**, e nesse caso o motivo
   fica escrito em `PERMITIDOS`, abaixo. Silêncio não conta como julgamento.

Uso:

    tools/confere-fronteira.py             # confere e falha com saída != 0
    tools/confere-fronteira.py --calibrar  # afere contra quatro defeitos conhecidos
    tools/confere-fronteira.py --lista     # só lista o que ela enxerga, sem julgar
"""

import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = os.path.join(RAIZ, "crates", "quall-ffi", "include", "quall.h")

# Pastas que não são nossas ou não são código de casca.
IGNORAR = (
    os.sep + "target" + os.sep,
    os.sep + "vendor" + os.sep,
    os.sep + ".libobs" + os.sep,
    os.sep + ".git" + os.sep,
    os.sep + "build" + os.sep,
    os.sep + "DD" + os.sep,
)

# ------------------------------------------------------------------------------------------------
# Buffer fixo permitido, com o julgamento escrito. Chave: (caminho relativo, função da fronteira).
#
# A regra para entrar aqui é uma só: **o tamanho da resposta é fixado pelo contrato, não pelo
# ambiente.** "Cabe hoje nesta bancada" não é motivo — foi exatamente o que se disse do
# `pares.json` antes de ele passar de 256 bytes.
# ------------------------------------------------------------------------------------------------
PERMITIDOS = {
    # `quall_generate_pin` devolve o `to_display()` de um `Pin`, que é **seis dígitos**: 7 bytes
    # com o NUL. Não é "cabe hoje": o header, o tipo `Pin` do núcleo e a tela de PIN das quatro
    # cascas fixam seis dígitos, e um PIN de tamanho variável mudaria o produto, não o buffer.
    # 16 bytes é mais que o dobro do necessário.
    #
    # Perguntar o tamanho antes seria **pior** aqui, e não só mais lento: a primeira chamada
    # sortearia um PIN e o jogaria fora, e a segunda sortearia outro. Duas entropias gastas para
    # usar uma. O que estes três sítios precisam não é do laço de duas chamadas — é de **conferir
    # que coube**, que é o que o portão cobra abaixo.
    ("apps/macos/Sources/QuallNetKit/NucleoDeRede.swift", "quall_generate_pin"):
        "PIN é de seis dígitos por contrato (7 bytes com NUL); 16 é folga fixa, não estimativa.",
    ("apps/ios/Quall/Comum/Nucleo.swift", "quall_generate_pin"):
        "PIN é de seis dígitos por contrato (7 bytes com NUL); 16 é folga fixa, não estimativa.",
    ("apps/ios/PortaoAppex/App/ProvaDoNucleo.swift", "quall_generate_pin"):
        "PIN é de seis dígitos por contrato (7 bytes com NUL); 16 é folga fixa, não estimativa.",

    # O JNI usa um buffer de pilha de 4 KiB e **cresce no heap** quando não cabe, nas duas funções
    # que crescem sem teto (o estado de pareamento e a lista de aparelhos). Nas outras ele confere
    # o retorno contra o tamanho e devolve um valor de falta explícito. Ver `quall_jni.c`.
    ("apps/android/app/src/main/cpp/quall_jni.c", "quall_generate_pin"):
        "PIN é de seis dígitos por contrato; o buffer é de 4 KiB e o retorno é conferido.",

    # Exemplos da própria fronteira: são programas de demonstração de ~250 linhas com rótulo e
    # par fixos no próprio arquivo. Eles não consomem nada que venha de fora.
    ("crates/quall-ffi/examples/sessao.c", "quall_track_label"):
        "exemplo: o rótulo é a constante \"Tela de teste\" declarada dez linhas acima.",
    ("crates/quall-ffi/examples/sessao.c", "quall_session_peer_json"):
        "exemplo: o par é o processo do próprio arquivo, com nome constante.",
    ("crates/quall-ffi/examples/sessao.c", "quall_track_stats_json"):
        "exemplo: imprime e descarta; um JSON truncado ali não corrompe estado nenhum.",
}


# ------------------------------------------------------------------------------------------------
# Ler o header
# ------------------------------------------------------------------------------------------------
def campos_dos_structs(texto):
    """`{nome do struct: [campos]}` a partir de `typedef struct X { … } X;` do header."""
    fora = {}
    for m in re.finditer(r"typedef struct (Quall\w+) \{(.*?)\n\} \1;", texto, re.S):
        nome, corpo = m.group(1), m.group(2)
        corpo = re.sub(r"/\*.*?\*/", "", corpo, flags=re.S)
        campos = []
        for linha in corpo.splitlines():
            linha = linha.strip()
            if not linha or linha.startswith("*") or linha.startswith("//"):
                continue
            c = re.match(r"^[\w \*]+?\**(\w+);$", linha)
            if c:
                campos.append(c.group(1))
        if campos:
            fora[nome] = campos
    return fora


def funcoes_buf_cap(texto):
    """Nomes das funções do padrão `(buf, cap)` de texto, lidos do próprio header."""
    fora = set()
    for m in re.finditer(r"intptr_t (quall_\w+)\(([^;]*?)\);", texto, re.S):
        args = " ".join(m.group(2).split())
        if "char *buf" in args and "uintptr_t cap" in args:
            fora.add(m.group(1))
    return fora


# ------------------------------------------------------------------------------------------------
# Varredura de arquivos
# ------------------------------------------------------------------------------------------------
def fontes(extensoes):
    for base, dirs, arqs in os.walk(RAIZ):
        dirs[:] = [d for d in dirs if not d.startswith(".") or d == ".github"]
        caminho_base = base + os.sep
        if any(p in caminho_base for p in IGNORAR):
            continue
        for a in sorted(arqs):
            if a.endswith(extensoes):
                yield os.path.join(base, a)


def rel(caminho):
    # **Sempre com barra normal, inclusive no Windows.** As chaves de `PERMITIDOS` são escritas
    # com `/`, e no Windows o `os.path.relpath` devolve `\` — nenhuma delas casaria, e a
    # conferência reprovaria os **sete** sítios já julgados como se fossem defeitos novos.
    #
    # Medido em 2026-08-30, na primeira vez que este roteiro rodou no Dell (pelo braço Windows do
    # portão): 8 PROBLEMAS lá contra CONFERÊNCIA OK no MacBook, sobre a mesma árvore, com os
    # mesmos 16 structs e as mesmas 63 chamadas conferidas. Um instrumento que muda de resposta
    # com o separador de caminho não é instrumento.
    return os.path.relpath(caminho, RAIZ).replace(os.sep, "/")


def sem_comentario(linha):
    return re.sub(r"//.*$", "", linha)


# ------------------------------------------------------------------------------------------------
# Conferência 1 — struct da fronteira montado em C
# ------------------------------------------------------------------------------------------------
def confere_zeragem(structs, listar, arquivos=None):
    faltas = []
    vistos = 0
    nomes = "|".join(sorted(structs))
    # `(?:^|[{;])` e não só `^`: uma declaração pode vir depois de uma chave ou de outro comando
    # **na mesma linha**, e a primeira versão desta regex era cega para isso — ela dizia
    # "CONFERÊNCIA OK" para `void x(void) { QuallFrame f; f.len = 0; }`. Foi a aferição que
    # encontrou o buraco, que é para o que ela serve. Parâmetro de função não entra: ali o que
    # precede é `(` ou `,`, que ficam de fora do conjunto de propósito.
    decl = re.compile(
        r"(?:^|[{;])\s*(?:const\s+)?(?:struct\s+)?(" + nomes + r")\s+(\w+)(\[\s*\w*\s*\])?\s*(=|;)")

    for arq in (arquivos if arquivos is not None else fontes((".c", ".m"))):
        linhas = open(arq, encoding="utf-8").read().splitlines()
        for i, linha in enumerate(linhas):
            crua = sem_comentario(linha)
            m = decl.search(crua)
            if not m:
                continue
            struct, var, arranjo, fecho = m.group(1), m.group(2), m.group(3), m.group(4)
            vistos += 1
            if listar:
                print("  %s:%d  %s %s%s" % (rel(arq), i + 1, struct, var, arranjo or ""))
                continue

            if fecho == ";":
                # Sem inicializador: exige `memset` do struct inteiro nas próximas linhas.
                janela = " ".join(linhas[i:i + 6])
                alvo = var if arranjo else "&" + var
                padrao = r"memset\s*\(\s*%s\s*,\s*0\s*,\s*sizeof\s*\(?\s*%s\s*\)?\s*\)" % (
                    re.escape(alvo), re.escape(var))
                if not re.search(padrao, janela):
                    faltas.append((rel(arq), i + 1,
                                   "`%s %s` sem `memset(%s, 0, sizeof %s)` logo abaixo"
                                   % (struct, var, alvo, var)))
                continue

            # Com inicializador. Copiar o retorno de uma função é seguro (o struct vem inteiro).
            resto = crua.split("=", 1)[1].strip()
            if not resto.startswith("{"):
                continue
            corpo = corpo_das_chaves(linhas, i)
            if corpo is None:
                faltas.append((rel(arq), i + 1,
                               "`%s %s = {` não fecha as chaves em 40 linhas" % (struct, var)))
                continue
            esperado = structs[struct]
            nomeados = re.findall(r"\.(\w+)\s*=", corpo)
            if nomeados:
                faltando = [c for c in esperado if c not in nomeados]
                if faltando:
                    faltas.append((rel(arq), i + 1,
                                   "`%s %s = {…}` não nomeia %s — inicializador parcial vira lixo "
                                   "no dia em que virar atribuição campo a campo"
                                   % (struct, var, ", ".join(faltando))))
            else:
                itens = elementos(corpo)
                if itens and len(itens) < len(esperado):
                    faltas.append((rel(arq), i + 1,
                                   "`%s %s = {…}` dá %d de %d campos por posição; use `memset` "
                                   "ou nomeie todos (`.campo = …`)"
                                   % (struct, var, len(itens), len(esperado))))
    return faltas, vistos


def corpo_das_chaves(linhas, i):
    """O texto entre a primeira `{` da linha `i` e a `}` que a fecha."""
    texto = "\n".join(linhas[i:i + 40])
    inicio = texto.index("{")
    nivel = 0
    for j in range(inicio, len(texto)):
        if texto[j] == "{":
            nivel += 1
        elif texto[j] == "}":
            nivel -= 1
            if nivel == 0:
                return texto[inicio + 1:j]
    return None


def elementos(corpo):
    """Elementos de primeiro nível de um inicializador, separados por vírgula."""
    fora, atual, nivel = [], "", 0
    for c in corpo:
        if c in "{([":
            nivel += 1
        elif c in "})]":
            nivel -= 1
        if c == "," and nivel == 0:
            fora.append(atual.strip())
            atual = ""
        else:
            atual += c
    if atual.strip():
        fora.append(atual.strip())
    return [e for e in fora if e and not e.startswith("//")]


# ------------------------------------------------------------------------------------------------
# Conferência 2 — o padrão `(buf, cap)`
# ------------------------------------------------------------------------------------------------
def confere_buf_cap(funcoes, listar, arquivos=None):
    faltas = []
    vistos = 0
    nomes = "|".join(sorted(funcoes))
    chamada = re.compile(r"\b(" + nomes + r")\s*\(")

    for arq in (arquivos if arquivos is not None else fontes((".c", ".m", ".swift"))):
        linhas = open(arq, encoding="utf-8").read().splitlines()
        fixos_c = arrays_fixos_em_c(linhas)
        for i, linha in enumerate(linhas):
            crua = sem_comentario(linha)
            m = chamada.search(crua)
            if not m:
                continue
            fn = m.group(1)
            vistos += 1
            if listar:
                print("  %s:%d  %s" % (rel(arq), i + 1, fn))
                continue

            chave = (rel(arq), fn)
            motivo = None
            if arq.endswith(".swift"):
                motivo = swift_buffer_fixo(linhas, i)
            else:
                motivo = c_buffer_fixo(crua, fixos_c)
            if motivo is None:
                continue
            if chave in PERMITIDOS:
                continue
            faltas.append((rel(arq), i + 1,
                           "`%s` com %s — o padrão é perguntar o tamanho com `buf` nulo primeiro. "
                           "Se o conteúdo é mesmo limitado, escreva o motivo em "
                           "tools/confere-fronteira.py::PERMITIDOS" % (fn, motivo)))
    return faltas, vistos


def arrays_fixos_em_c(linhas):
    """`{nome: tamanho}` de todo `char x[N]` declarado no arquivo, com N literal ou macro."""
    fora = {}
    for linha in linhas:
        for m in re.finditer(r"\bchar\s+(\w+)\s*\[\s*(\w+)\s*\]", sem_comentario(linha)):
            fora[m.group(1)] = m.group(2)
    return fora


def c_buffer_fixo(linha, fixos):
    for nome, tamanho in fixos.items():
        if re.search(r"[(,]\s*%s\s*,\s*sizeof\b" % re.escape(nome), linha):
            return "o buffer fixo `char %s[%s]`" % (nome, tamanho)
    return None


def swift_buffer_fixo(linhas, i):
    """Um `[CChar](repeating: 0, count: <literal>)` nas 8 linhas acima da chamada."""
    for j in range(max(0, i - 8), i + 1):
        m = re.search(r"\[CChar\]\(repeating:\s*0,\s*count:\s*(\d+)\s*\)", linhas[j])
        if m:
            return "um buffer fixo de %s bytes" % m.group(1)
    return None


# ------------------------------------------------------------------------------------------------
# Calibragem — porque instrumento não aferido contra caso conhecido não é instrumento
#
# Esta casa já pagou três vezes esta semana por publicar número de instrumento não aferido. Uma
# conferência que diz "CONFERÊNCIA OK" sem nunca ter sido vista **falhando** não prova nada: ela
# pode estar verde porque o código está certo, ou porque a regex não casa com nada.
#
# `--calibrar` monta um arquivo em C com **quatro defeitos conhecidos** e exige
# que os três sejam pegos. Roda em segundos e vive dentro do próprio roteiro, para ser repetível
# em vez de ser uma frase de relatório.
# ------------------------------------------------------------------------------------------------
CALIBRAGEM = '''/* gerado por --calibrar; apagado no fim */
#include <string.h>
#include "quall.h"
void a(void) {
    QuallTrackDesc d;
    d.kind = QUALL_TRACK_KIND_SCREEN;
    d.label = "x";
    (void)d;
}
void b(const QuallTrack *t) {
    char rotulo[256];
    quall_track_label(t, rotulo, sizeof rotulo);
}
void c(void) {
    QuallDeviceDesc m = {"id", "nome"};
    (void)m;
}
void d(void) { QuallFrame q; q.len = 0; (void)q; }
'''


def calibrar(structs, funcoes):
    import tempfile
    esperados = [
        ("zeragem: declaração sem memset", "QuallTrackDesc d"),
        ("zeragem: inicializador parcial", "QuallDeviceDesc m"),
        ("zeragem: declaração no meio da linha", "QuallFrame q"),
        ("(buf, cap): buffer fixo", "quall_track_label"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        arq = os.path.join(tmp, "_calibragem.c")
        with open(arq, "w", encoding="utf-8") as f:
            f.write(CALIBRAGEM)
        faltas = (confere_zeragem(structs, False, [arq])[0]
                  + confere_buf_cap(funcoes, False, [arq])[0])

    texto = " | ".join(m for _, _, m in faltas)
    ruim = 0
    for rotulo, marca in esperados:
        if marca in texto:
            print("  pegou  %s" % rotulo)
        else:
            print("  NÃO PEGOU  %s — a conferência está cega para esta regra" % rotulo)
            ruim = 1
    return ruim


# ------------------------------------------------------------------------------------------------
def main():
    listar = "--lista" in sys.argv
    texto = open(HEADER, encoding="utf-8").read()
    structs = campos_dos_structs(texto)
    funcoes = funcoes_buf_cap(texto)

    if not structs or not funcoes:
        print("FALHOU: não consegui ler %s (structs=%d, funções=%d)"
              % (rel(HEADER), len(structs), len(funcoes)))
        return 2

    print("fronteira: %d structs, %d funções `(buf, cap)` lidas de %s"
          % (len(structs), len(funcoes), rel(HEADER)))

    if "--calibrar" in sys.argv:
        print("calibragem contra quatro defeitos conhecidos:")
        return calibrar(structs, funcoes)

    if listar:
        print("\n-- structs da fronteira montados em C --")
    faltas_a, vistos_a = confere_zeragem(structs, listar)
    if listar:
        print("\n-- chamadas do padrão (buf, cap) --")
    faltas_b, vistos_b = confere_buf_cap(funcoes, listar)

    if listar:
        return 0

    print("  zeragem em C     : %d construções conferidas" % vistos_a)
    print("  padrão (buf, cap): %d chamadas conferidas, %d com buffer fixo julgado e permitido"
          % (vistos_b, len(PERMITIDOS)))

    faltas = faltas_a + faltas_b
    if not faltas:
        print("CONFERÊNCIA OK")
        return 0

    print("\n%d PROBLEMA(S):" % len(faltas))
    for arq, linha, msg in faltas:
        print("  %s:%d\n      %s" % (arq, linha, msg))
    return 1


if __name__ == "__main__":
    sys.exit(main())
