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
    // Two examples differ and one file is no example: the summary counts them apart.
    assert.equal(run.stdout.trim().split('\n').at(-1), `2 of ${EXAMPLES.length} examples do not match, 1 file is not in the list; run node scripts/export-examples.mjs`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('--check names a stray file without counting it as an example (issue #113)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vervanging-examples-'));
  try {
    cpSync(DIR, dir, { recursive: true });
    writeFileSync(join(dir, 'plan-old.json'), '{}\n');
    const run = exportExamples('--check', '--dir', dir);
    assert.equal(run.status, 1);
    assert.equal(run.stderr, '');
    assert.deepEqual(run.stdout.trim().split('\n'), [
      'not in the list: plan-old.json',
      '1 file is not in the list; run node scripts/export-examples.mjs',
    ]);
    cpSync(join(dir, 'plan-old.json'), join(dir, 'plan-older.json'));
    const two = exportExamples('--check', '--dir', dir);
    assert.equal(two.status, 1);
    assert.equal(two.stdout.trim().split('\n').at(-1), '2 files are not in the list; run node scripts/export-examples.mjs');
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

// uit in the last block takes the path where no next block exists (the replacement comes from the bench of the
// current block); this example must stay in the list. Its uit player is on court in the last block before uit.
test('an example applies uit to a player on court in the last block', () => {
  const entry = EXAMPLES.find(([name]) => name === 'match-equal-9-uit-last-block');
  assert.ok(entry, 'match-equal-9-uit-last-block is in the list');
  const args = entry[1];
  const i = args.indexOf('--actions');
  const items = args[i + 1].split(',');
  const uit = items.at(-1);
  assert.match(uit, /^uit=\d+$/);
  const player = Number(uit.slice('uit='.length));
  const before = [...args.slice(0, i + 1), items.slice(0, -1).join(','), ...args.slice(i + 2)];
  const sim = spawnSync(process.execPath, ['scripts/sim.mjs', ...before], { cwd: ROOT, encoding: 'utf8' });
  assert.equal(sim.status, 0, sim.stderr);
  const last = JSON.parse(sim.stdout);
  assert.equal(last.block, last.blocks);
  assert.equal(last.ended, false);
  assert.ok(last.onCourt.includes(player), `player ${player} is on court in the last block`);
  const example = JSON.parse(readFileSync(join(DIR, 'match-equal-9-uit-last-block.json'), 'utf8'));
  assert.equal(example.exitStatus, 0);
  const after = JSON.parse(example.stdout);
  assert.equal(after.block, after.blocks);
  assert.ok(!after.onCourt.includes(player));
  assert.ok(after.overview.find((row) => row.player === player).out);
});

test('actionsOf lists the match actions an argument list uses, sorted, each once', () => {
  assert.deepEqual(actionsOf(['plan', '--players', '10']), []);
  assert.deepEqual(actionsOf(['match', '--actions', 'wissel*3,undo,wissel']), ['undo', 'wissel']);
  assert.deepEqual(actionsOf(['match', '--actions', 'wissel:keep=4:extra:bench=8,uit=1,terug=1']),
    ['bench', 'extra', 'keep', 'terug', 'uit', 'wissel']);
});
