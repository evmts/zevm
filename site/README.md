# ZEVM documentation site

The published documentation at [zevm.tevm.sh](https://zevm.tevm.sh), built with
[vocs](https://vocs.dev) 2.

```bash
npm install
npm run dev     # local preview on http://localhost:5173
npm run build   # production build
```

## Layout

- `vocs.config.ts` — site config: title, `baseUrl`, top nav, sidebar.
- `src/pages/**` — page sources (`.mdx`). The route is the path under `src/pages`
  minus the extension, so `src/pages/reference/cli.mdx` serves `/reference/cli`.
- Cross-page links are absolute routes (`/reference/cli`), not relative file paths.

## Relationship to `docs/`

`docs/specs/**` remains the canonical contract source (PRD and JSON-RPC contract).
`src/pages/**` is the published public documentation. Behaviour changes are
docs-first: update the specs under `docs/specs/` before landing code, then reflect
the change here. See `docs/specs/docs-first-process.md`.

## Deployment

Vercel, with the project's **Root Directory** set to `site`. vocs auto-selects its
Vercel adapter when the `VERCEL` environment variable is present and writes the
Build Output API tree to `.vercel/output`, so no output directory needs to be
configured.
