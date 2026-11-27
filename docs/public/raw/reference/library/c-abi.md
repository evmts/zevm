# C ABI

# C ABI

The ZEVM C ABI exposes an in-memory execution node and the proof-verified light client through `libzevm` and `zevm.h`. Reach for it when embedding ZEVM in C, C++, Swift, or another host that can call a C-compatible library.

## Working example

This program was compiled and run against the libraries produced by `zig build c-ffi`.

```c
#include <stdio.h>
#include "zevm.h"

int main(void) {
    if (zevm_abi_version() != ZEVM_ABI_VERSION) {
        return 1;
    }
    printf("abi=%u\n", zevm_abi_version());
    printf("version=%s\n", zevm_version());
    printf("network=%s\n", zevm_light_network_name(ZEVM_NETWORK_MAINNET));
    printf("error=%s\n", zevm_error_message(ZEVM_ERR_NOT_SYNCED));
    return 0;
}
```

```bash
zig build c-ffi
cc example.c -I zig-out/include -L zig-out/lib -lzevm -Wl,-rpath,zig-out/lib -o example
./example
```

```text
abi=1
version=0.1.0
network=mainnet
error=light client is not synced
```

## ABI surface

The authoritative declarations are in [`include/zevm.h`](https://github.com/evmts/zevm/blob/main/include/zevm.h).

| Function | Purpose |
| --- | --- |
| `zevm_abi_version` | Return `ZEVM_ABI_VERSION`. |
| `zevm_version` | Return the package version string. |
| `zevm_error_message` | Map a `ZEVM_ERR_*` code to a static string. |
| `zevm_light_network_name` | Map a `ZEVM_NETWORK_*` selector to its name. |
| `zevm_node_create` | Create an in-memory execution node from a JSON config object with optional `chain_id`; `NULL` uses defaults. |
| `zevm_node_rpc` | Execute one JSON-RPC request or batch exactly once and return a caller-owned response buffer. |
| `zevm_node_free_response` | Release a buffer returned by `zevm_node_rpc`. |
| `zevm_node_destroy` | Release a node and all of its state. |
| `zevm_light_init` | Allocate a mainnet, Sepolia, or Holesky light-client handle. |
| `zevm_light_shutdown` | Release a handle. |
| `zevm_light_sync_step` | Advance bootstrap or consensus sync by one blocking step. |
| `zevm_light_get_balance` | Read a proof-verified balance. |
| `zevm_light_get_transaction_count` | Read a proof-verified account nonce. |
| `zevm_light_get_code` | Read proof-verified contract code. |
| `zevm_light_get_storage` | Read a proof-verified storage slot. |
| `zevm_light_status` | Return `NOT_SYNCED`, `SYNCING`, or `SYNCED`. |
| `zevm_light_last_error` | Read the last handle-owned error string. |

Output buffers are caller-owned. Calls using the same handle or node must be serialized by the host. `zevm_node_rpc` returns `NULL` with length zero for notifications; JSON-RPC errors arrive as JSON responses, and a nonzero return code means an ABI failure.

## Neighbours

[Light mode](../../concepts/light-mode) · [Verified light-mode reads](../json-rpc/verified-light-mode-reads) · [Installation](../../quickstart/installation)
