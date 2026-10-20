import * as core from './qti-core.mjs';

export class QtiScoreError extends Error {
  constructor({ code, message, location = null }) {
    super(message);
    this.name = 'QtiScoreError';
    this.code = code;
    this.location = location;
  }
}

function error(code, message) {
  return new QtiScoreError({ code, message });
}

function unwrap(text) {
  const value = JSON.parse(text);
  if (!value.ok) throw new QtiScoreError(value.error);
  return value;
}

function xmlText(xml) {
  if (typeof xml !== 'string') throw error('invalid_item', 'XML must be a string');
  return xml;
}

// Reject values that JSON.stringify would silently turn into null or omit.
// All QTI response interpretation and scoring remains in the MoonBit core.
function encodeResponse(response) {
  if (!response || typeof response !== 'object' || Array.isArray(response)) {
    throw error('invalid_response', 'Expected a response object');
  }
  const prototype = Object.getPrototypeOf(response);
  if (prototype !== Object.prototype && prototype !== null) {
    throw error('invalid_response', 'Expected a plain response object');
  }
  for (const key of Reflect.ownKeys(response)) {
    if (key !== 'RESPONSE') throw error('invalid_response', 'Unknown response identifier');
  }
  if (!Object.hasOwn(response, 'RESPONSE')) return '{}';
  const descriptor = Object.getOwnPropertyDescriptor(response, 'RESPONSE');
  if (!Object.hasOwn(descriptor, 'value')) throw error('invalid_response', 'Response must contain data, not an accessor');
  let value = descriptor.value;
  if (Array.isArray(value)) {
    if (value.length > 4096) throw error('limit_exceeded', 'Response exceeds 4096 values');
    value = Array.from(value);
    if (value.some(part => typeof part !== 'string')) throw error('invalid_response', 'Multiple response members must be strings');
  } else if (value !== null && typeof value !== 'string' &&
      !(typeof value === 'number' && Number.isFinite(value))) {
    throw error('invalid_response', 'Response must be a string, finite number, string array, or null');
  }
  return JSON.stringify({ RESPONSE: value });
}

class CompiledItem {
  #handle;
  #disposed = false;

  constructor(handle) { this.#handle = handle; }

  get disposed() { return this.#disposed; }

  #assertLive() {
    if (this.#disposed) throw error('disposed', 'Compiled item has been disposed');
  }

  describe() {
    this.#assertLive();
    return unwrap(core.describe_compiled(this.#handle)).item;
  }

  score(response) {
    this.#assertLive();
    return unwrap(core.score_compiled(this.#handle, encodeResponse(response))).result;
  }

  explain(response) {
    this.#assertLive();
    const { result, steps } = unwrap(core.explain_compiled(this.#handle, encodeResponse(response)));
    return { result, steps };
  }

  scoreBatch(responses) {
    this.#assertLive();
    if (!Array.isArray(responses)) throw error('invalid_response', 'Batch must be an array');
    if (responses.length > 4096) throw error('limit_exceeded', 'Batch exceeds 4096 attempts');
    // Array.from visits holes as well, so every input index has an outcome.
    return Array.from(responses, (response, index) => {
      try { return { index, ok: true, result: this.score(response) }; }
      catch (cause) {
        if (!(cause instanceof QtiScoreError)) throw cause;
        return { index, ok: false, error: { code: cause.code, message: cause.message, location: cause.location } };
      }
    });
  }

  dispose() {
    if (this.#disposed) return;
    core.release(this.#handle);
    this.#disposed = true;
  }
}

/** Compile once, score repeatedly, and call dispose() when finished. */
export function compileItem(xml) {
  const { handle } = unwrap(core.compile(xmlText(xml)));
  return new CompiledItem(handle);
}

/** One-shot scoring; no persistent compiled handle is allocated. */
export function evaluateItem(xml, response) {
  const { result } = unwrap(core.evaluate(xmlText(xml), encodeResponse(response)));
  return result;
}

export function describeItem(xml) {
  return unwrap(core.describe(xmlText(xml))).item;
}
