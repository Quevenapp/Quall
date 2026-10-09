/*
 * Fachada JNI sobre a superfície C do núcleo (`crates/quall-ffi/include/quall.h`).
 *
 * É a única peça em C deste app, e ela existe para fazer **o mínimo**: traduzir tipos de JNI
 * para os tipos do header e devolver o que veio. Nenhuma decisão de produto mora aqui — nem
 * política de reconexão, nem estado de sessão, nem fila. Quem decide é o Kotlin.
 *
 * ## Por que não há callback do Rust para o Java
 *
 * O header documenta (`quall_track_take_idr_request`) que o tratador de
 * `quall_track_on_idr_request` roda numa thread da libdatachannel, que **não está anexada à
 * JVM** — chamar de volta de lá exigiria `AttachCurrentThread`, referência global e desanexar na
 * saída. Nada disso existe neste arquivo: o emissor Android lê a bandeira atômica uma vez por
 * quadro, no laço que ele já tem (o do `MediaCodec`). Confira: não há `JNIEnv` capturado, nem
 * `NewGlobalRef`, nem função registrada como callback do núcleo.
 *
 * ## O receptor precisa de um callback — e ele para **em C**, não na JVM
 *
 * Receber não tem equivalente de bandeira atômica: `quall_track_on_frame` é a única forma de o
 * quadro remontado chegar à casca, e o `annexb` dele vale só durante a chamada. A saída que
 * mantém a regra acima é a **caixa de quadros** ([CaixaDeQuadros]): o tratador registrado é uma
 * função C que copia os bytes para um anel e sinaliza uma condvar. **Nenhum `JNIEnv` é tocado
 * dentro dele**, então nenhuma thread da libdatachannel precisa ser anexada à JVM. Quem cruza a
 * fronteira para o Java é a thread do receptor, que já é uma thread Java, chamando
 * `frameBoxTake` — e ela copia direto para o `ByteBuffer` de entrada do `MediaCodec`.
 *
 * O preço é uma cópia a mais por quadro (núcleo → anel → buffer do decodificador) e um anel
 * pequeno que **descarta o mais velho** quando enche. Descartar é o comportamento certo para
 * vídeo ao vivo, e é o mesmo princípio de "empacota e solta" do lado do emissor: o que não cabe
 * não vira fila.
 *
 * ## Toda string atravessa como `byte[]`, não como `String`
 *
 * `GetStringUTFChars` devolve **UTF-8 modificado** (CESU-8): caracteres fora do BMP viram um par
 * de sequências de 3 bytes, e o Rust rejeita isso com `QUALL_STATUS_NOT_UTF8`. `NewStringUTF`
 * tem o problema espelhado na volta. Um nome de aparelho com emoji é suficiente para cair nisso.
 * Por isso o Kotlin converte com `Charsets.UTF_8` dos dois lados e aqui só trafega `byte[]`.
 *
 * ## `quall_cleanup` não é exposto de propósito
 *
 * Ele tranca a libdatachannel inteira e exige que nenhuma sessão esteja viva. No desktop o
 * castigo por errar é um processo que não morre; no Android não existe "saída do processo" — o
 * Service para e o processo segue vivo, então não há instante seguro para chamar. E
 * `System.loadLibrary` não descarrega a `.so`: não há o que limpar. A função existe no header e
 * **não** tem `external fun` correspondente.
 */

#include <jni.h>

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>

#include "quall.h"

#define TAG "QuallJni"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/* Buffer de pilha para o padrão `(buf, cap)`. Cabe folgado a lista de aparelhos e os contadores
 * de track; acima disso o código cai no `malloc`. */
#define PILHA 4096

/*
 * **O padrão `(buf, cap)` da fronteira, numa forma só — e ela nunca trata "não coube" como
 * sucesso.**
 *
 * O contrato do topo de `quall.h`: a função devolve quantos bytes são necessários *incluindo o
 * NUL*, e **só escreve se couber**; negativo é erro. Buffer pequeno demais não é negativo — é um
 * positivo maior que a capacidade, com o buffer intocado. Quem lê `n > 0` como "deu certo"
 * devolve o buffer zerado, ou seja **string vazia**, sem erro em lugar nenhum.
 *
 * Esse é o defeito que parou de gravar o pareamento do app do macOS em 26/08, quando o
 * `pares.json` passou de 256 bytes: o usuário voltou a digitar o PIN toda vez e ninguém ligou uma
 * coisa à outra por quatro dias. Aqui metade das funções já crescia no heap e metade devolvia um
 * valor de falta em silêncio — a macro tira a escolha do sítio de chamada.
 *
 * Tenta na pilha primeiro (uma chamada em vez de duas no caso comum) e cresce no heap quando não
 * couber. `CHAMAR` é um nome de função-macro que recebe `(buf, cap)`.
 *
 * ## Repete até caber (F6b, 13/09/2026)
 *
 * A primeira versão desta macro chamava **duas** vezes e aceitava qualquer `n > 0` na segunda. O
 * contrato do teleprompter (`docs/contrato-teleprompter.md` §6) mediu o que isso esconde: o
 * conteúdo **cresce entre as duas chamadas** — o estado passou de 357 para 360 bytes porque
 * `par_visto_ha_ms` ganhou um dígito, e o roteiro muda quando chega uma edição do outro lado. Aí a
 * segunda chamada devolve um `n` maior que o buffer **sem escrever nada**, e a versão antiga fazia
 * `strlen` sobre um `malloc` não escrito: string de lixo, ou leitura além do buffer.
 *
 * Agora: enquanto o devolvido for maior que o buffer, cresce (com folga de 1/8, para não perseguir
 * um estado que ganha um dígito por vez) e chama de novo — até [TENTATIVAS_ATE_CABER] vezes, e
 * então desiste **dizendo** que desistiu. O comprimento sai do que a função devolveu (`strnlen`
 * limitado a `n`), nunca de um `strlen` solto.
 */
#define TENTATIVAS_ATE_CABER 8

#define POR_BUF_CAP(env_, saida_, falta_, CHAMAR)                                             \
    do {                                                                                      \
        char pilha_[PILHA];                                                                   \
        char *buf_ = pilha_;                                                                  \
        size_t cap_ = sizeof pilha_;                                                          \
        char *heap_ = NULL;                                                                   \
        int tentativas_ = 0;                                                                  \
        for (;;) {                                                                            \
            intptr_t n_ = CHAMAR(buf_, (uintptr_t)cap_);                                      \
            if (n_ <= 0) {                                                                    \
                (saida_) = falta_ou_nulo((env_), (falta_));                                      \
                break;                                                                        \
            }                                                                                 \
            if ((size_t)n_ <= cap_) {                                                         \
                (saida_) = para_bytes_n((env_), buf_, strnlen(buf_, (size_t)n_));             \
                break;                                                                        \
            }                                                                                 \
            if (++tentativas_ > TENTATIVAS_ATE_CABER) {                                       \
                LOGE("%s: o conteúdo cresceu %d vezes seguidas (%ld bytes); desisto",         \
                     __func__, TENTATIVAS_ATE_CABER, (long)n_);                               \
                (saida_) = falta_ou_nulo((env_), (falta_));                                      \
                break;                                                                        \
            }                                                                                 \
            size_t novo_ = (size_t)n_ + (size_t)n_ / 8 + 64;                                  \
            char *maior_ = (char *)realloc(heap_, novo_);                                     \
            if (maior_ == NULL) {                                                             \
                LOGE("%s: %ld bytes não couberam e o heap não deu conta", __func__, (long)n_); \
                (saida_) = falta_ou_nulo((env_), (falta_));                                      \
                break;                                                                        \
            }                                                                                 \
            heap_ = maior_;                                                                   \
            buf_ = heap_;                                                                     \
            cap_ = novo_;                                                                     \
        }                                                                                     \
        free(heap_);                                                                          \
    } while (0)

/* ============================================================================================
 * Pânico do Rust: sem isto, ele chega como SIGABRT mudo
 * ============================================================================================
 *
 * O workspace compila release com `panic = "abort"` e `strip = "debuginfo"`. O hook padrão do
 * Rust **roda antes do abort** e escreve a mensagem em `stderr` — mas no Android `stderr` de um
 * app vai para /dev/null, então o que sobra no `logcat` é um `SIGABRT` sem uma linha de texto.
 *
 * O conserto que não exige tocar em `crates/`: um `pipe()` no lugar do descritor 2 e uma thread
 * que registra a ocorrência/tamanho de cada trecho no `logcat`. Conteúdo stderr arbitrário pode
 * carregar PIN, nomes, IPs ou segredos: nunca copiá-lo para o diário. Falhas continuam ERROR,
 * com contagem e tamanho, mesmo para linha longa ou final sem quebra.
 *
 * O hook de pânico/logger da FFI usa a logcat diretamente e tem sua própria proteção. Este
 * bridge não é o caminho para publicar payloads de pânico ou mensagens livres de fornecedores.
 */
static void registrar_stderr_omitido(unsigned long *trechos, size_t bytes, int fim_linha) {
    ++*trechos;
    __android_log_print(ANDROID_LOG_ERROR, "QuallNucleo",
                        "stderr omitido; trecho=%lu bytes=%zu fim_linha=%d",
                        *trechos, bytes, fim_linha);
}

static void *bombear_stderr(void *arg) {
    int leitura = (int)(intptr_t)arg;
    char linha[512];
    size_t usado = 0;
    unsigned long trechos = 0;
    for (;;) {
        ssize_t n = read(leitura, linha + usado, sizeof linha - usado - 1);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            break;
        }
        usado += (size_t)n;
        char *inicio = linha;
        char *quebra;
        while ((quebra = memchr(inicio, '\n', (size_t)((linha + usado) - inicio))) != NULL) {
            registrar_stderr_omitido(&trechos, (size_t)(quebra - inicio), 1);
            inicio = quebra + 1;
        }
        usado = (size_t)((linha + usado) - inicio);
        memmove(linha, inicio, usado);
        if (usado == sizeof linha - 1) {
            /* Linha maior que o buffer: registra metadados e segue drenando, sem payload. */
            registrar_stderr_omitido(&trechos, usado, 0);
            usado = 0;
        }
    }
    if (usado != 0) registrar_stderr_omitido(&trechos, usado, 0);
    return NULL;
}

static void ligar_stderr_no_logcat(void) {
    int canos[2];
    if (pipe(canos) != 0) {
        LOGE("pipe() falhou (%d); pânico do Rust vai sair mudo", errno);
        return;
    }
    if (dup2(canos[1], STDERR_FILENO) < 0) {
        LOGE("dup2() falhou (%d); pânico do Rust vai sair mudo", errno);
        close(canos[0]);
        close(canos[1]);
        return;
    }
    close(canos[1]);
    pthread_t t;
    if (pthread_create(&t, NULL, bombear_stderr, (void *)(intptr_t)canos[0]) != 0) {
        LOGE("pthread_create() falhou; pânico do Rust vai sair mudo");
        close(canos[0]);
        return;
    }
    pthread_detach(t);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    ligar_stderr_no_logcat();
    /* `quall_install_panic_hook` é o pedido da dívida 11, atendido pelo núcleo nesta rodada:
     * `cb`/`user_data` nulos instalam só o caminho padrão, que no Android grava no logcat com a
     * etiqueta `quall` via `__android_log_write` — sem precisar de código nenhum daqui. Não
     * substitui o cano de stderr acima: aquele pega qualquer coisa que a libdatachannel ou o
     * OpenSSL gritem em stderr (não só pânico do Rust); este pega o pânico mesmo quando o
     * `std::panic::set_hook` do Rust já tomou conta de stderr para outra coisa. `adb logcat -s
     * quall` mostra o diagnóstico protegido do pânico; `adb logcat -s QuallNucleo` mostra só
     * ocorrência/tamanho dos trechos de stderr, nunca seu conteúdo. */
    quall_install_panic_hook(NULL, NULL);
    LOGI("quall JNI carregado; protocolo v%u", (unsigned)quall_protocol_version());
    return JNI_VERSION_1_6;
}

/* ============================================================================================
 * Conversões
 * ============================================================================================ */

/** `byte[]` → C string recém-alocada, terminada em NUL. Nulo entra, nulo sai. */
static char *copiar_bytes(JNIEnv *env, jbyteArray arr) {
    if (arr == NULL) {
        return NULL;
    }
    jsize n = (*env)->GetArrayLength(env, arr);
    char *s = (char *)malloc((size_t)n + 1);
    if (s == NULL) {
        return NULL;
    }
    if (n > 0) {
        (*env)->GetByteArrayRegion(env, arr, 0, n, (jbyte *)s);
    }
    s[n] = '\0';
    return s;
}

/** C string → `byte[]` (UTF-8 puro, sem o NUL). Nulo vira vazio. */
static jbyteArray para_bytes(JNIEnv *env, const char *s) {
    if (s == NULL) {
        s = "";
    }
    jsize n = (jsize)strlen(s);
    jbyteArray arr = (*env)->NewByteArray(env, n);
    if (arr == NULL) {
        return NULL;
    }
    if (n > 0) {
        (*env)->SetByteArrayRegion(env, arr, 0, n, (const jbyte *)s);
    }
    return arr;
}

/** `n` bytes de `s` → `byte[]`. O comprimento vem de quem chama (o que a fronteira devolveu). */
static jbyteArray para_bytes_n(JNIEnv *env, const char *s, size_t n) {
    if (s == NULL || n > (size_t)INT32_MAX) {
        n = 0;
    }
    jbyteArray arr = (*env)->NewByteArray(env, (jsize)n);
    if (arr == NULL) {
        return NULL;
    }
    if (n > 0) {
        (*env)->SetByteArrayRegion(env, arr, 0, (jsize)n, (const jbyte *)s);
    }
    return arr;
}

