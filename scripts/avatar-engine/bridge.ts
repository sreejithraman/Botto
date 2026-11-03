import { validateAvatar } from './upstream/validate.ts';
import { avatarFrame, preparedVolume } from './upstream/render.ts';
import { parsePath, flattenPath } from './upstream/path.ts';
import { createAnimator } from './upstream/animator.ts';

// Only the pinned engine is executable. Definition strings are always parsed as data.
const prepared = new Map<string, any>();
const sources = new Map<string, string>();
const animators = new Map<string, ReturnType<typeof createAnimator>>();
const bounded = <T>(cache: Map<string, T>, key: string, value: T, limit: number) => {
  if (cache.size >= limit) cache.delete(cache.keys().next().value!);
  cache.set(key, value);
};
class DefinitionRejection extends Error {
  constructor(readonly errors: string[]) { super(errors.join('\n')); }
}
const accepted = (raw: string) => {
  let source: unknown;
  try { source = JSON.parse(raw); }
  catch (error) {
    if (error instanceof SyntaxError) throw new DefinitionRejection(['Invalid avatar JSON']);
    throw error;
  }
  const result = validateAvatar(source);
  if (!result.ok) throw new DefinitionRejection(result.errors);
  return result.value;
};
const answer = (work: () => unknown) => {
  try { return JSON.stringify({ ok: true, value: work() }); }
  catch (error) {
    const rejected = error instanceof DefinitionRejection;
    return JSON.stringify({ ok: false, errorKind: rejected ? 'invalidDefinition' : 'renderer',
      errors: rejected ? error.errors : [String((error as Error).message ?? error)] });
  }
};
const pathValue = (d: string, evenOdd: boolean) => ({ commands: parsePath(d), evenOdd });
function sliceValue(slice: any) {
  if (!slice.evenOdd) return pathValue(slice.d, false);
  // Generated cross-sections are polylines. Transfer the engine's own loops
  // with exactly loopsToPath's 0.1-unit rounding, outside input-parser bounds.
  const round = (n: number) => Math.round(n * 10) / 10;
  const commands = slice.loops.flatMap((loop: number[][]) => [
    ...loop.map(([x, y], i) => ({ c: i === 0 ? 'M' : 'L', x: round(x), y: round(y) })), { c: 'Z' },
  ]);
  return { commands, evenOdd: true };
}

function eye(mark: any) {
  if (mark.shape === 'pill') return mark;
  // Canonical happyArc always writes M x y Q cx cy x y. No model text enters here.
  const values = mark.d.slice(1).split(/[ Q]/).filter(Boolean).map(Number);
  if (values.length !== 6 || values.some((v: number) => !Number.isFinite(v))) throw new Error('Invalid canonical happy arc');
  return { shape: 'arc', x0: values[0], y0: values[1], cx: values[2], cy: values[3], x1: values[4], y1: values[5], strokeWidth: mark.strokeWidth };
}

function hotFrame(entry: any, options: any) {
  const canonical = avatarFrame(entry.def, options);
  const ids = new Map(canonical.paths.map((path) => [path.id, entry.ids.get(path.d)]));
  return {
    name: canonical.name, color: canonical.color, ink: canonical.ink, root: canonical.root,
    shapes: canonical.shapes.map((shape) => {
      if (shape.kind === 'eye') return { ...shape, mark: eye(shape.mark) };
      const path = ids.get(shape.path);
      if (path === undefined) throw new Error('Canonical frame requested an unprepared path');
      return { ...shape, path };
    }),
  };
}

export function prepareValue(raw: string, depth = 6) {
  const sourceKey = `${raw}|${depth}`;
  const known = sources.get(sourceKey);
  if (known) {
    const hit = prepared.get(known);
    if (hit) return hit.asset;
  }
  const def = accepted(raw);
  const source = JSON.parse(raw);
  const key = JSON.stringify([def, depth]);
  const hit = prepared.get(key);
  if (hit) { bounded(sources, sourceKey, key, 32); return hit.asset; }
  const { vol } = preparedVolume(def, depth);
  const paths: Record<string, any> = {};
  const ids = new Map<string, string>();
  for (const part of vol.parts) {
    for (const slice of [...part.zSlices, ...part.xSlices]) {
      if (ids.has(slice.d)) continue;
      const id = `p${ids.size}`;
      ids.set(slice.d, id);
      paths[id] = sliceValue(slice);
    }
  }
  const entry = { def, ids, asset: null as any };
  const restingFrame = hotFrame(entry, { depth, time: 0, reducedMotion: true });
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const root = restingFrame.root;
  for (const shape of restingFrame.shapes) {
    if (shape.kind !== 'slice') continue;
    const matrix = shape.matrix;
    for (const polygon of flattenPath(paths[shape.path].commands)) for (const [x, y] of polygon) {
      const X = matrix[0] * x + matrix[2] * y + matrix[4];
      const Y = matrix[1] * x + matrix[3] * y + matrix[5];
      const px = root[0] * X + root[2] * Y + root[4], py = root[1] * X + root[3] * Y + root[5];
      minX = Math.min(minX, px); minY = Math.min(minY, py); maxX = Math.max(maxX, px); maxY = Math.max(maxY, py);
    }
  }
  const asset = { geometry: source, key, paths, outline: pathValue(def.body.path, false), restingBounds: { minX, minY, maxX, maxY }, restingFrame, isRestingPreview: false };
  entry.asset = asset;
  // At most 32 wrapper entries leave room in upstream's 64-entry volume cache.
  bounded(prepared, key, entry, 32);
  bounded(sources, sourceKey, key, 32);
  return asset;
}

export const validate = (raw: string) => answer(() => accepted(raw));
export const prepare = (raw: string, depth = 6) => answer(() => prepareValue(raw, depth));
export const frame = (raw: string, input: string) => answer(() => {
  const options = JSON.parse(input);
  const asset = prepareValue(raw, options.depth ?? 6);
  const entry = prepared.get(asset.key)!;
  const { instanceID, now, ...renderOptions } = options;
  if (typeof instanceID === 'string' && Number.isFinite(now)) {
    const instanceKey = `${instanceID}|${asset.key}`;
    let animator = animators.get(instanceKey);
    if (!animator) { animator = createAnimator(); bounded(animators, instanceKey, animator, 128); }
    const step = animator.step({ now, motion: options.motion, target: options.gaze ?? null, reducedMotion: options.reducedMotion });
    Object.assign(renderOptions, step);
  }
  return hotFrame(entry, renderOptions);
});
export function release(instanceID: string) {
  for (const key of animators.keys()) if (key.startsWith(`${instanceID}|`)) animators.delete(key);
}
