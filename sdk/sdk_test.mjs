import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, copyFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const sdkURL = process.env.QTI_SDK_URL || new URL('./index.mjs', import.meta.url).href;
const { compileItem, evaluateItem, describeItem, importPackage, QtiScoreError } = await import(sdkURL);
const core = await import(new URL('./qti-core.mjs', sdkURL));
const fixture = name => readFileSync(new URL(`../examples/${name}.xml`, import.meta.url), 'utf8');
const hasCode = code => cause => cause instanceof QtiScoreError && cause.code === code;
const packageBytes = () => readFileSync(new URL('../web/sample-package.zip', import.meta.url));
const packageAttempts = () => readFileSync(new URL('../examples/package-attempts.jsonl', import.meta.url), 'utf8');

test('composite sliders combine scalar fields and keep independent numeric metadata', () => {
  const item = compileItem(fixture('composite-slider'));
  try {
    const answer = Object.freeze({ TIME: 40, RATIO: 0.75, ACTION: 'Adapt' });
    assert.deepEqual(item.score(answer), { score: 5, status: 'answered', matches_correct: true });
    assert.equal(item.explain({ TIME: 40, RATIO: 0.7, ACTION: 'Adapt' }).result.score, 4);
    const metadata = item.describe();
    assert.equal(metadata.responses[0].slider.step, 10);
    assert.equal(metadata.responses[1].slider.step, 0.05);
    assert.equal(metadata.responses[2].slider, undefined);
    assert.equal(metadata.responses[2].inline_choice.choices.length, 2);
    assert.ok(metadata.responses[0].slider.prompt.includes('50 分钟'));
    assert.ok(!metadata.passage.some(p => p.text?.includes('50 分钟')));
    metadata.responses[0].slider.step = 999;
    assert.equal(item.describe().responses[0].slider.step, 10);
    const invalid = [{ TIME: 35, RATIO: 0.75 }, { TIME: 40, RATIO: 0.73 }, { RATIO: 1.05 },
      { TIME: ['40'] }, { RATIO: true }, { TIME: '4e1' }];
    const rows = item.scoreBatch([...invalid, answer]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [...invalid.map(() => 'invalid_response'), 5]);
    assert.throws(() => item.score({ TIME: 35 }), error => hasCode('invalid_response')(error) && error.message.includes('TIME'));
  } finally { item.dispose(); }
});

test('continuous composite sliders distinguish intentional zero from omissions', () => {
  const item = compileItem(fixture('composite-slider-continuous'));
  try {
    for (const answer of [{}, { ZERO: null, RATE: null }, { ZERO: '', RATE: ' ' }]) {
      assert.deepEqual(item.score(answer), { score: 0, status: 'unanswered', matches_correct: false });
    }
    assert.equal(item.score({ ZERO: 0 }).score, 1);
    assert.equal(item.score({ ZERO: null, RATE: 0.5 }).score, 2);
    assert.equal(item.score({ ZERO: 0, RATE: 0.5 }).matches_correct, true);
    assert.equal(item.score({ RATE: 0.55 }).score, 1);
    assert.equal(item.score({ RATE: 0.333 }).status, 'answered');
    const fields = item.describe().responses;
    assert.deepEqual([fields[0].slider.lower_bound, fields[0].slider.upper_bound], [0, 10]);
    assert.equal(fields[1].slider.step, null);
    assert.equal(fields[1].slider.orientation, 'vertical');
    assert.equal(fields[1].slider.reverse, true);
    assert.throws(() => item.score({ ZERO: 9 }), hasCode('invalid_response'));
  } finally { item.dispose(); }
});

test('composite slider package exports preserve partial attempts and independent handles', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-slider-package.zip', import.meta.url)));
  const item = bundle.getItem('mixed');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv, itemsCsv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-slider-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null), [5, 3, 4, 0, 1, null, null, null, 1, 0]);
    assert.equal(report.attempts[0].score_sum, 8);
    assert.equal(report.items[0].score_mean, 3);
    assert.equal(report.items[1].score_mean, 1.25);
    assert.ok(csv.includes('invalid_response'));
    assert.ok(itemsCsv.includes('"mixed",5,3,2'));
    bundle.dispose();
    assert.equal(item.score({ TIME: 40 }).score, 2);
  } finally { item.dispose(); bundle.dispose(); }
});

test('composite multiple arrays preserve partial credit, bag matching and caller inputs', () => {
  const item = compileItem(fixture('composite-multiple'));
  try {
    const answer = Object.freeze({ EVIDENCE: Object.freeze(['Feedback', 'Quiz']), ACTION: 'Adapt', COUNT: 4 });
    assert.deepEqual(item.score(answer), { score: 4, status: 'answered', matches_correct: true });
    const explanation = item.explain({ EVIDENCE: ['Quiz', 'Quiz'] });
    assert.equal(explanation.result.score, 1);
    assert.equal(explanation.result.matches_correct, false);
    assert.ok(explanation.steps.some(s => s.operation === 'duplicate_ignored'));
    const binding = item.describe().responses[0];
    assert.equal(binding.cardinality, 'multiple');
    assert.equal(binding.choice.min_choices, 0);
    assert.equal(binding.choice.max_choices, 2);
    binding.choice.choices.length = 0;
    assert.equal(item.describe().responses[0].choice.choices.length, 3);
    for (const value of [null, []]) assert.equal(item.score({ EVIDENCE: value }).status, 'unanswered');
    const invalid = ['Quiz', '', ['Quiz', 'Feedback', 'Rank'], ['Unknown'], [''], 1, [null]];
    const rows = item.scoreBatch([...invalid.map(value => ({ EVIDENCE: value })), answer]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [...invalid.map(() => 'invalid_response'), 4]);
  } finally { item.dispose(); }
});

test('required multiple groups enforce minimums and preserve unordered match multiplicity', () => {
  const item = compileItem(fixture('composite-multiple-required'));
  try {
    for (const response of [{}, { EVIDENCE: [], TOOLS: ['Quiz'] }, { EVIDENCE: ['Quiz'], TOOLS: ['Quiz'] },
      { EVIDENCE: ['Quiz', 'Feedback'] }, { EVIDENCE: ['Quiz', 'Portfolio'], TOOLS: ['Quiz'] }]) {
      assert.throws(() => item.score(response), hasCode('invalid_response'));
    }
    assert.equal(item.score({ EVIDENCE: ['Quiz', 'Quiz'], TOOLS: ['Quiz', 'Quiz'] }).score, 1);
    assert.equal(item.score({ EVIDENCE: ['Feedback', 'Quiz'], TOOLS: ['Portfolio', 'Quiz', 'Poster'] }).score, 4);
    assert.equal(item.describe().responses[1].choice.max_choices, 0);
  } finally { item.dispose(); }
});

