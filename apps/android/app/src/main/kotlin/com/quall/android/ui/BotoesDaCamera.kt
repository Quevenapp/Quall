package com.quall.android.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.mirror.EstadoDoMicrofone
import com.quall.android.mirror.GravacaoDaTelaBus
import com.quall.android.teleprompter.DecisaoDaGravacao

// ================================================================================================
// O microfone e o Gravar de todo emissor de câmera, no modelo do iOS (`BotaoDoMicrofone.swift`,
// `BotaoDeGravar` e `ControlesDaTelaDaCamera`): **compacto** (só o ícone; a linha de estado da tela
// R5) ou **pílula** (ícone e frase; a câmera comum). Só desenham: o toque é de quem os monta, pelo
// caminho que já existia (`BotaoDoMicrofone` da permissão, `MirrorService.pedirGravacao`).
// ================================================================================================

/**
 * **As frases do microfone de um estado**, no idioma de [c] (`docs/traducao.md`, Android): a pílula e o
 * redondo dizem o mesmo. Recusado e falhou vêm do estado tipado ([EstadoDoMicrofone.semPermissao]), e não
 * de uma palavra procurada na frase.
 */
private class FrasesDoMicrofone(c: Context, e: EstadoDoMicrofone) {
    val recusado = !e.ligado && e.semPermissao
    val falhou = !e.ligado && e.motivo.isNotBlank() && !recusado && e.disponivel
    private val nome = e.nome(Idioma.textos(c))

    /** A frase longa (a da pílula; a acessibilidade do redondo). */
    val longa: String = when {
        !e.disponivel -> c.getString(R.string.cam_mic_depois_da_camera, nome)
        e.ligado -> c.getString(R.string.cam_mic_ligado, nome)
        recusado -> c.getString(if (e.daPlaca) R.string.cam_mic_sem_acesso_placa else R.string.cam_mic_sem_acesso_microfone)
        falhou -> c.getString(
            if (e.daPlaca) R.string.cam_mic_nao_abriu_placa else if (e.daFita) R.string.cam_mic_nao_abriu_fita else R.string.cam_mic_nao_abriu_microfone,
        )
        else -> c.getString(R.string.cam_mic_desligado, nome)
    }

    /** O nome para a acessibilidade: "Desligar o microfone. Microfone ligado". */
    val descricao: String = c.getString(
        when {
            e.daPlaca -> if (e.ligado) R.string.cam_desligar_som_da_placa else R.string.cam_ligar_som_da_placa
            e.daFita -> if (e.ligado) R.string.cam_desligar_som_da_fita else R.string.cam_ligar_som_da_fita
            else -> if (e.ligado) R.string.microfone_desligar else R.string.cam_ligar_microfone
        },
    ) + ". " + longa

    /** O nome do botão na placa e na fita ("Som da placa"). */
    val nomeDoBotao: String = nome
}

/** O botão do microfone. Ligado é vermelho, como o "no ar" de uma filmadora: quem fala precisa ver que é ouvido. */
class BotaoDoMicrofoneDaTela(contexto: Context, private val compacto: Boolean) : LinearLayout(contexto) {
    private val icone = ImageView(contexto)
    private val frase = TextView(contexto)
    private var desenhado = ""

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = contexto.dp(44)
        icone.imageTintList = ColorStateList.valueOf(Cores.BRANCO)
        addView(icone, LayoutParams(contexto.dp(22), contexto.dp(22)))
        if (!compacto) {
            frase.setTextColor(Cores.BRANCO)
            frase.setTypeface(frase.typeface, Typeface.BOLD)
            frase.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            frase.maxLines = 1
            addView(frase, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { leftMargin = contexto.dp(8) })
            setPadding(contexto.dp(14), 0, contexto.dp(14), 0)
        } else {
            minimumWidth = contexto.dp(48)
        }
        isClickable = true
        isFocusable = true
    }

    fun atualizar(e: EstadoDoMicrofone) {
        // Na placa de captura, o botão é o "Som da placa" (§11, item 3): o mesmo liga/desliga.
        val f = FrasesDoMicrofone(context, e)
        val recusado = f.recusado
        val falhou = f.falhou
        val texto = f.longa
        val cor = when {
            e.ligado -> Cores.comAlfa(Cores.VERMELHO, 0.8f)
            recusado || falhou -> Cores.comAlfa(Cores.LARANJA, 0.55f)
            else -> Cores.FUNDO_DO_BOTAO
        }
        val chave = "$texto|$cor|${e.disponivel}"
        if (chave == desenhado) return
        desenhado = chave
        icone.setImageResource(if (e.ligado) R.drawable.ic_q_mic else R.drawable.ic_q_mic_cortado)
        frase.text = texto
        background = fundoArredondado(cor, context.dp(if (compacto) 9 else 22).toFloat())
        isEnabled = e.disponivel
        alpha = if (e.disponivel) 1f else 0.45f
        contentDescription = f.descricao
    }
}

