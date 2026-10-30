import { createBatchPanel } from './batch.mjs';
import { createWorkspace } from './workspace.mjs';
import { createOrderControl } from './order.mjs';
import { createMatchControl } from './match.mjs';
import { createAssociationControl } from './associate.mjs';
import { createGapControl } from './gap.mjs';
import { createHottextControl } from './hottext.mjs';
import { createInlineChoiceControl } from './inline-choice.mjs';
import { createSliderControl } from './slider.mjs';
import { createCompositeControl } from './composite.mjs';

const $ = id => document.getElementById(id);
const workspace = createWorkspace();
const batchPanel = createBatchPanel();
const source = $('xml-source');
const engineControls = [...document.querySelectorAll('[data-example], #compile, #open-file, #import-xml, #open-package, #sample-package')];
for (const control of engineControls) control.disabled = true;
source.disabled = true;
let engine;
let compiledItem;
let orderControl;
let matchControl;
let gapControl;
let hottextControl;
let inlineChoiceControl;
let sliderControl;
let compositeControl;
let contentPackage;
let item;
let activeXml = '';
let loading = 0;

function showError(id, error) {
  const target = $(id);
  target.hidden = !error;
  target.textContent = error ? `${error.code || 'error'} · ${error.message || String(error)}` : '';
}

function response() {
  if (!item) return { RESPONSE: null };
  if (item.kind === 'composite') return compositeControl?.response() || {};
  if (item.slider) return sliderControl?.response() || { RESPONSE: null };
  if (item.inline_choice) return inlineChoiceControl?.response() || { RESPONSE: null };
  if (item.gap_matching) return gapControl?.response() || { RESPONSE: null };
  if (item.association) return { [item.response_identifier]: matchControl?.read() ?? null };
  if (item.base_type === 'directedPair') return matchControl?.response() || { RESPONSE: null };
  if (item.cardinality === 'ordered') return orderControl?.response() || { RESPONSE: null };
  if (item.base_type !== 'identifier') return { RESPONSE: $('text-answer')?.value || '' };
  const values = [...$('answer-controls').querySelectorAll('input:checked')].map(input => input.value);
  return { RESPONSE: item.cardinality === 'single' ? values[0] ?? null : values };
}

function updateResponse() {
  $('response-json').textContent = JSON.stringify(response());
}

function resetResult() {
  $('item-feedback').replaceChildren();
  $('item-feedback').hidden = true;
  $('score-value').textContent = '—';
  $('result-message').textContent = '提交作答后，在这里查看结果。';
  $('match-message').textContent = '';
  $('score-trace').textContent = '勾选记录评分过程后，重新提交作答。';
  $('trace-summary').replaceChildren();
  showError('score-error', null);
}

function renderExplanation(steps) {
  const labels = { exact: '精确比较', absolute: '绝对误差', relative: '相对误差' };
  const list = $('trace-summary');
  list.replaceChildren();
  for (const step of steps) {
    const detail = step.details;
    let text;
    switch (step.operation) {
      case 'response': text = detail.status === 'unanswered' ? '未作答，进入空响应处理。' : `接收 ${detail.count} 个响应值。`; break;
      case 'null_response': text = '空响应按标准模板得 0 分，跳过映射上下界。'; break;
      case 'match_correct': text = `${detail.comparison === 'ordered' ? '按位置比较顺序：' : ''}${detail.matched ? '完全匹配' : '未完全匹配'}，得 ${detail.score} 分。`; break;
      case 'duplicate_ignored': text = `重复值 ${detail.value} 不重复计分。`; break;
      case 'map_value': text = `${detail.value}：${detail.used_default ? '使用默认映射' : `命中第 ${detail.entry_index + 1} 项映射`}，贡献 ${detail.contribution} 分。`; break;
      case 'mapping_bounds': text = `映射合计 ${detail.raw_score} 分，${detail.adjusted ? '按上下界调整为' : '最终为'} ${detail.score} 分。`; break;
      case 'numeric_condition': {
        const condition = detail.condition;
        const name = labels[condition.mode] || (condition.operator === 'is_null' ? '空响应检查' : '默认分支');
        const range = condition.lower === undefined ? '' : `，区间 ${condition.include_lower ? '[' : '('}${condition.lower}, ${condition.upper}${condition.include_upper ? ']' : ')'}`;
        text = `第 ${detail.branch + 1} 条规则：${name}${range}，${detail.selected ? '命中' : '未命中'}。`;
        break;
      }
      case 'composite_condition': {
        const condition = detail.condition;
        const branch = detail.branch === undefined ? '' : `第 ${detail.branch + 1} 档，`;
        const comparison = condition?.reason === 'null_operand' ? '空响应，' : condition ? `${labels[condition.mode] || (condition.operator === 'is_null' ? '未作答检查' : condition.operator === 'else' ? '默认分支' : '数值比较')}，` : '';
        const range = condition?.lower === undefined ? '' : `区间 ${condition.include_lower ? '[' : '('}${condition.lower}, ${condition.upper}${condition.include_upper ? ']' : ')'}，`;
        text = `${detail.identifier}：${branch}${comparison}${range}${detail.selected ? '命中并计分' : '未命中'}。`;
        break;
      }
      case 'composite_add': text = `${detail.identifier} 贡献 ${detail.contribution}，累计 ${detail.score}。`; break;
      case 'set_score': text = `设置得分为 ${detail.score}。`; break;
      default: text = step.operation;
    }
    const row = document.createElement('li');
    row.textContent = `${text}（XML ${step.location.line}:${step.location.column}）`;
    list.append(row);
  }
  $('score-trace').textContent = JSON.stringify(steps, null, 2);
}

