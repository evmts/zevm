import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";

const loader = await readFile(new URL("../src/browser.js", import.meta.url));
const wasm = await readFile(new URL("../../../zig-out/npm/browser/zevm.wasm", import.meta.url));
const result = Promise.withResolvers();
const page = `<script type="module">
try {
  const {createWasmBackend} = await import('/browser.js');
  const node = await createWasmBackend();
  const response = node.rpc(JSON.stringify({jsonrpc:"2.0", id:7, method:"eth_call",
    params:[{data:"0x602a60005260206000f3"}, "latest"]}));
  node.close();
  await fetch('/result', {method:'POST', body:response});
} catch (error) { await fetch('/result', {method:'POST', body:JSON.stringify({error:String(error)})}); }
</script>`;
const server = createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/result") {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    res.end();
    result.resolve(Buffer.concat(chunks).toString());
    return;
  }
  const files = { "/": ["text/html", page], "/browser.js": ["text/javascript", loader], "/zevm.wasm": ["application/wasm", wasm] };
  const file = files[req.url];
  if (file) res.writeHead(200, { "Content-Type": file[0] }).end(file[1]);
  else res.writeHead(404).end();
});
const profile = await mkdtemp(join(tmpdir(), "zevm-chromium-"));
server.listen(0, "127.0.0.1");
await once(server, "listening");
const browser = spawn(process.env.CHROME_BIN || "google-chrome", ["--headless", "--disable-dev-shm-usage", "--disable-gpu", "--no-sandbox", "--no-first-run", "--user-data-dir=" + profile, `http://127.0.0.1:${server.address().port}/`], { stdio: "ignore" });
const exit = once(browser, "exit");
browser.on("error", result.reject);
browser.on("exit", (code) => result.reject(new Error("Chromium exited: " + code)));
const timeout = setTimeout(() => result.reject(new Error("Browser eth_call timed out")), 60000);
try {
  assert.deepEqual(JSON.parse(await result.promise), { jsonrpc: "2.0", id: 7, result: "0x" + "00".repeat(31) + "2a" });
  console.log("Chromium eth_call returned 42 through the default Wasm loader");
} finally {
  clearTimeout(timeout);
  browser.kill();
  await exit.catch(() => {});
  server.closeAllConnections();
  server.close();
  await rm(profile, { recursive: true, force: true, maxRetries: 4 });
}
