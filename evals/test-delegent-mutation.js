'use strict';

// D4a — deterministic tests for the mutation boundary. No model, no network, no
// credential. Everything security-critical about mutation lives here, so that a
// later live gate misbehaving cannot be blamed on this layer.
//
// Writes happen only inside a temp staging root created per assertion group and
// removed afterwards. Nothing here touches the repository.

const fs = require('fs');
const os = require('os');
const path = require('path');

const toolsDir = path.resolve(__dirname, '..', 'skills', 'delegating-work', 'tools');
const scope = require(path.join(toolsDir, 'delegent-scope.js'));
const { writeFileTool } = require(path.join(toolsDir, 'delegent-nim-worker.js'));

const {
  MAX_WRITE_BYTES, normalizeRepoPath, parseScope, isInScope,
  resolveWriteTarget, parseGitStatusZ, verifyMutation
} = scope;

let failures = 0;
let checks = 0;

function check(condition, message) {
  checks++;
  if (!condition) {
    failures++;
    process.stdout.write('FAIL  ' + message + '\n');
  }
}

function makeRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-staging-'));
  fs.mkdirSync(path.join(root, 'docs', 'decisions'), { recursive: true });
  fs.mkdirSync(path.join(root, 'src'), { recursive: true });
  fs.writeFileSync(path.join(root, 'docs', 'existing.md'), 'before', 'utf8');
  fs.writeFileSync(path.join(root, 'README.md'), 'readme', 'utf8');
  return fs.realpathSync(root);
}

function cleanup(root) {
  try { fs.rmSync(root, { recursive: true, force: true }); } catch (err) { /* best effort */ }
}

// ---- normalizeRepoPath ----

check(normalizeRepoPath('docs/a.md').path === 'docs/a.md', 'a plain relative path normalizes');
check(normalizeRepoPath('docs\\a.md').path === 'docs/a.md', 'backslashes normalize to forward slashes');
check(normalizeRepoPath('./docs//a.md').path === 'docs/a.md', 'redundant segments collapse');
check(!normalizeRepoPath('').ok, 'an empty path is refused');
check(!normalizeRepoPath('   ').ok, 'a whitespace path is refused');
check(!normalizeRepoPath(undefined).ok, 'a missing path is refused');
check(!normalizeRepoPath('/etc/passwd').ok, 'a posix absolute path is refused');
check(!normalizeRepoPath('C:/Windows/x').ok, 'a drive-letter absolute path is refused');
check(!normalizeRepoPath('\\\\server\\share\\x').ok, 'a UNC path is refused');
check(!normalizeRepoPath('../outside.md').ok, 'a parent escape is refused');
check(!normalizeRepoPath('docs/../../outside.md').ok, 'an embedded parent escape is refused');
check(!normalizeRepoPath('.').ok, 'the repository root itself is refused');

// Globs are rejected outright rather than matched literally: a literal `*`
// would silently match nothing, which is a confusing way to fail.
check(!normalizeRepoPath('src/**/*.ts').ok, 'a glob is refused');
check(!normalizeRepoPath('src/a?.ts').ok, 'a single-character wildcard is refused');
check(!normalizeRepoPath('src/[ab].ts').ok, 'a character class is refused');

// ---- parseScope ----

check(parseScope({ prefixes: ['docs'] }).ok, 'a prefix-only scope parses');
check(parseScope({ paths: ['README.md'] }).ok, 'a path-only scope parses');
check(!parseScope({}).ok, 'an empty scope is refused');
check(!parseScope({ prefixes: [] , paths: [] }).ok, 'a scope with empty lists is refused');
check(!parseScope({ prefixes: ['src/**'] }).ok, 'a glob prefix is refused');
check(!parseScope({ paths: ['../x'] }).ok, 'an escaping scope path is refused');
check(!parseScope({ paths: ['C:/x'] }).ok, 'an absolute scope path is refused');
check(parseScope({ prefixes: ['docs\\decisions'] }).scope.prefixes[0] === 'docs/decisions',
  'a scope prefix is normalized');

// ---- isInScope: segment prefixes, not string prefixes ----

const docsScope = parseScope({ prefixes: ['docs'], paths: ['README.md'] }).scope;
check(isInScope(docsScope, 'docs/a.md'), 'a file under the prefix is in scope');
check(isInScope(docsScope, 'docs/decisions/b.md'), 'a nested file under the prefix is in scope');
check(isInScope(docsScope, 'README.md'), 'an exact declared path is in scope');
// The classic bug this guards: string-prefix matching would let `docs2` through.
check(!isInScope(docsScope, 'docs2/a.md'), 'a sibling directory sharing a name prefix is NOT in scope');
check(!isInScope(docsScope, 'docsomething'), 'a file whose name starts with the prefix is NOT in scope');
check(!isInScope(docsScope, 'src/a.ts'), 'an unrelated path is not in scope');
check(!isInScope(docsScope, 'README.md.bak'), 'a path extending an exact match is not in scope');
check(!isInScope(docsScope, '../docs/a.md'), 'an escaping path is never in scope');
// Windows folds case, so the scope check must fold too or the filesystem could
// land a write in a directory the check believed it had rejected.
check(isInScope(docsScope, 'DOCS/a.md'), 'prefix matching folds case, as the filesystem does');
check(isInScope(docsScope, 'readme.md'), 'exact matching folds case, as the filesystem does');

