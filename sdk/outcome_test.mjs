import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { importPackage, QtiScoreError } = await import(sdkURL);
const archive = () => readFileSync(new URL('../web/outcome-test-package.zip', import.meta.url));
const script = suffix => JSON.parse(readFileSync(new URL(`../examples/outcome${suffix}-actions.json`, import.meta.url), 'utf8'));
const hasCode = value => cause => cause instanceof QtiScoreError && cause.code === value;

for (const [name, suffix, expected, foundation] of [
  ['mastered', '', { SCORE: 4, PERCENT: 100, LEVEL: 'mastered' }, 'developing'],
  ['review', '-review', { SCORE: 0, PERCENT: 0, LEVEL: 'review' }, 'review'],
]) test(`authored ${name} route converts scores and delivers final test feedback`, () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('outcome-test');
  const sequence = script(suffix), session = plan.startSession(sequence.session_identifier);
  try {
    for (const action of sequence.actions) session.act(action);
    const state = session.describe(), { report, xml } = session.exportResult(sequence.datestamp);
    assert.equal(state.completed, true);
    assert.equal(report.has_errors, false);
    assert.equal(report.all_items_scored, true);
    assert.deepEqual(report.outcomes, expected);
    assert.deepEqual(report.test_feedback, state.test_feedback);
    assert.deepEqual(report.test_feedback.during, []);
    assert.deepEqual(report.test_feedback.at_end.map(message => message.identifier), [expected.LEVEL]);
    assert.deepEqual(report.test_feedback.completed_parts.map(part => part.part_identifier), ['foundation', 'transfer']);
    assert.deepEqual(report.test_feedback.completed_parts.map(part => part.completed_at), [6, 8]);
    assert.deepEqual(report.test_feedback.completed_parts[0].feedback.map(message => message.identifier), [foundation]);
    assert.match(xml, /identifier="PERCENT"/);
    assert.match(xml, /identifier="LEVEL"/);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('during feedback requires successful outcome processing and follows the active part', () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('outcome-test');
  const sequence = script(''), session = plan.startSession('during-feedback');
  try {
    assert.deepEqual(session.describe().test_feedback, { during: [], completed_parts: [], at_end: [] });
    session.act(sequence.actions[0]);
    assert.deepEqual(session.describe().test_feedback.during, []);
    session.act(sequence.actions[1]);
    const feedback = session.describe().test_feedback;
    assert.deepEqual(feedback.during.map(message => [message.scope, message.identifier, message.access]),
      [['test', 'developing', 'during'], ['part', 'developing', 'during']]);
    assert.deepEqual(feedback.at_end, []);
    assert.deepEqual(feedback.completed_parts, []);
    for (const action of sequence.actions.slice(2, 6)) session.act(action);
    const next = session.describe().test_feedback;
    assert.deepEqual(next.during.map(message => message.scope), ['test']);
    assert.deepEqual(next.completed_parts[0].feedback.map(message => message.identifier), ['developing']);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('feedback metadata is isolated and does not expose hidden text or conversion tables', () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('outcome-test');
  const sequence = script(''), session = plan.startSession('feedback-isolation');
  try {
    const description = plan.describe();
    assert.equal(description.has_feedback, true);
    assert.deepEqual(description.parts.map(part => [part.title, part.has_feedback]), [['基础理解', true], ['测量与迁移', true]]);
    assert.deepEqual(description.outcome_types.LEVEL, { base_type: 'identifier', cardinality: 'single' });
    assert.doesNotMatch(JSON.stringify(description), /interpolation|target-value|本次作答达到 mastered/);
    for (const action of sequence.actions.slice(0, 6)) session.act(action);
    const feedback = session.describe().test_feedback;
    feedback.during[0].text = 'Changed';
    feedback.completed_parts[0].feedback[0].text = 'Changed';
    feedback.completed_parts.length = 0;
    const fresh = session.describe().test_feedback;
    assert.notEqual(fresh.during[0].text, 'Changed');
    assert.notEqual(fresh.completed_parts[0].feedback[0].text, 'Changed');
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('restored part-end feedback stays frozen while simultaneous drafts wait for submission', () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('outcome-test');
  const sequence = script(''), session = plan.startSession('frozen-feedback');
  let restored;
  try {
    for (const action of sequence.actions.slice(0, 6)) session.act(action);
    const foundation = session.describe().test_feedback.completed_parts[0];
    session.act({ type: 'pause', time: 6.1 });
    restored = plan.restoreSession(session.snapshot());
    assert.deepEqual(restored.describe(), session.describe());
    restored.act({ type: 'resume', time: 6.2 });
    const before = restored.describe().test_feedback;
    restored.act(sequence.actions[6]);
    assert.deepEqual(restored.describe().test_feedback, before);
    assert.equal(restored.describe().current.result, null);
    const snapshot = restored.snapshot();
    assert.throws(() => restored.act({ type: 'save', time: 7.1, response: { RESPONSE: 'bad' } }), hasCode('invalid_response'));
    assert.equal(restored.snapshot(), snapshot);
    assert.deepEqual(restored.describe().test_feedback, before);
    restored.act(sequence.actions[7]);
    const report = restored.exportResult(sequence.datestamp).report;
    assert.deepEqual(report.outcomes, { SCORE: 4, PERCENT: 100, LEVEL: 'mastered' });
    assert.deepEqual(report.test_feedback.completed_parts[0], foundation);
    assert.equal(report.test_feedback.at_end[0].identifier, 'mastered');
    assert.equal(session.describe().paused, true);
  } finally { restored?.dispose(); session.dispose(); plan.dispose(); bundle.dispose(); }
});
