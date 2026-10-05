// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
#include "interface-do-cabo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
// `winsock2.h` **antes** de qualquer outro cabeçalho do Windows: `windows.h` puxa o `winsock.h`
// de 1.1 e as duas definições brigam. Esta é a razão de este arquivo não incluir `quall-obs.h`.
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
typedef SOCKET soquete_t;
#define SOQUETE_INVALIDO INVALID_SOCKET
#define fechar_soquete closesocket
#define erro_do_soquete() WSAGetLastError()
#define ERRO_RECUSADO WSAECONNREFUSED
#define ERRO_RESET WSAECONNRESET
#define ERRO_SEM_ROTA_HOST WSAEHOSTUNREACH
#define ERRO_SEM_ROTA_REDE WSAENETUNREACH
#define ERRO_HOST_CAIDO WSAEHOSTDOWN
#define ERRO_REDE_CAIDA WSAENETDOWN
#define ERRO_INTERROMPIDO WSAEINTR
typedef int comprimento_t;
// `winsock2.h` declara `struct pollfd` com estes mesmos três campos (é o `WSAPOLLFD`), então o
// corpo da sondagem é um só nas duas plataformas — só o nome da função de espera muda.
#else
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int soquete_t;
#define SOQUETE_INVALIDO (-1)
#define fechar_soquete close
#define erro_do_soquete() errno
#define ERRO_RECUSADO ECONNREFUSED
#define ERRO_RESET ECONNRESET
#define ERRO_SEM_ROTA_HOST EHOSTUNREACH
#define ERRO_SEM_ROTA_REDE ENETUNREACH
#define ERRO_HOST_CAIDO EHOSTDOWN
#define ERRO_REDE_CAIDA ENETDOWN
#define ERRO_INTERROMPIDO EINTR
typedef socklen_t comprimento_t;
#endif

// =================================================================================================
// Parte pura
// =================================================================================================

bool par_e_de_cabo(uint32_t par)
{
	return (par >> 16) == 0xA9FEu;
}

bool separar_endereco_do_par(const char *endpoint, uint32_t *ip, uint16_t *porta)
{
	if (!endpoint || !ip || !porta)
		return false;
	unsigned a = 0, b = 0, c = 0, d = 0, p = 0;
	char sobra = 0;
	// O `%c` no fim é o que recusa lixo depois da porta: com ele, `sscanf` devolve 6 e não 5.
	int campos = sscanf(endpoint, "%u.%u.%u.%u:%u%c", &a, &b, &c, &d, &p, &sobra);
	if (campos != 5)
		return false;
	if (a > 255 || b > 255 || c > 255 || d > 255 || p == 0 || p > 65535)
		return false;
	*ip = (a << 24) | (b << 16) | (c << 8) | d;
	*porta = (uint16_t)p;
	return true;
}

void endereco_em_texto(uint32_t ip, char *buf, size_t cap)
{
	if (!buf || cap == 0)
		return;
	snprintf(buf, cap, "%u.%u.%u.%u", (ip >> 24) & 0xFFu, (ip >> 16) & 0xFFu, (ip >> 8) & 0xFFu,
		 ip & 0xFFu);
}

/// Quantos bits a máscara tem. Serve só para ordenar: uma máscara esburacada contaria errado, e
/// máscara esburacada não existe em interface de sistema nenhum desde o CIDR.
static unsigned prefixo(uint32_t mascara)
{
	unsigned n = 0;
	for (int i = 31; i >= 0; i--) {
		if (mascara & (1u << i))
			n++;
		else
			break;
	}
	return n;
}

static bool contem(const struct interface_local *i, uint32_t par)
{
	if (i->mascara == 0)
		return false;
	return (i->ip & i->mascara) == (par & i->mascara);
}

/// Ordem de sondagem: prefixo mais específico primeiro; empatado, por nome; empatado, por
/// endereço. **Total e determinística** — ver o comentário do header.
static bool vem_antes(const struct interface_local *a, const struct interface_local *b)
{
	unsigned pa = prefixo(a->mascara), pb = prefixo(b->mascara);
	if (pa != pb)
		return pa > pb;
	int cmp = strcmp(a->nome, b->nome);
	if (cmp != 0)
		return cmp < 0;
	return a->ip < b->ip;
}

