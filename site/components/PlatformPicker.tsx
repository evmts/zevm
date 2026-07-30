'use client'

import { useEffect, useState } from 'react'

/**
 * Interactive platform-support picker.
 *
 * ZEVM ships one prebuilt native package per platform under `npm/platforms`,
 * wired into `@evmts/zevm` as optionalDependencies. This mirrors that table so a
 * reader can answer "is my machine supported, and which package do I get?"
 * without cross-referencing package.json files.
 *
 * Source of truth: the package.json of each npm/platforms directory.
 */

type Target = {
  os: string
  arch: string
  libc?: string
  pkg: string
}

const TARGETS: Target[] = [
  { os: 'darwin', arch: 'arm64', pkg: '@evmts/zevm-darwin-arm64' },
  { os: 'darwin', arch: 'x64', pkg: '@evmts/zevm-darwin-x64' },
  { os: 'linux', arch: 'arm64', libc: 'glibc', pkg: '@evmts/zevm-linux-arm64-gnu' },
  { os: 'linux', arch: 'arm64', libc: 'musl', pkg: '@evmts/zevm-linux-arm64-musl' },
  { os: 'linux', arch: 'x64', libc: 'glibc', pkg: '@evmts/zevm-linux-x64-gnu' },
  { os: 'linux', arch: 'x64', libc: 'musl', pkg: '@evmts/zevm-linux-x64-musl' },
  { os: 'win32', arch: 'arm64', pkg: '@evmts/zevm-win32-arm64-msvc' },
  { os: 'win32', arch: 'ia32', pkg: '@evmts/zevm-win32-ia32-msvc' },
  { os: 'win32', arch: 'x64', pkg: '@evmts/zevm-win32-x64-msvc' },
]

const OS_LABELS: Record<string, string> = {
  darwin: 'macOS',
  linux: 'Linux',
  win32: 'Windows',
}

const ARCHES = ['arm64', 'x64', 'ia32']
const LIBCS = ['glibc', 'musl']

function find(os: string, arch: string, libc: string) {
  return TARGETS.find(
    (t) => t.os === os && t.arch === arch && (os === 'linux' ? t.libc === libc : true),
  )
}

/** Best-effort guess of the visitor's platform from the UA string. */
function guess(): { os: string; arch: string } {
  if (typeof navigator === 'undefined') return { os: 'darwin', arch: 'arm64' }
  const ua = navigator.userAgent
  const os = /Win/.test(ua) ? 'win32' : /Linux|Android/.test(ua) ? 'linux' : 'darwin'
  const arch = /arm|aarch64|Mac OS X/.test(ua) && !/Intel Mac/.test(ua) ? 'arm64' : 'x64'
  return { os, arch }
}

export function PlatformPicker() {
  const [os, setOs] = useState('darwin')
  const [arch, setArch] = useState('arm64')
  const [libc, setLibc] = useState('glibc')
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    const g = guess()
    setOs(g.os)
    setArch(g.arch)
  }, [])

  // Windows has no arm64/x64/ia32 gap, but arm64 is absent on Windows ia32 etc.
  // Keep the selected arch valid whenever the OS changes.
  useEffect(() => {
    if (!TARGETS.some((t) => t.os === os && t.arch === arch)) {
      const first = TARGETS.find((t) => t.os === os)
      if (first) setArch(first.arch)
    }
  }, [os, arch])

  const match = find(os, arch, libc)
  const install = 'npm install @evmts/zevm@beta'

  const copy = () => {
    navigator.clipboard?.writeText(install)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div className="zevm-platform">
      <div className="zevm-platform__row">
        <div className="zevm-platform__group">
          <span className="zevm-platform__label" id="zevm-os">
            Operating system
          </span>
          <div className="zevm-platform__options" role="group" aria-labelledby="zevm-os">
            {Object.keys(OS_LABELS).map((value) => (
              <button
                key={value}
                type="button"
                className="zevm-chip"
                aria-pressed={os === value}
                onClick={() => setOs(value)}
              >
                {OS_LABELS[value]}
              </button>
            ))}
          </div>
        </div>

        <div className="zevm-platform__group">
          <span className="zevm-platform__label" id="zevm-arch">
            Architecture
          </span>
          <div className="zevm-platform__options" role="group" aria-labelledby="zevm-arch">
            {ARCHES.map((value) => {
              const available = TARGETS.some((t) => t.os === os && t.arch === value)
              return (
                <button
                  key={value}
                  type="button"
                  className="zevm-chip"
                  aria-pressed={arch === value}
                  disabled={!available}
                  onClick={() => setArch(value)}
                >
                  {value}
                </button>
              )
            })}
          </div>
        </div>

        {os === 'linux' && (
          <div className="zevm-platform__group">
            <span className="zevm-platform__label" id="zevm-libc">
              libc
            </span>
            <div className="zevm-platform__options" role="group" aria-labelledby="zevm-libc">
              {LIBCS.map((value) => (
                <button
                  key={value}
                  type="button"
                  className="zevm-chip"
                  aria-pressed={libc === value}
                  onClick={() => setLibc(value)}
                >
                  {value}
                </button>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="zevm-platform__result">
        {match ? (
          <>
            <div className="zevm-platform__pkg">
              <span className="zevm-badge zevm-badge--ok">Prebuilt binary</span>
              <code>{match.pkg}</code>
            </div>
            <div className="tevm-hero__install">
              <code>{install}</code>
              <button type="button" className="tevm-copy" onClick={copy}>
                {copied ? 'copied' : 'copy'}
              </button>
            </div>
            <p className="zevm-platform__note">
              npm resolves <code>{match.pkg}</code> automatically through the{' '}
              <code>optionalDependencies</code> of <code>@evmts/zevm</code>. Nothing is compiled at
              install time.
            </p>
          </>
        ) : (
          <>
            <div className="zevm-platform__pkg">
              <span className="zevm-badge zevm-badge--none">No prebuilt binary</span>
            </div>
            <p className="zevm-platform__note">
              This combination has no published package. Build the binary yourself — see{' '}
              <a href="/guides/building-from-source">Building From Source</a>.
            </p>
          </>
        )}
      </div>
    </div>
  )
}
