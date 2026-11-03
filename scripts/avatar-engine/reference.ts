import { readFileSync, writeFileSync } from 'node:fs';
import { avatarFrame } from './upstream/render.ts';
import { validateAvatar } from './upstream/validate.ts';
import { parsePath } from './upstream/path.ts';
import { examples } from './upstream/examples.ts';

const directory = new URL('../../Tests/BottoCoreTests/Fixtures/OpenBotAvatar/', import.meta.url);
writeFileSync(new URL('official-examples.json', directory), JSON.stringify(examples));
const selected = ['cat', 'ghost', 'rocket', 'book'].map(id => JSON.parse(readFileSync(new URL(`${id}.json`, directory), 'utf8')));
const cases = [];
function referencePath(path: {d: string, evenOdd: boolean}) {
  if (!path.evenOdd) return {commands: parsePath(path.d), evenOdd: false};
  const tokens = path.d.match(/[MLZ]|[+-]?(?:\d*\.)?\d+(?:e[+-]?\d+)?/gi)!;
  const commands = [];
  let command = '';
  for (let i = 0; i < tokens.length;) {
    if (/^[MLZ]$/.test(tokens[i])) command = tokens[i++];
    if (command === 'Z') { commands.push({c:'Z'}); command=''; continue; }
    if (command !== 'M' && command !== 'L') throw new Error('Unexpected generated reference path');
    commands.push({c:command,x:Number(tokens[i++]),y:Number(tokens[i++])});
    command='L';
  }
  return {commands,evenOdd:true};
}
for (const definition of selected) for (const options of [
  { time: 0, motion: 'idle', reducedMotion: true, depth: 6 },
  { time: 1.2, motion: 'thinking', reducedMotion: false, depth: 6 },
  { time: 3.4, motion: 'happy', reducedMotion: false, depth: 6 },
  { time: 5.1, motion: 'thinking', reducedMotion: false, depth: 6, view: { yaw: 1.8, pitch: -0.5 } },
]) {
  const valid = validateAvatar(definition);
  if (!valid.ok) throw new Error(valid.errors.join(';'));
  const frame = avatarFrame(valid.value, options);
  const paths = Object.fromEntries(frame.paths.map(path => [path.id, referencePath(path)]));
  const shapes = frame.shapes.map(shape => {
    if (shape.kind !== 'eye' || shape.mark.shape !== 'arc') return shape;
    const [move, curve] = parsePath(shape.mark.d);
    if (move.c !== 'M' || curve.c !== 'Q') throw new Error('Unexpected happy arc');
    return { ...shape, mark: { shape: 'arc', x0: move.x, y0: move.y, cx: curve.x1, cy: curve.y1,
      x1: curve.x, y1: curve.y, strokeWidth: shape.mark.strokeWidth } };
  });
  cases.push({ definition, options, frame: { name: frame.name, color: frame.color, ink: frame.ink, root: frame.root, shapes }, paths });
}
writeFileSync(new URL('node-reference.json', directory), JSON.stringify(cases));
console.log(`Wrote ${cases.length} independent Node reference frames`);
