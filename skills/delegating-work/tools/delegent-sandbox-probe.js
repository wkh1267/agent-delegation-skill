'use strict';

// The child half of the sandbox enforcement check. Run under
// `codex sandbox -P :workspace -C <staging tree>` by delegent-sandbox.js, it
// reports whether a write inside the tree is allowed and a write outside it is
// denied. Both halves matter: a sandbox that denied everything would look
// "enforcing" while being useless.
//
// Nothing is left behind. If containment has failed, the probe cleans up its own
// evidence rather than leaving a stray file in someone's directory.

const fs = require('fs');
const path = require('path');

const outsideDir = process.argv[2];
const result = { inside: 'unknown', outside: 'unknown' };

const insideFile = path.join(process.cwd(), '.delegent-sandbox-probe-inside');
try {
  fs.writeFileSync(insideFile, 'probe', 'utf8');
  result.inside = 'allowed';
  try { fs.unlinkSync(insideFile); } catch (err) { result.inside = 'allowed-not-cleaned'; }
} catch (err) {
  result.inside = 'denied';
}

if (!outsideDir) {
  result.outside = 'no-target';
} else {
  const outsideFile = path.join(outsideDir, '.delegent-sandbox-probe-outside');
  try {
    fs.mkdirSync(outsideDir, { recursive: true });
    fs.writeFileSync(outsideFile, 'probe', 'utf8');
    result.outside = 'allowed';
    try { fs.unlinkSync(outsideFile); } catch (err) { result.outside = 'allowed-not-cleaned'; }
    try { fs.rmdirSync(outsideDir); } catch (err) { /* may not be empty; leave it */ }
  } catch (err) {
    result.outside = 'denied';
  }
}

// Network is checked because a Worker cannot function without reaching its
// provider, and whether `:workspace` permits it depends on the Windows sandbox
// backend: the elevated backend blocks it, the unelevated one does not. Without
// this arm, a misconfigured sandbox surfaces as three provider retries and an
// unexplained failure rather than one clear precheck.
const target = process.argv[3] || 'https://integrate.api.nvidia.com/v1/models';
fetch(target, { method: 'GET' })
  .then((response) => { result.network = 'reachable:' + response.status; })
  .catch(() => { result.network = 'blocked'; })
  .then(() => {
    process.stdout.write('DELEGENT_SANDBOX_PROBE ' + JSON.stringify(result) + '\n');
  });
