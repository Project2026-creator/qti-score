import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { importPackage, QtiScoreError } = await import(sdkURL);
const bytes = name => readFileSync(new URL(`../web/${name}-test-package.zip`, import.meta.url));
const actions = name => JSON.parse(readFileSync(new URL(`../examples/${name}-actions.json`, import.meta.url), 'utf8'));
const hasCode = code => cause => cause instanceof QtiScoreError && cause.code === code;

test('seeded assembly preserves required anchors, chosen references and isolated metadata', () => {
  const bundle = importPackage(bytes('assembly'));
  const plans = [];
  try {
    for (const [seed, expected] of [
      [0, ['anchor','evidence','measurement','repeat','repeat']],
      [1, ['anchor','review','evidence','repeat','repeat']],
      [42, ['anchor','measurement','review','repeat','repeat']],
    ]) {
      const plan = bundle.getTest('assembly-test', { seed }); plans.push(plan);
      const description = plan.describe();
      assert.equal(description.assembly_seed, seed);
      assert.equal(description.candidate_count, 5);
      assert.deepEqual(description.entries.map(e => e.source_identifier), expected);
      assert.equal(new Set(description.entries.map(e => e.identifier)).size, 5);
      const same = bundle.getTest('assembly-test', { seed });
      try { assert.deepEqual(same.describe(), description); } finally { same.dispose(); }
      description.entries[0].weights.W = 100;
      description.entries[0].categories.length = 0;
      assert.equal(plan.describe().entries[0].weights.W, 2);
      assert.deepEqual(plan.describe().entries[0].categories, ['core']);
      assert.doesNotMatch(JSON.stringify(description), /correct_response|mapped_value/);
    }
    for (const seed of [-1, 0.5, NaN, Infinity, 2147483648, '1']) {
      assert.throws(() => bundle.getTest('assembly-test', { seed }), hasCode('invalid_response'));
    }
    const last = bundle.getTest('assembly-test', { seed: 2147483647 }); last.dispose();
  } finally { plans.forEach(plan => plan.dispose()); bundle.dispose(); }
});

test('assembled snapshots bind the seed and retain independent cloned grades in standard XML', () => {
  const bundle = importPackage(bytes('assembly'));
  const plan = bundle.getTest('assembly-test'), other = bundle.getTest('assembly-test', { seed: 1 });
  const sequence = actions('assembly'), session = plan.startSession(sequence.session_identifier);
  let restored;
  try {
    for (const action of sequence.actions.slice(0, 5)) session.act(action);
    const snapshot = session.snapshot();
    assert.equal(JSON.parse(snapshot).assembly_seed, 0);
    assert.throws(() => other.restoreSession(snapshot), hasCode('invalid_response'));
    const tampered = JSON.parse(snapshot); tampered.assembly_seed = 1;
    assert.throws(() => plan.restoreSession(JSON.stringify(tampered)), hasCode('invalid_response'));
    restored = plan.restoreSession(snapshot);
    for (const action of sequence.actions.slice(5)) restored.act(action);
    assert.equal(session.describe().completed, false);
    const { report, xml } = restored.exportResult(sequence.datestamp);
    assert.deepEqual(report.outcomes, { SCORE:6.5, CORE:3, ANCHOR:2, SECOND:1 });
    assert.deepEqual(report.items.map(e => e.outcomes.SCORE), [1,2,1,0,1]);
    assert.deepEqual(report.items.map(e => e.instance_index), [1,1,1,1,2]);
    assert.equal(report.items[3].identifier, report.items[4].identifier);
    assert.notEqual(report.items[3].instance_identifier, report.items[4].instance_identifier);
    assert.equal(report.items[3].response.RESPONSE, 'B');
    assert.equal(report.items[4].response.RESPONSE, 'A');
    assert.match(xml, /identifier="repeat"[^>]*sequenceIndex="4"/);
    assert.match(xml, /identifier="repeat"[^>]*sequenceIndex="5"/);
    assert.doesNotMatch(xml, /_qti_instance_/);
  } finally { restored?.dispose(); session.dispose(); other.dispose(); plan.dispose(); bundle.dispose(); }
});

test('all native interaction examples preserve structured drafts through the shared runtime', () => {
  const bundle = importPackage(bytes('interaction')), plan = bundle.getTest('interaction-test');
  const sequence = actions('interaction'), session = plan.startSession(sequence.session_identifier);
  let restored;
  try {
    for (const action of sequence.actions.slice(0, 9)) session.act(action);
    restored = plan.restoreSession(session.snapshot());
    for (const action of sequence.actions.slice(9)) restored.act(action);
    const { report } = restored.exportResult(sequence.datestamp);
    assert.deepEqual(report.items.map(e => e.outcomes.SCORE), [3,3,2,1,1,4,1,1]);
    assert.equal(report.outcomes.SCORE, 16);
    assert.deepEqual(report.items[3].response.RESPONSE, ['Analyze','Design','Develop','Implement','Evaluate']);
    assert.deepEqual(report.items[5].response, { ACTION:'Adapt', RATIO:75 });
    assert.deepEqual(report.items[7].response.RESPONSE, ['Locate','Adapt']);
  } finally { restored?.dispose(); session.dispose(); plan.dispose(); bundle.dispose(); }
});
