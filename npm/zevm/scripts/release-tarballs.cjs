"use strict";

const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const main = require("../package.json");
const directory = path.join(root, "zig-out/tarballs");
const packages = Object.keys(main.optionalDependencies).sort().map((name) => ({
  name,
  dir: path.join(root, "npm/platforms", name.slice("@evmts/zevm-".length)),
  files: ["zevm.node"],
}));
packages.push({ name: main.name, dir: path.join(root, "npm/zevm"), files: ["src/index.js", "src/browser.js", "src/zevm.wasm"] });

function filename(name) {
  return name.slice(1).replace("/", "-") + "-" + main.version + ".tgz";
}

function checkAddon(pkg) {
  const [os, arch] = path.basename(pkg.dir).split("-");
  const bytes = fs.readFileSync(path.join(pkg.dir, "zevm.node"));
  if (os === "darwin") {
    assert.equal(bytes.readUInt32LE(), 0xfeedfacf);
    assert.equal(bytes.readUInt32LE(4), arch === "arm64" ? 0x100000c : 0x1000007);
  } else if (os === "win32") {
    const pe = bytes.readUInt32LE(0x3c);
    assert.equal(bytes.toString("ascii", pe, pe + 4), "PE\0\0");
    assert.equal(bytes.readUInt16LE(pe + 4), { x64: 0x8664, ia32: 0x14c, arm64: 0xaa64 }[arch]);
  } else {
    assert.deepEqual([...bytes.subarray(0, 6)], [0x7f, 69, 76, 70, 2, 1]);
    assert.equal(bytes.readUInt16LE(18), arch === "arm64" ? 183 : 62);
    // Zig stamps the generic ELF ABI on FreeBSD shared objects. FreeBSD's
    // dynamic libc dependency distinguishes them from Linux at this stage.
    if (os === "freebsd") assert.ok(bytes.includes(Buffer.from("libc.so.7\0")));
  }
}

function pack() {
  fs.mkdirSync(directory, { recursive: true });
  for (const pkg of packages) {
    if (pkg.name !== main.name) checkAddon(pkg);
    const [result] = JSON.parse(execFileSync("npm", ["pack", "--json", "--ignore-scripts", "--pack-destination", directory], { cwd: pkg.dir }));
    assert.equal(result.name, pkg.name);
    assert.equal(result.version, main.version);
    assert.equal(result.filename, filename(pkg.name));
    assert.deepEqual(result.files.map((file) => file.path).sort(), [...pkg.files, "LICENSE", "README.md", "package.json"].sort());
    for (const file of result.files) assert.ok(file.size > 0, file.path);
  }
}

async function publish() {
  const tag = main.version.split("-")[1]?.split(".")[0] || "latest";
  // Check the complete set before uploading the first package. On a retry,
  // immutable versions already published must match the validated tarballs.
  const pending = [];
  for (const pkg of packages) {
    const file = path.join(directory, filename(pkg.name));
    const integrity = "sha512-" + createHash("sha512").update(fs.readFileSync(file)).digest("base64");
    const url = "https://registry.npmjs.org/" + encodeURIComponent(pkg.name) + "/" + main.version;
    const response = await fetch(url);
    if (response.status === 404) pending.push(file);
    else {
      if (!response.ok) throw new Error(pkg.name + " registry lookup returned " + response.status);
      assert.equal((await response.json()).dist.integrity, integrity, pkg.name + " already exists with different content");
    }
  }
  for (const file of pending) {
    execFileSync("npm", ["publish", file, "--registry=https://registry.npmjs.org", "--provenance", "--access", "public", "--tag", tag], { stdio: "inherit" });
  }
}

if (process.argv[2] === "pack") pack();
else if (process.argv[2] === "publish" && process.env.GITHUB_ACTIONS === "true") publish().catch((error) => { console.error(error); process.exitCode = 1; });
else throw new Error("Expected pack or a GitHub Actions publish");