function renderQuestion(initialResponses = {}) {
  workspace.setItem(item);
  $('item-id').textContent = `ITEM / ${item.identifier}`;
  $('question-title').textContent = item.title;
  $('question-prompt').textContent = item.prompt;
  $('question-prompt').hidden = item.kind === 'composite';
  const instructions = $('item-instructions');
  instructions.replaceChildren(...(item.instructions || []).map(text => {
    const paragraph = document.createElement('p'); paragraph.textContent = text; return paragraph;
  }));
  instructions.hidden = !item.instructions?.length;
  $('template-name').textContent = item.template;
  const fieldset = $('answer-controls');
  orderControl = null;
  matchControl = null;
  gapControl = null;
  hottextControl = null;
  inlineChoiceControl = null;
  sliderControl = null;
  compositeControl = null;
  fieldset.replaceChildren();
  const legend = document.createElement('legend');
  legend.className = 'sr-only';
  legend.textContent = item.kind === 'composite' ? '填写多个答案' : item.slider ? '选择数值' : item.inline_choice ? '文中下拉选词' : item.hottext ? '选择原文片段' : item.gap_matching ? '在文段中选词' : (item.base_type === 'directedPair' || item.association) ? '添加配对' : item.cardinality === 'ordered' ? '排列答案' : item.base_type !== 'identifier' ? '填写答案' : '选择答案';
  fieldset.append(legend);
  if (item.kind === 'composite') {
    compositeControl = createCompositeControl(fieldset, item, () => { updateResponse(); resetResult(); }, initialResponses);
  } else if (item.slider) {
    sliderControl = createSliderControl(fieldset, item, () => { updateResponse(); resetResult(); });
  } else if (item.inline_choice) {
    inlineChoiceControl = createInlineChoiceControl(fieldset, item);
  } else if (item.hottext) {
    hottextControl = createHottextControl(fieldset, item);
  } else if (item.gap_matching) {
    gapControl = createGapControl(fieldset, item, () => { updateResponse(); resetResult(); });
  } else if (item.association) {
    matchControl = createAssociationControl(fieldset, item, null, () => { updateResponse(); resetResult(); });
  } else if (item.base_type === 'directedPair') {
    matchControl = createMatchControl(fieldset, item, () => { updateResponse(); resetResult(); });
  } else if (item.cardinality === 'ordered') {
    orderControl = createOrderControl(fieldset, item, () => { updateResponse(); resetResult(); });
  } else if (item.base_type !== 'identifier') {
    const label = document.createElement('label');
    label.className = 'text-label';
    label.htmlFor = 'text-answer';
    label.textContent = '你的答案';
    const input = document.createElement('input');
    input.type = 'text';
    input.id = 'text-answer';
    input.className = 'text-answer';
    input.autocomplete = 'off';
    if (item.base_type === 'integer' || item.base_type === 'float') input.inputMode = 'decimal';
    input.maxLength = 65536;
    fieldset.append(label, input);
  } else {
    for (const choice of item.choices) {
      const label = document.createElement('label');
      label.className = 'answer-option';
      const input = document.createElement('input');
      input.type = item.cardinality === 'single' ? 'radio' : 'checkbox';
      input.name = 'RESPONSE';
      input.value = choice.identifier;
      const identifier = document.createElement('span');
      identifier.className = 'option-id';
      identifier.textContent = choice.identifier;
      const text = document.createElement('span');
      text.textContent = choice.text;
      label.append(input, identifier, text);
      fieldset.append(label);
    }
  }
  resetResult();
  updateResponse();
}