/**
 * O valor de falta da `POR_BUF_CAP`: um texto, ou **nulo** quando quem chama precisa distinguir
 * "falhou" de "vazio" (o roteiro: vazio é um roteiro, falha não é). Função, e não um `?:` dentro
 * da macro, porque comparar um literal de string com nulo é aviso do compilador.
 */
static jbyteArray falta_ou_nulo(JNIEnv *env, const char *falta) {
    return falta != NULL ? para_bytes(env, falta) : NULL;
}

/**
 * `byte[]` → C string, **recusando NUL no meio**. Uma `String` do Kotlin pode carregar o caractere U+0000;
 * em C ela seria cortada ali em silêncio — o núcleo, que recusa NUL num roteiro, nunca veria o que
 * veio depois. Devolve nulo (e `*tinha_nul = true`) nesse caso; nulo entra, nulo sai.
 */
static char *copiar_bytes_sem_nul(JNIEnv *env, jbyteArray arr, bool *tinha_nul) {
    *tinha_nul = false;
    char *s = copiar_bytes(env, arr);
    if (s == NULL) {
        return NULL;
    }
    jsize n = (*env)->GetArrayLength(env, arr);
    if (memchr(s, '\0', (size_t)n) != NULL) {
        *tinha_nul = true;
        free(s);
        return NULL;
    }
    return s;
}

static QuallDeviceDesc montar_desc(const char *id, const char *nome, jint caps) {
    /* Zerar antes de preencher, pela mesma razão registrada no `hostStart`: hoje os cinco campos
     * são atribuídos e o struct fica completo, mas no dia em que a fronteira ganhar o sexto esta
     * função passa a mandar lixo de pilha para o núcleo **sem uma linha de aviso** — foi
     * exatamente assim que `audio_codec` entrou no `QuallTrackDesc`. O `memset` continua correto
     * quando o struct cresce; a atribuição campo a campo, não. */
    QuallDeviceDesc me;
    memset(&me, 0, sizeof me);
    me.device_id = id;
    me.display_name = nome;
    me.screen_source = (caps & 1) != 0;
    me.camera_source = (caps & 2) != 0;
    me.sink = (caps & 4) != 0;
    return me;
}

