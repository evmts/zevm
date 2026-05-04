/*
 * zevm - C ABI for the zevm light client.
 *
 * This header exposes a minimal, read-only adapter around the zevm
 * consensus-layer sync engine and the eth_getProof-based execution-layer
 * verifier. It is intended for embedding in non-Zig hosts (Swift, etc.).
 *
 * Threading: every function takes a ZevmHandle. Calls on the same handle
 * are not synchronized internally - the caller must serialize them.
 * Different handles may be used concurrently from different threads.
 *
 * Memory: output buffers are caller-owned. For *_len parameters the caller
 * passes the buffer capacity in bytes, and the function writes the actual
 * number of bytes used. If the buffer is too small the function returns
 * ZEVM_ERR_BUFFER_TOO_SMALL and *out_len is set to the required size.
 *
 * Error strings returned by zevm_light_last_error are owned by the handle
 * and are valid only until the next call on that handle.
 */

#ifndef ZEVM_H
#define ZEVM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZevmHandle ZevmHandle;

/* ABI version for this header/library contract. Increment on breaking changes. */
#define ZEVM_ABI_VERSION 1

/* Network selectors. */
#define ZEVM_NETWORK_MAINNET 0
#define ZEVM_NETWORK_SEPOLIA 1
#define ZEVM_NETWORK_HOLESKY 2

/* Return codes. */
#define ZEVM_OK                  0
#define ZEVM_ERR_INVALID_ARG     1
#define ZEVM_ERR_NOT_SYNCED      2
#define ZEVM_ERR_BUFFER_TOO_SMALL 3
#define ZEVM_ERR_NETWORK         4
#define ZEVM_ERR_PROOF           5
#define ZEVM_ERR_BLOCK_UNAVAILABLE 6
#define ZEVM_ERR_INTERNAL        7

/* Sync status values returned by zevm_light_status. */
#define ZEVM_STATUS_NOT_SYNCED 0
#define ZEVM_STATUS_SYNCING    1
#define ZEVM_STATUS_SYNCED     2

/* Return the numeric C ABI version implemented by the loaded library. */
uint32_t zevm_abi_version(void);

/* Return the ZEVM package version string implemented by the loaded library. */
const char* zevm_version(void);

/* Return a stable static string for a ZEVM_* return code. */
const char* zevm_error_message(int code);

/* Return "mainnet", "sepolia", or "holesky"; NULL for unknown networks. */
const char* zevm_light_network_name(int network);

/*
 * Initialize a light client handle.
 *
 *   network          one of ZEVM_NETWORK_* (mainnet/sepolia/holesky)
 *   beacon_rpc_url   null-terminated consensus-layer RPC endpoint
 *   execution_rpc_url null-terminated execution-layer RPC endpoint
 *                    (used for eth_getProof / eth_getCode lookups)
 *
 * Returns NULL on allocation failure or invalid network. The handle must
 * be released with zevm_light_shutdown.
 */
ZevmHandle* zevm_light_init(
    int network,
    const char* beacon_rpc_url,
    const char* execution_rpc_url);

/* Release a handle. Safe to call with NULL. */
void zevm_light_shutdown(ZevmHandle* handle);

/*
 * Drive one tick of the consensus sync state machine.
 *
 * BLOCKING: this function performs synchronous HTTP requests to the
 * configured beacon RPC. Callers should invoke it from a background
 * thread or a timer that does not block the UI.
 *
 * The first call performs the bootstrap (using the network's default
 * checkpoint) plus an initial finality/optimistic update. Subsequent
 * calls run the engine's `advance` step.
 *
 * Returns ZEVM_OK on success, otherwise an error code; details available
 * via zevm_light_last_error.
 */
int zevm_light_sync_step(ZevmHandle* handle);

/*
 * Read a verified account balance.
 *
 *   address_hex   null-terminated 0x-prefixed 20-byte address
 *   block_number  pass 0 to use the latest verified head; otherwise the
 *                 number must match the currently verified optimistic or
 *                 finalized header (other blocks return
 *                 ZEVM_ERR_BLOCK_UNAVAILABLE)
 *   out_hex       buffer that receives the balance as a 0x-prefixed
 *                 lowercase hex string (no leading zero padding)
 *   out_len       on input: capacity of out_hex in bytes (must include
 *                 room for a NUL terminator); on output: number of bytes
 *                 written, including the NUL terminator
 *
 * 80 bytes is always sufficient for the balance string.
 */
int zevm_light_get_balance(
    ZevmHandle* handle,
    const char* address_hex,
    uint64_t block_number,
    char* out_hex,
    size_t* out_len);

/*
 * Read a verified account transaction count / nonce.
 *
 *   out_count receives the account nonce as an unsigned 64-bit integer.
 */
int zevm_light_get_transaction_count(
    ZevmHandle* handle,
    const char* address_hex,
    uint64_t block_number,
    uint64_t* out_count);

/*
 * Read verified contract code.
 *
 *   out_buf  receives the raw code bytes
 *   out_len  on input: capacity; on output: number of bytes written
 *
 * Returns ZEVM_ERR_BUFFER_TOO_SMALL with the required capacity in
 * *out_len if the buffer is undersized.
 */
int zevm_light_get_code(
    ZevmHandle* handle,
    const char* address_hex,
    uint64_t block_number,
    uint8_t* out_buf,
    size_t* out_len);

/*
 * Read a verified storage slot.
 *
 *   slot_hex  null-terminated 0x-prefixed slot key (any width)
 *   out_hex   receives the value as a 0x-prefixed 64-hex-digit string
 *             (zero-padded to 32 bytes). 67 bytes is always sufficient.
 */
int zevm_light_get_storage(
    ZevmHandle* handle,
    const char* address_hex,
    const char* slot_hex,
    uint64_t block_number,
    char* out_hex,
    size_t* out_len);

/* Returns ZEVM_STATUS_*; never returns an error. */
int zevm_light_status(ZevmHandle* handle);

/*
 * Returns the last error message recorded on this handle, or "" if no
 * error has been recorded. The returned pointer remains valid only
 * until the next call on this handle.
 */
const char* zevm_light_last_error(ZevmHandle* handle);

#ifdef __cplusplus
}
#endif

#endif /* ZEVM_H */
