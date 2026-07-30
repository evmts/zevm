'use client'

import { useState } from 'react'

const INSTALL = 'npm install @evmts/zevm@beta'

export function Hero() {
  const [copied, setCopied] = useState(false)

  const copy = () => {
    navigator.clipboard?.writeText(INSTALL)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div className="tevm-hero">
      <p className="tevm-hero__eyebrow">Ethereum client · written in Zig</p>
      <h1 className="tevm-hero__title">ZEVM</h1>
      <p className="tevm-hero__tagline">
        A writable trusted dev node and a proof-backed light client in one binary — shipped as a
        CLI, a C ABI, and a Node.js addon with prebuilt binaries for macOS, Linux and Windows.
      </p>

      <div className="tevm-hero__install">
        <code>{INSTALL}</code>
        <button type="button" className="tevm-copy" onClick={copy}>
          {copied ? 'copied' : 'copy'}
        </button>
      </div>

      <div className="tevm-hero__ctas">
        <a className="tevm-hero__cta tevm-hero__cta--primary" href="/quickstart/installation">
          Get started
        </a>
        <a className="tevm-hero__cta" href="/reference/cli">
          CLI reference
        </a>
        <a className="tevm-hero__cta" href="https://github.com/evmts/zevm">
          GitHub
        </a>
      </div>
    </div>
  )
}