size_t candidatas_do_par(const struct interface_local *ifs, size_t n, uint32_t par, size_t *saida,
			 size_t cap)
{
	if (!ifs || !saida || cap == 0)
		return 0;
	size_t k = 0;
	for (size_t i = 0; i < n && k < cap; i++) {
		if (contem(&ifs[i], par))
			saida[k++] = i;
	}
	// Ordenação por inserção: `k` é no máximo `INTERFACES_MAX`, e um algoritmo esperto aqui
	// custaria leitura sem devolver nada.
	for (size_t i = 1; i < k; i++) {
		size_t v = saida[i];
		size_t j = i;
		while (j > 0 && vem_antes(&ifs[v], &ifs[saida[j - 1]])) {
			saida[j] = saida[j - 1];
			j--;
		}
		saida[j] = v;
	}
	return k;
}

static void copiar_escolha(struct escolha_de_interface *esc, const struct interface_local *i,
			   enum motivo_da_escolha motivo)
{
	esc->prender = true;
	esc->motivo = motivo;
	endereco_em_texto(i->ip, esc->endereco, sizeof esc->endereco);
	snprintf(esc->nome, sizeof esc->nome, "%s", i->nome);
}

struct escolha_de_interface decidir_interface(const struct interface_local *ifs, size_t n,
					      uint32_t par, const enum sonda *sondas)
{
	struct escolha_de_interface esc;
	memset(&esc, 0, sizeof esc);

	if (par == 0) {
		esc.motivo = MOTIVO_PAR_NAO_E_IPV4;
		return esc;
	}

	// ------------------------------------------------------------------------------------
	// **Quem decide é o enlace do par, e não a faixa do endereço.**
	//
	// Esta função nasceu prendendo **só** em `169.254/16`, com o argumento de que fora dali
	// prender só tira opção — *"o ICE já reúne todo endereço privado como candidato `host` e
	// fica com o par que funciona"*. O argumento tem um furo, e ele foi medido em 01/09/2026:
	// **"o par que funciona" não é "o par que a pessoa quis".**
	//
	// A10s ancorado por USB no Dell, sinalização apontada para o endereço do cabo
	// (`192.168.58.57`, que é **privado** e não link-local), e a mídia saiu por
	// `192.168.56.103 <-> 192.168.56.159` — LAN do Dell contra Wi-Fi do telefone. Os dois pares
	// funcionavam; o ICE ficou com o rádio. Resultado: 190 trancos e 1,89 % de perda numa
	// corrida que só precisava de `--ligar-em` para dar zero e zero.
	//
	// Fora do link-local, prender **não habilita** o caminho: ele **seleciona**. E selecionar é
	// exatamente o que a pessoa pediu ao digitar aquele endereço.
	//
	// Em `169.254/16` continua valendo o outro motivo, mais forte: a libjuice **nunca junta**
	// link-local (`addr.c:84`, `udp.c:462`), então sem prender não há candidato nenhum e a
	// sessão não sobe.
	//
	// **A regra que ficou: prende quando há UMA interface no enlace do par.** Uma só significa
	// que existe um caminho direto e sem ambiguidade para aquele endereço — é o cabo do iOS, é
	// a ancoragem do Android, e é também a LAN de uma máquina com uma placa só, onde prender
	// não muda nada porque não havia outra opção mesmo.
	//
	// **O que isso custa, dito em voz alta:** numa máquina de uma placa só, os candidatos IPv6
	// deixam de ser oferecidos junto com o IPv4. O caminho de sinalização deste projeto já é
	// IPv4 (`signaling.rs` faz `TcpListener::bind(("0.0.0.0", porta))`), então na prática não há
	// sessão que dependa deles hoje — mas é perda de opção, e fica registrada em vez de
	// escondida.
	//
	// **Com empate — duas placas no mesmo enlace — não se prende no escuro:** a sondagem
	// desempata, e se ninguém responder a resposta é não prender. É o caso do Dell, com LAN e
	// Wi-Fi na mesma sub-rede.
	// ------------------------------------------------------------------------------------
	size_t idx[INTERFACES_MAX];
	size_t k = candidatas_do_par(ifs, n, par, idx, INTERFACES_MAX);
	esc.candidatas = k;

	if (k == 0) {
		// Nenhuma interface no enlace do par quer dizer que ele é **roteado** — se chega, chega
		// pelo gateway, e aí prender numa placa não descreve caminho nenhum.
		esc.motivo = MOTIVO_NENHUMA_INTERFACE_NO_ENLACE;
		return esc;
	}

	if (k == 1) {
		// **Uma só candidata: a sondagem informa, não decide.** Não há empate para desfazer,
		// e exigir resposta positiva aqui mataria o recurso inteiro no dia em que o aparelho
		// (ou um firewall no meio) engolisse o ICMP — trocaria "talvez não responda" por
		// "nunca prende". Só o "não" explícito do sistema veta.
		if (sondas && sondas[idx[0]] == SONDA_NAO_ALCANCOU) {
			esc.motivo = MOTIVO_UNICA_RECUSADA_PELA_SONDA;
			return esc;
		}
		copiar_escolha(&esc, &ifs[idx[0]], MOTIVO_UNICA_CANDIDATA);
		return esc;
	}

	// **Com empate, só a resposta decide.** É aqui que mora o achado desta bancada: três rotas
	// `169.254/16` `UCSI` e só a rota de host do ARP desempata.
	for (size_t i = 0; i < k; i++) {
		if (sondas && sondas[idx[i]] == SONDA_ALCANCOU) {
			copiar_escolha(&esc, &ifs[idx[i]], MOTIVO_SONDA_RESPONDEU);
			return esc;
		}
	}

	// **Ninguém respondeu, e não se chuta.**
	//
	// Com três candidatas iguais, prender na primeira acerta uma vez em três — e as duas
	// falhas seriam mudas, porque uma sessão que não sobe por interface errada é
	// indistinguível de uma que não sobe por aparelho desligado. Não prender devolve o
	// comportamento de antes (que também não funciona no cabo, e nisso nada se perde) e deixa
	// no diário a linha que nomeia o empate — que é o que um humano precisa para agir.
	esc.motivo = MOTIVO_EMPATE_SEM_RESPOSTA;
	return esc;
}

