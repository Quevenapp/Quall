// Banco de prova de `src/camera-remota-regras.c`, sem OBS nenhum: as regras que decidem o que o
// painel "Câmera do aparelho" mostra (R9b, `docs/controle-remoto-da-camera.md` §12).
//
//     cc -Wall -Wextra -Werror -o "$TMPDIR/prova-camera-remota" \
//        plugins/obs/bancada/prova-camera-remota.c plugins/obs/src/camera-remota-regras.c -lm \
//        && "$TMPDIR/prova-camera-remota"
//
// Cobre: os degraus de ISO (terços, faixa, o atual fora da escala), os do obturador (cinema e
// log2, **sempre inteiros**: 2^-13 s não é inteiro em ns, e o filmador recusaria), o texto do
// obturador, o número com o separador do idioma, as áreas, e os códigos de limite e de recusa
// (inclusive os que esta build não conhece).

#include "../src/camera-remota-regras.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static int falhas, casos;

static void confere_texto(const char *caso, const char *obtido, const char *esperado)
{
	casos++;
	if (strcmp(obtido, esperado) != 0) {
		falhas++;
		printf("FALHOU %s: obtido \"%s\", esperado \"%s\"\n", caso, obtido, esperado);
	}
}

static void confere_int(const char *caso, long long obtido, long long esperado)
{
	casos++;
	if (obtido != esperado) {
		falhas++;
		printf("FALHOU %s: obtido %lld, esperado %lld\n", caso, obtido, esperado);
	}
}

static void lista(const int64_t *v, size_t n, char *buf, size_t cap)
{
	size_t u = 0;
	buf[0] = '\0';
	for (size_t i = 0; i < n && u < cap; i++)
		u += (size_t)snprintf(buf + u, cap - u, "%s%lld", i ? " " : "", (long long)v[i]);
}

