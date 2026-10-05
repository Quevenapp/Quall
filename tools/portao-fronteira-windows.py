#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""As conferências da fronteira **do lado Windows** — as que o `rustc` não faz.

`tools/confere-fronteira.py` cobra duas coisas nas cascas de C, Objective-C e Swift:

1. struct da fronteira montado à mão tem de ser **zerado antes de preenchido**;
2. o padrão `(buf, cap)` tem de **perguntar o tamanho antes**.

Nenhuma das duas o alcança em `apps/windows` e `integrations/camera-windows`: os dois são Rust, o
`quall.h` não aparece em lugar nenhum deles (o app fala com o núcleo direto, em Rust), e a
varredura daquele roteiro é de `.c`, `.m` e `.swift`. O resultado é que rodar `confere-fronteira.py`
sobre a árvore do Windows devolve **zero construções conferidas** — verde por não casar com nada,
que é o modo de falha contra o qual aquele mesmo arquivo avisa em letras grandes.

Este roteiro leva as **mesmas duas ideias** para a linguagem em que o lado Windows está escrito.
Não são regras novas: são as mesmas duas, com o Win32 no lugar do `quall.h`.

## Conferência 1 — o padrão `(buf, cap)` do Win32, consumido com buffer fixo

O contrato do `quall.h` é: chame com `buf` nulo para perguntar o tamanho, aloque, chame de novo;
**buffer pequeno demais não devolve negativo** — devolve o tamanho necessário e não escreve nada.
Quem trata isso como sucesso lê um buffer zerado.

O Win32 tem exatamente a mesma família, e ela falha **pior**: em vez de não escrever, várias delas
**truncam e devolvem um número que parece sucesso**. `GetModuleFileNameW` é o caso didático — com
buffer curto ela copia o que cabe, devolve `nSize` (não zero, não negativo) e só o
`GetLastError() == ERROR_INSUFFICIENT_BUFFER` denuncia. Quem não olha o erro fica com um caminho
truncado que continua parecendo um caminho.

E aqui isso não é hipotético. `integrations/camera-windows/fonte/src/lib.rs` usava
`GetModuleFileNameW` com `[0u16; 520]` para descobrir o caminho da própria DLL e escrevia o
resultado em `HKLM\...\CLSID\{…}\InprocServer32`. Um caminho truncado ali registra um servidor COM
que aponta para um arquivo que não existe — a câmera aparece na lista e nunca entrega quadro,
que é o sintoma mais caro deste repositório.

Buffer fixo é permitido **quando o conteúdo é genuinamente limitado**, e nesse caso o motivo fica
escrito em `PERMITIDOS`. Silêncio não conta como julgamento — mesma regra do outro roteiro.

## Conferência 2 — struct do Win32 montado sem zerar

Em Rust o defeito do `quall_jni.c` (declarar o struct e preencher campo a campo, deixando o campo
novo com lixo de pilha) **não compila**: um literal de struct tem de nomear todos os campos ou
terminar em `..Default::default()`. A porta pela qual o defeito volta é uma só, e são três folhas:
`MaybeUninit::assume_init`, `mem::zeroed` seguido de preenchimento parcial, e `mem::transmute`
para um tipo do Win32.

Hoje não há **nenhuma** ocorrência dessas três nas duas árvores, e é por isso que esta conferência
precisa da aferição mais do que a outra: uma regra com zero achados se lê igual estando certa e
estando cega.

## Aferir antes de medir

`--calibrar` monta arquivos em Rust com defeitos conhecidos **e** com controles negativos — código
correto que a conferência **não** pode acusar. O controle negativo é a metade que falta na
aferição do lado de cá: uma regex que acusa tudo também pega os quatro defeitos conhecidos.

Uso:

    tools/portao-fronteira-windows.py             # confere e falha com saída != 0
    tools/portao-fronteira-windows.py --calibrar  # afere contra defeitos e controles conhecidos
    tools/portao-fronteira-windows.py --lista     # só lista o que ela enxerga, sem julgar
