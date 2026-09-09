import { copyFileSync, mkdirSync } from 'node:fs';
const destination = new URL('../macos/Sources/Resources/Controls/', import.meta.url);
mkdirSync(destination, { recursive: true });
for (const file of ['index.html', 'controls.js']) {
  copyFileSync(new URL(`src/${file}`, import.meta.url), new URL(file, destination));
}