static const char *sonda_em_palavras(enum sonda s)
{
	switch (s) {
	case SONDA_ALCANCOU:
		return "respondeu";
	case SONDA_NAO_ALCANCOU:
		return "sem rota";
	case SONDA_SEM_RESPOSTA:
		return "sem resposta";
	case SONDA_NAO_FEITA:
	default:
		return "não sondada";
	}
}

void formatar_candidatas(const struct interface_local *ifs, const size_t *idx, size_t k,
			 const enum sonda *sondas, char *buf, size_t cap)
{
	if (!buf || cap == 0)
		return;
	buf[0] = '\0';
	size_t escrito = 0;
	for (size_t i = 0; i < k; i++) {
		char end[INTERFACE_ENDERECO_MAX];
		endereco_em_texto(ifs[idx[i]].ip, end, sizeof end);
		int n = snprintf(buf + escrito, cap - escrito, "%s%s %s/%u %s", i ? "; " : "",
				 ifs[idx[i]].nome, end, prefixo(ifs[idx[i]].mascara),
				 sonda_em_palavras(sondas ? sondas[idx[i]] : SONDA_NAO_FEITA));
		if (n < 0 || (size_t)n >= cap - escrito)
			return; // truncou: melhor uma linha curta que uma linha mentirosa
		escrito += (size_t)n;
	}
}

const char *motivo_em_palavras(enum motivo_da_escolha m)
{
	switch (m) {
	case MOTIVO_PAR_NAO_E_IPV4:
		return "o endereço do par não é IPv4 literal";
	case MOTIVO_PAR_NAO_E_DE_CABO:
		return "o par não é link-local; o ICE junta este endereço sozinho";
	case MOTIVO_NENHUMA_INTERFACE_NO_ENLACE:
		return "nenhuma interface desta máquina está no enlace do par";
	case MOTIVO_UNICA_RECUSADA_PELA_SONDA:
		return "a única interface do enlace respondeu que não há rota";
	case MOTIVO_EMPATE_SEM_RESPOSTA:
		return "mais de uma interface no enlace e nenhuma respondeu";
	case MOTIVO_UNICA_CANDIDATA:
		return "única interface no enlace do par";
	case MOTIVO_SONDA_RESPONDEU:
		return "foi a que respondeu à sondagem";
	default:
		return "?";
	}
}

