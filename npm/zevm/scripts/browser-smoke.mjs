import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createWasmBackend } from "../src/browser.js";

const wasm = await WebAssembly.compile(await readFile(new URL("../../../zig-out/npm/browser/zevm.wasm", import.meta.url)));
const node = await createWasmBackend({ wasm });
const other = await createWasmBackend({ wasm, chainId: 1 });
const address = "0x0000000000000000000000000000000000000123";
const request = (method, params = []) => ({ jsonrpc: "2.0", id: 42, method, params });
const rpc = (method, params) => JSON.parse(node.rpc(JSON.stringify(request(method, params))));
try {
  assert.equal(rpc("eth_chainId").result, "0x7a69");
  assert.equal(JSON.parse(other.rpc(JSON.stringify(request("eth_chainId")))).result, "0x1");
  assert.equal(node.rpc(JSON.stringify({ jsonrpc: "2.0", method: "anvil_setCode", params: [address, "0x602a60005260206000f3"] })), null);
  assert.equal(rpc("eth_call", [{ to: address }, "latest"]).result, "0x" + "00".repeat(31) + "2a");
  assert.equal(JSON.parse(other.rpc(JSON.stringify(request("eth_getCode", [address, "latest"])))).result, "0x");
  const batch = JSON.parse(node.rpc(JSON.stringify([request("eth_chainId"), request("debug_traceTransaction", ["0x" + "00".repeat(32)])])));
  assert.equal(batch[0].result, "0x7a69");
  assert.equal(batch[1].error.code, -32601);
  const filterId = rpc("eth_newBlockFilter").result;
  assert.match(filterId, /^0x[0-9a-f]+$/i);
  assert.equal(rpc("eth_uninstallFilter", [filterId]).result, true);
  const trace = rpc("debug_traceCall", [{ to: address }, "latest"]).result;
  assert.equal(trace.failed, false);
  assert.ok(Array.isArray(trace.structLogs) && trace.structLogs.length > 0);
  assert.equal(JSON.parse(node.rpc("{")).error.code, -32700);
} finally {
  node.close();
  node.close();
  other.close();
}
assert.throws(() => node.rpc("{}"), /closed/);
console.log("browser reactor execution smoke passed");
