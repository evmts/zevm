import alchemy from "alchemy";
import { Assets, DnsRecords, Worker } from "alchemy/cloudflare";

const app = await alchemy("zevm-docs");

export const dns = await DnsRecords("zevm-sh-dns", {
  zoneId: "19e2460495f1890a4dbb84d068a5e0d9",
  records: [
    {
      name: "zevm.sh",
      type: "A",
      content: "192.0.2.1",
      proxied: true,
    },
  ],
});

export const assets = await Assets({
  path: "./public",
});

export const worker = await Worker("docs-router", {
  name: "zevm-docs",
  entrypoint: "./src/index.ts",
  compatibilityDate: "2026-05-04",
  bindings: {
    ASSETS: assets,
  },
  assets: {
    run_worker_first: true,
  },
  routes: [
    {
      pattern: "zevm.sh/*",
      adopt: true,
    },
  ],
});

console.log(`ZEVM docs Worker: ${worker.name}`);

await app.finalize();
