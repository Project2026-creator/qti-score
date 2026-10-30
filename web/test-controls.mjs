/** Candidate inputs only. Response interpretation and scoring stay in MoonBit. */
const element = (tag, text, className) => {
  const result = document.createElement(tag);
  if (text !== undefined) result.textContent = text;
  if (className) result.className = className;
  return result;
};
const action = (text, callback) => {
  const button = element('button', text); button.type = 'button';
  button.addEventListener('click', callback); return button;
};
function picker(labelText, choices, placeholder = '请选择') {
  const label = element('label', undefined, 'native-picker');
  label.append(element('span', labelText));
  const select = element('select'); select.setAttribute('aria-label', labelText);
  const empty = element('option', placeholder); empty.value = ''; select.append(empty);
  for (const choice of choices) {
    const option = element('option', choice.text); option.value = choice.identifier; select.append(option);
  }
  label.append(select); return { label, select };
}
function pairsOf(value) {
  return (Array.isArray(value) ? value : typeof value === 'string' && value ? [value] : [])
    .map(pair => pair.split(' '));
}

function matchControl(parent, binding, current, changed) {
  const spec = binding.matching, [sources, targets] = spec.sets;
  let pairs = pairsOf(current);
  const pickers = element('div', undefined, 'native-match-picker');
  const source = picker('关联来源', sources), target = picker('关联目标', targets);
  pickers.append(source.label, target.label);
  const list = element('ul', undefined, 'native-match-list'); list.setAttribute('aria-label', '已添加的关联');
  const feedback = element('p', '', 'native-help'); feedback.setAttribute('role', 'status');
  const single = binding.cardinality === 'single';
  const add = action(single ? '采用此关联' : '添加关联', () => {
    if (!source.select.value || !target.select.value) return;
    const pair = [source.select.value, target.select.value];
    const candidate = single ? [pair] : [...pairs, pair];
    if (!single && pairs.some(existing => existing[0] === pair[0] && existing[1] === pair[1])) {
      feedback.textContent = '此关联已添加。'; return;
    }
    if (spec.max_associations && candidate.length > spec.max_associations) {
      feedback.textContent = `最多可添加 ${spec.max_associations} 组关联。`; return;
    }
    for (const [set, index] of [[sources, 0], [targets, 1]]) {
      const choice = set.find(entry => entry.identifier === pair[index]);
      if (choice?.match_max && candidate.filter(entry => entry[index] === choice.identifier).length > choice.match_max) {
        feedback.textContent = `${choice.text} 最多可使用 ${choice.match_max} 次。`; return;
      }
    }
    pairs = candidate; render(); changed(); source.select.focus();
  });
  function render() {
    list.replaceChildren(...pairs.map(([from, to], index) => {
      const label = `${sources.find(choice => choice.identifier === from)?.text || from} → ${targets.find(choice => choice.identifier === to)?.text || to}`;
      const row = element('li'); const remove = action('移除', () => { pairs.splice(index, 1); render(); changed(); source.select.focus(); });
      remove.setAttribute('aria-label', `移除关联：${label}`); row.append(element('span', label), remove); return row;
    }));
    feedback.textContent = pairs.length ? `已添加 ${pairs.length} 组关联。` : '尚未添加关联。';
    add.disabled = !source.select.value || !target.select.value;
  }
  for (const select of [source.select, target.select]) select.addEventListener('change', () => { add.disabled = !source.select.value || !target.select.value; });
  parent.append(element('p', single ? '选择来源与目标，采用一组关联。' : '将来源与目标逐次配对；关联次数按题目要求检查。', 'native-help'), pickers, add, list, feedback);
  render();
  return {
    read: () => single ? (pairs[0]?.join(' ') ?? null) : pairs.map(pair => pair.join(' ')),
    reset() { pairs = []; source.select.value = target.select.value = ''; render(); },
  };
}

