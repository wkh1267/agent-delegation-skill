'use strict';

// The Delegent machine boundary, in one place.
//
// Two hosts share this module: the MCP boundary server and the direct NIM
// Worker runtime. Keeping one implementation is deliberate -- a boundary that
// validates slightly differently depending on who calls it is not a boundary.
//
// Nothing here repairs, coerces or re-parses a submission. A payload either
// satisfies the shipped schema exactly or it is rejected with the specific
// violations, so the Worker can correct itself and the Lead never sees a
// half-valid handoff.

// Exact validation over the JSON Schema subset the Delegent schemas use: an
// object with a closed property set, string with optional enum, and array of
// string. Anything outside that subset is reported rather than skipped, so a
// schema change cannot silently disable checking.
function validate(value, node, at) {
  const where = at || '$';

  if (!node || typeof node !== 'object') return [where + ' has no schema'];

  if (node.type === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      return [where + ' is not an object'];
    }
    const violations = [];
    const present = Object.keys(value);
    for (const required of node.required || []) {
      if (!present.includes(required)) violations.push(where + '.' + required + ' is missing');
    }
    const declared = Object.keys(node.properties || {});
    if (node.additionalProperties === false) {
      for (const name of present) {
        if (!declared.includes(name)) violations.push(where + '.' + name + ' is not allowed');
      }
    }
    for (const name of declared) {
      if (!present.includes(name)) continue;
      violations.push(...validate(value[name], node.properties[name], where + '.' + name));
    }
    return violations;
  }

  if (node.type === 'array') {
    if (!Array.isArray(value)) return [where + ' is not an array'];
    const violations = [];
    value.forEach((element, index) => {
      violations.push(...validate(element, node.items, where + '[' + index + ']'));
    });
    return violations;
  }

  if (node.type === 'string') {
    if (typeof value !== 'string') return [where + ' is not a string'];
    if (Array.isArray(node.enum) && node.enum.length > 0 && !node.enum.includes(value)) {
      return [where + ' is outside its allowed values'];
    }
    return [];
  }

  return [where + ' has an unsupported schema type'];
}

// Context Firewall: applied to every string that crosses the boundary, before
// it can reach the Lead's context.
function filterSensitive(text, credential) {
  if (typeof text !== 'string' || text.length === 0) return '';
  let safe = text;
  if (credential) safe = safe.split(credential).join('<redacted>');
  safe = safe.replace(/nvapi-[A-Za-z0-9_-]+/gi, '<redacted>');
  safe = safe.replace(/\bBearer\s+\S+/gi, 'Bearer <redacted>');
  safe = safe.replace(/\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}/gi, '<redacted>');
  safe = safe.replace(/\b(api[_-]?key|secret|password|passwd|token)(\s*[:=]\s*)\S+/gi, '$1$2<redacted>');
  safe = safe.replace(/\b[A-Za-z0-9_-]{48,}\b/g, '<token>');
  return safe;
}

// Filters every string the schema declares, at any depth the subset allows,
// and reports how many were processed so a caller can prove the firewall ran
// rather than assuming it.
function filterHandoff(handoff, schema, credential) {
  const filtered = {};
  let count = 0;
  for (const name of Object.keys(schema.properties || {})) {
    const node = schema.properties[name];
    const value = handoff[name];
    if (node.type === 'string' && typeof value === 'string') {
      filtered[name] = filterSensitive(value, credential);
      count++;
    } else if (node.type === 'array' && Array.isArray(value)) {
      filtered[name] = value.map((element) => {
        if (typeof element === 'string') {
          count++;
          return filterSensitive(element, credential);
        }
        return element;
      });
    } else if (value !== undefined) {
      filtered[name] = value;
    }
  }
  return { handoff: filtered, filteredStringCount: count };
}

module.exports = { validate, filterSensitive, filterHandoff };
