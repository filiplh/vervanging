#!/usr/bin/env node
// Exports the shared examples: runs scripts/sim.mjs over a fixed list of argument sets and writes each run, with its
// exact stdout, stderr and exit status, as one JSON file in shared/examples/ (plan decision #35, ADR-003). The Swift
// rules must give the same output for every file. The files are generated, never edited by hand.
//   node scripts/export-examples.mjs [--dir <path>]          writes the files (and removes stale ones)
//   node scripts/export-examples.mjs --check [--dir <path>]  compares the files with what the JS gives now
// --check exits 0 with "<n> examples match" as its last line, or exits 1 naming every example that differs, is
// missing or is not in the list; the last line counts the examples that do not match and the stray files apart.
// Paths in the examples' arguments are relative to the repo root; sim runs from there.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SIM = 'scripts/sim.mjs';
const DEFAULT_DIR = join(ROOT, 'shared', 'examples');
const FIXTURE = (name) => `scripts/fixtures/${name}`;

const P = (n, start, schedule, ...more) => ['--players', String(n), '--start', start, '--schedule', schedule, ...more];

// [name, sim arguments]. The name is the file name without .json; the kind is the sim command (plan, match, history).
export const EXAMPLES = [
  // The planner: both schedules, 8 to 12 players, several starting fives and seeds, swaps.
  ['plan-equal-8', ['plan', ...P(8, '1,2,3,4,5', 'equal')]],
  ['plan-equal-9', ['plan', ...P(9, '1,2,3,4,5', 'equal')]],
  ['plan-equal-10', ['plan', ...P(10, '1,2,3,4,5', 'equal')]],
  ['plan-equal-11', ['plan', ...P(11, '1,2,3,4,5', 'equal')]],
  ['plan-equal-12', ['plan', ...P(12, '1,2,3,4,5', 'equal')]],
  ['plan-five-8', ['plan', ...P(8, '1,2,3,4,5', 'five')]],
  ['plan-five-9', ['plan', ...P(9, '1,2,3,4,5', 'five')]],
  ['plan-five-10', ['plan', ...P(10, '1,2,3,4,5', 'five')]],
  ['plan-five-11', ['plan', ...P(11, '1,2,3,4,5', 'five')]],
  ['plan-five-12', ['plan', ...P(12, '1,2,3,4,5', 'five')]],
  ['plan-equal-10-start-6-10', ['plan', ...P(10, '6,7,8,9,10', 'equal')]],
  ['plan-equal-11-start-mixed', ['plan', ...P(11, '2,4,6,8,10', 'equal')]],
  ['plan-five-9-start-mixed', ['plan', ...P(9, '9,7,5,3,1', 'five')]],
  ['plan-equal-9-seed-2', ['plan', ...P(9, '1,2,3,4,5', 'equal', '--seed', '2')]],
  ['plan-equal-11-seed-7', ['plan', ...P(11, '1,2,3,4,5', 'equal', '--seed', '7')]],
  ['plan-five-11-seed-3', ['plan', ...P(11, '1,2,3,4,5', 'five', '--seed', '3')]],
  ['plan-equal-12-seed-42', ['plan', ...P(12, '3,5,7,9,11', 'equal', '--seed', '42')]],
  ['plan-equal-10-swap', ['plan', ...P(10, '1,2,3,4,5', 'equal', '--swap', '1,2')]],
  ['plan-five-12-swap', ['plan', ...P(12, '1,2,3,4,5', 'five', '--swap', '6,11')]],
  ['plan-equal-9-json-flag', ['plan', ...P(9, '1,2,3,4,5', 'equal', '--json')]],
  // The planner with a team history (decision #28): catch-up, uneven extra places, the sit limit relaxed.
  ['plan-equal-12-history-unused', ['plan', ...P(12, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-sample.json'))]],
  ['plan-equal-12-use-history-sample', ['plan', ...P(12, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-sample.json'), '--use-history')]],
  ['plan-equal-12-use-history-catchup', ['plan', ...P(12, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-catchup.json'), '--use-history')]],
  ['plan-five-12-use-history-catchup', ['plan', ...P(12, '1,2,3,4,5', 'five', '--history', FIXTURE('history-catchup.json'), '--use-history')]],
  ['plan-equal-12-use-history-reward', ['plan', ...P(12, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-reward.json'), '--use-history')]],
  ['plan-equal-11-use-history-empty', ['plan', ...P(11, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-empty.json'), '--use-history')]],
  ['plan-five-16-sit-relaxed', ['plan', ...P(16, '15,8,16,7,13', 'five', '--seed', '3')]],
  ['plan-five-16-use-history-sit-relaxed', ['plan', ...P(16, '15,8,16,7,13', 'five', '--seed', '3', '--history', FIXTURE('history-sit-relaxed.json'), '--use-history')]],
  ['invalid-plan-equal-16-no-plan', ['plan', ...P(16, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-sit-relaxed.json'), '--use-history')]],
  // The match engine: wissel, undo, in the zone, Extra minuten, uit and terug, the last block.
  ['match-equal-10-start', ['match', ...P(10, '1,2,3,4,5', 'equal')]],
  ['match-equal-10-wissel', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel')]],
  ['match-equal-10-wissel-undo', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel,wissel,undo')]],
  ['match-equal-9-last-block', ['match', ...P(9, '1,2,3,4,5', 'equal', '--actions', 'wissel*11')]],
  ['match-equal-9-uit-last-block', ['match', ...P(9, '1,2,3,4,5', 'equal', '--actions', 'wissel*11,uit=3')]],
  ['match-equal-9-ended', ['match', ...P(9, '1,2,3,4,5', 'equal', '--actions', 'wissel*12')]],
  ['match-five-8-ended', ['match', ...P(8, '1,2,3,4,5', 'five', '--actions', 'wissel*8')]],
  ['match-five-12-ended-undo', ['match', ...P(12, '1,2,3,4,5', 'five', '--actions', 'wissel*8,undo')]],
  ['match-equal-10-zone', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=4')]],
  ['match-equal-10-zone-bench', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=4:bench=8')]],
  ['match-equal-10-zone-undo', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=4,undo,wissel*2')]],
  ['match-equal-10-extra', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=4:extra')]],
  ['match-equal-10-extra-bench', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=4:extra:bench=8')]],
  ['match-five-10-extra-full', ['match', ...P(10, '1,2,3,4,5', 'five', '--actions', 'wissel:keep=3:extra,wissel*7')]],
  ['match-equal-10-uit-bench', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'uit=10,wissel*3')]],
  ['match-equal-10-uit-court', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel,uit=1,wissel')]],
  ['match-equal-10-uit-terug', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'uit=1,wissel*2,terug=1,wissel*2')]],
  ['match-equal-10-uit-undo', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'uit=1,undo')]],
  ['match-five-11-uit-terug-ended', ['match', ...P(11, '1,2,3,4,5', 'five', '--actions', 'uit=3,uit=7,wissel*3,terug=3,wissel*5')]],
  ['match-equal-12-mixed', ['match', ...P(12, '1,2,3,4,5', 'equal', '--actions', 'wissel,wissel:keep=3,uit=9,wissel*2,undo,wissel*3')]],
  ['match-equal-12-use-history', ['match', ...P(12, '1,2,3,4,5', 'equal', '--history', FIXTURE('history-catchup.json'), '--use-history', '--actions', 'wissel*4')]],
  // The team history: season totals (decision #26).
  ['history-sample', ['history', '--history', FIXTURE('history-sample.json')]],
  ['history-empty', ['history', '--history', FIXTURE('history-empty.json')]],
  ['history-catchup', ['history', '--history', FIXTURE('history-catchup.json')]],
  ['history-reward', ['history', '--history', FIXTURE('history-reward.json')]],
  ['history-sit-relaxed', ['history', '--history', FIXTURE('history-sit-relaxed.json')]],
  // Invalid input: exit status 2, one line on stderr, nothing on stdout.
  ['invalid-plan-no-players', ['plan', '--start', '1,2,3,4,5', '--schedule', 'equal']],
  ['invalid-plan-unknown-schedule', ['plan', ...P(10, '1,2,3,4,5', 'six')]],
  ['invalid-plan-start-four', ['plan', ...P(10, '1,2,3,4', 'equal')]],
  ['invalid-plan-four-players', ['plan', ...P(4, '1,2,3,4', 'equal')]],
  ['invalid-plan-swap-one', ['plan', ...P(10, '1,2,3,4,5', 'equal', '--swap', '1')]],
  ['invalid-plan-swap-starter-bench', ['plan', ...P(10, '1,2,3,4,5', 'equal', '--swap', '1,6')]],
  ['invalid-plan-use-history-alone', ['plan', ...P(10, '1,2,3,4,5', 'equal', '--use-history')]],
  ['invalid-history-missing-file', ['history', '--history', FIXTURE('does-not-exist.json')]],
  ['invalid-history-not-json', ['history', '--history', SIM]],
  ['invalid-match-unknown-action', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'jump')]],
  ['match-equal-9-wissel-after-end', ['match', ...P(9, '1,2,3,4,5', 'equal', '--actions', 'wissel*13')]],
  ['match-equal-10-undo-at-start', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'undo')]],
  ['invalid-match-keep-not-due-off', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'wissel:keep=10')]],
  ['invalid-match-terug-not-out', ['match', ...P(10, '1,2,3,4,5', 'equal', '--actions', 'terug=1')]],
  ['invalid-match-uit-too-many', ['match', ...P(8, '1,2,3,4,5', 'five', '--actions', 'uit=6,uit=7,uit=8,uit=1')]],
];

// The match actions an argument list uses, by name: wissel, undo, keep (in the zone), extra (Extra minuten),
// bench (keep with a bench player), uit, terug. Sorted, each once.
export function actionsOf(args) {
  const i = args.indexOf('--actions');
  if (i < 0 || args[i + 1] === undefined) return [];
  const used = new Set();
  for (const item of args[i + 1].split(',').filter((s) => s !== '')) {
    const [head, ...parts] = item.split(':');
    const type = head.replace(/[*=].*$/, '');
    used.add(type);
    for (const part of parts) used.add(part.replace(/=.*$/, ''));
  }
  return [...used].sort();
}

function run(name, args) {
  const result = spawnSync(process.execPath, [SIM, ...args], { cwd: ROOT, encoding: 'utf8' });
  if (result.error) throw result.error;
  const example = {
    name,
    kind: args[0],
    actions: actionsOf(args),
    args,
    exitStatus: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  };
  return `${JSON.stringify(example, null, 2)}\n`;
}

function main(argv) {
  let check = false;
  let dir = DEFAULT_DIR;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--check') check = true;
    else if (argv[i] === '--dir' && argv[i + 1] !== undefined) dir = resolve(argv[++i]);
    else {
      process.stderr.write(`export-examples: unexpected argument "${argv[i]}"\n`);
      return 2;
    }
  }
  const names = new Set(EXAMPLES.map(([name]) => name));
  if (names.size !== EXAMPLES.length) throw new Error('two examples share a name');
  const present = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.json')) : [];
  const stale = present.filter((f) => !names.has(f.slice(0, -'.json'.length)));

  if (!check) {
    mkdirSync(dir, { recursive: true });
    for (const [name, args] of EXAMPLES) {
      const file = join(dir, `${name}.json`);
      const text = run(name, args);
      if (!existsSync(file) || readFileSync(file, 'utf8') !== text) writeFileSync(file, text);
    }
    for (const f of stale) rmSync(join(dir, f));
    process.stdout.write(`${EXAMPLES.length} examples written\n`);
    return 0;
  }

  const problems = [];
  for (const [name, args] of EXAMPLES) {
    const file = join(dir, `${name}.json`);
    if (!existsSync(file)) {
      problems.push(`missing: ${name}.json`);
      continue;
    }
    if (readFileSync(file, 'utf8') !== run(name, args)) problems.push(`out of date: ${name}.json`);
  }
  // A stray file is not one of the examples: it is named, but the summary counts it apart (issue #113).
  for (const f of stale) problems.push(`not in the list: ${f}`);
  if (problems.length > 0) {
    for (const p of problems) process.stdout.write(`${p}\n`);
    const off = problems.length - stale.length;
    const parts = [];
    if (off > 0) parts.push(`${off} of ${EXAMPLES.length} examples do not match`);
    if (stale.length > 0) parts.push(`${stale.length} ${stale.length === 1 ? 'file is' : 'files are'} not in the list`);
    process.stdout.write(`${parts.join(', ')}; run node scripts/export-examples.mjs\n`);
    return 1;
  }
  process.stdout.write(`${EXAMPLES.length} examples match\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
