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
