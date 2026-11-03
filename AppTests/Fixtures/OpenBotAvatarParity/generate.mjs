// Run from the repository root with Node 22+: node --experimental-strip-types AppTests/Fixtures/OpenBotAvatarParity/generate.mjs
// Reference geometry and SVG rendering use the pinned upstream directly; no Botto bridge code is imported.
import { readFileSync, writeFileSync } from 'node:fs';
import { renderAvatarSvg } from '../../../scripts/avatar-engine/upstream/render.ts';
import { examples } from '../../../scripts/avatar-engine/upstream/examples.ts';
const presets = JSON.parse(readFileSync('Sources/BottoCore/Resources/HermesAvatarDefinitions.json', 'utf8'));
const source = '3a5119877844165eebafe57d3100da475f67d0a8';
const color = '#b0c8e0';
// Botto intentionally paints 85%-opaque black eyes over this opaque body.
const eyeColor = '#1a1e22';
const official = examples.filter(d => ['mug', 'watering-can'].includes(d.id));
const cat = JSON.parse(readFileSync('AppTests/Fixtures/OpenBotAvatarParity/cat.json', 'utf8'));
const definitions = [...presets, ...official, cat];
const cases = definitions.map(definition => ({ name: definition.id + '-rest', definition,
  options: { time: 0, depth: 6, motion: 'idle', reducedMotion: true } }));
for (const definition of [...official, cat]) {
  cases.push({ name: definition.id + '-turned-happy', definition,
    options: { time: 1.2, depth: 10, motion: 'happy', reducedMotion: true, view: { yaw: 1.1, pitch: 0.17 } } });
}
for (const item of cases) item.svg = renderAvatarSvg(item.definition, { ...item.options, color, eyeColor, size: 256 });
writeFileSync('AppTests/Fixtures/OpenBotAvatarParity/OpenBotAvatarParity.json', JSON.stringify({ source, color, eyeColor, cases }) + '\n');
