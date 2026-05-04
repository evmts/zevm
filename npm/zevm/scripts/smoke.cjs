"use strict";

const path = require("node:path");

const addonPath = process.argv[2];
if (!addonPath) {
  throw new Error("usage: node smoke.cjs <path-to-zevm.node>");
}

const native = require(path.resolve(process.cwd(), addonPath));

if (native.abiVersion() !== 1) {
  throw new Error(`unexpected ABI version ${native.abiVersion()}`);
}
if (typeof native.version() !== "string" || native.version().length === 0) {
  throw new Error("empty ZEVM version");
}
if (native.networkName(0) !== "mainnet") {
  throw new Error("unexpected mainnet name");
}
if (native.errorMessage(0) !== "ok") {
  throw new Error("unexpected ok error message");
}

const handle = native.lightInit(
  0,
  "http://127.0.0.1:0/bogus-beacon",
  "http://127.0.0.1:0/bogus-execution"
);
if (native.lightStatus(handle) !== 1) {
  throw new Error(`unexpected initial status ${native.lightStatus(handle)}`);
}
native.lightShutdown(handle);

console.log("ok");
