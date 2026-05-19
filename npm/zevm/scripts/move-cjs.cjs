const { mkdirSync, readdirSync, renameSync, rmSync } = require("node:fs");
const { join } = require("node:path");

const root = join(__dirname, "..");
const sourceDir = join(root, "dist-cjs");
const targetDir = join(root, "dist");

mkdirSync(targetDir, { recursive: true });
for (const file of readdirSync(sourceDir)) {
  if (!file.endsWith(".js")) continue;
  renameSync(join(sourceDir, file), join(targetDir, file.replace(/\.js$/, ".cjs")));
}
rmSync(sourceDir, { recursive: true, force: true });
