#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "node_api_subset.h"
#include "zevm.h"

#define ZEVM_NAPI_AUTO_LENGTH ((size_t)-1)
#define ZEVM_MAX_SAFE_JS_INTEGER 9007199254740991.0

typedef struct {
  ZevmHandle* handle;
} ZevmNativeHandle;

static napi_value js_undefined(napi_env env) {
  napi_value value = NULL;
  napi_get_undefined(env, &value);
  return value;
}

static void throw_status(napi_env env, napi_status status, const char* context) {
  char message[160];
  snprintf(message, sizeof(message), "%s failed with napi_status=%d", context, (int)status);
  napi_throw_error(env, "ZEVM_NAPI_ERROR", message);
}

static void throw_zevm(napi_env env, ZevmHandle* handle, int code) {
  const char* last_error = handle == NULL ? NULL : zevm_light_last_error(handle);
  const char* fallback = zevm_error_message(code);
  napi_throw_error(env, "ZEVM_ERROR", (last_error != NULL && last_error[0] != 0) ? last_error : fallback);
}

static bool get_args(napi_env env, napi_callback_info info, size_t expected, napi_value* argv) {
  size_t argc = expected;
  napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (status != napi_ok) {
    throw_status(env, status, "napi_get_cb_info");
    return false;
  }
  if (argc < expected) {
    napi_throw_type_error(env, "ZEVM_INVALID_ARG", "missing required argument");
    return false;
  }
  return true;
}

static bool get_int32(napi_env env, napi_value value, int32_t* out) {
  napi_status status = napi_get_value_int32(env, value, out);
  if (status != napi_ok) {
    napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected a number");
    return false;
  }
  return true;
}

static bool get_uint64(napi_env env, napi_value value, uint64_t* out) {
  napi_valuetype type;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    throw_status(env, status, "napi_typeof");
    return false;
  }
  if (type == napi_bigint) {
    bool lossless = false;
    status = napi_get_value_bigint_uint64(env, value, out, &lossless);
    if (status != napi_ok || !lossless) {
      napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected a lossless unsigned bigint");
      return false;
    }
    return true;
  }
  if (type == napi_number) {
    double number = 0;
    status = napi_get_value_double(env, value, &number);
    if (status != napi_ok || number < 0 || floor(number) != number || number > ZEVM_MAX_SAFE_JS_INTEGER) {
      napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected an unsigned safe-integer block number or bigint");
      return false;
    }
    *out = (uint64_t)number;
    return true;
  }
  napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected a number or bigint");
  return false;
}

static bool get_string(napi_env env, napi_value value, char** out) {
  size_t len = 0;
  napi_status status = napi_get_value_string_utf8(env, value, NULL, 0, &len);
  if (status != napi_ok) {
    napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected a string");
    return false;
  }
  char* buffer = (char*)malloc(len + 1);
  if (buffer == NULL) {
    napi_throw_error(env, "ZEVM_OOM", "allocation failed");
    return false;
  }
  status = napi_get_value_string_utf8(env, value, buffer, len + 1, &len);
  if (status != napi_ok) {
    free(buffer);
    throw_status(env, status, "napi_get_value_string_utf8");
    return false;
  }
  buffer[len] = 0;
  *out = buffer;
  return true;
}

