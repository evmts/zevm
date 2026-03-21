# ZEVM Internal Support: Upstream Ownership And Boundaries

Last updated: 2026-03-21

## Ownership Rule

- intended behavior: ZEVM is an integration shell. It should not document or imply ownership of a second state manager, a second EVM, or a second canonical RPC method model where upstream packages already own those concerns.
- current repo reality: the runtime and consensus code already import upstream packages for state management, blockchain data, primitives, EVM execution, and JSON-RPC handling
- documentation rule: public docs may name upstream systems where they shape user-visible behavior, but ZEVM docs remain the primary authority for the ZEVM product contract
- source IDs: `ARCH-01`

## Evidence Boundary Rule

- repo-primary evidence comes first: `docs/specs/prd.md`, `docs/specs/docs-first-process.md`, `src/`, and tests
- repo-secondary evidence comes second: `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md`
- external references may be cited as supporting context only; they must not replace repository-local proof for ZEVM contract claims

This rule matters especially for:

- JSON-RPC transport behavior
- trusted-mode fork semantics
- light-mode checkpoint and status behavior
- Hardhat/Anvil compatibility claims

- source IDs: `DOCS-01`, `ARCH-01`
