/** Cross-implementation checks against a pinned, independent QTI 3 release.
 * Install separately: npm install --prefix _build/interop --no-save --package-lock=false @longsightgroup/qti3-core@0.13.3
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { createServer } from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { compileItem } from '../sdk/index.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const external = path.join(root, '_build/interop/node_modules/@longsightgroup/qti3-core');
const version = JSON.parse(readFileSync(path.join(external, 'package.json'), 'utf8')).version;
assert.equal(version, '0.13.3', 'Independent implementation version must be pinned');
const { parseQtiXml, createItemSession, visibleModalFeedback } = await import(pathToFileURL(path.join(external, 'dist/index.js')));
const sources = [
  ['single', [{RESPONSE:'A'},{RESPONSE:'B'},{}]],
  ['multiple', [{RESPONSE:['A','C']},{RESPONSE:['A']},{}]],
  ['match', [{RESPONSE:['Quiz Diagnose','Portfolio Growth']},{RESPONSE:['Observation Diagnose']},{}]],
  ['associate', [{RESPONSE:['Memory Cognitivism']},{RESPONSE:['Cognitivism Memory']},{RESPONSE:['Behaviorism Cognitivism']},{}]],
  ['inline-choice', [{RESPONSE:'Formative'},{}]],
  ['hottext', [{RESPONSE:['Evidence','Support']},{}]],
  ['numeric', [{RESPONSE:100},{RESPONSE:100.5},{RESPONSE:110},{}]],
  ['dynamic-feedback', [{RESPONSE:'Adjust'},{RESPONSE:'Rank'},{}]],
];
const checks = [];
const differences = [];
for (const [name, responses] of sources) {
  const file = `examples/${name}.xml`, xml = readFileSync(path.join(root,file),'utf8');
  const parsed = parseQtiXml(xml);
  if (!parsed.ok && name === 'inline-choice' && parsed.diagnostics.every(d => d.code === 'interaction.child.unsupported' && d.message.includes('qti-label'))) {
    const own = compileItem(xml); own.dispose();
    differences.push({source:file,sha256:createHash('sha256').update(xml).digest('hex'),
      direction:'QTI Score content -> independent implementation',
      reason:'Pinned independent parser rejects qti-label in inline-choice; this source is checked separately against the official ASI XSD.',diagnostics:parsed.diagnostics});
    continue;
  }
  assert.equal(parsed.ok, true, `${file}: independent parsing failed ${JSON.stringify(parsed.diagnostics)}`);
  assert(parsed.document);
  const own = compileItem(xml);
  try {
    for (const response of responses) {
      const before = structuredClone(response), session = createItemSession(parsed.document);
      for (const [id,value] of Object.entries(response)) {
        assert(!session.respond(id,value).some(d=>d.severity==='error'), `${file}: response rejected`);
      }
      const result = session.score();
      assert(!result.diagnostics.some(d=>d.severity==='error'), `${file}: independent scoring errors ${JSON.stringify(result.diagnostics)}`);
      const observed = own.present(response), expected = Object.fromEntries(Object.keys(observed.outcomes).map(key=>[key,result.outcomes[key]]));
      assert.deepEqual(observed.outcomes, expected, `${file}: authored outcomes differ`);
      const feedback = visibleModalFeedback(parsed.document.item,result.outcomes).map(m=>m.identifier).sort();
      assert.deepEqual(observed.feedback.map(m=>m.identifier).sort(),feedback,`${file}: modal selection differs`);
      assert.deepEqual(response,before,`${file}: input mutation`);
      checks.push({source:file,sha256:createHash('sha256').update(xml).digest('hex'),response,matched_outcomes:expected,matched_modal_feedback:feedback,diagnostics:result.diagnostics});
    }
  } finally { own.dispose(); }
}
const report = {ok:true,independent_implementation:{name:'@longsightgroup/qti3-core',version,repository:'https://github.com/LongsightGroup/qti3',license:'MIT'},
  scope:'Original QTI 3 item XML, response processing, declared outcomes and modal-feedback selection across two independent implementations; not a full LMS or test-result import certification.',
  checks_passed:checks.length,known_differences:differences,checks};
const index=process.argv.indexOf('--output'), output=index>=0?path.resolve(process.argv[index+1]):path.join(root,'_build/independent-validation.json');
if (process.argv.includes('--browser')) {
  const { chromium } = await import(pathToFileURL(path.join(root,'_build/interop/node_modules/playwright-core/index.mjs')));
  const playerRoot=path.join(root,'_build/interop/node_modules/@longsightgroup/qti3-player/dist');
  const coreRoot=path.join(external,'dist');
  const fixture=readFileSync(path.join(root,'examples/dynamic-feedback.xml'),'utf8');
  const server=createServer((request,response)=>{
    try {
      const url=new URL(request.url,'http://127.0.0.1');
      if(url.pathname==='/') {
        response.setHeader('Content-Type','text/html;charset=utf-8');
        response.end('<!doctype html><meta charset="utf-8"><title>Independent QTI 3 item player</title><script type="importmap">{"imports":{"@longsightgroup/qti3-core":"/core/index.js"}}</script><body><h1>Independent QTI 3 item player</h1><qti-assessment-item-player id="player"></qti-assessment-item-player><script type="module">import {defineQtiAssessmentItemPlayer} from "/player/index.js";defineQtiAssessmentItemPlayer();await document.querySelector("#player").loadXml(await(await fetch("/item.xml")).text(),{feedbackRelease:"released",sessionControl:{showFeedback:true,requireScoredResponses:false}});window.ready=true;</script>');
      } else if(url.pathname==='/item.xml') {
        response.setHeader('Content-Type','application/xml;charset=utf-8');response.end(fixture);
      } else {
        const prefix=url.pathname.startsWith('/core/')?'/core/':url.pathname.startsWith('/player/')?'/player/':null;
        if(!prefix) {response.writeHead(404).end();return;}
        const directory=prefix==='/core/'?coreRoot:playerRoot;
        const resolved=path.resolve(directory,decodeURIComponent(url.pathname.slice(prefix.length)));
        if(!resolved.startsWith(directory+path.sep)||!resolved.endsWith('.js')) {response.writeHead(404).end();return;}
        response.setHeader('Content-Type','text/javascript;charset=utf-8');response.end(readFileSync(resolved));
      }
    } catch {response.writeHead(404).end();}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({channel:'chrome',headless:true,args:['--no-proxy-server']});
    const page=await browser.newPage({viewport:{width:1100,height:950}}), errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(()=>window.ready===true);
    assert.doesNotMatch(await page.locator('body').innerText(),/回答正确|关键步骤/);
    await page.getByRole('radio',{name:/依据学习证据调整教学/}).check();
    const result=await page.evaluate(()=>document.querySelector('#player').scoreAttempt());
    assert.equal(result.outcomes.SCORE,2);
    const displayed=await page.locator('body').innerText();
    assert.match(displayed,/得到 2\.0 分/);assert.match(displayed,/收集证据, 调整教学/);
    differences.push({source:'examples/dynamic-feedback.xml',direction:'QTI Score content -> independent player',
      reason:'Pinned independent player renders an ordered printed variable with comma-space instead of the authored delimiter.',
      expected:'收集证据 → 调整教学',observed:'收集证据, 调整教学'});
    assert.doesNotMatch(displayed,/请重新思考/);
    const state=await page.evaluate(()=>{
      const player=document.querySelector('#player'), snapshot=player.serialize();
      player.reset();player.restore(snapshot);return player.serialize();
    });
    const own=compileItem(fixture);
    try {assert.equal(own.present(state.responses).outcomes.SCORE,result.outcomes.SCORE);}
    finally {own.dispose();}
    assert.deepEqual(errors,[]);
    mkdirSync(path.dirname(output),{recursive:true});
    await page.screenshot({path:path.join(path.dirname(output),'independent-player.png'),fullPage:true});
    report.browser={ok:true,implementation:'@longsightgroup/qti3-player',version:'0.13.3',browser:await browser.version(),
      checks:['Original QTI Score XML loads without modification','Initial feedback omitted','Candidate selects and independent player scores 2','Scalar printed values and nested visibility agree; delimiter difference recorded','Independent player restores its state','Restored independent response is accepted by MoonBit with the same score'],page_errors:errors};
  } finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
}
mkdirSync(path.dirname(output),{recursive:true});writeFileSync(output,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({ok:true,implementation:report.independent_implementation,checks_passed:checks.length,known_differences:differences.length,browser:report.browser}));