function gapControl(parent, binding, current, changed) {
  const spec = binding.gap_matching, [choices, gaps] = spec.sets;
  const initial = new Map(pairsOf(current).map(([source, target]) => [target, source]));
  const selects = new Map();
  const passage = element('div', undefined, 'native-gap-passage'); passage.setAttribute('aria-label', '填空文段');
  const preview = element('p', '', 'native-gap-preview'); preview.setAttribute('aria-label', '填入后的文段');
  const status = element('p', '', 'native-help'); status.setAttribute('role', 'status');
  function update() {
    for (const select of selects.values()) for (const option of select.options) {
      const choice = choices.find(value => value.identifier === option.value);
      const elsewhere = [...selects.values()].filter(other => other !== select && other.value === option.value).length;
      option.disabled = !!choice?.match_max && elsewhere >= choice.match_max;
    }
    preview.textContent = spec.passage.map(part => 'text' in part ? part.text : choices.find(choice => choice.identifier === selects.get(part.gap)?.value)?.text || '〔未填写〕').join('');
    status.textContent = `已填写 ${[...selects.values()].filter(select => select.value).length} / ${gaps.length} 空。`;
  }
  for (const part of spec.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const index = gaps.findIndex(gap => gap.identifier === part.gap);
    const gap = gaps[index], label = gap.text === gap.identifier ? `第 ${index + 1} 空` : gap.text;
    const control = picker(label, choices, `〔${label}〕`);
    control.label.classList.add('native-gap-field'); control.select.value = initial.get(part.gap) || '';
    if (gap.match_min) control.select.setAttribute('aria-description', '非空作答需填写此空');
    control.select.addEventListener('change', () => { update(); changed(); });
    selects.set(part.gap, control.select); passage.append(control.label);
  }
  parent.append(element('p', `可选词：${choices.map(choice => `${choice.text}（${choice.match_max === 0 ? '可重复使用' : `最多 ${choice.match_max} 次`}）`).join('、')}。`, 'native-help'), passage, element('p', '填入后的文段', 'native-help'), preview, status);
  update();
  return {
    read() { const pairs = [...selects].filter(([, select]) => select.value).map(([target, select]) => `${select.value} ${target}`); return binding.cardinality === 'single' ? pairs[0] ?? null : pairs; },
    reset() { for (const select of selects.values()) select.value = ''; update(); },
  };
}

function hottextControl(parent, binding, current, changed) {
  const choices = new Map((binding.choices || binding.choice?.choices || []).map(choice => [choice.identifier, choice]));
  const inputs = [], multiple = binding.cardinality === 'multiple';
  const passage = element('div', undefined, 'native-hottext-passage'); passage.setAttribute('aria-label', '文段中的可选片段');
  for (const part of binding.hottext.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const choice = choices.get(part.choice), label = element('label', undefined, 'native-hottext-choice');
    const input = element('input'); input.type = multiple ? 'checkbox' : 'radio'; input.name = `hottext-${binding.identifier}`; input.value = choice.identifier;
    input.checked = multiple ? Array.isArray(current) && current.includes(choice.identifier) : current === choice.identifier;
    input.addEventListener('change', () => { update(); changed(); });
    inputs.push(input); label.append(input, document.createTextNode(choice.text)); passage.append(label);
  }
  const status = element('p', '', 'native-help'); status.setAttribute('role', 'status');
  const update = () => {
    const count = inputs.filter(input => input.checked).length;
    const maximum = binding.max_choices ?? binding.choice?.max_choices;
    for (const input of inputs) input.disabled = multiple && !!maximum && count >= maximum && !input.checked;
    status.textContent = `已选择 ${count} 个片段。`;
  };
  const clear = action('清除所选片段', () => { inputs.forEach(input => { input.checked = false; }); update(); changed(); });
  parent.append(element('p', multiple ? '在文段中勾选片段，再次点击可取消。' : '在文段中选择一个片段，也可清除后重新作答。', 'native-help'), passage, clear, status); update();
  return { read: () => multiple ? inputs.filter(input => input.checked).map(input => input.value) : inputs.find(input => input.checked)?.value ?? null, reset() { inputs.forEach(input => { input.checked = false; }); update(); } };
}

