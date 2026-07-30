"use strict";

const fs = require("node:fs");
const path = require("node:path");

const scriptDir = __dirname;
const packageRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(packageRoot, "../..");
const platformsRoot = path.resolve(packageRoot, "../platforms");

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

const mainPackage = readJson(path.resolve(packageRoot, "package.json"));
const version = mainPackage.version;
const expectedTag = `v${version}`;
const actualTag = process.argv[2] ?? process.env.GITHUB_REF_NAME;

invariant(version !== "0.0.0", "0.0.0 is not a releasable version");
invariant(
  /^0\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version),
  `expected an honest pre-1.0 semantic version, received ${version}`,
);
if (actualTag) {
  invariant(actualTag === expectedTag, `release tag ${actualTag} must equal ${expectedTag}`);
}

const zon = fs.readFileSync(path.resolve(repoRoot, "build.zig.zon"), "utf8");
const zonVersion = zon.match(/\.version\s*=\s*"([^"]+)"/)?.[1];
invariant(zonVersion === version, `build.zig.zon version ${zonVersion} != ${version}`);

const cBindings = fs.readFileSync(path.resolve(repoRoot, "src/c_bindings.zig"), "utf8");
const nativeVersion = cBindings.match(/ZEVM_VERSION[^=]*=\s*"([^"]+)"/)?.[1];
invariant(nativeVersion === version, `native ABI version ${nativeVersion} != ${version}`);

const platformDirs = fs
  .readdirSync(platformsRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .filter((entry) => fs.existsSync(path.resolve(platformsRoot, entry, "package.json")))
  .sort();

invariant(platformDirs.length > 0, "no native platform packages found");

const expectedOptionalDependencies = new Set();
for (const platform of platformDirs) {
  const manifest = readJson(path.resolve(platformsRoot, platform, "package.json"));
  expectedOptionalDependencies.add(manifest.name);
  invariant(manifest.version === version, `${manifest.name} version must equal ${version}`);
  invariant(manifest.publishConfig?.access === "public", `${manifest.name} must publish publicly`);
  invariant(manifest.publishConfig?.provenance === true, `${manifest.name} must enable provenance`);
  invariant(
    mainPackage.optionalDependencies?.[manifest.name] === version,
    `${mainPackage.name} must depend on ${manifest.name}@${version}`,
  );
}

for (const [name, dependencyVersion] of Object.entries(
  mainPackage.optionalDependencies ?? {},
)) {
  if (!name.startsWith("@evmts/zevm-")) continue;
  invariant(expectedOptionalDependencies.has(name), `unknown native package ${name}`);
  invariant(dependencyVersion === version, `${name} dependency must equal ${version}`);
}

invariant(mainPackage.publishConfig?.access === "public", "main package must publish publicly");
invariant(mainPackage.publishConfig?.provenance === true, "main package must enable provenance");

console.log(
  `release metadata ok: ${mainPackage.name}@${version}, tag=${expectedTag}, nativePackages=${platformDirs.length}`,
);
