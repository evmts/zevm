async function run({ method, bytecode, calldata, gas }) {
  const { NativeNode } = await import("../../npm/zevm/src/index.js")
  const vm = new NativeNode({ chain_id: 31337 })
  const rpc = (method, params = []) => {
    const reply = JSON.parse(vm.rpc(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params })))
    if (reply.error) throw new PlaygroundError("ZEVM returned RPC error " + reply.error.code)
    return reply.result
  }
  try {
    if (method === "eth_chainId" || method === "eth_blockNumber") {
      return { result: rpc(method) }
    }
    rpc("zevm_setCode", [address, bytecode])
    const tx = { to: address, data: calldata, gas: "0x" + gas.toString(16) }
    return method === "eth_call"
      ? { returnValue: rpc(method, [tx, "latest"]) }
      : summarize(rpc(method, [tx, "latest", { disableStack: true, disableStorage: true }]))
  } finally {
    vm.close()
  }
}

const maxGas = 250_000
const address = "0x0000000000000000000000000000000000000123"
const methods = new Set(["eth_chainId", "eth_blockNumber", "eth_call", "debug_traceCall"])
const hex = /^0x(?:[0-9a-f]{2})*$/i

class PlaygroundError extends Error {}

function request(input) {
  if (input === null || typeof input !== "object" || !methods.has(input.method)) {
    throw new PlaygroundError("Choose a supported operation")
  }
  const { method, bytecode = "0x", calldata = "0x", gas = 100_000 } = input
  if (typeof bytecode !== "string" || bytecode.length > 4098 || !hex.test(bytecode)) {
    throw new PlaygroundError("Enter up to 2048 bytes of hex bytecode")
  }
  if (typeof calldata !== "string" || calldata.length > 2050 || !hex.test(calldata)) {
    throw new PlaygroundError("Enter up to 1024 bytes of hex calldata")
  }
  if (!Number.isSafeInteger(gas) || gas < 21_000 || gas > maxGas) {
    throw new PlaygroundError("Set a gas limit between 21000 and 250000")
  }
  return { method, bytecode, calldata, gas }
}

function summarize(trace) {
  if (!Array.isArray(trace?.structLogs)) throw new PlaygroundError("Trace unavailable")
  return {
    gasUsed: trace.gas,
    failed: trace.failed,
    returnValue: trace.returnValue,
    truncated: trace.truncated === true || trace.structLogs.length > 256,
    steps: trace.structLogs.slice(0, 256).map(({ pc, op, gas, gasCost, depth }) => ({
      pc, op, gas, gasCost, depth
    }))
  }
}

let response
try {
  const [raw, extra] = process.argv.slice(2)
  if (typeof raw !== "string" || raw.length > 8192 || extra !== undefined) {
    throw new PlaygroundError("Send one JSON request of up to 8192 characters")
  }
  let input
  try {
    input = JSON.parse(raw)
  } catch {
    throw new PlaygroundError("Enter valid JSON")
  }
  response = await run(request(input))
} catch (error) {
  response = { error: error instanceof PlaygroundError ? error.message : "Execution unavailable" }
}
console.log(JSON.stringify(response))
