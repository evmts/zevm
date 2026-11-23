#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "node_api_subset.h"
#include "zevm.h"

/* Node-API 8 type tags. Declared here because node_api_subset.h predates
 * them. Tags let the addon reject Externals created by other addons, which
 * would otherwise be reinterpreted as ZEVM wrappers (type confusion). */
typedef struct {
  uint64_t lower;
  uint64_t upper;
} zevm_napi_type_tag;
extern napi_status napi_type_tag_object(napi_env env, napi_value value, const zevm_napi_type_tag* type_tag);
extern napi_status napi_check_object_type_tag(napi_env env, napi_value value, const zevm_napi_type_tag* type_tag, bool* result);

#define ZEVM_NAPI_AUTO_LENGTH ((size_t)-1)
#define ZEVM_MAX_SAFE_JS_INTEGER 9007199254740991.0

/* zevm_light_get_balance documents 80 bytes as always sufficient. */
#define ZEVM_BALANCE_BUFFER_LEN 80
/* zevm_light_get_storage documents 67 bytes as always sufficient. */
#define ZEVM_STORAGE_BUFFER_LEN 67
/* Covers EIP-170 code (24 KiB). Larger code retries once at the exact size. */
#define ZEVM_CODE_BUFFER_LEN (32 * 1024)

static const zevm_napi_type_tag ZEVM_LIGHT_HANDLE_TAG = {0x7a65766d6c696768ULL, 0x9d3c51f0a2e84b17ULL};
static const zevm_napi_type_tag ZEVM_NODE_HANDLE_TAG = {0x7a65766d6e6f6465ULL, 0x4be2a7c90d613f58ULL};

typedef struct {
  ZevmHandle* handle;
} ZevmNativeHandle;

typedef struct {
  ZevmNode* node;
} ZevmExecutionHandle;

/* Throwing is the last action on a failure path. If the throw itself fails an
 * exception is already pending, and there is nothing further to report. */
static void throw_error(napi_env env, const char* code, const char* message) {
  napi_status status = napi_throw_error(env, code, message);
  (void)status;
}

static void throw_type_error(napi_env env, const char* code, const char* message) {
  napi_status status = napi_throw_type_error(env, code, message);
  (void)status;
}

static void throw_status(napi_env env, napi_status status, const char* context) {
  if (status == napi_pending_exception) return;
  char message[160];
  snprintf(message, sizeof(message), "%s failed with napi_status=%d", context, (int)status);
  throw_error(env, "ZEVM_NAPI_ERROR", message);
}

static void throw_zevm(napi_env env, ZevmHandle* handle, int code) {
  const char* last_error = handle == NULL ? NULL : zevm_light_last_error(handle);
  const char* fallback = zevm_error_message(code);
  throw_error(env, "ZEVM_ERROR", (last_error != NULL && last_error[0] != 0) ? last_error : fallback);
}

/* Returning NULL from a Node-API callback yields `undefined` in JS.
 * Callers must evaluate the napi_* call in a separate statement before calling
 * `checked`: C leaves argument evaluation order unspecified, so passing the
 * call and its out-parameter as sibling arguments may read `value` before it
 * is written. */
static napi_value checked(napi_env env, napi_status status, napi_value value, const char* context) {
  if (status != napi_ok) {
    throw_status(env, status, context);
    return NULL;
  }
  return value;
}

static napi_value make_int32(napi_env env, int32_t value) {
  napi_value result = NULL;
  napi_status status = napi_create_int32(env, value, &result);
  return checked(env, status, result, "napi_create_int32");
}

static napi_value make_string(napi_env env, const char* text, size_t len) {
  napi_value result = NULL;
  napi_status status = napi_create_string_utf8(env, text, len, &result);
  return checked(env, status, result, "napi_create_string_utf8");
}

static napi_value make_null(napi_env env) {
  napi_value result = NULL;
  napi_status status = napi_get_null(env, &result);
  return checked(env, status, result, "napi_get_null");
}

static bool get_args(napi_env env, napi_callback_info info, size_t expected, napi_value* argv) {
  size_t argc = expected;
  napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (status != napi_ok) {
    throw_status(env, status, "napi_get_cb_info");
    return false;
  }
  if (argc < expected) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "missing required argument");
    return false;
  }
  return true;
}

