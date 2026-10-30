import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { importPackage, QtiScoreError } = await import(sdkURL);
const core = await import(new URL('./qti-core.mjs', sdkURL));
const archive = () => readFileSync(new URL('../web/runtime-test-package.zip', import.meta.url));
const script = () => JSON.parse(readFileSync(new URL('../examples/runtime-actions.json', import.meta.url), 'utf8'));
const hasCode = code => cause => cause instanceof QtiScoreError && cause.code === code;
function setup() {
  const bundle = importPackage(archive());
  const plan = bundle.getTest('runtime-test');
  return { bundle, plan };
}

test('test SDK executes authored parts, repeated item instances and test outcomes', () => {
  const { bundle, plan } = setup();
  const sequence = script(), session = plan.startSession(sequence.session_identifier);
  try {
    assert.equal(plan.describe().parts.length, 2);
    assert.equal(plan.describe().item_count, 4);
    assert.deepEqual(plan.describe().outcome_types.SCORE, { base_type: 'float', cardinality: 'single' });
    for (const action of sequence.actions) session.act(action);
    assert.equal(session.describe().completed, true);
    const { report, xml } = session.exportResult(sequence.datestamp, { candidateIdentifier: sequence.candidate_identifier });
    assert.equal(report.outcomes.SCORE, 4);
    assert.equal(report.items.length, 4);
    assert.equal(report.items[0].item_identifier, report.items[2].item_identifier);
    assert.notEqual(report.items[0].identifier, report.items[2].identifier);
    assert.match(xml, /assessmentResult/);
    assert.match(xml, /formative-1/);
    assert.match(xml, /formative-2/);
    assert.match(xml, /demo-candidate/);
    assert.doesNotMatch(xml, /C:\\Users|file:\/\//);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('session handles remain usable after package and test disposal', () => {
  const { bundle, plan } = setup(), session = plan.startSession('independent');
  bundle.dispose(); plan.dispose();
  try {
    assert.equal(session.act({ type: 'save', time: 1, response: { RESPONSE: 'A' } }).current.result, null);
    assert.equal(session.act({ type: 'submit', time: 2 }).current.result.score, 1);
    assert.throws(() => bundle.getTest('runtime-test'), hasCode('disposed'));
    assert.throws(() => plan.describe(), hasCode('disposed'));
    session.dispose(); session.dispose();
    for (const call of [() => session.describe(), () => session.snapshot(), () => session.act({ type: 'tick', time: 3 }), () => session.exportResult('2026-10-30T12:00:00Z')]) {
      assert.throws(call, hasCode('disposed'));
    }
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('paused snapshots replay into independent sessions and preserve response isolation', () => {
  const { bundle, plan } = setup(), session = plan.startSession('restore');
  let restored;
  try {
    session.act({ type: 'save', time: 1, response: { RESPONSE: 'A' } });
    session.act({ type: 'pause', time: 2 });
    const snapshot = session.snapshot();
    restored = plan.restoreSession(snapshot);
    assert.deepEqual(restored.describe(), session.describe());
    assert.equal(JSON.parse(snapshot).format, 'qti-score-test-session-v1');
    assert.doesNotMatch(snapshot, /correct_response|processing_source|MapEntry/);
    restored.act({ type: 'resume', time: 20 });
    restored.act({ type: 'submit', time: 21 });
    assert.equal(restored.describe().current.num_attempts, 1);
    assert.equal(session.describe().current.num_attempts, 0);
    const copied = restored.describe(); copied.current.response.RESPONSE = 'B';
    assert.equal(restored.describe().current.response.RESPONSE, 'A');
    assert.throws(() => plan.restoreSession(snapshot.replace(JSON.parse(snapshot).test_identity, 'wrong-test')), hasCode('invalid_response'));
  } finally { restored?.dispose(); session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('draft responses and simultaneous parts do not expose early scores', () => {
  const { bundle, plan } = setup(), session = plan.startSession('deferred');
  try {
    const actions = script().actions;
    const saved = session.act(actions[0]);
    assert.equal(saved.current.result, null);
    for (const action of actions.slice(1, 6)) session.act(action);
    const deferred = session.act(actions[6]);
    assert.equal(deferred.current.result, null);
    assert.deepEqual(deferred.current.feedback, []);
    assert.equal(deferred.current.submitted, false);
    const before = session.snapshot();
    assert.throws(() => session.act({ type: 'submit', time: 8 }), hasCode('invalid_response'));
    assert.equal(session.snapshot(), before);
    assert.throws(() => session.exportResult('2026-10-30T12:00:00Z'), hasCode('invalid_response'));
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('SDK rejects unsafe actions and invalid clocks before changing a session', () => {
  const { bundle, plan } = setup(), session = plan.startSession('invalid');
  try {
    const before = session.snapshot();
    const accessor = { type: 'save', time: 1 };
    Object.defineProperty(accessor, 'response', { get() { throw new Error('must not execute'); } });
    for (const action of [
      { type: 'save', time: NaN, response: {} },
      { type: 'save', time: Infinity, response: {} },
      { type: 'save', time: -1, response: {} },
      { type: 'save', time: 1, response: { RESPONSE: NaN } },
      { type: 'save', time: 1, response: { RESPONSE: ['A', undefined] } },
      { type: 'save', time: 1, response: { RESPONSE: 'A' }, extra: true },
      { type: 'save', time: 1, response: { RESPONSE: 'UNKNOWN' } },
      accessor, [], null,
    ]) {
      assert.throws(() => session.act(action), hasCode('invalid_response'));
      assert.equal(session.snapshot(), before);
    }
    assert.throws(() => plan.startSession('bad', { now: NaN }), hasCode('invalid_response'));
    assert.throws(() => plan.restoreSession({}), hasCode('invalid_response'));
    assert.throws(() => bundle.getTest('choice'), hasCode('invalid_package'));
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('test and session tables enforce independent bounded lifetimes', () => {
  const bundle = importPackage(archive()), plans = [], sessions = [];
  try {
    for (let i = 0; i < 16; i++) plans.push(bundle.getTest('runtime-test'));
    assert.throws(() => bundle.getTest('runtime-test'), hasCode('limit_exceeded'));
    plans.pop().dispose(); plans.push(bundle.getTest('runtime-test'));
    for (let i = 0; i < 16; i++) sessions.push(plans[0].startSession(`session-${i}`));
    assert.throws(() => plans[0].startSession('overflow'), hasCode('limit_exceeded'));
    sessions.pop().dispose(); sessions.push(plans[0].startSession('replacement'));
    for (const plan of plans) plan.dispose();
    assert.equal(sessions[0].describe().session_identifier, 'session-0');
  } finally { sessions.forEach(session => session.dispose()); plans.forEach(plan => plan.dispose()); bundle.dispose(); }
});

test('bridge rejects invalid test and session handles without mutation', () => {
  for (const call of [
    () => core.package_test(-1, 'runtime-test'), () => core.describe_test(-1),
    () => core.start_test_session(-1, 'invalid', 0), () => core.restore_test_session(-1, '{}'),
    () => core.describe_test_session(-1), () => core.snapshot_test_session(-1),
    () => core.act_test_session(-1, '{}'), () => core.export_test_session(-1, '2026-10-30T12:00:00Z', 'anonymous'),
  ]) assert.equal(JSON.parse(call()).error.code, 'invalid_handle');
  assert.equal(core.release_test(-1), false);
  assert.equal(core.release_test_session(-1), false);
});

test('typed feedback and extended text keep external grades pending through result export', () => {
  const bytes = readFileSync(new URL('../web/feedback-test-package.zip', import.meta.url));
  const sequence = JSON.parse(readFileSync(new URL('../examples/feedback-actions.json', import.meta.url), 'utf8'));
  const bundle = importPackage(bytes), plan = bundle.getTest('feedback-workflow');
  const session = plan.startSession(sequence.session_identifier);
  try {
    const description = plan.describe();
    assert.equal(description.item_count, 3);
    assert.equal(description.entries[0].item.template, 'typed_rules');
    assert.equal(description.entries[0].item.has_feedback, true);
    assert.equal(description.entries[1].item.extended_text.expected_lines, 3);
    assert.equal(description.entries[2].item.external_scoring, true);
    for (const [index, action] of sequence.actions.entries()) {
      const state = session.act(action);
      if (index === 1) {
        assert.equal(state.current.result.score, 5);
        assert.equal(state.current.feedback[0].identifier, 'both');
      }
      if (index === 4) assert.equal(state.current.result.score, 2);
      if (index === 7) assert.equal(state.current.result, null);
    }
    const { report, xml } = session.exportResult(sequence.datestamp);
    assert.equal(report.has_errors, false);
    assert.equal(report.all_items_scored, false);
    assert.equal(report.outcomes.SCORE, null);
    assert.equal(report.outcomes.MAXSCORE, 7);
    assert.equal(report.items[2].session_status, 'pendingExternalScoring');
    assert.equal(report.items[2].outcomes.SCORE, null);
    assert.equal(report.items[2].response.REFLECTION, sequence.actions[6].response.REFLECTION);
    assert.match(xml, /pendingExternalScoring/);
    assert.match(xml, /演示作答/);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('graphic test shares local image bytes and scores hotspot and directed region pairs', () => {
  const bundle = importPackage(readFileSync(new URL('../web/graphic-test-package.zip', import.meta.url)));
  const plan = bundle.getTest('graphic-test'), session = plan.startSession('graphic-session');
  const sequence = JSON.parse(readFileSync(new URL('../examples/graphic-actions.json', import.meta.url), 'utf8'));
  try {
    const description = plan.describe();
    assert.equal(description.entries[0].item.graphic.kind, 'hotspot');
    assert.equal(description.entries[0].item.graphic.regions.length, 3);
    assert.equal(description.entries[1].item.graphic.kind, 'graphic_gap_match');
    assert.ok(new TextDecoder().decode(bundle.readFile('items/graphic-map.svg')).includes('<svg'));
    assert.ok(!JSON.stringify(description).includes('correct_response'));
    for (const action of sequence.actions) session.act(action);
    const { report, xml } = session.exportResult(sequence.datestamp);
    assert.equal(report.has_errors, false);
    assert.equal(report.outcomes.SCORE, 4);
    assert.deepEqual(report.items.map(item => item.outcomes.SCORE), [1,3]);
    assert.deepEqual(report.items[1].response.RESPONSE, ['Read Reading','Discuss Collaboration','Share Presentation']);
    assert.match(xml, /baseType="directedPair"/);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});
