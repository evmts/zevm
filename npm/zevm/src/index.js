import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
export const ZEVM_NETWORK_MAINNET = 0;
export const ZEVM_NETWORK_SEPOLIA = 1;
export const ZEVM_NETWORK_HOLESKY = 2;
export const ZEVM_NETWORK_HOODI = 3;
export const ZEVM_STATUS_NOT_SYNCED = 0;
export const ZEVM_STATUS_SYNCING = 1;
export const ZEVM_STATUS_SYNCED = 2;
const require = createRequire(import.meta.url);
const platformPackages = {
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
function nativePackageKey() {
    if (process.platform === "win32") {
        return `${process.platform}-${process.arch}-msvc`;
    }
    if (process.platform !== "linux") {
        return `${process.platform}-${process.arch}`;
    }
    const report = process.report?.getReport?.();
    const glibc = report?.header?.glibcVersionRuntime ?? report?.header?.glibcVersionCompiler;
    const libc = glibc ? "gnu" : "musl";
    return `${process.platform}-${process.arch}-${libc}`;
}
function loadNative() {
    const override = process.env.ZEVM_NATIVE_PATH;
    if (override) {
        return require(override);
    }
    // Published platform packages win over a stray local build so installs
    // always load the prebuild that matches this package version.
    const packageKey = nativePackageKey();
    const packageNames = platformPackages[packageKey] ?? [];
    for (const packageName of packageNames) {
        try {
            require.resolve(packageName + "/package.json");
        }
        catch (err) {
            if (err.code === "MODULE_NOT_FOUND") continue;
            throw err;
        }
        return require(packageName);
    }
    // Development fallback: a locally staged addon (not shipped in the tarball).
    const here = dirname(fileURLToPath(import.meta.url));
    const localAddon = join(here, "..", "native", "zevm.node");
    if (existsSync(localAddon)) {
        return require(localAddon);
    }
    throw new Error(`No ZEVM native addon found for ${packageKey}. Supported prebuilds: ${Object.keys(platformPackages).join(", ")}`);
}
const native = loadNative();
if (typeof native.nodeCreate !== "function" || typeof native.nodeRpc !== "function") {
    throw new Error("ZEVM addon does not expose the execution-node ABI; rebuild the native addon");
}
export const abiVersion = native.abiVersion;
export const version = native.version;
export const errorMessage = native.errorMessage;
const INT32_MIN = -2147483648;
const INT32_MAX = 2147483647;
/**
 * Rejects NaN, Infinity, fractions, and out-of-int32 values that the native
 * layer would otherwise coerce (NaN -> 0 selects mainnet).
 */
function assertNetwork(network) {
    if (typeof network !== "number" || !Number.isInteger(network) || network < INT32_MIN || network > INT32_MAX) {
        throw new TypeError("network must be an integer ZEVM_NETWORK_* value");
    }
    return network;
}
export function networkName(network) {
    return native.networkName(assertNetwork(network));
}
const ZERO_CHECKPOINT_HEX = `0x${"0".repeat(64)}`;
function checkpointToHex(checkpoint) {
    let hex;
    if (typeof checkpoint === "string") {
        if (!/^0x[0-9a-fA-F]{64}$/.test(checkpoint)) {
            throw new TypeError("checkpoint must be a 0x-prefixed 32-byte hex string");
        }
        hex = checkpoint;
    }
    else if (checkpoint instanceof Uint8Array) {
        if (checkpoint.length !== 32) {
            throw new TypeError("checkpoint must be 32 bytes");
        }
        hex = `0x${Buffer.from(checkpoint).toString("hex")}`;
    }
    else {
        throw new TypeError("checkpoint must be a hex string or Uint8Array");
    }
    if (hex.toLowerCase() === ZERO_CHECKPOINT_HEX) {
        throw new TypeError("checkpoint must not be all zeros");
    }
    return hex;
}
export class LightClient {
    #handle;
    /**
     * @param {number} network one of ZEVM_NETWORK_*
     * @param {string} beaconRpcUrl non-empty consensus-layer RPC URL
     * @param {string} executionRpcUrl non-empty execution-layer RPC URL
     * @param {{ checkpoint?: string | Uint8Array, strictCheckpointAge?: boolean } | null} [options]
     *   checkpoint: trusted 32-byte beacon block root (defaults to the network's built-in checkpoint);
     *   strictCheckpointAge: fail the first syncStep when the checkpoint is too old
     */
    constructor(network, beaconRpcUrl, executionRpcUrl, options = undefined) {
        assertNetwork(network);
        if (options == null) {
            this.#handle = native.lightInit(network, beaconRpcUrl, executionRpcUrl);
            return;
        }
        if (typeof native.lightInitEx !== "function") {
            throw new Error("ZEVM addon does not support light client options; rebuild the native addon");
        }
        const checkpoint = options.checkpoint === undefined || options.checkpoint === null
            ? null
            : checkpointToHex(options.checkpoint);
        this.#handle = native.lightInitEx(network, beaconRpcUrl, executionRpcUrl, checkpoint, options.strictCheckpointAge ? 1 : 0);
    }
    /** Latest verified finalized checkpoint as a 0x-prefixed hex string. */
    getCheckpoint() {
        return native.lightGetCheckpoint(this.#requiredHandle());
    }
    close() {
        const handle = this.#handle;
        if (handle === undefined)
            return;
        this.#handle = undefined;
        native.lightShutdown(handle);
    }
    syncStep() {
        return native.lightSyncStep(this.#requiredHandle());
    }
    status() {
        return native.lightStatus(this.#requiredHandle());
    }
    lastError() {
        return native.lightLastError(this.#requiredHandle());
    }
    getBalance(address, blockNumber = 0) {
        return native.lightGetBalance(this.#requiredHandle(), address, blockNumber);
    }
    getTransactionCount(address, blockNumber = 0) {
        return native.lightGetTransactionCount(this.#requiredHandle(), address, blockNumber);
    }
    getCode(address, blockNumber = 0) {
        return native.lightGetCode(this.#requiredHandle(), address, blockNumber);
    }
    getStorage(address, slot, blockNumber = 0) {
        return native.lightGetStorage(this.#requiredHandle(), address, slot, blockNumber);
    }
    #requiredHandle() {
        if (this.#handle === undefined) {
            throw new Error("ZEVM light client is closed");
        }
        return this.#handle;
    }
}

/** An isolated native execution node. Call close to release native memory. */
export class NativeNode {
    #handle;
    constructor(config = {}) {
        this.#handle = native.nodeCreate(JSON.stringify(config));
    }
    /** Dispatch a JSON-RPC string once; notifications return null. */
    rpc(request) {
        if (!this.#handle) throw new Error('node is closed');
        return native.nodeRpc(this.#handle, request);
    }
    close() {
        if (!this.#handle) return;
        native.nodeDestroy(this.#handle);
        this.#handle = undefined;
    }
}
