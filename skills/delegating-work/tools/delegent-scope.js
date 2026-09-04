'use strict';

// Mutation scope, in one place.
//
// The write tool and the verifier must agree on what "in scope" means. If they
// disagreed, a write could be permitted and then flagged, or — far worse —
// permitted and not flagged. So both call this module and neither decides for
// itself.
//
// Per ADR-0003: the Lead declares directory prefixes and exact paths before the
// work; globs are rejected rather than tolerated. A glob is a small language
// with Windows-specific surprises, and in a security check every surprise is a
// hole. Nothing here silently normalises a suspicious path into an acceptable
// one — a path that does not parse is refused, not repaired.

const fs = require('fs');
const path = require('path');

const MAX_WRITE_BYTES = 1024 * 1024;

// Canonicalising a path is security-critical here -- every containment check
// compares against one -- so it has a single implementation.
//
// `fs.realpathSync` resolves symlinks but does NOT expand Windows 8.3 short
// names. CI proved the difference: a runner produced
// `C:\Users\RUNNER~1\...` on one side and `C:\Users\runneradmin\...` on the
// other for the same directory, and a containment check comparing them would
// answer "different" about one path. `realpathSync.native` expands both,
// because it asks Windows for the final name rather than walking links itself.
function canonicalPath(target) {
  try {
    if (typeof fs.realpathSync.native === 'function') return fs.realpathSync.native(target);
  } catch (err) {
    // Fall through: a missing path is the caller's problem to report.
  }
  return fs.realpathSync(target);
}

// Windows paths are case-insensitive, so `DOCS/x` and `docs/x` are the same
// file. Comparing case-sensitively would let the filesystem fold a path into a
// directory the scope check thought it had rejected. Folding matches the
// filesystem, which is the behaviour that actually governs where bytes land.
function foldPath(relative) {
  return relative.toLowerCase();
}

// Repo-relative, forward-slash, no traversal, no glob. Returns a reason rather
// than throwing, so callers can report it to a Worker verbatim.
function normalizeRepoPath(candidate) {
  if (typeof candidate !== 'string' || candidate.trim().length === 0) {
    return { ok: false, reason: 'path is required' };
  }
  if (/[*?]/.test(candidate) || candidate.indexOf('[') !== -1) {
    return { ok: false, reason: 'path must be literal; glob patterns are not accepted' };
  }
  if (candidate.indexOf('\0') !== -1) {
    return { ok: false, reason: 'path contains a null byte' };
  }

  const unified = candidate.split('\\').join('/');
  if (path.posix.isAbsolute(unified) || /^[A-Za-z]:/.test(unified) || unified.startsWith('//')) {
    return { ok: false, reason: 'path must be relative to the repository root' };
  }

  const segments = [];
  for (const segment of unified.split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment === '..') return { ok: false, reason: 'path must not traverse upwards' };
    segments.push(segment);
  }
  if (segments.length === 0) return { ok: false, reason: 'path resolves to the repository root' };

  return { ok: true, path: segments.join('/') };
}

// A declared scope: directory prefixes plus exact paths. Both are normalized
// through the same rules the Worker's paths are, so a scope cannot express
// something a path could never match.
function parseScope(raw) {
  const source = raw || {};
  const prefixes = [];
  const paths = [];

  for (const entry of source.prefixes || []) {
    const normalized = normalizeRepoPath(entry);
    if (!normalized.ok) return { ok: false, reason: 'scope prefix "' + entry + '": ' + normalized.reason };
    prefixes.push(normalized.path);
  }
  for (const entry of source.paths || []) {
    const normalized = normalizeRepoPath(entry);
    if (!normalized.ok) return { ok: false, reason: 'scope path "' + entry + '": ' + normalized.reason };
    paths.push(normalized.path);
  }

  if (prefixes.length === 0 && paths.length === 0) {
    return { ok: false, reason: 'a mutation scope must declare at least one prefix or path' };
  }
  return { ok: true, scope: { prefixes: prefixes, paths: paths } };
}

