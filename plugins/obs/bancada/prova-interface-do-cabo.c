// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
// Banco de prova da **escolha automática da interface**, sem OBS, sem rede e sem aparelho.
//
// Mesma razão de `prova-janela-do-enlace.c`: a decisão que vai prender a mídia a uma interface —
// e, ao prender, **desistir de todas as outras** — não pode ficar à espera de uma corrida com
// seis celulares num hub para ser afirmada. A parte pura do módulo não inclui nada do `libobs` e
// não abre socket nenhum, então ela compila e roda sozinha:
//
//     cc -std=c17 -Wall -Wextra -Werror -o /tmp/prova-interface-do-cabo \
//        plugins/obs/bancada/prova-interface-do-cabo.c plugins/obs/src/interface-do-cabo.c \
//        && /tmp/prova-interface-do-cabo
//
// **O que este banco NÃO prova**, e está dito aqui para não ser lido como mais do que é: ele
// exercita `candidatas_do_par`, `decidir_interface` e `formatar_candidatas` com a tabela de
// interfaces e as respostas da sondagem **dadas de mão beijada**. Quem enumera as interfaces de
// verdade (`interfaces_locais`) e quem põe o pacote no fio (`sondar_interface`) toca a
// plataforma, e nada aqui os exercita. Só bancada com aparelho prova aqueles dois.
//
// A tabela de interfaces dos casos 4 a 7 é a **medida** desta bancada em 01/09/2026, com três
// iOS no cabo (`docs/quall-pelo-cabo.md`):
//
//     en8  169.254.75.173  ->  iPad A16    169.254.20.3
//     en10 169.254.20.226  ->  iPhone X    169.254.20.2
//     en12 169.254.81.198  ->  iPhone 7    169.254.212.12
//     en0  192.168.56.131   ->  a Wi-Fi
//
// As três primeiras são `169.254/16`: **as três "contêm" qualquer aparelho de qualquer cabo**, e
// é exatamente por isso que a tabela de rotas não desempata.

#include "../src/interface-do-cabo.h"

#include <stdio.h>
#include <string.h>

static int falhas;
static int casos;

static uint32_t ip4(unsigned a, unsigned b, unsigned c, unsigned d)
{
	return (a << 24) | (b << 16) | (c << 8) | d;
}

static struct interface_local iface(const char *nome, uint32_t ip, unsigned bits)
{
	struct interface_local i;
	memset(&i, 0, sizeof i);
	snprintf(i.nome, sizeof i.nome, "%s", nome);
	i.ip = ip;
	i.mascara = bits == 0 ? 0u : (0xFFFFFFFFu << (32 - bits));
	return i;
}

/// A bancada de 01/09: três cabos e a Wi-Fi. A ordem em que a plataforma as devolve é
/// deliberadamente **diferente** da ordem de sondagem, para que o teste não passe por acidente.
static size_t bancada(struct interface_local *ifs)
{
	ifs[0] = iface("en0", ip4(192, 168, 1, 131), 24);
	ifs[1] = iface("en8", ip4(169, 254, 75, 173), 16);
	ifs[2] = iface("en12", ip4(169, 254, 81, 198), 16);
	ifs[3] = iface("en10", ip4(169, 254, 20, 226), 16);
	return 4;
}

static void confere(const char *caso, const struct escolha_de_interface *e, bool prender,
		    const char *nome, enum motivo_da_escolha motivo, size_t candidatas)
{
	casos++;
	if (e->prender == prender && (!prender || strcmp(e->nome, nome) == 0) &&
	    e->motivo == motivo && e->candidatas == candidatas) {
		if (prender)
			printf("ok %s\n  prende em %s (%s) — %s\n", caso, e->nome, e->endereco,
			       motivo_em_palavras(e->motivo));
		else
			printf("ok %s\n  não prende — %s\n", caso, motivo_em_palavras(e->motivo));
		return;
	}
	falhas++;
	printf("FALHOU %s\n  esperado: prender=%d nome=%s motivo=%d candidatas=%zu\n"
	       "  obtido  : prender=%d nome=%s motivo=%d candidatas=%zu\n",
	       caso, (int)prender, prender ? nome : "-", (int)motivo, candidatas, (int)e->prender,
	       e->nome[0] ? e->nome : "-", (int)e->motivo, e->candidatas);
}

