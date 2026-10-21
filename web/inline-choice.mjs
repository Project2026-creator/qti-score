/** A native select stays at its authored position in the plain-text passage. */
export function createInlineChoiceControl(fieldset, item) {
  const spec = item.inline_choice;
  const passage = document.createElement('div');
  passage.className = 'inline-choice-passage';
  const input = document.createElement('select');
  input.name = 'RESPONSE';
  input.setAttribute('aria-label', spec.label || '文中选项');
  input.setAttribute('aria-required', String(spec.required));
  const placeholder = document.createElement('option');
  placeholder.value = ''; placeholder.textContent = spec.placeholder || '请选择';
  input.append(placeholder);
  for (const choice of item.choices) {
    const option = document.createElement('option');
    option.value = choice.identifier; option.textContent = choice.text; input.append(option);
  }
  const field = document.createElement('label'); field.className = 'inline-choice-field';
  if (spec.label) {
    const label = document.createElement('span'); label.textContent = spec.label; field.append(label);
  }
  field.append(input);
  for (const part of spec.passage) {
    passage.append('text' in part ? document.createTextNode(part.text) : field);
  }
  const help = document.createElement('p'); help.className = 'order-help';
  help.textContent = spec.required ? '本题必答，请在文中选择一项。' : '从下拉框选择一项；选择占位项或清空可撤销作答。';
  const status = document.createElement('p'); status.className = 'order-help'; status.setAttribute('role', 'status');
  function update() {
    const missing = spec.required && !input.value;
    input.setAttribute('aria-invalid', String(missing));
    status.textContent = input.value ? `已选择：${input.selectedOptions[0].textContent}` : missing ? '尚未选择，提交时将报告缺少必答选项。' : '尚未作答。';
  }
  input.addEventListener('input', update);
  input.addEventListener('change', update);
  fieldset.append(help, passage, status); update();
  return {
    response() { return { RESPONSE: input.value || null }; },
    reset() { input.value = ''; update(); },
  };
}
