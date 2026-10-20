const $ = id => document.getElementById(id);
const source = $('xml-source');
let engine;
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
  if (item.base_type === 'string') return { RESPONSE: $('text-answer')?.value || '' };
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
  showError('score-error', null);
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
  legend.textContent = item.base_type === 'string' ? '填写答案' : '选择答案';
  fieldset.append(legend);
  if (item.base_type === 'string') {
    const label = document.createElement('label');
    label.className = 'text-label';
    label.htmlFor = 'text-answer';
    label.textContent = '你的答案';
    const input = document.createElement('input');
    input.type = 'text';
    input.id = 'text-answer';
    input.className = 'text-answer';
    input.autocomplete = 'off';
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
  const result = JSON.parse(engine.describe(source.value));
  if (!result.ok) {
    item = null;
    activeXml = '';
    $('submit-score').disabled = true;
    $('answer-controls').disabled = true;
    $('source-status').textContent = '题目尚未编译成功';
    resetResult();
    showError('compile-error', result.error);
    return;
  }
  item = result.item;
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
  const result = JSON.parse(engine.evaluate(activeXml, JSON.stringify(response())));
  if (!result.ok) {
    resetResult();
    showError('score-error', result.error);
    return;
  }
  const value = result.result;
  $('score-value').textContent = String(value.score);
  $('result-message').textContent = value.status === 'unanswered' ? '当前没有作答，按模板记为 0 分。' : '已按题目声明的模板完成评分。';
  $('match-message').textContent = value.status === 'unanswered' ? '' : value.matches_correct === null ? '题目未提供标准响应。' : value.matches_correct ? '与标准响应完全匹配。' : '未与标准响应完全匹配；映射模板仍可给予部分分数。';
});
$('answer-controls').addEventListener('input', () => { updateResponse(); resetResult(); });
$('clear-answer').addEventListener('click', () => { $('answer-form').reset(); updateResponse(); resetResult(); });
$('compile').addEventListener('click', compile);
source.addEventListener('input', () => {
  ++loading;
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
  engine = await import('./qti-score.mjs');
  await loadExample('single');
} catch (error) {
  $('source-status').textContent = '内核未载入';
  showError('fatal-error', { code: 'engine_unavailable', message: '请先执行 python tools/project.py serve 以构建并启动工作台。' });
}
