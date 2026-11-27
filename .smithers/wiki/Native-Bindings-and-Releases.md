---
title: Native Bindings, WASM & Releases
tags: [c-abi, napi, wasm, npm, releases]
---

# Native Bindings, WASM & Releases

See [[Overview]], [[Architecture]], and [[Smithers-Factory-and-Trust]].

## ABI & Packaging Surface

- **C ABI:** `include/zevm.h` + `src/c_bindings.zig`, verified by `zig build c-smoke` (`tools/c_smoke.c`) and `zig build fuzz-c-abi`.
- **Node-API (`@evmts/zevm`):** `npm/zevm/native/zevm_napi.c` + `npm/zevm/src/index.js` + 11 optional platform packages under `npm/platforms/*` (`darwin`, `linux` gnu/musl, `freebsd`, `win32` msvc), verified by `zig build npm-smoke`.
- **Browser WebAssembly:** `src/browser.zig` + `npm/zevm/src/browser.js`, built with `zig build wasm` and exercised in Node and Chromium smoke tests during release packing.

## Automated Release & Docs Pipeline

1. **Docs auto-publish on merge to `main`:** `.github/workflows/docs.yml` verifies `tools/docs_mirror.mjs`, regenerates `llms.txt` (`tools/generate_llms_txt.mjs`), generates the Lighthouse Backpressure Audit Report into `docs/public/audit/index.html`, builds Astro Starlight, and deploys `cloudflare/zevm-docs-worker` to `https://zevm.sh` when Cloudflare credentials are configured.
2. **Tag releases (`v*`):** `.github/workflows/release.yml` verifies version alignment (`npm/zevm/scripts/verify-release.cjs`), builds all 11 native platform addons + WASM + CLI release binaries, generates canonical `release-tuple.json` and `light-default-checkpoints.json`, publishes the npm packages with `--provenance` after requiring green `main` CI, and creates the GitHub Release so `.github/workflows/ci.yml`'s `Published Release Asset Validation` gate verifies reproducibility automatically.