"""

import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# As árvores do lado Windows. Ficam nomeadas aqui para o roteiro dizer **onde** olhou: uma
# conferência que varre a árvore inteira e não acha nada não distingue "não há defeito" de
# "não há arquivo".
ARVORES = (
    os.path.join("apps", "windows"),
    os.path.join("integrations", "camera-windows"),
)

IGNORAR = (
    os.sep + "target" + os.sep,
    os.sep + ".git" + os.sep,
)

# ------------------------------------------------------------------------------------------------
# A família `(buf, cap)` do Win32.
#
# O critério para entrar aqui é o mesmo do `quall.h`: **buffer pequeno demais não é erro**. A
# função devolve um número que passa por sucesso, e a diferença só aparece no `GetLastError` ou
# numa comparação com a capacidade que ninguém faz. Cada entrada traz o contrato por extenso
# porque é ele que justifica a regra — não a API.
# ------------------------------------------------------------------------------------------------
BUF_CAP = {
    "GetModuleFileNameW":
        "com buffer curto ela TRUNCA, devolve `nSize` (parece sucesso) e só o `GetLastError() == "
        "ERROR_INSUFFICIENT_BUFFER` denuncia; devolve 0 só em falha de verdade",
    "GetModuleFileNameA":
        "idem `GetModuleFileNameW`",
    "GetWindowTextW":
        "copia o que couber e devolve o que copiou; não há como distinguir 'coube' de 'cortei'",
    "GetWindowTextA":
        "idem `GetWindowTextW`",
    "GetClassNameW":
        "trunca em silêncio e devolve o comprimento copiado",
    "GetCurrentDirectoryW":
        "devolve o tamanho NECESSÁRIO (com NUL) quando não cabe, e não escreve — positivo maior "
        "que a capacidade, exatamente como o `(buf, cap)` do `quall.h`",
    "GetTempPathW":
        "devolve o tamanho necessário quando não cabe",
    "GetTempPath2W":
        "devolve o tamanho necessário quando não cabe",
    "GetFullPathNameW":
        "devolve o tamanho necessário (com NUL) quando não cabe",
    "GetLongPathNameW":
        "devolve o tamanho necessário quando não cabe",
    "GetShortPathNameW":
        "devolve o tamanho necessário quando não cabe",
    "GetEnvironmentVariableW":
        "devolve o tamanho necessário quando não cabe, e não escreve",
    "ExpandEnvironmentStringsW":
        "devolve o tamanho necessário; acima de 32 Ki nem isso",
    "GetLogicalDriveStringsW":
        "devolve o tamanho necessário quando não cabe",
    "QueryFullProcessImageNameW":
        "falha com ERROR_INSUFFICIENT_BUFFER, mas o `lpdwSize` de entrada é a capacidade e é fácil "
        "confundi-lo com o tamanho de saída",
    "GetPrivateProfileStringW":
        "trunca e devolve `nSize - 1`, que parece um comprimento legítimo",
    "GetUserNameW":
        "falha e escreve o tamanho necessário no mesmo parâmetro que levou a capacidade",
    "GetComputerNameExW":
        "idem `GetUserNameW`",
    "FormatMessageW":
        "sem ALLOCATE_BUFFER ela trunca e devolve o que copiou",
    "GetFinalPathNameByHandleW":
        "devolve o tamanho necessário quando não cabe",
    "RegQueryValueExW":
        "devolve ERROR_MORE_DATA e o tamanho necessário no mesmo `lpcbData`",
    "RegGetValueW":
        "idem `RegQueryValueExW`",
    "GetString":
        "IMFAttributes::GetString devolve E_NOT_SUFFICIENT_BUFFER; o par correto é "
        "`GetStringLength` antes, ou `GetAllocatedString`",
}

# Um array fixo em Rust: `let mut x = [0u16; 520];`, `let mut x: [u16; 260] = [0; 260];`, etc.
ARRAY_FIXO = re.compile(
    r"let\s+(?:mut\s+)?(\w+)\s*(?::\s*\[\s*\w+\s*;\s*(\w+)\s*\])?\s*=\s*\[\s*0[a-z0-9]*\s*;\s*(\w+)\s*\]")

# `MaybeUninit`/`zeroed`/`transmute`: as três folhas da única porta pela qual o defeito do
# `quall_jni.c` volta em Rust.
PORTAS_DE_LIXO = re.compile(r"\b(assume_init|MaybeUninit|mem::zeroed|zeroed\s*\(\s*\)|transmute)\b")

# ------------------------------------------------------------------------------------------------
# Buffer fixo permitido, com o julgamento escrito. Chave: (caminho relativo, função do Win32).
#
# A regra para entrar aqui é a mesma do outro roteiro: **o tamanho da resposta é fixado pelo
# contrato, não pelo ambiente.** "Cabe hoje nesta bancada" não é motivo.
# ------------------------------------------------------------------------------------------------
PERMITIDOS = {
    # O texto de um `EDIT` cujo conteúdo o próprio app limita: o campo de PIN tem `EM_LIMITTEXT`
    # de 6 e o de endereço guarda um `SocketAddr` — um IPv6 com porta e colchetes cabe em ~54
    # caracteres. Não é "cabe hoje": um endereço maior que 128 já não seria um endereço, e o corte
    # está declarado no comentário da função desde que ela foi escrita.
    ("apps/windows/src/janela.rs", "GetWindowTextW"):
        "o conteúdo é limitado pelo próprio controle (PIN de 6; endereço IPv6 com porta cabe em "
        "~54); 128 é folga fixa, não estimativa.",
}

# `MaybeUninit`/`zeroed`/`transmute` julgados e permitidos, com o motivo escrito. Vazio hoje, e
# essa é a informação: o lado Windows não usa nenhuma das três.
PORTAS_PERMITIDAS = {}


# ------------------------------------------------------------------------------------------------
def fontes(arvores=None):
    for arvore in (arvores if arvores is not None else ARVORES):
        base_abs = os.path.join(RAIZ, arvore)
        if not os.path.isdir(base_abs):
            continue
        for base, dirs, arqs in os.walk(base_abs):
            dirs[:] = [d for d in dirs if not d.startswith(".") and d != "target"]
            if any(p in base + os.sep for p in IGNORAR):
                continue
            for a in sorted(arqs):
                if a.endswith(".rs"):
                    yield os.path.join(base, a)


def rel(caminho):
    return os.path.relpath(caminho, RAIZ).replace(os.sep, "/")


def sem_comentario(linha):
    return re.sub(r"//.*$", "", linha)


# ------------------------------------------------------------------------------------------------
# Conferência 1 — o padrão `(buf, cap)` do Win32
# ------------------------------------------------------------------------------------------------
def confere_buf_cap(listar, arquivos=None):
    faltas = []
    vistos = 0
    chamada = re.compile(r"\b(" + "|".join(sorted(BUF_CAP)) + r")\s*\(")

    for arq in (arquivos if arquivos is not None else fontes()):
        linhas = open(arq, encoding="utf-8").read().splitlines()
        for i, linha in enumerate(linhas):
            crua = sem_comentario(linha)
            m = chamada.search(crua)
            if not m:
                continue
            fn = m.group(1)
            # A definição/encaminhamento de um método homônimo não é consumo. `fonte.rs`
            # **implementa** `IMFAttributes::GetString` e repassa; acusá-lo seria acusar a
            # assinatura da interface, não um consumidor dela.
            if re.search(r"\bfn\s+" + re.escape(fn) + r"\b", crua):
                continue
            vistos += 1
            if listar:
                print("  %s:%d  %s" % (rel(arq), i + 1, fn))
                continue

            motivo = buffer_fixo(linhas, i, crua)
            if motivo is None:
                continue
            if (rel(arq), fn) in PERMITIDOS:
                continue
            faltas.append((rel(arq), i + 1,
                           "`%s` com %s — %s. O padrão é perguntar o tamanho primeiro (chamada "
                           "com capacidade 0, ou `Vec` que cresce), ou conferir o retorno contra "
                           "a capacidade. Se o conteúdo é mesmo limitado, escreva o motivo em "
                           "tools/portao-fronteira-windows.py::PERMITIDOS"
                           % (fn, motivo, BUF_CAP[fn])))
    return faltas, vistos


def buffer_fixo(linhas, i, crua):
    """Um array de tamanho fixo declarado acima e passado nesta chamada.

    A janela é de 10 linhas para trás — o mesmo formato da regra de Swift do outro roteiro, e pelo
    mesmo motivo: a declaração e a chamada vivem juntas nas duas linguagens.
    """
    for j in range(max(0, i - 10), i + 1):
        for m in ARRAY_FIXO.finditer(sem_comentario(linhas[j])):
            nome = m.group(1)
            tamanho = m.group(3) or m.group(2)
            if re.search(r"[(,&]\s*(?:&\s*mut\s+)?" + re.escape(nome) + r"\b", crua):
                return "o buffer fixo `%s` de %s elementos" % (nome, tamanho)
    return None


# ------------------------------------------------------------------------------------------------
# Conferência 2 — struct do Win32 montado sem zerar
# ------------------------------------------------------------------------------------------------
def confere_zeragem(listar, arquivos=None):
    faltas = []
    vistos = 0
    for arq in (arquivos if arquivos is not None else fontes()):
        linhas = open(arq, encoding="utf-8").read().splitlines()
        for i, linha in enumerate(linhas):
            crua = sem_comentario(linha)
            m = PORTAS_DE_LIXO.search(crua)
            if not m:
                continue
            vistos += 1
            if listar:
                print("  %s:%d  %s" % (rel(arq), i + 1, m.group(1)))
                continue
            if (rel(arq), i + 1) in PORTAS_PERMITIDAS:
                continue
            faltas.append((rel(arq), i + 1,
                           "`%s` — é por aqui que o defeito do `quall_jni.c` (struct preenchido "
                           "campo a campo, campo novo com lixo de pilha) volta em Rust. Use "
                           "`::default()` ou um literal que nomeie todos os campos; se não der, "
                           "escreva o motivo em tools/portao-fronteira-windows.py::"
                           "PORTAS_PERMITIDAS" % m.group(1)))
    return faltas, vistos


# ------------------------------------------------------------------------------------------------
# Calibragem — com controle negativo, que é a metade que falta na aferição do lado de cá
#
# Quatro defeitos conhecidos e três controles negativos. O controle negativo importa: uma regex
# que acusa **tudo** pega os quatro defeitos e passa na aferição do outro roteiro. Aqui ela é
# reprovada.
# ------------------------------------------------------------------------------------------------
CALIBRAGEM_DEFEITOS = '''// gerado por --calibrar; apagado no fim
fn a() -> String {
    let mut buf = [0u16; 520];
    let n = unsafe { GetModuleFileNameW(Some(h), &mut buf) } as usize;
    String::from_utf16_lossy(&buf[..n])
}
fn b(hwnd: HWND) -> String {
    let mut buffer = [0u16; 128];
    let n = unsafe { GetWindowTextW(hwnd, &mut buffer) };
    String::from_utf16_lossy(&buffer[..n as usize])
}
fn c() -> D3D11_TEXTURE2D_DESC {
    let mut d: D3D11_TEXTURE2D_DESC = unsafe { std::mem::zeroed() };
    d.Width = 1280;
    d
}
fn d() -> MONITORINFOEXW {
    let mut info = unsafe { MaybeUninit::<MONITORINFOEXW>::uninit().assume_init() };
    info.monitorInfo.cbSize = 40;
    info
}
'''

CALIBRAGEM_CONTROLES = '''// gerado por --calibrar; apagado no fim
// Controle negativo 1: o laço de duas chamadas, que e o jeito certo. Nao pode ser acusado.
fn certo_um() -> String {
    let mut buf: Vec<u16> = vec![0; 260];
    loop {
        let n = unsafe { GetModuleFileNameW(None, &mut buf) } as usize;
        if n == 0 { return String::new(); }
        if n < buf.len() { return String::from_utf16_lossy(&buf[..n]); }
        buf.resize(buf.len() * 2, 0);
    }
}
// Controle negativo 2: struct do Win32 zerado por `default()` e com o campo de auto-tamanho
// preenchido. Nao pode ser acusado.
fn certo_dois() -> DISPLAY_DEVICEW {
    DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() }
}
// Controle negativo 3: um array fixo que nao vai para nenhuma funcao da familia `(buf, cap)`.
fn certo_tres() -> u32 {
    let mut area = [0u8; 16];
    area[0] = 1;
    area[0] as u32
}
'''


def calibrar():
    import tempfile
    # **Por linha, e não por texto concatenado.** A primeira versão desta função procurava a marca
    # no texto de todas as faltas juntas, e por isso dizia "pegou" para uma regra que ela não
    # pegara: `MaybeUninit::…::assume_init()` casa nas duas alternativas da mesma regex, a busca
    # devolve a primeira (`MaybeUninit`), e a marca `assume_init` do outro caso vinha da mensagem
    # errada. Ancorar na linha do defeito tira essa ambiguidade.
    esperados = [
        (4, "GetModuleFileNameW", "(buf, cap): GetModuleFileNameW com buffer fixo"),
        (9, "GetWindowTextW", "(buf, cap): GetWindowTextW com buffer fixo"),
        (13, "mem::zeroed", "zeragem: mem::zeroed com preenchimento parcial"),
        (18, "MaybeUninit", "zeragem: MaybeUninit::uninit().assume_init()"),
    ]
    ruim = 0
    with tempfile.TemporaryDirectory() as tmp:
        ruins = os.path.join(tmp, "defeitos.rs")
        bons = os.path.join(tmp, "controles.rs")
        with open(ruins, "w", encoding="utf-8") as f:
            f.write(CALIBRAGEM_DEFEITOS)
        with open(bons, "w", encoding="utf-8") as f:
            f.write(CALIBRAGEM_CONTROLES)

        faltas = (confere_buf_cap(False, [ruins])[0] + confere_zeragem(False, [ruins])[0])
        for linha, marca, rotulo in esperados:
            if any(l == linha and marca in msg for _, l, msg in faltas):
                print("  pegou        %s" % rotulo)
            else:
                print("  NÃO PEGOU    %s — a conferência está cega para esta regra" % rotulo)
                ruim = 1
        sobrando = [(l, m) for _, l, m in faltas if l not in [e[0] for e in esperados]]
        if sobrando:
            print("  ACUSOU A MAIS %d linha(s) sem defeito plantado: %s"
                  % (len(sobrando), ", ".join(str(l) for l, _ in sobrando)))
            ruim = 1

        # O controle negativo. Uma regex que acusa tudo passaria na metade de cima.
        limpas = (confere_buf_cap(False, [bons])[0] + confere_zeragem(False, [bons])[0])
        if limpas:
            print("  ACUSOU CERTO %d construção(ões) correta(s) — a conferência acusa demais:"
                  % len(limpas))
            for _, linha, msg in limpas:
                print("               linha %d: %s" % (linha, msg[:110]))
            ruim = 1
        else:
            print("  não acusou   os três controles negativos (laço de duas chamadas, struct com "
                  "`..Default::default()`, array fixo fora da família)")
    return ruim


# ------------------------------------------------------------------------------------------------
def main():
    listar = "--lista" in sys.argv

    if "--calibrar" in sys.argv:
        print("fronteira-windows: calibragem contra 4 defeitos e 3 controles negativos:")
        return calibrar()

    arvores_presentes = [a for a in ARVORES if os.path.isdir(os.path.join(RAIZ, a))]
    if not arvores_presentes:
        print("FALHOU: nenhuma das árvores do Windows existe em %s (%s)"
              % (RAIZ, ", ".join(ARVORES)))
        return 2

    print("fronteira-windows: %d funções `(buf, cap)` do Win32, árvores: %s"
          % (len(BUF_CAP), ", ".join(arvores_presentes)))

    if listar:
        print("\n-- chamadas do padrão (buf, cap) do Win32 --")
    faltas_a, vistos_a = confere_buf_cap(listar)
    if listar:
        print("\n-- MaybeUninit / mem::zeroed / transmute --")
    faltas_b, vistos_b = confere_zeragem(listar)
    if listar:
        return 0

    print("  padrão (buf, cap): %d chamadas conferidas, %d com buffer fixo julgado e permitido"
          % (vistos_a, len(PERMITIDOS)))
    print("  zeragem em Rust  : %d construções de `MaybeUninit`/`zeroed`/`transmute` conferidas"
          % vistos_b)

    # A guarda contra o verde vazio. Zero chamadas conferidas não é "está tudo certo": é "não
    # achei arquivo nenhum", e as duas se leem igual no terminal. A conferência 2 pode ser zero de
    # verdade (é o estado desejado), a 1 não — o lado Windows fala Win32 em toda tela.
    if vistos_a == 0:
        print("\nFALHOU: zero chamadas do padrão `(buf, cap)` encontradas nas árvores do Windows.")
        print("        Isso não é 'passou': é a conferência não tendo casado com nada.")
        return 1

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
