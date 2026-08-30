import { cp, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

const projectRoot = resolve(import.meta.dirname, "..");
const websiteRoot = resolve(projectRoot, "Website");
const outputRoot = resolve(projectRoot, "public");

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });

const staticEntries = [
  "index.html",
  "support.html",
  "privacy.html",
  "feedback-admin.html",
  "styles.css",
  "admin.css",
  "script.js",
  "feedback-admin.js",
  "robots.txt",
  "sitemap.xml",
  "assets",
];

for (const entry of staticEntries) {
  await cp(resolve(websiteRoot, entry), resolve(outputRoot, entry), { recursive: true });
}

console.log(`BandLoop website prepared at ${outputRoot}`);
