const $ = id => document.getElementById(id);
const source = $('xml-source');
let engine;
let compiledItem;
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
  if (item.base_type !== 'identifier') return { RESPONSE: $('text-answer')?.value || '' };
  const values = [...$('answer-controls').querySelectorAll('input:checked')].map(input => input.value);
  return { RESPONSE: item.cardinality === 'single' ? values[0] ?? null : values };
}

function updateResponse() {
  $('response-json').textContent = JSON.stringify(response());
}

function resetResult() {
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
      case 'match_correct': text = `${detail.matched ? '完全匹配' : '未完全匹配'}，得 ${detail.score} 分。`; break;
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
      case 'set_score': text = `设置得分为 ${detail.score}。`; break;
      default: text = step.operation;
    }
    const row = document.createElement('li');
    row.textContent = `${text}（XML ${step.location.line}:${step.location.column}）`;
    list.append(row);
  }
  $('score-trace').textContent = JSON.stringify(steps, null, 2);
}

function renderQuestion() {
  $('item-id').textContent = `ITEM / ${item.identifier}`;
  $('question-title').textContent = item.title;
  $('question-prompt').textContent = item.prompt;
  $('template-name').textContent = item.template;
  const fieldset = $('answer-controls');
  fieldset.replaceChildren();
  const legend = document.createElement('legend');
  legend.className = 'sr-only';
  legend.textContent = item.base_type !== 'identifier' ? '填写答案' : '选择答案';
  fieldset.append(legend);
  if (item.base_type !== 'identifier') {
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

async function loadPackage(readBytes, name) {
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
  let value;
  try {
    if ($('enable-trace').checked) {
      const explanation = compiledItem.explain(response());
      value = explanation.result;
      renderExplanation(explanation.steps);
      $('trace-panel').open = true;
    } else {
      value = compiledItem.score(response());
      $('trace-summary').replaceChildren();
      $('score-trace').textContent = '本次评分未记录解释。';
    }
  } catch (error) {
    resetResult();
    showError('score-error', error);
    return;
  }
  $('score-value').textContent = String(value.score);
  $('result-message').textContent = value.status === 'unanswered' ? '当前没有作答，已按题目声明的规则评分。' : '已按题目声明的规则完成评分。';
  $('match-message').textContent = value.status === 'unanswered' ? '' : value.matches_correct === null ? '题目未提供标准响应。' : value.matches_correct ? '与标准响应完全匹配。' : '未与标准响应完全匹配；评分规则仍可给予部分分数。';
});
$('answer-controls').addEventListener('input', () => { updateResponse(); resetResult(); });
$('clear-answer').addEventListener('click', () => { $('answer-form').reset(); updateResponse(); resetResult(); });
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
$('sample-package').addEventListener('click', () => loadPackage(async () => {
  const result = await fetch('./sample-package.zip');
  if (!result.ok) throw new Error('示例题包载入失败，请重新运行构建命令。');
  return new Uint8Array(await result.arrayBuffer());
}, 'sample-package.zip'));

try {
  engine = await import('../sdk/index.mjs');
  await loadExample('single');
} catch (error) {
  $('source-status').textContent = '内核未载入';
  showError('fatal-error', { code: 'engine_unavailable', message: '请先执行 python tools/project.py serve 以构建并启动工作台。' });
}
