#!/usr/bin/env node
'use strict';

// Staging tree lifecycle.
//
// Per ADR-0003 a mutating Worker never touches the user's working tree; it works
// in a `git worktree` created for the delegation and keyed by the Worker
// affinity, so an implement -> test -> debug sequence keeps its changes and a
// removed session takes its tree with it.
//
// This is deliberately **orchestrator-side**, not Worker-side. `codex sandbox
// -P :workspace` denies `.git`, so a sandboxed Worker cannot run any git command
// that writes. Creating, removing, and inspecting the tree therefore has to
// happen outside the sandbox, before and after the Worker runs. A Worker that
// could manage its own staging tree could also escape it.
//
// The worktree is checked out **detached** at the current HEAD. No branch is
// created, and `git status` inside the tree is naturally a diff against HEAD,
// which is exactly what the verifier consumes.
//
// Usage as a CLI, so a PowerShell orchestrator can drive it:
//   node delegent-staging.js ensure --repo <r> --base <b> --affinity <a>
//   node delegent-staging.js observe --repo <r> --base <b> --affinity <a>
//   node delegent-staging.js remove --repo <r> --base <b> --affinity <a>
// Each prints a single JSON object.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
// One canonicaliser, shared, because containment depends on it.
const { canonicalPath } = require('./delegent-scope');

