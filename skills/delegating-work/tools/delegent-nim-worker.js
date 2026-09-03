#!/usr/bin/env node
'use strict';

// Delegent Worker runtime, driving NVIDIA NIM directly.
//
// Why this exists rather than the Codex harness: Codex+NIM passed every layer
// except the one Delegent cannot compromise. Responses-native structured output
// is only advisory on this provider (8/10 conformance, 1/7 usable through
// `codex exec --output-schema`), and Codex never exposes an MCP tool to the
// model on this provider, so neither terminal-handoff boundary was reachable.
// Function calling, by contrast, is reliable here. Owning the loop puts the
// handoff on that path.
//
// What is deliberately given up, and must not be quietly assumed back: Codex
// supplied the sandbox, the shell tool and session persistence. This runtime has
// none of them, so its tool surface is read-only by construction: list, search
// and read, every one of them path-contained, with no shell and no writes.
// Mutation work needs a real sandbox story before it can live here.
//
// Emits newline-delimited JSON lifecycle events on stdout so a probe can
// validate a run the same way it validates a Codex run. The credential is never
// written to stdout, stderr or any artifact.
//
// Usage:
//   node delegent-nim-worker.js --schema <f> --out <f> --repo <dir> [options]
// Task text is read from stdin. Credential comes from NIM_API_KEY.

const fs = require('fs');
const path = require('path');
const { validate, filterHandoff } = require('./delegent-schema');

function parseArgs(argv) {
  const options = {
    model: 'nvidia/nemotron-3-super-120b-a12b',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    maxSteps: 8,
    maxHandoffAttempts: 3,
    requestRetries: 3
  };
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === '--schema') options.schemaPath = value;
    else if (key === '--out') options.outPath = value;
    else if (key === '--repo') options.repoRoot = value;
    else if (key === '--model') options.model = value;
    else if (key === '--base-url') options.baseUrl = value;
    else if (key === '--max-steps') options.maxSteps = parseInt(value, 10);
    else if (key === '--max-handoff-attempts') options.maxHandoffAttempts = parseInt(value, 10);
    else if (key === '--session') options.session = value;
    else if (key === '--session-dir') options.sessionDir = value;
    else options.unknown = key;
  }
  return options;
}

const options = parseArgs(process.argv);
const credential = process.env.NIM_API_KEY || '';
let schema = null;
let repoRoot = null;

function emit(event) {
  process.stdout.write(JSON.stringify(event) + '\n');
}

// Everything leaving this process is scrubbed of the credential, including
// error text that may embed a request URL or header.
function safe(text) {
  let value = typeof text === 'string' ? text : String(text);
  if (credential) value = value.split(credential).join('<redacted>');
  value = value.replace(/nvapi-[A-Za-z0-9_-]+/gi, '<redacted>');
  value = value.replace(/\bBearer\s+\S+/gi, 'Bearer <redacted>');
  return value;
}

class WorkerError extends Error {}

// Never call process.exit() in this runtime. Node still owns an open stdin
// handle here, and tearing the loop down underneath libuv aborts the process on
// Windows with `Assertion failed: !(handle->flags & UV_HANDLE_CLOSING)` in
// async.c -- which surfaces as a bogus 0xC0000409 exit code that hides whatever
// actually happened. Report through exitCode and let the loop unwind instead.
function fail(message) {
  emit({ type: 'error', message: safe(message) });
  emit({ type: 'turn.failed' });
  throw new WorkerError(message);
}

function init() {
  if (options.unknown) fail('unknown option: ' + options.unknown);
  if (!options.schemaPath || !options.outPath || !options.repoRoot) {
    fail('--schema, --out and --repo are required');
  }
  if (!credential) fail('NIM_API_KEY is required');
  if (options.session && !options.sessionDir) fail('--session requires --session-dir');
  schema = JSON.parse(fs.readFileSync(options.schemaPath, 'utf8'));
  repoRoot = fs.realpathSync(options.repoRoot);
}

