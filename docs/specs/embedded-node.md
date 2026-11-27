# Embedded execution node

`zevm_node_create`, `zevm_node_rpc`, and `zevm_node_destroy` expose the same
native NodeRuntime and JSON-RPC dispatcher as the executable, without a socket.
Voltaire owns Ethereum primitives and state; Guillotine Mini executes bytecode.
The host owns event delivery and serializes access to each node.

Creation accepts a JSON object with an optional unsigned `chain_id`. Unknown
configuration keys fail creation. Requests and batches follow the existing
JSON-RPC contract, including notifications and structured errors. Each RPC call
executes once and returns an allocated response, so querying buffer capacity
cannot accidentally execute a transaction twice. The caller frees the response
using `zevm_node_free_response`. Destruction releases all node state.

The npm browser export loads a wasm32-wasi reactor with the same embedded execution ABI. It supports the local trusted chain and manual or automatic mining. Network forks, light sync, Engine API and background interval mining require the native runtime.

Native fork reads use Voltaire's optional synchronous resolver to drain its
request/continue queue inside RPC and interpreter state reads. Async/WASM hosts
leave this resolver unset and retain `RpcPending` behavior.

`debug_traceCall` uses Guillotine Mini's tracer and returns opcode names, entering
stack/memory, gas, depth, output and failure status. Supported options are
`disableStack`, `enableMemory`, `enableReturnData`, and `disableStorage: true`.
Custom tracer programs and other options return -32602. The response retains at
most 100,000 steps and reports `truncated`; execution continues after that cap.
Trace execution reverts its state checkpoint. Native out-of-gas exceptions retain
their diagnostic and return -32000 rather than masquerading as a Solidity revert.