// -------------------------------------------------------------------------------------------------
// O extra que **toca o sistema**, e por isso não conta nos 12
//
// `prova-interface-do-cabo --sonda-em-loopback` enumera as interfaces de verdade e sonda
// `127.0.0.1:9` (*discard*, que nenhuma máquina desta bancada escuta) a partir de `127.0.0.1`.
// Não sai um byte na rede: é tudo laço interno.
//
// O que ele mede é a peça de que toda a decisão depende e que nenhum dos 12 casos exercita: **um
// ICMP *port unreachable* de volta vira `ECONNREFUSED` num socket UDP conectado, dentro do
// prazo**. Se isto não funcionasse, `sondar_interface` devolveria `sem resposta` para sempre e a
// escolha com três cabos nunca sairia do empate.
//
// Continua **não** provando o que só o cabo prova: que um iOS do outro lado de um USB-Ethernet
// responde do mesmo jeito, e que o pacote saiu pela interface a que o socket se prendeu.
// -------------------------------------------------------------------------------------------------
static int sonda_em_loopback(void)
{
	struct interface_local ifs[INTERFACES_MAX];
	size_t n = interfaces_locais(ifs, INTERFACES_MAX);
	printf("interfaces IPv4 no ar nesta máquina: %zu\n", n);
	for (size_t i = 0; i < n; i++) {
		char end[INTERFACE_ENDERECO_MAX];
		endereco_em_texto(ifs[i].ip, end, sizeof end);
		unsigned bits = 0;
		for (uint32_t m = ifs[i].mascara; m & 0x80000000u; m <<= 1)
			bits++;
		printf("   %-12s %s/%u\n", ifs[i].nome, end, bits);
	}

	enum sonda s = sondar_interface(ip4(127, 0, 0, 1), ip4(127, 0, 0, 1), 9, SONDA_PRAZO_MS);
	const char *nome = s == SONDA_ALCANCOU     ? "ALCANCOU"
			   : s == SONDA_NAO_ALCANCOU ? "NAO_ALCANCOU"
			   : s == SONDA_SEM_RESPOSTA ? "SEM_RESPOSTA"
						     : "NAO_FEITA";
	printf("\nsonda 127.0.0.1 -> 127.0.0.1:9 (porta fechada): %s\n", nome);
	if (s == SONDA_ALCANCOU) {
		printf("verde: o ICMP de porta inalcançável chega como ECONNREFUSED e vira prova"
		       " positiva\n");
		return 0;
	}
	printf("VERMELHO: sem o ECONNREFUSED a sondagem nunca desempata\n");
	return 1;
}

