/** Native selection controls in plain-text context. The core owns scoring. */
export function createHottextControl(fieldset, item) {
  const choices = new Map(item.choices.map(choice => [choice.identifier, choice]));
  const controls = [];
  const passage = document.createElement('div');
  passage.className = 'hottext-passage'; passage.setAttribute('aria-label', '文段中的可选片段');
  for (const part of item.hottext.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const choice = choices.get(part.choice);
    const label = document.createElement('label'); label.className = 'hottext-choice';
    const input = document.createElement('input');
    input.type = item.cardinality === 'single' ? 'radio' : 'checkbox';
    input.name = 'RESPONSE'; input.value = choice.identifier;
    input.addEventListener('change', update);
    controls.push(input);
    label.append(input, document.createTextNode(choice.text)); passage.append(label);
  }
  const help = document.createElement('p'); help.className = 'order-help';
  help.textContent = item.cardinality === 'single' ? '在文段中选择一个片段；清空作答可取消选择。' : '勾选文段中的片段，再次点击可取消。';
  const status = document.createElement('p'); status.className = 'order-help'; status.setAttribute('role', 'status');
  function update() {
    const count = controls.filter(control => control.checked).length;
    status.textContent = !count ? '尚未作答。' : count < item.min_choices ? `已选择 ${count} 项，至少需要 ${item.min_choices} 项。` :
      item.max_choices !== 0 && count > item.max_choices ? `已选择 ${count} 项，最多允许 ${item.max_choices} 项。` : `已选择 ${count} 项，可提交评分。`;
  }
  fieldset.append(help, passage, status); update();
  return { reset() { for (const control of controls) control.checked = false; update(); } };
}