// ---- Worker continuity ----
//
// Continuity is opt-in: with no --session the runtime is stateless, exactly as
// the D1 and D1b gates validated it. The affinity string is the Delegent
// identity `delegent:<project>:<scope>:<role>`, and reuse is a placement
// decision the Lead makes, not something this runtime infers:
//
//   same subsystem, follow-up, implement->test->debug  -> reuse
//   independent review, security, spec compliance      -> fresh
//
// State is kept locally rather than through provider-side response ids, because
// owning the loop was the whole point of the pivot and a hosted store is one
// more provider behaviour we would have to trust.
//
// The stored transcript contains whatever the Worker read, so it belongs outside
// the repository alongside the other runtime artifacts, and it is bounded: an
// unbounded transcript would eventually exceed the model's context anyway.
const SESSION_MAX_ITEMS = 400;

function sessionFileFor(affinity) {
  // The affinity is a colon-delimited identity, not a path. Flatten it to one
  // safe filename so it cannot address anything outside the session directory.
  const safe = affinity.replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 120);
  const digest = require('crypto').createHash('sha256').update(affinity).digest('hex').slice(0, 12);
  return path.join(options.sessionDir, safe + '-' + digest + '.json');
}

function loadSession(affinity) {
  const file = sessionFileFor(affinity);
  if (!fs.existsSync(file)) return { input: [], turns: 0, file: file, loaded: false };
  try {
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!Array.isArray(saved.input)) return { input: [], turns: 0, file: file, loaded: false };
    return {
      input: saved.input,
      turns: Number.isInteger(saved.turns) ? saved.turns : 0,
      file: file,
      loaded: true
    };
  } catch (err) {
    // A corrupt session must not take the Worker down; it starts fresh and says so.
    emit({ type: 'session.unreadable' });
    return { input: [], turns: 0, file: file, loaded: false };
  }
}

function saveSession(affinity, session, input) {
  const file = sessionFileFor(affinity);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // Keep the tail: the most recent exchanges are what a follow-up depends on.
  const trimmed = input.length > SESSION_MAX_ITEMS ? input.slice(-SESSION_MAX_ITEMS) : input;
  const payload = {
    affinity: affinity,
    turns: session.turns + 1,
    item_count: trimmed.length,
    trimmed: trimmed.length < input.length,
    updated_at: new Date().toISOString(),
    input: trimmed
  };
  const temp = file + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(payload, null, 2), 'utf8');
  fs.renameSync(temp, file);
  emit({
    type: 'session.saved',
    turns: payload.turns,
    item_count: payload.item_count,
    trimmed: payload.trimmed
  });
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

// ---- Tool surface: read-only by construction ----

// Containment is the security-critical part of the tool surface, so it is a
// separate exported function with its own tests. It resolves the *real* path
// before comparing, so a symlink cannot walk out of the repository, and it never
// creates anything: a missing entry is simply reported.
//
// Every read-only tool must route through this. None of them may resolve a
// model-supplied path themselves.
function resolveContainedEntry(root, requested) {
  if (typeof requested !== 'string' || requested.length === 0) {
    return { ok: false, reason: 'path is required' };
  }
  if (path.isAbsolute(requested)) {
    return { ok: false, reason: 'path must be relative to the repository root' };
  }

  const realRoot = fs.realpathSync(root);
  let real;
  try {
    real = fs.realpathSync(path.resolve(realRoot, requested));
  } catch (err) {
    return { ok: false, reason: 'path not found: ' + requested };
  }
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    return { ok: false, reason: 'path escapes the repository root' };
  }

  const stats = fs.statSync(real);
  return { ok: true, real: real, isFile: stats.isFile(), isDirectory: stats.isDirectory() };
}

// File-only wrapper, kept because most callers want exactly that and because
// refusing a directory here is a tested property.
function resolveContainedPath(root, requested) {
  const entry = resolveContainedEntry(root, requested);
  if (!entry.ok) return entry;
  if (!entry.isFile) return { ok: false, reason: 'not a regular file: ' + requested };
  return { ok: true, real: entry.real };
}

function readFileTool(args, root) {
  const resolved = resolveContainedPath(root || repoRoot, args && args.path);
  if (!resolved.ok) return { ok: false, output: resolved.reason };

  const maxLines = args && Number.isInteger(args.max_lines) && args.max_lines > 0 ? args.max_lines : 200;
  const lines = fs.readFileSync(resolved.real, 'utf8').split(/\r?\n/).slice(0, maxLines);
  return { ok: true, output: lines.join('\n') };
}

// Directories that would dominate any walk without adding anything a Worker
// needs to reason about.
const SKIPPED_DIRS = ['.git', 'node_modules'];
// Bounds so a model-chosen search cannot turn into an unbounded filesystem walk.
const SEARCH_MAX_FILES = 2000;
const SEARCH_MAX_FILE_BYTES = 1024 * 1024;

