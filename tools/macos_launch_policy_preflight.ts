#!/usr/bin/env bun

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

if (process.platform !== "darwin") {
  process.exit(0);
}

const timeoutSeconds = Number.parseInt(process.env.ZEVM_LAUNCH_POLICY_TIMEOUT ?? "3", 10);
const timeoutMillis = Number.isFinite(timeoutSeconds) && timeoutSeconds > 0 ? timeoutSeconds * 1000 : 3000;
const tmpDir = mkdtempSync(join(tmpdir(), "zevm-launch-policy-preflight-"));
const probeSource = join(tmpDir, "probe.c");
const probeBinary = join(tmpDir, "probe");

function cleanup(): void {
  rmSync(tmpDir, { recursive: true, force: true });
}

function printResult(command: string[]): void {
  const proc = Bun.spawnSync(command, { stdout: "pipe", stderr: "pipe" });
  process.stdout.write(new TextDecoder().decode(proc.stdout));
  process.stderr.write(new TextDecoder().decode(proc.stderr));
}

function fail(message: string): never {
  console.error(message);
  cleanup();
  process.exit(1);
}

process.on("exit", cleanup);
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(signal, () => {
    cleanup();
    process.exit(signal === "SIGINT" ? 130 : 143);
  });
}

writeFileSync(
  probeSource,
  `#include <stdio.h>

int main(void) {
    puts("zevm-launch-policy-ok");
    return 0;
}
`,
);

const compile = Bun.spawnSync(["cc", "-o", probeBinary, probeSource], {
  stdout: "pipe",
  stderr: "pipe",
});
if (compile.exitCode !== 0) {
  process.stderr.write("error: could not compile macOS local launch-policy probe with cc\n");
  process.stderr.write(new TextDecoder().decode(compile.stderr));
  cleanup();
  process.exit(1);
}

const probe = Bun.spawn([probeBinary], { stdout: "pipe", stderr: "pipe" });
const stdoutPromise = new Response(probe.stdout).text();
const stderrPromise = new Response(probe.stderr).text();
let timedOut = false;
const timer = setTimeout(() => {
  timedOut = true;
  probe.kill("SIGKILL");
}, timeoutMillis);

const code = await probe.exited;
clearTimeout(timer);
const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);

if (timedOut) {
  process.stderr.write(
    `error: newly built local executables did not reach main within ${timeoutMillis / 1000}s on this macOS host\n`,
  );
  process.stderr.write("error: ZEVM executable/test gates would hang before producing useful test output\n");
  process.stderr.write(
    "error: this matches ticket .smithers/tickets/063-fix-built-executable-launch-hang-in-test-gates.md\n",
  );
  if (Bun.which("spctl")) printResult(["spctl", "--assess", "-vv", probeBinary]);
  if (Bun.which("xattr")) printResult(["xattr", "-l", probeBinary]);
  cleanup();
  process.exit(1);
}

if (code !== 0) {
  process.stderr.write("error: macOS local launch-policy probe exited non-zero\n");
  process.stderr.write(stderr);
  cleanup();
  process.exit(1);
}

if (!stdout.includes("zevm-launch-policy-ok")) {
  process.stderr.write("error: macOS local launch-policy probe ran but did not emit the expected output\n");
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  cleanup();
  process.exit(1);
}