// =================================================================================================
// Parte impura: a plataforma
// =================================================================================================

size_t interfaces_locais(struct interface_local *saida, size_t cap)
{
	if (!saida || cap == 0)
		return 0;
	size_t n = 0;

#ifdef _WIN32
	// `GetAdaptersAddresses` e não `SIO_GET_INTERFACE_LIST`: só ela traz o nome amigável, e um
	// diário que diz "prendi em 169.254.75.173" sem dizer em qual adaptador não serve a ninguém.
	ULONG tam = 16384;
	IP_ADAPTER_ADDRESSES *lista = NULL;
	ULONG r = ERROR_BUFFER_OVERFLOW;
	for (int tentativa = 0; tentativa < 3 && r == ERROR_BUFFER_OVERFLOW; tentativa++) {
		void *novo = realloc(lista, tam);
		if (!novo)
			break;
		lista = novo;
		r = GetAdaptersAddresses(AF_INET,
					 GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
						 GAA_FLAG_SKIP_DNS_SERVER,
					 NULL, lista, &tam);
	}
	if (r == NO_ERROR && lista) {
		for (IP_ADAPTER_ADDRESSES *a = lista; a && n < cap; a = a->Next) {
			if (a->OperStatus != IfOperStatusUp)
				continue;
			if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK)
				continue;
			for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u && n < cap;
			     u = u->Next) {
				if (!u->Address.lpSockaddr ||
				    u->Address.lpSockaddr->sa_family != AF_INET)
					continue;
				const SOCKADDR_IN *sa = (const SOCKADDR_IN *)u->Address.lpSockaddr;
				unsigned bits = u->OnLinkPrefixLength;
				if (bits > 32)
					bits = 32;
				memset(&saida[n], 0, sizeof saida[n]);
				saida[n].ip = ntohl(sa->sin_addr.s_addr);
				saida[n].mascara =
					bits == 0 ? 0u : (0xFFFFFFFFu << (32 - bits));
				WideCharToMultiByte(CP_UTF8, 0, a->FriendlyName, -1, saida[n].nome,
						    (int)sizeof saida[n].nome, NULL, NULL);
				if (saida[n].nome[0] == '\0')
					snprintf(saida[n].nome, sizeof saida[n].nome, "if%lu",
						 (unsigned long)a->IfIndex);
				n++;
			}
		}
	}
	free(lista);
#else
	struct ifaddrs *lista = NULL;
	if (getifaddrs(&lista) != 0)
		return 0;
	for (struct ifaddrs *a = lista; a && n < cap; a = a->ifa_next) {
		if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET)
			continue;
		// `IFF_RUNNING` além de `IFF_UP`: um cabo desplugado deixa a interface `UP` com o
		// endereço ainda configurado, e ela entraria na lista como candidata viva.
		if ((a->ifa_flags & IFF_UP) == 0 || (a->ifa_flags & IFF_RUNNING) == 0)
			continue;
		if (a->ifa_flags & IFF_LOOPBACK)
			continue;
		const struct sockaddr_in *sa = (const struct sockaddr_in *)(void *)a->ifa_addr;
		memset(&saida[n], 0, sizeof saida[n]);
		saida[n].ip = ntohl(sa->sin_addr.s_addr);
		if (a->ifa_netmask) {
			const struct sockaddr_in *m =
				(const struct sockaddr_in *)(void *)a->ifa_netmask;
			saida[n].mascara = ntohl(m->sin_addr.s_addr);
		}
		snprintf(saida[n].nome, sizeof saida[n].nome, "%s", a->ifa_name ? a->ifa_name : "?");
		n++;
	}
	freeifaddrs(lista);
#endif
	return n;
}