test('multiple package batches isolate invalid rows and retain full exports and item handles', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-multiple-package.zip', import.meta.url)));
  const item = bundle.getItem('mixed');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv, itemsCsv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-multiple-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(row => row.ok ? row.result.score : null), [4, 4, 2, 1, 0, null, null, null, 1, 2]);
    assert.equal(report.attempts[0].score_sum, 8);
    assert.equal(report.scored_count, 7);
    assert.equal(report.error_count, 3);
    assert.equal(report.items[0].score_mean, 1.8);
    assert.ok(csv.includes('invalid_response'));
    assert.ok(itemsCsv.includes('"mixed",7,5,2'));
    bundle.dispose();
    assert.equal(item.score({ EVIDENCE: ['Quiz'] }).score, 1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('composite single choices preserve separate scalar control descriptions and partial credit', () => {
  const item = compileItem(fixture('composite-choice'));
  try {
    const answer = { METHOD: 'Formative', ACTION: 'Adapt', RATIO: 75, UNIT: '%' };
    assert.deepEqual(item.score(answer), { score: 6, status: 'answered', matches_correct: true });
    assert.equal(item.explain(answer).result.score, 6);
    assert.equal(item.score({ METHOD: 'Formative', ACTION: 'Review', RATIO: 74.5, UNIT: '%' }).score, 4.5);
    const metadata = item.describe();
    assert.equal(metadata.responses[0].choice.prompt, '利用学习过程中的证据调整教学，属于哪种评价？');
    assert.equal(metadata.responses[0].choice.required, false);
    assert.equal(metadata.responses[0].inline_choice, undefined);
    assert.equal(metadata.responses[1].inline_choice.choices.length, 3);
    metadata.responses[0].choice.choices.length = 0;
    assert.equal(item.describe().responses[0].choice.choices.length, 2);
    assert.equal(item.score({}).status, 'unanswered');
    assert.equal(item.score({ METHOD: 'Summative' }).score, 0);
    assert.deepEqual(answer, { METHOD: 'Formative', ACTION: 'Adapt', RATIO: 75, UNIT: '%' });
  } finally { item.dispose(); }
});

test('composite required choices reject invalid shapes and stay usable after row errors', () => {
  const item = compileItem(fixture('composite-choice-required'));
  try {
    const invalid = [{}, { METHOD: 'Formative' }, { METHOD: ['Formative'], ACTION: 'Adapt' },
      { METHOD: 'formative', ACTION: 'Adapt' }, { METHOD: 'Adapt', ACTION: 'Adapt' }];
    const rows = item.scoreBatch([...invalid, { METHOD: 'Formative', ACTION: 'Adapt' }]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [...invalid.map(() => 'invalid_response'), 2]);
    const description = item.describe();
    assert.equal(description.responses[0].choice.orientation, 'horizontal');
    assert.equal(description.responses[1].choice.required, true);
  } finally { item.dispose(); }
});

test('composite choice package reports and exports retain independent item handles', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-choice-package.zip', import.meta.url)));
  const item = bundle.getItem('mixed');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv, itemsCsv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-choice-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(row => row.ok ? row.result.score : null), [6, 2, 4.5, 1, 0, null, null, 0]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [8, 4.5, 1, 0, null, null, 0]);
    assert.equal(report.items[0].score_mean, 2.875);
    assert.ok(csv.includes('invalid_response'));
    assert.ok(itemsCsv.includes('"mixed",5,4,1'));
    bundle.dispose();
    assert.equal(item.score({ METHOD: 'Formative' }).score, 2);
  } finally { item.dispose(); bundle.dispose(); }
});

test('composite fallback preserves penalties, optional omissions and first-true execution', () => {
  const item = compileItem(fixture('composite-fallback'));
  try {
    const input = { ACTION: 'Ignore', RATIO: 80 };
    assert.deepEqual(item.score(input), { score: -1.5, status: 'answered', matches_correct: false });
    assert.deepEqual(input, { ACTION: 'Ignore', RATIO: 80 });
    const rows = item.scoreBatch([{ ACTION: 'Adapt', RATIO: 75 }, { ACTION: 'Adapt', RATIO: 80 }, {}, { RATIO: 'bad' }, input]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [4, 1.5, 0, 'invalid_response', -1.5]);
    const trace = item.explain(input);
    assert.equal(trace.result.score, -1.5);
    assert.equal(trace.steps.filter(s => s.operation === 'composite_add').length, 2);
    assert.equal(trace.steps.filter(s => s.details.condition?.operator === 'else').length, 2);
    assert.ok(trace.steps.filter(s => s.details.condition?.operator === 'else').every(s => s.details.selected && s.location.line > 0));
    const correct = item.explain({ ACTION: 'Adapt', RATIO: 75 });
    assert.ok(!correct.steps.some(s => s.details.condition?.operator === 'else'));
    assert.equal(evaluateItem(fixture('composite-fallback'), input).score, -1.5);
  } finally { item.dispose(); }
});

test('composite authored NULL credit stays unanswered while required controls still reject omissions', () => {
  const pattern = '</qti-is-null><qti-set-outcome-value identifier="SCORE"><qti-sum><qti-variable identifier="SCORE"/><qti-base-value base-type="float">0</qti-base-value>';
  const source = fixture('composite-fallback').replaceAll(pattern, pattern.replace('>0</qti-base-value>', '>0.25</qti-base-value>'));
  assert.deepEqual(evaluateItem(source, {}), { score: 0.5, status: 'unanswered', matches_correct: false });
  const required = compileItem(source.replace('response-identifier="ACTION">', 'response-identifier="ACTION" required="true">'));
  try {
    for (const response of [{}, { ACTION: null }, { ACTION: '' }, { RATIO: 75 }]) assert.throws(() => required.score(response), hasCode('invalid_response'));
    assert.equal(required.score({ ACTION: 'Adapt', RATIO: 75 }).score, 4);
    assert.ok(!JSON.stringify(required.describe()).includes('operator'));
    const duplicate = source.replace('</qti-response-else>', '</qti-response-else><qti-response-else/>');
    assert.throws(() => compileItem(duplicate), hasCode('invalid_item'));
  } finally { required.dispose(); }
});

test('composite fallback package exports preserve negative scores and independent item lifetimes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-fallback-package.zip', import.meta.url)));
  const item = bundle.getItem('diagnostic');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-fallback-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null), [4, 2, 1.5, 1, 0, null, null, -1.5]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [6, 1.5, 1, 0, null, null, -1.5]);
    assert.equal(report.error_count, 2);
    assert.ok(csv.includes('invalid_response') && csv.includes('-1.5'));
    bundle.dispose();
    assert.equal(item.score({ RATIO: 80 }).score, -0.5);
  } finally { item.dispose(); bundle.dispose(); }
});

