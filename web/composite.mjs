/** Collect independent scalar responses in their authored text positions. */
export function createCompositeControl(fieldset, item) {
  const controls = new Map();
  const passage = document.createElement('div'); passage.className = 'composite-passage';
  for (const part of item.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const binding = item.responses.find(b => b.identifier === part.response);
    const spec = binding.inline_choice;
    const input = document.createElement(spec ? 'select' : 'input'); input.className = 'composite-entry';
    input.setAttribute('aria-label', spec?.label || `第 ${item.responses.indexOf(binding) + 1} 空`);
    if (spec) {
      input.setAttribute('aria-required', String(spec.required));
      const placeholder = document.createElement('option');
      placeholder.value = ''; placeholder.textContent = binding.placeholder || '请选择'; input.append(placeholder);
      for (const choice of spec.choices) {
        const option = document.createElement('option');
        option.value = choice.identifier; option.textContent = choice.text; input.append(option);
      }
    } else {
      input.type = 'text'; input.autocomplete = 'off'; input.maxLength = 65536; input.placeholder = binding.placeholder;
      if (binding.base_type !== 'string') input.inputMode = 'decimal';
    }
    controls.set(binding.identifier, input);
    if (spec?.label) {
      const field = document.createElement('label'); field.className = 'inline-choice-field';
      const label = document.createElement('span'); label.textContent = spec.label;
      field.append(label, input); passage.append(field);
    } else { passage.append(input); }
  }
  const help = document.createElement('p'); help.className = 'order-help';
  const requiredCount = item.responses.filter(b => b.inline_choice?.required).length;
  help.textContent = `${item.responses.length} 个空分别作答；${requiredCount ? `${requiredCount} 个下拉选项必答，其余空可留空。` : '留空表示未作答。'}得分由题目规则合成。`;
  fieldset.append(help, passage);
  return {
    response() { return Object.fromEntries([...controls].map(([id, input]) => [id, input.value || null])); },
    reset() { for (const input of controls.values()) input.value = ''; },
  };
}