function compile() {
  if (!engine) return;
  showError('compile-error', null);
  try {
    const next = engine.compileItem(source.value);
    compiledItem?.dispose();
    compiledItem = next;
    item = compiledItem.describe();
  } catch (error) {
    compiledItem?.dispose();
    compiledItem = null;
    item = null;
    activeXml = '';
    $('submit-score').disabled = true;
    $('answer-controls').disabled = true;
    $('source-status').textContent = '题目尚未编译成功';
    resetResult();
    showError('compile-error', error);
    return;
  }
  activeXml = source.value;
  $('source-status').textContent = '已编译 · 可提交作答';
  $('submit-score').disabled = false;
  $('answer-controls').disabled = false;
  renderQuestion();
}

function clearPackage() {
  contentPackage?.dispose();
  contentPackage = null;
  batchPanel.setPackage(null);
  $('package-report').hidden = true;
  $('package-items').replaceChildren();
  $('resource-list').replaceChildren();
  $('package-selection').textContent = '';
  $('package-status').textContent = '支持本地题包，最大 8 MiB。文件仅在当前浏览器中读取。';
  showError('package-error', null);
}

function restoreScoring() {
  const ready = !!compiledItem && source.value === activeXml;
  $('submit-score').disabled = !ready;
  $('answer-controls').disabled = !ready;
}

function selectPackageItem(entry) {
  if (!contentPackage || entry.status !== 'ready') return;
  ++loading;
  let next;
  try {
    next = contentPackage.getItem(entry.resource_id);
    const xml = new TextDecoder('utf-8', { fatal: true }).decode(contentPackage.readFile(entry.path));
    const files = contentPackage.resourceFiles(entry.resource_id);
    compiledItem?.dispose();
    compiledItem = next;
    item = next.describe();
    source.value = xml;
    activeXml = xml;
    $('filename').textContent = entry.path;
    $('source-status').textContent = '题包中的已编译题目 · 可提交作答';
    $('package-selection').textContent = `当前资源 ${entry.resource_id} · 含依赖共 ${files.length} 个文件：${files.join('、')}`;
    for (const button of $('package-items').querySelectorAll('button')) {
      button.setAttribute('aria-pressed', String(button.dataset.resource === entry.resource_id));
    }
    for (const button of document.querySelectorAll('[data-example]')) button.setAttribute('aria-pressed', 'false');
    showError('compile-error', null);
    renderQuestion();
    restoreScoring();
  } catch (error) {
    if (next && next !== compiledItem) next.dispose();
    showError('package-error', error);
  }
}

