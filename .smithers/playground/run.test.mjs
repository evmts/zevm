import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { test } from "node:test"

const entry = fileURLToPath(new URL("./run.mjs", import.meta.url))
const run = (request) => JSON.parse(execFileSync(process.execPath, [entry, JSON.stringify(request)], {
  encoding: "utf8",
  timeout: 10_000
}))
const example = { method: "debug_traceCall", bytecode: "0x602a60005260206000f3" }

test("runs an in-memory EVM program and returns its opcode trace", () => {
  const result = run(example)
  assert.equal(result.failed, false)
  assert.equal(result.returnValue, "0x" + "2a".padStart(64, "0"))
  assert.equal(result.gasUsed, 21018)
  assert.deepEqual(result.steps.map((step) => step.op), ["PUSH1", "PUSH1", "MSTORE", "PUSH1", "PUSH1", "RETURN"])
  assert.deepEqual(run({ method: "eth_chainId" }), { result: "0x7a69" })
})

test("bounds input and refuses arbitrary methods", () => {
  assert.deepEqual(run({ method: "evm_mine" }), { error: "Choose a supported operation" })
  assert.deepEqual(run({ ...example, gas: 250001 }), { error: "Set a gas limit between 21000 and 250000" })
  assert.deepEqual(run({ ...example, bytecode: "0xabc" }), { error: "Enter up to 2048 bytes of hex bytecode" })
})

test("playground HTML CSP hashes match inline style and script", () => {
  const cspScript = fileURLToPath(new URL("./csp.mjs", import.meta.url))
  const out = execFileSync(process.execPath, [cspScript, "--check"], { encoding: "utf8" })
  assert.match(out, /playground-csp: ok/)
})
