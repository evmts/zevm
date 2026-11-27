import { Smithers as S } from "@smthrs/targets"

const node = S.Host.bin("node")

const wikiSources = S.Filegroup({
  srcs: [
    S.file("coding-project.json"),
    S.glob("wiki/*.md"),
    S.glob("history/*.json"),
  ],
})

const playgroundSources = S.Filegroup({
  srcs: [
    S.file("playground/csp.mjs"),
    S.file("playground/index.html"),
    S.file("playground/run.mjs"),
    S.file("playground/run.test.mjs"),
  ],
})

const wikiCheck = S.Shell.Test({
  summary: "Verify Obsidian wiki wikilinks, source citations, and mythical history",
  bin: node,
  args: ["tools/wiki_sync.mjs", "--check"],
  data: [S.file("//tools/wiki_sync.mjs"), wikiSources],
  sandbox: "none",
  timeout: "2m",
})

const playgroundCspCheck = S.Shell.Test({
  summary: "Verify .smithers/playground/index.html CSP SHA-256 hashes match inline assets",
  bin: node,
  args: [".smithers/playground/csp.mjs", "--check"],
  data: [playgroundSources],
  sandbox: "none",
  timeout: "1m",
})

const playgroundJsCheck = S.Shell.Test({
  summary: "Syntax-check .smithers/playground/*.mjs",
  bin: node,
  args: ["--check", ".smithers/playground/run.mjs"],
  data: [playgroundSources],
  sandbox: "none",
  timeout: "1m",
})

// Factory projection: .smithers/FACTORY.ts and .smithers/flows/** render to
// the checked-in .smithers/factory.json and .smithers/home.json.
//   smthrs target //.smithers:factory-write --write   # regenerate
//   smthrs ci //.smithers:factory-check                # drift check (in ci)
export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" }),
    "wiki-sources": wikiSources,
    "playground-sources": playgroundSources,
    "wiki-check": wikiCheck,
    "playground-csp-check": playgroundCspCheck,
    "playground-js-check": playgroundJsCheck,
  },
})