function renderPackage(report, name) {
  $('package-status').textContent = `${name} · ${report.identifier} · ${report.ready_count} / ${report.items.length} 道可评分 · ${report.file_count} 个文件`;
  $('package-report').hidden = false;
  $('package-selection').textContent = '';
  const list = $('package-items');
  list.replaceChildren();
  for (const entry of report.items) {
    const row = document.createElement('div');
    row.className = 'package-item';
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.resource = entry.resource_id;
    button.setAttribute('aria-pressed', 'false');
    button.disabled = entry.status !== 'ready';
    const status = document.createElement('span');
    status.className = `package-badge ${entry.status}`;
    status.textContent = { ready: '可评分', unsupported: '暂不支持', invalid: '无效' }[entry.status];
    const label = document.createElement('strong');
    label.textContent = entry.item?.title || entry.resource_id;
    const path = document.createElement('small');
    path.textContent = entry.path || '未指定入口文件';
    button.append(status, label, path);
    button.addEventListener('click', () => selectPackageItem(entry));
    row.append(button);
    if (entry.error) {
      const reason = document.createElement('p');
      reason.className = 'package-diagnostic';
      reason.textContent = `${entry.error.code} · ${entry.error.message}`;
      row.append(reason);
    }
    list.append(row);
  }
  if (!report.items.length) list.textContent = '清单中没有 QTI 3 单题资源。';
  const resources = $('resource-list');
  resources.replaceChildren();
  for (const resource of report.resources) {
    const row = document.createElement('li');
    row.textContent = `${resource.identifier} · ${resource.type} · ${resource.resolved_file_count} 个文件（含依赖）` +
      (resource.dependencies.length ? ` · 依赖 ${resource.dependencies.join('、')}` : '') +
      (resource.issues.length ? ` · ${resource.issues.map(issue => issue.message).join('；')}` : '');
    resources.append(row);
  }
  const first = report.items.find(entry => entry.status === 'ready');
  if (first) selectPackageItem(first);
}

async function loadPackage(readBytes, name, sampleSource = null) {
  if (!engine) return;
  const request = ++loading;
  $('submit-score').disabled = true;
  $('answer-controls').disabled = true;
  showError('package-error', null);
  try {
    const bytes = await readBytes();
    if (request !== loading) return;
    const next = engine.importPackage(bytes);
    let report;
    try { report = next.describe(); }
    catch (error) { next.dispose(); throw error; }
    contentPackage?.dispose();
    contentPackage = next;
    batchPanel.setPackage(next, report.identifier, sampleSource);
    compiledItem?.dispose();
    compiledItem = null;
    item = null;
    activeXml = '';
    source.value = '';
    $('filename').textContent = '尚未选取题目';
    $('source-status').textContent = '请在题包列表中选择可评分题目';
    $('item-id').textContent = 'ITEM';
    $('question-title').textContent = '尚未选取可评分题目';
    $('question-prompt').textContent = '';
    $('template-name').textContent = '—';
    $('answer-controls').replaceChildren();
    for (const button of document.querySelectorAll('[data-example]')) button.setAttribute('aria-pressed', 'false');
    resetResult();
    updateResponse();
    showError('compile-error', null);
    renderPackage(report, name);
  } catch (error) {
    if (request === loading) showError('package-error', error);
  } finally {
    if (request === loading) restoreScoring();
  }
}

async function loadExample(name) {
  if (!engine) return;
  const request = ++loading;
  $('submit-score').disabled = true;
  try {
    const result = await fetch(`../examples/${name}.xml`);
    if (!result.ok) throw new Error('示例文件载入失败');
    const xml = await result.text();
    if (request !== loading) return;
    clearPackage();
    source.value = xml;
    $('filename').textContent = `${name}.xml`;
    for (const button of document.querySelectorAll('[data-example]')) {
      button.setAttribute('aria-pressed', String(button.dataset.example === name));
    }
    compile();
  } catch (error) {
    if (request === loading) showError('compile-error', { code: 'load_error', message: error.message });
  } finally {
    if (request === loading) restoreScoring();
  }
}

