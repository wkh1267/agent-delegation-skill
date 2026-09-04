#!/usr/bin/env node
'use strict';

// Delegate one task to a Worker and return a validated handoff.
//
// This is the entry point a Lead calls. Everything under it already existed as
// tested modules; this only sequences them, so it deliberately adds no
// abstraction of its own.
//
// Read-only by default. Declaring a mutation scope is what turns on the staging
// tree and the sandbox, because those exist to contain writes and there are no
// writes without a scope (ADR-0003).
//
//   node delegent.js --repo <dir> --task "..." [--scope-prefix docs]
//                    [--scope-path README.md] [--session <affinity>] [--dry-run]
//
// The staging tree is left in place on purpose: the Lead reviews the diff and
// accepts. Committing and cleanup are the Lead's, not the Worker's.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const here = __dirname;
const { parseScope, verifyMutation, canonicalPath } = require('./delegent-scope');
const staging = require('./delegent-staging');
const sandbox = require('./delegent-sandbox');

function parseArgs(argv) {
  const o = { scopePrefixes: [], scopePaths: [] };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--dry-run') { o.dryRun = true; continue; }
    const v = argv[++i];
    if (k === '--repo') o.repo = v;
    else if (k === '--task') o.task = v;
    else if (k === '--task-file') o.taskFile = v;
    else if (k === '--scope-prefix') o.scopePrefixes.push(v);
    else if (k === '--scope-path') o.scopePaths.push(v);
    else if (k === '--session') o.session = v;
    else if (k === '--out') o.out = v;
    else o.unknown = k;
  }
  return o;
}

// Everything the sandbox writes must land in TEMP or the staging tree; nothing
// else is writable under `:workspace`.
function tempDir() {
  const dir = path.join(os.tmpdir(), 'delegent');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function plan(options) {
  if (options.unknown) return { ok: false, reason: 'unknown option: ' + options.unknown };
  if (!options.repo) return { ok: false, reason: '--repo is required' };

  const task = options.taskFile ? fs.readFileSync(options.taskFile, 'utf8') : options.task;
  if (!task || !task.trim()) return { ok: false, reason: '--task or --task-file is required' };

  const mutating = options.scopePrefixes.length > 0 || options.scopePaths.length > 0;
  let scope = null;
  if (mutating) {
    const parsed = parseScope({ prefixes: options.scopePrefixes, paths: options.scopePaths });
    if (!parsed.ok) return { ok: false, reason: parsed.reason };
    scope = parsed.scope;
    // The staging tree is keyed by affinity, so a mutating task needs one.
    if (!options.session) return { ok: false, reason: 'a mutation scope requires --session (the Worker affinity)' };
  }

  const temp = tempDir();
  return {
    ok: true,
    dryRun: Boolean(options.dryRun),
    mutating: mutating,
    scope: scope,
    task: task.trim(),
    repo: canonicalPath(options.repo),
    session: options.session || null,
    sessionDir: options.session ? path.join(temp, 'sessions') : null,
    out: options.out || path.join(temp, 'handoff.json'),
    stagingBase: path.join(temp, 'staging')
  };
}

function runWorker(p, cwd, sandboxed) {
  const args = [
    path.join(here, 'delegent-nim-worker.js'),
    '--schema', path.join(here, '..', 'schemas', 'delegent-handoff.schema.json'),
    '--out', p.out,
    '--repo', cwd
  ];
  for (const prefix of (p.scope ? p.scope.prefixes : [])) args.push('--scope-prefix', prefix);
  for (const exact of (p.scope ? p.scope.paths : [])) args.push('--scope-path', exact);
  if (p.session) args.push('--session', p.session, '--session-dir', p.sessionDir);

  let file = process.execPath;
  let spawnArgs = args;
  let env = process.env;
  let verbatim = false;

  if (sandboxed) {
    const found = sandbox.findCodexLauncher();
    if (!found.ok) return { ok: false, reason: found.reason };
    const built = sandbox.buildSandboxCommand({
      launcher: found.launcher,
      stagingPath: cwd,
      command: process.execPath,
      commandArgs: args
    });
    if (!built.ok) return { ok: false, reason: built.reason };
    file = built.file;
    spawnArgs = built.args;
    verbatim = true;
    env = Object.assign({}, process.env, { CODEX_HOME: sandbox.ensureSandboxHome(null) });
  }

  const run = spawnSync(file, spawnArgs, {
    cwd: cwd,
    env: env,
    input: p.task + '\n',
    encoding: 'utf8',
    windowsVerbatimArguments: verbatim,
    timeout: 300000
  });
  return { ok: true, code: run.status, stdout: String(run.stdout || '') };
}

function main() {
  const p = plan(parseArgs(process.argv));
  if (!p.ok) {
    process.stdout.write(JSON.stringify(p) + '\n');
    process.exitCode = 2;
    return;
  }
  if (p.dryRun) {
    process.stdout.write(JSON.stringify({
      ok: true, mutating: p.mutating, repo: p.repo, session: p.session, out: p.out
    }) + '\n');
    return;
  }

  let cwd = p.repo;
  let stagingPath = null;

  if (p.mutating) {
    const tree = staging.ensureStagingTree({ repoRoot: p.repo, baseDir: p.stagingBase, affinity: p.session });
    if (!tree.ok) { process.stdout.write(JSON.stringify(tree) + '\n'); process.exitCode = 1; return; }
    stagingPath = tree.path;
    cwd = tree.path;

    // Never run a Worker on a boundary we have not checked this run.
    const guard = sandbox.verifyEnforcing({ stagingPath: stagingPath });
    if (!guard.ok || !guard.usable) {
      process.stdout.write(JSON.stringify({ ok: false, reason: 'sandbox is not usable', detail: guard }) + '\n');
      process.exitCode = 1;
      return;
    }
  }

  const run = runWorker(p, cwd, p.mutating);
  if (!run.ok) { process.stdout.write(JSON.stringify(run) + '\n'); process.exitCode = 1; return; }

  let handoff = null;
  try { handoff = JSON.parse(fs.readFileSync(p.out, 'utf8')); } catch (err) { handoff = null; }

  const result = {
    ok: run.code === 0 && handoff !== null,
    handoff: handoff,
    staging_tree: stagingPath,
    worker_exit: run.code
  };

  if (p.mutating && handoff) {
    const observed = staging.observeChanges(stagingPath);
    result.verdict = verifyMutation({
      scope: p.scope,
      reportedChanges: handoff.changes,
      observedStatus: observed.ok ? observed.status : ''
    });
    // A containment breach means OUR tools failed, not the Worker. Never retried,
    // and the tree is left for inspection.
    result.ok = result.ok && result.verdict.ok;
  }

  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  process.exitCode = result.ok ? 0 : 1;
}

module.exports = { plan, parseArgs };

if (require.main === module) main();