test('mixed composite choices and numerical tiers share the existing score and explain APIs', () => {
  const item = compileItem(fixture('composite-inline'));
  try {
    assert.equal(item.score({ ACTION: 'Adapt', RATIO: 75 }).score, 4);
    assert.equal(item.score({ ACTION: 'Review', RATIO: 74.5 }).score, 1.5);
    assert.equal(item.explain({ ACTION: 'Review', RATIO: 74.5 }).result.score, 1.5);
    assert.deepEqual(item.score({}), { score: 0, status: 'unanswered', matches_correct: false });
    const trace = item.explain({ ACTION: 'Adapt' });
    assert.ok(trace.steps.some(s => s.operation === 'composite_add' && s.details.identifier === 'ACTION' && s.details.contribution === 2));
    assert.deepEqual(evaluateItem(fixture('composite-inline'), { RATIO: 75 }), item.score({ RATIO: 75 }));
  } finally { item.dispose(); }
});

test('composite inline metadata is isolated and keeps choice text out of the passage', () => {
  const item = compileItem(fixture('composite-inline'));
  try {
    const metadata = item.describe();
    const spec = metadata.responses[0].inline_choice;
    assert.equal(metadata.responses[0].base_type, 'identifier');
    assert.equal(spec.required, false);
    assert.equal(spec.label, '学习行动');
    assert.deepEqual(spec.choices.map(c => c.identifier), ['Adapt', 'Review', 'Ignore']);
    assert.ok(!JSON.stringify(metadata.passage).includes('调整策略并再次尝试'));
    spec.choices[0].identifier = 'changed'; spec.choices.length = 0; spec.required = true;
    assert.equal(item.describe().responses[0].inline_choice.choices[0].identifier, 'Adapt');
    assert.equal(item.score({ ACTION: 'Adapt' }).score, 2);
    assert.equal(item.score({}).score, 0);
  } finally { item.dispose(); }
});

test('composite required fields and foreign choices fail per attempt without aborting a batch', () => {
  const item = compileItem(fixture('composite-inline-required'));
  try {
    const rows = item.scoreBatch([{}, { METHOD: 'Formative' }, { METHOD: 'Formative', ACTION: 'Formative' },
      { METHOD: 'Formative', ACTION: 'Adapt' }, { METHOD: 'Summative', ACTION: 'Ignore' }]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), ['invalid_response', 'invalid_response', 'invalid_response', 2, 0]);
    for (const action of [null, '', ['Adapt'], 1, undefined]) {
      assert.throws(() => item.score({ METHOD: 'Formative', ACTION: action }), hasCode('invalid_response'));
    }
    const metadata = item.describe();
    assert.ok(metadata.responses.every(b => b.inline_choice.required));
    assert.throws(() => compileItem(fixture('composite-inline').replace('map-key="Review"', 'map-key="Missing"')), hasCode('invalid_item'));
  } finally { item.dispose(); }
});

test('mixed inline packages preserve row errors, CSV output and independent item lifetimes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-inline-package.zip', import.meta.url)));
  const item = bundle.getItem('mixed');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-inline-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null), [4, 2, 1.5, 2, null, null, 0, 0]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [6, 1.5, 2, null, null, 0, 0]);
    assert.equal(report.error_count, 2);
    assert.ok(csv.includes('invalid_response'));
    bundle.dispose();
    assert.equal(item.score({ ACTION: 'Review', RATIO: 75 }).score, 2.5);
  } finally { item.dispose(); bundle.dispose(); }
});

test('composite numeric tiers stop at the first match and expose interval diagnostics only on request', () => {
  const item = compileItem(fixture('composite-tolerance'));
  try {
    const input = { UNIT: 'cm', LENGTH: 100.5, GROUPS: 4 };
    assert.deepEqual(item.score(input), { score: 4, status: 'answered', matches_correct: false });
    assert.deepEqual(input, { UNIT: 'cm', LENGTH: 100.5, GROUPS: 4 });
    const rows = item.scoreBatch([{ LENGTH: 100 }, { LENGTH: 99 }, { LENGTH: 105 }, { LENGTH: 105.001 }, {}, { LENGTH: 'bad' }, { LENGTH: 100.5 }]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [3, 2, 1, 0, 0, 'invalid_response', 2]);
    const trace = item.explain(input);
    const conditions = trace.steps.filter(s => s.operation === 'composite_condition' && s.details.identifier === 'LENGTH');
    assert.deepEqual(conditions.map(s => [s.details.branch, s.details.selected]), [[0, false], [1, true]]);
    assert.equal(conditions[1].details.condition.lower, 99);
    assert.equal(conditions[1].details.condition.upper, 101);
    assert.ok(conditions.every(s => s.location.line > 0));
    assert.equal(trace.result.score, item.score(input).score);
    assert.equal(item.score({ UNIT: 'cm', LENGTH: 100, GROUPS: 4 }).score, 5);
    const metadata = JSON.stringify(item.describe());
    assert.ok(!metadata.includes('tolerance') && !metadata.includes('correct') && !metadata.includes('branches'));
  } finally { item.dispose(); }
});

test('composite tolerance authoring errors fail compilation without changing existing compiled instances', () => {
  const source = fixture('composite-tolerance');
  const item = compileItem(source);
  try {
    for (const tolerance of ['-1', 'NaN', '1 2 3']) {
      assert.throws(() => compileItem(source.replace('tolerance="1"', `tolerance="${tolerance}"`)), hasCode('invalid_item'));
    }
    const exactTolerance = compileItem(source.replace('tolerance="1"', 'tolerance="0"'));
    const crossResponse = compileItem(source.replaceAll('<qti-correct identifier="LENGTH"/>', '<qti-correct identifier="GROUPS"/>'));
    try {
      assert.equal(exactTolerance.score({ LENGTH: 100 }).score, 3);
      assert.equal(crossResponse.describe().template, 'typed_rules');
      assert.equal(crossResponse.score({ LENGTH: 100, GROUPS: 4 }).score, 1);
    } finally { exactTolerance.dispose(); crossResponse.dispose(); }
    assert.throws(() => compileItem(source.replaceAll('<qti-match>', '<qti-equal>').replaceAll('</qti-match>', '</qti-equal>')), hasCode('unsupported'));
    assert.equal(item.score({ LENGTH: 100 }).score, 3);
    assert.deepEqual(evaluateItem(source, { LENGTH: null }), item.score({}));
  } finally { item.dispose(); }
});

test('composite tolerance packages retain row errors, exports and independent item lifetimes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/composite-tolerance-package.zip', import.meta.url)));
  const item = bundle.getItem('measurement');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv } = bundle.scoreAttempts(readFileSync(new URL('../examples/composite-tolerance-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null), [5, 2, 4, 1, null, 0, 3]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [7, 4, 1, null, 0, 3]);
    assert.equal(report.error_count, 1);
    assert.ok(csv.includes('invalid_response'));
    bundle.dispose();
    assert.equal(item.score({ LENGTH: 100.5 }).score, 2);
  } finally { item.dispose(); bundle.dispose(); }
});