/**
 * **O botão Gravar/Parar**: parado, o círculo vermelho ("Gravar" na pílula); abrindo ou fechando, o
 * spinner ("Começando…" / "Salvando…"); gravando, fundo vermelho com ■, o tempo, "SEM SOM" com o
 * microfone desligado, e o espaço que sobra (§5.5).
 */
class BotaoDeGravar(contexto: Context, private val compacto: Boolean) : LinearLayout(contexto) {
    private val icone = ImageView(contexto)
    private val espera = spinnerBranco(contexto)
    private val coluna = LinearLayout(contexto).apply { orientation = VERTICAL }
    private val linha1 = TextView(contexto)
    private val linha2 = TextView(contexto)
    private var desenhado = ""

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = contexto.dp(44)
        minimumWidth = contexto.dp(48)
        addView(icone, LayoutParams(contexto.dp(22), contexto.dp(22)))
        addView(espera, LayoutParams(contexto.dp(20), contexto.dp(20)))
        linha1.setTextColor(Cores.BRANCO)
        linha1.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        linha1.maxLines = 1
        linha2.setTextColor(Cores.BRANCO)
        linha2.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        linha2.maxLines = 1
        coluna.addView(linha1)
        coluna.addView(linha2)
        addView(coluna, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { leftMargin = contexto.dp(6) })
        isClickable = true
        isFocusable = true
    }

    /** [habilitado]: a câmera montada, e o aparelho grava (a D1 pode dizer que não). */
    fun atualizar(fase: GravacaoDaTelaBus.Fase, decorridoMs: Long, espacoLivre: Long, microfoneLigado: Boolean, habilitado: Boolean) {
        val gravando = fase == GravacaoDaTelaBus.Fase.GRAVANDO
        val tempo = if (gravando) DecisaoDaGravacao.tempo(decorridoMs) else ""
        val chave = "$fase|$tempo|$espacoLivre|$microfoneLigado|$habilitado"
        if (chave == desenhado) return
        desenhado = chave
        val ocupado = fase == GravacaoDaTelaBus.Fase.COMECANDO || fase == GravacaoDaTelaBus.Fase.PARANDO
        icone.visibility = if (ocupado) GONE else VISIBLE
        espera.visibility = if (ocupado) VISIBLE else GONE
        val espaco = if (espacoLivre > 0) DecisaoDaGravacao.espaco(espacoLivre) else ""
        when (fase) {
            GravacaoDaTelaBus.Fase.PARADA -> {
                icone.setImageResource(R.drawable.ic_q_gravar)
                icone.imageTintList = ColorStateList.valueOf(Cores.VERMELHO)
                linha1.text = context.getString(R.string.cam_gravar)
                linha1.setTypeface(Typeface.DEFAULT, Typeface.BOLD)
                linha2.text = ""
            }
            GravacaoDaTelaBus.Fase.COMECANDO -> { linha1.text = context.getString(R.string.cam_comecando); linha2.text = "" }
            GravacaoDaTelaBus.Fase.PARANDO -> { linha1.text = context.getString(R.string.cam_salvando); linha2.text = "" }
            GravacaoDaTelaBus.Fase.GRAVANDO -> {
                icone.setImageResource(R.drawable.ic_q_parar)
                icone.imageTintList = ColorStateList.valueOf(Cores.BRANCO)
                linha1.text = tempo
                linha1.setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
                // **Sem som, dito por extenso** (decisão do Pessoa Exemplo, 24/09 à noite).
                linha2.text = listOfNotNull(if (microfoneLigado) null else context.getString(R.string.cam_sem_som), espaco.ifEmpty { null })
                    .joinToString(" · ")
            }
        }
        // Compacto: parado, só o círculo; ocupado, só o spinner; gravando, o tempo e a linha de baixo.
        coluna.visibility = when {
            !compacto -> VISIBLE
            gravando -> VISIBLE
            else -> GONE
        }
        linha2.visibility = if (linha2.text.isNullOrEmpty()) GONE else VISIBLE
        setPadding(if (gravando || !compacto) context.dp(if (compacto) 8 else 14) else 0, 0,
            if (gravando || !compacto) context.dp(if (compacto) 8 else 14) else 0, 0)
        background = fundoArredondado(if (gravando) Cores.comAlfa(Cores.VERMELHO, 0.85f) else Cores.FUNDO_DO_BOTAO,
            context.dp(if (compacto) 9 else 22).toFloat())
        val ativo = habilitado && fase != GravacaoDaTelaBus.Fase.PARANDO && fase != GravacaoDaTelaBus.Fase.COMECANDO
        isEnabled = ativo
        alpha = if (habilitado) 1f else 0.45f
        contentDescription = descricaoDoGravar(context, fase, tempo, microfoneLigado)
    }
}