$('answer-form').addEventListener('submit', event => {
  event.preventDefault();
  if (!item || source.value !== activeXml) return;
  showError('score-error', null);
  $('item-feedback').replaceChildren();
  $('item-feedback').hidden = true;
  let value;
  let explanationSteps = null;
  const submittedResponse = response();
  try {
    if ($('enable-trace').checked) {
      const explanation = compiledItem.explain(submittedResponse);
      value = explanation.result;
      explanationSteps = explanation.steps;
    } else {
      value = compiledItem.score(submittedResponse);
    }
    if (item.has_feedback || item.dynamic_content) {
      const presentation = compiledItem.present(submittedResponse);
      if (item.dynamic_content) {
        item = presentation.item;
        renderQuestion(submittedResponse);
      }
      const region = $('item-feedback');
      region.hidden = !presentation.feedback.length;
      for (const message of presentation.feedback) {
        const card = document.createElement('section');
        const title = document.createElement('h4'); title.textContent = message.title || '本次反馈';
        const text = document.createElement('p'); text.textContent = message.text;
        card.append(title, text); region.append(card);
      }
    }
    if (explanationSteps !== null) {
      renderExplanation(explanationSteps); $('trace-panel').open = true;
    } else {
      $('trace-summary').replaceChildren(); $('score-trace').textContent = '本次评分未记录解释。';
    }
  } catch (error) {
    resetResult();
    showError('score-error', error);
    return;
  }
  $('score-value').textContent = String(value.score);
  $('result-message').textContent = value.status === 'unanswered' ? '当前没有作答，已按题目声明的规则评分。' : '已按题目声明的规则完成评分。';
  let matchMessage = '';
  if (value.status !== 'unanswered') {
    if (value.matches_correct === null) matchMessage = '题目未提供标准响应。';
    else if (value.matches_correct) matchMessage = '与标准响应完全匹配。';
    else if (value.score < 0) matchMessage = '未与标准响应完全匹配，已按题目规则扣分。';
    else if (item.template === 'match_correct') matchMessage = '未与标准响应完全匹配；本题按完全匹配评分。';
    else matchMessage = '未与标准响应完全匹配；评分规则仍可给予部分分数。';
  }
  $('match-message').textContent = matchMessage;
  workspace.record(item, submittedResponse, value);
});
$('answer-controls').addEventListener('input', () => { updateResponse(); resetResult(); });
$('clear-answer').addEventListener('click', () => { $('answer-form').reset(); orderControl?.reset(); matchControl?.reset(); gapControl?.reset(); hottextControl?.reset(); inlineChoiceControl?.reset(); sliderControl?.reset(); compositeControl?.reset(); updateResponse(); resetResult(); });
$('compile').addEventListener('click', () => { ++loading; compile(); });
source.addEventListener('input', () => {
  ++loading;
  compiledItem?.dispose();
  compiledItem = null;
  for (const button of $('package-items').querySelectorAll('button')) button.setAttribute('aria-pressed', 'false');
  $('package-selection').textContent = '';
  $('source-status').textContent = '源文件已修改，请重新编译';
  $('submit-score').disabled = true;
  $('answer-controls').disabled = true;
  resetResult();
});
for (const button of document.querySelectorAll('[data-example]')) {
  button.addEventListener('click', () => loadExample(button.dataset.example));
}
$('open-file').addEventListener('click', () => $('file-input').click());
$('import-xml').addEventListener('click', () => $('file-input').click());
$('file-input').addEventListener('change', async event => {
  const file = event.target.files?.[0];
  if (!file) return;
  const request = ++loading;
  if (file.size > 4 * 1048576) {
    showError('compile-error', { code: 'limit_exceeded', message: 'XML 文件过大，请选择小于 4 MiB 的文件。' });
    return;
  }
  try {
    const xml = await file.text();
    if (request !== loading) return;
    clearPackage();
    source.value = xml;
    $('filename').textContent = file.name;
    for (const button of document.querySelectorAll('[data-example]')) button.setAttribute('aria-pressed', 'false');
    compile();
  } catch (error) { if (request === loading) showError('compile-error', error); }
  event.target.value = '';
});
$('open-package').addEventListener('click', () => $('package-input').click());
$('package-input').addEventListener('change', event => {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  loadPackage(async () => {
    if (file.size > 8 * 1048576) throw { code: 'limit_exceeded', message: 'ZIP 文件超过 8 MiB 上限。' };
    return new Uint8Array(await file.arrayBuffer());
  }, file.name);
});
$('sample-package').addEventListener('click', () => {
  const key = $('sample-package-kind').value;
  const name = `${key}-package.zip`;
  loadPackage(async () => {
    const result = await fetch(`./${name}`);
    if (!result.ok) throw new Error('示例题包载入失败，请重新运行构建命令。');
    return new Uint8Array(await result.arrayBuffer());
  }, name, key === 'sample' ? 'package-attempts.jsonl' : `${key}-attempts.jsonl`);
});

try {
  engine = await import('../sdk/index.mjs?v=0.19.0');
  await loadExample('single');
} catch (error) {
  $('source-status').textContent = '内核未载入';
  showError('fatal-error', { code: 'engine_unavailable', message: '请先执行 python tools/project.py serve 以构建并启动工作台。' });
} finally {
  for (const control of engineControls) control.disabled = !engine;
  source.disabled = !engine;
}
