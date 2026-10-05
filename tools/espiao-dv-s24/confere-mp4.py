#!/usr/bin/env python3
"""Confere MP4s da gravação da DV (no Mac): ffprobe (resolução, taxa, duração, som), a continuidade
dos tempos (buracos no vídeo e no som), o silêncio no som (onde a âncora pôs silêncio ou a fita não
tinha som) e o desvio entre o fim do som e o do vídeo.

    confere-mp4.py A.mp4 [B.mp4 ...]
"""
import json
import subprocess
import sys

import numpy as np


def main() -> None:
    for arq in sys.argv[1:]:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", arq],
                           capture_output=True, text=True)
        info = json.loads(r.stdout)
        f = info["format"]
        print(f"== {arq}: {int(f['size']) / 1e6:.1f} MB, {float(f['duration']):.2f} s, "
              f"{int(f['bit_rate']) / 1e6:.2f} Mbit/s")
        for st in info["streams"]:
            if st["codec_type"] == "video":
                print(f"  vídeo: {st['codec_name']} {st.get('profile')} {st['width']}x{st['height']} "
                      f"{st['avg_frame_rate']} quadros={st.get('nb_frames')} {int(st.get('bit_rate', 0)) / 1e6:.2f} Mbit/s "
                      f"cor={st.get('color_range')}/{st.get('color_space')} duração {st.get('duration')}")
            else:
                print(f"  som: {st['codec_name']} {st.get('profile')} {st['sample_rate']} Hz {st['channels']} canais "
                      f"{int(st.get('bit_rate', 0)) / 1e3:.0f} kbit/s duração {st.get('duration')}")
        # tempos do vídeo: buracos
        r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time",
                            "-of", "csv=p=0", arq], capture_output=True, text=True)
        t = np.array(sorted(float(x) for x in r.stdout.split() if x))
        d = np.diff(t)
        print(f"  vídeo: {len(t)} pacotes, passo mediano {np.median(d) * 1000:.2f} ms, maior {d.max() * 1000:.1f} ms")
        # som: níveis por segundo e trechos de silêncio
        so = subprocess.run(["ffmpeg", "-v", "error", "-i", arq, "-map", "0:a:0", "-ac", "1", "-ar", "48000",
                             "-f", "s16le", "-"], capture_output=True).stdout
        a = np.frombuffer(so, np.int16).astype(float)
        if len(a):
            por_seg = [np.sqrt(np.mean(a[i:i + 48000] ** 2)) for i in range(0, len(a) - 48000, 48000)]
            janelas = a[: len(a) // 1601 * 1601].reshape(-1, 1601)
            mudo = (np.abs(janelas).max(axis=1) < 4)
            print(f"  som: {len(a) / 48000:.2f} s, RMS por segundo " + " ".join(f"{x:.0f}" for x in por_seg[:20]))
            print(f"  som: {mudo.sum()} de {len(mudo)} quadros de som mudos (máx |a| < 4)")


if __name__ == "__main__":
    main()