static bool get_type(napi_env env, napi_value value, napi_valuetype* out) {
  napi_status status = napi_typeof(env, value, out);
  if (status != napi_ok) {
    throw_status(env, status, "napi_typeof");
    return false;
  }
  return true;
}

static bool get_int32(napi_env env, napi_value value, int32_t* out) {
  napi_valuetype type;
  if (!get_type(env, value, &type)) return false;
  if (type != napi_number) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a number");
    return false;
  }
  napi_status status = napi_get_value_int32(env, value, out);
  if (status != napi_ok) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a number");
    return false;
  }
  return true;
}

/* Reads a ZEVM_NETWORK_* selector. napi_get_value_int32 coerces NaN and
 * Infinity to 0 (mainnet) and truncates fractions, so validate the double. */
static bool get_network(napi_env env, napi_value value, int32_t* out) {
  napi_valuetype type;
  if (!get_type(env, value, &type)) return false;
  if (type != napi_number) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "network must be a number");
    return false;
  }
  double number = 0;
  napi_status status = napi_get_value_double(env, value, &number);
  if (status != napi_ok || !isfinite(number) || floor(number) != number || number < (double)INT32_MIN ||
      number > (double)INT32_MAX) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "network must be an integer ZEVM_NETWORK_* value");
    return false;
  }
  *out = (int32_t)number;
  return true;
}

static bool get_uint64(napi_env env, napi_value value, uint64_t* out) {
  napi_valuetype type;
  if (!get_type(env, value, &type)) return false;
  if (type == napi_bigint) {
    bool lossless = false;
    napi_status status = napi_get_value_bigint_uint64(env, value, out, &lossless);
    if (status != napi_ok || !lossless) {
      throw_type_error(env, "ZEVM_INVALID_ARG", "expected a lossless unsigned bigint");
      return false;
    }
    return true;
  }
  if (type == napi_number) {
    double number = 0;
    napi_status status = napi_get_value_double(env, value, &number);
    if (status != napi_ok || number < 0 || floor(number) != number || number > ZEVM_MAX_SAFE_JS_INTEGER) {
      throw_type_error(env, "ZEVM_INVALID_ARG", "expected an unsigned safe-integer block number or bigint");
      return false;
    }
    *out = (uint64_t)number;
    return true;
  }
  throw_type_error(env, "ZEVM_INVALID_ARG", "expected a number or bigint");
  return false;
}

/* Copies a JS string into a malloc'd NUL-terminated UTF-8 buffer. Strings with
 * embedded NUL bytes are rejected: the C ABI would silently truncate them. */
static bool get_string(napi_env env, napi_value value, char** out, size_t* out_len) {
  napi_valuetype type;
  if (!get_type(env, value, &type)) return false;
  if (type != napi_string) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a string");
    return false;
  }
  size_t len = 0;
  napi_status status = napi_get_value_string_utf8(env, value, NULL, 0, &len);
  if (status != napi_ok) {
    throw_status(env, status, "napi_get_value_string_utf8");
    return false;
  }
  char* buffer = (char*)malloc(len + 1);
  if (buffer == NULL) {
    throw_error(env, "ZEVM_OOM", "allocation failed");
    return false;
  }
  size_t copied = 0;
  status = napi_get_value_string_utf8(env, value, buffer, len + 1, &copied);
  if (status != napi_ok) {
    free(buffer);
    throw_status(env, status, "napi_get_value_string_utf8");
    return false;
  }
  buffer[copied] = 0;
  if (copied != len || strlen(buffer) != copied) {
    free(buffer);
    throw_type_error(env, "ZEVM_INVALID_ARG", "string arguments must not contain NUL bytes");
    return false;
  }
  *out = buffer;
  if (out_len != NULL) *out_len = copied;
  return true;
}