// ---- resolveWriteTarget ----

let root = makeRoot();
check(resolveWriteTarget(root, docsScope, 'docs/new.md').ok, 'an in-scope new file resolves');
check(resolveWriteTarget(root, docsScope, 'docs/existing.md').existed === true, 'an existing target is reported as existing');
check(resolveWriteTarget(root, docsScope, 'docs/new.md').existed === false, 'a new target is reported as new');
check(resolveWriteTarget(root, docsScope, 'docs/deep/new/x.md').ok, 'a new nested path resolves');
check(resolveWriteTarget(root, docsScope, 'docs/deep/new/x.md').parentToCreate === true,
  'a new nested path reports that a parent must be created');

const outOfScope = resolveWriteTarget(root, docsScope, 'src/a.ts');
check(!outOfScope.ok && outOfScope.outOfScope === true, 'an out-of-scope path is refused and flagged as such');
const escaping = resolveWriteTarget(root, docsScope, '../outside.md');
check(!escaping.ok, 'an escaping path is refused');
check(!resolveWriteTarget(root, docsScope, 'docs').ok, 'a directory target is refused');

// A symlink must never be written through, because the bytes would land wherever
// it points. Skipped rather than silently passed when it cannot be created.
let symlinkTested = false;
try {
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-outside-'));
  const outsideFile = path.join(outsideDir, 'secret.txt');
  fs.writeFileSync(outsideFile, 'must not be overwritten', 'utf8');
  fs.symlinkSync(outsideFile, path.join(root, 'docs', 'link.md'), 'file');
  symlinkTested = true;
  const viaLink = resolveWriteTarget(root, docsScope, 'docs/link.md');
  check(!viaLink.ok && viaLink.outOfScope === true, 'writing through a symlink is refused');

  fs.symlinkSync(outsideDir, path.join(root, 'docs', 'linkdir'), 'dir');
  const viaLinkDir = resolveWriteTarget(root, docsScope, 'docs/linkdir/x.md');
  check(!viaLinkDir.ok, 'writing through a symlinked directory is refused');
  check(fs.readFileSync(outsideFile, 'utf8') === 'must not be overwritten', 'the outside file is untouched');
} catch (err) {
  process.stdout.write('SKIP  symlink write arms (' + (err && err.code ? err.code : 'unavailable') + ')\n');
}
cleanup(root);

// ---- writeFileTool ----

root = makeRoot();
const emitted = [];
const ctx = { root: root, scope: docsScope, emit: (e) => emitted.push(e) };

const created = writeFileTool({ path: 'docs/new.md', content: 'hello' }, ctx);
check(created.ok && created.output.indexOf('CREATED') !== -1, 'an in-scope create succeeds');
check(fs.readFileSync(path.join(root, 'docs', 'new.md'), 'utf8') === 'hello', 'the content is written');

const overwritten = writeFileTool({ path: 'docs/existing.md', content: 'after' }, ctx);
check(overwritten.ok && overwritten.output.indexOf('OVERWROTE') !== -1, 'an in-scope overwrite succeeds');
check(fs.readFileSync(path.join(root, 'docs', 'existing.md'), 'utf8') === 'after', 'the overwrite replaces content');

const nested = writeFileTool({ path: 'docs/deep/new/x.md', content: 'x' }, ctx);
check(nested.ok, 'a write creates missing parent directories inside scope');
check(fs.existsSync(path.join(root, 'docs', 'deep', 'new', 'x.md')), 'the nested file exists');

const refusedScope = writeFileTool({ path: 'src/a.ts', content: 'x' }, ctx);
check(!refusedScope.ok && refusedScope.output.indexOf('WRITE_REFUSED') !== -1, 'an out-of-scope write is refused');
check(!fs.existsSync(path.join(root, 'src', 'a.ts')), 'the refused write created nothing');

check(!writeFileTool({ path: '../outside.md', content: 'x' }, ctx).ok, 'an escaping write is refused');
check(!writeFileTool({ path: 'docs/a.md' }, ctx).ok, 'a write with no content is refused');
check(!writeFileTool({ path: 'docs/a.md', content: 42 }, ctx).ok, 'a non-string content is refused');
check(!writeFileTool({ path: 'docs/glob*.md', content: 'x' }, ctx).ok, 'a glob write path is refused');
check(!writeFileTool({ path: 'docs/big.md', content: 'x'.repeat(MAX_WRITE_BYTES + 1) }, ctx).ok,
  'a write over the size limit is refused');
check(!fs.existsSync(path.join(root, 'docs', 'big.md')), 'the oversized write created nothing');
check(!writeFileTool({ path: 'docs/a.md', content: 'x' }, { root: root, scope: null, emit: ctx.emit }).ok,
  'writing with no declared scope is refused');

