#!/usr/bin/env node
// Extract only the first-party app strings consumed by the website guide.
// Usage: node Scripts/export-guide-localizations.cjs /path/to/app-source
// Emits JSON to stdout; the website source is updated with a reviewable patch.
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const sourceRoot = process.argv[2];
if (!sourceRoot) throw new Error("Provide the ForgePlay app source directory.");
const root = path.resolve(__dirname, "..");
const map = JSON.parse(fs.readFileSync(path.join(root, "site-data/guide-app-map.json"), "utf8"));
const script = fs.readFileSync(path.join(root, "site-assets/guide-app.js"), "utf8");
const literals = [...script.matchAll(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g)]
  .map(([value]) => value[0] === '"' ? JSON.parse(value) : value.slice(1, -1))
  .filter(value => /[가-힣]/.test(value));
const keys = [...new Set([
  ...Object.values(map.views).flatMap(view => [view.title, ...view.notes]),
  ...literals
])].sort();
const output = {};
for (const locale of ["ko", "en", "de", "es", "fr", "ja", "zh-Hans", "zh-Hant"]) {
  const input = path.join(sourceRoot, "Resources", `${locale}.lproj`, "Localizable.strings");
  const strings = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", input], {
    encoding: "utf8", maxBuffer: 8 * 1024 * 1024
  }));
  output[locale] = {};
  for (const key of keys) {
    const sourceKey = map.aliases?.[key] || key;
    const value = strings[sourceKey];
    if (typeof value !== "string" || !value.trim()) {
      throw new Error(`Missing ${locale} translation: ${sourceKey}`);
    }
    output[locale][key] = value;
  }
}
process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
