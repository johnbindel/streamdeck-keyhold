import { readFile, writeFile } from "node:fs/promises";

const outputPath = process.argv[2];
if (!outputPath) {
	console.error("usage: node scripts/build-manifest.js <output-path>");
	process.exit(1);
}

const packageJson = JSON.parse(await readFile("package.json", "utf8"));
const manifest = JSON.parse(await readFile("manifest.json", "utf8"));

if (!/^\d+\.\d+\.\d+$/.test(packageJson.version)) {
	throw new Error(`package.json version must be major.minor.patch, got ${packageJson.version}`);
}

manifest.Version = `${packageJson.version}.0`;
await writeFile(outputPath, `${JSON.stringify(manifest, null, "\t")}\n`);