// The events a successful write emits are what the live gate will assert on.
const writeEvents = emitted.filter((e) => e.item && e.item.type === 'write');
check(writeEvents.length === 3, 'exactly the three successful writes emitted an event');
check(writeEvents[0].item.created === true, 'a create is reported as created');
check(writeEvents[1].item.created === false, 'an overwrite is reported as not created');
check(writeEvents.every((e) => typeof e.item.bytes === 'number'), 'each write reports its byte count');
check(!writeEvents.some((e) => e.item.path === 'src/a.ts'), 'a refused write emitted no event');
cleanup(root);

// ---- parseGitStatusZ ----

const status = parseGitStatusZ('?? docs/new.md\0 M docs/existing.md\0A  src/a.ts\0');
check(status.changes.length === 3, 'three changes parse');
check(status.changes.some((c) => c.path === 'docs/new.md' && c.status === '??'), 'an untracked file parses');
check(status.changes.some((c) => c.path === 'docs/existing.md' && c.status === 'M'), 'a modified file parses');
check(status.disallowedOps.length === 0, 'a plain status reports no disallowed operations');

// The NUL form is used precisely so a path with a space needs no unquoting.
const spaced = parseGitStatusZ('?? docs/with space.md\0');
check(spaced.changes.length === 1 && spaced.changes[0].path === 'docs/with space.md',
  'a path containing a space parses without quoting');

// A rename carries a second field. Renames are not permitted, so it must be
// reported as disallowed and its original path must not become a separate change.
const renamed = parseGitStatusZ('R  docs/new.md\0docs/old.md\0 M README.md\0');
check(renamed.disallowedOps.length === 1, 'a rename is reported as a disallowed operation');
check(renamed.disallowedOps[0].from === 'docs/old.md', 'the rename records where it came from');
check(!renamed.changes.some((c) => c.path === 'docs/old.md'), 'the rename source is not counted as a change');
check(renamed.changes.some((c) => c.path === 'README.md'), 'changes after a rename still parse');
check(parseGitStatusZ('').changes.length === 0, 'an empty status parses to no changes');

// ---- verifyMutation: the two failures stay apart ----

const clean = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/new.md', 'docs/existing.md'],
  observedStatus: '?? docs/new.md\0 M docs/existing.md\0'
});
check(clean.ok, 'agreement between scope, report and diff passes');
check(!clean.containmentBreach && !clean.reportingMismatch, 'a clean result flags neither failure');

const breach = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/new.md', 'src/sneaky.ts'],
  observedStatus: '?? docs/new.md\0?? src/sneaky.ts\0'
});
check(!breach.ok, 'an out-of-scope change fails');
check(breach.containmentBreach === true, 'an out-of-scope change is a containment breach');
check(breach.reportingMismatch === false, 'reporting it honestly is not also a reporting mismatch');
check(breach.outOfScope.indexOf('src/sneaky.ts') !== -1, 'the breach names the offending path');

const unreported = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/new.md'],
  observedStatus: '?? docs/new.md\0 M docs/existing.md\0'
});
check(!unreported.ok, 'an unreported in-scope change fails');
check(unreported.reportingMismatch === true, 'an unreported change is a reporting mismatch');
check(unreported.containmentBreach === false, 'an unreported in-scope change is NOT a containment breach');
check(unreported.unreported.indexOf('docs/existing.md') !== -1, 'the mismatch names the unreported path');

const overreported = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/new.md', 'docs/imagined.md'],
  observedStatus: '?? docs/new.md\0'
});
check(!overreported.ok, 'a claimed change that did not happen fails');
check(overreported.reportingMismatch === true, 'a claimed non-change is a reporting mismatch');
check(overreported.containmentBreach === false, 'a claimed non-change is not a containment breach');
check(overreported.overreported.indexOf('docs/imagined.md') !== -1, 'the mismatch names the imagined path');

// Both at once must report both, so neither hides the other.
const both = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/imagined.md'],
  observedStatus: '?? src/sneaky.ts\0'
});
check(both.containmentBreach === true && both.reportingMismatch === true,
  'a breach and a mismatch together are both reported');

// A rename inside scope is still a disallowed operation, not merely a change.
const renameInScope = verifyMutation({
  scope: docsScope,
  reportedChanges: ['docs/b.md'],
  observedStatus: 'R  docs/b.md\0docs/a.md\0'
});
check(renameInScope.containmentBreach === true,
  'a rename is a containment breach even entirely inside the scope');

check(verifyMutation({ scope: docsScope, reportedChanges: [], observedStatus: '' }).ok,
  'no changes reported and none observed passes');

if (failures === 0) {
  process.stdout.write('PASS Delegent mutation boundary ' + checks + ' assertions' +
    (symlinkTested ? ' (incl. symlink writes)' : ' (symlink arms skipped)') + '\n');
  process.exitCode = 0;
} else {
  process.stdout.write('FAIL Delegent mutation boundary: ' + failures + ' of ' + checks + ' assertions failed\n');
  process.exitCode = 1;
}
