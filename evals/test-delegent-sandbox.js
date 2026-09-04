'use strict';

// D4d — deterministic tests for the sandbox layer.
//
// The command-shape and config parts run anywhere, with no codex installed. The
// enforcement arm needs codex and network, so it skips explicitly rather than
// passing quietly: a sandbox test that silently reports success when it could
// not check anything is worse than no test.

const fs = require('fs');
const os = require('os');
const path = require('path');

const toolsDir = path.resolve(__dirname, '..', 'skills', 'delegating-work', 'tools');
const sandbox = require(path.join(toolsDir, 'delegent-sandbox.js'));
const { ensureSandboxHome, findCodexLauncher, buildSandboxCommand, verifyEnforcing } = sandbox;

let failures = 0;
let checks = 0;

function check(condition, message) {
  checks++;
  if (!condition) {
    failures++;
    process.stdout.write('FAIL  ' + message + '\n');
  }
}

// ---- buildSandboxCommand ----

const staging = path.join(os.tmpdir(), 'delegent staging with space');

const viaExe = buildSandboxCommand({
  launcher: 'C:\\tools\\codex.exe',
  stagingPath: staging,
  command: 'C:\\node\\node.exe',
  commandArgs: ['worker.js', '--flag', 'value']
});
check(viaExe.ok, 'a native launcher builds a command');
check(viaExe.file === 'C:\\tools\\codex.exe', 'a native launcher is spawned directly');
check(viaExe.args.indexOf('sandbox') === 0, 'the sandbox subcommand comes first');
check(viaExe.args.indexOf('-P') !== -1 && viaExe.args[viaExe.args.indexOf('-P') + 1] === ':workspace',
  'the workspace permission profile is requested');
check(viaExe.args[viaExe.args.indexOf('-C') + 1] === staging, 'the staging tree is the sandbox cwd');
// Everything after `--` is the child command, so a child flag can never be read
// as a flag for codex itself.
const separator = viaExe.args.indexOf('--');
check(separator !== -1, 'the child command is separated by --');
check(viaExe.args[separator + 1] === 'C:\\node\\node.exe', 'the child command follows the separator');
check(viaExe.args.slice(separator).indexOf('--flag') > 0, 'child flags stay after the separator');

const viaCmd = buildSandboxCommand({
  launcher: 'C:\\npm\\codex.cmd',
  stagingPath: staging,
  command: 'C:\\Program Files\\nodejs\\node.exe',
  commandArgs: ['worker.js']
});
check(viaCmd.ok, 'a cmd shim builds a command');
check(/cmd\.exe$/i.test(viaCmd.file) || /^cmd/i.test(path.basename(viaCmd.file)),
  'a cmd shim is driven through the comspec');
check(viaCmd.args[0] === '/d' && viaCmd.args[2] === '/c', 'the comspec gets /d /s /c');
// `cmd /s /c` strips the outermost quote pair, so the whole inner command needs
// one extra layer or a path with a space breaks it.
check(viaCmd.args[3].startsWith('"') && viaCmd.args[3].endsWith('"'),
  'the whole inner command is wrapped in an extra quote layer');
check(viaCmd.raw.indexOf('"C:\\npm\\codex.cmd"') === 0, 'the shim path is quoted');
check(viaCmd.raw.indexOf('"C:\\Program Files\\nodejs\\node.exe"') !== -1,
  'a child path containing a space is quoted');
check(viaCmd.raw.indexOf('"' + staging + '"') !== -1, 'a staging path containing a space is quoted');

check(!buildSandboxCommand({ stagingPath: staging, command: 'node' }).ok, 'a missing launcher is refused');
check(!buildSandboxCommand({ launcher: 'codex.exe', command: 'node' }).ok, 'a missing staging path is refused');
check(!buildSandboxCommand({ launcher: 'codex.exe', stagingPath: staging }).ok, 'a missing command is refused');

// ---- ensureSandboxHome ----

const homeDir = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-sbxhome-')), 'home');
const home = ensureSandboxHome(homeDir);
check(home === homeDir, 'an explicit home directory is honoured');
check(fs.existsSync(path.join(home, 'config.toml')), 'a config is written');
const config = fs.readFileSync(path.join(home, 'config.toml'), 'utf8');
// The unelevated backend is the one that contains writes *and* keeps network.
// The elevated backend blocks network, which strands a Worker at its provider.
check(/\[windows\]/.test(config), 'the config declares the windows table');
check(/sandbox\s*=\s*"unelevated"/.test(config), 'the config selects the unelevated backend');
check(!/elevated"/.test(config.replace('unelevated"', '')), 'the config does not select the elevated backend');

const again = ensureSandboxHome(homeDir);
check(again === homeDir, 'ensuring an existing home is idempotent');
check(fs.readFileSync(path.join(home, 'config.toml'), 'utf8') === config, 'the config is unchanged on a second ensure');

// A drifted config is corrected rather than trusted.
fs.writeFileSync(path.join(home, 'config.toml'), '[windows]\nsandbox = "elevated"\n', 'utf8');
ensureSandboxHome(homeDir);
check(/sandbox\s*=\s*"unelevated"/.test(fs.readFileSync(path.join(home, 'config.toml'), 'utf8')),
  'a drifted config is rewritten to the unelevated backend');

// It must never be the user's own Codex home.
const defaultHome = ensureSandboxHome(null);
check(path.basename(defaultHome) === 'codex-sandbox-home', 'the default home is a dedicated directory');
check(defaultHome.indexOf(path.join(os.homedir(), '.codex')) !== 0,
  'the default home is never the user global Codex home');

try { fs.rmSync(path.dirname(homeDir), { recursive: true, force: true }); } catch (err) { /* best effort */ }

// ---- live enforcement, only when it can actually be checked ----

let liveChecked = false;
const found = findCodexLauncher();
if (!found.ok) {
  process.stdout.write('SKIP  live enforcement arm (codex not on PATH)\n');
} else {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delegent-sbxlive-'));
  try {
    const verdict = verifyEnforcing({ stagingPath: stagingDir });
    if (!verdict.ok) {
      process.stdout.write('SKIP  live enforcement arm (' + verdict.reason + ')\n');
    } else {
      liveChecked = true;
      check(verdict.inside === 'allowed', 'a write inside the staging tree is allowed');
      check(verdict.outside === 'denied', 'a write outside the staging tree is denied');
      check(verdict.enforcing === true, 'the sandbox reports itself enforcing');
      // Both halves are required: a sandbox denying everything would look
      // "enforcing" while being useless to a Worker that must reach a provider.
      check(typeof verdict.network === 'string', 'the probe reports a network verdict');
      check(verdict.usable === (verdict.enforcing && verdict.networkUsable),
        'usable means enforcing and network-capable together');
    }
  } finally {
    try { fs.rmSync(stagingDir, { recursive: true, force: true }); } catch (err) { /* best effort */ }
  }
}

if (failures === 0) {
  process.stdout.write('PASS Delegent sandbox layer ' + checks + ' assertions' +
    (liveChecked ? ' (incl. live enforcement)' : ' (live arm skipped)') + '\n');
  process.exitCode = 0;
} else {
  process.stdout.write('FAIL Delegent sandbox layer: ' + failures + ' of ' + checks + ' assertions failed\n');
  process.exitCode = 1;
}
