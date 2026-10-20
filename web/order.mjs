/** Rendering and input only; order validation and scoring remain in MoonBit. */
export function createOrderControl(fieldset, item, onChange) {
  const choices = new Map(item.choices.map(choice => [choice.identifier, choice]));
  const original = item.choices.map(choice => choice.identifier);
  const full = item.min_choices === original.length && item.max_choices === original.length;
  let selected = full ? [...original] : [];
  let committed = false;

  const help = document.createElement('p');
  help.className = 'order-help';
  help.textContent = full ? '用上移／下移调整顺序，或点击“采用当前顺序”确认作答。初始排列尚未作为答案提交。' :
    `选择 ${item.min_choices}–${item.max_choices} 项，再用上移／下移调整顺序。`;
  const available = document.createElement('div');
  available.className = 'order-available';
  available.setAttribute('aria-label', '可加入的排序项目');
  const list = document.createElement('ol');
  list.className = 'order-list';
  list.setAttribute('aria-label', '当前排列');
  const status = document.createElement('p');
  status.className = 'order-help';
  status.setAttribute('role', 'status');
  const confirm = document.createElement('button');
  confirm.type = 'button';
  confirm.className = 'secondary order-confirm';
  confirm.textContent = '采用当前顺序';
  confirm.hidden = !full;
  confirm.addEventListener('click', () => { committed = true; render(); onChange(); });
  fieldset.append(help, available, list, confirm, status);

  function button(label, action, className = 'order-action') {
    const control = document.createElement('button');
    control.type = 'button';
    control.className = className;
    control.textContent = label;
    control.addEventListener('click', action);
    return control;
  }

  function changed(focusId) {
    committed = selected.length > 0;
    render(focusId);
    onChange();
  }

  function move(id, delta) {
    const index = selected.indexOf(id);
    const target = index + delta;
    if (target < 0 || target >= selected.length) return;
    [selected[index], selected[target]] = [selected[target], selected[index]];
    changed(id);
  }

  function render(focusId) {
    available.replaceChildren();
    if (!full) {
      for (const id of original.filter(id => !selected.includes(id))) {
        const choice = choices.get(id);
        const add = button(`＋ ${choice.text}`, () => {
          if (selected.length >= item.max_choices) return;
          selected.push(id);
          changed(id);
        }, 'secondary order-add');
        add.setAttribute('aria-label', `加入 ${choice.text}`);
        add.dataset.choice = id;
        add.disabled = selected.length >= item.max_choices;
        available.append(add);
      }
    }
    list.replaceChildren();
    for (const [index, id] of selected.entries()) {
      const choice = choices.get(id);
      const row = document.createElement('li');
      row.tabIndex = -1;
      row.dataset.choice = id;
      row.setAttribute('aria-label', `第 ${index + 1} 项：${choice.text}`);
      const label = document.createElement('span');
      label.textContent = choice.text;
      label.className = 'order-label';
      const position = document.createElement('span');
      position.className = 'order-position';
      position.textContent = String(index + 1);
      const up = button('↑', () => move(id, -1));
      up.setAttribute('aria-label', `上移 ${choice.text}`);
      up.disabled = index === 0;
      const down = button('↓', () => move(id, 1));
      down.setAttribute('aria-label', `下移 ${choice.text}`);
      down.disabled = index === selected.length - 1;
      row.append(position, label, up, down);
      if (!full) {
        const remove = button('移除', () => {
          selected = selected.filter(value => value !== id);
          changed(id);
        });
        remove.setAttribute('aria-label', `移除 ${choice.text}`);
        row.append(remove);
      }
      list.append(row);
    }
    status.textContent = !committed ? '尚未作答。' : selected.length < item.min_choices ?
      `已记录 ${selected.length} 项，至少需要 ${item.min_choices} 项。` :
      `已记录 ${selected.length} 项的顺序，可提交评分。`;
    if (focusId) ([...list.children].find(row => row.dataset.choice === focusId) ||
      [...available.children].find(control => control.dataset.choice === focusId))?.focus();
  }

  render();
  return {
    response() { return { RESPONSE: committed ? [...selected] : null }; },
    reset() { selected = full ? [...original] : []; committed = false; render(); },
  };
}
