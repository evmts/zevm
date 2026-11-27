// Each backend owns its reactor, linear memory and trusted local chain.
const encoder = new TextEncoder();
const decoder = new TextDecoder();

export async function createWasmBackend({ chainId = 31337, wasm } = {}) {
  if (!Number.isSafeInteger(chainId) || chainId < 1) throw new RangeError("chainId must be a positive safe integer");
  if (wasm === undefined) {
    const wasmURL = new URL("./zevm.wasm", import.meta.url);
    const response = await fetch(wasmURL);
    if (!response.ok) throw new Error(`Failed to fetch ZEVM wasm (HTTP ${response.status})`);
    wasm = await response.arrayBuffer();
  }

  let api;
  const memory = () => new DataView(api.memory.buffer);
  const wasi = {
    clock_time_get(id, _precision, out) {
      if (id !== 0 && id !== 1) return 28; // EINVAL
      const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.floor(performance.now() * 1e6));
      memory().setBigUint64(out, ns, true);
      return 0;
    },
    // Browser instances have no open files or preopened directories.
    fd_close: () => 8,
    fd_fdstat_get: () => 8,
    fd_filestat_get: () => 8,
    fd_pwrite: () => 8,
    fd_prestat_get: () => 8,
    fd_prestat_dir_name: () => 8,
    fd_read: () => 8,
    fd_seek: () => 8,
    path_open: () => 8,
    fd_write(fd, vec, count, out) {
      if (fd !== 1 && fd !== 2) return 8;
      const view = memory();
      let total = 0;
      for (let i = 0; i < count; i++) total += view.getUint32(vec + i * 8 + 4, true);
      view.setUint32(out, total, true);
      return 0;
    },
    proc_exit(status) { throw new Error(`ZEVM exited with status ${status}`); },
  };
  const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);
  api = (await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi,
    env: { js_opcode_callback: () => 0, js_precompile_callback: () => 0 },
  })).exports;
  api._initialize();

  function alloc(length) {
    const ptr = api.zevm_alloc(length);
    if (!ptr) throw new Error("ZEVM allocation failed");
    return ptr >>> 0;
  }
  const config = encoder.encode(JSON.stringify({ chain_id: chainId }) + "\0");
  const configPtr = alloc(config.length);
  let handle;
  try {
    new Uint8Array(api.memory.buffer, configPtr, config.length).set(config);
    handle = api.zevm_node_create(configPtr);
  } finally {
    api.zevm_free(configPtr, config.length);
  }
  if (!handle) throw new Error("ZEVM initialization failed");

  return {
    rpc(json) {
      if (!handle) throw new Error("ZEVM backend is closed");
      if (typeof json !== "string") throw new TypeError("rpc expects a JSON string");
      const input = encoder.encode(json);
      // The first two aligned u32s hold the response pointer and length.
      const ptr = alloc(8 + input.length);
      try {
        new Uint8Array(api.memory.buffer, ptr + 8, input.length).set(input);
        const status = api.zevm_node_rpc(handle, ptr + 8, input.length, ptr, ptr + 4);
        if (status !== 0) throw new Error(`ZEVM RPC failed with status ${status}`);
        const view = memory();
        const result = view.getUint32(ptr, true);
        if (!result) return null;
        const length = view.getUint32(ptr + 4, true);
        try {
          return decoder.decode(new Uint8Array(api.memory.buffer, result, length));
        } finally {
          api.zevm_node_free_response(result, length);
        }
      } finally {
        api.zevm_free(ptr, 8 + input.length);
      }
    },
    close() {
      if (handle) api.zevm_node_destroy(handle);
      handle = 0;
      api = undefined;
    },
  };
}
