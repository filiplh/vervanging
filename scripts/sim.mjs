#!/usr/bin/env node
// Command-line runner over the planner, so its behaviour can be checked from outside without a browser.
//   node scripts/sim.mjs plan --players <n> --start <a,b,c,d,e> --schedule <equal|five> [--seed <n>] [--swap <a,b>] [--json]
// Prints one JSON object on stdout. Invalid input: exit status 2, one line on stderr, nothing on stdout.
import { makePlan, swapPlayers, planStats, PlanError } from '../public/js/planner.js';

class UsageError extends Error {}

function parse(argv) {
  const [command, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (!arg.startsWith('--')) throw new UsageError(`unexpected argument "${arg}"`);
    const key = arg.slice(2);
    if (key === 'json') { opts.json = true; continue; }
    const value = rest[i + 1];
    if (value === undefined || value.startsWith('--')) throw new UsageError(`--${key} needs a value`);
    opts[key] = value;
    i++;
  }
  return { command, opts };
}

function numberList(text, name) {
  const list = String(text).split(',').filter((s) => s !== '').map(Number);
  if (list.some((n) => !Number.isInteger(n))) throw new UsageError(`--${name} must be comma-separated player numbers`);
  return list;
}

function positiveInt(text, name) {
  const n = Number(text);
  if (!Number.isInteger(n) || n < 1) throw new UsageError(`--${name} must be a whole number of 1 or more`);
  return n;
}

function planFrom(opts) {
  if (opts.players === undefined) throw new UsageError('--players is required');
  if (opts.start === undefined) throw new UsageError('--start is required');
  const count = positiveInt(opts.players, 'players');
  const players = Array.from({ length: count }, (_, i) => i + 1);
  const start = numberList(opts.start, 'start');
  const seed = opts.seed === undefined ? 1 : positiveInt(opts.seed, 'seed');
  let plan = makePlan({ players, start, schedule: opts.schedule ?? 'equal', seed });
  if (opts.swap !== undefined) {
    const pair = numberList(opts.swap, 'swap');
    if (pair.length !== 2) throw new UsageError('--swap takes two player numbers');
    plan = swapPlayers(plan, pair[0], pair[1]);
  }
  return plan;
}

function main(argv) {
  const { command, opts } = parse(argv);
  if (command !== 'plan') throw new UsageError(`unknown command "${command ?? ''}": use plan`);
  const plan = planFrom(opts);
  const stats = planStats(plan);
  return {
    blocks: plan.blocks,
    blockSeconds: plan.blockSeconds,
    grid: plan.grid,
    minutes: stats.minutes,
    subsPerChange: stats.subsPerChange,
    longestBenchSeconds: stats.longestBenchSeconds,
    sitLimitRelaxed: plan.sitLimitRelaxed,
  };
}

try {
  process.stdout.write(`${JSON.stringify(main(process.argv.slice(2)))}\n`);
} catch (error) {
  if (error instanceof UsageError || error instanceof PlanError) {
    process.stderr.write(`sim: ${error.message}\n`);
    process.exit(2);
  }
  throw error;
}