test('composite descriptions and multi-field responses preserve existing compiled-item methods', () => {
  const item = compileItem(fixture('composite'));
  try {
    const metadata = item.describe();
    assert.equal(metadata.kind,'composite');
    assert.deepEqual(metadata.responses.map(b=>b.identifier),['PLATFORM','COUNT']);
    assert.equal(metadata.response_identifier,undefined);
    assert.equal(metadata.passage.filter(p=>p.response).length,2);
    metadata.responses[0].identifier='Changed'; metadata.passage.length=0;
    assert.equal(item.describe().responses[0].identifier,'PLATFORM');
    const input={PLATFORM:'LMS',COUNT:4};
    assert.deepEqual(item.score(input),{score:4,status:'answered',matches_correct:true});
    assert.deepEqual(input,{PLATFORM:'LMS',COUNT:4});
    assert.equal(item.explain(input).result.score,4);
    assert.equal(item.score({COUNT:'04'}).score,2);
    assert.equal(item.score({}).status,'unanswered');
  } finally { item.dispose(); }
});

test('composite invalid fields and accessors cannot silently become missing responses', () => {
  const item = compileItem(fixture('composite'));
  try {
    const rows=item.scoreBatch([{PLATFORM:'lms',COUNT:4},{PLATFORM:'LMS',COUNT:4.5},{OTHER:4},{COUNT:4},{}]);
    assert.deepEqual(rows.map(r=>r.ok?r.result.score:r.error.code),[3,'invalid_response','invalid_response',2,0]);
    let accessed=false;
    assert.throws(()=>item.score({get PLATFORM(){accessed=true;return 'LMS';}}),hasCode('invalid_response'));
    assert.equal(accessed,false);
    for(const input of [{COUNT:undefined},{COUNT:Infinity},{COUNT:[4]},{COUNT:['4']},{PLATFORM:4}]) assert.throws(()=>item.score(input),hasCode('invalid_response'));
    assert.throws(()=>item.score(Object.fromEntries(Array.from({length:33},(_,i)=>[`X${i}`,null]))),hasCode('limit_exceeded'));
    assert.throws(()=>compileItem(fixture('composite').replace('identifier="COUNT" cardinality','identifier="PLATFORM" cardinality')),hasCode('invalid_item'));
  } finally {item.dispose();}
});

test('composite numeric mappings retain scalar numerical equality and row-local errors', () => {
  const item=compileItem(fixture('composite-numeric'));
  try {
    assert.equal(item.score({RATIO:0.75,TOTAL:20}).score,3);
    assert.equal(item.score({RATIO:'7e-1',TOTAL:'020'}).score,2);
    assert.equal(item.score({RATIO:0.7500000000000001}).score,0);
    assert.equal(item.score({TOTAL:20}).matches_correct,false);
    const explanation=item.explain({RATIO:0.7});
    assert.ok(explanation.steps.some(s=>s.operation==='composite_add'&&s.details.identifier==='RATIO'&&s.details.contribution===1));
  }finally{item.dispose();}
  assert.throws(()=>compileItem(fixture('composite').replace('base-type="integer"','base-type="float"')),hasCode('unsupported'));
});

test('composite package batches and independent item lifetimes work with unchanged SDK entry points',()=>{
  const bundle=importPackage(readFileSync(new URL('../web/composite-package.zip',import.meta.url)));
  const item=bundle.getItem('platform');
  try {
    assert.equal(bundle.describe().ready_count,2);
    const {report,csv}=bundle.scoreAttempts(readFileSync(new URL('../examples/composite-attempts.jsonl',import.meta.url),'utf8'));
    assert.deepEqual([report.row_count,report.scored_count,report.error_count],[6,5,1]);
    assert.deepEqual(report.rows.map(r=>r.ok?r.result.score:null),[4,3,3,1,null,0]);
    assert.deepEqual(report.attempts.map(a=>a.score_sum),[7,3,1,null,0]);
    assert.ok(csv.includes('invalid_response'));
    bundle.dispose();
    assert.equal(item.score({COUNT:4}).score,2);
  }finally{item.dispose();bundle.dispose();}
});

test('slider metadata and numerical mappings retain NULL and defensive-copy semantics', () => {
  const item = compileItem(fixture('slider'));
  try {
    const metadata = item.describe();
    assert.deepEqual(metadata.slider, {lower_bound:0,upper_bound:100,step:10,step_label:true,orientation:'horizontal',reverse:false});
    metadata.slider.lower_bound = 1000;
    assert.equal(item.describe().slider.lower_bound, 0);
    assert.equal(describeItem(fixture('numeric')).slider, undefined);
    assert.equal(item.score({}).status, 'unanswered');
    assert.equal(item.score({RESPONSE:0}).status, 'answered');
    assert.equal(item.score({RESPONSE:'0040'}).score, 2);
    const partial = item.explain({RESPONSE:30});
    assert.equal(partial.result.score, 1);
    assert.ok(partial.steps.some(s => s.operation === 'map_value' && s.details.value === 30));
    for (const value of [45,110,-10,40.5,'4e1',[],['40']]) assert.throws(() => item.score({RESPONSE:value}),hasCode('invalid_response'));
  } finally { item.dispose(); }
});

test('floating sliders support stepped and continuous numeric rules without changing typed responses', () => {
  const source = fixture('slider-float');
  const item = compileItem(source);
  const continuous = compileItem(source.replace(' step="0.05"',''));
  try {
    assert.equal(item.describe().slider.orientation, 'vertical');
    assert.equal(item.score({RESPONSE:0.75}).score, 2);
    assert.equal(item.score({RESPONSE:'7e-1'}).score, 1);
    assert.throws(() => item.score({RESPONSE:0.743}),hasCode('invalid_response'));
    assert.equal(continuous.describe().slider.step, null);
    assert.equal(continuous.score({RESPONSE:0.743}).score, 1);
    const rows = item.scoreBatch([{RESPONSE:0.75},{RESPONSE:0.74},{RESPONSE:0.8},{}]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code),[2,'invalid_response',1,0]);
  } finally { item.dispose(); continuous.dispose(); }
});

test('numeric map keys use value equality and reject alternate spellings of the same key', () => {
  const source = fixture('slider');
  assert.throws(() => compileItem(source.replace('map-key="30"','map-key="+0040"')),hasCode('invalid_item'));
  const floats = source.replace('base-type="integer"','base-type="float"');
  assert.throws(() => compileItem(floats.replace('map-key="30"','map-key="4e1"')),hasCode('invalid_item'));
  const bounded = compileItem(source.replace('lower-bound="0" upper-bound="2"','lower-bound="1" upper-bound="1.5"'));
  try {
    assert.equal(bounded.score({}).score, 0);
    assert.equal(bounded.score({RESPONSE:0}).score, 1);
    assert.equal(bounded.score({RESPONSE:40}).score, 1.5);
  } finally { bounded.dispose(); }
});

