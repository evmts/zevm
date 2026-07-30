import { defineConfig } from 'vocs/config'

export default defineConfig({
  title: 'ZEVM',
  description:
    'ZEVM is a Zig Ethereum client with a writable trusted dev node and a proof-backed light client, distributed as a binary, a C ABI, and a Node.js addon.',
  baseUrl: 'https://zevm.tevm.sh',
  rootDir: '.',
  // Shared tevm.sh family identity — matches contract.tevm.sh / bundler.tevm.sh.
  logoUrl: { light: '/tevm-logo-light.png', dark: '/tevm-logo-dark.png' },
  iconUrl: '/favicon.svg',
  // Same accent the sibling family sites render with.
  accentColor: '#0085FF',
  colorScheme: 'light dark',
  editLink: {
    pattern: 'https://github.com/evmts/zevm/edit/main/site/src/pages/:path',
    text: 'Edit on GitHub',
  },
  socials: [
    { icon: 'github', link: 'https://github.com/evmts/zevm' },
  ],
  topNav: [
    { text: 'Guides', link: '/quickstart/installation' },
    { text: 'Reference', link: '/reference/cli' },
    { text: 'Ecosystem', link: '/ecosystem' },
    {
      text: 'npm',
      link: 'https://www.npmjs.com/package/@evmts/zevm',
    },
    {
      text: 'tevm family',
      items: [
        { text: 'tevm.sh', link: 'https://tevm.sh' },
        { text: 'contract', link: 'https://contract.tevm.sh' },
        { text: 'bundler', link: 'https://bundler.tevm.sh' },
        { text: 'cli', link: 'https://cli.tevm.sh' },
        { text: 'test', link: 'https://test.tevm.sh' },
        { text: 'logger', link: 'https://logger.tevm.sh' },
        { text: 'ethers', link: 'https://ethers.tevm.sh' },
        { text: 'mud', link: 'https://mud.tevm.sh' },
        { text: 'examples', link: 'https://examples.tevm.sh' },
        { text: 'voltaire', link: 'https://voltaire.tevm.sh' },
        { text: 'guillotine', link: 'https://guillotine.tevm.sh' },
        { text: 'mini', link: 'https://mini.tevm.sh' },
        { text: 'zevm', link: 'https://zevm.tevm.sh' },
      ],
    },
  ],
  sidebar: [
    { text: 'Introduction', link: '/' },
    {
      text: 'Getting Started',
      collapsed: false,
      items: [
        { text: 'Installation', link: '/quickstart/installation' },
        { text: 'Run Trusted Mode', link: '/quickstart/run-trusted-mode' },
        { text: 'Run Light Mode', link: '/quickstart/run-light-mode' },
        { text: 'Forked Dev Node', link: '/quickstart/forked-dev-node' },
        { text: 'Troubleshooting', link: '/quickstart/troubleshooting' },
      ],
    },
    {
      text: 'Concepts',
      collapsed: false,
      items: [
        { text: 'Runtime Modes', link: '/concepts/runtime-modes' },
        { text: 'Trusted Mode', link: '/concepts/trusted-mode' },
        { text: 'Light Mode', link: '/concepts/light-mode' },
        { text: 'State, Fork & Snapshots', link: '/concepts/state-fork-and-snapshots' },
        { text: 'Method Support By Mode', link: '/concepts/method-support-by-mode' },
        {
          text: 'Architecture & Upstream Ownership',
          link: '/concepts/architecture-and-upstream-ownership',
        },
      ],
    },
    {
      text: 'Guides',
      collapsed: false,
      items: [
        { text: 'Testing Contracts Against ZEVM', link: '/guides/contract-testing' },
        { text: 'Embedding The Light Client In Node.js', link: '/guides/node-light-client' },
        { text: 'Embedding The C ABI', link: '/guides/embedding-c-abi' },
        { text: 'Building From Source', link: '/guides/building-from-source' },
      ],
    },
    {
      text: 'Reference',
      collapsed: false,
      items: [
        { text: 'CLI', link: '/reference/cli' },
        { text: 'Node.js API', link: '/reference/node-api' },
        { text: 'C ABI', link: '/reference/c-abi' },
        {
          text: 'Configuration',
          collapsed: true,
          items: [
            { text: 'Overview', link: '/reference/configuration/overview' },
            { text: 'Trusted Mode', link: '/reference/configuration/trusted-mode' },
            { text: 'Light Mode', link: '/reference/configuration/light-mode' },
          ],
        },
        {
          text: 'JSON-RPC',
          collapsed: true,
          items: [
            { text: 'Overview', link: '/reference/json-rpc/overview' },
            { text: 'Core Reads', link: '/reference/json-rpc/core-reads' },
            {
              text: 'Blocks, Receipts & Logs',
              link: '/reference/json-rpc/blocks-receipts-and-logs',
            },
            {
              text: 'Transactions & Mining',
              link: '/reference/json-rpc/transactions-and-mining',
            },
            { text: 'Simulation', link: '/reference/json-rpc/simulation' },
            { text: 'Dev Controls', link: '/reference/json-rpc/dev-controls' },
            { text: 'Managed Dev Wallet', link: '/reference/json-rpc/managed-dev-wallet' },
            {
              text: 'Verified Light-Mode Reads',
              link: '/reference/json-rpc/verified-light-mode-reads',
            },
            {
              text: 'Unsupported & Deferred',
              link: '/reference/json-rpc/unsupported-and-deferred',
            },
          ],
        },
        { text: 'Release Metadata Runbook', link: '/reference/release-metadata-runbook' },
        { text: 'CI & Release Gates', link: '/reference/ci-and-release-gates' },
        { text: 'Canonical Specs', link: '/reference/canonical-specs' },
        { text: 'Specs & Process', link: '/reference/specs-and-process' },
      ],
    },
    { text: 'Ecosystem', link: '/ecosystem' },
  ],
})
