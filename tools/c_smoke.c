/*
 * Linkage smoke test for libzevm. Initializes a handle with a bogus
 * URL, prints status, then shuts it down. Exits 0 on success.
 *
 * The point is to prove that:
 *   1. zig-out/lib/libzevm.a links cleanly with a plain C program.
 *   2. The exported symbols (init / status / shutdown / last_error)
 *      are reachable from C.
 * No network I/O is performed; sync_step is intentionally not called.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zevm.h"

int main(void) {
    ZevmHandle* h = zevm_light_init(
        ZEVM_NETWORK_MAINNET,
        "http://127.0.0.1:0/bogus-beacon",
        "http://127.0.0.1:0/bogus-execution"
    );
    if (h == NULL) {
        fprintf(stderr, "zevm_light_init returned NULL\n");
        return 1;
    }

    int status = zevm_light_status(h);
    const char* err = zevm_light_last_error(h);
    printf("status=%d last_error=\"%s\"\n", status, err ? err : "(null)");

    zevm_light_shutdown(h);

    /* Calling shutdown(NULL) must be a no-op. */
    zevm_light_shutdown(NULL);

    printf("ok\n");
    return 0;
}
