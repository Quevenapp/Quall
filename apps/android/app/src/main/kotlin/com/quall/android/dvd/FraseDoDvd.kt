package com.quall.android.dvd

import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **Uma frase para a pessoa, ainda sem idioma** (`docs/traducao.md`, Android): a chave do recurso e os
 * argumentos. Os módulos do disco (o IFO, o leitor, a leitura) não têm `Context` e decidem a frase longe
 * da tela — a recusa do §2.1 nasce no `Ifo` e é mostrada pela tela, pelo serviço ou pela transmissão.
 * Quem desenha monta com [em] no idioma do momento ([com.quall.android.core.Idioma.textos] no app,
 * `TextosDeTeste` nos testes).
 *
 * Um argumento que é outra [Frase] é montado no mesmo idioma ("%1$s — o que já foi está em …" com o
 * motivo dentro). Igualdade pela chave e pelos argumentos: os testes comparam a recusa sem idioma.
 */
class Frase(@StringRes val id: Int, vararg args: Any) {
    val args: List<Any> = args.toList()

    fun em(t: Textos): String {
        val a = args.map { if (it is Frase) it.em(t) else it }.toTypedArray()
        return if (a.isEmpty()) t.s(id) else t.s(id, *a)
    }

    override fun equals(other: Any?): Boolean = other is Frase && other.id == id && other.args == args
    override fun hashCode(): Int = id * 31 + args.hashCode()

    /** Para o diário (sem `Context` não há idioma): a chave em hexadecimal e os argumentos. */
    override fun toString(): String = "frase#${Integer.toHexString(id)}${if (args.isEmpty()) "" else args.toString()}"

    companion object {
        /**
         * Um texto que já veio pronto (o detalhe técnico de uma exceção, o nome do leitor): passa como
         * está, nos dois idiomas.
         */
        fun cru(texto: String): Frase = Frase(R.string.dvd_cru, texto)
    }
}

/**
 * Uma falha que chega à tela com uma frase decidida aqui (o leitor que não está aberto, o título que
 * não existe), e não com o texto técnico da exceção. A mensagem da exceção fica para o diário.
 */
class ErroDoDvd(val frase: Frase, detalhe: String) : IllegalStateException(detalhe)

/** A frase de uma exceção para a pessoa: a decidida ([ErroDoDvd], [RecusaDoDisco]) ou o texto técnico cru. */
fun Throwable.fraseDoDvd(): Frase = when (this) {
    is ErroDoDvd -> frase
    is RecusaDoDisco -> recusa
    else -> Frase.cru(message ?: javaClass.simpleName)
}
