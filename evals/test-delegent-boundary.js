'use strict';

// Deterministic tests for the shared Delegent boundary: the exact validator,
// the Context Firewall, and the Worker's path containment. No provider, no
// credential, no network.
//
// These properties are the ones the live gates take for granted, so they are
// pinned here rather than inferred from a passing run. Path containment in
// particular is security-critical: it is the only thing standing between a
// model-chosen path and the rest of the filesystem.

const fs = require('fs');
const os = require('os');
const path = require('path');

const toolsDir = path.resolve(__dirname, '..', 'skills', 'delegating-work', 'tools');
const { validate, filterSensitive, filterHandoff } = require(path.join(toolsDir, 'delegent-schema.js'));
const { resolveContainedPath, readFileTool } = require(path.join(toolsDir, 'delegent-nim-worker.js'));

const schemaPath = path.resolve(__dirname, '..', 'skills', 'delegating-work', 'schemas', 'delegent-handoff.schema.json');
const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const repoRoot = path.resolve(__dirname, '..');

let failures = 0;
let checks = 0;

function check(condition, message) {
  checks++;
  if (!condition) {
    failures++;
    process.stdout.write('FAIL  ' + message + '\n');
  }
}

const validHandoff = {
  status: 'completed',
  summary: 'Inspected the README and reported findings.',
  evidence: ['README.md: Context-aware coding-agent orchestration for Codex.'],
  changes: [],
  tests: [],
  risks: [],
  decisions_needed: [],
  review_targets: []
};

// ---- Exact validation ----

check(validate(validHandoff, schema).length === 0, 'a conforming handoff has no violations');

// A property with no enum must not be treated as an enum. This is the mistake
// the PowerShell side made, where @($null).Count is 1, and it rejected every
// free-text field.
check(validate(validHandoff, schema).length === 0, 'free-text fields are not treated as enums');

function withoutField(name) {
  const copy = JSON.parse(JSON.stringify(validHandoff));
  delete copy[name];
  return copy;
}
for (const field of Object.keys(schema.properties)) {
  const violations = validate(withoutField(field), schema);
  check(violations.length === 1 && violations[0] === '$.' + field + ' is missing',
    'a missing ' + field + ' is reported exactly once');
}

const withExtra = Object.assign({}, validHandoff, { surprise: 'nope' });
check(validate(withExtra, schema).some((v) => v.indexOf('is not allowed') !== -1),
  'an unknown field is rejected');

const badStatus = Object.assign({}, validHandoff, { status: 'finished' });
check(validate(badStatus, schema).some((v) => v.indexOf('outside its allowed values') !== -1),
  'a status outside the enum is rejected');

const scalarForArray = Object.assign({}, validHandoff, { evidence: 'not-an-array' });
check(validate(scalarForArray, schema).some((v) => v.indexOf('is not an array') !== -1),
  'a scalar where a list is required is rejected');

const numberForString = Object.assign({}, validHandoff, { summary: 42 });
check(validate(numberForString, schema).some((v) => v.indexOf('is not a string') !== -1),
  'a non-string summary is rejected');

const nestedWrongType = Object.assign({}, validHandoff, { evidence: [7] });
check(validate(nestedWrongType, schema).some((v) => v.indexOf('$.evidence[0]') !== -1),
  'a wrongly typed list element is reported with its index');

check(validate([], schema).length === 1, 'an array where an object is required is rejected');
check(validate('nope', schema).length === 1, 'a string where an object is required is rejected');
check(validate(null, schema).length === 1, 'null where an object is required is rejected');

// ---- Context Firewall ----

const credential = 'nvapi-0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijkl';
check(filterSensitive('key is ' + credential, credential).indexOf(credential) === -1,
  'the exact credential is redacted');
check(filterSensitive('nvapi-someothertokenvalue123456', credential).indexOf('nvapi-someother') === -1,
  'any nvapi-shaped token is redacted');
check(filterSensitive('Authorization: Bearer abc.def.ghi', credential).indexOf('abc.def.ghi') === -1,
  'a bearer token is redacted');