// Prefix matching is by path segment, never by string prefix: `docs` must cover
// `docs/x` and must not cover `docs2/x`.
function isInScope(scope, relativePath) {
  const normalized = normalizeRepoPath(relativePath);
  if (!normalized.ok) return false;
  const target = foldPath(normalized.path);

  for (const exact of scope.paths || []) {
    if (foldPath(exact) === target) return true;
  }
  for (const prefix of scope.prefixes || []) {
    const folded = foldPath(prefix);
    if (target === folded) return true;
    if (target.startsWith(folded + '/')) return true;
  }
  return false;
}

function describeScope(scope) {
  const parts = [];
  for (const prefix of scope.prefixes || []) parts.push(prefix + '/');
  for (const exact of scope.paths || []) parts.push(exact);
  return parts.join(', ');
}

// Resolves where a write would actually land, and refuses if that is anywhere
// other than inside the root and inside the scope.
//
// The target may not exist yet, so realpath cannot be called on it directly.
// Instead the deepest existing ancestor is resolved — which collapses any
// symlink in the existing part of the path — and the remaining segments are
// appended. Since normalization already removed `..`, appending cannot escape.
function resolveWriteTarget(root, scope, relativePath) {
  const normalized = normalizeRepoPath(relativePath);
  if (!normalized.ok) return { ok: false, reason: normalized.reason };

  if (!isInScope(scope, normalized.path)) {
    return {
      ok: false,
      outOfScope: true,
      reason: 'path is outside the declared mutation scope (' + describeScope(scope) + ')'
    };
  }

  let realRoot;
  try {
    realRoot = canonicalPath(root);
  } catch (err) {
    return { ok: false, reason: 'staging root does not exist' };
  }

  const segments = normalized.path.split('/');
  let existingDepth = segments.length - 1;
  let ancestor = null;
  while (existingDepth >= 0) {
    const candidate = path.join(realRoot, ...segments.slice(0, existingDepth));
    if (fs.existsSync(candidate)) {
      ancestor = candidate;
      break;
    }
    existingDepth--;
  }
  if (ancestor === null) return { ok: false, reason: 'staging root does not exist' };

  let realAncestor;
  try {
    realAncestor = canonicalPath(ancestor);
  } catch (err) {
    return { ok: false, reason: 'could not resolve an existing parent of the path' };
  }
  if (realAncestor !== realRoot && !realAncestor.startsWith(realRoot + path.sep)) {
    return { ok: false, outOfScope: true, reason: 'path escapes the staging root through a link' };
  }
  if (!fs.statSync(realAncestor).isDirectory()) {
    return { ok: false, reason: 'a parent of the path is not a directory' };
  }

  const remaining = segments.slice(existingDepth);
  const target = remaining.length === 0 ? realAncestor : path.join(realAncestor, ...remaining);
  if (target !== realRoot && !target.startsWith(realRoot + path.sep)) {
    return { ok: false, outOfScope: true, reason: 'path escapes the staging root' };
  }

  // An existing target must be an ordinary file. A symlink is refused outright
  // rather than resolved, because writing through one lands wherever it points.
  if (fs.existsSync(target)) {
    const stats = fs.lstatSync(target);
    if (stats.isSymbolicLink()) return { ok: false, outOfScope: true, reason: 'refusing to write through a symlink' };
    if (!stats.isFile()) return { ok: false, reason: 'target exists and is not a regular file' };
  }

  return {
    ok: true,
    absolute: target,
    relative: normalized.path,
    existed: fs.existsSync(target),
    parentToCreate: remaining.length > 1
  };
}

// ---- Observed changes ----

// Parses `git status --porcelain=v1 -z`. The NUL-separated form is used
// deliberately: git quotes and escapes paths in the human form, and a parser
// that has to unquote is a parser that can be fooled.
//
// Rename and copy entries carry a second path field. Neither is a permitted
// operation, so they are reported as disallowed rather than resolved.
function parseGitStatusZ(text) {
  const changes = [];
  const disallowedOps = [];
  if (typeof text !== 'string' || text.length === 0) {
    return { changes: changes, disallowedOps: disallowedOps };
  }

  const fields = text.split('\0');
  for (let i = 0; i < fields.length; i++) {
    const entry = fields[i];
    if (!entry || entry.length < 4) continue;
    const code = entry.slice(0, 2);
    const filePath = entry.slice(3).split('\\').join('/');
    if (code[0] === 'R' || code[0] === 'C') {
      // The following field is the original path; consume it so it is not read
      // as a separate change.
      const original = fields[i + 1];
      i++;
      disallowedOps.push({
        status: code.trim(),
        path: filePath,
        from: original ? original.split('\\').join('/') : null
      });
      continue;
    }
    changes.push({ status: code.trim(), path: filePath });
  }
  return { changes: changes, disallowedOps: disallowedOps };
}

