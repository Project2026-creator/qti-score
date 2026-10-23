import { createSliderControl } from './slider.mjs';

/** Collect independent responses in their authored text positions. */
export function createCompositeControl(fieldset, item, onChange = () => {}) {
  const controls = new Map();
  const passage = document.createElement('div'); passage.className = 'composite-passage';
  let sliderGroup;
  for (const part of item.passage) {
    if ('text' in part) { sliderGroup = null; passage.append(document.createTextNode(part.text)); continue; }
    const binding = item.responses.find(b => b.identifier === part.response);
    if (binding.slider) {
      const block = document.createElement('fieldset'); block.className = 'composite-slider';
      const legend = document.createElement('legend');
      const title = binding.slider.prompt || `第 ${item.responses.indexOf(binding) + 1} 项数值`;
      legend.textContent = title; block.append(legend);
      const control = createSliderControl(block, binding, onChange, {
        responseIdentifier: binding.identifier, idPrefix: `composite-slider-${binding.identifier}`,
        rangeLabel: `${title}：滑杆`,
      });
      const clear = document.createElement('button'); clear.type = 'button';
      clear.className = 'text-button'; clear.textContent = '清除此项';
      clear.addEventListener('click', () => { control.reset(); onChange(); }); block.append(clear);
      controls.set(binding.identifier, { value: () => control.response()[binding.identifier], reset: () => control.reset() });
      if (!sliderGroup) {
        sliderGroup = document.createElement('div'); sliderGroup.className = 'composite-slider-group';
        passage.append(sliderGroup);
      }
      sliderGroup.append(block); continue;
    }
    sliderGroup = null;
    if (binding.choice) {
      const multiple = binding.cardinality === 'multiple';
      const block = document.createElement('fieldset'); block.className = 'composite-choice';
      block.setAttribute('role', multiple ? 'group' : 'radiogroup');
      if (!multiple) block.setAttribute('aria-required', String(binding.choice.required));
      block.dataset.orientation = binding.choice.orientation;
      const legend = document.createElement('legend');
      legend.textContent = (binding.choice.prompt || `第 ${item.responses.indexOf(binding) + 1} 项选择`) +
        (binding.choice.required ? '（必答）' : '（可选）');
      block.append(legend);
      const inputs = [];
      for (const choice of binding.choice.choices) {
        const label = document.createElement('label'); label.className = 'answer-option';
        const radio = document.createElement('input'); radio.type = multiple ? 'checkbox' : 'radio';
        radio.name = `composite-${binding.identifier}`; radio.value = choice.identifier;
        const text = document.createElement('span'); text.textContent = choice.text;
        label.append(radio, text); block.append(label); inputs.push(radio);
      }
      const hint = document.createElement('p'); hint.className = 'composite-choice-help';
      hint.id = `choice-help-${binding.identifier}`;
      const updateHint = () => {
        if (!multiple) return;
        const { min_choices: minimum, max_choices: maximum } = binding.choice;
        const count = inputs.filter(input => input.checked).length;
        hint.textContent = `多选 · ${minimum ? `至少 ${minimum} 项` : '可留空'} · ${maximum ? `最多 ${maximum} 项` : '不设上限'} · 已选 ${count} 项`;
      };
      if (multiple) {
        hint.setAttribute('role', 'status'); block.setAttribute('aria-describedby', hint.id);
        block.addEventListener('change', updateHint); block.append(hint); updateHint();
      }
      controls.set(binding.identifier, {
        value: () => multiple ? inputs.filter(input => input.checked).map(input => input.value) : inputs.find(input => input.checked)?.value || null,
        reset: () => { for (const input of inputs) input.checked = false; updateHint(); },
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
  const requirement = requiredCount === item.responses.length ? '所有选项组均为必答。' : requiredCount ? `${requiredCount} 组选项必答，其余响应可留空。` : '留空表示未作答。';
  help.textContent = `${item.responses.length} 个响应分别作答；${requirement}得分由题目规则合成。`;
  fieldset.append(help, passage);
  return {
    response() { return Object.fromEntries([...controls].map(([id, control]) => [id, control.value()])); },
    reset() { for (const control of controls.values()) control.reset(); },
  };
}
