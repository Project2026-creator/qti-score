import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { compileItem, evaluateItem, describeItem, QtiScoreError } = await import(sdkURL);
const core = await import(new URL('./qti-core.mjs', sdkURL));
const fixture = name => readFileSync(new URL(`../examples/${name}.xml`, import.meta.url), 'utf8');
const hasCode = code => cause => cause instanceof QtiScoreError && cause.code === code;

test('compiled and one-shot scoring agree for every supported interaction', () => {
  for (const [name, cases] of [
    ['single', [['A', 1], ['B', 0], [null, 0]]],
    ['multiple', [[['A', 'C'], 2], [['A'], 1], [['B'], 0], [[], 0]]],
    ['text', [['LMS', 1], ['lms', 0.5], [' LMS ', 0]]],
    ['numeric', [[100, 2], [100.5, 1], [104, 0.5], [110, 0], [null, 0]]],
    ['integer', [[42, 1], ['0042', 1], [41, 0]]],
  ]) {
    const xml = fixture(name);
    const item = compileItem(xml);
    try {
      for (const [response, expected] of cases) {
        const result = item.score({ RESPONSE: response });
        assert.equal(result.score, expected);
        assert.deepEqual(result, evaluateItem(xml, { RESPONSE: response }));
        assert.deepEqual(item.explain({ RESPONSE: response }).result, result);
        assert.equal(Object.hasOwn(result, 'steps'), false);
      }
    } finally { item.dispose(); }
  }
});

test('compiled instances are isolated and metadata is a fresh copy', () => {
  const a = compileItem(fixture('single'));
  const b = compileItem(fixture('numeric'));
  try {
    const description = a.describe();
    description.choices.length = 0;
    description.title = 'changed';
    assert.equal(a.describe().choices.length, 3);
    assert.equal(a.score({ RESPONSE: 'A' }).score, 1);
    assert.equal(b.score({ RESPONSE: 100 }).score, 2);
    assert.deepEqual(describeItem(fixture('single')), a.describe());
    assert.equal(Object.hasOwn(a.describe(), 'correct_response'), false);
  } finally { a.dispose(); b.dispose(); }
});

test('batch continues after an invalid response and preserves every input index', () => {
  const item = compileItem(fixture('numeric'));
  try {
    const results = item.scoreBatch([{ RESPONSE: 100 }, { RESPONSE: 'bad' }, { RESPONSE: 104 }, {}]);
    assert.deepEqual(results.map(row => row.ok), [true, false, true, true]);
    assert.deepEqual(results.map(row => row.index), [0, 1, 2, 3]);
    assert.equal(results[1].error.code, 'invalid_response');
    assert.equal(results[2].result.score, 0.5);
    assert.equal(item.scoreBatch(new Array(2)).length, 2);
    assert.equal(item.scoreBatch(new Array(2))[0].ok, false);
    assert.deepEqual(item.scoreBatch([]), []);
    assert.throws(() => item.scoreBatch(new Array(4097)), hasCode('limit_exceeded'));
    assert.throws(() => item.scoreBatch(null), hasCode('invalid_response'));
  } finally { item.dispose(); }
});

test('JavaScript values cannot silently turn into missing or NULL responses', () => {
  const item = compileItem(fixture('numeric'));
  try {
    for (const response of [{ RESPONSE: undefined }, { RESPONSE: NaN }, { RESPONSE: Infinity },
      { RESPONSE: 1n }, { RESPONSE: new Array(1) }, { OTHER: 1 }, undefined, [], new Date()]) {
      assert.throws(() => item.score(response), hasCode('invalid_response'));
    }
    let accessed = false;
    assert.throws(() => item.score({ get RESPONSE() { accessed = true; return 100; } }), hasCode('invalid_response'));
    assert.equal(accessed, false);
    assert.equal(item.score({}).status, 'unanswered');
  } finally { item.dispose(); }
});

test('integer parsing and finite numeric validation are enforced by the core', () => {
  const integer = compileItem(fixture('integer'));
  const text = compileItem(fixture('text'));
  try {
    for (const response of [42.5, Number.MAX_SAFE_INTEGER + 1, '4.2e1', '4503599627370496.5']) {
      assert.throws(() => integer.score({ RESPONSE: response }), hasCode('invalid_response'));
    }
    assert.throws(() => text.score({ RESPONSE: 42 }), hasCode('invalid_response'));
    assert.equal(integer.score({ RESPONSE: Number.MAX_SAFE_INTEGER }).score, 0);
  } finally { integer.dispose(); text.dispose(); }
});

