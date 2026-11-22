#!/usr/bin/env node
// Command-line runner over the planner and the match engine, so their behaviour can be checked from outside without a
// browser. Players are numbered 1..n.
//   node scripts/sim.mjs plan --players <n> --start <a,b,c,d,e> --schedule <equal|five> [--seed <n>] [--swap <a,b>] [--json]
//   node scripts/sim.mjs match --players <n> --start <a,b,c,d,e> --schedule <equal|five> [--seed <n>] [--swap <a,b>]
//                              [--actions <action,...>] [--json]
//     Actions are comma-separated: wissel, undo ("wissel*11" repeats one 11 times), wissel:keep=P (in the zone:
//     P stays on, the proposed incoming player stays off), wissel:keep=P:bench=Q (Q stays off), uit=P and terug=P
//     (from the next block on). Prints the final match state.
// Prints one JSON object on stdout. Invalid input: exit status 2, one line on stderr, nothing on stdout.
import { makePlan, swapPlayers, planStats, PlanError } from '../public/js/planner.js';
import { startMatch, applyAction, onCourt, minutesSoFar, MatchError } from '../public/js/match.js';

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

// "wissel,wissel*3,wissel:keep=4,wissel:keep=4:bench=9,uit=1,terug=1,undo" -> a list of engine actions
function parseActions(text = '') {
  const actions = [];
  for (const item of String(text).split(',').filter((s) => s !== '')) {
    let m = /^(wissel|undo)(?:\*(\d+))?$/.exec(item);
    if (m) {
      const count = m[2] === undefined ? 1 : Number(m[2]);
      if (count < 1 || count > 1000) throw new UsageError(`action "${item}": the count must be 1 to 1000`);
      for (let i = 0; i < count; i++) actions.push({ type: m[1] });
      continue;
    }
    m = /^wissel:keep=(\d+)(?::bench=(\d+))?$/.exec(item);
    if (m) {
      actions.push({ type: 'wissel', keep: Number(m[1]), bench: m[2] === undefined ? null : Number(m[2]) });
      continue;
    }
    m = /^(uit|terug)=(\d+)$/.exec(item);
    if (m) {
      actions.push({ type: m[1], player: Number(m[2]) });
      continue;
    }
    throw new UsageError(`unknown action "${item}": use wissel, undo (optionally with *<count>), wissel:keep=P[:bench=Q], uit=P or terug=P`);
  }
  return actions;
}

function runMatch(opts) {
  const actions = parseActions(opts.actions);
  let state = startMatch(planFrom(opts));
  for (const action of actions) {
    try {
      state = applyAction(state, action);
    } catch (error) {
      if (error instanceof MatchError) throw new UsageError(error.message);
      throw error;
    }
  }
  return {
    block: state.block,
    blocks: state.blocks,
    ended: state.ended,
    onCourt: onCourt(state),
    minutes: minutesSoFar(state),
  };
}

function main(argv) {
  const { command, opts } = parse(argv);
  if (command === 'match') return runMatch(opts);
  if (command !== 'plan') throw new UsageError(`unknown command "${command ?? ''}": use plan or match`);
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
