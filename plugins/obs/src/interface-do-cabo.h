// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
// -------------------------------------------------------------------------------------------------
// **Por qual interface deste computador o par é alcançado, e o endereço local a prender.**
//
// O que este módulo resolve, em uma frase: o `QuallSessionOptions::bind_address` precisa de um
// endereço IPv4 **local**, e ninguém vai digitar `169.254.x` seis vezes num estúdio de seis
// celulares num hub USB.
//
// # A armadilha, medida nesta bancada
//
// A tabela de rotas **sozinha não desempata**. Com três aparelhos iOS no cabo, o Mac tem três
// rotas `169.254/16` concorrentes — `en8`, `en10`, `en12`, todas `UCSI` — e só a **rota de host
// que o ARP cria** diz qual interface de fato alcança aquele aparelho. Os roteiros de bancada
// resolvem com um `ping` antes de conectar (`tools/emissor_android.py:aquecer_arp`), e está
// escrito lá que *"o produto não tem equivalente"*. Este módulo é o equivalente: ele **sonda
// antes de decidir**, e a sondagem serve a duas coisas de uma vez —
//
//  1. **desempatar**: só quem responde é escolhido;
//  2. **abrir a rota**: pôr um pacote no fio em direção ao par é o que faz o ARP resolver e a
//     rota de host nascer. Sem isso, o `bind_address` se prende a um endereço cuja rota ainda
//     não existe — e, pior, a **sinalização** sai pela interface errada antes disso, porque
//     `signaling::connect` não tem por onde ser presa. Por isso a sondagem vem **antes** de
//     conectar, e não depois.
//
// # A divisão do arquivo, e por que ela existe
//
// A parte **pura** (`candidatas_do_par`, `decidir_interface`, `formatar_candidatas`) recebe a
// tabela de interfaces e o par e devolve a escolha: nada de socket, nada de sistema, e por isso
// ela tem banco de prova (`plugins/obs/bancada/prova-interface-do-cabo.c`) do mesmo jeito que
// `janela-do-enlace.c` tem — 12 casos, com a tabela de interfaces medida em 01/09 como entrada.
//
// A parte **impura** (`interfaces_locais`, `sondar_interface`) toca a plataforma. Ela vai até onde
// dá sem aparelho, e nem um passo além: `prova-interface-do-cabo --sonda-em-loopback` enumera as
// interfaces de verdade e sonda `127.0.0.1:9`, o que prova que o ICMP de porta fechada volta como
// `ECONNREFUSED`. **Não prova o cabo** — que um iOS do outro lado de um USB-Ethernet responda do
// mesmo jeito é dedução, e o `bind` ter de fato escolhido a interface é outra. As duas estão na
// lista de "não provado" de `docs/quall-pelo-cabo.md`, não escondidas.
//
// O módulo não inclui nada do `libobs` de propósito: quem escreve no diário é `receptor.c`.
// -------------------------------------------------------------------------------------------------
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define INTERFACE_NOME_MAX 64
#define INTERFACE_ENDERECO_MAX 46
/// Teto de interfaces IPv4 consideradas. Um hub de seis celulares dá seis, mais Wi-Fi, mais o que
/// o usuário tiver: 32 é folga de cinco vezes, e o custo é 32 structs na pilha.
#define INTERFACES_MAX 32

/// Quanto tempo esperar a resposta de **cada** candidata. No cabo o RTT medido nesta bancada é de
/// 0,875 a 1,288 ms; 300 ms é 200 vezes isso. O custo do pior caso — nenhuma responde — é
/// `300 ms × candidatas`, e ele acontece uma vez por tentativa de sessão, não no caminho quente.
#define SONDA_PRAZO_MS 300u

/// Uma interface IPv4 desta máquina, como a plataforma a enumera. Endereços em **ordem do host**.
struct interface_local {
	char nome[INTERFACE_NOME_MAX];
	uint32_t ip;
	uint32_t mascara;
};

/// O que a sondagem descobriu sobre uma candidata.
enum sonda {
	/// Não foi sondada. É o valor 0 para que um `memset` produza o estado honesto.
	SONDA_NAO_FEITA = 0,
	/// **O par respondeu por esta interface.** É prova positiva: o enlace resolveu o endereço
	/// físico e o outro lado está vivo ali.
	SONDA_ALCANCOU,
	/// O sistema disse que não há como chegar (`EHOSTUNREACH`, `ENETUNREACH`). É a única
	/// resposta que **veta** uma candidata.
	SONDA_NAO_ALCANCOU,
	/// Nada voltou dentro do prazo. **Não é "não"** — é "não sei", e a diferença decide.
	SONDA_SEM_RESPOSTA,
};

