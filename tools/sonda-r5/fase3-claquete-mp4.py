#!/usr/bin/env python3
"""
R5, fase 3: a claquete física (G4) medida **no arquivo gravado**, e não na rede.

O analisador da claquete (`tools/claquete-fisica/analisar.py`, da frente da claquete; hoje no ramo
`worktree-agent-a7d1e6a60b8a3c9dd`) lê o prefixo que `quall-probe receber-claquete` grava:
P.h264, P.quadros.csv (pos, timestamp_us), P.som.pcm, P.som.csv (timestamp_us, amostra, amostras) e
P.json (o relógio comum). Este adaptador escreve esse prefixo **a partir do MP4 da gravação local**:

- o vídeo sai do MP4 sem recodificar (`-c copy -bsf h264_mp4toannexb`), e cada quadro leva o PTS do
  arquivo (a hora da câmera, com o zero no primeiro quadro), casado pelo byte onde começa no .h264;
- o som é decodificado pelo ffmpeg (o atraso do AAC já saiu do PTS no gravador) e vai como um
  pacote só, a partir do PTS dele;
- o relógio comum é o do próprio arquivo: deslocamento 0 nos dois, atraso de conteúdo 0.

Depois, o analisador de sempre:

    tools/sonda-r5/fase3-claquete-mp4.py GRAVACAO.mp4 PREFIXO
    python3 <ramo da claquete>/tools/claquete-fisica/analisar.py PREFIXO --semente S --distancia-m D \\
        [--roi x,y,w,h] --saida relato.json

**Nenhum quadro é aberto**: o analisador lê a luminância média de cada quadro reduzido e demodula o
bipe. A gravação da claquete tem o que estiver atrás do iPad e o som da sala: sim do Pessoa Exemplo por
corrida, e apague o MP4 e o prefixo depois de medir.
"""
import csv
import json
import subprocess
import sys


def roda(*args):
    r = subprocess.run(list(args), capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"falhou: {' '.join(args)}\n{r.stderr.strip()}")
    return r.stdout


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    mp4, P = sys.argv[1], sys.argv[2]
    info = json.loads(roda("ffprobe", "-v", "error", "-show_streams", "-of", "json", mp4))
    v = next(s for s in info["streams"] if s["codec_type"] == "video")
    a = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    if a is None:
        sys.exit("o MP4 não tem som")

    # O vídeo em Annex-B, e os PTS do MP4 na ordem dos quadros (sem quadro B: decodificação = exibição).
    roda("ffmpeg", "-v", "error", "-y", "-i", mp4, "-map", f"0:{v['index']}", "-c", "copy",
         "-bsf:v", "h264_mp4toannexb", "-f", "h264", P + ".h264")
    tb = [int(x) for x in v["time_base"].split("/")]
    pts = [int(l.split(",")[0]) for l in roda(
        "ffprobe", "-v", "error", "-select_streams", str(v["index"]), "-show_entries", "packet=pts",
        "-of", "csv=p=0", mp4).split() if l.strip()]
    pos = [int(l.split(",")[0]) for l in roda(
        "ffprobe", "-v", "error", "-f", "h264", "-show_entries", "packet=pos", "-of", "csv=p=0",
        P + ".h264").split() if l.strip() and l.split(",")[0] != "N/A"]
    if len(pos) != len(pts):
        sys.exit(f"o .h264 tem {len(pos)} quadros e o MP4 {len(pts)}: não dá para casar")
    with open(P + ".quadros.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["pos", "timestamp_us"])
        for p, t in zip(pos, pts):
            w.writerow([p, t * tb[0] * 1_000_000 // tb[1]])

    # O som decodificado, mono s16le na taxa do arquivo, como um pacote só a partir do PTS dele.
    taxa, canais = int(a["sample_rate"]), 1
    roda("ffmpeg", "-v", "error", "-y", "-i", mp4, "-map", f"0:{a['index']}", "-ac", "1",
         "-f", "s16le", "-acodec", "pcm_s16le", P + ".som.pcm")
    n = len(open(P + ".som.pcm", "rb").read()) // 2
    ta = [int(x) for x in a["time_base"].split("/")]
    inicio = int(a.get("start_pts", 0)) * ta[0] * 1_000_000 // ta[1]
    with open(P + ".som.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp_us", "amostra", "amostras"])
        w.writerow([inicio, 0, n])

    meta = {
        "origem": f"arquivo {mp4} (gravação local, fase 3 do R5)",
        "video": {"deslocamento_us": 0, "status": "o PTS do arquivo", "violacoes_da_guarda": 0},
        "som": {"deslocamento_us": 0, "status": "o PTS do arquivo", "violacoes_da_guarda": 0,
                "taxa_hz": taxa, "canais": canais, "atraso_do_conteudo_us": 0,
                "codec": "aac decodificado pelo ffmpeg (o atraso do codificador já saiu no gravador)"},
        "serie_do_deslocamento": [],
    }
    with open(P + ".json", "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    print(f"{P}.*: {len(pts)} quadros, {n} amostras a {taxa} Hz — pronto para o analisar.py da claquete")


if __name__ == "__main__":
    main()
