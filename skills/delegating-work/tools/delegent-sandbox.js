#!/usr/bin/env node
'use strict';

// The second layer under the mutation boundary.
//
// Per ADR-0003 our own tool layer is the primary control, because it is more
// precise: it enforces the declared scope, not just a directory. This module is
// the floor beneath it, so a defect in that layer cannot put bytes outside the
// staging tree.
//
// Verified behaviour of `codex sandbox -P :workspace -C <dir>` on this host:
//
//   stdin                       forwarded to the child, so a Worker can still
//                               read its task from it
//   writes inside cwd           allowed
//   writes into TEMP            allowed -- which is why the handoff and the
//                               session transcript must live there, not under
//                               LOCALAPPDATA\agent-delegation-skills, where
//                               they are denied
//   writes anywhere else        denied with EPERM, including the real
//                               repository and the user profile
//   reads                       unrestricted
//   network                     open, which the Worker needs for the provider
//                               and which means the sandbox mitigates nothing
//                               about exfiltration
//   .git                        denied even inside cwd, so a sandboxed process
//                               cannot commit
//
// The last two are why the shell stays out of this runtime entirely, and why the
// staging tree is created and committed by the unsandboxed orchestrator.
//
// `verifyEnforcing` exists because a gate that assumes the sandbox is on would
// pass just as happily when it is off. Enforcement is checked, never assumed.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const PROBE_MARKER = 'DELEGENT_SANDBOX_PROBE ';

// The sandbox must never inherit the user's global Codex configuration, for a
// reason found the hard way: a `~/.codex/config.toml` carrying
// `[windows] sandbox = "elevated"` still contains writes but *blocks network*,
// so a Worker under it fails at the provider with nothing explaining why. The
// unelevated backend contains writes and keeps network, which is what a Worker
// needs, so this module supplies its own home and does not touch the user's.
function ensureSandboxHome(dir) {
  const home = dir || path.join(
    process.env.LOCALAPPDATA || os.tmpdir(),
    'agent-delegation-skills',
    'codex-sandbox-home'
  );
  fs.mkdirSync(home, { recursive: true });
  const config = path.join(home, 'config.toml');
  const desired = '[windows]\nsandbox = "unelevated"\n';
  let current = null;
  try { current = fs.readFileSync(config, 'utf8'); } catch (err) { current = null; }
  if (current !== desired) fs.writeFileSync(config, desired, 'utf8');
  return home;
}

// `codex` on PATH is a .cmd/.ps1 shim, not an executable, so a direct spawn with
// no shell cannot find it. Resolve a real launcher instead of hoping.
function findCodexLauncher() {
  const pathExt = (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';');
  const dirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    for (const candidate of ['codex.exe', 'codex.cmd', 'codex.bat']) {
      const full = path.join(dir, candidate);
      try {
        if (fs.existsSync(full)) {
          return { ok: true, launcher: full, kind: candidate.endsWith('.exe') ? 'native' : 'cmd-shim' };
        }
      } catch (err) { /* keep scanning */ }
    }
  }
  return { ok: false, reason: 'no codex.exe or codex.cmd found on PATH' };
}

// Pure, so the argument shape is testable without codex installed. A cmd shim
// has to be driven through the comspec, and the whole inner command is wrapped
// in one more layer of quotes because `cmd /s /c` strips the outermost pair.
function buildSandboxCommand(options) {
  const launcher = options.launcher;
  const stagingPath = options.stagingPath;
  const command = options.command;
  const commandArgs = options.commandArgs || [];
  if (!launcher || !stagingPath || !command) {
    return { ok: false, reason: 'launcher, stagingPath and command are required' };
  }

  const sandboxArgs = ['sandbox', '-P', ':workspace', '-C', stagingPath, '--', command].concat(commandArgs);

  if (/\.exe$/i.test(launcher)) {
    return { ok: true, file: launcher, args: sandboxArgs, shell: false };
  }

  const comspec = process.env.ComSpec || 'cmd.exe';
  const quoted = ['"' + launcher + '"']
    .concat(sandboxArgs.map((a) => (/[\s"]/.test(a) ? '"' + a + '"' : a)))
    .join(' ');
  return { ok: true, file: comspec, args: ['/d', '/s', '/c', '"' + quoted + '"'], shell: false, raw: quoted };
}

// Runs a child under the sandbox that tries to write outside the staging tree.
// If that write succeeds, the sandbox is not enforcing and the caller must
// refuse to proceed rather than run a Worker it believes is contained.
function verifyEnforcing(options) {
  const stagingPath = options.stagingPath;
  if (!stagingPath || !fs.existsSync(stagingPath)) {
    return { ok: false, reason: 'stagingPath does not exist' };
  }

  const found = findCodexLauncher();
  if (!found.ok) return { ok: false, reason: found.reason };

  // Somewhere outside the staging tree and outside TEMP, since TEMP is writable
  // by design and would not discriminate.
  const outsideDir = options.outsideDir || path.join(os.homedir(), 'delegent-sandbox-enforcement-check');
  const probe = path.join(__dirname, 'delegent-sandbox-probe.js');
  if (!fs.existsSync(probe)) return { ok: false, reason: 'sandbox probe script is missing' };

  const built = buildSandboxCommand({
    launcher: found.launcher,
    stagingPath: stagingPath,
    command: process.execPath,
    commandArgs: [probe, outsideDir]
  });
  if (!built.ok) return { ok: false, reason: built.reason };

  const home = ensureSandboxHome(options.codexHome);
  const run = spawnSync(built.file, built.args, {
    encoding: 'utf8',
    timeout: 90000,
    windowsVerbatimArguments: true,
    cwd: stagingPath,
    env: Object.assign({}, process.env, { CODEX_HOME: home })
  });

  const stdout = String(run.stdout || '');
  const line = stdout.split(/\r?\n/).find((l) => l.indexOf(PROBE_MARKER) === 0);
  if (!line) {
    return { ok: false, reason: 'the enforcement probe produced no result', launcher: found.kind };
  }

  let verdict;
  try {
    verdict = JSON.parse(line.slice(PROBE_MARKER.length));
  } catch (err) {
    return { ok: false, reason: 'the enforcement probe result was not JSON' };
  }

  const enforcing = verdict.outside === 'denied' && verdict.inside === 'allowed';
  const networkUsable = typeof verdict.network === 'string' && verdict.network.indexOf('reachable') === 0;
  return {
    ok: true,
    enforcing: enforcing,
    networkUsable: networkUsable,
    usable: enforcing && networkUsable,
    inside: verdict.inside,
    outside: verdict.outside,
    network: verdict.network,
    launcher: found.kind,
    codexHome: home,
    outsideDir: outsideDir
  };
}

module.exports = { PROBE_MARKER, ensureSandboxHome, findCodexLauncher, buildSandboxCommand, verifyEnforcing };

if (require.main === module) {
  const command = process.argv[2];
  let result;
  if (command === 'verify') {
    result = verifyEnforcing({ stagingPath: process.argv[3] });
  } else if (command === 'which') {
    result = findCodexLauncher();
    if (result.ok) result.codexHome = ensureSandboxHome(null);
  } else {
    result = { ok: false, reason: 'unknown command; expected verify|which' };
  }
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exitCode = result.ok && (result.usable !== false) ? 0 : 1;
}
