#!/usr/bin/env node
/**
 * Build/update .smithers/playground/index.html CSP SHA-256 hashes cleanly so
 * Smithers Cloud's strict iframe Content-Security-Policy always matches the
 * inline <style> and <script> blocks verbatim.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const file = path.resolve(process.cwd(), ".smithers/playground/index.html");
const checkOnly = process.argv.includes("--check");
const html = fs.readFileSync(file, "utf8");

const styleMatch = html.match(/<style>([\s\S]*?)<\/style>/);
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
if (!styleMatch || !scriptMatch) {
  console.error("playground-csp: missing <style> or <script> tag");
  process.exit(1);
}

const sha256 = (text) =>
  `sha256-${crypto.createHash("sha256").update(text, "utf8").digest("base64")}`;

const styleHash = sha256(styleMatch[1]);
const scriptHash = sha256(scriptMatch[1]);
const expectedCsp =
  `default-src 'none'; script-src '${scriptHash}'; style-src '${styleHash}'; base-uri 'none'; form-action 'none'; connect-src 'none'`;

const nextHtml = html.replace(
  /(<meta http-equiv="Content-Security-Policy" content=")[^"]*(")/,
  `$1${expectedCsp}$2`,
);

if (checkOnly) {
  if (nextHtml !== html) {
    console.error("playground-csp: CSP hashes in .smithers/playground/index.html are out of date");
    process.exit(1);
  }
  console.log(`playground-csp: ok (${scriptHash}, ${styleHash})`);
} else {
  fs.writeFileSync(file, nextHtml);
  console.log(`playground-csp: updated (${scriptHash}, ${styleHash})`);
}
