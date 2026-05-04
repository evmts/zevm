# ZEVM Docs Infrastructure

Builds the Astro Starlight docs site from `docs/`, uploads the static output to
Cloudflare Assets, serves it at `zevm.sh/docs`, and temporarily redirects the
root domain to `/docs` until the root domain has a marketing site.

## Deploy

```sh
cd cloudflare/zevm-docs-worker
npm install
npm run deploy
```

`npm run deploy` runs the Starlight build, copies `docs/dist` into the Worker
asset bundle, and deploys with Alchemy.

The Worker and `zevm.sh/*` route are declared in `alchemy.run.ts`.
