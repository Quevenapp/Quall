package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Testes de [RelogioDoPts] (`docs/som-no-receptor.md` §19.4). **Rodam na JVM, sem aparelho.** Os
 * casos são os aparelhos da bancada, com os números medidos: o A07 (declara `REALTIME`, ficou a
 * ~2,94 h de `elapsedRealtime`) e o A10s (declara `UNKNOWN`, ~103 ms de `MONOTONIC`).
 */
class RelogioDoPtsTest {

    private val dormiu = 10_584_000_000L // 2,94 h
    private val mono = 20_000_000_000L // 5,6 h de MONOTONIC
    private val boot = mono + dormiu

    @Test
    fun a_tela_e_monotonic_e_nada_muda() {
        val r = RelogioDoPts()
        val pts = mono - 15_000
        assertEquals(pts, r.quadro(pts, mono, boot))
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r.classe)
        assertEquals(0L, r.correcaoUs)
        assertEquals(15_000L, r.mPrimeiroUs)
        assertEquals(-dormiu, r.bUs)
    }

    @Test
    fun a_camera_em_boottime_num_aparelho_que_dormiu_recebe_b() {
        val r = RelogioDoPts()
        val pts = boot - 40_000 // capturado 40 ms antes, em BOOTTIME
        val c = r.quadro(pts, mono, boot)
        assertEquals(RelogioDoPts.Classe.BOOTTIME, r.classe)
        assertEquals(-dormiu, r.correcaoUs)
        assertEquals(mono - 40_000, c)
        // O quadro seguinte, 33 ms depois, com a mesma correção.
        assertEquals(mono - 40_000 + 33_333, r.quadro(pts + 33_333, mono + 33_333 + 38_000, boot + 33_333 + 38_000))
    }

    /**
     * **O A07**: declara `REALTIME`, e o PTS é `MONOTONIC` num aparelho que dormiu 2,94 h. Converter
     * pela declaração poria 2,94 h de erro no vídeo; medir não põe nada.
     */
    @Test
    fun o_a07_declara_realtime_e_e_monotonic() {
        val r = RelogioDoPts()
        val pts = mono - 40_000
        assertEquals(pts, r.quadro(pts, mono, boot))
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r.classe)
        assertEquals(0L, r.correcaoUs)
    }

    /** **O A10s**: declara `UNKNOWN`, e o número é plausível como latência. Fica como está. */
    @Test
    fun o_a10s_declara_unknown_com_103_ms() {
        val r = RelogioDoPts()
        val pts = mono - 103_000
        assertEquals(pts, r.quadro(pts, mono, mono + 5_000))
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r.classe)
    }

    @Test
    fun relogio_desconhecido_recebe_m_e_fica_atrasado_pela_latencia() {
        val r = RelogioDoPts()
        // Um PTS com origem própria (começa perto de zero).
        val pts = 1_234_567L
        val c = r.quadro(pts, mono, boot)
        assertEquals(RelogioDoPts.Classe.DESCONHECIDO, r.classe)
        assertEquals(mono - pts, r.correcaoUs)
        assertEquals(mono, c)
        assertEquals(mono + 33_333, r.quadro(pts + 33_333, mono + 30_000, boot + 30_000))
    }

    @Test
    fun sem_ter_dormido_boottime_e_monotonic_nao_se_distinguem() {
        // |b| abaixo da tolerância: o PTS em BOOTTIME com latência maior que |b| cai em MONOTONIC,
        // com erro de |b| (menos que a tolerância); com latência menor, em desconhecido.
        val b = 100_000L
        val r1 = RelogioDoPts()
        r1.quadro(mono + b - 150_000, mono, mono + b)
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r1.classe)
        val r2 = RelogioDoPts()
        r2.quadro(mono + b - 40_000, mono, mono + b)
        assertEquals(RelogioDoPts.Classe.DESCONHECIDO, r2.classe)
    }

    @Test
    fun a_decisao_e_uma_so_e_o_m_minimo_segue_medido() {
        val r = RelogioDoPts()
        r.quadro(mono - 50_000, mono, boot)
        // Um quadro com m fora da faixa depois não muda nada (seria um degrau no vídeo).
        val pts2 = mono - 500_000
        assertEquals(pts2, r.quadro(pts2, mono, boot))
        r.quadro(mono + 10_000 - 12_000, mono + 10_000, boot + 10_000)
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r.classe)
        assertEquals(12_000L, r.mMinimoUs)
        assertEquals(3L, r.quadros)
    }

    /**
     * A revisão do código (E): o primeiro quadro que sai do encoder mais de 300 ms depois da
     * captura (o encoder ou a câmera aquecendo; o A07 já mostrou 251 ms de encode) virava
     * `DESCONHECIDO`, e a correção `m` atrasava o vídeo inteiro por ele. Um relógio desconhecido de
     * verdade dá m de horas ou negativo; até 2 s, com o PTS não sendo `BOOTTIME`, é `MONOTONIC`.
     */
    @Test
    fun o_primeiro_quadro_lento_ainda_e_monotonic() {
        for ((lat, b) in listOf(350_000L to -dormiu, 1_900_000L to -dormiu, 350_000L to -5_000L)) {
            val r = RelogioDoPts()
            val pts = mono - lat
            assertEquals("latência $lat, b $b", pts, r.quadro(pts, mono, mono - b))
            assertEquals("latência $lat, b $b", RelogioDoPts.Classe.MONOTONIC, r.classe)
            assertEquals(0L, r.correcaoUs)
        }
        // Acima do limite, desconhecido; e o BOOTTIME segue BOOTTIME.
        val r = RelogioDoPts()
        r.quadro(mono - 2_500_000, mono, boot)
        assertEquals(RelogioDoPts.Classe.DESCONHECIDO, r.classe)
        val rb = RelogioDoPts()
        rb.quadro(boot - 120_000, mono, boot)
        assertEquals(RelogioDoPts.Classe.BOOTTIME, rb.classe)
    }

    @Test
    fun o_controle_sem_corrigir_classifica_e_devolve_o_pts_cru() {
        val r = RelogioDoPts(corrigir = false)
        val pts = boot - 40_000
        assertEquals(pts, r.quadro(pts, mono, boot))
        assertEquals(RelogioDoPts.Classe.BOOTTIME, r.classe)
        assertEquals(-dormiu, r.correcaoUs)
    }

    // --- a zona ambígua (R5, fase 2): o aparelho que quase não dormiu ---------------------------

    private val pouco = 200_000L // dormiu 200 ms desde o boot: |b| abaixo da tolerância

    /**
     * **A frontal do S24, com o aparelho recém-ligado**: declara `REALTIME` e é `BOOTTIME`, 76 ms de
     * latência (S-A1). Sem a declaração, `m` sai −124 ms e o quadro caía em desconhecido, com a
     * latência inteira somada ao vídeo; com ela, o carimbo recebe `b` e sai exato.
     */
    @Test
    fun a_zona_ambigua_com_a_declaracao_recebe_b() {
        val r = RelogioDoPts(declaradoBoottime = true)
        val capturaMono = mono - 76_000
        val pts = capturaMono + pouco // o mesmo instante, em BOOTTIME
        assertEquals(capturaMono, r.quadro(pts, mono, mono + pouco))
        assertEquals(RelogioDoPts.Classe.BOOTTIME, r.classe)
        assertEquals(-pouco, r.correcaoUs)
        assertEquals(true, r.pelaDeclaracao)
    }

    /** O mesmo quadro sem a declaração: o comportamento de antes, intacto (a tela, o A10s). */
    @Test
    fun a_zona_ambigua_sem_a_declaracao_fica_como_era() {
        val r = RelogioDoPts()
        val pts = mono - 76_000 + pouco
        r.quadro(pts, mono, mono + pouco)
        assertEquals(RelogioDoPts.Classe.DESCONHECIDO, r.classe)
        assertEquals(false, r.pelaDeclaracao)
    }

    /**
     * **O preço, escrito**: um aparelho que declara e é `MONOTONIC` (o A07), na zona ambígua, erra por
     * `|b|` — menos que a tolerância, o mesmo tamanho do erro de não corrigir quem diz a verdade.
     */
    @Test
    fun a_zona_ambigua_num_aparelho_que_mente_erra_por_b() {
        val r = RelogioDoPts(declaradoBoottime = true)
        val pts = mono - 40_000 // MONOTONIC de verdade
        val c = r.quadro(pts, mono, mono + pouco)
        assertEquals(RelogioDoPts.Classe.BOOTTIME, r.classe)
        assertEquals(pts - pouco, c)
    }

    /** Fora da zona ambígua a medida manda, com ou sem declaração: o A07 de 2,94 h continua certo. */
    @Test
    fun fora_da_zona_ambigua_a_declaracao_nao_muda_nada() {
        val r = RelogioDoPts(declaradoBoottime = true)
        val pts = mono - 40_000
        assertEquals(pts, r.quadro(pts, mono, boot))
        assertEquals(RelogioDoPts.Classe.MONOTONIC, r.classe)
        assertEquals(false, r.pelaDeclaracao)
    }
}