int main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "--sonda-em-loopback") == 0)
		return sonda_em_loopback();

	struct interface_local ifs[8];
	enum sonda sondas[8];
	struct escolha_de_interface e;
	uint32_t par = 0;
	uint16_t porta = 0;

	// --- 1. o endereço do par -----------------------------------------------------------
	casos++;
	if (separar_endereco_do_par("169.254.20.3:7877", &par, &porta) &&
	    par == ip4(169, 254, 164, 151) && porta == 7877) {
		printf("ok o endereço do par vira ip e porta\n  169.254.20.3 : 7877\n");
	} else {
		falhas++;
		printf("FALHOU o endereço do par vira ip e porta\n");
	}

	casos++;
	{
		// Um nome de máquina, um IPv6 com escopo, um endereço sem porta e lixo depois da
		// porta. Nenhum é literal IPv4, e nenhum pode virar um `bind_address` chutado.
		const char *ruins[] = {"iPad-de-Pessoa Exemplo.local:7877", "[fe80::1%en8]:7877",
				       "169.254.20.3", "169.254.20.3:7877x",
				       "169.254.300.1:7877", "169.254.20.3:0", NULL};
		bool todos_recusados = true;
		for (int i = 0; ruins[i]; i++) {
			if (separar_endereco_do_par(ruins[i], &par, &porta)) {
				todos_recusados = false;
				printf("  aceitou o que não devia: %s\n", ruins[i]);
			}
		}
		if (todos_recusados) {
			printf("ok o que não é literal IPv4 é recusado\n"
			       "  nome, IPv6 com escopo, sem porta, lixo na porta, octeto > 255,"
			       " porta 0\n");
		} else {
			falhas++;
			printf("FALHOU o que não é literal IPv4 é recusado\n");
		}
	}

	// --- 2. um enlace, um bind — inclusive na Wi-Fi -------------------------------------
	//
	// **Este teste mudou de resposta em 01/09/2026, e a mudança é o conserto.**
	//
	// Ele afirmava que o par de Wi-Fi **não** prende, com o argumento de que fora do link-local
	// prender só tira candidato do ICE, "que sabe escolher sozinho". A bancada mediu o furo: o
	// A10s ancorado por USB dá `192.168.58.57`, que é privado e não link-local, e o ICE
	// escolheu **o rádio** — 190 trancos numa corrida que só precisava de bind para dar zero.
	// Fora do link-local prender não habilita o caminho, **seleciona**; e selecionar é o que a
	// pessoa pediu ao digitar aquele endereço.
	//
	// A regra passou a ser o **enlace**: uma interface no enlace do par, um bind. Aqui `en0`
	// contém 192.168.56.137 e é a única que contém, então prende em `en0` — e a sessão vai pela
	// Wi-Fi exatamente como antes, porque não havia outro caminho para ela ir.
	//
	// **O custo, e ele é real:** os candidatos IPv6 deixam de ser oferecidos. A sinalização
	// deste projeto é IPv4 (`signaling.rs` faz `bind(("0.0.0.0", porta))`), então nenhuma sessão
	// de hoje depende deles — mas é opção perdida, e está escrita e não escondida.
	{
		size_t n = bancada(ifs);
		memset(sondas, 0, sizeof sondas);
		e = decidir_interface(ifs, n, ip4(192, 168, 1, 137), sondas);
		confere("o par de Wi-Fi prende na única interface do enlace dele", &e, true,
			"en0", MOTIVO_UNICA_CANDIDATA, 1);
	}

	// --- 2b. a ancoragem de Android, que é o caso que a regra antiga errava --------------
	//
	// `192.168.59.76` é o A10s ancorado por USB; `Ethernet 4` do Dell é `192.168.59.218/24`.
	// Endereço **privado**, não link-local: pela regra antiga não prendia, e a mídia ia pelo
	// rádio com o telefone alcançável pelos dois caminhos.
	{
		ifs[0] = iface("en0", ip4(192, 168, 1, 131), 24);
		ifs[1] = iface("Ethernet 4", ip4(192, 168, 248, 218), 24);
		memset(sondas, 0, sizeof sondas);
		e = decidir_interface(ifs, 2, ip4(192, 168, 248, 76), sondas);
		confere("a ancoragem de Android prende, apesar de o endereço ser privado", &e, true,
			"Ethernet 4", MOTIVO_UNICA_CANDIDATA, 1);
	}

	// --- 3. cabo sem interface de cabo --------------------------------------------------
	{
		ifs[0] = iface("en0", ip4(192, 168, 1, 131), 24);
		memset(sondas, 0, sizeof sondas);
		e = decidir_interface(ifs, 1, ip4(169, 254, 164, 151), sondas);
		confere("par no cabo e nenhuma interface no enlace", &e, false, NULL,
			MOTIVO_NENHUMA_INTERFACE_NO_ENLACE, 0);
	}

	// --- 4. um cabo só: a sondagem informa, não decide -----------------------------------
	{
		ifs[0] = iface("en0", ip4(192, 168, 1, 131), 24);
		ifs[1] = iface("en8", ip4(169, 254, 75, 173), 16);
		memset(sondas, 0, sizeof sondas);
		sondas[1] = SONDA_SEM_RESPOSTA;
		e = decidir_interface(ifs, 2, ip4(169, 254, 164, 151), sondas);
		confere("um cabo só, sem resposta: prende assim mesmo", &e, true, "en8",
			MOTIVO_UNICA_CANDIDATA, 1);

		// E o "não" explícito do sistema veta — é a única resposta que veta.
		sondas[1] = SONDA_NAO_ALCANCOU;
		e = decidir_interface(ifs, 2, ip4(169, 254, 164, 151), sondas);
		confere("um cabo só, mas o sistema disse que não há rota", &e, false, NULL,
			MOTIVO_UNICA_RECUSADA_PELA_SONDA, 1);
	}

	// --- 5. TRÊS CABOS: o caso que motiva o módulo inteiro -------------------------------
	//
	// O iPad está no `en8`. As três interfaces `169.254/16` contêm o endereço dele, e a ordem
	// determinística de sondagem começa por `en10` — a **errada**. Se a escolha fosse pela
	// tabela de rotas, ou pela ordem, ou pela primeira candidata, o resultado seria `en10` e a
	// sessão não subiria. Quem desempata é a resposta.
	{
		size_t n = bancada(ifs);
		size_t idx[8];
		size_t k = candidatas_do_par(ifs, n, ip4(169, 254, 164, 151), idx, 8);

		casos++;
		if (k == 3 && strcmp(ifs[idx[0]].nome, "en10") == 0 &&
		    strcmp(ifs[idx[1]].nome, "en12") == 0 && strcmp(ifs[idx[2]].nome, "en8") == 0) {
			printf("ok as três candidatas saem em ordem fixa, e a primeira é a errada\n"
			       "  %s, %s, %s — o iPad está na última\n",
			       ifs[idx[0]].nome, ifs[idx[1]].nome, ifs[idx[2]].nome);
		} else {
			falhas++;
			printf("FALHOU a ordem das candidatas (k=%zu)\n", k);
		}

		// Só o `en8` respondeu.
		memset(sondas, 0, sizeof sondas);
		sondas[3] = SONDA_SEM_RESPOSTA; // en10, sondada primeiro e calada
		sondas[2] = SONDA_SEM_RESPOSTA; // en12, idem
		sondas[1] = SONDA_ALCANCOU;     // en8, o cabo do iPad
		e = decidir_interface(ifs, n, ip4(169, 254, 164, 151), sondas);
		confere("com três cabos, quem responde é quem prende", &e, true, "en8",
			MOTIVO_SONDA_RESPONDEU, 3);

		casos++;
		if (strcmp(e.endereco, "169.254.75.173") == 0) {
			printf("ok o endereço que vai para o bind_address é o local, não o do par\n"
			       "  %s\n", e.endereco);
		} else {
			falhas++;
			printf("FALHOU o endereço do bind_address: %s\n", e.endereco);
		}

		// A linha do diário: sem ela, uma escolha automática errada é indistinguível de um
		// aparelho desligado.
		char linha[256];
		formatar_candidatas(ifs, idx, k, sondas, linha, sizeof linha);
		casos++;
		const char *esperada = "en10 169.254.20.226/16 sem resposta; "
				       "en12 169.254.81.198/16 sem resposta; "
				       "en8 169.254.75.173/16 respondeu";
		if (strcmp(linha, esperada) == 0) {
			printf("ok o diário nomeia cada candidata e o que ela respondeu\n  %s\n",
			       linha);
		} else {
			falhas++;
			printf("FALHOU a linha do diário\n  esperado: %s\n  obtido  : %s\n", esperada,
			       linha);
		}
	}

	// --- 6. três cabos e ninguém responde: não se chuta ----------------------------------
	{
		size_t n = bancada(ifs);
		memset(sondas, 0, sizeof sondas);
		sondas[1] = SONDA_SEM_RESPOSTA;
		sondas[2] = SONDA_SEM_RESPOSTA;
		sondas[3] = SONDA_SEM_RESPOSTA;
		e = decidir_interface(ifs, n, ip4(169, 254, 212, 12), sondas);
		confere("três cabos, nenhum responde: não prende e diz que empatou", &e, false, NULL,
			MOTIVO_EMPATE_SEM_RESPOSTA, 3);
	}

	// --- 7. prefixo mais específico vem antes -------------------------------------------
	//
	// Não é caso de bancada: é a regra de ordenação, e ela existe para que uma interface com
	// rota mais específica não fique atrás de uma `/16` genérica só por causa do nome.
	{
		ifs[0] = iface("en8", ip4(169, 254, 75, 173), 16);
		ifs[1] = iface("bridge100", ip4(169, 254, 164, 1), 24);
		size_t idx[8];
		size_t k = candidatas_do_par(ifs, 2, ip4(169, 254, 164, 151), idx, 8);
		casos++;
		if (k == 2 && strcmp(ifs[idx[0]].nome, "bridge100") == 0) {
			printf("ok o prefixo mais específico é sondado primeiro\n"
			       "  bridge100 /24 antes de en8 /16\n");
		} else {
			falhas++;
			printf("FALHOU a ordem por prefixo\n");
		}
	}

	printf("\n%s: %d/%d\n", falhas ? "VERMELHO" : "verde", casos - falhas, casos);
	return falhas ? 1 : 0;
}