/* Returns the External's data only if this addon created and tagged it. */
static bool get_tagged_external(napi_env env, napi_value value, const zevm_napi_type_tag* tag, void** out) {
  napi_valuetype type;
  if (!get_type(env, value, &type)) return false;
  if (type != napi_external) return false;
  bool tagged = false;
  napi_status status = napi_check_object_type_tag(env, value, tag, &tagged);
  if (status != napi_ok) {
    throw_status(env, status, "napi_check_object_type_tag");
    return false;
  }
  if (!tagged) return false;
  status = napi_get_value_external(env, value, out);
  if (status != napi_ok) {
    throw_status(env, status, "napi_get_value_external");
    return false;
  }
  return *out != NULL;
}

/* Wraps data in a tagged External. On failure after the External exists, the
 * finalizer owns `data` and runs when the unreachable External is collected. */
static napi_value make_tagged_external(napi_env env, void* data, napi_finalize finalize_cb, const zevm_napi_type_tag* tag) {
  napi_value result = NULL;
  napi_status status = napi_create_external(env, data, finalize_cb, NULL, &result);
  if (status != napi_ok) {
    finalize_cb(env, data, NULL);
    throw_status(env, status, "napi_create_external");
    return NULL;
  }
  status = napi_type_tag_object(env, result, tag);
  if (status != napi_ok) {
    throw_status(env, status, "napi_type_tag_object");
    return NULL;
  }
  return result;
}

static bool get_handle(napi_env env, napi_value value, ZevmNativeHandle** out) {
  void* raw = NULL;
  if (!get_tagged_external(env, value, &ZEVM_LIGHT_HANDLE_TAG, &raw)) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a ZEVM light client handle");
    return false;
  }
  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)raw;
  if (wrapper->handle == NULL) {
    throw_error(env, "ZEVM_CLOSED", "light client is closed");
    return false;
  }
  *out = wrapper;
  return true;
}

static void finalize_handle(napi_env env, void* data, void* hint) {
  (void)env;
  (void)hint;
  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)data;
  if (wrapper != NULL) {
    if (wrapper->handle != NULL) {
      zevm_light_shutdown(wrapper->handle);
    }
    free(wrapper);
  }
}

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Parses "0x" + 64 hex digits into 32 bytes. */
static bool parse_checkpoint_hex(const char* text, size_t len, uint8_t out[ZEVM_CHECKPOINT_LEN]) {
  if (len != 2 + ZEVM_CHECKPOINT_LEN * 2 || text[0] != '0' || (text[1] != 'x' && text[1] != 'X')) return false;
  for (size_t i = 0; i < ZEVM_CHECKPOINT_LEN; i++) {
    int high = hex_nibble(text[2 + i * 2]);
    int low = hex_nibble(text[3 + i * 2]);
    if (high < 0 || low < 0) return false;
    out[i] = (uint8_t)((high << 4) | low);
  }
  return true;
}

static napi_value abi_version(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = NULL;
  napi_status status = napi_create_uint32(env, zevm_abi_version(), &result);
  return checked(env, status, result, "napi_create_uint32");
}

static napi_value version(napi_env env, napi_callback_info info) {
  (void)info;
  return make_string(env, zevm_version(), ZEVM_NAPI_AUTO_LENGTH);
}

static napi_value error_message(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  int32_t code = 0;
  if (!get_int32(env, argv[0], &code)) return NULL;
  return make_string(env, zevm_error_message(code), ZEVM_NAPI_AUTO_LENGTH);
}

static napi_value network_name(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  int32_t network = 0;
  if (!get_network(env, argv[0], &network)) return NULL;
  const char* name = zevm_light_network_name(network);
  if (name == NULL) return make_null(env);
  return make_string(env, name, ZEVM_NAPI_AUTO_LENGTH);
}

static napi_value wrap_light_handle(napi_env env, ZevmHandle* handle) {
  if (handle == NULL) {
    throw_error(env, "ZEVM_INIT_FAILED", "zevm_light_init failed (unknown network, empty URL, or all-zero checkpoint)");
    return NULL;
  }
  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)malloc(sizeof(ZevmNativeHandle));
  if (wrapper == NULL) {
    zevm_light_shutdown(handle);
    throw_error(env, "ZEVM_OOM", "allocation failed");
    return NULL;
  }
  wrapper->handle = handle;
  return make_tagged_external(env, wrapper, finalize_handle, &ZEVM_LIGHT_HANDLE_TAG);
}