/// Classifica um `errno`/`WSAGetLastError` de socket. `0` é "ainda não sei".
static enum sonda classificar(int e)
{
	if (e == 0)
		return SONDA_NAO_FEITA;
	// **"Recusado" é o resultado bom.** O par mandou um ICMP *port unreachable* de volta: para
	// isso ele precisou receber o pacote, e para receber o pacote o enlace precisou resolver o
	// endereço físico. É a prova positiva, e vem em um RTT.
	if (e == ERRO_RECUSADO || e == ERRO_RESET)
		return SONDA_ALCANCOU;
	if (e == ERRO_SEM_ROTA_HOST || e == ERRO_SEM_ROTA_REDE || e == ERRO_HOST_CAIDO ||
	    e == ERRO_REDE_CAIDA)
		return SONDA_NAO_ALCANCOU;
	return SONDA_SEM_RESPOSTA;
}

// -------------------------------------------------------------------------------------------------
// A sondagem, e as duas escolhas dela que não são óbvias
//
// **1. UDP, e não TCP na porta de sinalização.** A tentação é abrir o TCP que a sessão vai abrir
// de qualquer jeito. Não dá: `signaling.rs` (`aceitar_ate`) propaga `HandshakeError::Failure` com
// `?`, então uma conexão que **abre e fecha** sem falar faz o `accept` do emissor devolver erro e
// derruba a espera dele. O núcleo tolera a conexão muda que **fica aberta** — é o que os testes
// `conexao_que_abre_e_nao_fala_nao_pendura_o_accept` e
// `receptor_de_verdade_entra_apesar_de_uma_conexao_muda_na_frente` fixam — e ninguém testou a que
// fecha. Sondar não pode custar a sessão que se está preparando.
//
// A porta de sinalização em **UDP** não tem ninguém escutando (a sinalização é TCP; a mídia usa
// porta efêmera), então o que responde é o **núcleo do sistema do par**, com um ICMP. Nenhum
// processo do outro lado vê coisa alguma.
//
// **2. `bind` e nada mais, de propósito.** Existe `IP_BOUND_IF` no Darwin e `IP_UNICAST_IF` no
// Windows, e os dois forçam a saída pela interface passando por cima da tabela de rotas. Não são
// usados aqui: o socket da mídia da libjuice faz **só `bind`**
// (`RtcConfig::bind_address` -> `udp.c:154`), e uma sondagem mais forte que o alvo dá falso
// positivo — diria "alcança" de uma interface por onde a mídia depois não sairia. A sondagem tem
// de ser um ensaio do que vai acontecer, não uma versão melhorada dele.
// -------------------------------------------------------------------------------------------------
/// `poll` de um descritor só, com o nome que cada plataforma lhe deu.
static int esperar(struct pollfd *p, int ms)
{
#ifdef _WIN32
	return WSAPoll(p, 1, ms);
#else
	return poll(p, 1, ms);
#endif
}

enum sonda sondar_interface(uint32_t local, uint32_t par, uint16_t porta, uint32_t prazo_ms)
{
#ifdef _WIN32
	WSADATA wsa;
	bool iniciou = (WSAStartup(MAKEWORD(2, 2), &wsa) == 0);
#endif
	enum sonda saida = SONDA_SEM_RESPOSTA;