function listFilesTool(args, root) {
  const requested = args && args.path ? args.path : '.';
  const entry = resolveContainedEntry(root || repoRoot, requested);
  if (!entry.ok) return { ok: false, output: entry.reason };
  if (!entry.isDirectory) return { ok: false, output: 'not a directory: ' + requested };

  const maxEntries = args && Number.isInteger(args.max_entries) && args.max_entries > 0
    ? Math.min(args.max_entries, 500) : 200;

  const names = fs.readdirSync(entry.real, { withFileTypes: true })
    .filter((d) => !(d.isDirectory() && SKIPPED_DIRS.indexOf(d.name) !== -1))
    .slice(0, maxEntries)
    .map((d) => (d.isDirectory() ? d.name + '/' : d.name));

  if (names.length === 0) return { ok: true, output: '(empty)' };
  return { ok: true, output: names.join('\n') };
}

// Literal substring search, deliberately not regex: a model-supplied pattern
// would otherwise be an easy way to hang the Worker on catastrophic backtracking.
function searchTool(args, root) {
  const pattern = args && args.pattern;
  if (typeof pattern !== 'string' || pattern.length === 0) {
    return { ok: false, output: 'pattern is required' };
  }

  const requested = args && args.path ? args.path : '.';
  const entry = resolveContainedEntry(root || repoRoot, requested);
  if (!entry.ok) return { ok: false, output: entry.reason };

  const maxResults = args && Number.isInteger(args.max_results) && args.max_results > 0
    ? Math.min(args.max_results, 200) : 50;
  const realRoot = fs.realpathSync(root || repoRoot);

  const results = [];
  let filesScanned = 0;
  let truncated = false;

  const scanFile = (full) => {
    let stats;
    try {
      stats = fs.statSync(full);
    } catch (err) {
      return;
    }
    if (stats.size > SEARCH_MAX_FILE_BYTES) return;

    filesScanned++;
    let content;
    try {
      content = fs.readFileSync(full, 'utf8');
    } catch (err) {
      return;
    }
    // A NUL byte means binary; skip it rather than reporting noise.
    if (content.indexOf(String.fromCharCode(0)) !== -1) return;
    if (content.indexOf(pattern) === -1) return;

    const relative = path.relative(realRoot, full).split(path.sep).join('/');
    const lines = content.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(pattern) === -1) continue;
      if (results.length >= maxResults) {
        truncated = true;
        return;
      }
      const text = lines[i].length > 200 ? lines[i].slice(0, 200) + '...' : lines[i];
      results.push(relative + ':' + (i + 1) + ': ' + text.trim());
    }
  };

  // Symlinks are skipped outright rather than resolved, so the walk cannot leave
  // the repository even through a directory link.
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      return;
    }
    for (const item of entries) {
      if (results.length >= maxResults || filesScanned >= SEARCH_MAX_FILES) {
        truncated = true;
        return;
      }
      if (item.isSymbolicLink()) continue;
      const full = path.join(dir, item.name);
      if (item.isDirectory()) {
        if (SKIPPED_DIRS.indexOf(item.name) !== -1) continue;
        walk(full);
        continue;
      }
      if (item.isFile()) scanFile(full);
    }
  };

  if (entry.isDirectory) walk(entry.real);
  else scanFile(entry.real);

  if (results.length === 0) return { ok: true, output: 'no matches for: ' + pattern };
  const header = results.length + ' match(es)' + (truncated ? ' (truncated)' : '') + ':\n';
  return { ok: true, output: header + results.join('\n') };
}

const handoffState = { attempts: 0, accepted: false, violations: [] };

// The machine boundary. Validates against the shipped schema, and a rejected
// submission is never persisted -- the violations go back so the Worker can
// correct itself.
function handoffTool(args) {
  handoffState.attempts++;
  const violations = validate(args || {}, schema);
  handoffState.violations = violations;

  if (violations.length > 0) {
    emit({
      type: 'item.completed',
      item: { type: 'handoff', accepted: false, violation_count: violations.length, violations: violations }
    });
    return {
      ok: false,
      output: 'HANDOFF_REJECTED: ' + violations.length + ' schema violation(s): ' +
        violations.join('; ') + '. Resubmit with every required field and no extra fields.'
    };
  }

  const { handoff, filteredStringCount } = filterHandoff(args, schema, credential);
  const tempPath = options.outPath + '.tmp';
  fs.writeFileSync(tempPath, JSON.stringify(handoff, null, 2), 'utf8');
  fs.renameSync(tempPath, options.outPath);

  handoffState.accepted = true;
  emit({
    type: 'item.completed',
    item: {
      type: 'handoff',
      accepted: true,
      violation_count: 0,
      filtered_string_count: filteredStringCount
    }
  });
  return { ok: true, output: 'HANDOFF_ACCEPTED' };
}

