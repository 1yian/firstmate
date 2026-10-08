#!/usr/bin/env node
// Prepare an isolated, pinned OptChat copy without changing its upstream source.
// Usage: node .pi/optchat/package.mjs prepare <published-package-dir> <new-patched-dir>
// Requires Node and patch. Does not download, install globally, or activate memory.
// Existing destinations are validated and reused, never replaced or repaired.
import fs from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
const directory = path.dirname(fileURLToPath(import.meta.url));
const manifest = JSON.parse(fs.readFileSync(path.join(directory, "manifest.json"), "utf8"));
const hash = content => createHash("sha256").update(content).digest("hex");
function sourceFiles(root) {
  const files = [];
  const visit = relative => {
    const file = path.join(root, relative), stat = fs.lstatSync(file);
    if (stat.isDirectory()) for (const name of fs.readdirSync(file).sort()) visit(`${relative}/${name}`);
    else if (stat.isFile()) files.push(relative);
    else throw new Error(`Unsupported OptChat source entry: ${relative}`);
  };
  visit("src"); return files.sort();
}
export function verifyPackage(packageDirectory, variant = "patched") {
  if (!["published", "patched"].includes(variant)) throw new Error("Unknown OptChat package variant");
  const root = fs.realpathSync(packageDirectory);
  const info = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  if (info.name !== manifest.package || info.version !== manifest.version) throw new Error(`Expected ${manifest.package}@${manifest.version}`);
  const expectedSources = Object.keys(manifest.files).filter(file => file.startsWith("src/")).sort();
  if (JSON.stringify(sourceFiles(root)) !== JSON.stringify(expectedSources)) throw new Error("Unexpected OptChat source-file inventory");
  for (const [relative, publishedHash] of Object.entries(manifest.files)) {
    const file = path.join(root, relative);
    const expected = variant === "patched" ? manifest.patchedFiles[relative] ?? publishedHash : publishedHash;
    if (!fs.lstatSync(file).isFile() || hash(fs.readFileSync(file)) !== expected) throw new Error(`OptChat ${variant} fingerprint differs: ${relative}`);
  }
  if (variant === "patched") {
    const receipt = JSON.parse(fs.readFileSync(path.join(root, "firstmate-patch.json"), "utf8"));
    if (receipt.npmIntegrity !== manifest.npmIntegrity || receipt.patchSha256 !== manifest.patchSha256) throw new Error("OptChat patch provenance differs");
  }
  return { package: manifest.package, version: manifest.version, npmIntegrity: manifest.npmIntegrity, patchSha256: manifest.patchSha256 };
}
export function preparePackage(sourceDirectory, destinationDirectory) {
  const source = fs.realpathSync(sourceDirectory), destination = path.resolve(destinationDirectory);
  // Do not let a copy end up inside its own source or overwrite an existing copy.
  if (destination === source || destination.startsWith(`${source}${path.sep}`)) throw new Error("Patched destination must be separate from the published package");
  verifyPackage(source, "published");
  if (fs.existsSync(destination)) {
    verifyPackage(destination);
    return { destination, reused: true };
  }
  const parent = path.dirname(destination);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const temporary = path.join(parent, `.optchat-prepare-${process.pid}-${randomUUID()}`);
  fs.mkdirSync(temporary, { mode: 0o700 });
  let reservation, published = false;
  try {
    // Atomic reservation prevents two preparers from claiming the same absent path.
    fs.mkdirSync(destination, { mode: 0o700 });
    reservation = fs.statSync(destination);
    // Only published distribution files; dependencies remain in the local install's
    // parent node_modules or Pi's supported extension import aliases.
    for (const relative of Object.keys(manifest.files)) {
      const file = path.join(temporary, relative);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.copyFileSync(path.join(source, relative), file, fs.constants.COPYFILE_EXCL);
    }
    const patch = path.join(directory, "connected-windows.patch");
    if (hash(fs.readFileSync(patch)) !== manifest.patchSha256) throw new Error("Maintained OptChat patch fingerprint differs");
    const result = spawnSync("patch", ["-p1", "-f", "-F", "0", "-i", patch], { cwd: temporary, encoding: "utf8", timeout: 10000 });
    if (result.status !== 0) throw new Error(`OptChat dependency patch failed: ${result.error?.message || result.stderr || result.stdout}`);
    fs.writeFileSync(path.join(temporary, "firstmate-patch.json"), `${JSON.stringify({ ...verifyPackage(source, "published"), npmShasum: manifest.npmShasum, preparedAt: new Date().toISOString() }, null, 2)}\n`, { mode: 0o600, flag: "wx" });
    verifyPackage(temporary);
    if (fs.lstatSync(destination).ino !== reservation.ino) throw new Error("Patched destination ownership changed during preparation");
    fs.renameSync(temporary, destination);
    published = true;
    return { destination, reused: false };
  } finally {
    // This unique newly-created scratch directory is the only cleanup target.
    fs.rmSync(temporary, { recursive: true, force: true });
    if (reservation && !published) {
      try {
        // Only remove our own still-empty reservation, never another caller's work.
        if (fs.lstatSync(destination).ino === reservation.ino) fs.rmdirSync(destination);
      } catch { /* A changed/nonempty destination is preserved for inspection. */ }
    }
  }
}
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const args = process.argv.slice(2);
  if (args.length === 1 && ["--help", "-h"].includes(args[0])) {
    console.log("Usage: node .pi/optchat/package.mjs prepare <published-package-dir> <new-patched-dir>\nPreserves the upstream package; verifies version and every published file before applying the pinned default-on capability patch. Existing destinations are only validated, never replaced.");
  } else {
    try {
      if (args.length !== 3 || args[0] !== "prepare") throw new Error("Use --help for package preparation syntax");
      console.log(JSON.stringify(preparePackage(args[1], args[2])));
    } catch (error) { console.error(error.message); process.exitCode = 1; }
  }
}