test('slider package batches share range validation and retain independent item lifetimes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/slider-package.zip', import.meta.url)));
  const item = bundle.getItem('share');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const {report,csv} = bundle.scoreAttempts(readFileSync(new URL('../examples/slider-attempts.jsonl',import.meta.url),'utf8'));
    assert.deepEqual([report.row_count,report.scored_count,report.error_count],[7,5,2]);
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null),[2,2,1,1,null,null,0]);
    assert.equal(report.rows[6].result.status,'unanswered');
    assert.ok(csv.includes('slider response does not lie on its step grid'));
    bundle.dispose();
    assert.equal(item.score({RESPONSE:40}).score,2);
  } finally { item.dispose(); bundle.dispose(); }
});

test('inline choice metadata preserves context and cannot alter compiled scoring', () => {
  const item = compileItem(fixture('inline-choice'));
  try {
    const metadata = item.describe();
    assert.equal(metadata.inline_choice.passage.map(p => p.text ?? `[${p.response}]`).join(''),
      '形成性评价在学习过程中收集证据，帮助教师[RESPONSE]，并为学习者提供及时反馈。\n');
    assert.equal(metadata.inline_choice.label, '评价目的');
    assert.equal(metadata.inline_choice.placeholder, '请选择评价目的');
    assert.equal(metadata.inline_choice.required, false);
    metadata.inline_choice.passage.length = 0;
    metadata.inline_choice.required = true; metadata.choices[0].identifier = 'Changed';
    assert.equal(item.describe().inline_choice.required, false);
    assert.equal(item.describe().inline_choice.passage.filter(p => p.response).length, 1);
    assert.equal(item.score({RESPONSE:'Improve'}).score, 1);
    assert.equal(item.score({}).status, 'unanswered');
    assert.equal(item.score({RESPONSE:''}).score, 0);
    assert.equal(describeItem(fixture('single')).inline_choice, undefined);
  } finally { item.dispose(); }
});

test('inline required selection and typed response validation use the shared core', () => {
  const xml = fixture('inline-choice-required');
  const item = compileItem(xml);
  try {
    assert.equal(item.score({RESPONSE:'Adapt'}).score, 2);
    assert.equal(item.explain({RESPONSE:'Review'}).result.score, 0.5);
    const rows = item.scoreBatch([{}, {RESPONSE:null}, {RESPONSE:''}, {RESPONSE:[]},
      {RESPONSE:['Adapt']}, {RESPONSE:1}, {RESPONSE:'adapt'}, {RESPONSE:'Unknown'}, {RESPONSE:'Ignore'}]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code),
      Array(8).fill('invalid_response').concat(0));
  } finally { item.dispose(); }
  assert.throws(() => compileItem(xml.replace('shuffle="false"', 'shuffle="true"')), hasCode('unsupported'));
  const minimum = compileItem(xml.replace('required="true"', 'min-choices="1"'));
  try { assert.throws(() => minimum.score({}), hasCode('invalid_response')); }
  finally { minimum.dispose(); }
});