function orderControl(parent, binding, current, changed) {
  const choices = new Map((binding.choices || binding.choice?.choices || []).map(choice => [choice.identifier, choice]));
  const minimum = binding.min_choices ?? binding.choice?.min_choices ?? 0;
  const maximum = binding.max_choices ?? binding.choice?.max_choices ?? choices.size;
  const original = [...choices.keys()], full = minimum === original.length && maximum === original.length;
  let committed = Array.isArray(current) && current.length > 0;
  let selected = committed ? [...current] : full ? [...original] : [];
  const available = element('div', undefined, 'native-order-available'); available.setAttribute('aria-label', '可加入的排序项目');
  const list = element('ol', undefined, 'native-order-list'); list.setAttribute('aria-label', '当前排列');
  const status = element('p', '', 'native-help'); status.setAttribute('role', 'status');
  const adopt = action('采用当前顺序', () => { committed = true; render(); changed(); }); adopt.hidden = !full;
  function afterChange(focusId) { committed = selected.length > 0; render(focusId); changed(); }
  function move(id, offset) {
    const from = selected.indexOf(id), target = from + offset;
    if (target < 0 || target >= selected.length) return;
    [selected[from], selected[target]] = [selected[target], selected[from]]; afterChange(id);
  }
  function render(focusId) {
    available.replaceChildren();
    if (!full) for (const id of original.filter(id => !selected.includes(id))) {
      const choice = choices.get(id), add = action(`＋ ${choice.text}`, () => { selected.push(id); afterChange(id); });
      add.dataset.choice = id; add.setAttribute('aria-label', `加入 ${choice.text}`); add.disabled = !!maximum && selected.length >= maximum; available.append(add);
    }
    list.replaceChildren(...selected.map((id, index) => {
      const choice = choices.get(id), row = element('li'); row.tabIndex = -1; row.dataset.choice = id; row.setAttribute('aria-label', `第 ${index + 1} 项：${choice.text}`);
      const up = action('↑', () => move(id, -1)), down = action('↓', () => move(id, 1));
      up.setAttribute('aria-label', `上移 ${choice.text}`); up.disabled = index === 0;
      down.setAttribute('aria-label', `下移 ${choice.text}`); down.disabled = index === selected.length - 1;
      row.append(element('span', String(index + 1), 'native-order-position'), element('span', choice.text, 'native-order-label'), up, down);
      if (!full) { const remove = action('移除', () => { selected = selected.filter(value => value !== id); afterChange(id); }); remove.setAttribute('aria-label', `移除 ${choice.text}`); row.append(remove); }
      return row;
    }));
    status.textContent = committed ? `已记录 ${selected.length} 项的顺序。` : '初始排列尚未作答；调整或采用当前顺序后才会记录答案。';
    if (focusId) [...list.children, ...available.children].find(node => node.dataset.choice === focusId)?.focus();
  }
  const clear = action('清除此题排列', () => { selected = full ? [...original] : []; committed = false; render(); changed(); });
  parent.append(element('p', full ? '使用上移、下移按钮调整排列，或采用当前顺序。' : `加入 ${minimum}–${maximum || original.length} 项，再调整先后顺序。`, 'native-help'), available, list, adopt, clear, status); render();
  return { read: () => committed ? [...selected] : null, reset() { selected = full ? [...original] : []; committed = false; render(); } };
}

function inlineControl(parent, binding, current, changed, insideComposite) {
  const spec = binding.inline_choice, choices = spec.choices || binding.choices;
  const control = picker(spec.label || binding.identifier || '文中选项', choices, spec.placeholder || binding.placeholder || '请选择');
  control.label.classList.add('native-inline-field'); control.select.dataset.inlineControl = 'true';
  control.select.setAttribute('aria-required', String(spec.required)); control.select.value = typeof current === 'string' ? current : '';
  control.select.addEventListener('change', changed);
  if (insideComposite || !spec.passage) parent.append(control.label);
  else {
    const passage = element('div', undefined, 'native-inline-passage'); passage.setAttribute('aria-label', '文中下拉选项');
    for (const part of spec.passage) passage.append('text' in part ? document.createTextNode(part.text) : control.label);
    parent.append(passage);
  }
  return { read: () => control.select.value || null, reset() { control.select.value = ''; } };
}

/** Restore the exact supported response value before exposing the controls. */
export function createNativeControl(parent, binding, current, changed, { inline = false } = {}) {
  if (binding.graphic) return null;
  if (binding.gap_matching) return gapControl(parent, binding, current, changed);
  if (binding.matching) return matchControl(parent, binding, current, changed);
  if (binding.hottext) return hottextControl(parent, binding, current, changed);
  if (binding.cardinality === 'ordered') return orderControl(parent, binding, current, changed);
  if (binding.inline_choice) return inlineControl(parent, binding, current, changed, inline);
  return null;
}