/* lightInit(network, beaconUrl, executionUrl) */
static napi_value light_init(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return NULL;

  int32_t network = 0;
  char* beacon = NULL;
  char* execution = NULL;
  if (!get_network(env, argv[0], &network)) return NULL;
  if (!get_string(env, argv[1], &beacon, NULL)) return NULL;
  if (!get_string(env, argv[2], &execution, NULL)) {
    free(beacon);
    return NULL;
  }

  ZevmHandle* handle = zevm_light_init(network, beacon, execution);
  free(beacon);
  free(execution);
  return wrap_light_handle(env, handle);
}

/* lightInitEx(network, beaconUrl, executionUrl, checkpointHex | null, strictCheckpointAge) */
static napi_value light_init_ex(napi_env env, napi_callback_info info) {
  napi_value argv[5];
  if (!get_args(env, info, 5, argv)) return NULL;

  int32_t network = 0;
  int32_t strict = 0;
  if (!get_network(env, argv[0], &network)) return NULL;
  if (!get_int32(env, argv[4], &strict)) return NULL;

  uint8_t checkpoint[ZEVM_CHECKPOINT_LEN];
  bool has_checkpoint = false;
  napi_valuetype checkpoint_type;
  if (!get_type(env, argv[3], &checkpoint_type)) return NULL;
  if (checkpoint_type != napi_null && checkpoint_type != napi_undefined) {
    char* checkpoint_hex = NULL;
    size_t checkpoint_hex_len = 0;
    if (!get_string(env, argv[3], &checkpoint_hex, &checkpoint_hex_len)) return NULL;
    bool valid = parse_checkpoint_hex(checkpoint_hex, checkpoint_hex_len, checkpoint);
    free(checkpoint_hex);
    if (!valid) {
      throw_type_error(env, "ZEVM_INVALID_ARG", "checkpoint must be a 0x-prefixed 32-byte hex string");
      return NULL;
    }
    has_checkpoint = true;
  }

  char* beacon = NULL;
  char* execution = NULL;
  if (!get_string(env, argv[1], &beacon, NULL)) return NULL;
  if (!get_string(env, argv[2], &execution, NULL)) {
    free(beacon);
    return NULL;
  }

  ZevmHandle* handle = zevm_light_init_ex(network, beacon, execution, has_checkpoint ? checkpoint : NULL, strict != 0);
  free(beacon);
  free(execution);
  return wrap_light_handle(env, handle);
}

static napi_value light_shutdown(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  void* raw = NULL;
  if (!get_tagged_external(env, argv[0], &ZEVM_LIGHT_HANDLE_TAG, &raw)) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a ZEVM light client handle");
    return NULL;
  }
  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)raw;
  if (wrapper->handle != NULL) {
    zevm_light_shutdown(wrapper->handle);
    wrapper->handle = NULL;
  }
  return NULL;
}

static napi_value light_sync_step(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  return make_int32(env, zevm_light_sync_step(wrapper->handle));
}

static napi_value light_status(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  return make_int32(env, zevm_light_status(wrapper->handle));
}

static napi_value light_last_error(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  const char* message = zevm_light_last_error(wrapper->handle);
  return make_string(env, message == NULL ? "" : message, ZEVM_NAPI_AUTO_LENGTH);
}

/* Returns the latest verified checkpoint as a 0x-prefixed hex string. */
static napi_value light_get_checkpoint(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;

  uint8_t checkpoint[ZEVM_CHECKPOINT_LEN];
  int code = zevm_light_get_checkpoint(wrapper->handle, checkpoint);
  if (code != ZEVM_OK) {
    throw_zevm(env, wrapper->handle, code);
    return NULL;
  }
  static const char alphabet[] = "0123456789abcdef";
  char hex[2 + ZEVM_CHECKPOINT_LEN * 2];
  hex[0] = '0';
  hex[1] = 'x';
  for (size_t i = 0; i < ZEVM_CHECKPOINT_LEN; i++) {
    hex[2 + i * 2] = alphabet[checkpoint[i] >> 4];
    hex[3 + i * 2] = alphabet[checkpoint[i] & 0x0f];
  }
  return make_string(env, hex, sizeof(hex));
}