/** O nome do Gravar para a acessibilidade (a pílula e o redondo; o redondo acrescenta o espaço). */
private fun descricaoDoGravar(c: Context, fase: GravacaoDaTelaBus.Fase, tempo: String, microfoneLigado: Boolean): String = when (fase) {
    GravacaoDaTelaBus.Fase.PARADA -> c.getString(if (microfoneLigado) R.string.cam_gravar else R.string.cam_gravar_sem_som_desc)
    GravacaoDaTelaBus.Fase.COMECANDO -> c.getString(R.string.cam_gravacao_comecando)
    GravacaoDaTelaBus.Fase.PARANDO -> c.getString(R.string.cam_fechando_arquivo)
    GravacaoDaTelaBus.Fase.GRAVANDO ->
        c.getString(if (microfoneLigado) R.string.cam_parar_gravacao_desc else R.string.cam_parar_gravacao_desc_sem_som, tempo)
}

/**
 * **Uma pílula de texto da placa de captura** na tela da transmissão (o "Ouvir" e a "Foto", §11): o
 * fundo do botão, o texto branco; `destaque` pinta de verde (o ouvir ligado).
 */
class BotaoDaPlaca(contexto: Context) : LinearLayout(contexto) {
    private val frase = TextView(contexto)
    private var desenhado = ""

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = contexto.dp(44)
        frase.setTextColor(Cores.BRANCO)
        frase.setTypeface(frase.typeface, Typeface.BOLD)
        frase.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        frase.maxLines = 1
        addView(frase, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        setPadding(contexto.dp(14), 0, contexto.dp(14), 0)
        isClickable = true
        isFocusable = true
    }

    fun atualizar(texto: String, destaque: Boolean = false, descricao: String = texto) {
        val chave = "$texto|$destaque"
        if (chave == desenhado) return
        desenhado = chave
        frase.text = texto
        background = fundoArredondado(if (destaque) Cores.comAlfa(Cores.VERDE, 0.7f) else Cores.FUNDO_DO_BOTAO, context.dp(22).toFloat())
        contentDescription = descricao
    }
}

