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

const homeSources = S.Filegroup({
  srcs: [
    S.file("HOME.mjs"),
    S.file("home.json"),
  ],
})

const homeWrite = S.Shell.Run({
  summary: "Project .smithers/HOME.mjs into .smithers/home.json",
  bin: node,
  args: ["tools/home_projection.mjs", "--write"],
  data: [S.file("//tools/home_projection.mjs"), S.file("HOME.mjs")],
  sandbox: "none",
  manual: true,
  timeout: "1m",
})

const homeCheck = S.Shell.Test({
  summary: "Verify .smithers/home.json matches .smithers/HOME.mjs and 3-audience policy",
  bin: node,
  args: ["tools/home_projection.mjs", "--check"],
  data: [S.file("//tools/home_projection.mjs"), homeSources],
  sandbox: "none",
  timeout: "1m",
})

const sh = S.Host.bin("sh")

const factoryWrite = S.Shell.Run({
  summary: "Project .smithers/FACTORY.ts into .smithers/factory.json",
  bin: sh,
  tools: [node],
  args: ["scripts/smthrs", "target", "//.smithers:factory-check", "--write"],
  data: [S.file("FACTORY.ts"), S.file("//scripts/smthrs")],
  sandbox: "none",
  manual: true,
  timeout: "5m",
})

// Factory projection: .smithers/FACTORY.ts and .smithers/flows/** render to
// the checked-in .smithers/factory.json, while .smithers/HOME.mjs renders to
// .smithers/home.json.
//   smthrs target //.smithers:factory-write --write   # regenerate factory.json
//   smthrs ci //.smithers:factory-check               # drift check (in ci)
//   smthrs ci //.smithers:home-check                  # 3-audience home check
export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    "factory-write": factoryWrite,
    "factory-check": S.FactoryProjection({ mode: "check", homeOutput: ".smithers/.home-projection.unused" }),
    "home-write": homeWrite,
    "home-check": homeCheck,
    "home-sources": homeSources,
    "wiki-sources": wikiSources,
    "playground-sources": playgroundSources,
    "wiki-check": wikiCheck,
    "playground-csp-check": playgroundCspCheck,
    "playground-js-check": playgroundJsCheck,
  },
})