check(filterSensitive('api_key=hunter2secretvalue', credential).indexOf('hunter2secretvalue') === -1,
  'an api_key assignment is redacted');
check(filterSensitive('password: correcthorsebattery', credential).indexOf('correcthorsebattery') === -1,
  'a password assignment is redacted');
check(filterSensitive('README.md line 3', credential) === 'README.md line 3',
  'ordinary evidence text is left intact');

const leaky = Object.assign({}, validHandoff, {
  summary: 'used ' + credential,
  evidence: ['token ' + credential, 'README.md is fine']
});
const filtered = filterHandoff(leaky, schema, credential);
check(JSON.stringify(filtered.handoff).indexOf(credential) === -1,
  'the credential does not survive handoff filtering');
// status, summary and both evidence entries: every declared string, including
// the enum-constrained one, passes through the firewall.
check(filtered.filteredStringCount === 4, 'every declared string is filtered and counted');
check(filtered.handoff.evidence[1] === 'README.md is fine', 'filtering preserves clean evidence');
check(validate(filtered.handoff, schema).length === 0, 'a filtered handoff still satisfies the schema');

// ---- Path containment (security-critical) ----

check(resolveContainedPath(repoRoot, 'README.md').ok, 'a repository-relative file resolves');
check(!resolveContainedPath(repoRoot, '').ok, 'an empty path is refused');
check(!resolveContainedPath(repoRoot, undefined).ok, 'a missing path is refused');
check(!resolveContainedPath(repoRoot, path.join(repoRoot, 'README.md')).ok,
  'an absolute path is refused even inside the repository');
check(!resolveContainedPath(repoRoot, '../../../Windows/System32/drivers/etc/hosts').ok,
  'a parent-directory escape is refused');
check(!resolveContainedPath(repoRoot, 'does-not-exist-' + Date.now() + '.txt').ok,
  'a missing file is reported, not created');
check(!resolveContainedPath(repoRoot, '.').ok, 'a directory is refused');
check(!resolveContainedPath(repoRoot, 'evals').ok, 'a subdirectory is refused');

const escaped = resolveContainedPath(repoRoot, '..');
check(!escaped.ok, 'the parent directory itself is refused');

// A symlink pointing outside the repository must not be followed out of it.
// Creating one needs privileges on Windows, so this arm is skipped when it
// cannot be created rather than reported as a pass.
const linkName = 'delegent-escape-link-' + Date.now();
const linkPath = path.join(repoRoot, linkName);
let symlinkTested = false;
try {
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-outside-'));
  const outsideFile = path.join(outsideDir, 'secret.txt');
  fs.writeFileSync(outsideFile, 'should never be readable through the repo', 'utf8');
  fs.symlinkSync(outsideFile, linkPath, 'file');
  symlinkTested = true;
  const viaLink = resolveContainedPath(repoRoot, linkName);
  check(!viaLink.ok, 'a symlink out of the repository is refused');
  const read = readFileTool({ path: linkName }, repoRoot);
  check(!read.ok, 'read_file refuses to follow a symlink out of the repository');
} catch (err) {
  process.stdout.write('SKIP  symlink escape arm (' + (err && err.code ? err.code : 'unavailable') + ')\n');
} finally {
  try { if (fs.existsSync(linkPath)) fs.unlinkSync(linkPath); } catch (err) { /* best effort */ }
}

// ---- read_file behaviour ----

const readOk = readFileTool({ path: 'README.md', max_lines: 3 }, repoRoot);
check(readOk.ok, 'read_file reads a contained file');
check(readOk.output.split('\n').length <= 3, 'read_file honours max_lines');
check(!readFileTool({ path: '../outside.txt' }, repoRoot).ok, 'read_file refuses an escape');

if (failures === 0) {
  process.stdout.write('PASS Delegent boundary ' + checks + ' assertions' +
    (symlinkTested ? ' (incl. symlink escape)' : ' (symlink arm skipped)') + '\n');
  process.exitCode = 0;
} else {
  process.stdout.write('FAIL Delegent boundary: ' + failures + ' of ' + checks + ' assertions failed\n');
  process.exitCode = 1;
}