// ================================================================================================
// **Os três controles redondos da câmera no ar** (`docs/telas-estudio.md` §6.5): o microfone, o gravar
// e o parar, numa linha, cada um com a legenda embaixo (12, branco a 80 %). Só desenham: o toque é de
// quem os monta, pelos caminhos de sempre. A tela R5 continua com os compactos acima.
// ================================================================================================

/** O círculo e a legenda embaixo. O toque é do controle inteiro (círculo e legenda). */
open class ControleRedondo(contexto: Context, diametroDp: Int) : LinearLayout(contexto) {
    protected val circulo = FrameLayout(contexto)
    protected val legenda = TextView(contexto)

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        addView(circulo, LayoutParams(contexto.dp(diametroDp), contexto.dp(diametroDp)))
        legenda.apply {
            setTextColor(0xCCFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
            gravity = Gravity.CENTER
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        addView(legenda, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = contexto.dp(8) })
        isClickable = true
        isFocusable = true
    }
}

/**
 * **O microfone** (56, branco a 16 %; ligado: `noAr` a 85 %; recusado ou que não abriu: âmbar). A legenda
 * é curta ("Mic desligado", "Mic ligado", "Ligando…", "Sem acesso", "Não abriu"; na placa e na fita,
 * "Som …"); a frase longa de hoje vai na acessibilidade e no Aviso embaixo.
 */
class MicrofoneRedondo(contexto: Context) : ControleRedondo(contexto, 56) {
    private val icone = ImageView(contexto)
    private var desenhado = ""

    init {
        circulo.addView(icone, FrameLayout.LayoutParams(contexto.dp(24), contexto.dp(24), Gravity.CENTER))
    }

    /** [comReceptor]: há quem receba (o microfone só abre de verdade aí; na espera ele não abre, por desenho). */
    fun atualizar(e: EstadoDoMicrofone, comReceptor: Boolean) {
        val f = FrasesDoMicrofone(context, e)
        val recusado = f.recusado
        val falhou = f.falhou
        // A frase longa de hoje (a da pílula de antes), para a acessibilidade.
        val longa = f.longa
        // Na placa e na fita, o nome do botão ("Som da placa", "Som da fita", `MicrofoneBus`); a cor diz
        // se está ligado. No microfone, a frase curta de cada estado.
        val somDaFonte = e.daPlaca || e.daFita
        val curta = when {
            recusado -> context.getString(R.string.cam_mic_curta_sem_acesso)
            falhou -> context.getString(R.string.cam_mic_curta_nao_abriu)
            somDaFonte -> f.nomeDoBotao
            e.ligado && !e.capturando && comReceptor -> context.getString(R.string.cam_mic_curta_ligando)
            e.ligado -> context.getString(R.string.cam_mic_curta_ligado)
            else -> context.getString(R.string.cam_mic_curta_desligado)
        }
        val fundo = when {
            e.ligado -> Cores.comAlfa(Cores.NO_AR, 0.85f)
            recusado || falhou -> Cores.comAlfa(Cores.AGUARDANDO, 0.28f)
            else -> 0x29FFFFFF
        }
        val corDoIcone = if (recusado || falhou) Cores.AGUARDANDO_TEXTO else Cores.BRANCO
        val chave = "$curta|$longa|$fundo|${e.disponivel}"
        if (chave == desenhado) return
        desenhado = chave
        icone.setImageResource(if (e.ligado) R.drawable.ic_q_mic else R.drawable.ic_q_mic_cortado)
        icone.imageTintList = ColorStateList.valueOf(corDoIcone)
        circulo.background = bolinha(fundo)
        legenda.text = curta
        isEnabled = e.disponivel
        alpha = if (e.disponivel) 1f else 0.45f
        contentDescription = f.descricao
    }
}

/**
 * **O gravar** (78: o anel branco de 4 e o miolo `noAr`). Gravando, o miolo vira quadrado arredondado e a
 * legenda é o tempo em mono, com "· SEM SOM" quando for o caso; abrindo ou fechando, a roda. Desligado a
 * 40 % até a câmera montar, como hoje.
 */