function git(repoRoot, args) {
  try {
    const stdout = execFileSync('git', ['-C', repoRoot].concat(args), {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    return { ok: true, stdout: stdout };
  } catch (err) {
    const stderr = err && err.stderr ? String(err.stderr) : '';
    const stdout = err && err.stdout ? String(err.stdout) : '';
    return { ok: false, stdout: stdout, reason: (stderr || String(err && err.message)).trim() };
  }
}

// Same flattening the session store uses: the affinity is a colon-delimited
// identity, not a path, so it is reduced to one safe directory name that cannot
// address anything outside the base directory. The digest keeps two affinities
// that flatten alike from colliding.
function flattenAffinity(affinity) {
  const safe = String(affinity).replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 100);
  const digest = crypto.createHash('sha256').update(String(affinity)).digest('hex').slice(0, 12);
  return safe + '-' + digest;
}

function stagingPathFor(baseDir, affinity) {
  return path.join(baseDir, flattenAffinity(affinity));
}

function listWorktrees(repoRoot) {
  const result = git(repoRoot, ['worktree', 'list', '--porcelain']);
  if (!result.ok) return { ok: false, reason: result.reason, paths: [] };
  const paths = [];
  for (const line of result.stdout.split(/\r?\n/)) {
    if (line.startsWith('worktree ')) paths.push(path.resolve(line.slice('worktree '.length)));
  }
  return { ok: true, paths: paths };
}

// Windows path comparison cannot be exact-string. git reports the path it
// recorded, which may differ from ours in drive-letter case, separator, or 8.3
// short form (a CI runner's TEMP is often RUNNER~1). realpath resolves most of
// that, but not case, so comparison folds case on win32 as the filesystem does.
function samePath(a, b) {
  if (!a || !b) return false;
  const normalize = (value) => {
    let resolved = value;
    try { resolved = canonicalPath(value); } catch (err) { resolved = path.resolve(value); }
    resolved = path.normalize(resolved).replace(/[\\/]+$/, '');
    return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
  };
  return normalize(a) === normalize(b);
}

function isRegisteredWorktree(repoRoot, stagingPath) {
  const listed = listWorktrees(repoRoot);
  if (!listed.ok) return false;
  return listed.paths.some((p) => samePath(p, stagingPath));
}

// Creates the tree, or reuses it when the affinity already has one. Reuse is
// what makes multi-turn implementation possible, so it is reported explicitly
// rather than inferred by the caller.
function ensureStagingTree(options) {
  const repoRoot = options.repoRoot;
  const baseDir = options.baseDir;
  const affinity = options.affinity;
  if (!repoRoot || !baseDir || !affinity) {
    return { ok: false, reason: 'repoRoot, baseDir and affinity are required' };
  }

  const head = git(repoRoot, ['rev-parse', 'HEAD']);
  if (!head.ok) return { ok: false, reason: 'repository has no HEAD to base a staging tree on' };

  // Clear registrations whose directory has already been deleted, so a stale
  // entry cannot block a fresh create.
  git(repoRoot, ['worktree', 'prune']);

  const stagingPath = stagingPathFor(baseDir, affinity);
  const exists = fs.existsSync(stagingPath);
  const registered = exists && isRegisteredWorktree(repoRoot, stagingPath);

  if (exists && registered) {
    return { ok: true, path: stagingPath, created: false, reused: true, head: head.stdout.trim() };
  }
  if (exists && !registered) {
    // A directory sitting where a worktree belongs is an unexplained state. It
    // is reported rather than deleted: removing a directory nobody asked us to
    // remove is exactly the kind of damage this whole boundary exists to avoid.
    return {
      ok: false,
      path: stagingPath,
      reason: 'a directory already exists at the staging path but is not a registered worktree'
    };
  }

  fs.mkdirSync(baseDir, { recursive: true });
  const added = git(repoRoot, ['worktree', 'add', '--detach', stagingPath, 'HEAD']);
  if (!added.ok) return { ok: false, path: stagingPath, reason: added.reason };

  return { ok: true, path: stagingPath, created: true, reused: false, head: head.stdout.trim() };
}

// Removal is forced because a staging tree that mattered has uncommitted changes
// in it by definition; refusing to remove a dirty tree would leak trees forever.
function removeStagingTree(options) {
  const repoRoot = options.repoRoot;
  const stagingPath = stagingPathFor(options.baseDir, options.affinity);

  if (!fs.existsSync(stagingPath)) {
    git(repoRoot, ['worktree', 'prune']);
    return { ok: true, path: stagingPath, removed: false, alreadyAbsent: true };
  }

  const removed = git(repoRoot, ['worktree', 'remove', '--force', stagingPath]);
  if (!removed.ok && fs.existsSync(stagingPath)) {
    return { ok: false, path: stagingPath, reason: removed.reason };
  }
  git(repoRoot, ['worktree', 'prune']);
  return { ok: true, path: stagingPath, removed: true, alreadyAbsent: false };
}

// The observed diff, in the NUL-separated form the verifier parses. `git status`
// is used rather than `git diff` because a newly created file is untracked and
// invisible to a plain diff, and a Worker creating files is the common case.
function observeChanges(stagingPath) {
  if (!fs.existsSync(stagingPath)) return { ok: false, reason: 'staging tree does not exist' };
  const result = git(stagingPath, ['status', '--porcelain=v1', '-z', '--untracked-files=all']);
  if (!result.ok) return { ok: false, reason: result.reason };
  return { ok: true, status: result.stdout };
}

function stagingStatus(options) {
  const stagingPath = stagingPathFor(options.baseDir, options.affinity);
  return {
    ok: true,
    path: stagingPath,
    exists: fs.existsSync(stagingPath),
    registered: fs.existsSync(stagingPath) && isRegisteredWorktree(options.repoRoot, stagingPath)
  };
}

module.exports = {
  samePath,
  flattenAffinity,
  stagingPathFor,
  listWorktrees,
  isRegisteredWorktree,
  ensureStagingTree,
  removeStagingTree,
  observeChanges,
  stagingStatus
};

if (require.main === module) {
  const argv = process.argv;
  const command = argv[2];
  const options = {};
  for (let i = 3; i < argv.length; i += 2) {
    if (argv[i] === '--repo') options.repoRoot = argv[i + 1];
    else if (argv[i] === '--base') options.baseDir = argv[i + 1];
    else if (argv[i] === '--affinity') options.affinity = argv[i + 1];
  }

  let result;
  if (command === 'ensure') result = ensureStagingTree(options);
  else if (command === 'remove') result = removeStagingTree(options);
  else if (command === 'status') result = stagingStatus(options);
  else if (command === 'observe') result = observeChanges(stagingPathFor(options.baseDir, options.affinity));
  else result = { ok: false, reason: 'unknown command: ' + String(command) };

  process.stdout.write(JSON.stringify(result) + '\n');
  process.exitCode = result.ok ? 0 : 1;
}
