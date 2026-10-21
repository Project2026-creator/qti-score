/** Plain text, native selects and a contextual preview; scoring is in MoonBit. */
export function createGapControl(fieldset, item, onChange) {
  const { sets: [choices, gaps], passage } = item.gap_matching;
  const labels = new Map(gaps.map((gap, index) => [gap.identifier,
    gap.text === gap.identifier ? `第 ${index + 1} 空` : gap.text]));
  const controls = new Map();
  const help = document.createElement('p');
  help.className = 'order-help';
  help.textContent = `可选词：${choices.map(c => `${c.text}（${c.match_max === 0 ? '可重复' : `最多 ${c.match_max} 空`}）`).join('、')}。`;
  const content = document.createElement('div');
  content.className = 'gap-passage';
  content.setAttribute('aria-label', '填空文段');
  for (const part of passage) {
    if ('text' in part) { content.append(document.createTextNode(part.text)); continue; }
    const gap = gaps.find(g => g.identifier === part.gap);
    const control = document.createElement('select');
    control.setAttribute('aria-label', labels.get(part.gap));
    if (gap.match_min > 0) control.setAttribute('aria-description', '非空作答需要填写此空');
    const placeholder = document.createElement('option');
    placeholder.value = ''; placeholder.textContent = `〔${labels.get(part.gap)}〕`;
    control.append(placeholder);
    for (const choice of choices) {
      const option = document.createElement('option');
      option.value = choice.identifier; option.textContent = choice.text;
      control.append(option);
    }
    control.addEventListener('change', () => { update(); onChange(); });
    controls.set(part.gap, control);
    content.append(control);
  }
  const heading = document.createElement('p');
  heading.className = 'order-help'; heading.textContent = '填入后的文段';
  const preview = document.createElement('p');
  preview.className = 'gap-preview'; preview.setAttribute('aria-label', '填入后的文段');
  const status = document.createElement('p');
  status.className = 'order-help'; status.setAttribute('role', 'status');
  function update() {
    preview.textContent = passage.map(part => {
      if ('text' in part) return part.text;
      const choice = choices.find(c => c.identifier === controls.get(part.gap).value);
      return choice?.text ?? `〔${labels.get(part.gap)}〕`;
    }).join('');
    const count = [...controls.values()].filter(control => control.value).length;
    status.textContent = count ? `已填写 ${count} / ${gaps.length} 空，提交后检查必填项与词语使用次数。` : '尚未作答。';
  }
  fieldset.append(help, content, heading, preview, status);
  update();
  return {
    response() {
      const pairs = [...controls].filter(([, control]) => control.value).map(([id, control]) => `${control.value} ${id}`);
      return { RESPONSE: item.cardinality === 'single' ? pairs[0] ?? null : pairs };
    },
    reset() { for (const control of controls.values()) control.value = ''; update(); },
  };
}