/// Por que a escolha foi essa. Vai para o diário: uma escolha automática que não se explica é a
/// classe de instrumento que `docs/regras-de-frente.md` proíbe.
enum motivo_da_escolha {
	/// O endereço do par não é um literal IPv4 `a.b.c.d:porta`.
	MOTIVO_PAR_NAO_E_IPV4 = 0,
	/// **Não usado desde 01/09/2026.** Era "o par não é link-local", quando a regra prendia só
	/// em `169.254/16`. A regra passou a ser o **enlace** e não a faixa — ver
	/// [`decidir_interface`] —, e um par roteado agora cai em
	/// [`MOTIVO_NENHUMA_INTERFACE_NO_ENLACE`], que descreve o mesmo fato com o nome certo. O
	/// valor fica no lugar para não renumerar o que já foi para o diário.
	MOTIVO_PAR_NAO_E_DE_CABO,
	/// Nenhuma interface desta máquina tem endereço no enlace do par.
	MOTIVO_NENHUMA_INTERFACE_NO_ENLACE,
	/// Havia uma só candidata e a sondagem disse, com todas as letras, que não se chega.
	MOTIVO_UNICA_RECUSADA_PELA_SONDA,
	/// Mais de uma candidata e **nenhuma** respondeu. Não se chuta.
	MOTIVO_EMPATE_SEM_RESPOSTA,
	/// Uma só candidata no enlace: não há empate para a sondagem desfazer.
	MOTIVO_UNICA_CANDIDATA,
	/// Havia empate, e esta é a que respondeu.
	MOTIVO_SONDA_RESPONDEU,
};

struct escolha_de_interface {
	/// Passar `endereco` em `QuallSessionOptions::bind_address`? Quando `false`, a casca passa
	/// `NULL` e a sessão sobe **exatamente como subia antes**.
	bool prender;
	char endereco[INTERFACE_ENDERECO_MAX];
	char nome[INTERFACE_NOME_MAX];
	enum motivo_da_escolha motivo;
	/// Quantas interfaces tinham endereço no enlace do par. Vai para o diário mesmo quando a
	/// escolha é não prender: é o número que explica um empate.
	size_t candidatas;
};

// --- parte pura ----------------------------------------------------------------------------------

/// `169.254.0.0/16` — a faixa que a libjuice recusa (`libjuice/src/addr.c:84`) e a única em que
/// prender muda a resposta.
bool par_e_de_cabo(uint32_t par);

/// `"169.254.20.3:7877"` -> ip e porta. Falso em qualquer coisa que não seja literal IPv4.
bool separar_endereco_do_par(const char *endpoint, uint32_t *ip, uint16_t *porta);

/// Escreve `a.b.c.d` em `buf`.
void endereco_em_texto(uint32_t ip, char *buf, size_t cap);

/// Índices das interfaces cuja sub-rede contém `par`, na ordem em que devem ser sondadas:
/// **prefixo mais específico primeiro**, depois por nome. A ordem é fixa de propósito — uma
/// escolha automática que muda de resposta entre duas execuções não é diagnosticável.
size_t candidatas_do_par(const struct interface_local *ifs, size_t n, uint32_t par, size_t *saida,
			 size_t cap);

/// **A decisão inteira, sem tocar em socket nenhum.** `sondas` é paralelo a `ifs` e pode ser
/// `NULL` (equivale a tudo `SONDA_NAO_FEITA`).
struct escolha_de_interface decidir_interface(const struct interface_local *ifs, size_t n,
					      uint32_t par, const enum sonda *sondas);

/// Uma linha para o diário com cada candidata e o que ela respondeu.
void formatar_candidatas(const struct interface_local *ifs, const size_t *idx, size_t k,
			 const enum sonda *sondas, char *buf, size_t cap);

const char *motivo_em_palavras(enum motivo_da_escolha m);

// --- parte impura --------------------------------------------------------------------------------

/// As interfaces IPv4 no ar desta máquina, sem loopback. Devolve quantas couberam.
size_t interfaces_locais(struct interface_local *saida, size_t cap);

/// Põe um pacote no fio em direção ao par, **a partir de `local`**, e olha o que volta.
enum sonda sondar_interface(uint32_t local, uint32_t par, uint16_t porta, uint32_t prazo_ms);

/// Enumera, sonda e decide. `relato` (pode ser `NULL`) recebe a linha das candidatas.
struct escolha_de_interface escolher_interface_do_par(const char *endpoint, char *relato,
						      size_t relato_cap);
