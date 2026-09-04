'use strict';

// D4b — deterministic tests for the staging tree lifecycle. Needs git, but no
// model, no network and no credential.
//
// Every arm runs against a throwaway repository created in the temp directory.
// This test never creates a worktree of the real repository, because a test that
// mutates the repo it lives in is exactly the hazard the staging tree exists to
// remove.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const toolsDir = path.resolve(__dirname, '..', 'skills', 'delegating-work', 'tools');
const staging = require(path.join(toolsDir, 'delegent-staging.js'));
const { verifyMutation, parseScope } = require(path.join(toolsDir, 'delegent-scope.js'));

let failures = 0;
let checks = 0;

function check(condition, message) {
  checks++;
  if (!condition) {
    failures++;
    process.stdout.write('FAIL  ' + message + '\n');
  }
}

function git(cwd, args) {
  return execFileSync('git', ['-C', cwd].concat(args), {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

function makeRepo() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-repo-')));
  git(root, ['init', '--quiet']);
  git(root, ['config', 'user.email', 'test@example.invalid']);
  git(root, ['config', 'user.name', 'Delegent Test']);
  git(root, ['config', 'commit.gpgsign', 'false']);
  fs.mkdirSync(path.join(root, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'docs', 'existing.md'), 'before\n', 'utf8');
  fs.writeFileSync(path.join(root, 'README.md'), 'readme\n', 'utf8');
  git(root, ['add', '-A']);
  git(root, ['commit', '--quiet', '-m', 'initial']);
  return root;
}

function cleanup(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (err) { /* best effort */ }
}

const affinity = 'delegent:testproj:docs:implementer';
const other = 'delegent:testproj:docs:reviewer';

// ---- affinity flattening ----

check(staging.flattenAffinity(affinity).indexOf(':') === -1, 'the affinity flattens away path-hostile characters');
check(staging.flattenAffinity(affinity).indexOf('/') === -1, 'the flattened affinity contains no separator');
check(staging.flattenAffinity(affinity) === staging.flattenAffinity(affinity), 'flattening is deterministic');
check(staging.flattenAffinity(affinity) !== staging.flattenAffinity(other), 'different affinities flatten differently');
// Two affinities that sanitize to the same string must still not collide.
check(staging.flattenAffinity('a:b') !== staging.flattenAffinity('a_b'), 'the digest prevents a sanitize collision');
const probeBase = path.join(os.tmpdir(), 'delegent-probe-base');
check(path.dirname(staging.stagingPathFor(probeBase, affinity)) === probeBase,
  'the staging path is a direct child of the base directory');

// The security property behind the flattening: an affinity is attacker-shaped
// input as far as this module is concerned, and no affinity may address a path
// outside the base directory.
for (const hostile of [
  '../../escape', 'a/../../b', 'C:/Windows/Temp', '/etc/passwd',
  '..\\..\\escape', 'a/b/c', 'delegent:x:..:..'
]) {
  const resolved = staging.stagingPathFor(probeBase, hostile);
  check(path.dirname(resolved) === probeBase, 'a hostile affinity ("' + hostile + '") cannot leave the base directory');
}

// ---- path comparison, which CI proved cannot be exact-string ----
//
// A GitHub Windows runner reported a staging tree as unregistered even though
// git had just created it: git's recorded path and ours differed in case and
// short-path form. Comparison folds case on win32, as the filesystem does.

check(staging.samePath(os.tmpdir(), os.tmpdir()), 'a path equals itself');
check(!staging.samePath(os.tmpdir(), path.join(os.tmpdir(), 'nope-' + Date.now())),
  'different paths are not equal');
check(!staging.samePath(null, os.tmpdir()), 'a missing path never matches');
check(staging.samePath(os.tmpdir(), os.tmpdir() + path.sep),
  'a trailing separator does not change identity');
if (process.platform === 'win32') {
  check(staging.samePath(os.tmpdir().toUpperCase(), os.tmpdir().toLowerCase()),
    'case is folded on Windows, as the filesystem does');
}

// ---- create, reuse, remove ----

let repo = makeRepo();
let base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-staging-base-')));

const before = staging.stagingStatus({ repoRoot: repo, baseDir: base, affinity: affinity });
check(before.exists === false, 'no staging tree exists before it is created');

const created = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(created.ok && created.created === true && created.reused === false, 'the first ensure creates the tree');
check(fs.existsSync(path.join(created.path, 'README.md')), 'the staging tree contains the repository content');
check(fs.realpathSync(created.path) !== repo, 'the staging tree is not the repository itself');
check(!fs.realpathSync(created.path).startsWith(repo + path.sep), 'the staging tree lives outside the repository');

// Detached, so no branch is created and status is a diff against HEAD.
const headState = git(created.path, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();
check(headState === 'HEAD', 'the staging tree is checked out detached, creating no branch');
check(git(repo, ['branch', '--list']).indexOf(staging.flattenAffinity(affinity)) === -1,
  'no branch is created in the parent repository');

const reused = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(reused.ok && reused.reused === true && reused.created === false, 'a second ensure reuses the same tree');
check(reused.path === created.path, 'reuse resolves to the same path');

// A different affinity is a different tree: that is what keeps an independent
// review from inheriting an implementer's uncommitted work.
const otherTree = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: other });
check(otherTree.ok && otherTree.created === true, 'a different affinity gets its own tree');
check(otherTree.path !== created.path, 'the two affinities do not share a tree');

const listed = staging.listWorktrees(repo);
check(listed.ok && listed.paths.length === 3, 'git reports the main tree plus both staging trees');

// ---- changes survive reuse, and are observable ----

fs.writeFileSync(path.join(created.path, 'docs', 'new.md'), 'added\n', 'utf8');
fs.writeFileSync(path.join(created.path, 'docs', 'existing.md'), 'after\n', 'utf8');

const observed = staging.observeChanges(created.path);
check(observed.ok, 'changes in the staging tree are observable');
check(observed.status.indexOf('docs/new.md') !== -1, 'a newly created file appears in the observed status');
check(observed.status.indexOf('docs/existing.md') !== -1, 'a modified file appears in the observed status');
check(observed.status.indexOf('\0') !== -1, 'the observed status is NUL-separated');

// The whole point of tying the tree to the affinity: work survives to the next turn.
const afterReuse = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(afterReuse.reused === true, 'ensure still reuses after the tree has changes');
check(fs.readFileSync(path.join(created.path, 'docs', 'new.md'), 'utf8') === 'added\n',
  'uncommitted work survives a reuse');

// The repository's own working tree must be untouched throughout.
check(git(repo, ['status', '--porcelain']).trim() === '', 'the parent repository working tree stays clean');
check(!fs.existsSync(path.join(repo, 'docs', 'new.md')), 'the new file did not appear in the repository');
check(fs.readFileSync(path.join(repo, 'docs', 'existing.md'), 'utf8') === 'before\n',
  'the repository copy of the modified file is unchanged');

// ---- the observed status feeds the verifier end to end ----

const scope = parseScope({ prefixes: ['docs'] }).scope;
const verdict = verifyMutation({
  scope: scope,
  reportedChanges: ['docs/new.md', 'docs/existing.md'],
  observedStatus: observed.status
});
check(verdict.ok, 'a truthful report of real staging-tree changes verifies');

const dishonest = verifyMutation({
  scope: scope,
  reportedChanges: ['docs/new.md'],
  observedStatus: observed.status
});
check(dishonest.reportingMismatch === true && dishonest.containmentBreach === false,
  'omitting a real change is caught as a reporting mismatch, not a breach');

// A write outside the scope, made directly, must read as a containment breach.
fs.writeFileSync(path.join(created.path, 'README.md'), 'tampered\n', 'utf8');
const breachStatus = staging.observeChanges(created.path);
const breach = verifyMutation({
  scope: scope,
  reportedChanges: ['docs/new.md', 'docs/existing.md', 'README.md'],
  observedStatus: breachStatus.status
});
check(breach.containmentBreach === true, 'an out-of-scope change in the tree is a containment breach');
check(breach.outOfScope.indexOf('README.md') !== -1, 'the breach names the out-of-scope file');

// ---- removal ----

const removedOther = staging.removeStagingTree({ repoRoot: repo, baseDir: base, affinity: other });
check(removedOther.ok && removedOther.removed === true, 'a clean staging tree is removed');
check(!fs.existsSync(otherTree.path), 'the removed tree is gone from disk');

// Removal must work on a dirty tree, or trees would leak forever.
const removedDirty = staging.removeStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(removedDirty.ok && removedDirty.removed === true, 'a staging tree with uncommitted changes is removed');
check(!fs.existsSync(created.path), 'the dirty tree is gone from disk');
check(staging.listWorktrees(repo).paths.length === 1, 'only the main worktree remains registered');
check(git(repo, ['status', '--porcelain']).trim() === '', 'removal left the repository clean');

const removedAgain = staging.removeStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(removedAgain.ok && removedAgain.alreadyAbsent === true, 'removing an absent tree is not an error');

// After removal the affinity can start over.
const recreated = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(recreated.ok && recreated.created === true, 'an affinity can be given a fresh tree after removal');
check(!fs.existsSync(path.join(recreated.path, 'docs', 'new.md')), 'the fresh tree does not carry the old work');
staging.removeStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });

