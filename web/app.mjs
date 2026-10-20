const $ = id => document.getElementById(id);
const source = $('xml-source');
let engine;
let compiledItem;
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

async function loadExample(name) {
  const request = ++loading;
  $('submit-score').disabled = true;
  try {
    const result = await fetch(`../examples/${name}.xml`);
    if (!result.ok) throw new Error('示例文件载入失败');
    const xml = await result.text();
    if (request !== loading) return;
    source.value = xml;
    $('filename').textContent = `${name}.xml`;
    for (const button of document.querySelectorAll('[data-example]')) {
      button.setAttribute('aria-pressed', String(button.dataset.example === name));
    }
    compile();
  } catch (error) {
    if (request === loading) showError('compile-error', { code: 'load_error', message: error.message });
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
$('compile').addEventListener('click', compile);
source.addEventListener('input', () => {
  ++loading;
  compiledItem?.dispose();
  compiledItem = null;
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
  const xml = await file.text();
  if (request !== loading) return;
  source.value = xml;
  $('filename').textContent = file.name;
  for (const button of document.querySelectorAll('[data-example]')) button.setAttribute('aria-pressed', 'false');
  compile();
});

try {
  engine = await import('../sdk/index.mjs');
  await loadExample('single');
} catch (error) {
  $('source-status').textContent = '内核未载入';
  showError('fatal-error', { code: 'engine_unavailable', message: '请先执行 python tools/project.py serve 以构建并启动工作台。' });
}
