"use strict";

// Fails unless every published version string agrees: the main package, each
// platform package, the main package's optionalDependencies, build.zig.zon,
// and the version the native ABI reports. Pass a tag (or set GITHUB_REF_NAME
// in a tag build) to also require it to equal v<version>.

const fs = require("node:fs");
const path = require("node:path");

const packageRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(packageRoot, "../..");
const platformsRoot = path.resolve(packageRoot, "../platforms");

const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const errors = [];
const invariant = (condition, message) => {
  if (!condition) errors.push(message);
};

const mainPackage = readJson(path.resolve(packageRoot, "package.json"));
const version = mainPackage.version;

invariant(version !== "0.0.0", "0.0.0 is not a releasable version");
invariant(
  /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version),
  `package version ${version} is not semver`,
);

const tag = process.argv[2] ?? (process.env.GITHUB_REF_TYPE === "tag" ? process.env.GITHUB_REF_NAME : undefined);
if (tag) invariant(tag === `v${version}`, `release tag ${tag} must equal v${version}`);

const zon = fs.readFileSync(path.resolve(repoRoot, "build.zig.zon"), "utf8");
const zonVersion = zon.match(/\.version\s*=\s*"([^"]+)"/)?.[1];
invariant(zonVersion === version, `build.zig.zon version ${zonVersion} != ${version}`);

const cBindings = fs.readFileSync(path.resolve(repoRoot, "src/c_bindings.zig"), "utf8");
const nativeVersion = cBindings.match(/const ZEVM_VERSION[^=]*=\s*"([^"]+)"/)?.[1];
invariant(nativeVersion === version, `src/c_bindings.zig ZEVM_VERSION ${nativeVersion} != ${version}`);

const platformNames = new Set();
for (const entry of fs.readdirSync(platformsRoot, { withFileTypes: true })) {
  const manifestPath = path.resolve(platformsRoot, entry.name, "package.json");
  if (!entry.isDirectory() || !fs.existsSync(manifestPath)) continue;
  const manifest = readJson(manifestPath);
  platformNames.add(manifest.name);
  invariant(manifest.version === version, `${manifest.name}@${manifest.version} != ${version}`);
  invariant(manifest.publishConfig?.access === "public", `${manifest.name} must publish with access public`);
  invariant(
    mainPackage.optionalDependencies?.[manifest.name] === version,
    `${mainPackage.name} optionalDependencies must pin ${manifest.name}@${version}`,
  );
}
invariant(platformNames.size > 0, "no platform packages under npm/platforms");

for (const name of Object.keys(mainPackage.optionalDependencies ?? {})) {
  invariant(platformNames.has(name), `optionalDependency ${name} has no npm/platforms package`);
}
invariant(mainPackage.publishConfig?.access === "public", `${mainPackage.name} must publish with access public`);

if (errors.length > 0) {
  for (const error of errors) console.error(`release metadata: ${error}`);
  process.exit(1);
}
console.log(`release metadata ok: ${mainPackage.name}@${version}, ${platformNames.size} platform packages`);