	soquete_t s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s == SOQUETE_INVALIDO)
		goto fim;

	struct sockaddr_in eu;
	memset(&eu, 0, sizeof eu);
	eu.sin_family = AF_INET;
	eu.sin_addr.s_addr = htonl(local);
	eu.sin_port = 0;
	if (bind(s, (struct sockaddr *)&eu, (comprimento_t)sizeof eu) != 0) {
		// O endereço não é (mais) desta máquina: a interface caiu ou o APIPA mudou entre a
		// enumeração e agora. Isso é um "não" honesto, e não um "não sei".
		saida = SONDA_NAO_ALCANCOU;
		goto fecha;
	}

	struct sockaddr_in ele;
	memset(&ele, 0, sizeof ele);
	ele.sin_family = AF_INET;
	ele.sin_addr.s_addr = htonl(par);
	ele.sin_port = htons(porta);
	if (connect(s, (struct sockaddr *)&ele, (comprimento_t)sizeof ele) != 0) {
		saida = classificar(erro_do_soquete());
		goto fecha;
	}

	const char um_byte = 0;
	if (send(s, &um_byte, 1, 0) < 0) {
		enum sonda imediata = classificar(erro_do_soquete());
		if (imediata != SONDA_NAO_FEITA) {
			saida = imediata;
			goto fecha;
		}
	}

	// Passos curtos, e em cada passo as **duas** portas por onde o erro de ICMP aparece: o
	// socket ficar legível, e o `SO_ERROR` pendurado. Depender de uma só já custou diagnóstico
	// neste projeto.
	//
	// `poll` e não `select`: este código roda **dentro do OBS**, que abre descritor por fonte,
	// por captura e por saída. `select` é indefinido com descritor >= `FD_SETSIZE` e o defeito
	// sairia como corrupção de pilha numa cena grande — sintoma a três passos da causa.
	for (uint32_t passado = 0; passado < prazo_ms; passado += 20) {
		struct pollfd espera;
		memset(&espera, 0, sizeof espera);
		espera.fd = s;
		espera.events = POLLIN;
		int pronto = esperar(&espera, 20);
		if (pronto > 0) {
			char lixo[64];
			int lido = (int)recv(s, lixo, (comprimento_t)sizeof lixo, 0);
			if (lido >= 0) {
				saida = SONDA_ALCANCOU; // alguém respondeu de verdade
				goto fecha;
			}
			enum sonda c = classificar(erro_do_soquete());
			if (c != SONDA_NAO_FEITA) {
				saida = c;
				goto fecha;
			}
		} else if (pronto < 0 && erro_do_soquete() != ERRO_INTERROMPIDO) {
			break;
		}

		int pendurado = 0;
		comprimento_t tamanho = (comprimento_t)sizeof pendurado;
		if (getsockopt(s, SOL_SOCKET, SO_ERROR, (void *)&pendurado, &tamanho) == 0 &&
		    pendurado != 0) {
			enum sonda c = classificar(pendurado);
			if (c != SONDA_NAO_FEITA) {
				saida = c;
				goto fecha;
			}
		}
	}

fecha:
	fechar_soquete(s);
fim:
#ifdef _WIN32
	if (iniciou)
		WSACleanup();
#endif
	return saida;
}

struct escolha_de_interface escolher_interface_do_par(const char *endpoint, char *relato,
						      size_t relato_cap)
{
	struct escolha_de_interface esc;
	memset(&esc, 0, sizeof esc);
	if (relato && relato_cap)
		relato[0] = '\0';

	uint32_t par = 0;
	uint16_t porta = 0;
	if (!separar_endereco_do_par(endpoint, &par, &porta)) {
		esc.motivo = MOTIVO_PAR_NAO_E_IPV4;
		return esc;
	}
	// **Aqui não há atalho por faixa de endereço, e é de propósito.** A versão anterior saía
	// cedo fora de `169.254/16` para não pagar enumeração nem sondagem — e com isso não prendia
	// numa ancoragem de Android, que dá endereço privado. A enumeração de interfaces é barata
	// (uma chamada ao sistema) e a sondagem só acontece quando há **empate**; o caso comum de
	// LAN sai pelo `k == 0` ou pelo `k == 1` sem pôr um pacote no fio.
	struct interface_local ifs[INTERFACES_MAX];
	size_t n = interfaces_locais(ifs, INTERFACES_MAX);

	enum sonda sondas[INTERFACES_MAX];
	memset(sondas, 0, sizeof sondas);

	size_t idx[INTERFACES_MAX];
	size_t k = candidatas_do_par(ifs, n, par, idx, INTERFACES_MAX);

	// Sonda na ordem determinística e **para na primeira que responde**. Gastar o prazo das
	// outras só serviria para descobrir que uma segunda também alcança — e nesse caso qualquer
	// uma das duas serve, porque as duas alcançam o par.
	for (size_t i = 0; i < k; i++) {
		sondas[idx[i]] = sondar_interface(ifs[idx[i]].ip, par, porta, SONDA_PRAZO_MS);
		if (sondas[idx[i]] == SONDA_ALCANCOU)
			break;
	}

	if (relato)
		formatar_candidatas(ifs, idx, k, sondas, relato, relato_cap);
	return decidir_interface(ifs, n, par, sondas);
}