int main(void)
{
	int64_t d[64];
	char b[512];
	size_t n;

	// ISO: terços na faixa, mais o mínimo e o máximo exatos.
	n = degraus_de_iso(55, 900, false, 0, d, 64);
	lista(d, n, b, sizeof b);
	confere_texto("iso 55..900", b, "55 64 80 100 125 160 200 250 320 400 500 640 800 900");
	// O atual fora da escala entra (o combo tem de mostrar o que está valendo).
	n = degraus_de_iso(50, 3200, true, 333, d, 64);
	confere_int("iso com atual 333: quantos", (long long)n, 20);
	n = degraus_de_iso(50, 3200, true, 9999, d, 64);
	confere_int("iso com atual fora da faixa: não entra", (long long)n, 19);
	n = degraus_de_iso(800, 100, false, 0, d, 64);
	confere_int("iso com faixa invertida", (long long)n, 0);
	n = degraus_de_iso(50, 6400, false, 0, d, 4);
	confere_int("iso respeita a capacidade", (long long)n, 4);

	// Obturador de cinema na faixa do Android do exemplo do §3.2 (100 µs a 1/30 s).
	n = degraus_do_obturador(100000, 33333333, false, false, 0, d, 64);
	lista(d, n, b, sizeof b);
	confere_texto("obturador cinema", b,
		      "100000 125000 250000 500000 1000000 2000000 4000000 8000000 8333333 10000000 "
		      "16666667 20000000 20833333 33333333");
	casos++;
	for (size_t i = 1; i < n; i++)
		if (d[i - 1] >= d[i]) {
			falhas++;
			printf("FALHOU obturador cinema fora de ordem em %zu\n", i);
			break;
		}
	// log2 (Windows): 2^v s, arredondado ao inteiro, de 1/8192 s a 1/32 s.
	n = degraus_do_obturador(122070, 31250000, true, false, 0, d, 64);
	lista(d, n, b, sizeof b);
	confere_texto("obturador log2", b, "122070 244141 488281 976563 1953125 3906250 7812500 15625000 31250000");
	// 13/10 (§3.1): com "Travar fps" desligado o `max` é o teto efetivo, 1/piso. A 30 fps, 1/15 s:
	// entram o 1/15 e o 1/20 (com o 1/24 e o 1/25 de antes); um teto fora da lista entra ele mesmo.
	n = degraus_do_obturador(10000000, 66666667, false, false, 0, d, 64);
	lista(d, n, b, sizeof b);
	confere_texto("obturador até 1/15", b, "10000000 16666667 20000000 20833333 33333333 40000000 41666667 "
					       "50000000 66666667");
	n = degraus_do_obturador(10000000, 83333333, false, false, 0, d, 64);
	confere_int("obturador até 1/12: o teto e o 1/15", d[n - 1] == 83333333 && d[n - 2] == 66666667, 1);
	// log2 até o teto novo: 1/16 s a 30 fps destravado.
	n = degraus_do_obturador(1000000, 66666667, true, false, 0, d, 64);
	confere_int("obturador log2 até 1/16", d[n - 1], 62500000);

	// O `ev` remoto (13/10, §3.3): sem a dica, só com Auto e destravado; com ela, sempre.
	confere_int("ev sem dica, Auto", ev_remoto_livre(false, true, false), 1);
	confere_int("ev sem dica, Manual", ev_remoto_livre(false, false, false), 0);
	confere_int("ev sem dica, travado", ev_remoto_livre(false, true, true), 0);
	confere_int("ev com dica, Manual", ev_remoto_livre(true, false, false), 1);
	confere_int("ev com dica, travado", ev_remoto_livre(true, true, true), 1);
	confere_int("nota de destravar sem dica", nota_de_destravar_o_ev(false, true, true), 1);
	confere_int("nota de destravar com dica", nota_de_destravar_o_ev(true, true, true), 0);
	confere_int("nota de destravar no Manual", nota_de_destravar_o_ev(false, false, true), 0);

	n = degraus_do_obturador(1000000, 2000000, false, true, 1234567.4, d, 64);
	lista(d, n, b, sizeof b);
	confere_texto("obturador com atual", b, "1000000 1234567 2000000");

	// Texto do obturador.
	texto_do_obturador(16666667, ',', b, sizeof b);
	confere_texto("1/60", b, "1/60 s");
	texto_do_obturador(122070, ',', b, sizeof b);
	confere_texto("1/8192", b, "1/8192 s");
	texto_do_obturador(2000000000, ',', b, sizeof b);
	confere_texto("2 s", b, "2 s");
	texto_do_obturador(1500000000, '.', b, sizeof b);
	confere_texto("1.5 s", b, "1.5 s");

	// Número com separador.
	numero_com_separador(1.7, 1, ',', b, sizeof b);
	confere_texto("f/1,7", b, "1,7");
	numero_com_separador(-0.3, 1, ',', b, sizeof b);
	confere_texto("-0,3", b, "-0,3");
	numero_com_separador(-0.04, 1, ',', b, sizeof b);
	confere_texto("-0,04 com 1 casa é 0", b, "0");
	numero_com_separador(0.50, 2, '.', b, sizeof b);
	confere_texto("0.5", b, "0.5");
	numero_com_separador(5200, 0, ',', b, sizeof b);
	confere_texto("5200", b, "5200");

	// Metros do foco: 10 dioptrias na posição 1 = 0,1 m; na metade, 0,2 m; na 0, infinito.
	{
		double mt = 0;
		confere_int("foco em 1", metros_do_foco(10, 1, &mt) && numeros_iguais(mt, 0.1), 1);
		confere_int("foco em 0,5", metros_do_foco(10, 0.5, &mt) && numeros_iguais(mt, 0.2), 1);
		confere_int("foco em 0 é infinito", metros_do_foco(10, 0, &mt), 0);
		confere_int("sem dioptrias é infinito", metros_do_foco(0, 0.5, &mt), 0);
	}

	// Comparação.
	confere_int("800 == 800.0", numeros_iguais(800, 800.0), 1);
	confere_int("0.3 == 0.30000001", numeros_iguais(0.3, 0.30000001), 1);
	confere_int("0.3 != 0.4", numeros_iguais(0.3, 0.4), 0);

	// Áreas.
	confere_int("area ev", area_do_campo("ev"), AREA_EXPOSICAO);
	confere_int("area obturadorNs", area_do_campo("obturadorNs"), AREA_ISO_E_OBTURADOR);
	confere_int("area kelvin", area_do_campo("kelvin"), AREA_BALANCO);
	confere_int("area focoPosicao", area_do_campo("focoPosicao"), AREA_FOCO);
	confere_int("area toque", area_do_campo("toque"), AREA_NENHUMA);
	confere_int("area travaIso (leitura)", area_do_campo("travaIso"), AREA_NENHUMA);
	// Os ajustes de imagem (R9 §3.7, 13/10).
	confere_int("area gama", area_do_campo("gama"), AREA_IMAGEM);
	confere_int("area nitidez", area_do_campo("nitidez"), AREA_IMAGEM);
	confere_int("area contraluz", area_do_campo("contraluz"), AREA_IMAGEM);
	confere_int("imagem saturacao", e_ajuste_de_imagem("saturacao"), 1);
	confere_int("imagem contraste", e_ajuste_de_imagem("contraste"), 1);
	confere_int("imagem contraluz não é de -100 a 100", e_ajuste_de_imagem("contraluz"), 0);
	confere_int("imagem ev", e_ajuste_de_imagem("ev"), 0);
	confere_int("imagem nulo", e_ajuste_de_imagem(NULL), 0);

	// O zoom (R9 §3.8, 13/10): na área Foco, o ausente é o 1× cortado na faixa, o texto com o separador
	// e o "×", e as paradas lidas sem o locale.
	confere_int("area zoom", area_do_campo("zoom"), AREA_FOCO);
	confere_int("zoom", e_zoom("zoom"), 1);
	confere_int("zoom nulo", e_zoom(NULL), 0);
	confere_int("zoom não é imagem", e_ajuste_de_imagem("zoom"), 0);
	confere_int("neutro 0,6..100", llround(zoom_neutro(0.6, 100) * 100), 100);
	confere_int("neutro 2..10", llround(zoom_neutro(2, 10) * 100), 200);
	texto_do_zoom(0.6, ',', b, sizeof b);
	confere_texto("zoom 0,6", b, "0,6\xc3\x97");
	texto_do_zoom(1.0, ',', b, sizeof b);
	confere_texto("zoom 1", b, "1\xc3\x97");
	texto_do_zoom(2.38, '.', b, sizeof b);
	confere_texto("zoom 2.4 em inglês", b, "2.4\xc3\x97");
	texto_do_zoom(23.6, ',', b, sizeof b);
	confere_texto("zoom 24", b, "24\xc3\x97");
	{
		double z[ZOOM_PARADAS_MAX];
		size_t k = json_lista_de_numeros("[0.6, 1,3 ,5e0,\"x\",{\"a\":1},-2.5E-1]", z, ZOOM_PARADAS_MAX);
		confere_int("paradas lidas", (long long)k, 5);
		confere_int("parada 0", llround(z[0] * 100), 60);
		confere_int("parada 3", llround(z[3] * 100), 500);
		confere_int("parada 4", llround(z[4] * 100), -25);
		confere_int("não é lista", (long long)json_lista_de_numeros("{\"a\":1}", z, 4), 0);
		confere_int("cap", (long long)json_lista_de_numeros("[1,2,3,4,5]", z, 2), 2);
	}

	// Limites.
	confere_int("limite macos", frase_do_limite("macos"), LIMITE_MACOS);
	confere_int("limite outro_app", frase_do_limite("outro_app"), LIMITE_OUTRO_APP);
	confere_int("limite novo", frase_do_limite("lente_quebrada"), LIMITE_OUTRO);
	confere_int("foco_fixo sem controle", limite_leva_controle(LIMITE_FOCO_FIXO), 0);
	confere_int("fabricante com controle", limite_leva_controle(LIMITE_FABRICANTE), 1);
	confere_int("outro com controle", limite_leva_controle(LIMITE_OUTRO), 1);

	// Recusas (§3.5).
	confere_int("recusa superado", frase_da_recusa("superado"), RECUSA_NADA);
	confere_int("recusa camera_trocada", frase_da_recusa("camera_trocada"), RECUSA_NADA);
	confere_int("recusa nao_permitido", frase_da_recusa("nao_permitido"), RECUSA_NAO_PERMITIDO);
	confere_int("recusa incoerente", frase_da_recusa("incoerente"), RECUSA_NAO_ACEITOU);
	confere_int("recusa sem_resposta", frase_da_recusa("sem_resposta"), RECUSA_NAO_RESPONDEU);
	confere_int("recusa desconhecida", frase_da_recusa("bateria_fraca"), RECUSA_NAO_APLICOU);
	confere_int("recusa nula", frase_da_recusa(NULL), RECUSA_NADA);

	// O leitor mínimo de JSON: as listas de texto que o `obs_data` descarta. Com espaços, escape e
	// chaves na ordem que for, porque o leitor não pode depender de quem escreveu.
	{
		const char *estado =
			"{\"situacao\":\"pronto\",\"autor\":\"Pixel \\\"do\\\" {Bruno} [x]\","
			"\"capacidades\":{\"controles\":{\"ev\":{\"max\":2.0,\"min\":-2.0},"
			"\"foco\": {\"passo\":1, \"valores\": [\"auto\", \"travado\",\"manual\"]},"
			"\"iso\":{\"inteiro\":true}},\"limites\":{}},"
			"\"lido\":{\"iso\":400,\"divergentes\":[\"iso\",\"obturadorNs\"]},"
			"\"ajuste\":{\"foco\":\"auto\"}}";
		char t[8][24];
		const char *c1[] = {"capacidades", "controles", "foco", "valores"};
		n = json_lista_de_textos(json_procurar(estado, c1, 4), &t[0][0], 24, 8);
		confere_int("valores do foco: quantos", (long long)n, 3);
		confere_texto("valores do foco: o terceiro", n == 3 ? t[2] : "", "manual");
		const char *c2[] = {"lido", "divergentes"};
		n = json_lista_de_textos(json_procurar(estado, c2, 2), &t[0][0], 24, 8);
		confere_int("divergentes: quantos", (long long)n, 2);
		confere_texto("divergentes: o segundo", n == 2 ? t[1] : "", "obturadorNs");
		const char *c3[] = {"capacidades", "controles", "kelvin", "valores"};
		confere_int("campo ausente", json_procurar(estado, c3, 4) == NULL, 1);
		const char *c4[] = {"capacidades", "controles", "ev", "valores"};
		confere_int("descritor sem valores", json_procurar(estado, c4, 4) == NULL, 1);
		confere_int("lista que não é lista",
			    (long long)json_lista_de_textos("{\"a\":1}", &t[0][0], 24, 8), 0);
		confere_int("lixo não derruba", json_procurar("{\"lido\":", c2, 2) == NULL, 1);
		const char *c5[] = {"capacidades", "controles", "foco"};
		confere_int("tamanho do descritor do foco",
			    (long long)json_tamanho_do_valor(json_procurar(estado, c5, 3)),
			    (long long)strlen("{\"passo\":1, \"valores\": [\"auto\", \"travado\",\"manual\"]}"));
		const char *c6[] = {"situacao"};
		confere_int("tamanho de um texto",
			    (long long)json_tamanho_do_valor(json_procurar(estado, c6, 1)), 8);
		char curtos[4][8];
		n = json_lista_de_textos("[\"luzDoDia\",\"um-texto-comprido-demais-para-caber\"]",
					 &curtos[0][0], 8, 4);
		confere_texto("texto cortado na largura", n == 2 ? curtos[1] : "", "um-text");
	}

	// "Travar fps" (R9 §3.1.1): a frase e o botão do aviso da pouca luz.
	{
		confere_int("area travarFps", area_do_campo("travarFps"), AREA_EXPOSICAO);
		struct pouca_luz p = pouca_luz_do_filmador(true, 15, 15, true, 30, true, false, true, true);
		confere_int("clareando: frase", p.frase, POUCA_LUZ_CLAREANDO);
		confere_int("clareando: o fps que chega", p.numero_da_frase, 15);
		confere_int("clareando: botão", p.botao, BOTAO_DA_LUZ_TRAVAR_EM);
		confere_int("clareando: o fps escolhido", p.numero_do_botao, 30);
		confere_int("clareando: o botão trava", p.botao_trava, 1);
		p = pouca_luz_do_filmador(true, 30, 15, true, 30, true, true, true, true);
		confere_int("travada: frase", p.frase, POUCA_LUZ_ESCURA);
		confere_int("travada: a 30", p.numero_da_frase, 30);
		confere_int("travada: botão", p.botao, BOTAO_DA_LUZ_CLAREAR);
		confere_int("travada: o piso", p.numero_do_botao, 15);
		confere_int("travada: o botão destrava", p.botao_trava, 0);
		p = pouca_luz_do_filmador(true, 15, 15, false, 0, true, false, true, true);
		confere_int("sem o fps: botão sem número", p.botao, BOTAO_DA_LUZ_TRAVAR);
		p = pouca_luz_do_filmador(true, 15, 15, true, 30, false, false, true, true);
		confere_int("manual: nada", p.frase, POUCA_LUZ_NADA);
		p = pouca_luz_do_filmador(true, 15, 15, true, 30, true, false, false, true);
		confere_int("sem a trava: a frase", p.frase, POUCA_LUZ_CLAREANDO);
		confere_int("sem a trava: sem botão", p.botao, BOTAO_DA_LUZ_NADA);
		p = pouca_luz_do_filmador(true, 15, 15, true, 30, true, false, true, false);
		confere_int("não permitido: sem botão", p.botao, BOTAO_DA_LUZ_NADA);
		p = pouca_luz_do_filmador(false, 0, 0, false, 0, true, false, true, true);
		confere_int("apagada: nada", p.frase, POUCA_LUZ_NADA);
	}

	// A prévia antes de conectar (13/10): o conjunto típico do R9, por área e sem repetir.
	{
		static const long long esperado[] = {5, 2, 3, 3, 5}; // o Foco com o zoom no alto (R9 §3.8)
		size_t total = 0;
		for (int area = AREA_EXPOSICAO; area < AREA_NENHUMA; area++) {
			const char *campos[16];
			size_t n = campos_da_previa((enum area_da_camera)area, campos, 16);
			confere_int("prévia: campos da área", (long long)n, esperado[area]);
			casos++;
			if (!titulo_da_area((enum area_da_camera)area)) {
				falhas++;
				printf("FALHOU prévia: área %d sem título\n", area);
			}
			for (size_t i = 0; i < n; i++) {
				confere_int("prévia: o campo é da área", (long long)area_do_campo(campos[i]), area);
				casos++;
				if (!rotulo_da_previa(campos[i])) {
					falhas++;
					printf("FALHOU prévia: %s sem rótulo\n", campos[i]);
				}
			}
			total += n;
		}
		confere_int("prévia: total", (long long)total, 18);
		const char *um[1];
		confere_int("prévia: cap respeitado", (long long)campos_da_previa(AREA_EXPOSICAO, um, 1), 1);
		confere_texto("prévia: primeiro da exposição", um[0], "exposicao");
		confere_int("prévia: nenhuma área", (long long)campos_da_previa(AREA_NENHUMA, um, 1), 0);
		casos++;
		if (rotulo_da_previa("toque") || titulo_da_area(AREA_NENHUMA)) {
			falhas++;
			printf("FALHOU prévia: toque ou área nenhuma não são da prévia\n");
		}
	}

	printf("%d casos, %d falhas\n", casos, falhas);
	return falhas ? 1 : 0;
}
