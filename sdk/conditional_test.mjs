import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { importPackage, QtiScoreError } = await import(sdkURL);
const archive = () => readFileSync(new URL('../web/conditional-test-package.zip', import.meta.url));
const script = suffix => JSON.parse(readFileSync(new URL(`../examples/conditional${suffix}-actions.json`, import.meta.url), 'utf8'));
const code = value => cause => cause instanceof QtiScoreError && cause.code === value;

for (const [name, suffix, total, skipped] of [
  ['pass', '', 4, [false, true, false, false]],
  ['catchup', '-catchup', 2, [false, false, true, false]],
  ['exit', '-exit', 0, [false, true, true, true]],
]) test(`conditional ${name} path preserves presented items and initial skipped sessions`, () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('conditional-test');
  const sequence = script(suffix), session = plan.startSession(sequence.session_identifier);
  try {
    for (const action of sequence.actions) session.act(action);
    const state = session.describe(), { report, xml } = session.exportResult(sequence.datestamp);
    assert.equal(state.completed, true);
    assert.deepEqual(report.outcomes, { SCORE: total });
    assert.equal(report.has_errors, false);
    assert.equal(report.all_items_scored, true);
    assert.deepEqual(state.items.map(item => item.skipped), skipped);
    assert.deepEqual(report.items.map(item => item.skipped), skipped);
    assert.deepEqual(report.items.map(item => item.presented), skipped.map(value => !value));
    assert.deepEqual(report.items.map(item => item.session_status), skipped.map(value => value ? 'initial' : 'final'));
    assert.deepEqual(report.items.map(item => item.num_attempts), skipped.map(value => value ? 0 : 1));
    assert.equal((xml.match(/sessionStatus="initial"/g) || []).length, skipped.filter(Boolean).length);
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('candidate test instructions remain safe, actor-filtered and isolated across descriptions', () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('conditional-test');
  const session = plan.startSession('instructions');
  try {
    const description = plan.describe(), current = session.describe();
    assert.equal(description.conditional_navigation, true);
    assert.deepEqual(description.parts.map(part => part.conditional_navigation), [true, false]);
    assert.deepEqual(current.current.instructions.map(instruction => instruction.scope), ['test', 'part', 'section']);
    assert.deepEqual(current.current.instructions.map(instruction => instruction.scope_identifier), ['guided-practice', 'diagnosis', 'diagnostic-section']);
    assert.doesNotMatch(JSON.stringify(description), /评分者提示|correct_response|mapped_value/);
    description.entries[0].instructions[0].text = 'Modified';
    current.current.instructions[0].text = 'Modified';
    assert.notEqual(plan.describe().entries[0].instructions[0].text, 'Modified');
    assert.notEqual(session.describe().current.instructions[0].text, 'Modified');
  } finally { session.dispose(); plan.dispose(); bundle.dispose(); }
});

test('branching occurs on next, restores active scope, and excludes skipped item grading', () => {
  const bundle = importPackage(archive()), plan = bundle.getTest('conditional-test');
  const session = plan.startSession('resumable'), sequence = script('');
  let restored;
  try {
    for (const action of sequence.actions.slice(0, 2)) session.act(action);
    assert.equal(session.describe().current.identifier, 'diagnostic');
    assert.equal(session.describe().items[1].skipped, false);
    session.act(sequence.actions[2]);
    const next = session.describe();
    assert.equal(next.current.identifier, 'advanced');
    assert.equal(next.items[1].skipped, true);
    assert.equal(next.items[1].num_attempts, 0);
    assert.equal(next.items[1].presented, false);
    assert.deepEqual(next.current.instructions.map(instruction => instruction.scope_identifier), ['guided-practice', 'diagnosis', 'advanced-section']);
    session.act({ type: 'pause', time: 3.5 });
    const snapshot = session.snapshot(); restored = plan.restoreSession(snapshot);
    assert.deepEqual(restored.describe(), session.describe());
    const before = restored.snapshot();
    assert.throws(() => restored.act({ type: 'select', time: 3.6, identifier: 'remedial' }), code('invalid_response'));
    assert.equal(restored.snapshot(), before);
    restored.act({ type: 'resume', time: 3.7 });
    for (const action of sequence.actions.slice(3)) restored.act(action);
    assert.equal(restored.exportResult(sequence.datestamp).report.outcomes.SCORE, 4);
    assert.equal(session.describe().paused, true);
    assert.equal(session.snapshot(), snapshot);
  } finally { restored?.dispose(); session.dispose(); plan.dispose(); bundle.dispose(); }
});
