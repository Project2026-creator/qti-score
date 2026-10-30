import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const { compileItem, importPackage, QtiScoreError } = await import(process.env.QTI_SDK_URL || new URL('./index.mjs',import.meta.url).href);
const xml = readFileSync(new URL('../examples/dynamic-feedback.xml',import.meta.url),'utf8');
const archive = () => readFileSync(new URL('../web/dynamic-test-package.zip',import.meta.url));
const script = JSON.parse(readFileSync(new URL('../examples/dynamic-actions.json',import.meta.url),'utf8'));

test('present evaluates an explicit submission and returns only visible rendered content',()=>{
  const item=compileItem(xml);
  try {
    const before=JSON.stringify(item.describe());
    assert.doesNotMatch(before,/回答正确|关键步骤/);
    const result=item.present({RESPONSE:'Adjust'});
    assert.equal(result.outcomes.SCORE,2);
    assert.match(JSON.stringify(result.item),/得到 2.0 分/);
    assert.match(JSON.stringify(result.item),/收集证据 → 调整教学/);
    assert.match(result.feedback[0].text,/得分 2.0/);
    assert.doesNotMatch(JSON.stringify(result),/qti-content:|请重新思考/);
    result.item.responses[0].choice.choices[0].text='changed';
    result.feedback[0].text='changed';
    assert.match(JSON.stringify(item.present({RESPONSE:'Rank'}).item),/请重新思考/);
    assert.equal(JSON.stringify(item.describe()),before);
  } finally {item.dispose();}
  assert.throws(()=>item.present({}),error=>error instanceof QtiScoreError&&error.code==='disposed');
});

test('simultaneous drafts do not update printed outcomes and frozen history survives restore',()=>{
  const bundle=importPackage(archive()), plan=bundle.getTest('dynamic-test'), session=plan.startSession('printed-history');
  let restored;
  try {
    session.act(script.actions[0]);
    assert.deepEqual(session.describe().test_feedback.during,[]);
    assert.doesNotMatch(JSON.stringify(session.describe().current.item),/回答正确/);
    session.act(script.actions[1]); session.act(script.actions[2]);
    const history=session.describe().test_feedback.completed_parts;
    assert.match(history[0].feedback[0].text,/2.0/);
    session.act(script.actions[3]);
    assert.doesNotMatch(JSON.stringify(session.describe().current.item),/回答正确/);
    restored=plan.restoreSession(session.snapshot());
    assert.deepEqual(restored.describe(),session.describe());
    restored.act(script.actions[4]);
    const completed=restored.describe(), result=restored.exportResult(script.datestamp);
    assert.match(JSON.stringify(completed.current.item),/得到 2.0 分/);
    assert.equal(result.report.outcomes.SCORE,4);
    assert.deepEqual(completed.test_feedback.completed_parts[0],history[0]);
    assert.match(completed.test_feedback.at_end[0].text,/4.0 \/ 4.0/);
    assert.doesNotMatch(result.xml,/qti-printed-variable|qti-feedback-inline|回答正确/);
  } finally {restored?.dispose();session.dispose();plan.dispose();bundle.dispose();}
});

test('package item handles retain the present API after their package is disposed',()=>{
  const bundle=importPackage(archive());
  const item=bundle.getItem('dynamic'); bundle.dispose();
  try { assert.equal(item.present({RESPONSE:'Rank'}).outcomes.SCORE,0); }
  finally {item.dispose();}
});
