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
  const keys = Reflect.ownKeys(response);
  if (keys.length > 32) throw error('limit_exceeded', 'At most 32 response variables');
  const encoded = Object.create(null);
  for (const key of keys) {
    if (typeof key !== 'string') throw error('invalid_response', 'Unknown response identifier');
    const descriptor = Object.getOwnPropertyDescriptor(response, key);
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
    encoded[key] = value;
  }
  return JSON.stringify(encoded);
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

  present(response) {
    this.#assertLive();
    return unwrap(core.present_compiled(this.#handle, encodeResponse(response))).presentation;
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

function packageKey(value) {
  if (typeof value !== 'string') throw error('invalid_package', 'Resource identifier or file path must be a string');
  return value;
}

class ContentPackage {
  #handle;
  #disposed = false;
  constructor(handle) { this.#handle = handle; }
  get disposed() { return this.#disposed; }
  #assertLive() {
    if (this.#disposed) throw error('disposed', 'Content package has been disposed');
  }
  describe() {
    this.#assertLive();
    return unwrap(core.describe_package(this.#handle)).package;
  }
  getItem(resourceId) {
    this.#assertLive();
    const { handle } = unwrap(core.package_item(this.#handle, packageKey(resourceId)));
    return new CompiledItem(handle);
  }
  getTest(resourceId, { seed = 0 } = {}) {
    this.#assertLive();
    if (!Number.isInteger(seed) || seed < 0 || seed > 2147483647) {
      throw error('invalid_response', 'Assembly seed must be an integer from 0 to 2147483647');
    }
    const { handle } = unwrap(core.package_test_seeded(this.#handle, packageKey(resourceId), seed));
    return new CompiledTest(handle);
  }
  resourceFiles(resourceId) {
    this.#assertLive();
    return unwrap(core.package_files(this.#handle, packageKey(resourceId))).files;
  }
  readFile(path) {
    this.#assertLive();
    const { base64 } = unwrap(core.package_file(this.#handle, packageKey(path)));
    return Uint8Array.from(atob(base64), character => character.charCodeAt(0));
  }
  scoreAttempts(jsonl) {
    this.#assertLive();
    if (typeof jsonl !== 'string') throw error('invalid_response', 'Batch JSONL must be a string');
    const { report, csv, items_csv: itemsCsv } = unwrap(core.score_package_attempts(this.#handle, jsonl));
    return { report, csv, itemsCsv };
  }
  dispose() {
    if (this.#disposed) return;
    core.release_package(this.#handle);
    this.#disposed = true;
  }
}

/** Import a bounded ZIP in memory. Opened items have independent lifetimes. */
export function importPackage(bytes) {
  if (!(bytes instanceof Uint8Array)) throw error('invalid_package', 'ZIP input must be a Uint8Array');
  if (bytes.byteLength > 8 * 1048576) throw error('limit_exceeded', 'ZIP input exceeds 8 MiB');
  const { handle } = unwrap(core.import_package(new Uint8Array(bytes)));
  return new ContentPackage(handle);
}

function clockValue(value) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw error('invalid_response', 'Session time must be a finite nonnegative number');
  }
  return value;
}

function encodeAction(action) {
  if (!action || typeof action !== 'object' || Array.isArray(action) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(action))) {
    throw error('invalid_response', 'Expected a plain session action object');
  }
  const result = Object.create(null);
  for (const key of Reflect.ownKeys(action)) {
    if (!['type', 'time', 'identifier', 'response'].includes(key)) {
      throw error('invalid_response', 'Unknown session action field');
    }
    const descriptor = Object.getOwnPropertyDescriptor(action, key);
    if (!Object.hasOwn(descriptor, 'value')) throw error('invalid_response', 'Action must contain data, not an accessor');
    const value = descriptor.value;
    if (key === 'response') result[key] = JSON.parse(encodeResponse(value));
    else if (key === 'time') result[key] = clockValue(value);
    else {
      if (typeof value !== 'string') throw error('invalid_response', `Action ${key} must be a string`);
      result[key] = value;
    }
  }
  return JSON.stringify(result);
}

class CompiledTest {
  #handle;
  #disposed = false;
  constructor(handle) { this.#handle = handle; }
  get disposed() { return this.#disposed; }
  #assertLive() {
    if (this.#disposed) throw error('disposed', 'Compiled test has been disposed');
  }
  describe() {
    this.#assertLive();
    return unwrap(core.describe_test(this.#handle)).test;
  }
  startSession(identifier, { now = 0 } = {}) {
    this.#assertLive();
    if (typeof identifier !== 'string') throw error('invalid_response', 'Session identifier must be a string');
    const { handle } = unwrap(core.start_test_session(this.#handle, identifier, clockValue(now)));
    return new TestSession(handle);
  }
  restoreSession(snapshot) {
    this.#assertLive();
    if (typeof snapshot !== 'string') throw error('invalid_response', 'Snapshot must be a JSON string');
    const { handle } = unwrap(core.restore_test_session(this.#handle, snapshot));
    return new TestSession(handle);
  }
  dispose() {
    if (this.#disposed) return;
    core.release_test(this.#handle);
    this.#disposed = true;
  }
}

class TestSession {
  #handle;
  #disposed = false;
  constructor(handle) { this.#handle = handle; }
  get disposed() { return this.#disposed; }
  #assertLive() {
    if (this.#disposed) throw error('disposed', 'Test session has been disposed');
  }
  act(action) {
    this.#assertLive();
    return unwrap(core.act_test_session(this.#handle, encodeAction(action))).session;
  }
  describe() {
    this.#assertLive();
    return unwrap(core.describe_test_session(this.#handle)).session;
  }
  snapshot() {
    this.#assertLive();
    return unwrap(core.snapshot_test_session(this.#handle)).snapshot;
  }
  exportResult(datestamp, { candidateIdentifier = 'anonymous' } = {}) {
    this.#assertLive();
    if (typeof datestamp !== 'string' || typeof candidateIdentifier !== 'string') {
      throw error('invalid_response', 'Datestamp and candidate identifier must be strings');
    }
    const { report, xml } = unwrap(core.export_test_session(this.#handle, datestamp, candidateIdentifier));
    return { report, xml };
  }
  dispose() {
    if (this.#disposed) return;
    core.release_test_session(this.#handle);
    this.#disposed = true;
  }
}
