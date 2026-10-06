/* CLI fixture: actual constructor/capability setup and unchanged OS-backed RNG.
 * Build against the guarded static prefix. No capability/provider/RNG override.
 */
#include <openssl/crypto.h>
#include <openssl/rand.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <unistd.h>

extern unsigned int OPENSSL_armcap_P;

int main(void) {
    unsigned long hwcap = getauxval(AT_HWCAP);
    unsigned long hwcap2 = getauxval(AT_HWCAP2);
    int base_sve = !!(hwcap & (1UL << 22));
    int sve2 = !!(hwcap2 & (1UL << 1));
    unsigned char random[32] = {0};
    int initialized = OPENSSL_init_crypto(0, NULL);
    int rng_ok = initialized == 1 && RAND_status() == 1 && RAND_bytes(random, sizeof(random)) == 1;
    OPENSSL_cleanse(random, sizeof(random));
    int selected_base = !!(OPENSSL_armcap_P & (1U << 13));
    int selected_sve2 = !!(OPENSSL_armcap_P & (1U << 14));
    int guard_ok = selected_sve2 == (base_sve && sve2) && selected_base == base_sve;
    printf("{\"pageSize\":%ld,\"hwcap\":\"0x%lx\",\"hwcap2\":\"0x%lx\","
           "\"baseSVE\":%s,\"advertisedSVE2\":%s,\"selectedSVE2\":%s,"
           "\"initPassed\":%s,\"rngPassed\":%s,\"guardPassed\":%s}\n",
           sysconf(_SC_PAGESIZE), hwcap, hwcap2, base_sve ? "true" : "false",
           sve2 ? "true" : "false", selected_sve2 ? "true" : "false",
           initialized == 1 ? "true" : "false", rng_ok ? "true" : "false", guard_ok ? "true" : "false");
    return initialized == 1 && rng_ok && guard_ok ? 0 : 1;
}
