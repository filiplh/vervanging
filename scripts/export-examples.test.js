import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EXAMPLES, actionsOf } from './export-examples.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SCRIPT = fileURLToPath(new URL('./export-examples.mjs', import.meta.url));
const DIR = join(ROOT, 'shared', 'examples');

function exportExamples(...args) {
  return spawnSync(process.execPath, [SCRIPT, ...args], { cwd: ROOT, encoding: 'utf8' });
}

// This is what keeps the examples from going stale: verify fails when the JS rules give another output.
test('the shared examples match what the JS rules give now', () => {
  const run = exportExamples('--check');
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal(run.stdout.trim().split('\n').at(-1), `${EXAMPLES.length} examples match`);
  assert.equal(readdirSync(DIR).filter((f) => f.endsWith('.json')).length, EXAMPLES.length);
});

test('--check names an example that changed, one that is missing and one that is not in the list', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vervanging-examples-'));
  try {
    cpSync(DIR, dir, { recursive: true });
    const changed = join(dir, 'plan-equal-10.json');
    const example = JSON.parse(readFileSync(changed, 'utf8'));
    example.stdout = example.stdout.replace('"blocks":12', '"blocks":13');
    writeFileSync(changed, `${JSON.stringify(example, null, 2)}\n`);
    rmSync(join(dir, 'history-sample.json'));
    writeFileSync(join(dir, 'plan-old.json'), '{}\n');
    const run = exportExamples('--check', '--dir', dir);
    assert.equal(run.status, 1);
    assert.match(run.stdout, /^out of date: plan-equal-10\.json$/m);
    assert.match(run.stdout, /^missing: history-sample\.json$/m);
    assert.match(run.stdout, /^not in the list: plan-old\.json$/m);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the list covers every kind, 8 to 12 players, both schedules, every sim action and invalid input', () => {
  assert.ok(EXAMPLES.length >= 40);
  assert.equal(new Set(EXAMPLES.map(([name]) => name)).size, EXAMPLES.length);
  const kinds = new Set(EXAMPLES.map(([, args]) => args[0]));
  for (const kind of ['plan', 'match', 'history']) assert.ok(kinds.has(kind), kind);
  const planArgs = EXAMPLES.filter(([, args]) => args[0] === 'plan').map(([, args]) => args.join(' '));
  for (const schedule of ['equal', 'five']) {
    for (let n = 8; n <= 12; n++) {
      assert.ok(planArgs.some((a) => a.includes(`--players ${n} `) && a.includes(`--schedule ${schedule}`)), `${n} ${schedule}`);
    }
  }
  const actions = new Set(EXAMPLES.filter(([n]) => !n.startsWith('invalid-')).flatMap(([, args]) => actionsOf(args)));
  assert.deepEqual([...actions].sort(), ['bench', 'extra', 'keep', 'terug', 'uit', 'undo', 'wissel']);
  const fixtures = readdirSync(join(ROOT, 'scripts', 'fixtures'));
  for (const fixture of fixtures) {
    assert.ok(EXAMPLES.some(([, args]) => args.includes(`scripts/fixtures/${fixture}`)), fixture);
  }
  for (const [name] of EXAMPLES.filter(([n]) => n.startsWith('invalid-'))) {
    const example = JSON.parse(readFileSync(join(DIR, `${name}.json`), 'utf8'));
    assert.equal(example.exitStatus, 2, name);
    assert.equal(example.stdout, '', name);
  }
});

test('actionsOf lists the match actions an argument list uses, sorted, each once', () => {
  assert.deepEqual(actionsOf(['plan', '--players', '10']), []);
  assert.deepEqual(actionsOf(['match', '--actions', 'wissel*3,undo,wissel']), ['undo', 'wissel']);
  assert.deepEqual(actionsOf(['match', '--actions', 'wissel:keep=4:extra:bench=8,uit=1,terug=1']),
    ['bench', 'extra', 'keep', 'terug', 'uit', 'wissel']);
});
