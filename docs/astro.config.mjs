import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  site: "https://zevm.sh",
  base: "/docs",
  integrations: [
    starlight({
      title: "ZEVM",
      favicon: "/favicon.svg",
      logo: {
        src: "./favicon.svg",
        alt: "ZEVM",
      },
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/evmts/zevm",
        },
      ],
      customCss: ["./src/styles/starlight.css"],
      sidebar: [
        {
          label: "Overview",
          items: [
            { label: "ZEVM", slug: "index" },
            { label: "Canonical Specs", slug: "reference/canonical-specs" },
            { label: "Specs And Process", slug: "reference/specs-and-process" },
            { label: "CI And Release Gates", slug: "reference/ci-and-release-gates" },
            { label: "Release Metadata Runbook", slug: "reference/release-metadata-runbook" },
          ],
        },
        {
          label: "Quickstart",
          items: [
            { label: "Installation", slug: "quickstart/installation" },
            { label: "Run Trusted Mode", slug: "quickstart/run-trusted-mode" },
            { label: "Forked Dev Node", slug: "quickstart/forked-dev-node" },
            { label: "Run Light Mode", slug: "quickstart/run-light-mode" },
            { label: "Troubleshooting", slug: "quickstart/troubleshooting" },
          ],
        },
        {
          label: "Concepts",
          items: [
            { label: "Runtime Modes", slug: "concepts/runtime-modes" },
            { label: "Trusted Mode", slug: "concepts/trusted-mode" },
            { label: "Light Mode", slug: "concepts/light-mode" },
            { label: "State Fork And Snapshots", slug: "concepts/state-fork-and-snapshots" },
            { label: "Method Support By Mode", slug: "concepts/method-support-by-mode" },
            { label: "Architecture And Upstream Ownership", slug: "concepts/architecture-and-upstream-ownership" },
          ],
        },
        {
          label: "Configuration Reference",
          items: [
            { label: "Overview", slug: "reference/configuration/overview" },
            { label: "Trusted Mode", slug: "reference/configuration/trusted-mode" },
            { label: "Light Mode", slug: "reference/configuration/light-mode" },
          ],
        },
        {
          label: "JSON-RPC Reference",
          items: [
            { label: "Overview", slug: "reference/json-rpc/overview" },
            { label: "Core Reads", slug: "reference/json-rpc/core-reads" },
            { label: "Managed Dev Wallet", slug: "reference/json-rpc/managed-dev-wallet" },
            { label: "Simulation", slug: "reference/json-rpc/simulation" },
            { label: "Transactions And Mining", slug: "reference/json-rpc/transactions-and-mining" },
            { label: "Blocks, Receipts, And Logs", slug: "reference/json-rpc/blocks-receipts-and-logs" },
            { label: "ZEVM Controls", slug: "reference/json-rpc/dev-controls" },
            { label: "Verified Light-Mode Reads", slug: "reference/json-rpc/verified-light-mode-reads" },
            { label: "Unsupported And Deferred", slug: "reference/json-rpc/unsupported-and-deferred" },
          ],
        },
      ],
    }),
  ],
});