test('inline package reports keep required omissions separate from optional unanswered zeroes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/inline-choice-package.zip', import.meta.url)));
  const item = bundle.getItem('purpose');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const {report,csv} = bundle.scoreAttempts(readFileSync(new URL('../examples/inline-choice-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual([report.scored_count, report.error_count], [4, 2]);
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : null), [1, 2, 0.5, null, 0, null]);
    assert.equal(report.rows[3].error.code, 'invalid_response');
    assert.equal(report.rows[4].result.status, 'unanswered');
    assert.ok(csv.includes('inline choice requires a selection'));
    bundle.dispose();
    assert.equal(item.score({RESPONSE:'Improve'}).score, 1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('hottext metadata retains passage positions and safe candidate instructions', () => {
  const item = compileItem(fixture('hottext'));
  try {
    const metadata = item.describe();
    assert.equal(metadata.hottext.passage.map(p => p.text ?? `[${p.choice}]`).join(''),
      '课堂上，教师[Evidence]，并依据证据[Support]。\n把[Ranking]作为唯一目标，不能替代过程反馈。\n');
    assert.equal(metadata.instructions.length, 1);
    metadata.instructions[0] = 'changed'; metadata.hottext.passage.length = 0; metadata.choices[0].identifier = 'changed';
    assert.equal(item.describe().hottext.passage.length, 10);
    assert.equal(item.describe().choices[0].identifier, 'Evidence');
    assert.notEqual(item.describe().instructions[0], 'changed');
    const input = ['Support', 'Evidence'];
    assert.equal(item.score({RESPONSE:input}).score, 2);
    assert.equal(item.explain({RESPONSE:input}).result.matches_correct, true);
    assert.deepEqual(input,['Support','Evidence']);
    const rows = item.scoreBatch([{RESPONSE:['Evidence']},{RESPONSE:['Evidence','Evidence']},{RESPONSE:['Unknown']},{}]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [1,'invalid_response','invalid_response',0]);
  } finally { item.dispose(); }
});

test('single hottext and instruction actor boundaries are enforced by the core', () => {
  const item = compileItem(fixture('hottext-single'));
  try {
    assert.equal(item.score({RESPONSE:'Feedback'}).score,1);
    assert.equal(item.score({RESPONSE:'Final'}).score,0);
    assert.equal(item.score({}).status,'unanswered');
    assert.throws(() => item.score({RESPONSE:['Feedback']}),hasCode('invalid_response'));
  } finally { item.dispose(); }
  assert.throws(() => compileItem(fixture('hottext-single').replace('view="candidate"','view="scorer"')),hasCode('unsupported'));
  const escaped = compileItem(fixture('hottext-single').replace('选择一个片段，','&lt;script&gt;&amp;<em>说明</em>'));
  try { assert.ok(escaped.describe().instructions[0].startsWith('<script>&说明')); }
  finally { escaped.dispose(); }
});

test('hottext package batch exports share the scorer and independent item lifetime', () => {
  const bundle = importPackage(readFileSync(new URL('../web/hottext-package.zip', import.meta.url)));
  const item = bundle.getItem('evidence');
  try {
    assert.equal(bundle.describe().ready_count,2);
    const {report,csv} = bundle.scoreAttempts(readFileSync(new URL('../examples/hottext-attempts.jsonl',import.meta.url),'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : r.error.code),[2,1,1,'invalid_response',0]);
    assert.deepEqual(report.attempts.map(a => a.score_sum),[3,1,null,0]);
    assert.ok(csv.includes('false,,,,"invalid_response"'));
    bundle.dispose();
    assert.equal(item.score({RESPONSE:['Evidence']}).score,1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('gap matching preserves contextual passage and validates words and required gaps', () => {
  const item = compileItem(fixture('gap'));
  try {
    const metadata = item.describe();
    assert.equal(metadata.matching, undefined);
    const { passage, sets } = metadata.gap_matching;
    assert.deepEqual(sets.map(s => s.length), [3, 3]);
    assert.equal(passage.map(p => p.text ?? `[${p.gap}]`).join(''), '形成性评价先收集[G1]，再依据证据[G2]教学。\n下一轮学习继续收集[G3]。\n');
    const rows = item.scoreBatch([
      {RESPONSE:['Feedback G1','Adjust G2','Feedback G3']}, {RESPONSE:['Feedback G1','Rank G2']},
      {RESPONSE:['Feedback G1','Feedback G2','Feedback G3']}, {RESPONSE:['Adjust G2']},
      {RESPONSE:['Feedback G1','Rank G1']}, {},
    ]);
    assert.deepEqual(rows.map(r => r.ok ? r.result.score : r.error.code), [3,0.5,'invalid_response','invalid_response','invalid_response',0]);
    passage.length = 0; sets[0][0].identifier = 'changed';
    assert.equal(item.describe().gap_matching.passage.length, 10);
    assert.equal(item.describe().gap_matching.sets[0][0].identifier, 'Feedback');
    assert.equal(item.explain({RESPONSE:['Feedback G1']}).result.score, 1);
  } finally { item.dispose(); }
});

test('single gap uses string pairs and leaves whitespace content safe as metadata text', () => {
  const source = fixture('gap-single').replace('评价的主要目的是', '&lt;script&gt;&amp;<strong>正文</strong>');
  const item = compileItem(source);
  try {
    const plain = item.describe().gap_matching.passage.map(p => p.text ?? `[${p.gap}]`).join('');
    assert.equal(plain, '<script>&正文[Goal]。\n');
    assert.equal(item.score({RESPONSE:'Improve Goal'}).score, 1);
    assert.equal(item.score({RESPONSE:''}).status, 'unanswered');
    assert.throws(() => item.score({RESPONSE:['Improve Goal']}),hasCode('invalid_response'));
  } finally { item.dispose(); }
});

test('gap packages and batch exports share the scorer and independent item lifetime', () => {
  const bundle = importPackage(readFileSync(new URL('../web/gap-package.zip', import.meta.url)));
  const item = bundle.getItem('cycle');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv } = bundle.scoreAttempts(readFileSync(new URL('../examples/gap-attempts.jsonl', import.meta.url),'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : r.error.code), [3,1,0.5,'invalid_response',0]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [4,0.5,null,0]);
    assert.ok(csv.includes('false,,,,"invalid_response"'));
    bundle.dispose();
    assert.equal(item.score({RESPONSE:['Feedback G1']}).score, 1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('matching supports many-to-one partial credit and preserves pair direction', () => {
  const item = compileItem(fixture('match'));
  try {
    const pairs = ['Observation Diagnose', 'Portfolio Growth', 'Quiz Diagnose'];
    assert.equal(item.score({ RESPONSE: pairs }).score, 3);
    assert.equal(item.score({ RESPONSE: pairs }).matches_correct, true);
    const report = item.scoreBatch([
      { RESPONSE: ['Quiz Diagnose', 'Portfolio Diagnose'] }, { RESPONSE: ['Diagnose Quiz'] },
      { RESPONSE: ['Quiz Diagnose', 'Quiz Growth'] }, { RESPONSE: ['Quiz Diagnose', ' Quiz\tDiagnose '] }, {},
    ]);
    assert.deepEqual(report.map(r => r.ok ? r.result.score : r.error.code), [0.5, 'invalid_response', 'invalid_response', 'invalid_response', 0]);
    const explanation = item.explain({ RESPONSE: [' Quiz\tDiagnose '] });
    assert.equal(explanation.result.score, 1);
    assert.equal(explanation.steps.find(s => s.operation === 'map_value').details.value, 'Quiz Diagnose');
    assert.deepEqual(pairs, ['Observation Diagnose', 'Portfolio Growth', 'Quiz Diagnose']);
    const metadata = item.describe();
    assert.equal(metadata.base_type, 'directedPair');
    assert.deepEqual(metadata.matching.sets.map(s => s.length), [3, 2]);
    metadata.matching.sets[0][0].identifier = 'changed';
    metadata.matching.sets[1].length = 0;
    assert.equal(item.describe().matching.sets[0][0].identifier, 'Quiz');
    assert.equal(item.describe().matching.sets[1].length, 2);
    assert.equal('correct_response' in metadata, false);
  } finally { item.dispose(); }
});

test('single directed pairs require a string and default to one association', () => {
  const item = compileItem(fixture('match-single'));
  try {
    assert.equal(item.describe().matching.max_associations, 1);
    assert.equal(item.score({ RESPONSE: 'Portfolio Growth' }).score, 1);
    assert.equal(item.score({ RESPONSE: 'Quiz Growth' }).score, 0);
    assert.equal(item.score({ RESPONSE: '' }).status, 'unanswered');
    assert.throws(() => item.score({ RESPONSE: ['Portfolio Growth'] }), hasCode('invalid_response'));
  } finally { item.dispose(); }
});

test('matching content packages retain row failures and standalone item lifetimes', () => {
  const bundle = importPackage(readFileSync(new URL('../web/match-package.zip', import.meta.url)));
  const item = bundle.getItem('methods');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    const { report, csv } = bundle.scoreAttempts(readFileSync(new URL('../examples/match-attempts.jsonl', import.meta.url), 'utf8'));
    assert.deepEqual(report.rows.map(r => r.ok ? r.result.score : r.error.code), [3, 0.5, 'invalid_response', 0]);
    assert.deepEqual(report.attempts.map(a => a.score_sum), [3, 0.5, null, 0]);
    assert.ok(csv.includes('false,,,,"invalid_response"'));
    bundle.dispose();
    assert.equal(item.score({ RESPONSE: ['Quiz Diagnose'] }).score, 1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('ordered arrays compare positions and retain the caller sequence', () => {
  const item = compileItem(fixture('order'));
  const values = ['Analyze', 'Design', 'Develop', 'Implement', 'Evaluate'];
  try {
    assert.equal(item.describe().cardinality, 'ordered');
    assert.equal(item.describe().min_choices, 5);
    assert.equal(item.describe().max_choices, 5);
    assert.equal(item.score({ RESPONSE: values }).score, 1);
    assert.deepEqual(item.score({ RESPONSE: values }), evaluateItem(fixture('order'), { RESPONSE: values }));
    const reversed = [...values].reverse();
    const explanation = item.explain({ RESPONSE: reversed });
    assert.equal(explanation.result.score, 0);
    assert.equal(explanation.result.matches_correct, false);
    assert.equal(explanation.steps.at(-1).details.comparison, 'ordered');
    assert.deepEqual(values, ['Analyze', 'Design', 'Develop', 'Implement', 'Evaluate']);
    assert.deepEqual(reversed, ['Evaluate', 'Implement', 'Develop', 'Design', 'Analyze']);
    assert.equal(item.scoreBatch([{ RESPONSE: values }, { RESPONSE: reversed }, {}])[2].result.status, 'unanswered');
    const metadata = item.describe();
    metadata.choices.reverse();
    assert.equal(item.describe().choices[0].identifier, 'Develop');
  } finally { item.dispose(); }
});

test('ordered subsets reject repeated/unknown choices and distinguish NULL from invalid containers', () => {
  const item = compileItem(fixture('order-subset'));
  try {
    assert.equal(item.score({ RESPONSE: ['Locate', 'Adapt'] }).score, 1);
    assert.equal(item.score({ RESPONSE: ['Adapt', 'Locate'] }).score, 0);
    assert.equal(item.score({ RESPONSE: ['Locate', 'Adapt', 'Rank'] }).score, 0);
    for (const value of [[], null]) assert.equal(item.score({ RESPONSE: value }).status, 'unanswered');
    for (const value of [['Locate'], ['Locate', 'Locate'], ['Locate', 'missing'],
      ['Locate', 'Adapt', 'Rank', 'Skip'], ['Locate', ''], 'Locate', '', 1]) {
      assert.throws(() => item.score({ RESPONSE: value }), hasCode('invalid_response'));
    }
  } finally { item.dispose(); }
});

test('ordered package items and batch reports use the same positional scorer', () => {
  const bundle = importPackage(readFileSync(new URL('../web/order-package.zip', import.meta.url)));
  const item = bundle.getItem('priorities');
  try {
    assert.equal(bundle.describe().ready_count, 2);
    assert.ok(bundle.describe().items.every(entry => entry.status === 'ready' && entry.item.cardinality === 'ordered'));
    const source = readFileSync(new URL('../examples/order-attempts.jsonl', import.meta.url), 'utf8');
    const { report, csv } = bundle.scoreAttempts(source);
    assert.equal(report.scored_count, 3);
    assert.equal(report.error_count, 1);
    assert.deepEqual(report.rows.map(row => row.result?.score ?? null), [1, 1, 0, null]);
    assert.deepEqual(report.attempts.map(attempt => attempt.score_sum), [2, 0]);
    assert.ok(csv.includes('false,,,,"invalid_response"'));
    bundle.dispose();
    assert.equal(item.score({ RESPONSE: ['Locate', 'Adapt'] }).score, 1);
  } finally { item.dispose(); bundle.dispose(); }
});

test('item analytics expose observed scores and match counts through the MoonBit bridge', () => {
  const bundle = importPackage(packageBytes());
  try {
    const { report, itemsCsv } = bundle.scoreAttempts(packageAttempts());
    assert.deepEqual(report.items.map(s => s.resource_id), ['choice', 'measurement', 'essay']);
    assert.deepEqual(report.items.map(s => [s.row_count, s.scored_count, s.score_mean, s.score_min, s.score_max]),
      [[2, 2, 0.5, 0, 1], [3, 2, 0.75, 0.5, 1], [1, 0, null, null, null]]);
    for (const s of report.items) assert.equal(s.matched_count + s.unmatched_count + s.unclassified_count, s.scored_count);
    assert.equal(itemsCsv.split('\r\n').length, 5);
    assert.ok(itemsCsv.includes('"essay",1,0,1,0,0,0,0,0,,,\r\n'));
    report.items.length = 0;
    assert.equal(bundle.scoreAttempts(packageAttempts()).report.items.length, 3);
  } finally { bundle.dispose(); }
});

test('item analytics keep unassignable resource errors and empty means explicit', () => {
  const bundle = importPackage(packageBytes());
  try {
    const { report } = bundle.scoreAttempts('bad-json\n' + JSON.stringify({ attempt_id: 'a', resource_id: '=missing', response: {} }));
    assert.equal(report.unassigned_resource_count, 1);
    assert.equal(report.items[0].resource_id, '=missing');
    assert.equal(report.items[0].score_mean, null);
    assert.ok(bundle.scoreAttempts(JSON.stringify({ attempt_id: 'a', resource_id: '=missing', response: {} })).itemsCsv.includes('"\'=missing"'));
    assert.deepEqual(bundle.scoreAttempts('').report.items, []);
  } finally { bundle.dispose(); }
});

test('package batch groups attempts and retains errors without assigning zero scores', () => {
  const bundle = importPackage(packageBytes());
  try {
    const { report, csv } = bundle.scoreAttempts(packageAttempts());
    assert.equal(report.row_count, 6);
    assert.equal(report.scored_count, 4);
    assert.equal(report.error_count, 2);
    assert.equal(report.answered_count, 3);
    assert.equal(report.unanswered_count, 1);
    assert.equal(report.has_errors, true);
    assert.deepEqual(report.attempts.map(summary => summary.score_sum), [2, 0, 0.5]);
    assert.deepEqual(report.attempts.map(summary => summary.all_rows_scored), [true, false, false]);
    assert.equal(report.rows[3].result, null);
    assert.equal(report.rows[3].item_id, 'measurement');
    assert.equal(report.rows[3].error.code, 'invalid_response');
    assert.equal(report.rows[4].error.code, 'unsupported');
    assert.equal(report.rows[4].error.location.line, 7);
    assert.ok(csv.includes('false,,,,"invalid_response"'));
    assert.ok(csv.endsWith('\r\n'));
    assert.equal(Object.hasOwn(report.rows[0], 'response'), false);
    assert.equal(Object.hasOwn(report.rows[0], 'steps'), false);
  } finally { bundle.dispose(); }
});

test('batch identity conflicts, malformed JSON and nonfinite responses stay row-local', () => {
  const bundle = importPackage(packageBytes());
  try {
    const line = (attempt_id, resource_id, response) => JSON.stringify({ attempt_id, resource_id, response });
    const { report } = bundle.scoreAttempts('\uFEFF\r\n' + [
      line('a', 'choice', { RESPONSE: 'A' }), line('a', 'choice', {}), '{oops}',
      '{"attempt_id":"b","resource_id":"measurement","response":{"RESPONSE":1e309}}',
      line('c', 'choice', { RESPONSE: 'B' }),
    ].join('\r\n'));
    assert.deepEqual(report.rows.map(row => row.line), [2, 3, 4, 5, 6]);
    assert.deepEqual(report.rows.map(row => row.ok), [false, false, false, false, true]);
    assert.ok(report.rows[0].error.message.includes('duplicate'));
    assert.ok(report.rows[1].error.message.includes('duplicate'));
    assert.equal(report.unassigned_count, 1);
    assert.equal(report.attempts[0].score_sum, null);
    assert.equal(report.rows[4].result.score, 0);
  } finally { bundle.dispose(); }
});

test('batch reports are fresh and CSV preserves quoted text with formula prefixes', () => {
  const bundle = importPackage(packageBytes());
  try {
    const source = ['学生,"A"', '=1+2', '+1', '@name', '-name', '＝1'].map(attempt_id =>
      JSON.stringify({ attempt_id, resource_id: 'choice', response: {} })).join('\n');
    const first = bundle.scoreAttempts(source);
    assert.ok(first.csv.includes('"学生,""A"""'));
    assert.ok(first.csv.includes('"\'=1+2"'));
    assert.equal(first.report.rows[1].attempt_id, '=1+2');
    first.report.rows[0].result.score = 99;
    first.report.attempts.length = 0;
    const second = bundle.scoreAttempts(source);
    assert.equal(second.report.rows[0].result.score, 0);
    assert.equal(second.report.attempts.length, 6);
    assert.equal(first.csv, second.csv);
    assert.equal(bundle.scoreAttempts('').report.row_count, 0);
  } finally { bundle.dispose(); }
});

test('batch input budgets and disposal are enforced without persistent result handles', () => {
  const bundle = importPackage(packageBytes());
  try {
    assert.throws(() => bundle.scoreAttempts([]), hasCode('invalid_response'));
    assert.throws(() => bundle.scoreAttempts(' '.repeat(4194305)), hasCode('limit_exceeded'));
    assert.throws(() => bundle.scoreAttempts('{}\n'.repeat(4097)), hasCode('limit_exceeded'));
    for (let i = 0; i < 6; i++) assert.equal(bundle.scoreAttempts(packageAttempts()).report.scored_count, 4);
  } finally { bundle.dispose(); }
  assert.throws(() => bundle.scoreAttempts(''), hasCode('disposed'));
});

test('ZIP import retains per-item diagnostics and scores supported resources', () => {
  const bundle = importPackage(packageBytes());
  const items = [];
  try {
    const report = bundle.describe();
    assert.equal(report.identifier, 'education-bank');
    assert.equal(report.file_count, 5);
    assert.equal(report.ready_count, 2);
    assert.deepEqual(report.items.map(entry => entry.status), ['ready', 'ready', 'unsupported']);
    assert.equal(report.items[2].error.code, 'unsupported');
    assert.ok(report.items[2].error.location.line > 0);
    assert.deepEqual(bundle.resourceFiles('choice'), ['items/single.xml', 'assets/note.txt']);
    for (const [id, response, expected] of [['choice', 'A', 1], ['measurement', 100.5, 1]]) {
      const item = bundle.getItem(id);
      items.push(item);
      assert.equal(item.score({ RESPONSE: response }).score, expected);
      assert.deepEqual(item.explain({ RESPONSE: response }).result, item.score({ RESPONSE: response }));
    }
    assert.throws(() => bundle.getItem('essay'), hasCode('unsupported'));
    assert.throws(() => bundle.getItem('formative'), hasCode('invalid_package'));
    assert.throws(() => bundle.resourceFiles('missing'), hasCode('invalid_package'));
    assert.throws(() => bundle.readFile('../escape'), hasCode('invalid_package'));
    assert.throws(() => bundle.readFile('missing'), hasCode('invalid_package'));
    assert.throws(() => bundle.getItem(null), hasCode('invalid_package'));
  } finally { items.forEach(item => item.dispose()); bundle.dispose(); }
});

test('ZIP inputs, resource bytes and nested reports cannot change an imported package', () => {
  const bytes = packageBytes();
  const bundle = importPackage(bytes);
  bytes.fill(0);
  try {
    const report = bundle.describe();
    report.resources[0].files.length = 0;
    report.items[0].item.choices.length = 0;
    bundle.resourceFiles('choice').length = 0;
    const note = bundle.readFile('assets/note.txt');
    assert.deepEqual(note, new Uint8Array(readFileSync(new URL('../examples/package-note.txt', import.meta.url))));
    note.fill(0);
    assert.equal(bundle.describe().resources[0].files.length, 1);
    assert.equal(bundle.describe().items[0].item.choices.length, 3);
    assert.equal(bundle.resourceFiles('choice').length, 2);
    assert.notEqual(bundle.readFile('assets/note.txt')[0], 0);
  } finally { bundle.dispose(); }
});

test('opened package items survive parent disposal and package handles are not reused', () => {
  const bundle = importPackage(packageBytes());
  const item = bundle.getItem('choice');
  bundle.dispose(); bundle.dispose();
  try {
    assert.equal(bundle.disposed, true);
    assert.equal(item.score({ RESPONSE: 'A' }).score, 1);
    for (const operation of [() => bundle.describe(), () => bundle.getItem('choice'),
      () => bundle.resourceFiles('choice'), () => bundle.readFile('imsmanifest.xml')]) {
      assert.throws(operation, hasCode('disposed'));
    }
  } finally { item.dispose(); }
  const old = JSON.parse(core.import_package(packageBytes()));
  assert.equal(core.release_package(old.handle), true);
  assert.equal(core.release_package(old.handle), false);
  const fresh = JSON.parse(core.import_package(packageBytes()));
  try {
    assert.notEqual(old.handle, fresh.handle);
    assert.equal(JSON.parse(core.describe_package(old.handle)).error.code, 'invalid_handle');
  } finally { core.release_package(fresh.handle); }
});

test('package budgets and failed imports do not leak package handles', () => {
  for (const value of [null, 'zip', new ArrayBuffer(0)]) {
    assert.throws(() => importPackage(value), hasCode('invalid_package'));
  }
  assert.throws(() => importPackage(new Uint8Array(8 * 1048576 + 1)), hasCode('limit_exceeded'));
  for (let i = 0; i < 6; i++) assert.throws(() => importPackage(new Uint8Array([1, 2, 3])), hasCode('invalid_package'));
  const bundles = [];
  try {
    for (let i = 0; i < 4; i++) bundles.push(importPackage(packageBytes()));
    assert.throws(() => importPackage(packageBytes()), hasCode('limit_exceeded'));
    bundles.pop().dispose();
    bundles.push(importPackage(packageBytes()));
  } finally { bundles.forEach(bundle => bundle.dispose()); }
});

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
      const path = join(source, file);
      copyFileSync(existsSync(path) ? path : join(source, '..', file), join(installed, file));
    }
    const script = `import {readFileSync} from 'node:fs';
      import {compileItem,importPackage} from '@project2026-creator/qti-score';
      const input=JSON.parse(readFileSync(0,'utf8'));
      const item=compileItem(input.xml);
      const bundle=importPackage(Buffer.from(input.zip,'base64'));
      try { console.log(JSON.stringify({score:item.score({RESPONSE:100.5}).score,ready:bundle.describe().ready_count,
        scored:bundle.scoreAttempts(input.attempts).report.scored_count})); }
      finally { item.dispose(); bundle.dispose(); }`;
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script],
      { input: JSON.stringify({ xml: fixture('numeric'), zip: packageBytes().toString('base64'), attempts: packageAttempts() }), encoding: 'utf8', cwd: folder });
    assert.equal(child.status, 0, child.stderr);
    assert.equal(JSON.parse(child.stdout).score, 1);
    assert.equal(JSON.parse(child.stdout).ready, 2);
    assert.equal(JSON.parse(child.stdout).scored, 4);
  } finally {
    assert.ok(resolve(folder).startsWith(resolve(tmpdir()) + sep + 'qti-sdk-'));
    rmSync(folder, { recursive: true, force: true });
  }
});
