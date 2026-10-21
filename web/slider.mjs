/** Range and text inputs collect a response; the MoonBit core validates it. */
export function createSliderControl(fieldset, item, onChange) {
  const spec = item.slider;
  let selected = false;
  const range = document.createElement('input');
  range.type = 'range'; range.id = 'slider-answer'; range.className = 'slider-input';
  range.min = String(spec.lower_bound); range.max = String(spec.upper_bound);
  range.step = spec.step === null ? 'any' : String(spec.step);
  range.value = String(spec.lower_bound);
  range.setAttribute('aria-label', '数值滑杆'); range.setAttribute('aria-orientation', spec.orientation);
  range.style.direction = spec.orientation === 'vertical' ? (spec.reverse ? 'ltr' : 'rtl') : (spec.reverse ? 'rtl' : 'ltr');
  if (spec.orientation === 'vertical') range.style.writingMode = 'vertical-lr';
  const label = document.createElement('label'); label.htmlFor = 'slider-value'; label.className = 'text-label';
  label.textContent = '填写数值';
  const input = document.createElement('input'); input.type = 'text'; input.id = 'slider-value';
  input.className = 'text-answer'; input.inputMode = 'decimal'; input.autocomplete = 'off'; input.maxLength = 65536;
  input.placeholder = '尚未作答';
  const adopt = document.createElement('button'); adopt.type = 'button'; adopt.className = 'secondary'; adopt.textContent = '采用滑杆当前位置';
  const bounds = document.createElement('p'); bounds.className = 'order-help';
  bounds.textContent = `范围 ${spec.lower_bound}–${spec.upper_bound}；${spec.step === null ? '连续数值' : `步长 ${spec.step}`}。`;
  const status = document.createElement('p'); status.className = 'order-help'; status.setAttribute('role', 'status');
  function update() {
    range.setAttribute('aria-valuetext', selected ? `滑杆位置 ${range.value}；填写值 ${input.value}` : `位置 ${range.value}，尚未记录为答案`);
    status.textContent = selected ? `当前作答：${input.value}` : `尚未作答；滑杆当前位置 ${range.value} 还不是答案。`;
  }
  function chooseRange() { selected = true; input.value = range.value; update(); onChange(); }
  range.addEventListener('input', chooseRange);
  adopt.addEventListener('click', chooseRange);
  input.addEventListener('input', () => {
    selected = input.value.trim() !== '';
    const value = Number(input.value);
    // Sync the visual position when possible, but keep the exact text as the
    // response. Out-of-range and off-grid entries must reach core validation.
    if (selected && Number.isFinite(value) && value >= spec.lower_bound && value <= spec.upper_bound) range.value = input.value;
    update(); onChange();
  });
  const track = document.createElement('div'); track.className = 'slider-track'; track.dataset.orientation = spec.orientation;
  const lower = document.createElement('span'); lower.textContent = String(spec.lower_bound);
  const upper = document.createElement('span'); upper.textContent = String(spec.upper_bound);
  track.append(lower, range, upper);
  if (spec.step_label && spec.step !== null && spec.orientation === 'horizontal' && (spec.upper_bound - spec.lower_bound) / spec.step <= 20) {
    const ticks = document.createElement('datalist'); ticks.id = 'slider-ticks';
    for (let i = 0; i <= Math.floor((spec.upper_bound - spec.lower_bound) / spec.step); i++) {
      const tick = document.createElement('option'); tick.value = String(Number((spec.lower_bound + i * spec.step).toPrecision(12)));
      tick.label = tick.value; ticks.append(tick);
    }
    range.setAttribute('list', ticks.id); track.append(ticks);
  }
  fieldset.append(bounds, track, status, label, input, adopt); update();
  return {
    response() { return { RESPONSE: selected ? input.value : null }; },
    reset() { selected = false; input.value = ''; range.value = String(spec.lower_bound); update(); },
  };
}