class GravarRedondo(contexto: Context) : ControleRedondo(contexto, 78) {
    private val miolo = View(contexto)
    private val roda = spinnerBranco(contexto)
    private var desenhado = ""

    init {
        circulo.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.TRANSPARENT)
            setStroke(contexto.dp(4), Cores.BRANCO)
        }
        circulo.addView(miolo, FrameLayout.LayoutParams(contexto.dp(58), contexto.dp(58), Gravity.CENTER))
        circulo.addView(roda, FrameLayout.LayoutParams(contexto.dp(28), contexto.dp(28), Gravity.CENTER))
    }

    /** [habilitado]: a câmera montada, e o aparelho grava (a D1 pode dizer que não). */
    fun atualizar(fase: GravacaoDaTelaBus.Fase, decorridoMs: Long, espacoLivre: Long, microfoneLigado: Boolean, habilitado: Boolean) {
        val gravando = fase == GravacaoDaTelaBus.Fase.GRAVANDO
        val tempo = if (gravando) DecisaoDaGravacao.tempo(decorridoMs) else ""
        val chave = "$fase|$tempo|$espacoLivre|$microfoneLigado|$habilitado"
        if (chave == desenhado) return
        desenhado = chave
        val ocupado = fase == GravacaoDaTelaBus.Fase.COMECANDO || fase == GravacaoDaTelaBus.Fase.PARANDO
        roda.visibility = if (ocupado) VISIBLE else GONE
        miolo.visibility = if (ocupado) GONE else VISIBLE
        val lado = context.dp(if (gravando) 30 else 58)
        (miolo.layoutParams as FrameLayout.LayoutParams).let { lp ->
            if (lp.width != lado) {
                lp.width = lado
                lp.height = lado
                miolo.layoutParams = lp
            }
        }
        miolo.background = if (gravando) fundoArredondado(Cores.NO_AR, context.dp(8).toFloat()) else bolinha(Cores.NO_AR)
        val espaco = if (espacoLivre > 0) DecisaoDaGravacao.espaco(espacoLivre) else ""
        legenda.text = when (fase) {
            GravacaoDaTelaBus.Fase.PARADA -> context.getString(R.string.cam_gravar)
            GravacaoDaTelaBus.Fase.COMECANDO -> context.getString(R.string.cam_comecando)
            GravacaoDaTelaBus.Fase.PARANDO -> context.getString(R.string.cam_salvando)
            GravacaoDaTelaBus.Fase.GRAVANDO -> tempo + if (microfoneLigado) "" else " · " + context.getString(R.string.cam_sem_som)
        }
        legenda.typeface = if (gravando) Typeface.create(Typeface.MONOSPACE, Typeface.BOLD) else Typeface.create("sans-serif-medium", Typeface.NORMAL)
        isEnabled = habilitado && !ocupado
        alpha = if (habilitado) 1f else 0.4f
        contentDescription = descricaoDoGravar(context, fase, tempo, microfoneLigado) +
            (if (gravando && espaco.isNotEmpty()) ". $espaco" else "")
    }
}

/** **O parar** (56, o vermelho a 24 % e o quadradinho #FF8A80): "Cancelar", "Parar" ou "Parar e salvar". */
class PararRedondo(contexto: Context) : ControleRedondo(contexto, 56) {
    init {
        circulo.background = bolinha(Cores.comAlfa(Cores.NO_AR, 0.24f))
        circulo.addView(View(contexto).apply {
            background = fundoArredondado(Cores.PERIGO_TEXTO, contexto.dp(3).toFloat())
        }, FrameLayout.LayoutParams(contexto.dp(18), contexto.dp(18), Gravity.CENTER))
        contexto.getString(R.string.cancelar).let { rotulo(it, it) }
    }

    fun rotulo(curto: String, descricao: String) {
        if (legenda.text.toString() != curto) legenda.text = curto
        if (contentDescription != descricao) contentDescription = descricao
    }
}