test('explanations identify mapping contributions and numeric branch decisions', () => {
  const mapped = compileItem(fixture('multiple'));
  const numeric = compileItem(fixture('numeric'));
  try {
    const trace = mapped.explain({ RESPONSE: ['A', 'A', 'D'] });
    assert.equal(trace.result.score, 0);
    assert.ok(trace.steps.some(s => s.operation === 'duplicate_ignored'));
    assert.ok(trace.steps.some(s => s.operation === 'map_value' && s.details.used_default));
    const explanation = numeric.explain({ RESPONSE: 104 });
    assert.ok(explanation.steps.some(s => s.operation === 'numeric_condition' &&
      s.details.condition.mode === 'relative' && s.details.selected));
    assert.ok(explanation.steps.every(s => s.location.line > 0 && s.location.column > 0));
  } finally { mapped.dispose(); numeric.dispose(); }
});

test('disposal is idempotent and released handles are never reused', () => {
  const item = compileItem(fixture('single'));
  item.dispose(); item.dispose();
  assert.equal(item.disposed, true);
  for (const operation of [() => item.describe(), () => item.score({}), () => item.explain({}), () => item.scoreBatch([])]) {
    assert.throws(operation, hasCode('disposed'));
  }
  const old = JSON.parse(core.compile(fixture('single')));
  core.release(old.handle);
  const fresh = JSON.parse(core.compile(fixture('numeric')));
  try {
    assert.notEqual(old.handle, fresh.handle);
    assert.equal(JSON.parse(core.score_compiled(old.handle, '{}')).error.code, 'invalid_handle');
  } finally { core.release(fresh.handle); }
});

test('failed compilation does not consume handles and the live limit can be recovered', () => {
  for (let i = 0; i < 4; i++) assert.throws(() => compileItem('<bad/>'), hasCode('unsupported'));
  const items = [];
  try {
    for (let i = 0; i < 256; i++) items.push(compileItem(fixture('single')));
    assert.throws(() => compileItem(fixture('single')), hasCode('limit_exceeded'));
    assert.equal(evaluateItem(fixture('single'), { RESPONSE: 'A' }).score, 1);
    items.pop().dispose();
    items.push(compileItem(fixture('numeric')));
  } finally { items.forEach(item => item.dispose()); }
});

test('compilation errors preserve structured source positions', () => {
  assert.throws(() => compileItem(fixture('numeric').replace('tolerance="1"', 'tolerance="-1"')),
    cause => hasCode('invalid_item')(cause) && cause.location.line > 1 && cause.location.column > 0);
  assert.throws(() => compileItem(null), hasCode('invalid_item'));
});

test('standalone package runs after being copied outside the repository', () => {
  const folder = mkdtempSync(join(tmpdir(), 'qti-sdk-'));
  try {
    const source = fileURLToPath(new URL('./', sdkURL));
    const installed = join(folder, 'node_modules', '@project2026-creator', 'qti-score');
    mkdirSync(installed, { recursive: true });
    for (const file of ['index.mjs', 'index.d.mts', 'package.json', 'qti-core.mjs', 'README.md', 'LICENSE', 'NOTICE']) {
      copyFileSync(join(source, file), join(installed, file));
    }
    const script = `import {readFileSync} from 'node:fs';
      import {compileItem} from '@project2026-creator/qti-score';
      const item=compileItem(readFileSync(0,'utf8'));
      try { console.log(JSON.stringify(item.score({RESPONSE:100.5}))); } finally { item.dispose(); }`;
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script],
      { input: fixture('numeric'), encoding: 'utf8', cwd: folder });
    assert.equal(child.status, 0, child.stderr);
    assert.equal(JSON.parse(child.stdout).score, 1);
  } finally {
    assert.ok(resolve(folder).startsWith(resolve(tmpdir()) + sep + 'qti-sdk-'));
    rmSync(folder, { recursive: true, force: true });
  }
});