cleanup(base);
cleanup(repo);

// ---- refusals ----

repo = makeRepo();
base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-staging-base-')));

check(!staging.ensureStagingTree({ repoRoot: repo, baseDir: base }).ok, 'ensure requires an affinity');
check(!staging.ensureStagingTree({ baseDir: base, affinity: affinity }).ok, 'ensure requires a repository');

// A stray directory where a worktree belongs is reported, never deleted: this
// module must not destroy something it was not asked to manage.
const strayPath = staging.stagingPathFor(base, affinity);
fs.mkdirSync(strayPath, { recursive: true });
fs.writeFileSync(path.join(strayPath, 'someones-work.txt'), 'do not delete me', 'utf8');
const stray = staging.ensureStagingTree({ repoRoot: repo, baseDir: base, affinity: affinity });
check(!stray.ok, 'a stray directory at the staging path is refused');
check(fs.existsSync(path.join(strayPath, 'someones-work.txt')), 'the stray directory is left intact');
cleanup(base);

// A repository with no commit has no HEAD to base a tree on.
const emptyRepo = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-empty-')));
git(emptyRepo, ['init', '--quiet']);
const emptyBase = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-empty-base-')));
const noHead = staging.ensureStagingTree({ repoRoot: emptyRepo, baseDir: emptyBase, affinity: affinity });
check(!noHead.ok && /HEAD/.test(noHead.reason), 'a repository with no commits is refused with a clear reason');
cleanup(emptyBase);
cleanup(emptyRepo);

check(!staging.observeChanges(path.join(base, 'does-not-exist')).ok, 'observing an absent tree is refused');
cleanup(repo);

if (failures === 0) {
  process.stdout.write('PASS Delegent staging tree ' + checks + ' assertions\n');
  process.exitCode = 0;
} else {
  process.stdout.write('FAIL Delegent staging tree: ' + failures + ' of ' + checks + ' assertions failed\n');
  process.exitCode = 1;
}