static napi_value light_get_balance(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  if (!get_uint64(env, argv[2], &block_number)) return NULL;
  if (!get_string(env, argv[1], &address, NULL)) return NULL;

  /* One network round trip: the buffer is always large enough. */
  char out[ZEVM_BALANCE_BUFFER_LEN];
  size_t len = sizeof(out);
  int code = zevm_light_get_balance(wrapper->handle, address, block_number, out, &len);
  free(address);
  if (code != ZEVM_OK) {
    throw_zevm(env, wrapper->handle, code);
    return NULL;
  }
  return make_string(env, out, len - 1);
}

static napi_value light_get_transaction_count(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  uint64_t count = 0;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  if (!get_uint64(env, argv[2], &block_number)) return NULL;
  if (!get_string(env, argv[1], &address, NULL)) return NULL;
  int code = zevm_light_get_transaction_count(wrapper->handle, address, block_number, &count);
  free(address);
  if (code != ZEVM_OK) {
    throw_zevm(env, wrapper->handle, code);
    return NULL;
  }
  napi_value result = NULL;
  napi_status status = napi_create_bigint_uint64(env, count, &result);
  return checked(env, status, result, "napi_create_bigint_uint64");
}

static napi_value light_get_code(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  if (!get_uint64(env, argv[2], &block_number)) return NULL;
  if (!get_string(env, argv[1], &address, NULL)) return NULL;

  size_t capacity = ZEVM_CODE_BUFFER_LEN;
  uint8_t* out = (uint8_t*)malloc(capacity);
  if (out == NULL) {
    free(address);
    throw_error(env, "ZEVM_OOM", "allocation failed");
    return NULL;
  }
  size_t len = capacity;
  int code = zevm_light_get_code(wrapper->handle, address, block_number, out, &len);
  if (code == ZEVM_ERR_BUFFER_TOO_SMALL) {
    /* Only oversized code pays for a second fetch, at the exact size. */
    free(out);
    capacity = len;
    out = (uint8_t*)malloc(capacity);
    if (out == NULL) {
      free(address);
      throw_error(env, "ZEVM_OOM", "allocation failed");
      return NULL;
    }
    len = capacity;
    code = zevm_light_get_code(wrapper->handle, address, block_number, out, &len);
  }
  free(address);
  if (code != ZEVM_OK) {
    free(out);
    throw_zevm(env, wrapper->handle, code);
    return NULL;
  }
  napi_value result = NULL;
  void* copied = NULL;
  napi_status status = napi_create_buffer_copy(env, len, out, &copied, &result);
  free(out);
  return checked(env, status, result, "napi_create_buffer_copy");
}

static napi_value light_get_storage(napi_env env, napi_callback_info info) {
  napi_value argv[4];
  if (!get_args(env, info, 4, argv)) return NULL;
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  char* slot = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return NULL;
  if (!get_uint64(env, argv[3], &block_number)) return NULL;
  if (!get_string(env, argv[1], &address, NULL)) return NULL;
  if (!get_string(env, argv[2], &slot, NULL)) {
    free(address);
    return NULL;
  }

  /* One network round trip: the buffer is always large enough. */
  char out[ZEVM_STORAGE_BUFFER_LEN];
  size_t len = sizeof(out);
  int code = zevm_light_get_storage(wrapper->handle, address, slot, block_number, out, &len);
  free(address);
  free(slot);
  if (code != ZEVM_OK) {
    throw_zevm(env, wrapper->handle, code);
    return NULL;
  }
  return make_string(env, out, len - 1);
}

static void finalize_node(napi_env env, void* data, void* hint) {
  (void)env;
  (void)hint;
  ZevmExecutionHandle* wrapper = (ZevmExecutionHandle*)data;
  if (wrapper != NULL) {
    zevm_node_destroy(wrapper->node);
    free(wrapper);
  }
}

static ZevmExecutionHandle* execution_handle(napi_env env, napi_value value) {
  void* raw = NULL;
  if (!get_tagged_external(env, value, &ZEVM_NODE_HANDLE_TAG, &raw)) {
    throw_type_error(env, "ZEVM_INVALID_ARG", "expected a node handle");
    return NULL;
  }
  return (ZevmExecutionHandle*)raw;
}

