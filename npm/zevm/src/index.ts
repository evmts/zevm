import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ZEVM_NETWORK_MAINNET = 0;
export const ZEVM_NETWORK_SEPOLIA = 1;
export const ZEVM_NETWORK_HOLESKY = 2;

export const ZEVM_STATUS_NOT_SYNCED = 0;
export const ZEVM_STATUS_SYNCING = 1;
export const ZEVM_STATUS_SYNCED = 2;

export type ZevmNetwork =
  | typeof ZEVM_NETWORK_MAINNET
  | typeof ZEVM_NETWORK_SEPOLIA
  | typeof ZEVM_NETWORK_HOLESKY;

export type ZevmStatus =
  | typeof ZEVM_STATUS_NOT_SYNCED
  | typeof ZEVM_STATUS_SYNCING
  | typeof ZEVM_STATUS_SYNCED;

type NativeHandle = object;

type Native = {
  abiVersion(): number;
  version(): string;
  errorMessage(code: number): string;
  networkName(network: number): string | null;
  lightInit(network: number, beaconRpcUrl: string, executionRpcUrl: string): NativeHandle;
  lightShutdown(handle: NativeHandle): void;
  lightSyncStep(handle: NativeHandle): number;
  lightStatus(handle: NativeHandle): number;
  lightLastError(handle: NativeHandle): string;
  lightGetBalance(handle: NativeHandle, address: string, blockNumber: number | bigint): string;
  lightGetTransactionCount(handle: NativeHandle, address: string, blockNumber: number | bigint): bigint;
  lightGetCode(handle: NativeHandle, address: string, blockNumber: number | bigint): Buffer;
  lightGetStorage(handle: NativeHandle, address: string, slot: string, blockNumber: number | bigint): string;
};

const require = createRequire(import.meta.url);

const platformPackages: Record<string, readonly string[]> = {
  "darwin-arm64": ["@evmts/zevm-darwin-arm64"],
  "darwin-x64": ["@evmts/zevm-darwin-x64"],
  "freebsd-arm64": ["@evmts/zevm-freebsd-arm64"],
  "freebsd-x64": ["@evmts/zevm-freebsd-x64"],
  "linux-arm64-gnu": ["@evmts/zevm-linux-arm64-gnu"],
  "linux-arm64-musl": ["@evmts/zevm-linux-arm64-musl"],
  "linux-x64-gnu": ["@evmts/zevm-linux-x64-gnu"],
  "linux-x64-musl": ["@evmts/zevm-linux-x64-musl"],
  "win32-arm64-msvc": ["@evmts/zevm-win32-arm64-msvc"],
  "win32-ia32-msvc": ["@evmts/zevm-win32-ia32-msvc"],
  "win32-x64-msvc": ["@evmts/zevm-win32-x64-msvc"],
};

function nativePackageKey(): string {
  if (process.platform === "win32") {
    return `${process.platform}-${process.arch}-msvc`;
  }

  if (process.platform !== "linux") {
    return `${process.platform}-${process.arch}`;
  }

  const report = process.report?.getReport?.() as
    | { header?: { glibcVersionRuntime?: string; glibcVersionCompiler?: string } }
    | undefined;
  const glibc = report?.header?.glibcVersionRuntime ?? report?.header?.glibcVersionCompiler;
  const libc = glibc ? "gnu" : "musl";
  return `${process.platform}-${process.arch}-${libc}`;
}

function isMissingPlatformPackage(err: unknown, packageName: string): boolean {
  const code = (err as NodeJS.ErrnoException).code;
  const message = err instanceof Error ? err.message : "";
  return code === "MODULE_NOT_FOUND" && message.includes(packageName);
}

function loadNative(): Native {
  const override = process.env.ZEVM_NATIVE_PATH;
  if (override) {
    return require(override) as Native;
  }

  const packageKey = nativePackageKey();
  const packageNames = platformPackages[packageKey] ?? [];
  for (const packageName of packageNames) {
    try {
      return require(packageName) as Native;
    } catch (err) {
      if (!isMissingPlatformPackage(err, packageName)) {
        throw err;
      }
    }
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const localAddon = join(here, "..", "native", "zevm.node");
  if (existsSync(localAddon)) {
    return require(localAddon) as Native;
  }

  throw new Error(
    `No ZEVM native addon found for ${packageKey}. Supported prebuilds: ${Object.keys(platformPackages).join(", ")}`,
  );
}

const native = loadNative();

export const abiVersion = native.abiVersion;
export const version = native.version;
export const errorMessage = native.errorMessage;
export const networkName = native.networkName;

export class LightClient {
  #handle: NativeHandle | undefined;

  constructor(network: ZevmNetwork, beaconRpcUrl: string, executionRpcUrl: string) {
    this.#handle = native.lightInit(network, beaconRpcUrl, executionRpcUrl);
  }

  close(): void {
    const handle = this.#handle;
    if (handle === undefined) return;
    this.#handle = undefined;
    native.lightShutdown(handle);
  }

  syncStep(): number {
    return native.lightSyncStep(this.#requiredHandle());
  }

  status(): ZevmStatus {
    return native.lightStatus(this.#requiredHandle()) as ZevmStatus;
  }

  lastError(): string {
    return native.lightLastError(this.#requiredHandle());
  }

  getBalance(address: string, blockNumber: number | bigint = 0): string {
    return native.lightGetBalance(this.#requiredHandle(), address, blockNumber);
  }

  getTransactionCount(address: string, blockNumber: number | bigint = 0): bigint {
    return native.lightGetTransactionCount(this.#requiredHandle(), address, blockNumber);
  }

  getCode(address: string, blockNumber: number | bigint = 0): Buffer {
    return native.lightGetCode(this.#requiredHandle(), address, blockNumber);
  }

  getStorage(address: string, slot: string, blockNumber: number | bigint = 0): string {
    return native.lightGetStorage(this.#requiredHandle(), address, slot, blockNumber);
  }

  #requiredHandle(): NativeHandle {
    if (this.#handle === undefined) {
      throw new Error("ZEVM light client is closed");
    }
    return this.#handle;
  }
}
