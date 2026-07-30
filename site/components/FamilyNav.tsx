/**
 * Cross-repo navigation for the tevm.sh family of documentation sites.
 * Every entry below is a live site.
 */

export const FAMILY = [
  { name: 'tevm.sh', url: 'https://tevm.sh', desc: 'The Ethereum toolkit — start here' },
  { name: 'contract.tevm.sh', url: 'https://contract.tevm.sh', desc: 'Typesafe contract bindings' },
  { name: 'bundler.tevm.sh', url: 'https://bundler.tevm.sh', desc: 'Import Solidity from JS' },
  { name: 'cli.tevm.sh', url: 'https://cli.tevm.sh', desc: 'Command line interface' },
  { name: 'test.tevm.sh', url: 'https://test.tevm.sh', desc: 'Contract testing utilities' },
  { name: 'logger.tevm.sh', url: 'https://logger.tevm.sh', desc: 'Structured logging' },
  { name: 'ethers.tevm.sh', url: 'https://ethers.tevm.sh', desc: 'ethers.js integration' },
  { name: 'mud.tevm.sh', url: 'https://mud.tevm.sh', desc: 'MUD framework integration' },
  { name: 'examples.tevm.sh', url: 'https://examples.tevm.sh', desc: 'End-to-end examples' },
  { name: 'voltaire.tevm.sh', url: 'https://voltaire.tevm.sh', desc: 'Ethereum primitives in Zig' },
  {
    name: 'guillotine.tevm.sh',
    url: 'https://guillotine.tevm.sh',
    desc: 'High-performance EVM interpreter',
  },
  { name: 'mini.tevm.sh', url: 'https://mini.tevm.sh', desc: 'Minimal spec-faithful EVM' },
  { name: 'zevm.tevm.sh', url: 'https://zevm.tevm.sh', desc: 'Zig Ethereum client (this site)' },
]

const CURRENT = 'zevm.tevm.sh'

export function FamilyNav() {
  return (
    <nav className="tevm-family" aria-label="tevm documentation family">
      <p className="tevm-family__title">Explore the tevm family</p>
      <div className="tevm-family__grid">
        {FAMILY.map((site) => (
          <a
            key={site.name}
            className="tevm-family__item"
            href={site.url}
            aria-current={site.name === CURRENT ? 'page' : undefined}
          >
            <span className="tevm-family__name">{site.name}</span>
            <span className="tevm-family__desc">{site.desc}</span>
          </a>
        ))}
      </div>
    </nav>
  )
}
