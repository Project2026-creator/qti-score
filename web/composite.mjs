/** Collect independent scalar responses in their authored text positions. */
export function createCompositeControl(fieldset, item) {
  const controls = new Map();
  const passage = document.createElement('div'); passage.className = 'composite-passage';
  for (const part of item.passage) {
    if ('text' in part) { passage.append(document.createTextNode(part.text)); continue; }
    const binding = item.responses.find(b => b.identifier === part.response);
    const input = document.createElement('input'); input.type = 'text'; input.className = 'composite-entry';
    input.autocomplete = 'off'; input.maxLength = 65536; input.placeholder = binding.placeholder;
    input.setAttribute('aria-label', `第 ${item.responses.indexOf(binding) + 1} 空`);
    if (binding.base_type !== 'string') input.inputMode = 'decimal';
    controls.set(binding.identifier, input); passage.append(input);
  }
  const help = document.createElement('p'); help.className = 'order-help';
  help.textContent = `${item.responses.length} 个空分别提交；留空表示该响应未作答，得分由题目规则合成。`;
  fieldset.append(help, passage);
  return {
    response() { return Object.fromEntries([...controls].map(([id, input]) => [id, input.value || null])); },
    reset() { for (const input of controls.values()) input.value = ''; },
  };
}
