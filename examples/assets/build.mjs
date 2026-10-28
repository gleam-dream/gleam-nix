import { mkdir, writeFile } from "node:fs/promises";

await mkdir("dist", { recursive: true });
await writeFile(
  "dist/index.html",
  '<!doctype html><html lang="en"><title>Gleam Nix</title><p>Independent frontend assets</p></html>\n',
);
