#!/usr/bin/env node
'use strict';

// Delegent handoff boundary, exposed to Codex as an MCP stdio tool.
//
// This exists because hosted NVIDIA NIM does not enforce Responses-native
// structured output: `text.format` json_schema conformance was 8/10 at the
// provider, and driving it through `codex exec --output-schema` was usable in
// only 1 of 7 attempts (the rest hung, because Codex re-requests when the final
// message fails the schema and the provider never converges). Function calling,
// by contrast, is reliable on this provider. So the terminal handoff travels as
// tool-call arguments rather than as a schema-constrained final message.
//
// The server is the machine boundary, not a convenience: it validates every
// submission against the shipped schema and rejects a non-conforming one with
// the specific violations, so the Worker can correct itself. Nothing is
// repaired or coerced here, and a rejected submission is never written out.
//
// Usage: node delegent-handoff-mcp.js <schema.json> <accepted-out.json>
// Deliberately dependency-free so the Worker runtime needs no install step.

const fs = require('fs');
const path = require('path');
// One boundary implementation, shared with the direct NIM Worker runtime.
const { validate } = require('./delegent-schema');

const schemaPath = process.argv[2];
const outPath = process.argv[3];

if (!schemaPath || !outPath) {
  process.stderr.write('delegent-handoff-mcp: schema path and output path are required\n');
  process.exit(2);
}

const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const logPath = outPath + '.log.jsonl';
// Method-name-only trace. Distinguishes "the host never connected" from "the
// host connected but the model called the tool by another name", which are
// otherwise indistinguishable from the outside.
const rpcLogPath = outPath + '.rpc.jsonl';
const TOOL_NAME = 'delegent_handoff';

// The log records only counts and outcomes, never submitted content, so it is
// safe to read while diagnosing a run.
function appendLog(entry) {
  try {
    fs.appendFileSync(logPath, JSON.stringify(entry) + '\n', 'utf8');
  } catch (err) {
    // A log failure must never take the boundary down.
  }
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function respond(id, result) {
  send({ jsonrpc: '2.0', id: id, result: result });
}

function respondError(id, code, message) {
  send({ jsonrpc: '2.0', id: id, error: { code: code, message: message } });
}

function handleToolCall(id, params) {
  const name = params && params.name;
  if (name !== TOOL_NAME) {
    respondError(id, -32602, 'Unknown tool: ' + String(name));
    return;
  }

  const args = (params && params.arguments) || {};
  const violations = validate(args, schema);

  if (violations.length > 0) {
    appendLog({ accepted: false, violation_count: violations.length, at: new Date().toISOString() });
    // isError lets the Worker see precisely what to fix and resubmit. The
    // violations are schema paths, so no submitted content is echoed back.
    respond(id, {
      isError: true,
      content: [{
        type: 'text',
        text: 'HANDOFF_REJECTED: ' + violations.length + ' schema violation(s): ' +
          violations.join('; ') + '. Resubmit with every required field and no extra fields.'
      }]
    });
    return;
  }

  // Write atomically so a reader never observes a partial handoff.
  const tempPath = outPath + '.tmp';
  fs.writeFileSync(tempPath, JSON.stringify(args, null, 2), 'utf8');
  fs.renameSync(tempPath, outPath);
  appendLog({ accepted: true, violation_count: 0, at: new Date().toISOString() });

  respond(id, {
    content: [{ type: 'text', text: 'HANDOFF_ACCEPTED' }]
  });
}

function handle(message) {
  const id = message.id;
  const method = message.method;

  // Names only, never params, so the trace stays safe to read.
  try {
    fs.appendFileSync(rpcLogPath, JSON.stringify({
      method: String(method),
      tool: (message.params && message.params.name) ? String(message.params.name) : null,
      at: new Date().toISOString()
    }) + '\n', 'utf8');
  } catch (err) {
    // A trace failure must never take the boundary down.
  }

  // Notifications carry no id and expect no response.
  if (id === undefined || id === null) return;

  if (method === 'initialize') {
    respond(id, {
      protocolVersion: (message.params && message.params.protocolVersion) || '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'delegent-handoff', version: '0.1.0' }
    });
    return;
  }

  if (method === 'tools/list') {
    respond(id, {
      tools: [{
        name: TOOL_NAME,
        description:
          'Submit the final Delegent handoff for the delegated task. Call this exactly once, ' +
          'as the last action of the turn, after the work is done. Every field is required; ' +
          'use an empty array for a list that has no entries.',
        inputSchema: schema
      }]
    });
    return;
  }

  if (method === 'tools/call') {
    handleToolCall(id, message.params);
    return;
  }

  if (method === 'ping') {
    respond(id, {});
    return;
  }

  respondError(id, -32601, 'Method not found: ' + String(method));
}

// MCP stdio transport is newline-delimited JSON, so buffer until each newline.
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let newline = buffer.indexOf('\n');
  while (newline !== -1) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line.length > 0) {
      let message = null;
      try {
        message = JSON.parse(line);
      } catch (err) {
        message = null;
      }
      if (message) {
        try {
          handle(message);
        } catch (err) {
          if (message.id !== undefined && message.id !== null) {
            respondError(message.id, -32603, 'Internal error');
          }
        }
      }
    }
    newline = buffer.indexOf('\n');
  }
});
process.stdin.on('end', () => process.exit(0));