// Built after init, because the handoff tool's parameters are the shipped
// schema and it is not loaded until then.
function buildTools() {
  return [
  {
    type: 'function',
    name: 'list_files',
    description: 'List the entries of a directory in the repository. Directory names end with a slash. Read-only.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['path'],
      properties: {
        path: { type: 'string', description: 'Repository-relative directory, for example docs/decisions. Use "." for the root.' },
        max_entries: { type: 'integer', description: 'Maximum number of entries to return.' }
      }
    }
  },
  {
    type: 'function',
    name: 'search',
    description:
      'Search the repository for a literal substring and return matching lines as path:line: text. ' +
      'Not a regular expression. Read-only.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['pattern'],
      properties: {
        pattern: { type: 'string', description: 'Exact text to find. Treated literally, not as a pattern.' },
        path: { type: 'string', description: 'Repository-relative directory or file to search under. Defaults to the whole repository.' },
        max_results: { type: 'integer', description: 'Maximum number of matching lines to return.' }
      }
    }
  },
  {
    type: 'function',
    name: 'read_file',
    description: 'Read a text file from the repository. Read-only; paths are relative to the repository root.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['path'],
      properties: {
        path: { type: 'string', description: 'Repository-relative path, for example README.md' },
        max_lines: { type: 'integer', description: 'Maximum number of leading lines to return.' }
      }
    }
  },
  {
    type: 'function',
    name: 'delegent_handoff',
    description:
      'Submit the final Delegent handoff for the delegated task. Call this exactly once, as the ' +
      'last action, after the work is done. Every field is required; use an empty array for a ' +
      'list that has no entries.',
    parameters: schema
  }
  ];
}

let tools = null;
const dispatch = {
  list_files: listFilesTool,
  search: searchTool,
  read_file: readFileTool,
  delegent_handoff: handoffTool
};

// Nemotron needs the tool contract stated explicitly rather than inferred from
// the schema alone; that was already true of Codex's exec_command in N3.
const instructions = [
  'You are a Delegent Worker. Do the delegated task using the provided tools, then report.',
  'Use list_files to see what exists, search to locate text, and read_file to inspect a file.',
  'Never guess a path or a file\'s contents. Look, then report what you actually saw.',
  'Finish by calling delegent_handoff exactly once. That call is the only way to report.',
  'Do not answer in prose instead of calling delegent_handoff.',
  'Every delegent_handoff field is required. Use an empty array for a list with no entries.',
  'If a handoff submission is rejected, read the listed violations and resubmit corrected arguments.'
].join(' ');

