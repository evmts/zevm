# Smithers Workflow Commands

This checkout does not include a `.smithers/package.json`. Smithers workflow commands are run from `workflow/`.

## Install

```sh
cd workflow
bun install
```

`smithers-orchestrator` is an optional local dependency (`file:../../smithers`) and `super-ralph` is a local link dependency (`link:super-ralph`).
If those local paths are absent, `bun run workflow:list` exits with a prerequisite message.

## Typecheck

```sh
cd workflow
bun run tsc --noEmit
```

## Kanban Workflow Invocation

```sh
cd workflow
bun run workflow:list
```

Expected monitoring output when local Smithers deps are missing:

```text
smithers-orchestrator CLI is not installed in this checkout.
Install local dependencies first (../../smithers and workflow/super-ralph).
Expected command after local deps are present:
  bun run workflow:list
```

Expected behavior when local deps are present: the command hands off to
`smithers-orchestrator ... workflow list components/workflow.tsx --root <workflow-dir>`
and streams Smithers CLI workflow/kanban status to the terminal.

## Bun `EISDIR` Runtime/Cache Troubleshooting

If `bun run workflow:list` fails with a Bun `EISDIR` module/cache error in a machine that *does* have local deps, clean and reinstall:

```sh
cd workflow
rm -rf node_modules
bun pm cache rm
bun install
bun run workflow:list
```

If the error persists, verify `../../smithers` and `workflow/super-ralph` are valid directories and not symlink targets to files.