// ---- The verifier ----
//
// Three-way agreement between the declared scope, what the Worker reported, and
// what actually changed. The two failure kinds are kept apart on purpose:
//
//   containment  an observed change outside the declared scope. The write tool
//                should have made this impossible, so observing one means OUR
//                code is defective. Never retried.
//   reporting    the Worker's `changes` disagree with the observed diff. That is
//                the Worker misreporting, and is a reject-and-correct case.
function verifyMutation(input) {
  const scope = input.scope;
  const observed = parseGitStatusZ(input.observedStatus || '');
  const observedPaths = observed.changes.map((c) => c.path);

  const reported = [];
  for (const entry of input.reportedChanges || []) {
    const normalized = normalizeRepoPath(entry);
    reported.push(normalized.ok ? normalized.path : String(entry));
  }

  const foldedReported = reported.map(foldPath);
  const foldedObserved = observedPaths.map(foldPath);

  const outOfScope = observedPaths.filter((p) => !isInScope(scope, p));
  const unreported = observedPaths.filter((p) => foldedReported.indexOf(foldPath(p)) === -1);
  const overreported = reported.filter((p) => foldedObserved.indexOf(foldPath(p)) === -1);

  const containmentBreach = outOfScope.length > 0 || observed.disallowedOps.length > 0;
  const reportingMismatch = unreported.length > 0 || overreported.length > 0;

  return {
    ok: !containmentBreach && !reportingMismatch,
    containmentBreach: containmentBreach,
    reportingMismatch: reportingMismatch,
    outOfScope: outOfScope,
    disallowedOps: observed.disallowedOps,
    unreported: unreported,
    overreported: overreported,
    observedPaths: observedPaths
  };
}

module.exports = {
  MAX_WRITE_BYTES,
  canonicalPath,
  normalizeRepoPath,
  parseScope,
  isInScope,
  describeScope,
  resolveWriteTarget,
  parseGitStatusZ,
  verifyMutation
};

// A verify CLI so an orchestrator in another language drives this
// implementation instead of growing a second one. The payload arrives as JSON
// on stdin because the observed status is NUL-separated and would not survive
// argv intact.
//
//   node delegent-scope.js verify   < payload.json
//   payload: { scope: {prefixes, paths}, reportedChanges: [...], observedStatus: "..." }
if (require.main === module) {
  if (process.argv[2] !== 'verify') {
    process.stdout.write(JSON.stringify({ ok: false, reason: 'unknown command; expected: verify' }) + '\n');
    process.exitCode = 2;
  } else {
    let raw = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { raw += chunk; });
    process.stdin.on('end', () => {
      let payload;
      try {
        // A .NET StreamWriter — which is what a PowerShell orchestrator writes
        // stdin through — prefixes a UTF-8 BOM, and JSON.parse rejects it. Strip
        // it here rather than requiring every caller to know that.
        payload = JSON.parse(raw.replace(/^\uFEFF/, '').trim());
      } catch (err) {
        process.stdout.write(JSON.stringify({ ok: false, reason: 'stdin was not valid JSON' }) + '\n');
        process.exitCode = 2;
        return;
      }
      const parsed = parseScope(payload.scope);
      if (!parsed.ok) {
        process.stdout.write(JSON.stringify({ ok: false, reason: parsed.reason }) + '\n');
        process.exitCode = 2;
        return;
      }
      const verdict = verifyMutation({
        scope: parsed.scope,
        reportedChanges: payload.reportedChanges,
        observedStatus: payload.observedStatus
      });
      process.stdout.write(JSON.stringify(verdict) + '\n');
      process.exitCode = verdict.ok ? 0 : 1;
    });
  }
}
