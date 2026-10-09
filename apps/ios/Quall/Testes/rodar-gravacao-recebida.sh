#!/bin/bash
set -euo pipefail
pasta_testes="$(cd "$(dirname "$0")" && pwd)"
pasta_base="${1:-$(mktemp -d)}"
mkdir -p "$pasta_base"
pasta_saida="$(mktemp -d "$pasta_base/rodada.XXXXXX")"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x240:rate=30 -frames:v 90 -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -x264-params 'keyint=30:min-keyint=30:scenecut=0:bframes=0:repeat-headers=1:aud=1' -f h264 -y "$pasta_saida/320.h264"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 60 -c:v libx264 -preset ultrafast -tune zerolatency -profile:v high -x264-params 'keyint=30:min-keyint=30:scenecut=0:bframes=0:repeat-headers=1:aud=1' -f h264 -y "$pasta_saida/640.h264"
xcrun swiftc "$pasta_testes/../Receber/TomadaRecebida.swift" "$pasta_testes/../Receber/ReferenciasH264Recebidas.swift" "$pasta_testes/GravacaoRecebida/main.swift" -o "$pasta_saida/sonda"
"$pasta_saida/sonda" "$pasta_saida"
python3 - "$pasta_saida" <<'PY'
import array, json, pathlib, subprocess, sys
pasta = pathlib.Path(sys.argv[1])
for arquivo in sorted(pasta.glob('*.mp4')):
    r = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-count_packets','-of','json',str(arquivo)]))
    video = next(s for s in r['streams'] if s['codec_type'] == 'video')
    audio = next((s for s in r['streams'] if s['codec_type'] == 'audio'),None)
    assert video['codec_name'] == 'h264',r
    assert float(video['duration']) > 1.8 or arquivo.name.startswith('retoma'), r
    assert (audio is None) == (arquivo.name.startswith('sem-som') or arquivo.name.startswith('retoma')), r
    if audio:
        assert audio['codec_name']=='aac' and audio['sample_rate']=='48000',r
        assert float(audio.get('duration',0)) <= float(video['duration']) + .06,r
    if arquivo.name.startswith('normal') or arquivo.name.startswith('sem-som'):
        assert int(video['nb_read_packets']) == 90,r
        pacotes = json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_packets','-show_entries','packet=flags,pts_time','-of','json',str(arquivo)]))['packets']
        assert sum('K' in p['flags'] for p in pacotes) == 3,pacotes
    if arquivo.name.startswith('perda'):
        assert int(video['nb_read_packets']) == 70,r
    if arquivo.name.startswith('troca-parte1'):
        assert (video['width'],video['height'])==(320,240),r
    if arquivo.name.startswith('troca-parte2'):
        assert (video['width'],video['height'])==(640,360),r
    if arquivo.name.startswith('estatica'):
        esperado = float((pasta / 'estatica-duracao.txt').read_text())
        assert int(video['nb_read_packets']) == 1,r
        assert abs(float(video['duration']) - esperado) < .08,(r,esperado)
        assert 15.8 <= float(audio['duration']) <= 16.1,r
    if arquivo.name.startswith('retoma'):
        assert int(video['nb_read_packets']) == 2,r
        assert .50 <= float(video['duration']) <= .56,r
    subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(arquivo),'-f','null','-'],check=True)
    if arquivo.name.startswith('pcm8k'):
        raw = subprocess.check_output(['ffmpeg','-v','error','-ss','0.3','-i',str(arquivo),'-t','1','-map','0:a:0','-ac','1','-ar','48000','-f','f32le','-'])
        valores = array.array('f'); valores.frombytes(raw)
        cruzamentos = sum(a <= 0 < b for a,b in zip(valores,valores[1:]))
        assert 435 <= cruzamentos <= 445,(cruzamentos,'frequência PCM 8k não foi preservada')
    print(arquivo.name,video['width'],video['height'],video['nb_read_packets'],'quadros, som=',bool(audio))
print('FFPROBE_E_DECODE_APROVADOS')
PY
printf 'Artefatos da sonda: %s\n' "$pasta_saida"
