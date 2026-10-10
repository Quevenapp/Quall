/* CLI-only native loader fixture. Pass libc++_shared.so and libquall.so paths.
 * No Activity, pairing, media, socket, user data or capability/RNG override.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <unistd.h>

typedef uint16_t (*protocol_fn)(void);
typedef intptr_t (*pin_fn)(char *, uintptr_t);

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    printf("{\"stage\":\"beforeDlopen\",\"pageSize\":%ld,\"hwcap\":\"0x%lx\",\"hwcap2\":\"0x%lx\"}\n",
           sysconf(_SC_PAGESIZE), getauxval(AT_HWCAP), getauxval(AT_HWCAP2));
    fflush(stdout);
    void *cpp = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!cpp) { fprintf(stderr, "libc++ load failed: %s\n", dlerror()); return 3; }
    void *core = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!core) { fprintf(stderr, "core load failed: %s\n", dlerror()); return 4; }
    protocol_fn version = (protocol_fn)dlsym(core, "quall_protocol_version");
    pin_fn generate = (pin_fn)dlsym(core, "quall_generate_pin");
    if (!version || !generate) return 5;
    char pin[8] = {0};
    intptr_t size = generate(pin, sizeof(pin));
    int valid = size == 7 && pin[6] == 0;
    for (int i = 0; i < 6; ++i) valid = valid && pin[i] >= '0' && pin[i] <= '9';
    volatile char *wipe = pin;
    for (unsigned i = 0; i < sizeof(pin); ++i) wipe[i] = 0;
    uint16_t protocol = version();
    printf("{\"stage\":\"loaded\",\"protocolVersion\":%u,\"pinGenerationPassed\":%s}\n",
           protocol, valid ? "true" : "false");
    dlclose(core);
    dlclose(cpp);
    return protocol == 3 && valid ? 0 : 6;
}
