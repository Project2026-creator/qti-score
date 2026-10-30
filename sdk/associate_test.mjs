import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { associateChoices } from '../web/associate.mjs';

const { compileItem, importPackage, QtiScoreError } = await import(process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href);
const xml = readFileSync(new URL('../examples/associate.xml', import.meta.url), 'utf8');
const full = ['Memory Cognitivism', 'Reinforcement Behaviorism', 'ActiveLearning Constructivism'];
const hasCode = code => error => error instanceof QtiScoreError && error.code === code;

test('associate reverses endpoints without mutating caller input or leaking keys', () => {
  const item = compileItem(xml);
  try {
    const response = { RESPONSE: [...full] };
    assert.deepEqual(item.score(response), { score: 3, status: 'answered', matches_correct: true });
    assert.deepEqual(response.RESPONSE, full);
    assert.equal(item.score({ RESPONSE: ['Cognitivism Memory'] }).score, 1);
    const description = item.describe();
    assert.equal(description.base_type, 'pair');
    assert.equal(description.association.choices.length, 6);
    assert.doesNotMatch(JSON.stringify(description), /correct_response|map_key|mapped_value/);
    description.association.choices[0].match_group.push('changed');
    description.association.choices.length = 0;
    assert.equal(item.describe().association.choices.length, 6);
    assert.deepEqual(item.describe().association.choices[0].match_group, []);
  } finally { item.dispose(); }
});

test('associate rejects reversed duplicate self and exhausted endpoints', () => {
  const item = compileItem(xml);
  try {
    for (const pairs of [['Memory Cognitivism', 'Cognitivism Memory'], ['Memory Memory'], ['Memory Missing'], ['Memory Cognitivism', 'Memory Behaviorism']]) {
      assert.throws(() => item.score({ RESPONSE: pairs }), hasCode('invalid_response'));
    }
    assert.equal(item.score({ RESPONSE: [] }).status, 'unanswered');
    assert.equal(item.score({}).score, 0);
  } finally { item.dispose(); }
});

test('associate shuffle respects fixed slots and leaves authored metadata intact', () => {
  const item = compileItem(xml);
  try {
    const spec = item.describe().association, original = structuredClone(spec);
    const shuffled = associateChoices(spec, () => 0);
    assert.deepEqual(spec, original);
    assert.deepEqual(shuffled[5], spec.choices[5]);
    assert.notDeepEqual(shuffled.slice(0, 5), spec.choices.slice(0, 5));
    assert.deepEqual(associateChoices({ ...spec, shuffle: false }), spec.choices);
  } finally { item.dispose(); }
});

test('typed composite descriptions retain association controls beside text entries', () => {
  const source = xml.replace('</qti-response-declaration>', '</qti-response-declaration><qti-response-declaration identifier="NOTE" cardinality="single" base-type="string"/>')
    .replace('</qti-item-body>', '<p>补充说明：<qti-text-entry-interaction response-identifier="NOTE"/></p></qti-item-body>')
    .replace(/<qti-response-processing[^>]*\/>/, '<qti-response-processing><qti-set-outcome-value identifier="SCORE"><qti-map-response identifier="RESPONSE"/></qti-set-outcome-value></qti-response-processing>');
  const item = compileItem(source);
  try {
    const metadata = item.describe();
    assert.equal(metadata.kind, 'composite');
    assert.equal(metadata.responses[0].association.choices.length, 6);
    assert.equal(metadata.responses[1].base_type, 'string');
    assert.equal(item.score({ RESPONSE: full, NOTE: '学习理论' }).score, 3);
  } finally { item.dispose(); }
});

test('associate session resumes a draft and exports canonical pair variables', () => {
  const bundle = importPackage(readFileSync(new URL('../web/associate-test-package.zip', import.meta.url)));
  const plan = bundle.getTest('associate-test'), session = plan.startSession('association-resume');
  let restored;
  try {
    session.act({ type: 'save', time: 1, response: { RESPONSE: full } });
    restored = plan.restoreSession(session.snapshot());
    assert.deepEqual(restored.describe(), session.describe());
    const before = restored.snapshot();
    assert.throws(() => restored.act({ type: 'save', time: 2, response: { RESPONSE: ['Memory Memory'] } }), hasCode('invalid_response'));
    assert.equal(restored.snapshot(), before);
    restored.act({ type: 'submit', time: 2 });
    restored.act({ type: 'finish_part', time: 3 });
    const { report, xml: result } = restored.exportResult('2026-10-30T12:00:00Z');
    assert.equal(report.outcomes.SCORE, 3);
    assert.deepEqual(report.items[0].response.RESPONSE, ['Cognitivism Memory', 'Behaviorism Reinforcement', 'ActiveLearning Constructivism']);
    assert.match(result, /baseType="pair"/);
    assert.doesNotMatch(result, /correctResponse|mapping/);
  } finally { restored?.dispose(); session.dispose(); plan.dispose(); bundle.dispose(); }
});