static napi_value node_create(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  char* config = NULL;
  if (!get_string(env, argv[0], &config, NULL)) return NULL;
  ZevmNode* node = zevm_node_create(config);
  free(config);
  if (node == NULL) {
    throw_error(env, "ZEVM_INIT_FAILED", "invalid node configuration or native initialization failed");
    return NULL;
  }
  ZevmExecutionHandle* wrapper = (ZevmExecutionHandle*)malloc(sizeof(*wrapper));
  if (wrapper == NULL) {
    zevm_node_destroy(node);
    throw_error(env, "ZEVM_OOM", "allocation failed");
    return NULL;
  }
  wrapper->node = node;
  return make_tagged_external(env, wrapper, finalize_node, &ZEVM_NODE_HANDLE_TAG);
}

static napi_value node_destroy(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  ZevmExecutionHandle* wrapper = execution_handle(env, argv[0]);
  if (wrapper != NULL) {
    zevm_node_destroy(wrapper->node);
    wrapper->node = NULL;
  }
  return NULL;
}

static napi_value node_rpc(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  if (!get_args(env, info, 2, argv)) return NULL;
  ZevmExecutionHandle* wrapper = execution_handle(env, argv[0]);
  if (wrapper == NULL) return NULL;
  if (wrapper->node == NULL) {
    throw_error(env, "ZEVM_CLOSED", "node is closed");
    return NULL;
  }
  char* request = NULL;
  size_t request_len = 0;
  if (!get_string(env, argv[1], &request, &request_len)) return NULL;
  unsigned char* response = NULL;
  size_t response_len = 0;
  int code = zevm_node_rpc(wrapper->node, request, request_len, &response, &response_len);
  free(request);
  if (code != ZEVM_OK) {
    throw_error(env, "ZEVM_RPC_FAILED", zevm_error_message(code));
    return NULL;
  }
  napi_value result = response == NULL ? make_null(env) : make_string(env, (const char*)response, response_len);
  zevm_node_free_response(response, response_len);
  return result;
}

NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    {"nodeCreate", NULL, node_create, NULL, NULL, NULL, napi_default, NULL},
    {"nodeDestroy", NULL, node_destroy, NULL, NULL, NULL, napi_default, NULL},
    {"nodeRpc", NULL, node_rpc, NULL, NULL, NULL, napi_default, NULL},
    {"abiVersion", NULL, abi_version, NULL, NULL, NULL, napi_default, NULL},
    {"version", NULL, version, NULL, NULL, NULL, napi_default, NULL},
    {"errorMessage", NULL, error_message, NULL, NULL, NULL, napi_default, NULL},
    {"networkName", NULL, network_name, NULL, NULL, NULL, napi_default, NULL},
    {"lightInit", NULL, light_init, NULL, NULL, NULL, napi_default, NULL},
    {"lightInitEx", NULL, light_init_ex, NULL, NULL, NULL, napi_default, NULL},
    {"lightShutdown", NULL, light_shutdown, NULL, NULL, NULL, napi_default, NULL},
    {"lightSyncStep", NULL, light_sync_step, NULL, NULL, NULL, napi_default, NULL},
    {"lightStatus", NULL, light_status, NULL, NULL, NULL, napi_default, NULL},
    {"lightLastError", NULL, light_last_error, NULL, NULL, NULL, napi_default, NULL},
    {"lightGetCheckpoint", NULL, light_get_checkpoint, NULL, NULL, NULL, napi_default, NULL},
    {"lightGetBalance", NULL, light_get_balance, NULL, NULL, NULL, napi_default, NULL},
    {"lightGetTransactionCount", NULL, light_get_transaction_count, NULL, NULL, NULL, napi_default, NULL},
    {"lightGetCode", NULL, light_get_code, NULL, NULL, NULL, napi_default, NULL},
    {"lightGetStorage", NULL, light_get_storage, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_status status = napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  if (status != napi_ok) {
    throw_status(env, status, "napi_define_properties");
    return NULL;
  }
  return exports;
}