static bool get_handle(napi_env env, napi_value value, ZevmNativeHandle** out) {
  void* raw = NULL;
  napi_status status = napi_get_value_external(env, value, &raw);
  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)raw;
  if (status != napi_ok || wrapper == NULL || wrapper->handle == NULL) {
    napi_throw_type_error(env, "ZEVM_INVALID_ARG", "expected a ZEVM light client handle");
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

static napi_value abi_version(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result;
  napi_create_uint32(env, zevm_abi_version(), &result);
  return result;
}

static napi_value version(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result;
  napi_create_string_utf8(env, zevm_version(), ZEVM_NAPI_AUTO_LENGTH, &result);
  return result;
}

static napi_value error_message(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  int32_t code = 0;
  if (!get_int32(env, argv[0], &code)) return js_undefined(env);
  napi_value result;
  napi_create_string_utf8(env, zevm_error_message(code), ZEVM_NAPI_AUTO_LENGTH, &result);
  return result;
}

static napi_value network_name(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  int32_t network = 0;
  if (!get_int32(env, argv[0], &network)) return js_undefined(env);
  const char* name = zevm_light_network_name(network);
  napi_value result;
  if (name == NULL) {
    napi_get_null(env, &result);
  } else {
    napi_create_string_utf8(env, name, ZEVM_NAPI_AUTO_LENGTH, &result);
  }
  return result;
}

static napi_value light_init(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return js_undefined(env);

  int32_t network = 0;
  char* beacon = NULL;
  char* execution = NULL;
  if (!get_int32(env, argv[0], &network)) return js_undefined(env);
  if (!get_string(env, argv[1], &beacon)) return js_undefined(env);
  if (!get_string(env, argv[2], &execution)) {
    free(beacon);
    return js_undefined(env);
  }

  ZevmHandle* handle = zevm_light_init(network, beacon, execution);
  free(beacon);
  free(execution);

  if (handle == NULL) {
    napi_throw_error(env, "ZEVM_INIT_FAILED", "zevm_light_init failed");
    return js_undefined(env);
  }

  ZevmNativeHandle* wrapper = (ZevmNativeHandle*)malloc(sizeof(ZevmNativeHandle));
  if (wrapper == NULL) {
    zevm_light_shutdown(handle);
    napi_throw_error(env, "ZEVM_OOM", "allocation failed");
    return js_undefined(env);
  }
  wrapper->handle = handle;

  napi_value result;
  napi_status status = napi_create_external(env, wrapper, finalize_handle, NULL, &result);
  if (status != napi_ok) {
    finalize_handle(env, wrapper, NULL);
    throw_status(env, status, "napi_create_external");
    return js_undefined(env);
  }
  return result;
}

static napi_value light_shutdown(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  zevm_light_shutdown(wrapper->handle);
  wrapper->handle = NULL;
  return js_undefined(env);
}

static napi_value light_sync_step(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  int code = zevm_light_sync_step(wrapper->handle);
  napi_value result;
  napi_create_int32(env, code, &result);
  return result;
}

static napi_value light_status(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  napi_value result;
  napi_create_int32(env, zevm_light_status(wrapper->handle), &result);
  return result;
}

static napi_value light_last_error(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  napi_value result;
  napi_create_string_utf8(env, zevm_light_last_error(wrapper->handle), ZEVM_NAPI_AUTO_LENGTH, &result);
  return result;
}

static napi_value light_get_balance(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  if (!get_string(env, argv[1], &address)) return js_undefined(env);
  if (!get_uint64(env, argv[2], &block_number)) {
    free(address);
    return js_undefined(env);
  }

  size_t len = 0;
  int code = zevm_light_get_balance(wrapper->handle, address, block_number, NULL, &len);
  if (code != ZEVM_ERR_BUFFER_TOO_SMALL) {
    free(address);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  char* out = (char*)malloc(len);
  if (out == NULL) {
    free(address);
    napi_throw_error(env, "ZEVM_OOM", "allocation failed");
    return js_undefined(env);
  }
  code = zevm_light_get_balance(wrapper->handle, address, block_number, out, &len);
  free(address);
  if (code != ZEVM_OK) {
    free(out);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  napi_value result;
  napi_create_string_utf8(env, out, len - 1, &result);
  free(out);
  return result;
}

static napi_value light_get_transaction_count(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  uint64_t count = 0;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  if (!get_string(env, argv[1], &address)) return js_undefined(env);
  if (!get_uint64(env, argv[2], &block_number)) {
    free(address);
    return js_undefined(env);
  }
  int code = zevm_light_get_transaction_count(wrapper->handle, address, block_number, &count);
  free(address);
  if (code != ZEVM_OK) {
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  napi_value result;
  napi_create_bigint_uint64(env, count, &result);
  return result;
}

static napi_value light_get_code(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  if (!get_string(env, argv[1], &address)) return js_undefined(env);
  if (!get_uint64(env, argv[2], &block_number)) {
    free(address);
    return js_undefined(env);
  }

  size_t len = 0;
  int code = zevm_light_get_code(wrapper->handle, address, block_number, NULL, &len);
  if (code != ZEVM_OK && code != ZEVM_ERR_BUFFER_TOO_SMALL) {
    free(address);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  uint8_t* out = len == 0 ? NULL : (uint8_t*)malloc(len);
  if (len != 0 && out == NULL) {
    free(address);
    napi_throw_error(env, "ZEVM_OOM", "allocation failed");
    return js_undefined(env);
  }
  code = zevm_light_get_code(wrapper->handle, address, block_number, out, &len);
  free(address);
  if (code != ZEVM_OK) {
    free(out);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  napi_value result;
  void* copied = NULL;
  napi_status status = napi_create_buffer_copy(env, len, out, &copied, &result);
  free(out);
  if (status != napi_ok) {
    throw_status(env, status, "napi_create_buffer_copy");
    return js_undefined(env);
  }
  return result;
}

static napi_value light_get_storage(napi_env env, napi_callback_info info) {
  napi_value argv[4];
  if (!get_args(env, info, 4, argv)) return js_undefined(env);
  ZevmNativeHandle* wrapper = NULL;
  char* address = NULL;
  char* slot = NULL;
  uint64_t block_number = 0;
  if (!get_handle(env, argv[0], &wrapper)) return js_undefined(env);
  if (!get_string(env, argv[1], &address)) return js_undefined(env);
  if (!get_string(env, argv[2], &slot)) {
    free(address);
    return js_undefined(env);
  }
  if (!get_uint64(env, argv[3], &block_number)) {
    free(address);
    free(slot);
    return js_undefined(env);
  }

  size_t len = 0;
  int code = zevm_light_get_storage(wrapper->handle, address, slot, block_number, NULL, &len);
  if (code != ZEVM_ERR_BUFFER_TOO_SMALL) {
    free(address);
    free(slot);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  char* out = (char*)malloc(len);
  if (out == NULL) {
    free(address);
    free(slot);
    napi_throw_error(env, "ZEVM_OOM", "allocation failed");
    return js_undefined(env);
  }
  code = zevm_light_get_storage(wrapper->handle, address, slot, block_number, out, &len);
  free(address);
  free(slot);
  if (code != ZEVM_OK) {
    free(out);
    throw_zevm(env, wrapper->handle, code);
    return js_undefined(env);
  }
  napi_value result;
  napi_create_string_utf8(env, out, len - 1, &result);
  free(out);
  return result;
}

NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    {"abiVersion", NULL, abi_version, NULL, NULL, NULL, napi_default, NULL},
    {"version", NULL, version, NULL, NULL, NULL, napi_default, NULL},
    {"errorMessage", NULL, error_message, NULL, NULL, NULL, napi_default, NULL},
    {"networkName", NULL, network_name, NULL, NULL, NULL, napi_default, NULL},
    {"lightInit", NULL, light_init, NULL, NULL, NULL, napi_default, NULL},
    {"lightShutdown", NULL, light_shutdown, NULL, NULL, NULL, napi_default, NULL},
    {"lightSyncStep", NULL, light_sync_step, NULL, NULL, NULL, napi_default, NULL},
    {"lightStatus", NULL, light_status, NULL, NULL, NULL, napi_default, NULL},
    {"lightLastError", NULL, light_last_error, NULL, NULL, NULL, napi_default, NULL},
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
