// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RedacaoDeLogsTest {
    @Test
    fun pin_e_chaves_nao_aparecem_em_mensagem_livre_ou_json() {
        for (entrada in listOf("PIN 482719", "pin=482719", "PIN: 482 719", "{\"pin\":\"482719\"}",
            "segredo='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
            "{\"private_key\":[1,2,3],\"status\":17}")) {
            val saida = RedacaoDeLogs.mensagem(entrada)
            assertFalse(saida.contains("482719"))
            assertFalse(saida.contains("482 719"))
            assertFalse(saida.contains("aaaaaaaa"))
            assertFalse(saida.contains("[1,2,3]"))
            assertTrue(saida.contains("<segredo>"))
        }
    }

    @Test
    fun identidades_links_e_tokens_sao_redigidos() {
        val token = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789+/="
        val texto = "device_id=android-abcdef12 display_name=\"Nome privado\" autor=alguem " +
            "quall://482719@[fd00::1]:7877 $token servidor=vizinho.local “Nome remoto”"
        val saida = RedacaoDeLogs.mensagem(texto)
        for (valor in listOf("abcdef12", "Nome privado", "alguem", "482719", "fd00::1", token, "vizinho.local", "Nome remoto")) {
            assertFalse(valor, saida.contains(valor))
        }
    }

    @Test
    fun ips_sao_omitidos_mas_familia_porta_e_metricas_continuam() {
        for (ip in listOf("fd00::1", "2001:db8:1:2:3:4:5:6", "fe80::1%en0", "::1", "::ffff:192.0.2.1")) {
            assertEquals("local=[<ipv6>]:7877 fps=30 status=17", RedacaoDeLogs.mensagem("local=[$ip]:7877 fps=30 status=17"))
        }
        assertEquals("par=<ipv4>:7979 bytes=123456 causa=timeout",
            RedacaoDeLogs.mensagem("par=192.168.56.2:7979 bytes=123456 causa=timeout"))
        assertEquals("latencia=12.3 bytes=123456 bitrate=789012 status=17 PIN errado",
            RedacaoDeLogs.mensagem("latencia=12.3 bytes=123456 bitrate=789012 status=17 PIN errado"))
    }

    @Test
    fun texto_nao_numerico_ipv6_nao_vira_endereco_e_nao_ha_dns() {
        val mensagem = "codec=avc:48000:2 erro=BAD_PIN resolucao=1280x720 bytes=654321"
        assertEquals(mensagem, RedacaoDeLogs.mensagem(mensagem))
    }

    @Test
    fun uri_e_caminho_privado_nao_revelam_arquivo() {
        assertEquals("gravacao=<uri> arquivo=<caminho privado>",
            RedacaoDeLogs.mensagem("gravacao=content://media/video/12 arquivo=/storage/emulated/0/filme.mp4"))
    }

    @Test
    fun throwable_e_causas_nao_vazam_o_texto_original() {
        val causa = IllegalArgumentException("pin=482719 par=192.0.2.1:7877")
        val erro = IllegalStateException("falha em [fd00::1]:7979", causa)
        erro.addSuppressed(IllegalStateException("PIN 482719"))
        val saida = RedacaoDeLogs.falha(erro)
        assertTrue(saida.contains("IllegalStateException"))
        assertTrue(saida.contains("IllegalArgumentException"))
        assertTrue(saida.contains("suprimidas=1"))
        assertFalse(saida.contains("482719"))
        assertFalse(saida.contains("192.0.2.1"))
        assertFalse(saida.contains("fd00::1"))
    }

    @Test
    fun campo_incompleto_ou_livre_retira_todos_os_fragmentos_ate_o_fim_da_mensagem() {
        val a = "PrimeiroFragmentoPrivado"
        val b = "SegundoFragmentoPrivado"
        for (rotulo in listOf("segredo", "password", "senha", "token", "authorization", "ice_pwd", "ice_ufrag", "ufrag")) {
            for (valor in listOf("$a $b", "\"$a $b", "'$a $b", "[\"$a\",[\"$b\"]", "{\"a\":\"$a\",\"b\":[\"$b\"]", "[\"$a\",{\"b\":\"$b\"]")) {
                val saida = RedacaoDeLogs.mensagem("$rotulo=$valor\nstatus=17 fps=30")
                for (fragmento in listOf(a, b, "Primeiro", "Segundo", "FragmentoPrivado")) {
                    assertFalse("$rotulo/$valor: fragmento $fragmento", saida.contains(fragmento))
                }
                assertFalse(saida.contains("status=17"))
            }
        }
    }

    @Test
    fun campos_completos_aninhados_preservam_as_metricas_seguintes() {
        for (valor in listOf("\"Primeiro Segundo\"", "'Primeiro Segundo'", "[\"Primeiro\",[\"Segundo\"]]", "{\"a\":[\"Primeiro\",{\"b\":\"Segundo\"}]}")) {
            assertEquals("secret=<segredo> status=17 fps=30", RedacaoDeLogs.mensagem("secret=$valor status=17 fps=30"))
        }
        assertEquals("secret=<segredo> status=17", RedacaoDeLogs.mensagem("secret=\"Primeiro\\\" Segundo\" status=17"))
        assertEquals("device_id=<identificador>", RedacaoDeLogs.mensagem("device_id=\"Nome livre sem fechar status=17"))
    }

    @Test
    fun rotulos_de_material_de_pareamento_e_pin_malformado_nao_deixam_fragmentos() {
        for (rotulo in listOf("pin", "pinDoPrompter", "pin_do_prompter", "private_key", "public_key", "shared_secret", "chave", "nonce", "mac", "proof", "resume_key", "pair_key")) {
            val saida = RedacaoDeLogs.mensagem("$rotulo=Alpha Beta")
            assertFalse(saida.contains("Alpha"))
            assertFalse(saida.contains("Beta"))
        }
        for (entrada in listOf("PIN 4-82719 Alpha Beta", "PIN novo 482719 Alpha Beta", "PIN malformado 12 Alpha Beta")) {
            val saida = RedacaoDeLogs.mensagem(entrada)
            assertFalse(saida.contains("82719"))
            assertFalse(saida.contains("Alpha"))
            assertFalse(saida.contains("Beta"))
        }
    }

    @Test
    fun detalhe_externo_nao_ecoa_prosa_nem_segredo_sem_rotulo() {
        assertEquals("detalhe externo omitido", RedacaoDeLogs.erroExterno("NomeDeVizinho 482719 duas palavras"))
        assertEquals("conexão recusada; errno=61", RedacaoDeLogs.erroExterno("connection refused NomeDeVizinho segredoLivre (os error 61)"))
        assertEquals("detalhe externo omitido; errno=13", RedacaoDeLogs.erroExterno("outro erro NomeDeArquivo errno=13"))
        assertEquals("detalhe externo omitido", RedacaoDeLogs.erroExterno("errno=482719 segredoLivre"))
        assertEquals("detalhe externo omitido", RedacaoDeLogs.erroExterno("errno=9999 segredoLivre"))
    }

    @Test
    fun throwable_so_preserva_classe_codigo_causas_e_local_de_codigo() {
        val causa = IllegalArgumentException("NomeSemRotulo segredoLivre 482719 errno=13")
        val erro = IllegalStateException("ArquivoPrivado e outras palavras", causa)
        erro.stackTrace = arrayOf(StackTraceElement("com.quall.android.FonteTeste", "abrir", "FonteTeste.kt", 42))
        val saida = RedacaoDeLogs.falha(erro)
        for (fragmento in listOf("NomeSemRotulo", "segredoLivre", "482719", "ArquivoPrivado", "outras palavras")) assertFalse(saida.contains(fragmento))
        assertTrue(saida.contains("IllegalStateException"))
        assertTrue(saida.contains("IllegalArgumentException"))
        assertTrue(saida.contains("errno=13"))
        assertTrue(saida.contains("com.quall.android.FonteTeste.abrir:42"))
    }

    @Test
    fun valor_multilinha_completo_e_truncado_nao_vaza_a_cauda() {
        for (rotulo in listOf("secret", "password", "ice_pwd", "device_id")) {
            for (valor in listOf("\"Prefixo\nCaudaSensivel\"", "[\"Prefixo\",\n[\"CaudaSensivel\"]]", "{\"a\":\"Prefixo\",\n\"b\":\"CaudaSensivel\"}")) {
                val saida = RedacaoDeLogs.mensagem("$rotulo=$valor\nstatus=17 fps=30")
                for (fragmento in listOf("Prefixo", "Cauda", "Sensivel")) assertFalse(saida.contains(fragmento))
                assertTrue(saida.endsWith("\nstatus=17 fps=30"))
            }
            for (valor in listOf("\"Prefixo\nCaudaSensivel", "[\"Prefixo\",\n[\"CaudaSensivel\"]", "{\"a\":\"Prefixo\",\n\"b\":\"CaudaSensivel\"", "Prefixo\nCaudaSensivel")) {
                val saida = RedacaoDeLogs.mensagem("$rotulo=$valor\nstatus=17 fps=30")
                for (fragmento in listOf("Prefixo", "Cauda", "Sensivel", "status=17")) assertFalse(saida.contains(fragmento))
            }
        }
    }
}