async function postResponses(input) {
  const body = {
    model: options.model,
    instructions: instructions,
    input: input,
    tools: tools,
    tool_choice: 'auto',
    max_output_tokens: 2000
  };

  // The hosted endpoint intermittently 404s a valid model id or drops the
  // response stream, so a bounded retry is part of normal operation here.
  let lastError = 'unknown';
  for (let attempt = 1; attempt <= options.requestRetries; attempt++) {
    let response;
    try {
      response = await fetch(options.baseUrl.replace(/\/$/, '') + '/responses', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + credential, 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
    } catch (err) {
      lastError = 'request failed: ' + safe(err && err.message ? err.message : err);
      emit({ type: 'provider.retry', attempt: attempt, reason: lastError });
      continue;
    }
    if (!response.ok) {
      lastError = 'http ' + response.status;
      emit({ type: 'provider.retry', attempt: attempt, reason: lastError });
      continue;
    }
    try {
      return await response.json();
    } catch (err) {
      lastError = 'undecodable response body';
      emit({ type: 'provider.retry', attempt: attempt, reason: lastError });
    }
  }
  return { __error: lastError };
}

async function main() {
  init();
  tools = buildTools();

  const task = (await readStdin()).trim();
  if (!task) fail('task text on stdin is required');

  const threadId = 'delegent-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
  emit({ type: 'thread.started', thread_id: threadId });

  // A reused Worker starts from the prior transcript, so a follow-up can be
  // answered from what it already learned instead of re-reading the repository.
  let session = { input: [], turns: 0, loaded: false };
  if (options.session) {
    session = loadSession(options.session);
    emit({
      type: 'session.loaded',
      affinity: options.session,
      reused: session.loaded,
      prior_turns: session.turns,
      prior_item_count: session.input.length
    });
  }

  const input = session.input.concat([{ role: 'user', content: [{ type: 'input_text', text: task }] }]);
  let toolCallCount = 0;
  let steps = 0;
  const usage = { input_tokens: 0, output_tokens: 0 };

  while (steps < options.maxSteps && !handoffState.accepted) {
    steps++;
    emit({ type: 'turn.started', step: steps });

    const result = await postResponses(input);
    if (result.__error) fail('provider request failed: ' + result.__error);

    if (result.usage) {
      usage.input_tokens += result.usage.input_tokens || 0;
      usage.output_tokens += result.usage.output_tokens || 0;
    }

    const calls = [];
    for (const item of result.output || []) {
      if (item.type === 'function_call') calls.push(item);
    }

    if (calls.length === 0) {
      // No tool call and no accepted handoff means the model tried to answer in
      // prose. That is exactly the prompt-only boundary this runtime rejects, so
      // it is pushed back rather than accepted.
      emit({ type: 'item.completed', item: { type: 'prose_answer_rejected' } });
      input.push({
        role: 'user',
        content: [{
          type: 'input_text',
          text: 'You did not call a tool. Do not answer in prose. Call delegent_handoff with the required arguments now.'
        }]
      });
      continue;
    }

    for (const call of calls) {
      const handler = dispatch[call.name];
      let outcome;
      if (!handler) {
        outcome = { ok: false, output: 'unsupported tool: ' + String(call.name) };
      } else {
        let args = {};
        try {
          args = call.arguments ? JSON.parse(call.arguments) : {};
        } catch (err) {
          outcome = { ok: false, output: 'arguments were not valid JSON' };
        }
        if (!outcome) {
          if (call.name === 'delegent_handoff' && handoffState.attempts >= options.maxHandoffAttempts) {
            outcome = { ok: false, output: 'handoff attempt budget exhausted' };
          } else {
            try {
              outcome = handler(args);
            } catch (err) {
              outcome = { ok: false, output: 'tool failed: ' + safe(err && err.message ? err.message : err) };
            }
          }
        }
      }

      toolCallCount++;
      if (call.name !== 'delegent_handoff') {
        emit({ type: 'item.completed', item: { type: 'tool_call', name: String(call.name), ok: outcome.ok } });
      }

      input.push({ type: 'function_call', call_id: call.call_id, name: call.name, arguments: call.arguments || '{}' });
      input.push({ type: 'function_call_output', call_id: call.call_id, output: outcome.output });
    }

    if (handoffState.attempts >= options.maxHandoffAttempts && !handoffState.accepted) break;
  }

  // Persist even when the handoff failed: the exploration the Worker did is
  // still worth carrying into the retry rather than making it start over.
  if (options.session) {
    try {
      saveSession(options.session, session, input);
    } catch (err) {
      emit({ type: 'session.save_failed', message: safe(err && err.message ? err.message : err) });
    }
  }

  emit({
    type: 'turn.completed',
    steps: steps,
    tool_call_count: toolCallCount,
    handoff_attempts: handoffState.attempts,
    handoff_accepted: handoffState.accepted,
    session_reused: Boolean(options.session) && session.loaded,
    usage: usage
  });

  process.exitCode = handoffState.accepted ? 0 : 1;
}

// Only run the loop when invoked directly, so the security-critical pieces can
// be required and tested without a provider or a credential.
if (require.main === module) {
  main().catch((err) => {
    // fail() has already emitted its events; anything else is unexpected.
    if (!(err instanceof WorkerError)) {
      emit({ type: 'error', message: safe('runtime error: ' + (err && err.stack ? err.stack : err)) });
      emit({ type: 'turn.failed' });
    }
    process.exitCode = 1;
  });
}

module.exports = {
  resolveContainedEntry,
  resolveContainedPath,
  readFileTool,
  listFilesTool,
  searchTool,
  buildTools
};
