/** Collect independent scalar responses in their authored text positions. */
export function createCompositeControl(fieldset, item) {
  const controls = new Map();
  const passage = document.createElement('div'); passage.className = 'composite-passage';
  for (const part of item.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const binding = item.responses.find(b => b.identifier === part.response);
    if (binding.choice) {
      const block = document.createElement('fieldset'); block.className = 'composite-choice';
      block.setAttribute('role', 'radiogroup');
      block.setAttribute('aria-required', String(binding.choice.required));
      block.dataset.orientation = binding.choice.orientation;
      const legend = document.createElement('legend');
      legend.textContent = (binding.choice.prompt || `第 ${item.responses.indexOf(binding) + 1} 项选择`) +
        (binding.choice.required ? '（必答）' : '（可选）');
      block.append(legend);
      const inputs = [];
      for (const choice of binding.choice.choices) {
        const label = document.createElement('label'); label.className = 'answer-option';
        const radio = document.createElement('input'); radio.type = 'radio';
        radio.name = `composite-${binding.identifier}`; radio.value = choice.identifier;
        const text = document.createElement('span'); text.textContent = choice.text;
        label.append(radio, text); block.append(label); inputs.push(radio);
      }
      controls.set(binding.identifier, {
        value: () => inputs.find(input => input.checked)?.value || null,
        reset: () => { for (const input of inputs) input.checked = false; },
      });
      passage.append(block);
      continue;
    }
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
    controls.set(binding.identifier, { value: () => input.value || null, reset: () => { input.value = ''; } });
    if (spec?.label) {
      const field = document.createElement('label'); field.className = 'inline-choice-field';
      const label = document.createElement('span'); label.textContent = spec.label;
      field.append(label, input); passage.append(field);
    } else { passage.append(input); }
  }
  const help = document.createElement('p'); help.className = 'order-help';
  const requiredCount = item.responses.filter(b => b.inline_choice?.required || b.choice?.required).length;
  help.textContent = `${item.responses.length} 个响应分别作答；${requiredCount ? `${requiredCount} 组选项必答，其余响应可留空。` : '留空表示未作答。'}得分由题目规则合成。`;
  fieldset.append(help, passage);
  return {
    response() { return Object.fromEntries([...controls].map(([id, control]) => [id, control.value()])); },
    reset() { for (const control of controls.values()) control.reset(); },
  };
}
