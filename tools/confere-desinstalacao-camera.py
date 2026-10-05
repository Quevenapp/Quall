#!/usr/bin/env python3
"""Portão: a desinstalação da câmera virtual confere tudo que a instalação publica?

POR QUE ESTE ARQUIVO EXISTE
===========================

`docs/camera-virtual.md` registra o achado central de 2026-08-27:

    Um removedor que confere menos do que a criação publica **fabrica** o fantasma que promete
    eliminar. `MFCreateVirtualCamera` publica o nó em QUATRO classes de interface, mais o nó em
    `Enum\\SWD\\VCAMDEVAPI`: cinco lugares, não três. O documento dizia "três lugares" e o
    `remover.ps1` conferia DUAS das quatro classes antes de imprimir "removido inteiro".

E a lição que ele tira, em letra maiúscula no original:

    **Enumere o que existe, não confira contra uma lista que você escreveu.** Uma lista fixa
    envelhece em silêncio; uma busca, não.

Uma lição que mora só num documento envelhece do mesmo jeito que a lista que ela condena. Este
portão a transforma em teste: ele reprova qualquer script de remoção ou inventário da câmera
virtual que volte a conferir contra uma lista de GUIDs escrita à mão, e reprova qualquer
divergência entre os três lugares que hoje repetem o mesmo CLSID.

Ele roda em qualquer máquina — não precisa de Windows, nem de PowerShell, nem do Dell. É análise
de texto sobre os arquivos do repositório, e é de propósito: o custo de rodá-lo tem de ser baixo o
bastante para caber num portão de compilação.

    tools/confere-desinstalacao-camera.py            # a partir da raiz do repositório
    tools/confere-desinstalacao-camera.py --raiz /caminho

Saída 0 = passou. 1 = reprovou. 2 = erro de uso.

O QUE ELE **NÃO** PROVA
=======================

Que a remoção funciona. Isso só se prova numa máquina com uma câmera virtual publicada, rodando
`camera-desinstalar.ps1` e conferindo o registro depois — e de novo depois de um reinício, porque
um nó removido e conferido já voltou. Este portão prova que a ferramenta **procura** em vez de
listar; não prova que ela acha.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# As quatro classes de interface medidas em 2026-08-27. Elas estão aqui para serem PROCURADAS nos
# scripts, e não para serem usadas por script nenhum — é justamente a lista cuja presença em código
# reprova.
CLASSES_MEDIDAS = {
    "e5323777-f976-4f5b-9b55-b94699c46e44": "KSCATEGORY_VIDEO_CAMERA",
    "65e8773d-8f56-11d0-a3b9-00a0c9223196": "KSCATEGORY_CAPTURE",
    "6994ad05-93ef-11d0-a3cc-00a0c9223196": "KSCATEGORY_VIDEO",
    "588c8d20-c0e3-4fd3-b511-8f2f692156f8": "(sem nome documentado)",
}

# Os arquivos que mexem no ciclo de vida do nó de câmera virtual. Se um novo aparecer e não estiver
# aqui, ele escapa do portão — por isso a varredura de "arquivo esquecido", mais abaixo.
SCRIPTS_DE_NO = [
    "apps/windows/scripts/instalador/camera-desinstalar.ps1",
    "integrations/camera-windows/scripts/remover.ps1",
    "integrations/camera-windows/scripts/inventario-nos.ps1",
]

FONTE_CLSID = "integrations/camera-windows/fonte/src/lib.rs"
WXS = "apps/windows/scripts/instalador/Quall.wxs"

GUID = re.compile(r"\{?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}?")


class Resultado:
    def __init__(self) -> None:
        self.erros: list[str] = []
        self.oks: list[str] = []

    def ok(self, msg: str) -> None:
        self.oks.append(msg)

    def erro(self, msg: str) -> None:
        self.erros.append(msg)


def sem_comentarios_ps1(texto: str) -> str:
    """Tira comentários de PowerShell, para que a lista de GUIDs possa viver na prosa.

    A distinção importa: `camera-desinstalar.ps1` cita as quatro classes no cabeçalho — como
    história, para quem for mexer entender o que aconteceu — e o portão não pode reprovar por
    isso. O que ele reprova é a lista em **código**.
    """
    texto = re.sub(r"<#.*?#>", "", texto, flags=re.S)

    # Cortar em `#` com uma expressão regular era o caminho óbvio, e ele estava errado de um jeito
    # que este portão pegou em si mesmo na primeira execução: o padrão que a varredura de classes
    # usa é `("*#" + $hash + "#*")`, e um corte cego no primeiro `#` apaga justamente a linha que
    # prova que a busca existe. O portão reprovou os três scripts por não fazerem o que fazem.
    #
    # Não é um parser de PowerShell — é um cortador que respeita aspas, que é o mínimo para não
    # mentir sobre o próprio critério.
    linhas = []
    for linha in texto.splitlines():
        aspas = None
        corte = len(linha)
        for i, c in enumerate(linha):
            if aspas:
                if c == aspas:
                    aspas = None
            elif c in "\"'":
                aspas = c
            elif c == "#" and (i == 0 or linha[i - 1] != "`"):
                corte = i
                break
        linhas.append(linha[:corte])
    return "\n".join(linhas)


def sem_comentarios_xml(texto: str) -> str:
    return re.sub(r"<!--.*?-->", "", texto, flags=re.S)


def clsid_da_fonte(raiz: Path, r: Resultado) -> str | None:
    p = raiz / FONTE_CLSID
    if not p.exists():
        r.erro(f"não achei {FONTE_CLSID} — o CLSID da fonte de mídia é a referência de todos os outros")
        return None
    m = re.search(r'CLSID_TEXTO:\s*&str\s*=\s*"(\{[0-9A-Fa-f-]+\})"', p.read_text(encoding="utf-8", errors="replace"))
    if not m:
        r.erro(f"{FONTE_CLSID}: não achei `CLSID_TEXTO` — o formato mudou?")
        return None
    r.ok(f"CLSID da fonte de mídia: {m.group(1)}  ({FONTE_CLSID})")
    return m.group(1).upper()


def confere_clsid_repetido(raiz: Path, referencia: str, r: Resultado) -> None:
    """O mesmo GUID está escrito à mão em quatro arquivos. Divergir é o modo de falha barato.

    O `camera-desinstalar.ps1` usa o CLSID para decidir de QUEM é cada nó. Se ele divergir do que a
    DLL registra, a varredura classifica o nó do Quall como "de outros" e o preserva — a
    desinstalação sai limpa, sem remover nada, e ninguém percebe até a câmera fantasma aparecer.
    """
    alvos = {
        WXS: r'ClsidFonte\s*=\s*"(\{[0-9A-Fa-f-]+\})"',
        "apps/windows/scripts/instalador/camera-desinstalar.ps1": r'\$Clsid\s*=\s*"(\{[0-9A-Fa-f-]+\})"',
        "integrations/camera-windows/scripts/remover.ps1": r'\$Clsid\s*=\s*"(\{[0-9A-Fa-f-]+\})"',
        "integrations/camera-windows/scripts/inventario-nos.ps1": r'\$Clsid\s*=\s*"(\{[0-9A-Fa-f-]+\})"',
    }
    for rel, padrao in alvos.items():
        p = raiz / rel
        if not p.exists():
            r.erro(f"não achei {rel}")
            continue
        m = re.search(padrao, p.read_text(encoding="utf-8", errors="replace"))
        if not m:
            r.erro(f"{rel}: não achei o CLSID no formato esperado")
        elif m.group(1).upper() != referencia:
            r.erro(f"{rel}: CLSID {m.group(1)} != {referencia} da DLL — a varredura trataria o nó do Quall como de outro dono")
        else:
            r.ok(f"{rel}: CLSID confere")


def confere_busca_em_vez_de_lista(raiz: Path, r: Resultado) -> None:
    for rel in SCRIPTS_DE_NO:
        p = raiz / rel
        if not p.exists():
            r.erro(f"não achei {rel}")
            continue
        bruto = p.read_text(encoding="utf-8", errors="replace")
        codigo = sem_comentarios_ps1(bruto)

        achadas = {g.lower() for g in GUID.findall(codigo)} & set(CLASSES_MEDIDAS)
        if achadas:
            nomes = ", ".join(sorted(f"{g} ({CLASSES_MEDIDAS[g]})" for g in achadas))
            r.erro(
                f"{rel}: classe de interface escrita à mão EM CÓDIGO: {nomes}\n"
                f"        Foi exatamente assim que nasceu o fantasma 'AvStream Media Device'.\n"
                f"        Procure as classes (varrer DeviceClasses) em vez de listá-las."
            )
        else:
            r.ok(f"{rel}: nenhuma classe de interface escrita à mão em código")

        # A busca de verdade: varrer `...\Control\DeviceClasses` e casar pelo hash. Sem isso o
        # script pode estar usando alguma outra lista fixa que este portão não conhece.
        tem_varredura = re.search(r"Get-ChildItem\s+\$dc\b", codigo) and re.search(r'"\*#"\s*\+\s*\$?\w+\s*\+\s*"#\*"', codigo)
        if tem_varredura:
            r.ok(f"{rel}: varre DeviceClasses procurando o hash")
        else:
            r.erro(
                f"{rel}: não achei a varredura de DeviceClasses pelo hash.\n"
                f"        Sem ela não há como saber em quantos lugares o nó está publicado."
            )


def confere_conferencia_contra_zero(raiz: Path, r: Resultado) -> None:
    """A conferência pós-remoção tem de ser contra ZERO, não contra a diferença.

    "Sumiram duas das quatro" é o resultado que fabrica o fantasma, e ele passa numa conferência
    que só olhe se o número diminuiu.
    """
    for rel in SCRIPTS_DE_NO:
        p = raiz / rel
        if not p.exists():
            continue
        codigo = sem_comentarios_ps1(p.read_text(encoding="utf-8", errors="replace"))
        if "remov" not in rel.lower() and "desinstalar" not in rel.lower():
            continue  # o inventário não remove nada; não há o que conferir depois
        if re.search(r"\.Count\s+-eq\s+0", codigo) or re.search(r"\.Count\s*-gt\s*0", codigo):
            r.ok(f"{rel}: confere o que sobrou contra zero")
        else:
            r.erro(f"{rel}: não achei a conferência 'sobrou.Count -eq 0' depois da remoção")


def confere_registro_com(raiz: Path, r: Resultado) -> None:
    """O que o MSI declara tem de ser o que a DLL registraria.

    O `.wxs` declara as chaves COM na tabela de registro em vez de chamar `regsvr32`, para que o
    Windows Installer as desfaça sozinho. O preço dessa escolha é que os valores passam a existir
    em dois lugares — e se divergirem, o Frame Server instancia um CLSID que aponta para lugar
    nenhum.
    """
    lib = raiz / FONTE_CLSID
    wxs = raiz / WXS
    if not lib.exists() or not wxs.exists():
        return
    fonte = lib.read_text(encoding="utf-8", errors="replace")
    pacote = sem_comentarios_xml(wxs.read_text(encoding="utf-8", errors="replace"))

    m = re.search(r'NOME_AMIGAVEL:\s*&str\s*=\s*"([^"]+)"', fonte)
    if m:
        if m.group(1) in pacote:
            r.ok(f'{WXS}: nome amigável do CLSID confere ("{m.group(1)}")')
        else:
            r.erro(f'{WXS}: a DLL registra "{m.group(1)}" como valor padrão do CLSID; o pacote declara outra coisa')

    m = re.search(r'Some\("ThreadingModel"\),\s*"([^"]+)"', fonte)
    if m:
        alvo = m.group(1)
        if re.search(rf'Name="ThreadingModel"[^/]*Value="{re.escape(alvo)}"', pacote):
            r.ok(f'{WXS}: ThreadingModel confere ("{alvo}")')
        else:
            r.erro(f'{WXS}: a DLL registra ThreadingModel="{alvo}"; o pacote declara outra coisa')

    if "InprocServer32" in pacote:
        r.ok(f"{WXS}: declara InprocServer32")
    else:
        r.erro(f"{WXS}: não declara InprocServer32 — a DLL não seria instanciável")


def confere_xml_bem_formado(raiz: Path, r: Resultado) -> None:
    """O `.wxs` é XML antes de ser WiX, e isso é conferível sem Windows.

    Não substitui `wix build` — não valida schema, não resolve extensão, não acha erro de
    sequência. Mas a primeira versão deste arquivo **não era XML válido**: comentário de XML não
    pode conter dois hifens seguidos, e todo comando de linha do WiX (`--global`, `-d`) os tem.
    Um erro que o `wix` só acusaria numa máquina Windows, achado aqui em milissegundos.
    """
    from xml.etree import ElementTree

    p = raiz / WXS
    if not p.exists():
        r.erro(f"não achei {WXS}")
        return
    try:
        ElementTree.parse(p)
        r.ok(f"{WXS}: XML bem formado")
    except ElementTree.ParseError as e:
        r.erro(f"{WXS}: XML malformado — {e}")

    # GUID repetido entre componentes é o defeito clássico de MSI escrito à mão: dois componentes
    # com o mesmo GUID fazem o Windows Installer tratá-los como o mesmo recurso, e desinstalar um
    # apaga os arquivos do outro.
    guids = re.findall(r'Guid="([0-9A-Fa-f-]{36})"', p.read_text(encoding="utf-8", errors="replace"))
    repetidos = {g for g in guids if guids.count(g) > 1}
    if repetidos:
        r.erro(f"{WXS}: GUID de componente repetido: {', '.join(sorted(repetidos))}")
    else:
        r.ok(f"{WXS}: {len(guids)} GUIDs de componente, todos distintos")


def procura_esquecidos(raiz: Path, r: Resultado) -> None:
    """Algum outro arquivo mexe em VCAMDEVAPI sem estar na lista deste portão?

    Uma lista fixa envelhece em silêncio — inclusive a lista **deste** arquivo. A varredura fecha
    o buraco que o portão abriria em si mesmo.
    """
    conhecidos = {(raiz / s).resolve() for s in SCRIPTS_DE_NO}
    achados = []
    for p in raiz.rglob("*.ps1"):
        if ".git" in p.parts or "worktrees" in p.parts:
            continue
        if p.resolve() in conhecidos:
            continue
        texto = p.read_text(encoding="utf-8", errors="replace")
        if "VCAMDEVAPI" in texto and "remove-device" in texto.lower():
            achados.append(p.relative_to(raiz))
    if achados:
        for a in achados:
            r.erro(f"{a}: remove nó VCAMDEVAPI e não está sob este portão — acrescente-o a SCRIPTS_DE_NO")
    else:
        r.ok("nenhum script de remoção de nó fora do portão")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raiz", default=".", help="raiz do repositório (padrão: diretório atual)")
    a = ap.parse_args()

    raiz = Path(a.raiz).resolve()
    if not (raiz / "Cargo.toml").exists():
        print(f"{raiz} não parece a raiz do repositório (sem Cargo.toml)", file=sys.stderr)
        return 2

    r = Resultado()
    ref = clsid_da_fonte(raiz, r)
    if ref:
        confere_clsid_repetido(raiz, ref, r)
    confere_busca_em_vez_de_lista(raiz, r)
    confere_conferencia_contra_zero(raiz, r)
    confere_registro_com(raiz, r)
    confere_xml_bem_formado(raiz, r)
    procura_esquecidos(raiz, r)

    for m in r.oks:
        print(f"  ok    {m}")
    for m in r.erros:
        print(f"  ERRO  {m}")
    print()
    if r.erros:
        print(f"REPROVADO: {len(r.erros)} problema(s), {len(r.oks)} conferência(s) ok.")
        return 1
    print(f"passou: {len(r.oks)} conferências.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
