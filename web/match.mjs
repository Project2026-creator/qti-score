/** Input controls only. The MoonBit core validates and scores associations. */
export function createMatchControl(fieldset, item, onChange) {
  const [sources, targets] = item.matching.sets;
  let pairs = [];
  const help = document.createElement('p');
  help.className = 'order-help';
  help.textContent = item.cardinality === 'single' ? '选择来源和目标，添加一组关联。' :
    '选择来源和目标，逐次添加关联；同一目标可以按题目规则关联多次。';
  const picker = document.createElement('div');
  picker.className = 'match-picker';
  function select(labelText, choices) {
    const label = document.createElement('label');
    label.textContent = labelText;
    const control = document.createElement('select');
    const empty = document.createElement('option');
    empty.value = ''; empty.textContent = '请选择';
    control.append(empty);
    for (const choice of choices) {
      const option = document.createElement('option');
      option.value = choice.identifier; option.textContent = choice.text;
      control.append(option);
    }
    label.append(control); picker.append(label);
    return control;
  }
  const source = select('来源', sources);
  const target = select('目标', targets);
  const add = document.createElement('button');
  add.type = 'button'; add.className = 'secondary'; add.textContent = '添加关联';
  const list = document.createElement('ul');
  list.className = 'match-list'; list.setAttribute('aria-label', '已添加的关联');
  const status = document.createElement('p');
  status.className = 'order-help'; status.setAttribute('role', 'status');
  function updateAdd() { add.disabled = !source.value || !target.value; }
  source.addEventListener('change', updateAdd); target.addEventListener('change', updateAdd);
  add.addEventListener('click', () => {
    if (!source.value || !target.value) return;
    const pair = [source.value, target.value];
    if (item.cardinality === 'single') pairs = [pair]; else pairs.push(pair);
    render(); onChange(); source.focus();
  });
  function render() {
    list.replaceChildren();
    for (const [index, [from, to]] of pairs.entries()) {
      const row = document.createElement('li');
      const text = document.createElement('span');
      text.textContent = `${sources.find(c => c.identifier === from).text} → ${targets.find(c => c.identifier === to).text}`;
      const remove = document.createElement('button');
      remove.type = 'button'; remove.className = 'text-button'; remove.textContent = '移除';
      remove.setAttribute('aria-label', `移除 ${text.textContent}`);
      remove.addEventListener('click', () => { pairs.splice(index, 1); render(); onChange(); source.focus(); });
      row.append(text, remove); list.append(row);
    }
    status.textContent = pairs.length ? `已添加 ${pairs.length} 组关联，提交后检查次数限制并评分。` : '尚未作答。';
    updateAdd();
  }
  fieldset.append(help, picker, add, list, status);
  render();
  return {
    response() {
      const values = pairs.map(([from, to]) => `${from} ${to}`);
      return { RESPONSE: item.cardinality === 'single' ? values[0] ?? null : values };
    },
    reset() { pairs = []; source.value = ''; target.value = ''; render(); },
  };
}
