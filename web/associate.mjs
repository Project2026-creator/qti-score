/** Candidate input only; authoritative validation and scoring are in MoonBit. */
export function associateChoices(spec, random = Math.random) {
  const free = spec.choices.filter(choice => !choice.fixed);
  if (spec.shuffle) for (let i = free.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [free[i], free[j]] = [free[j], free[i]];
  }
  let index = 0;
  return spec.choices.map(choice => choice.fixed ? choice : free[index++]);
}

export function createAssociationControl(parent, binding, current = null, changed = () => {}) {
  const spec = binding.association, choices = associateChoices(spec);
  const byId = new Map(choices.map(choice => [choice.identifier, choice]));
  let pairs = (Array.isArray(current) ? current : current ? [current] : []).map(pair => pair.trim().split(/\s+/));
  const node = (tag, text, className) => {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  };
  const pickers = node('div', undefined, 'associate-picker');
  function picker(title) {
    const label = node('label'), select = node('select');
    select.setAttribute('aria-label', title);
    const empty = node('option', '请选择'); empty.value = ''; select.append(empty);
    for (const choice of choices) {
      const option = node('option', choice.text); option.value = choice.identifier; select.append(option);
    }
    label.append(node('span', title), select); pickers.append(label); return select;
  }
  const first = picker('配对第一项'), second = picker('配对第二项');
  const add = node('button', binding.cardinality === 'single' ? '采用此配对' : '添加配对'); add.type = 'button';
  const list = node('ul', undefined, 'associate-list'); list.setAttribute('aria-label', '已添加的无向配对');
  const status = node('p', '', 'associate-help'); status.setAttribute('role', 'status');
  const key = pair => [...pair].sort().join(' ');
  const single = binding.cardinality === 'single';
  function render() {
    list.replaceChildren(...pairs.map(([a, b], index) => {
      const label = `${byId.get(a)?.text || a} ↔ ${byId.get(b)?.text || b}`;
      const row = node('li'), remove = node('button', '移除'); remove.type = 'button';
      remove.setAttribute('aria-label', `移除配对：${label}`);
      remove.addEventListener('click', () => { pairs.splice(index, 1); render(); changed(); first.focus(); });
      row.append(node('span', label), remove); return row;
    }));
    status.textContent = pairs.length ? `已添加 ${pairs.length} 组配对。` : '从同一组选项中选择两项，顺序可以交换。';
    add.disabled = !first.value || !second.value;
  }
  add.addEventListener('click', () => {
    const a = first.value, b = second.value;
    if (!a || !b) return;
    if (a === b) { status.textContent = '请选择两个不同的选项。'; return; }
    const candidate = single ? [[a, b]] : [...pairs, [a, b]];
    if (!single && pairs.some(pair => key(pair) === key([a, b]))) {
      status.textContent = '此配对已添加，交换两端仍是同一组。'; return;
    }
    if (spec.max_associations && candidate.length > spec.max_associations) {
      status.textContent = `最多可添加 ${spec.max_associations} 组配对。`; return;
    }
    for (const [id, other] of [[a, b], [b, a]]) {
      const choice = byId.get(id);
      if (choice.match_group.length && !choice.match_group.includes(other)) {
        status.textContent = '题目规则不允许这两项配对。'; return;
      }
      if (choice.match_max && candidate.filter(pair => pair.includes(id)).length > choice.match_max) {
        status.textContent = `${choice.text} 最多可使用 ${choice.match_max} 次。`; return;
      }
    }
    pairs = candidate; first.value = second.value = ''; render(); changed(); first.focus();
  });
  for (const select of [first, second]) select.addEventListener('change', () => { add.disabled = !first.value || !second.value; });
  parent.append(node('p', '无向关联 · 每组由两个不同的选项组成', 'associate-help'), pickers, add, list, status);
  render();
  return {
    read: () => single ? (pairs[0]?.join(' ') ?? null) : pairs.map(pair => pair.join(' ')),
    reset() { pairs = []; first.value = second.value = ''; render(); },
  };
}
