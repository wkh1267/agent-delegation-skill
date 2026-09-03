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
// supplied the sandbox, the shell tool and session persistence. This runtime
// has none of them, so its tool surface is read-only by construction -- one
// repository read, path-contained, no shell and no writes. Mutation work needs
// a real sandbox story before it can live here.
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
  schema = JSON.parse(fs.readFileSync(options.schemaPath, 'utf8'));
  repoRoot = fs.realpathSync(options.repoRoot);
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
// creates anything: a missing file is simply reported.
function resolveContainedPath(root, requested) {
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
    return { ok: false, reason: 'file not found: ' + requested };
  }
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    return { ok: false, reason: 'path escapes the repository root' };
  }
  if (!fs.statSync(real).isFile()) {
    return { ok: false, reason: 'not a regular file: ' + requested };
  }
  return { ok: true, real: real };
}

function readFileTool(args, root) {
  const resolved = resolveContainedPath(root || repoRoot, args && args.path);
  if (!resolved.ok) return { ok: false, output: resolved.reason };

  const maxLines = args && Number.isInteger(args.max_lines) && args.max_lines > 0 ? args.max_lines : 200;
  const lines = fs.readFileSync(resolved.real, 'utf8').split(/\r?\n/).slice(0, maxLines);
  return { ok: true, output: lines.join('\n') };
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
const dispatch = { read_file: readFileTool, delegent_handoff: handoffTool };

// Nemotron needs the tool contract stated explicitly rather than inferred from
// the schema alone; that was already true of Codex's exec_command in N3.
const instructions = [
  'You are a Delegent Worker. Do the delegated task using the provided tools, then report.',
  'Use read_file to inspect files. Never guess a file\'s contents.',
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

  const input = [{ role: 'user', content: [{ type: 'input_text', text: task }] }];
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

  emit({
    type: 'turn.completed',
    steps: steps,
    tool_call_count: toolCallCount,
    handoff_attempts: handoffState.attempts,
    handoff_accepted: handoffState.accepted,
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

module.exports = { resolveContainedPath, readFileTool, buildTools };