/* ============================================================================================
 * Ficha
 * ============================================================================================ */

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_protocolVersion(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jint)quall_protocol_version();
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_knownPeersHasSecureBytes(JNIEnv *env, jclass cls,
                                                               jbyteArray known_peers_json) {
    (void)cls;
    char *known = copiar_bytes(env, known_peers_json);
    if (known == NULL) return -1;
    jint result = (jint)quall_known_peers_has_secure(known);
    free(known);
    return result;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_serviceTypeBytes(JNIEnv *env, jclass cls) {
    (void)cls;
    return para_bytes(env, quall_service_type());
}

/*
 * `quall_last_error` é **por thread**. O Kotlin precisa chamar da mesma thread que falhou — e é
 * o que `QuallNative.kt` documenta e faz.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_lastErrorBytes(JNIEnv *env, jclass cls) {
    (void)cls;
    return para_bytes(env, quall_last_error());
}

/*
 * `quall_last_status` é **por thread**, como o `quall_last_error`, e tem a mesma regra de uso: ler
 * logo depois da chamada que sinalizou falha, antes de qualquer outra chamada `quall_` naquela
 * thread. Uma chamada bem-sucedida **não** limpa o valor — perguntar "deu erro?" a esta função é
 * ler um valor velho; a pergunta certa é ao que a chamada devolveu (nulo, ou negativo).
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_lastStatus(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jint)quall_last_status();
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_generatePinBytes(JNIEnv *env, jclass cls) {
    (void)cls;
    char pilha[PILHA];
    intptr_t n = quall_generate_pin(pilha, sizeof pilha);
    if (n <= 0 || (size_t)n > sizeof pilha) {
        LOGE("quall_generate_pin devolveu %ld", (long)n);
        return para_bytes(env, "");
    }
    return para_bytes(env, pilha);
}

/* ============================================================================================
 * Anúncio mDNS
 * ============================================================================================ */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_advertiserStart(JNIEnv *env, jclass cls,
                                                        jbyteArray device_id,
                                                        jbyteArray display_name, jint caps,
                                                        jint porta) {
    (void)cls;
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    jlong saida = 0;
    if (id != NULL && nome != NULL) {
        QuallDeviceDesc me = montar_desc(id, nome, caps);
        QuallAdvertiser *a = quall_advertiser_start(&me, (uint16_t)porta);
        saida = (jlong)(uintptr_t)a;
    }
    free(id);
    free(nome);
    return saida;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_advertiserStop(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    quall_advertiser_stop((QuallAdvertiser *)(uintptr_t)handle);
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_advertiserLabelBytes(JNIEnv *env, jclass cls,
                                                           jlong handle) {
    (void)cls;
    const QuallAdvertiser *a = (const QuallAdvertiser *)(uintptr_t)handle;
    if (a == NULL) return para_bytes(env, "");
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_advertiser_label(a, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}

/* ============================================================================================
 * Navegação mDNS
 * ============================================================================================ */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_browserStart(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_browser_start();
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_browserCollect(JNIEnv *env, jclass cls, jlong handle,
                                                       jint ms) {
    (void)env;
    (void)cls;
    QuallBrowser *b = (QuallBrowser *)(uintptr_t)handle;
    if (b == NULL) {
        return -1;
    }
    return (jint)quall_browser_collect(b, (uint32_t)ms);
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_browserDevicesJsonBytes(JNIEnv *env, jclass cls,
                                                                jlong handle) {
    (void)cls;
    const QuallBrowser *b = (const QuallBrowser *)(uintptr_t)handle;
    if (b == NULL) {
        return para_bytes(env, "[]");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_browser_devices_json(b, (buf), (cap))
    POR_BUF_CAP(env, saida, "[]", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_browserStop(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    quall_browser_stop((QuallBrowser *)(uintptr_t)handle);
}

/* ============================================================================================
 * Cancelamento (dívida 10) — substitui o truque de conexão TCP descartável que a casca usava
 * ============================================================================================ */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_cancellerNew(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_canceller_new();
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_cancellerFree(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    quall_canceller_free((struct QuallCanceller *)(uintptr_t)handle);
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_sessionCancel(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    quall_session_cancel((const struct QuallCanceller *)(uintptr_t)handle);
}

/* ============================================================================================
 * Sessão emissora
 * ============================================================================================ */

/*
 * **Bloqueia** até a sessão subir, o prazo estourar, ou o cancelador acionar (`quall.h`). O
 * Kotlin chama de uma thread própria; nenhuma região crítica de JNI é segurada aqui, justamente
 * porque isto pode ficar minutos parado.
 *
 * Sempre passa por `quall_host_cancelable`, nunca por `quall_host`: o header documenta que
 * cancelador nulo reproduz `quall_host` exatamente, então não há caminho a menos por chamar a
 * versão cancelável sempre — e um só caminho é um caminho a menos para divergir.
 *
 * ## A segunda track entra aqui, e só aqui
 *
 * `audio_track_kind < 0` quer dizer "sem áudio", e é o caminho que existia antes. Com áudio, a
 * oferta leva **duas** tracks. Isso não é escolha de estilo: o que não está na oferta SDP só
 * entra com renegociação, que o Quall não implementa. Um `quall_track_*` de áudio criado depois
 * de a sessão subir não teria como existir.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_hostStart(JNIEnv *env, jclass cls, jbyteArray device_id,
                                                  jbyteArray display_name, jint caps,
                                                  jbyteArray pin, jbyteArray known_peers_json,
                                                  jint porta, jint timeout_ms, jint track_kind,
                                                  jbyteArray track_label, jint audio_track_kind,
                                                  jbyteArray audio_track_label, jint audio_codec,
                                                  jlong canceller_handle) {
    (void)cls;
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    char *pin_c = copiar_bytes(env, pin);
    char *known = copiar_bytes(env, known_peers_json); /* pode ser nulo, e nulo é válido */
    char *rotulo = copiar_bytes(env, track_label);
    char *rotulo_audio = copiar_bytes(env, audio_track_label); /* nulo quando não há áudio */
    bool com_audio = audio_track_kind >= 0 && rotulo_audio != NULL;

    jlong saida = 0;
    if (id != NULL && nome != NULL && pin_c != NULL && rotulo != NULL) {
        /* **O `memset` é obrigatório, e o defeito que ele fecha não dá aviso nenhum.**
         *
         * Este bloco era `QuallTrackDesc track; track.kind = …; track.label = …;` — sem zerar.
         * `QuallTrackDesc` ganhou um terceiro campo (`audio_codec`) na rodada de áudio da
         * fronteira, e a partir daí ele ia para o núcleo com **lixo de pilha**. O `memset`
         * logo abaixo é de `opcoes`, não deste struct.
         *
         * O mesmo campo, nas cascas Swift, quebrou o **build** — elas ficaram dias sem compilar e
         * alguém viu. Em C ninguém reclama: compila, roda, e passa um valor indeterminado que às
         * vezes calha de ser 0. É a assimetria que faz esta linha valer o comentário.
         *
         * Zerar o struct inteiro, e não acrescentar uma atribuição por campo: da próxima vez que
         * a fronteira crescer, o `memset` continua correto e a atribuição por campo não. Zero é
         * `QUALL_AUDIO_CODEC_DEFAULT`, que é "use o codec do preset da espécie" — o valor certo
         * para a track de vídeo, que ignora o campo, e para a de áudio quando a casca não escolhe.
         */
        QuallTrackDesc tracks[2];
        memset(tracks, 0, sizeof tracks);
        tracks[0].kind = (enum QuallTrackKind)track_kind;
        tracks[0].label = rotulo;
        if (com_audio) {
            tracks[1].kind = (enum QuallTrackKind)audio_track_kind;
            tracks[1].label = rotulo_audio;
            tracks[1].audio_codec = (enum QuallAudioCodec)audio_codec;
        }

        QuallSessionOptions opcoes;
        memset(&opcoes, 0, sizeof opcoes);
        opcoes.me = montar_desc(id, nome, caps);
        opcoes.pin = pin_c;
        opcoes.known_peers_json = known;
        opcoes.signaling_port = (uint16_t)porta;
        opcoes.timeout_ms = (uint32_t)timeout_ms;
        opcoes.tracks = tracks;
        opcoes.track_count = com_audio ? 2 : 1;

        const struct QuallCanceller *cancelador =
            (const struct QuallCanceller *)(uintptr_t)canceller_handle;
        saida = (jlong)(uintptr_t)quall_host_cancelable(&opcoes, cancelador);
    } else {
        LOGE("hostStart: falta de memória ao copiar as strings");
    }

    free(id);
    free(nome);
    free(pin_c);
    free(known);
    free(rotulo);
    free(rotulo_audio);
    return saida;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_sessionSignalingPort(JNIEnv *env, jclass cls,
                                                             jlong sessao) {
    (void)env;
    (void)cls;
    return (jint)quall_session_signaling_port((const QuallSession *)(uintptr_t)sessao);
}

JNIEXPORT jboolean JNICALL
Java_com_quall_android_core_QuallNative_sessionPairingIsNew(JNIEnv *env, jclass cls,
                                                            jlong sessao) {
    (void)env;
    (void)cls;
    return quall_session_pairing_is_new((const QuallSession *)(uintptr_t)sessao) ? JNI_TRUE
                                                                                : JNI_FALSE;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_sessionPeerJsonBytes(JNIEnv *env, jclass cls,
                                                             jlong sessao) {
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return para_bytes(env, "{}");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_session_peer_json(s, (buf), (cap))
    POR_BUF_CAP(env, saida, "{}", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_sessionKnownPeersJsonBytes(JNIEnv *env, jclass cls,
                                                                   jlong sessao,
                                                                   jbyteArray known_json) {
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return para_bytes(env, "");
    }
    char *known = copiar_bytes(env, known_json);
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_session_known_peers_json(s, known, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    free(known);
    return saida;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_sessionTrackCount(JNIEnv *env, jclass cls, jlong sessao) {
    (void)env;
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return 0;
    }
    return (jint)quall_session_track_count(s);
}

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_sessionTrack(JNIEnv *env, jclass cls, jlong sessao,
                                                     jint idx) {
    (void)env;
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL || idx < 0) {
        return 0;
    }
    return (jlong)(uintptr_t)quall_session_track(s, (uintptr_t)idx);
}

/*
 * `quall_session_close` deixou de ser `void` em 2026-08-26 (dívida 24): agora **é barreira**, e o
 * status é o que autoriza a casca a liberar o `user_data` de um tratador. Devolvemos o código ao
 * Kotlin em vez de engolir — é dele que o receptor depende para saber se pode liberar a caixa de
 * quadros.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_sessionClose(JNIEnv *env, jclass cls, jlong sessao) {
    (void)env;
    (void)cls;
    return (jint)quall_session_close((QuallSession *)(uintptr_t)sessao);
}

/* ============================================================================================
 * Sessão receptora
 * ============================================================================================ */

/*
 * **Bloqueia** até a sessão subir, o prazo estourar, ou o cancelador acionar. Mesma regra do
 * `hostStart`: chamada de uma thread de trabalho, sem região crítica de JNI segurada.
 *
 * Sempre por `quall_connect_cancelable`, nunca por `quall_connect` — cancelador nulo reproduz a
 * versão simples exatamente, e um caminho só é um caminho a menos para divergir.
 *
 * `pin` pode ser nulo: é o caso do par já conhecido, em que o núcleo retoma o pareamento sem
 * pedir os seis dígitos. `tracks` **não** é preenchido de propósito — `QuallSessionOptions::tracks`
 * "só vale em `quall_host`", e quem conecta recebe as tracks do outro lado por
 * `quall_session_next_track`.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_connectStart(JNIEnv *env, jclass cls, jbyteArray endpoint,
                                                     jbyteArray device_id, jbyteArray display_name,
                                                     jint caps, jbyteArray pin,
                                                     jbyteArray known_peers_json, jint timeout_ms,
                                                     jlong canceller_handle,
                                                     jbyteArray bind_address,
                                                     jint screen_width_px, jint screen_height_px) {
    (void)cls;
    char *destino = copiar_bytes(env, endpoint);
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    char *pin_c = copiar_bytes(env, pin);   /* pode ser nulo, e nulo é válido */
    char *known = copiar_bytes(env, known_peers_json); /* idem */
    char *prender = copiar_bytes(env, bind_address);   /* idem: nulo = todas as interfaces */

    jlong saida = 0;
    if (destino != NULL && id != NULL && nome != NULL) {
        QuallSessionOptions opcoes;
        memset(&opcoes, 0, sizeof opcoes);
        opcoes.me = montar_desc(id, nome, caps);
        opcoes.pin = pin_c;
        opcoes.known_peers_json = known;
        opcoes.signaling_port = 0;
        opcoes.timeout_ms = (uint32_t)timeout_ms;
        opcoes.tracks = NULL;
        opcoes.track_count = 0;
        /*
         * Prende a midia (e a sinalizacao) a UMA interface. Nulo = todas, que e o produto.
         *
         * O nucleo ja tinha isto (`TransportConfig::bind_address`) e a casca Android nao
         * alcancava. Custou dois bracos de bancada: em 01/09 e de novo em 02/09/2026, uma corrida
         * "pelo cabo" fechou pela Wi-Fi porque o ICE escolheu o par do radio apesar de o telefone
         * ter discado o endereco da ancoragem. Sem isto, o unico jeito de forcar o cabo e desligar
         * o Wi-Fi do aparelho — o que derruba o adb e obriga alguem a tocar na tela.
         */
        opcoes.bind_address = prender;

        const struct QuallCanceller *cancelador =
            (const struct QuallCanceller *)(uintptr_t)canceller_handle;
        /*
         * A tela deste aparelho vai no aperto de mao: a tela estendida do Mac cria um monitor por
         * receptor e da a ele o formato desta tela (`docs/tela-estendida.md`). 0x0 = nao digo, e
         * o nucleo se comporta como `quall_connect_cancelable`.
         */
        uint32_t tela_l = screen_width_px > 0 ? (uint32_t)screen_width_px : 0;
        uint32_t tela_a = screen_height_px > 0 ? (uint32_t)screen_height_px : 0;
        saida = (jlong)(uintptr_t)quall_connect_with_screen(destino, &opcoes, cancelador, tela_l, tela_a);
    } else {
        LOGE("connectStart: falta de memória ao copiar as strings");
    }

    free(destino);
    free(id);
    free(nome);
    free(pin_c);
    free(known);
    free(prender);
    return saida;
}

/*
 * Próxima track que chegou do outro lado. Nulo (0) quando nada chegou a tempo — estado normal.
 * O header exige que esta e `sessionNextEvent` sejam chamadas de **uma** thread só; quem garante
 * isso é o Kotlin (`ReceptorSessao` roda as duas no mesmo laço).
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_sessionNextTrack(JNIEnv *env, jclass cls, jlong sessao,
                                                         jint timeout_ms) {
    (void)env;
    (void)cls;
    QuallSession *s = (QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return 0;
    }
    return (jlong)(uintptr_t)quall_session_next_track(s, (uint32_t)timeout_ms);
}

/* O detector de queda. `QUALL_SESSION_EVENT_NONE` (0) é estado normal, não erro. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_sessionNextEvent(JNIEnv *env, jclass cls, jlong sessao,
                                                         jint timeout_ms) {
    (void)env;
    (void)cls;
    QuallSession *s = (QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return (jint)QUALL_SESSION_EVENT_FAILED;
    }
    return (jint)quall_session_next_event(s, (uint32_t)timeout_ms);
}

/* ============================================================================================
 * Track
 * ============================================================================================ */

/*
 * O caminho do quadro.
 *
 * `GetDirectBufferAddress` devolve a **base** do buffer — ele ignora `position()`. Por isso o
 * deslocamento vem como argumento explícito: o `MediaCodec.BufferInfo.offset` do OMX legado do
 * Galaxy A10s não é zero, e somar errado aqui mandaria bytes deslocados pela rede com o retorno
 * dizendo `QUALL_STATUS_OK`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackSendFrame(JNIEnv *env, jclass cls, jlong track,
                                                       jobject buffer, jint deslocamento,
                                                       jint tamanho, jlong timestamp_us,
                                                       jboolean idr) {
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL || buffer == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, buffer);
    if (base == NULL) {
        /* Aconteceria com um `ByteBuffer` não-direto. O Kotlin garante que não; se algum dia
         * deixar de garantir, o erro precisa ser legível e não corrupção de memória. */
        LOGE("trackSendFrame: o ByteBuffer não é direto");
        return (jint)QUALL_STATUS_INVALID;
    }
    jlong capacidade = (*env)->GetDirectBufferCapacity(env, buffer);
    if (deslocamento < 0 || tamanho <= 0 || capacidade < 0 ||
        (jlong)deslocamento + (jlong)tamanho > capacidade) {
        LOGE("trackSendFrame: fatia inválida (off=%d len=%d cap=%lld)", (int)deslocamento,
             (int)tamanho, (long long)capacidade);
        return (jint)QUALL_STATUS_INVALID;
    }

    /* Zerado antes de preencher: ver `montar_desc`. */
    QuallFrame quadro;
    memset(&quadro, 0, sizeof quadro);
    quadro.annexb = base + deslocamento;
    quadro.len = (uintptr_t)tamanho;
    quadro.timestamp_us = (uint64_t)timestamp_us;
    quadro.idr = (idr == JNI_TRUE);
    return (jint)quall_track_send_frame(t, &quadro);
}

/*
 * `pegar_pedido_de_idr` do contrato. Uma leitura atômica; é o que substitui o callback.
 */
JNIEXPORT jboolean JNICALL
Java_com_quall_android_core_QuallNative_trackTakeIdrRequest(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return JNI_FALSE;
    }
    return quall_track_take_idr_request(t) ? JNI_TRUE : JNI_FALSE;
}

/*
 * Por onde a midia esta indo: o par de candidatos ICE escolhido, como JSON.
 *
 * Existe porque uma corrida "pelo cabo" pode fechar pela Wi-Fi e parecer sucesso — foi o que
 * aconteceu em 01/09/2026, e o braco foi anulado. O `quall-probe` sempre soube disso porque le o
 * `Ready` do Rust; a casca Android nao tinha nada equivalente, e por isso um braco de cabo so
 * podia ser CRIDO, nunca conferido.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_sessionPathJsonBytes(JNIEnv *env, jclass cls,
                                                            jlong sessao) {
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return para_bytes(env, "{}");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_session_path_json(s, (buf), (cap))
    POR_BUF_CAP(env, saida, "{}", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_trackStatsJsonBytes(JNIEnv *env, jclass cls, jlong track) {
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return para_bytes(env, "{}");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_track_stats_json(t, (buf), (cap))
    POR_BUF_CAP(env, saida, "{}", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_trackLabelBytes(JNIEnv *env, jclass cls, jlong track) {
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return para_bytes(env, "");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_track_label(t, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackKind(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return -1;
    }
    return (jint)quall_track_kind(t);
}

/*
 * `pedir_idr` do contrato. O receptor chama ao entrar na sessão — e o header avisa que devolve
 * erro **enquanto a track não abriu**, o que é estado normal por alguns milissegundos. Quem
 * insiste é o Kotlin; aqui só se traduz o status.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackRequestIdr(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_track_request_idr(t);
}

/*
 * `quall_track_frames_dropped`: quantos quadros o depacotizador jogou fora por incompletos.
 *
 * **Existe por causa do preço, e o preço mudou o desenho.** Até 31/08/2026 a casca lia este `u64`
 * desserializando `quall_track_stats_json` — um alocador e um parser de JSON por leitura —, e foi
 * exatamente por isso que ela só perguntava a cada 100 ms. O header do núcleo antecipa este erro
 * palavra por palavra: *"uma casca que ache isso caro vai acabar não perguntando"*. Com a leitura
 * custando uma trava e um `u64`, a casca passa a perguntar **uma vez por quadro**, e a condenação
 * da cadeia de referência deixa de ser amostrada.
 *
 * **Nunca chame isto de dentro do tratador de quadro.** `quall_track_frames_dropped` pega o
 * cadeado do depacotizador, e o núcleo despacha o tratador **com esse mesmo cadeado na mão**
 * (`crates/quall-core/src/track.rs`, o fecho de `ao_receber`): chamar de lá trava a track para
 * sempre. Aqui isso não é risco de fato — `receber_quadro` só copia para a caixa, e quem chama
 * esta função é a thread do laço Kotlin —, mas a regra vale para qualquer casca.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_trackFramesDropped(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return 0;
    }
    return (jlong)quall_track_frames_dropped(t);
}

/*
 * O caminho de volta do sinal, os dois lados.
 *
 * `reportLink` é do receptor; `takeLinkReport` é do emissor. Os dois tocam a sinalização, que
 * não é acessada de duas threads — cada casca chama de uma thread só, a mesma que já chama
 * `sessionNextEvent`. Ver `quall_core::signaling::RelatoDoEnlace`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_sessionReportLink(
        JNIEnv *env, jclass cls, jlong sessao,
        jlong ms, jlong pacotes, jlong perdidos, jlong suspeitos, jlong idrsQuebrados,
        jlong naoEntregues) {
    (void)env;
    (void)cls;
    QuallSession *s = (QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_session_report_link(
            s, (uint64_t)ms, (uint64_t)pacotes, (uint64_t)perdidos,
            (uint64_t)suspeitos, (uint64_t)idrsQuebrados, (uint64_t)naoEntregues);
}

/*
 * Escreve `{ms, pacotes, perdidos, suspeitos, idrs_quebrados, nao_decodificados}` em `saida` e
 * devolve `true`.
 *
 * `saida` é um `long[]` de **seis** posições, alocado uma vez pela casca e reaproveitado: um
 * array novo por janela seria lixo por janela num aparelho de 1,79 GB, e a janela é do caminho
 * quente do emissor.
 */
JNIEXPORT jboolean JNICALL
Java_com_quall_android_core_QuallNative_sessionTakeLinkReport(
        JNIEnv *env, jclass cls, jlong sessao, jint prazoMs, jlongArray saida) {
    (void)cls;
    QuallSession *s = (QuallSession *)(uintptr_t)sessao;
    /* **Seis desde 09/09/2026**, e a guarda de tamanho é o que separa "a casca é antiga" de
     * escrita fora do array: `quall_session_take_link_report` escreve seis `uint64_t` sempre. */
    if (s == NULL || saida == NULL || (*env)->GetArrayLength(env, saida) < 6) {
        return JNI_FALSE;
    }
    uint64_t campos[6];
    if (!quall_session_take_link_report(s, (uint32_t)prazoMs, campos)) {
        return JNI_FALSE;
    }
    jlong copia[6];
    for (int i = 0; i < 6; i++) {
        copia[i] = (jlong)campos[i];
    }
    (*env)->SetLongArrayRegion(env, saida, 0, 6, copia);
    return JNI_TRUE;
}

/* O controlador de taxa. A política mora no núcleo; aqui só atravessa. Ver `quall_core::taxa`. */
/*
 * O teto de taxa para uma geometria, em bps, direto de `quall_teto_ajustar`.
 *
 * Existe porque até 02/09/2026 a casca Android decidia o bitrate sozinha — `4_000_000` para a
 * tela e `6_000_000` para a câmera, cravados — e quando o teto de resolução subiu para 1080p em
 * 01/09 nenhum dos dois subiu junto. É o mesmo padrão que o teto de resolução já tinha cobrado:
 * ninguém tinha onde perguntar, então cada casca respondeu sozinha.
 *
 * Devolve `0` se a fronteira recusar; quem chama decide o que fazer com isso em vez de receber um
 * alvo inventado.
 */
/*
 * Bancada: crava a profundidade do anel de reordenacao da track receptora. `0` desliga a fila.
 * Nenhum caminho de produto chama isto — ver `Bancada.profundidadeDoAnel`.
 */
JNIEXPORT jboolean JNICALL
Java_com_quall_android_core_QuallNative_trackSetReorderDepth(JNIEnv *env, jclass cls,
                                                            jlong track, jint pacotes) {
    (void)env;
    (void)cls;
    if (track == 0 || pacotes < 0) {
        return JNI_FALSE;
    }
    return quall_track_set_reorder_depth((const QuallTrack *)(uintptr_t)track,
                                         (uint32_t)pacotes) == QUALL_STATUS_OK
           ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_tetoDeTaxaBps(JNIEnv *env, jclass cls,
                                                     jint largura, jint altura, jint fps,
                                                     jint alvoMaxFs) {
    (void)env;
    (void)cls;
    QuallTeto teto;
    memset(&teto, 0, sizeof(teto));
    if (largura <= 0 || altura <= 0 || fps <= 0) {
        return 0;
    }
    // **O alvo entra aqui também, e a razão está medida.** Em 07/09/2026 o cardápio de resolução
    // subiu a geometria do S24 para 4K e esta função continuou chamando `quall_teto_ajustar`, que
    // não conhece a escolha e grampeia no padrão de 1080p: o encoder recebeu 3840x2160 com
    // **6,68 Mbps**, o orçamento de 1080p — 0,027 bit/pixel contra os 0,145 do produto.
    //
    // É exatamente o defeito que o comentário de `tetoDeTaxaBps` no Kotlin já registrava sobre
    // 01/09 ("o teto de resolução subiu e nenhum dos dois subiu junto"), repetido no mesmo
    // arquivo que o descreve. As duas metades do teto andam juntas ou não andam.
    if (quall_teto_ajustar_para((uint32_t)largura, (uint32_t)altura, (uint32_t)fps,
                                alvoMaxFs > 0 ? (uint32_t)alvoMaxFs : 0u,
                                (uint32_t)fps, &teto)
        != QUALL_STATUS_OK) {
        return 0;
    }
    return (jint)teto.teto_de_taxa_bps;
}

/*
 * A **geometria** que o teto permite, do mesmo `quall_teto_ajustar` que já dava a taxa.
 *
 * Existe porque a casca perguntava só metade. `tetoDeTaxaBps` logo acima chama a fronteira,
 * lê `teto_de_taxa_bps` e **descarta `teto.largura` e `teto.altura`** — então o caminho de tela
 * do Android entregava ao encoder a geometria crua do aparelho. Medido em campo em 07/09/2026:
 * o S24 espelhava a tela em 1440x3120, que são 17.550 macroblocos por quadro contra os 8192 do
 * `MaxFS` do nível 4.0 que o nosso próprio SDP anuncia — 2,14 vezes acima. Funcionava porque o
 * VideoToolbox do receptor é tolerante, e "funciona no receptor que eu tenho" não é o contrato.
 *
 * O iOS já fazia certo, por outro caminho: `CodificadorH264.destino(..., tetoMaior: 1920,
 * tetoMenor: 1080)`. A diferença é que lá o teto está escrito na casca e aqui ele é perguntado —
 * que é a disciplina certa, e a razão de esta função existir em vez de dois literais no Kotlin.
 *
 * Devolve os dois empacotados num `jlong` — largura nos 32 bits altos, altura nos baixos — para
 * não alocar objeto Java dentro do JNI. `0` é recusa da fronteira, e quem chama decide; devolver
 * a geometria de entrada em silêncio seria o defeito que esta função conserta.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_tetoDeResolucao(JNIEnv *env, jclass cls,
                                                       jint largura, jint altura, jint fps,
                                                       jint alvoMaxFs) {
    (void)env;
    (void)cls;
    QuallTeto teto;
    memset(&teto, 0, sizeof(teto));
    if (largura <= 0 || altura <= 0 || fps <= 0) {
        return 0;
    }
    // `alvoMaxFs` é a resolução que o usuário escolheu, em macroblocos por quadro. `0` é "não
    // escolheu" e o núcleo cai no padrão de 1080p — o comportamento de antes do cardápio.
    if (quall_teto_ajustar_para((uint32_t)largura, (uint32_t)altura, (uint32_t)fps,
                                alvoMaxFs > 0 ? (uint32_t)alvoMaxFs : 0u,
                                (uint32_t)fps, &teto)
        != QUALL_STATUS_OK) {
        return 0;
    }
    return ((jlong)teto.largura << 32) | (jlong)teto.altura;
}

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_rateNew(JNIEnv *env, jclass cls, jint tetoBps) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_rate_new((uint32_t)tetoBps);
}

/*
 * Devolve o motivo (`QuallRateReason`) e escreve o bitrate novo em `saida[0]` quando houve um.
 *
 * `saida` é um `int[]` de uma posição, reaproveitado — mesmo motivo do array acima.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_rateSample(
        JNIEnv *env, jclass cls, jlong controle,
        jlong ms, jlong pacotes, jlong perdidos, jlong suspeitos, jlong idrsQuebrados,
        jlong naoEntregues, jintArray saida) {
    (void)cls;
    QuallRate *r = (QuallRate *)(uintptr_t)controle;
    if (r == NULL) {
        return (jint)QUALL_RATE_REASON_SKIPPED;
    }
    uint32_t novo = 0;
    QuallRateReason motivo = quall_rate_sample(
            r, (uint64_t)ms, (uint64_t)pacotes, (uint64_t)perdidos,
            (uint64_t)suspeitos, (uint64_t)idrsQuebrados, (uint64_t)naoEntregues, &novo);
    if (saida != NULL && (*env)->GetArrayLength(env, saida) >= 1) {
        jint v = (jint)novo;
        (*env)->SetIntArrayRegion(env, saida, 0, 1, &v);
    }
    return (jint)motivo;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_rateCurrentBps(JNIEnv *env, jclass cls, jlong controle) {
    (void)env;
    (void)cls;
    return (jint)quall_rate_current_bps((const QuallRate *)(uintptr_t)controle);
}

JNIEXPORT jboolean JNICALL
Java_com_quall_android_core_QuallNative_rateAtFloor(JNIEnv *env, jclass cls, jlong controle) {
    (void)env;
    (void)cls;
    return quall_rate_at_floor((const QuallRate *)(uintptr_t)controle) ? JNI_TRUE : JNI_FALSE;
}

/* `{janelas, descidas, subidas}` em `saida`, um `long[3]` reaproveitado. */
JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_rateCounters(
        JNIEnv *env, jclass cls, jlong controle, jlongArray saida) {
    (void)cls;
    const QuallRate *r = (const QuallRate *)(uintptr_t)controle;
    if (r == NULL || saida == NULL || (*env)->GetArrayLength(env, saida) < 3) {
        return;
    }
    uint64_t campos[3];
    quall_rate_counters(r, campos);
    jlong copia[3];
    for (int i = 0; i < 3; i++) {
        copia[i] = (jlong)campos[i];
    }
    (*env)->SetLongArrayRegion(env, saida, 0, 3, copia);
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_rateFree(JNIEnv *env, jclass cls, jlong controle) {
    (void)env;
    (void)cls;
    quall_rate_free((QuallRate *)(uintptr_t)controle);
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_trackFree(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    quall_track_free((QuallTrack *)(uintptr_t)track);
}

/* ============================================================================================
 * Caixa de quadros — o receptor, sem anexar thread nenhuma à JVM
 * ============================================================================================
 *
 * O tratador de `quall_track_on_frame` roda numa thread da libdatachannel e o `annexb` que ele
 * recebe aponta para o buffer interno do núcleo, válido **só durante a chamada**. As duas coisas
 * juntas obrigam a uma decisão:
 *
 *   (a) anexar aquela thread à JVM (`AttachCurrentThread` + `NewGlobalRef` + desanexar) e chamar
 *       o Kotlin de dentro do tratador; ou
 *   (b) copiar os bytes para uma estrutura em C e deixar uma thread **Java** vir buscar.
 *
 * Esta casca escolhe (b), pelo mesmo argumento que já valia para o pedido de IDR no emissor
 * (ver o topo do arquivo e `QuallNative.kt`): anexar threads de biblioteca à JVM é onde um app
 * de 1,79 GB morre, e é uma decisão que se paga uma vez e se cobra em todo quadro.
 *
 * ## O anel descarta o mais velho, e isso é o desenho
 *
 * O tratador **não pode bloquear** — segurar a thread da libdatachannel trava a recepção de RTCP
 * da sessão inteira. Então ele nunca espera o consumidor: se o anel está cheio, o quadro mais
 * velho é sobrescrito e o contador `descartados` sobe. Guardar tudo seria fila, e fila é
 * exatamente o que o contrato proíbe: num espelhamento ao vivo, quadro velho não serve.
 *
 * ## Tempo de vida
 *
 * A caixa é o `user_data` do tratador. Ela só pode ser liberada depois de
 * `quall_track_on_frame(t, NULL, NULL)` **ou** `quall_session_close(s)` devolverem
 * `QUALL_STATUS_OK` — que é a barreira que a fronteira C passou a dar em 2026-08-26. Quem
 * respeita isso é o Kotlin; aqui só existem `frameBoxNew`/`frameBoxFree`, e nada em C libera a
 * caixa por conta própria.
 */

#define CAIXA_SLOTS 16
#define CAIXA_EXIBICAO_SLOTS 4
/* Teto por quadro. Um IDR de 720p a 4 Mbps fica na casa das dezenas de KiB; 4 MiB é folga de
 * duas ordens de grandeza e ainda assim um limite, para um quadro corrompido não pedir o mundo. */
#define CAIXA_MAX_QUADRO (4u * 1024u * 1024u)

typedef struct {
    uint8_t *bytes;
    size_t cap;
    size_t len;
    uint64_t timestamp_us;
    bool idr;
} SlotDeQuadro;

typedef struct CaixaDeQuadros {
    pthread_mutex_t m;
    pthread_cond_t cv;
    SlotDeQuadro slots[CAIXA_SLOTS];
    unsigned capacidade;
    struct CaixaDeQuadros *gravacao;
    /* Contadores monotônicos: `escrita - leitura` é quantos quadros esperam. */
    unsigned escrita;
    unsigned leitura;
    unsigned long recebidos;
    unsigned long descartados;
    unsigned long grandes_demais;
    unsigned long nao_couberam;
} CaixaDeQuadros;

/*
 * O tratador. Roda em thread da libdatachannel: **nada de JNI aqui dentro**, nada que bloqueie
 * por tempo indeterminado. Uma trava curta e um `memcpy`.
 */
static void guardar_quadro(CaixaDeQuadros *c, const struct QuallFrame *frame) {
    if (c == NULL || frame == NULL || frame->annexb == NULL || frame->len == 0) {
        return;
    }
    if (frame->len > CAIXA_MAX_QUADRO) {
        pthread_mutex_lock(&c->m);
        c->grandes_demais++;
        pthread_mutex_unlock(&c->m);
        return;
    }

    pthread_mutex_lock(&c->m);
    c->recebidos++;
    if (c->escrita - c->leitura >= c->capacidade) {
        /* Cheio: o mais velho vai embora. Ver "o anel descarta o mais velho" acima. */
        c->leitura++;
        c->descartados++;
    }
    SlotDeQuadro *s = &c->slots[c->escrita % c->capacidade];
    if (s->cap < frame->len) {
        uint8_t *maior = (uint8_t *)realloc(s->bytes, frame->len);
        if (maior == NULL) {
            /* Sem memória para este quadro: ele **e os que esperam** vão embora. Jogar fora só o
             * novo deixaria na caixa quadros mais velhos que o descarte, e o receptor conta com o
             * contrário — todo descarte contado é anterior ao quadro tirado em seguida
             * (`DividaDaCaixa`: um IDR tirado depois pagaria um buraco que veio depois dele). */
            c->descartados += 1u + (c->escrita - c->leitura);
            c->leitura = c->escrita;
            pthread_mutex_unlock(&c->m);
            return;
        }
        s->bytes = maior;
        s->cap = frame->len;
    }
    memcpy(s->bytes, frame->annexb, frame->len);
    s->len = frame->len;
    s->timestamp_us = frame->timestamp_us;
    s->idr = frame->idr;
    c->escrita++;
    pthread_cond_signal(&c->cv);
    pthread_mutex_unlock(&c->m);
}

static void receber_quadro(const struct QuallFrame *frame, void *user_data) {
    CaixaDeQuadros *c = (CaixaDeQuadros *)user_data;
    if (c == NULL) return;
    pthread_mutex_lock(&c->m);
    if (c->gravacao != NULL) guardar_quadro(c->gravacao, frame);
    pthread_mutex_unlock(&c->m);
    guardar_quadro(c, frame);
}

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_frameBoxNew(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    CaixaDeQuadros *c = (CaixaDeQuadros *)calloc(1, sizeof *c);
    if (c == NULL) {
        return 0;
    }
    c->capacidade = CAIXA_EXIBICAO_SLOTS;
    if (pthread_mutex_init(&c->m, NULL) != 0) {
        free(c);
        return 0;
    }
    /* `CLOCK_MONOTONIC` na condvar: o prazo do `frameBoxTake` não pode andar com ajuste de NTP. */
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    int erro = pthread_cond_init(&c->cv, &attr);
    pthread_condattr_destroy(&attr);
    if (erro != 0) {
        pthread_mutex_destroy(&c->m);
        free(c);
        return 0;
    }
    return (jlong)(uintptr_t)c;
}

/* Recording owns a separate bounded queue: disk/AAC latency cannot drain the display queue.
 * Unset under this lock before freeing the recording box, even if track unregister fails. */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_recordingBoxNew(JNIEnv *env, jclass cls) {
    jlong box = Java_com_quall_android_core_QuallNative_frameBoxNew(env, cls);
    if (box != 0) ((CaixaDeQuadros *)(uintptr_t)box)->capacidade = CAIXA_SLOTS;
    return box;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_frameBoxSetRecording(JNIEnv *env, jclass cls,
                                                            jlong box, jlong recording) {
    (void)env; (void)cls;
    CaixaDeQuadros *c = (CaixaDeQuadros *)(uintptr_t)box;
    if (c == NULL) return;
    pthread_mutex_lock(&c->m);
    c->gravacao = (CaixaDeQuadros *)(uintptr_t)recording;
    pthread_mutex_unlock(&c->m);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackCaptureOffsetRawUs(JNIEnv *env, jclass cls,
                                                               jlong track, jlongArray out) {
    (void)cls;
    if (out == NULL || (*env)->GetArrayLength(env, out) < 2) return -1;
    int64_t offset = 0;
    int32_t guard = 0;
    int32_t status = quall_track_capture_offset_raw_us((QuallTrack *)(uintptr_t)track, &offset, &guard);
    if (status == 1) {
        jlong values[2] = {(jlong)offset, (jlong)guard};
        (*env)->SetLongArrayRegion(env, out, 0, 2, values);
    }
    return status;
}

/*
 * Só chame depois de a barreira do núcleo ter voltado com `QUALL_STATUS_OK` — ver "Tempo de
 * vida" acima. Não há como conferir isso daqui: quem sabe é quem fechou.
 */
JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_frameBoxFree(JNIEnv *env, jclass cls, jlong caixa) {
    (void)env;
    (void)cls;
    CaixaDeQuadros *c = (CaixaDeQuadros *)(uintptr_t)caixa;
    if (c == NULL) {
        return;
    }
    for (int i = 0; i < CAIXA_SLOTS; i++) {
        free(c->slots[i].bytes);
    }
    pthread_cond_destroy(&c->cv);
    pthread_mutex_destroy(&c->m);
    free(c);
}

/**
 * Tira o quadro mais antigo da caixa e o copia **direto para o `ByteBuffer` de entrada do
 * `MediaCodec`** — é por isso que `destino` é um buffer direto, e não um `byte[]`: o caminho do
 * quadro no receptor tem uma cópia a menos que a versão óbvia.
 *
 * Devolve o tamanho em bytes (> 0), ou:
 *   -1  nada chegou dentro do prazo (estado normal),
 *   -2  o quadro não cabe no `destino` — foi descartado, e o contador `nao_couberam` sobe;
 *       `meta[0]` e `meta[1]` dizem qual era,
 *   -3  argumento inválido.
 *
 * `meta` recebe `[timestamp_us, idr?1:0, recebidos, descartados, grandes_demais, nao_couberam]`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_frameBoxTake(JNIEnv *env, jclass cls, jlong caixa,
                                                     jobject destino, jlongArray meta,
                                                     jint timeout_ms) {
    (void)cls;
    CaixaDeQuadros *c = (CaixaDeQuadros *)(uintptr_t)caixa;
    if (c == NULL || destino == NULL) {
        return -3;
    }
    uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, destino);
    jlong capacidade = (*env)->GetDirectBufferCapacity(env, destino);
    if (base == NULL || capacidade <= 0) {
        LOGE("frameBoxTake: o ByteBuffer de destino não é direto");
        return -3;
    }

    struct timespec prazo;
    clock_gettime(CLOCK_MONOTONIC, &prazo);
    prazo.tv_sec += timeout_ms / 1000;
    prazo.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (prazo.tv_nsec >= 1000000000L) {
        prazo.tv_sec += 1;
        prazo.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&c->m);
    /* Prazo curto por chamada (o receptor chama num laço): é o que faz o desligamento ser
     * rápido sem existir um "acorde" vindo de fora. Uma função de acordar seria mais direta e
     * seria também um ponteiro a mais que a interface poderia tocar depois de liberado — e a
     * regra do projeto é nunca chamar a fronteira com um id que possa estar morto. */
    while (c->escrita == c->leitura) {
        if (pthread_cond_timedwait(&c->cv, &c->m, &prazo) != 0) {
            break;
        }
    }

    jint saida;
    uint64_t ts = 0;
    bool idr = false;
    if (c->escrita == c->leitura) {
        saida = -1;
    } else {
        SlotDeQuadro *s = &c->slots[c->leitura % c->capacidade];
        if ((jlong)s->len > capacidade) {
            c->nao_couberam++;
            c->leitura++;
            saida = -2;
            /* Diz o que era: um IDR que não cabe no decodificador é o caso que o receptor precisa
             * saber, porque pedir outro traz um do mesmo tamanho. */
            ts = s->timestamp_us;
            idr = s->idr;
        } else {
            memcpy(base, s->bytes, s->len);
            ts = s->timestamp_us;
            idr = s->idr;
            saida = (jint)s->len;
            c->leitura++;
        }
    }
    jlong valores[6];
    valores[0] = (jlong)ts;
    valores[1] = idr ? 1 : 0;
    valores[2] = (jlong)c->recebidos;
    valores[3] = (jlong)c->descartados;
    valores[4] = (jlong)c->grandes_demais;
    valores[5] = (jlong)c->nao_couberam;
    pthread_mutex_unlock(&c->m);

    if (meta != NULL && (*env)->GetArrayLength(env, meta) >= 6) {
        (*env)->SetLongArrayRegion(env, meta, 0, 6, valores);
    }
    return saida;
}

/**
 * Liga (`caixa != 0`) ou desliga (`caixa == 0`) o tratador de quadro desta track.
 *
 * Desligar é `quall_track_on_frame(t, NULL, NULL)`, que desde 2026-08-26 **é barreira**: com
 * `QUALL_STATUS_OK`, o tratador antigo não está rodando em thread nenhuma e não voltará a rodar
 * — e só então a caixa pode ser liberada. Qualquer outro status quer dizer "não libere nada".
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackOnFrame(JNIEnv *env, jclass cls, jlong track,
                                                     jlong caixa) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    if (caixa == 0) {
        return (jint)quall_track_on_frame(t, NULL, NULL);
    }
    return (jint)quall_track_on_frame(t, receber_quadro, (void *)(uintptr_t)caixa);
}

/* ============================================================================================
 * Áudio
 * ============================================================================================
 *
 * O Android não tinha áudio nenhum até esta rodada: `grep -ri audio` no Kotlin não achava linha.
 * O caminho do núcleo já existia inteiro e provado entre sondas (`docs/audio.md`); o que faltava
 * era a fachada.
 *
 * ## A caixa de slots é a mesma ideia da caixa de quadros, e pelo mesmo motivo
 *
 * `quall_track_on_audio` entrega **um slot de 20 ms por chamada, em ordem de reprodução**, de uma
 * thread da libdatachannel, com o `payload` válido só durante a chamada. As duas restrições são
 * idênticas às do vídeo, e a saída é idêntica: copiar para um anel em C e deixar uma thread
 * **Java** vir buscar. Nenhum `JNIEnv`, nenhum `AttachCurrentThread`, nenhuma referência global.
 *
 * ## O anel é maior que o do vídeo, e descarta o mais velho pelo mesmo argumento
 *
 * 32 slots são 640 ms — folga de uma ordem de grandeza sobre a profundidade do jitter buffer do
 * núcleo (2 slots) e sobre o buffer do `AudioTrack`. O consumidor é um `AudioTrack` em
 * `WRITE_BLOCKING`, que consome em tempo real por construção; se ele parar, o anel enche, e aí a
 * escolha é a mesma do vídeo — o mais velho vai embora e o contador sobe. Fila de áudio ao vivo é
 * latência que não volta.
 *
 * ## O decodificador **não** mora aqui
 *
 * Ele é `quall_audio_decoder_*` da fronteira C, criado pelo preset da espécie. A alternativa era
 * o `MediaCodec` do Android, e ela cai num detalhe que não é detalhe: o `MediaCodec` não tem
 * `decode_fec` nem ocultação de perda explícita, então a ordem `FEC` que o jitter buffer entrega
 * não teria consumidor — o socorro atravessaria a rede para ser jogado fora.
 */

/* Teto de um slot. `MAX_AMOSTRA` da fronteira é 4 KiB; aqui o mesmo número, com nome próprio
 * porque o header não o exporta. */
#define CAIXA_MAX_SLOT 4096u
/* 32 × 20 ms = 640 ms. Ver "o anel é maior que o do vídeo" acima. */
#define CAIXA_AUDIO_SLOTS 32

typedef struct {
    uint8_t bytes[CAIXA_MAX_SLOT];
    size_t len;
    int order;
    uint16_t sequence;
    uint64_t timestamp_us;
    int8_t fec_has_lbrr;
} SlotDeAudio;

typedef struct CaixaDeAudio {
    pthread_mutex_t m;
    pthread_cond_t cv;
    SlotDeAudio slots[CAIXA_AUDIO_SLOTS];
    unsigned escrita;
    unsigned leitura;
    unsigned long recebidos;
    unsigned long descartados;
    unsigned long grandes_demais;
} CaixaDeAudio;

/*
 * O tratador de slot. Thread da libdatachannel: uma trava curta e um `memcpy`, nada de JNI.
 *
 * `SILENCE` chega com `payload` nulo e `len` 0, e **é um slot legítimo** — é o pedido de
 * ocultação de perda. Descartá-lo aqui por "não tem bytes" tiraria 20 ms do relógio de
 * reprodução e o som andaria mais rápido que o relógio do emissor.
 */
static void receber_slot_de_audio(const struct QuallAudioSlot *slot, void *user_data) {
    CaixaDeAudio *c = (CaixaDeAudio *)user_data;
    if (c == NULL || slot == NULL) {
        return;
    }
    if (slot->len > CAIXA_MAX_SLOT) {
        pthread_mutex_lock(&c->m);
        c->grandes_demais++;
        pthread_mutex_unlock(&c->m);
        return;
    }

    pthread_mutex_lock(&c->m);
    c->recebidos++;
    if (c->escrita - c->leitura >= CAIXA_AUDIO_SLOTS) {
        c->leitura++;
        c->descartados++;
    }
    SlotDeAudio *s = &c->slots[c->escrita % CAIXA_AUDIO_SLOTS];
    s->len = slot->len;
    if (slot->payload != NULL && slot->len > 0) {
        memcpy(s->bytes, slot->payload, slot->len);
    }
    s->order = (int)slot->order;
    s->sequence = slot->sequence;
    s->timestamp_us = slot->timestamp_us;
    s->fec_has_lbrr = slot->fec_has_lbrr;
    c->escrita++;
    pthread_cond_signal(&c->cv);
    pthread_mutex_unlock(&c->m);
}

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_audioBoxNew(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    CaixaDeAudio *c = (CaixaDeAudio *)calloc(1, sizeof *c);
    if (c == NULL) {
        return 0;
    }
    if (pthread_mutex_init(&c->m, NULL) != 0) {
        free(c);
        return 0;
    }
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    int erro = pthread_cond_init(&c->cv, &attr);
    pthread_condattr_destroy(&attr);
    if (erro != 0) {
        pthread_mutex_destroy(&c->m);
        free(c);
        return 0;
    }
    return (jlong)(uintptr_t)c;
}

/* Só depois de a barreira do núcleo ter voltado `QUALL_STATUS_OK`. Mesma regra da caixa de
 * quadros; aqui há um detalhe a mais e ele está na doc de `trackOnAudio`. */
JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_audioBoxFree(JNIEnv *env, jclass cls, jlong caixa) {
    (void)env;
    (void)cls;
    CaixaDeAudio *c = (CaixaDeAudio *)(uintptr_t)caixa;
    if (c == NULL) {
        return;
    }
    pthread_cond_destroy(&c->cv);
    pthread_mutex_destroy(&c->m);
    free(c);
}

/**
 * Tira o slot mais antigo da caixa.
 *
 * Devolve o tamanho do payload em bytes — **e `0` é resposta válida**, é a ordem `SILENCE`, que
 * pede ocultação de perda. O que distingue "nada chegou" é `-1`.
 *
 *   >= 0  há slot; `meta[0]` diz o que fazer com ele,
 *   -1    nada chegou dentro do prazo (estado normal),
 *   -2    o payload não coube no `destino` (descartado),
 *   -3    argumento inválido.
 *
 * `meta` recebe `[order, sequence, timestamp_us, fec_has_lbrr, recebidos, descartados]`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_audioBoxTake(JNIEnv *env, jclass cls, jlong caixa,
                                                     jobject destino, jlongArray meta,
                                                     jint timeout_ms) {
    (void)cls;
    CaixaDeAudio *c = (CaixaDeAudio *)(uintptr_t)caixa;
    if (c == NULL || destino == NULL) {
        return -3;
    }
    uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, destino);
    jlong capacidade = (*env)->GetDirectBufferCapacity(env, destino);
    if (base == NULL || capacidade <= 0) {
        LOGE("audioBoxTake: o ByteBuffer de destino não é direto");
        return -3;
    }

    struct timespec prazo;
    clock_gettime(CLOCK_MONOTONIC, &prazo);
    prazo.tv_sec += timeout_ms / 1000;
    prazo.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (prazo.tv_nsec >= 1000000000L) {
        prazo.tv_sec += 1;
        prazo.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&c->m);
    while (c->escrita == c->leitura) {
        if (pthread_cond_timedwait(&c->cv, &c->m, &prazo) != 0) {
            break;
        }
    }

    jint saida;
    jlong valores[6] = {0, 0, 0, 0, 0, 0};
    if (c->escrita == c->leitura) {
        saida = -1;
    } else {
        SlotDeAudio *s = &c->slots[c->leitura % CAIXA_AUDIO_SLOTS];
        if ((jlong)s->len > capacidade) {
            c->descartados++;
            c->leitura++;
            saida = -2;
        } else {
            if (s->len > 0) {
                memcpy(base, s->bytes, s->len);
            }
            valores[0] = (jlong)s->order;
            valores[1] = (jlong)s->sequence;
            valores[2] = (jlong)s->timestamp_us;
            valores[3] = (jlong)s->fec_has_lbrr;
            saida = (jint)s->len;
            c->leitura++;
        }
    }
    valores[4] = (jlong)c->recebidos;
    valores[5] = (jlong)c->descartados;
    pthread_mutex_unlock(&c->m);

    if (meta != NULL && (*env)->GetArrayLength(env, meta) >= 6) {
        (*env)->SetLongArrayRegion(env, meta, 0, 6, valores);
    }
    return saida;
}

/**
 * Liga (`caixa != 0`) ou desliga (`caixa == 0`) o tratador de áudio desta track.
 *
 * **Desligar escoa o buffer antes de voltar**, e o escoamento chama o tratador **desta thread**
 * (`quall.h`). Como o tratador é `receber_slot_de_audio`, que só encosta na caixa, isso é seguro
 * — mas quer dizer que a caixa pode ganhar slots novos durante a chamada de desligamento. O
 * Kotlin drena o que sobrou depois de `OK` e antes de `audioBoxFree`; se não drenar, o que se
 * perde são os últimos ~40 ms, e o header explica por que isso é pior do que parece.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackOnAudio(JNIEnv *env, jclass cls, jlong track,
                                                     jlong caixa) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    if (caixa == 0) {
        return (jint)quall_track_on_audio(t, NULL, NULL);
    }
    return (jint)quall_track_on_audio(t, receber_slot_de_audio, (void *)(uintptr_t)caixa);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackAudioCodec(JNIEnv *env, jclass cls, jlong track) {
    (void)env;
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL) {
        return 0;
    }
    return (jint)quall_track_audio_codec(t);
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_audioPresetJsonBytes(JNIEnv *env, jclass cls, jint kind,
                                                             jint codec) {
    (void)cls;
    char pilha[PILHA];
    intptr_t n = quall_audio_preset_json((enum QuallTrackKind)kind, (enum QuallAudioCodec)codec,
                                         pilha, sizeof pilha);
    if (n < 0 || (size_t)n > sizeof pilha) {
        return para_bytes(env, "{}");
    }
    return para_bytes(env, pilha);
}

/* ---- decodificador ---------------------------------------------------------------------- */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_audioDecoderNew(JNIEnv *env, jclass cls, jint kind,
                                                        jint codec) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_audio_decoder_new((enum QuallTrackKind)kind,
                                                     (enum QuallAudioCodec)codec);
}

/**
 * Decodifica um slot em PCM intercalado de 16 bits. Devolve amostras **por canal**, ou `-1`.
 *
 * `entrada` nula (ou `tamanho` 0) é a ordem `SILENCE`: vira ocultação de perda. `fec` só pode
 * vir `true` depois de o Kotlin ter conferido `fec_has_lbrr == 1` — a fronteira recusa `fec` com
 * pacote nulo, mas não tem como recusar `fec` sobre um pacote sem LBRR: ali a libopus cai na
 * ocultação de perda **em silêncio** e devolve sucesso.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_audioDecoderDecode(JNIEnv *env, jclass cls, jlong dec,
                                                           jobject entrada, jint deslocamento,
                                                           jint tamanho, jboolean fec,
                                                           jshortArray saida) {
    (void)cls;
    QuallAudioDecoder *d = (QuallAudioDecoder *)(uintptr_t)dec;
    if (d == NULL || saida == NULL) {
        return -1;
    }
    const uint8_t *pacote = NULL;
    if (entrada != NULL && tamanho > 0) {
        uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, entrada);
        jlong capacidade = (*env)->GetDirectBufferCapacity(env, entrada);
        if (base == NULL || deslocamento < 0 ||
            (jlong)deslocamento + (jlong)tamanho > capacidade) {
            LOGE("audioDecoderDecode: fatia inválida (off=%d len=%d)", (int)deslocamento,
                 (int)tamanho);
            return -1;
        }
        pacote = base + deslocamento;
    } else {
        tamanho = 0;
    }

    jsize n = (*env)->GetArrayLength(env, saida);
    jshort *pcm = (*env)->GetShortArrayElements(env, saida, NULL);
    if (pcm == NULL) {
        return -1;
    }
    intptr_t escritas = quall_audio_decoder_decode(d, pacote, (uintptr_t)tamanho,
                                                   fec == JNI_TRUE, (int16_t *)pcm, (size_t)n);
    /* `0` copia de volta e libera; é o modo certo mesmo quando a decodificação falhou, porque
     * `GetShortArrayElements` pode ter devolvido uma cópia. */
    (*env)->ReleaseShortArrayElements(env, saida, pcm, 0);
    return (jint)escritas;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_audioDecoderFree(JNIEnv *env, jclass cls, jlong dec) {
    (void)env;
    (void)cls;
    quall_audio_decoder_free((QuallAudioDecoder *)(uintptr_t)dec);
}

/* ---- encoder e envio -------------------------------------------------------------------- */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_audioEncoderNew(JNIEnv *env, jclass cls, jint kind,
                                                        jint codec) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_audio_encoder_new((enum QuallTrackKind)kind,
                                                     (enum QuallAudioCodec)codec);
}

/**
 * Codifica um quadro de PCM intercalado. `saida` é um `ByteBuffer` **direto** — o mesmo que vai
 * depois para `trackSendAudio`, sem cópia intermediária. Devolve bytes escritos, ou `-1`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_audioEncoderEncode(JNIEnv *env, jclass cls, jlong enc,
                                                           jshortArray pcm, jint amostras,
                                                           jobject saida) {
    (void)cls;
    QuallAudioEncoder *e = (QuallAudioEncoder *)(uintptr_t)enc;
    if (e == NULL || pcm == NULL || saida == NULL) {
        return -1;
    }
    uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, saida);
    jlong capacidade = (*env)->GetDirectBufferCapacity(env, saida);
    if (base == NULL || capacidade <= 0) {
        LOGE("audioEncoderEncode: o ByteBuffer de saída não é direto");
        return -1;
    }
    jsize n = (*env)->GetArrayLength(env, pcm);
    if (amostras < 0 || amostras > n) {
        return -1;
    }
    jshort *entrada = (*env)->GetShortArrayElements(env, pcm, NULL);
    if (entrada == NULL) {
        return -1;
    }
    intptr_t escritos = quall_audio_encoder_encode(e, (const int16_t *)entrada,
                                                   (uintptr_t)amostras, base,
                                                   (uintptr_t)capacidade);
    /* `JNI_ABORT`: a entrada não foi modificada, então não há o que copiar de volta. */
    (*env)->ReleaseShortArrayElements(env, pcm, entrada, JNI_ABORT);
    return (jint)escritos;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_audioEncoderFree(JNIEnv *env, jclass cls, jlong enc) {
    (void)env;
    (void)cls;
    quall_audio_encoder_free((QuallAudioEncoder *)(uintptr_t)enc);
}

/**
 * `enviar_audio` do contrato: **um** quadro codificado por chamada.
 *
 * O pacotizador de áudio da libdatachannel não fragmenta — uma mensagem entra, um pacote RTP sai.
 * Dois quadros de Opus numa chamada viram um pacote que o outro lado decodifica errado **sem erro
 * nenhum no caminho** (`docs/audio.md` §6). Por isso não existe versão em lote desta função.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_trackSendAudio(JNIEnv *env, jclass cls, jlong track,
                                                       jobject buffer, jint deslocamento,
                                                       jint tamanho, jlong timestamp_us) {
    (void)cls;
    const QuallTrack *t = (const QuallTrack *)(uintptr_t)track;
    if (t == NULL || buffer == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    uint8_t *base = (uint8_t *)(*env)->GetDirectBufferAddress(env, buffer);
    jlong capacidade = (*env)->GetDirectBufferCapacity(env, buffer);
    if (base == NULL) {
        LOGE("trackSendAudio: o ByteBuffer não é direto");
        return (jint)QUALL_STATUS_INVALID;
    }
    if (deslocamento < 0 || tamanho <= 0 || capacidade < 0 ||
        (jlong)deslocamento + (jlong)tamanho > capacidade) {
        LOGE("trackSendAudio: fatia inválida (off=%d len=%d cap=%lld)", (int)deslocamento,
             (int)tamanho, (long long)capacidade);
        return (jint)QUALL_STATUS_INVALID;
    }

    /* Zerado antes de preencher: ver `montar_desc`. */
    QuallAudioSample amostra;
    memset(&amostra, 0, sizeof amostra);
    amostra.payload = base + deslocamento;
    amostra.len = (uintptr_t)tamanho;
    amostra.timestamp_us = (uint64_t)timestamp_us;
    return (jint)quall_track_send_audio(t, &amostra);
}

/* ============================================================================================
 * Teleprompter (F6b) — o papel, as mensagens da sessão e a réplica do estado
 * ============================================================================================
 *
 * `docs/contrato-teleprompter.md` §6 e §7. Mesma disciplina do resto do arquivo: **só traduz**.
 * A fusão do estado, os carimbos, o que sai e quando — tudo mora no núcleo
 * (`quall_core::teleprompter`); a política de reconexão e o que a tela faz com cada bit, no
 * Kotlin (`teleprompter/`).
 *
 * - **Nenhum callback.** A bombeada é chamada em laço por uma thread Java (a da sessão); a tela
 *   edita chamando `quall_teleprompter_set_*` da thread dela, e o núcleo manda na hora. Nenhuma
 *   thread da libdatachannel encosta na JVM.
 * - **Texto entra por `byte[]`**, nunca `jstring` (CESU-8, ver o topo): um roteiro terá emoji. E
 *   recusa NUL no meio (`copiar_bytes_sem_nul`), que o C cortaria em silêncio.
 * - **Ponteiros como `jlong`**, `0` = nulo, no molde de `sessionNextTrack`.
 * - **`changed` volta num `int[1]`**, reaproveitado pela casca — um objeto por bombeada seria lixo
 *   a 10 Hz.
 * - `_state_json`, `_text`, `_saved_json` e `_stats_json` pela `POR_BUF_CAP`, que agora **repete
 *   até caber**. `quall_messages_next` **não** passa por ela: o `0` dele é "nada chegou" e o
 *   `n > cap` é "não consumida" — tem o laço próprio logo abaixo.
 */

/*
 * Anúncio com papel. `role` nulo reproduz `quall_advertiser_start` (a fronteira garante); a casca
 * só chama com `"teleprompter"`.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_advertiserStartWithRole(JNIEnv *env, jclass cls,
                                                                jbyteArray device_id,
                                                                jbyteArray display_name,
                                                                jint caps, jint porta,
                                                                jbyteArray role) {
    (void)cls;
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    char *papel = copiar_bytes(env, role);
    jlong saida = 0;
    if (id != NULL && nome != NULL) {
        QuallDeviceDesc me = montar_desc(id, nome, caps);
        saida = (jlong)(uintptr_t)quall_advertiser_start_with_role(&me, (uint16_t)porta, papel);
    }
    free(id);
    free(nome);
    free(papel);
    return saida;
}

/*
 * **Hospeda como teleprompter.** Bloqueia como `hostStart` (até o controle entrar, o prazo estourar
 * ou o cancelador acionar) e é chamada da mesma forma: de uma thread de trabalho, sem região
 * crítica de JNI segurada.
 *
 * `tracks` nulo e `track_count` 0 **pelo `memset`**, e não por esquecimento: um teleprompter não
 * emite track nenhuma, e a fronteira recusa `track_count > 0` com papel (`QUALL_STATUS_INVALID`).
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_hostWithRole(JNIEnv *env, jclass cls,
                                                     jbyteArray device_id,
                                                     jbyteArray display_name, jint caps,
                                                     jbyteArray pin, jbyteArray known_peers_json,
                                                     jint porta, jint timeout_ms,
                                                     jlong canceller_handle, jbyteArray role) {
    (void)cls;
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    char *pin_c = copiar_bytes(env, pin);
    char *known = copiar_bytes(env, known_peers_json); /* pode ser nulo, e nulo é válido */
    char *papel = copiar_bytes(env, role);

    jlong saida = 0;
    if (id != NULL && nome != NULL && pin_c != NULL) {
        QuallSessionOptions opcoes;
        memset(&opcoes, 0, sizeof opcoes);
        opcoes.me = montar_desc(id, nome, caps);
        opcoes.pin = pin_c;
        opcoes.known_peers_json = known;
        opcoes.signaling_port = (uint16_t)porta;
        opcoes.timeout_ms = timeout_ms > 0 ? (uint32_t)timeout_ms : 0u;
        const struct QuallCanceller *cancelador =
            (const struct QuallCanceller *)(uintptr_t)canceller_handle;
        saida = (jlong)(uintptr_t)quall_host_with_role(&opcoes, cancelador, papel);
    } else {
        LOGE("hostWithRole: falta de memória ao copiar as strings");
    }

    free(id);
    free(nome);
    free(pin_c);
    free(known);
    free(papel);
    return saida;
}

/*
 * **Conecta como controle remoto.** Bloqueia como `connectStart`. `pin` nulo é "o par já é
 * conhecido, retome"; `bind_address` nulo é "todas as interfaces" (o produto). Diante de um
 * prompter que já tem controle, sai com `QUALL_STATUS_BUSY` — "tente de novo", nunca queda.
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_connectWithRole(JNIEnv *env, jclass cls,
                                                        jbyteArray endpoint,
                                                        jbyteArray device_id,
                                                        jbyteArray display_name, jint caps,
                                                        jbyteArray pin,
                                                        jbyteArray known_peers_json,
                                                        jint timeout_ms, jlong canceller_handle,
                                                        jbyteArray bind_address,
                                                        jbyteArray role) {
    (void)cls;
    char *destino = copiar_bytes(env, endpoint);
    char *id = copiar_bytes(env, device_id);
    char *nome = copiar_bytes(env, display_name);
    char *pin_c = copiar_bytes(env, pin);              /* pode ser nulo */
    char *known = copiar_bytes(env, known_peers_json); /* idem */
    char *prender = copiar_bytes(env, bind_address);   /* idem */
    char *papel = copiar_bytes(env, role);

    jlong saida = 0;
    if (destino != NULL && id != NULL && nome != NULL) {
        QuallSessionOptions opcoes;
        memset(&opcoes, 0, sizeof opcoes);
        opcoes.me = montar_desc(id, nome, caps);
        opcoes.pin = pin_c;
        opcoes.known_peers_json = known;
        opcoes.timeout_ms = timeout_ms > 0 ? (uint32_t)timeout_ms : 0u;
        opcoes.bind_address = prender;
        const struct QuallCanceller *cancelador =
            (const struct QuallCanceller *)(uintptr_t)canceller_handle;
        saida = (jlong)(uintptr_t)quall_connect_with_role(destino, &opcoes, cancelador, papel);
    } else {
        LOGE("connectWithRole: falta de memória ao copiar as strings");
    }

    free(destino);
    free(id);
    free(nome);
    free(pin_c);
    free(known);
    free(prender);
    free(papel);
    return saida;
}

/* ---- as mensagens da sessão ------------------------------------------------------------- */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_messageMaxBytes(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)quall_message_max_bytes();
}

/* O handle é da casca: libere com `messagesFree`. Sobrevive a `sessionClose` (o header garante). */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_sessionMessages(JNIEnv *env, jclass cls, jlong sessao) {
    (void)env;
    (void)cls;
    const QuallSession *s = (const QuallSession *)(uintptr_t)sessao;
    if (s == NULL) {
        return 0;
    }
    return (jlong)(uintptr_t)quall_session_messages(s);
}

/* Qualquer thread, não bloqueia. `QUALL_STATUS_TRANSPORT` antes de o canal abrir é "tente de novo". */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_messagesSend(JNIEnv *env, jclass cls, jlong handle,
                                                    jbyteArray mensagem) {
    (void)cls;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)handle;
    if (m == NULL || mensagem == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool tinha_nul = false;
    char *s = copiar_bytes_sem_nul(env, mensagem, &tinha_nul);
    if (s == NULL) {
        return (jint)(tinha_nul ? QUALL_STATUS_INVALID : QUALL_STATUS_NULL_POINTER);
    }
    jint st = (jint)quall_messages_send(m, s);
    free(s);
    return st;
}

/*
 * **A próxima mensagem — com o laço próprio que o contrato pede** (§7).
 *
 * `quall_messages_next` não cabe na `POR_BUF_CAP`: lá `0` seria erro, aqui é "nada chegou no
 * prazo"; e `n > cap` aqui quer dizer **"há uma mensagem de `n` bytes, não consumida"** — ela fica
 * na vaga de espiada da sessão e é a primeira da próxima chamada. O laço aloca `n` e chama de novo
 * **com prazo zero** (a mensagem já está lá; esperar de novo seria pagar o prazo duas vezes).
 *
 * `estado[0]` diz o que aconteceu: `1` = mensagem (devolvida), `0` = nada no prazo (devolve nulo),
 * negativo = erro, com o código `QuallStatus` com sinal trocado (`-QUALL_STATUS_CLOSED` quando a
 * sessão acabou e a fila esvaziou). Um leitor por sessão: numa sessão de teleprompter quem lê é a
 * bombeada, e esta função existe para as frentes que usarem o canal fora dele.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_messagesNextBytes(JNIEnv *env, jclass cls, jlong handle,
                                                         jint timeout_ms, jintArray estado) {
    (void)cls;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)handle;
    jint st = 0;
    jbyteArray saida = NULL;
    if (m == NULL) {
        st = -(jint)QUALL_STATUS_NULL_POINTER;
    } else {
        char pilha[PILHA];
        char *buf = pilha;
        size_t cap = sizeof pilha;
        char *heap = NULL;
        uint32_t espera = timeout_ms > 0 ? (uint32_t)timeout_ms : 0u;
        for (int tentativa = 0;; tentativa++) {
            intptr_t n = quall_messages_next(m, espera, buf, (uintptr_t)cap);
            if (n == 0) {
                st = 0;
                break;
            }
            if (n < 0) {
                st = -(jint)quall_last_status();
                break;
            }
            if ((size_t)n <= cap) {
                saida = para_bytes_n(env, buf, strnlen(buf, (size_t)n));
                st = 1;
                break;
            }
            if (tentativa >= TENTATIVAS_ATE_CABER) {
                LOGE("messagesNextBytes: a mensagem de %ld bytes não coube em %d tentativas",
                     (long)n, TENTATIVAS_ATE_CABER);
                st = -(jint)QUALL_STATUS_INVALID;
                break;
            }
            char *maior = (char *)realloc(heap, (size_t)n);
            if (maior == NULL) {
                LOGE("messagesNextBytes: sem memória para %ld bytes", (long)n);
                st = -(jint)QUALL_STATUS_INVALID;
                break;
            }
            heap = maior;
            buf = heap;
            cap = (size_t)n;
            espera = 0;
        }
        free(heap);
    }
    /* `NewByteArray` sem memória deixa uma exceção pendente, e com ela o JNI proíbe qualquer outra
     * chamada (o CheckJNI aborta no debug). A exceção sobe para o Kotlin como `OutOfMemoryError`. */
    if ((*env)->ExceptionCheck(env)) {
        return NULL;
    }
    if (estado != NULL && (*env)->GetArrayLength(env, estado) >= 1) {
        (*env)->SetIntArrayRegion(env, estado, 0, 1, &st);
    }
    return saida;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_messagesStatsJsonBytes(JNIEnv *env, jclass cls,
                                                              jlong handle) {
    (void)cls;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)handle;
    if (m == NULL) {
        return para_bytes(env, "{}");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_messages_stats_json(m, (buf), (cap))
    POR_BUF_CAP(env, saida, "{}", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_messagesFree(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    quall_messages_free((QuallMessages *)(uintptr_t)handle);
}

/* ---- a réplica do teleprompter ---------------------------------------------------------- */

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_teleprompterMaxTextBytes(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)quall_teleprompter_max_text_bytes();
}

/*
 * Nulo com `QUALL_STATUS_INVALID` quando o salvo é ilegível ou de outra versão: a casca chama de
 * novo com `saved_json` nulo (o padrão), como o contrato manda (§3, "Persistência").
 */
JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_teleprompterNew(JNIEnv *env, jclass cls,
                                                       jbyteArray author_id, jbyteArray role,
                                                       jbyteArray saved_json) {
    (void)cls;
    char *autor = copiar_bytes(env, author_id);
    char *papel = copiar_bytes(env, role);
    bool salvo_com_nul = false;
    char *salvo = copiar_bytes_sem_nul(env, saved_json, &salvo_com_nul);
    jlong saida = 0;
    if (autor != NULL && papel != NULL && !salvo_com_nul) {
        saida = (jlong)(uintptr_t)quall_teleprompter_new(autor, papel, salvo);
    }
    free(autor);
    free(papel);
    free(salvo);
    return saida;
}

/* Só depois de ninguém mais usar a réplica — quem garante é `ReplicaDoTeleprompter` (a trava). */
JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_teleprompterFree(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    quall_teleprompter_free((QuallTeleprompter *)(uintptr_t)t);
}

/* Ao **confirmar** a edição, nunca a cada tecla. Texto com NUL no meio: `QUALL_STATUS_INVALID`. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetText(JNIEnv *env, jclass cls, jlong t,
                                                           jbyteArray texto) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL || texto == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool tinha_nul = false;
    char *s = copiar_bytes_sem_nul(env, texto, &tinha_nul);
    if (s == NULL) {
        return (jint)(tinha_nul ? QUALL_STATUS_INVALID : QUALL_STATUS_NULL_POINTER);
    }
    jint st = (jint)quall_teleprompter_set_text(tp, s);
    free(s);
    return st;
}

/* "Segurar para rolar" e a trava da pergunta do texto (docs/contrato-teleprompter.md §12.7, §11.10).
 * Os quatro no molde de set_scrolling: o ponteiro como jlong, 0 = nulo, o QuallStatus de volta. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterEnableHold(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_enable_hold(tp);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterEnableTextQuestion(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_enable_text_question(tp);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterHold(JNIEnv *env, jclass cls, jlong t,
                                                         jboolean backwards) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_hold(tp, backwards == JNI_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterRelease(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_release(tp);
}

/* A gravação (docs/contrato-teleprompter.md §13). No molde de set_scrolling; o motivo da recusa entra
 * por bytes, como o texto, e com NUL no meio é INVALID. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterEnableRecording(JNIEnv *env, jclass cls, jlong t,
                                                                   jboolean enabled) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_enable_recording(tp, enabled == JNI_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetRecording(JNIEnv *env, jclass cls, jlong t,
                                                                jboolean recording) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_recording(tp, recording == JNI_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterRefuseRecording(JNIEnv *env, jclass cls, jlong t,
                                                                   jlong n, jbyteArray motivo) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL || motivo == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool tinha_nul = false;
    char *s = copiar_bytes_sem_nul(env, motivo, &tinha_nul);
    if (s == NULL) {
        return (jint)(tinha_nul ? QUALL_STATUS_INVALID : QUALL_STATUS_NULL_POINTER);
    }
    jint st = (jint)quall_teleprompter_refuse_recording(tp, (uint64_t)n, s);
    free(s);
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterRequestRecord(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_request_record(tp);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterRequestStop(JNIEnv *env, jclass cls, jlong t) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_request_stop(tp);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetScrolling(JNIEnv *env, jclass cls, jlong t,
                                                                jboolean rolando) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_scrolling(tp, rolando == JNI_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetSpeed(JNIEnv *env, jclass cls, jlong t,
                                                            jdouble linhas_por_segundo) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_speed(tp, (double)linhas_por_segundo);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetFontSize(JNIEnv *env, jclass cls, jlong t,
                                                               jdouble pontos) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_font_size(tp, (double)pontos);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetMargin(JNIEnv *env, jclass cls, jlong t,
                                                             jdouble fracao) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_margin(tp, (double)fracao);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetReadingLine(JNIEnv *env, jclass cls,
                                                                  jlong t, jdouble fracao) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_reading_line(tp, (double)fracao);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetMirror(JNIEnv *env, jclass cls, jlong t,
                                                             jboolean espelho) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_mirror(tp, espelho == JNI_TRUE);
}

/* Só o prompter; pode ser chamada a cada quadro — o núcleo limita o envio a 4 Hz. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSetPosition(JNIEnv *env, jclass cls, jlong t,
                                                               jdouble fracao) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_set_position(tp, (double)fracao);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterJump(JNIEnv *env, jclass cls, jlong t,
                                                        jdouble fracao) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_jump(tp, (double)fracao);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterJumpBy(JNIEnv *env, jclass cls, jlong t,
                                                          jdouble delta) {
    (void)env;
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_teleprompter_jump_by(tp, (double)delta);
}

/*
 * **A bombeada.** Devolve o `QuallStatus` e escreve os bits em `changed[0]` — **inclusive quando
 * devolve `QUALL_STATUS_CLOSED`**: a fila foi lida até o fim e a última mensagem do outro lado (a
 * pausa tocada antes da queda) está nesses bits. Quem chama aplica `changed` antes de qualquer
 * outra coisa (§6).
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterPump(JNIEnv *env, jclass cls, jlong t,
                                                        jlong mensagens, jint timeout_ms,
                                                        jintArray changed) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)mensagens;
    uint32_t mudou = 0;
    jint st;
    if (tp == NULL || m == NULL) {
        st = (jint)QUALL_STATUS_NULL_POINTER;
    } else {
        st = (jint)quall_teleprompter_pump(tp, m, timeout_ms > 0 ? (uint32_t)timeout_ms : 0u,
                                           &mudou);
    }
    if (changed != NULL && (*env)->GetArrayLength(env, changed) >= 1) {
        jint v = (jint)mudou;
        (*env)->SetIntArrayRegion(env, changed, 0, 1, &v);
    }
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterPeerLost(JNIEnv *env, jclass cls, jlong t,
                                                            jintArray changed) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    uint32_t mudou = 0;
    jint st;
    if (tp == NULL) {
        st = (jint)QUALL_STATUS_NULL_POINTER;
    } else {
        st = (jint)quall_teleprompter_peer_lost(tp, &mudou);
    }
    if (changed != NULL && (*env)->GetArrayLength(env, changed) >= 1) {
        jint v = (jint)mudou;
        (*env)->SetIntArrayRegion(env, changed, 0, 1, &v);
    }
    return st;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_teleprompterStateJsonBytes(JNIEnv *env, jclass cls,
                                                                  jlong t) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    /* Em falha, **vazio** e não `"{}"`: `"{}"` a casca leria como o estado padrão — `rolando`
     * falso — e pararia o prompter por causa de um erro de leitura (achado da revisão de 13/09).
     * Vazio ela lê como "não há estado" e mantém o que desenhava. */
    if (tp == NULL) {
        return para_bytes(env, "");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_teleprompter_state_json(tp, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}

/* O roteiro inteiro (até 128 KiB): cai no heap da `POR_BUF_CAP`, e repete se ele mudou no meio. */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_teleprompterTextBytes(JNIEnv *env, jclass cls, jlong t) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    /* Em falha, **nulo**: `""` é um roteiro (vazio), e a tela o mostraria no lugar do de verdade. */
    if (tp == NULL) {
        return NULL;
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_teleprompter_text(tp, (buf), (cap))
    POR_BUF_CAP(env, saida, NULL, CHAMAR);
#undef CHAMAR
    return saida;
}

/* ---- A pergunta do texto e as cópias (docs/contrato-teleprompter.md §11.6) ---------------- */

/*
 * A escolha: `keep_mine` falso é "usar o do prompter"; `seen_digest` é o `"resumo"` de
 * `"do_prompter"` **que a tela mostrou**. Um resumo com NUL no meio não é resumo: `INVALID` (em C
 * ele seria cortado ali e viraria outro); nulo segue para o núcleo, que responde `NULL_POINTER`.
 */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterResolveText(JNIEnv *env, jclass cls, jlong t,
                                                               jboolean keep_mine,
                                                               jbyteArray seen_digest) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool tinha_nul = false;
    char *resumo = copiar_bytes_sem_nul(env, seen_digest, &tinha_nul);
    if (tinha_nul) {
        return (jint)QUALL_STATUS_INVALID;
    }
    jint st = (jint)quall_teleprompter_resolve_text(tp, keep_mine == JNI_TRUE, resumo);
    free(resumo);
    return st;
}

/* O texto **do prompter** na pergunta aberta (até 128 KiB); nulo sem pergunta aberta ou em falha. */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_teleprompterQuestionTextBytes(JNIEnv *env, jclass cls,
                                                                     jlong t) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return NULL;
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_teleprompter_question_text(tp, (buf), (cap))
    POR_BUF_CAP(env, saida, NULL, CHAMAR);
#undef CHAMAR
    return saida;
}

/* O texto inteiro de uma cópia, pelo resumo dela; nulo se não está na lista (ou em falha). */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_teleprompterTextCopyBytes(JNIEnv *env, jclass cls,
                                                                 jlong t, jbyteArray digest) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    bool tinha_nul = false;
    char *resumo = copiar_bytes_sem_nul(env, digest, &tinha_nul);
    if (tp == NULL || resumo == NULL) {
        free(resumo);
        return NULL;
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_teleprompter_text_copy(tp, resumo, (buf), (cap))
    POR_BUF_CAP(env, saida, NULL, CHAMAR);
#undef CHAMAR
    free(resumo);
    return saida;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_teleprompterForgetTextCopy(JNIEnv *env, jclass cls, jlong t,
                                                                  jbyteArray digest) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool tinha_nul = false;
    char *resumo = copiar_bytes_sem_nul(env, digest, &tinha_nul);
    if (tinha_nul) {
        return (jint)QUALL_STATUS_INVALID;
    }
    jint st = (jint)quall_teleprompter_forget_text_copy(tp, resumo);
    free(resumo);
    return st;
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_teleprompterSavedJsonBytes(JNIEnv *env, jclass cls,
                                                                  jlong t) {
    (void)cls;
    const QuallTeleprompter *tp = (const QuallTeleprompter *)(uintptr_t)t;
    if (tp == NULL) {
        return para_bytes(env, "");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_teleprompter_saved_json(tp, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}

/* ============================================================================================
 * O controle remoto da câmera (`docs/controle-remoto-da-camera.md`, R9b, 02/10/2026)
 * ============================================================================================
 *
 * As 20 funções de `quall_camera_host_*` (o filmador) e `quall_camera_remote_*` (o receptor), no
 * molde do teleprompter:
 *
 * - **Ponteiros como `jlong`**, `0` = nulo.
 * - **O JSON de entrada por `byte[]`**, nunca `jstring` (o CESU-8 do topo), e recusando NUL no meio
 *   (`copiar_bytes_sem_nul`): um NUL cortaria o JSON em silêncio. NUL no meio → `QUALL_STATUS_INVALID`.
 * - **`_state_json` pela `POR_BUF_CAP`**, que repete até caber (o estado ganha dígitos entre as duas
 *   chamadas: `ha_ms`, os contadores). Em falha, **vazio**: a casca lê vazio como "sem estado" e
 *   mantém o que desenhava.
 * - **`next_request` com laço próprio**, como `messagesNextBytes`: lá o `0` é "fila vazia" (e não
 *   erro), e `n > cap` é "o pedido ainda está na fila, aloque e chame de novo" — ele **só sai da fila
 *   quando coube**. A `POR_BUF_CAP` leria o `0` como falha.
 * - **A bombeada devolve um `jint` só**: os bits de `changed` nos 16 de baixo e o `QuallStatus` nos
 *   de cima (`changed | status << 16`). Os bits são poucos (o filmador usa 2, o receptor 5) e o
 *   status cabe folgado; um `int[]` por bombeada seria lixo a 10 Hz, e o `changed` vem preenchido
 *   **também** com `QUALL_STATUS_CLOSED`, então os dois precisam voltar juntos.
 */

static jint camera_bombeada(QuallStatus st, uint32_t mudou) {
    return (jint)((mudou & 0xFFFFu) | ((uint32_t)st << 16));
}

/*
 * Um JSON obrigatório, para as funções de um texto só. NUL no meio → `INVALID`; nulo (ou sem memória
 * para copiar) → `NULL_POINTER`.
 */
#define COM_JSON(env_, arr_, nome_, st_, CORPO)                                                \
    do {                                                                                      \
        bool nul_ = false;                                                                    \
        char *nome_ = copiar_bytes_sem_nul((env_), (arr_), &nul_);                            \
        if (nome_ == NULL) {                                                                  \
            (st_) = (jint)(nul_ ? QUALL_STATUS_INVALID : QUALL_STATUS_NULL_POINTER);          \
        } else {                                                                              \
            CORPO;                                                                            \
            free(nome_);                                                                      \
        }                                                                                     \
    } while (0)

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_cameraHostNew(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_camera_host_new();
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_cameraHostFree(JNIEnv *env, jclass cls, jlong h) {
    (void)env;
    (void)cls;
    quall_camera_host_free((QuallCameraHost *)(uintptr_t)h);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostSetAllowed(JNIEnv *env, jclass cls, jlong h,
                                                            jboolean permite) {
    (void)env;
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_camera_host_set_allowed(f, permite == JNI_TRUE);
}

/* Os dois nulos = sem câmera (a câmera fechou). Um nulo só, o núcleo recusa com `INVALID`. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostSetCamera(JNIEnv *env, jclass cls, jlong h,
                                                           jbyteArray capacidades,
                                                           jbyteArray ajuste) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    bool nul_c = false;
    bool nul_a = false;
    char *c = copiar_bytes_sem_nul(env, capacidades, &nul_c);
    char *a = copiar_bytes_sem_nul(env, ajuste, &nul_a);
    jint st;
    if (nul_c || nul_a) {
        st = (jint)QUALL_STATUS_INVALID;
    } else if ((capacidades != NULL && c == NULL) || (ajuste != NULL && a == NULL)) {
        st = (jint)QUALL_STATUS_NULL_POINTER; /* sem memória para copiar */
    } else {
        st = (jint)quall_camera_host_set_camera(f, c, a);
    }
    free(c);
    free(a);
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostSetCapabilities(JNIEnv *env, jclass cls, jlong h,
                                                                 jbyteArray capacidades) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, capacidades, c, st, st = (jint)quall_camera_host_set_capabilities(f, c));
    return st;
}

/* `pedido` 0 = mudança feita no filmador; senão o `"n"` que `next_request` entregou. */
JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostSetSettings(JNIEnv *env, jclass cls, jlong h,
                                                             jbyteArray ajuste, jlong pedido) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, ajuste, a, st, st = (jint)quall_camera_host_set_settings(f, a, (uint64_t)pedido));
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostUpdateSettings(JNIEnv *env, jclass cls, jlong h,
                                                                jbyteArray ajuste) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, ajuste, a, st, st = (jint)quall_camera_host_update_settings(f, a));
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostSetRead(JNIEnv *env, jclass cls, jlong h,
                                                         jbyteArray lido) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, lido, l, st, st = (jint)quall_camera_host_set_read(f, l));
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostReject(JNIEnv *env, jclass cls, jlong h,
                                                        jlong pedido, jbyteArray motivo) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, motivo, m, st, st = (jint)quall_camera_host_reject(f, (uint64_t)pedido, m));
    return st;
}

/*
 * **O próximo pedido aceito — com o laço próprio** (ver o topo desta seção). Nulo com a fila vazia
 * (`estado[0] = 0`), o pedido com `estado[0] = 1`, ou nulo com o `QuallStatus` com sinal trocado em
 * `estado[0]`. O pedido que não coube **continua na fila**: o laço aloca e chama de novo.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_cameraHostNextRequestBytes(JNIEnv *env, jclass cls, jlong h,
                                                                  jintArray estado) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    jint st = 0;
    jbyteArray saida = NULL;
    if (f == NULL) {
        st = -(jint)QUALL_STATUS_NULL_POINTER;
    } else {
        char pilha[PILHA];
        char *buf = pilha;
        size_t cap = sizeof pilha;
        char *heap = NULL;
        for (int tentativa = 0;; tentativa++) {
            intptr_t n = quall_camera_host_next_request(f, buf, (uintptr_t)cap);
            if (n == 0) {
                st = 0;
                break;
            }
            if (n < 0) {
                st = -(jint)quall_last_status();
                break;
            }
            if ((size_t)n <= cap) {
                saida = para_bytes_n(env, buf, strnlen(buf, (size_t)n));
                st = 1;
                break;
            }
            if (tentativa >= TENTATIVAS_ATE_CABER) {
                LOGE("cameraHostNextRequestBytes: o pedido de %ld bytes não coube em %d tentativas",
                     (long)n, TENTATIVAS_ATE_CABER);
                st = -(jint)QUALL_STATUS_INVALID;
                break;
            }
            size_t novo = (size_t)n + (size_t)n / 8 + 64;
            char *maior = (char *)realloc(heap, novo);
            if (maior == NULL) {
                LOGE("cameraHostNextRequestBytes: sem memória para %ld bytes", (long)n);
                st = -(jint)QUALL_STATUS_INVALID;
                break;
            }
            heap = maior;
            buf = heap;
            cap = novo;
        }
        free(heap);
    }
    if ((*env)->ExceptionCheck(env)) {
        return NULL;
    }
    if (estado != NULL && (*env)->GetArrayLength(env, estado) >= 1) {
        (*env)->SetIntArrayRegion(env, estado, 0, 1, &st);
    }
    return saida;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostPump(JNIEnv *env, jclass cls, jlong h,
                                                      jlong mensagens, jint timeout_ms) {
    (void)env;
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)mensagens;
    uint32_t mudou = 0;
    QuallStatus st;
    if (f == NULL || m == NULL) {
        st = QUALL_STATUS_NULL_POINTER;
    } else {
        st = quall_camera_host_pump(f, m, timeout_ms > 0 ? (uint32_t)timeout_ms : 0u, &mudou);
    }
    return camera_bombeada(st, mudou);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraHostForget(JNIEnv *env, jclass cls, jlong h,
                                                        jlong mensagens) {
    (void)env;
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)mensagens;
    if (f == NULL || m == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_camera_host_forget(f, m);
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_cameraHostStateJsonBytes(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    const QuallCameraHost *f = (const QuallCameraHost *)(uintptr_t)h;
    if (f == NULL) {
        return para_bytes(env, "");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_camera_host_state_json(f, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}

JNIEXPORT jlong JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteNew(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(uintptr_t)quall_camera_remote_new();
}

JNIEXPORT void JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteFree(JNIEnv *env, jclass cls, jlong r) {
    (void)env;
    (void)cls;
    quall_camera_remote_free((QuallCameraRemote *)(uintptr_t)r);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteRequest(JNIEnv *env, jclass cls, jlong r,
                                                           jbyteArray ajuste) {
    (void)cls;
    const QuallCameraRemote *c = (const QuallCameraRemote *)(uintptr_t)r;
    if (c == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    jint st = 0;
    COM_JSON(env, ajuste, a, st, st = (jint)quall_camera_remote_request(c, a));
    return st;
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteRestore(JNIEnv *env, jclass cls, jlong r) {
    (void)env;
    (void)cls;
    const QuallCameraRemote *c = (const QuallCameraRemote *)(uintptr_t)r;
    if (c == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_camera_remote_restore(c);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteTouch(JNIEnv *env, jclass cls, jlong r,
                                                         jdouble x, jdouble y, jboolean longo) {
    (void)env;
    (void)cls;
    const QuallCameraRemote *c = (const QuallCameraRemote *)(uintptr_t)r;
    if (c == NULL) {
        return (jint)QUALL_STATUS_NULL_POINTER;
    }
    return (jint)quall_camera_remote_touch(c, x, y, longo == JNI_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_quall_android_core_QuallNative_cameraRemotePump(JNIEnv *env, jclass cls, jlong r,
                                                        jlong mensagens, jint timeout_ms) {
    (void)env;
    (void)cls;
    const QuallCameraRemote *c = (const QuallCameraRemote *)(uintptr_t)r;
    const QuallMessages *m = (const QuallMessages *)(uintptr_t)mensagens;
    uint32_t mudou = 0;
    QuallStatus st;
    if (c == NULL || m == NULL) {
        st = QUALL_STATUS_NULL_POINTER;
    } else {
        st = quall_camera_remote_pump(c, m, timeout_ms > 0 ? (uint32_t)timeout_ms : 0u, &mudou);
    }
    return camera_bombeada(st, mudou);
}

JNIEXPORT jbyteArray JNICALL
Java_com_quall_android_core_QuallNative_cameraRemoteStateJsonBytes(JNIEnv *env, jclass cls,
                                                                  jlong r) {
    (void)cls;
    const QuallCameraRemote *c = (const QuallCameraRemote *)(uintptr_t)r;
    if (c == NULL) {
        return para_bytes(env, "");
    }
    jbyteArray saida;
#define CHAMAR(buf, cap) quall_camera_remote_state_json(c, (buf), (cap))
    POR_BUF_CAP(env, saida, "", CHAMAR);
#undef CHAMAR
    return saida;
}
