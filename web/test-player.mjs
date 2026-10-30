import { importPackage } from '../sdk/index.mjs';

const $ = id => document.getElementById(id);
let bundle, plan, session, planDescription, state;
let readers = new Map(), clockBase = 0, clockOrigin = performance.now(), lastAction = 0;
let inputDirty = false, jsonDirty = false;
let imageURLs = [];
const clock = () => Math.max(lastAction, clockBase + (performance.now() - clockOrigin) / 1000);
const node = (tag, text, className) => { const result = document.createElement(tag); if (text !== undefined) result.textContent = text; if (className) result.className = className; return result; };

function status(text) { $('status').textContent = text; $('error').hidden = true; }
function showError(error) {
  $('error').textContent = `${error.code ? `${error.code}：` : ''}${error.message}`;
  $('error').hidden = false;
  $('result').hidden = true;
  $('feedback').replaceChildren();
}
function run(operation) { try { operation(); } catch (error) { showError(error); } }
async function runAsync(operation) { try { await operation(); } catch (error) { showError(error); } }
function disposeSession() { session?.dispose(); session = undefined; state = undefined; }
function disposePlan() { disposeSession(); plan?.dispose(); plan = undefined; planDescription = undefined; }
function download(filename, content, type) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const anchor = node('a'); anchor.href = url; anchor.download = filename; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
function syncClock(snapshot) {
  const data = JSON.parse(snapshot);
  lastAction = data.actions.at(-1)?.time ?? data.started_at;
  clockBase = lastAction; clockOrigin = performance.now();
}

function openPlan() {
  const next = bundle.getTest($('test-resource').value);
  disposePlan(); plan = next; planDescription = plan.describe();
  $('test-title').textContent = planDescription.title;
  $('plan-summary').textContent = `${planDescription.parts.length} 个部分 · ${planDescription.item_count} 道题\n` + planDescription.parts.map(part => `${part.identifier}：${part.navigation_mode === 'linear' ? '顺序作答' : '自由导航'} / ${part.submission_mode === 'individual' ? '逐题提交' : '整部分提交'}${part.max_time === null ? '' : ` / ${part.max_time} 秒`}`).join('\n');
  $('start-test').disabled = false; $('snapshot-file').disabled = false;
  resetWorkspace(); status('试卷已就绪，可以开始新会话或恢复快照。');
}
async function loadPackage(bytes) {
  const next = importPackage(bytes);
  const resources = next.describe().resources.filter(resource => resource.type === 'imsqti_test_xmlv3p0');
  if (!resources.length) { next.dispose(); throw new Error('内容包中没有 QTI 3 试卷资源。'); }
  disposePlan(); bundle?.dispose(); bundle = next;
  resetWorkspace(); $('start-test').disabled = true; $('snapshot-file').disabled = true;
  $('plan-summary').textContent = '选择试卷后打开，编译通过后即可开始。';
  $('test-resource').replaceChildren(...resources.map(resource => { const option = node('option', resource.identifier); option.value = resource.identifier; return option; }));
  $('test-resource').disabled = false; $('open-test').disabled = false;
  openPlan();
}
function resetWorkspace() {
  clearImages();
  $('response-controls').replaceChildren(); $('item-nav').replaceChildren(); $('feedback').replaceChildren();
  $('result').hidden = true; $('completion').hidden = true;
  $('item-title').textContent = '等待开始会话'; $('item-prompt').textContent = '点击“开始新会话”，按照试卷顺序完成作答。';
  $('response-json').value = '{}'; $('part-label').textContent = '准备开始';
  for (const id of ['download-snapshot', 'pause-test', 'save-response', 'submit-response', 'next-item', 'finish-part', 'save-json']) $(id).disabled = true;
}

function clearImages() { imageURLs.forEach(url => URL.revokeObjectURL(url)); imageURLs = []; }
function localImagePath(reference, itemPath) {
  // The core already decoded this local URI exactly once. A percent character
  // in its normalized path is a literal filename character, not another URI.
  if (typeof reference !== 'string' || !reference || /[:\\\x00-\x1f\x7f]/.test(reference) || reference.startsWith('/')) throw new Error('图像必须引用内容包内的相对路径。');
  const parts = itemPath.split('/').slice(0, -1);
  for (const part of reference.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') { if (!parts.length) throw new Error('图像路径超出内容包。'); parts.pop(); }
    else parts.push(part);
  }
  return parts.join('/');
}
function safeImageBytes(bytes, type) {
  const ascii = (...positions) => positions.map(index => String.fromCharCode(bytes[index] ?? 0)).join('');
  if (type === 'image/png' && ascii(0,1,2,3,4,5,6,7) === '\x89PNG\r\n\x1a\n') return bytes;
  if (type === 'image/jpeg' && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return bytes;
  if (type === 'image/gif' && ['GIF87a','GIF89a'].includes(ascii(0,1,2,3,4,5))) return bytes;
  if (type === 'image/webp' && ascii(0,1,2,3) === 'RIFF' && ascii(8,9,10,11) === 'WEBP') return bytes;
  if (type !== 'image/svg+xml') throw new Error('图像格式与声明的类型不一致。');
  const source = new TextDecoder('utf-8', {fatal:true}).decode(bytes);
  if (/<!DOCTYPE|<!ENTITY/i.test(source)) throw new Error('SVG 图像包含不支持的文档声明。');
  const document = new DOMParser().parseFromString(source, 'image/svg+xml');
  if (document.querySelector('parsererror') || document.documentElement.localName !== 'svg') throw new Error('SVG 图像格式无效。');
  const tags = new Set(['svg','g','path','rect','circle','ellipse','line','polyline','polygon','title','desc','text','tspan']);
  const attributes = new Set(['xmlns','id','role','aria-label','aria-labelledby','aria-describedby','width','height','viewBox','preserveAspectRatio','x','y','x1','y1','x2','y2','cx','cy','r','rx','ry','d','points','transform','fill','fill-rule','fill-opacity','stroke','stroke-width','stroke-opacity','stroke-linecap','stroke-linejoin','opacity','font-family','font-size','font-weight','text-anchor','dominant-baseline','dx','dy']);
  for (const element of document.querySelectorAll('*')) {
    if (element.namespaceURI !== 'http://www.w3.org/2000/svg' || !tags.has(element.localName)) throw new Error('SVG 图像包含动态或不支持的内容。');
    for (const attribute of element.attributes) {
      if (!attributes.has(attribute.name) || (attribute.name !== 'xmlns' && /url\s*\(|https?:|javascript:|data:|file:|\/\//i.test(attribute.value))) throw new Error('SVG 图像包含外部引用或不支持的属性。');
    }
  }
  if (document.createTreeWalker(document, NodeFilter.SHOW_PROCESSING_INSTRUCTION).nextNode()) throw new Error('SVG 图像不支持处理指令。');
  return new TextEncoder().encode(new XMLSerializer().serializeToString(document.documentElement));
}
function packageImage(description, itemPath) {
  const bytes = bundle.readFile(localImagePath(description.data, itemPath));
  const url = URL.createObjectURL(new Blob([safeImageBytes(bytes, description.type)], {type:description.type})); imageURLs.push(url);
  const image = node('img'); image.src = url; image.alt = description.alternative || '题目图像';
  if (description.width) image.width = description.width;
  if (description.height) image.height = description.height;
  return image;
}
function regionShape(region) {
  const svgNS = 'http://www.w3.org/2000/svg';
  const shape = document.createElementNS(svgNS, {rect:'rect',circle:'circle',ellipse:'ellipse',poly:'polygon'}[region.shape]);
  const c = region.coords;
  const values = region.shape === 'rect' ? {x:c[0],y:c[1],width:c[2]-c[0],height:c[3]-c[1]} : region.shape === 'circle' ? {cx:c[0],cy:c[1],r:c[2]} : region.shape === 'ellipse' ? {cx:c[0],cy:c[1],rx:c[2],ry:c[3]} : {points:Array.from({length:c.length/2},(_,i)=>`${c[2*i]},${c[2*i+1]}`).join(' ')};
  for (const [key,value] of Object.entries(values)) shape.setAttribute(key, String(value));
  return shape;
}
function graphicPicture(field, graphic, itemPath, activate) {
  const picture = node('div', undefined, 'graphic-picture');
  try {
    const image = packageImage(graphic.object, itemPath); picture.append(image);
    const overlay = document.createElementNS('http://www.w3.org/2000/svg','svg'); overlay.classList.add('graphic-overlay');
    const fit = () => { overlay.setAttribute('viewBox',`0 0 ${graphic.object.width || image.naturalWidth} ${graphic.object.height || image.naturalHeight}`); };
    if (graphic.object.width && graphic.object.height) fit(); else image.addEventListener('load',fit);
    overlay.setAttribute('aria-label','图中可选区域');
    for (const region of graphic.regions) {
      const shape = regionShape(region); shape.dataset.graphicRegion = region.identifier;
      shape.setAttribute('role','button'); shape.setAttribute('tabindex','0'); shape.setAttribute('aria-label',`图中：${region.label}`);
      const title = document.createElementNS('http://www.w3.org/2000/svg','title'); title.textContent = region.label; shape.append(title);
      const choose = () => { if (!field.disabled) activate(region.identifier, shape); };
      shape.addEventListener('click',choose); shape.addEventListener('keydown',event=>{ if (event.key==='Enter'||event.key===' ') { event.preventDefault(); choose(); } });
      overlay.append(shape);
    }
    picture.append(overlay);
    image.addEventListener('error',()=>{ picture.replaceChildren(node('p','图像未能显示，可继续使用下方文字控件作答。')); });
  } catch (error) { picture.append(node('p',`图像未显示：${error.message} 可使用下方文字控件作答。`)); }
  field.append(picture); return picture;
}
function graphicControl(field, binding, current, itemPath) {
  const graphic = binding.graphic, id = binding.identifier;
  if (graphic.kind === 'hotspot') {
    const inputs = new Map();
    const picture = graphicPicture(field,graphic,itemPath,region=>{ const input=inputs.get(region); if (!input) return; input.checked=binding.cardinality==='multiple'?!input.checked:true; sync(); changed(); });
    const sync = () => { for (const shape of picture.querySelectorAll('[data-graphic-region]')) shape.setAttribute('aria-pressed',String(inputs.get(shape.dataset.graphicRegion)?.checked || false)); };
    for (const region of graphic.regions) {
      const label=node('label',undefined,'answer-option'), input=node('input'); input.type=binding.cardinality==='multiple'?'checkbox':'radio'; input.name=`graphic-${id}`; input.value=region.identifier;
      input.checked=binding.cardinality==='multiple'?Array.isArray(current)&&current.includes(region.identifier):current===region.identifier;
      input.addEventListener('change',()=>{sync();changed();}); inputs.set(region.identifier,input); label.append(input,node('span',region.label)); field.append(label);
    }
    readers.set(id,()=>binding.cardinality==='multiple'?[...inputs.values()].filter(input=>input.checked).map(input=>input.value):[...inputs.values()].find(input=>input.checked)?.value??null);
    const clear=node('button','清除此项'); clear.type='button'; clear.addEventListener('click',()=>{inputs.forEach(input=>{input.checked=false;});sync();changed();}); field.append(clear); sync();
    return;
  }
  const sources=binding.matching?.sets?.[0] || [], rows=[];
  const rowContainer=node('div',undefined,'graphic-pair-rows');
  graphicPicture(field,graphic,itemPath,region=>{const row=rows.find(row=>row.target.value===region); if(row) row.source.focus();});
  const pictures=node('div',undefined,'graphic-choice-images');
  for (const entry of graphic.gap_images || []) {
    const figure=node('figure'); try { figure.append(packageImage(entry.image,itemPath)); } catch { figure.append(node('span','图像未显示')); }
    figure.append(node('figcaption',sources.find(source=>source.identifier===entry.identifier)?.text || entry.identifier)); pictures.append(figure);
  }
  if (pictures.childNodes.length) field.append(pictures);
  const addRow=(sourceId='',targetId='',countValue=1)=>{
    const row=node('div',undefined,'graphic-pair-row'), source=node('select'),target=node('select'),count=node('input'), remove=node('button','移除');
    source.setAttribute('aria-label','关联的活动'); target.setAttribute('aria-label','图中目标区域'); count.setAttribute('aria-label','此关联的次数');
    source.append(node('option','选择活动')); source.options[0].value='';
    for (const choice of sources) {const option=node('option',choice.text);option.value=choice.identifier;source.append(option);}
    target.append(node('option','选择区域')); target.options[0].value='';
    for (const region of graphic.regions) {const option=node('option',region.label);option.value=region.identifier;target.append(option);}
    source.value=sourceId;target.value=targetId;count.type='number';count.min='1';count.step='1';count.value=String(countValue);remove.type='button';
    const updateLimit=()=>{const a=sources.find(choice=>choice.identifier===source.value)?.match_max||4096,b=graphic.regions.find(region=>region.identifier===target.value)?.match_max||4096;count.max=String(Math.min(a,b,graphic.max_associations||4096));};
    for (const input of [source,target,count]) input.addEventListener('change',()=>{updateLimit();changed();});
    const data={row,source,target,count};rows.push(data); remove.addEventListener('click',()=>{rows.splice(rows.indexOf(data),1);row.remove();changed();});
    row.append(source,target,count,remove);rowContainer.append(row);updateLimit();
  };
  const grouped=new Map();
  for (const pair of Array.isArray(current)?current:[]) grouped.set(pair,(grouped.get(pair)||0)+1);
  if(grouped.size) for(const[pair,count]of grouped){const[source,target]=pair.split(' ');addRow(source,target,count);} else for(const region of graphic.regions)addRow('',region.identifier);
  field.append(rowContainer);
  readers.set(id,()=>{const values=[];for(const row of rows){if(!row.source.value||!row.target.value)continue;const count=Number(row.count.value);if(!Number.isInteger(count)||count<1||count>Number(row.count.max)||values.length+count>4096)throw new Error('关联次数须符合区域和活动的次数上限。');for(let i=0;i<count;i++)values.push(`${row.source.value} ${row.target.value}`);}return values;});
  const add=node('button','添加关联');add.type='button';add.addEventListener('click',()=>{if(rows.length>=4096)return;addRow();changed();});field.append(add);
  field.append(node('small','次数保留重复关联。每项活动、区域及总关联数由题目规则检查。'));
}
function changed() {
  inputDirty = true; jsonDirty = false;
  try { $('response-json').value = JSON.stringify(response(), null, 2); }
  catch (error) { showError(error); }
  $('result').hidden = true; $('feedback').replaceChildren();
  $('status').textContent = '作答已修改，点击“保存作答”写入会话。';
}
function createControl(binding, current, multipleBindings, itemPath) {
  const id = binding.identifier || binding.response_identifier;
  const field = node('fieldset', undefined, 'response-field');
  field.append(node('legend', binding.choice?.prompt || binding.slider?.prompt || binding.inline_choice?.label || (binding.extended_text ? (multipleBindings ? binding.extended_text.prompt : '你的作答') : id)));
  if (binding.graphic) { graphicControl(field,binding,current,itemPath); return field; }
  const choiceList = binding.choice?.choices || binding.inline_choice?.choices || binding.choices;
  if (choiceList?.length && binding.cardinality !== 'ordered' && binding.base_type !== 'directedPair') {
    const multiple = binding.cardinality === 'multiple';
    const inputs = choiceList.map(choice => {
      const label = node('label', undefined, 'answer-option'), input = node('input');
      input.type = multiple ? 'checkbox' : 'radio'; input.name = `answer-${id}`; input.value = choice.identifier;
      input.checked = multiple ? Array.isArray(current) && current.includes(choice.identifier) : current === choice.identifier;
      input.addEventListener('change', changed); label.append(input, node('span', choice.text)); field.append(label); return input;
    });
    readers.set(id, () => multiple ? inputs.filter(input => input.checked).map(input => input.value) : inputs.find(input => input.checked)?.value ?? null);
    const clear = node('button', '清除此项'); clear.type = 'button'; clear.addEventListener('click', () => { inputs.forEach(input => { input.checked = false; }); changed(); }); field.append(clear);
  } else if (binding.slider) {
    const description = binding.slider, pair = node('div', undefined, 'slider-pair');
    const range = node('input'), value = node('input'); range.type = 'range'; value.type = 'number';
    range.min = value.min = description.lower_bound; range.max = value.max = description.upper_bound;
    range.step = value.step = description.step ?? 'any';
    range.setAttribute('aria-label', `${id} 滑杆`); value.setAttribute('aria-label', `${id} 数值`);
    value.value = typeof current === 'number' ? current : ''; range.value = current ?? description.lower_bound;
    range.addEventListener('input', () => { value.value = range.value; changed(); });
    value.addEventListener('input', () => { if (value.value !== '') range.value = value.value; changed(); });
    readers.set(id, () => value.value === '' ? null : Number(value.value)); pair.append(range, value); field.append(pair);
    field.append(node('small', `${description.lower_bound} 至 ${description.upper_bound}${description.step === null ? ' · 连续数值' : ` · 步长 ${description.step}`}`));
    const clear = node('button', '清除此项'); clear.type = 'button'; clear.addEventListener('click', () => { value.value = ''; changed(); }); field.append(clear);
  } else if (binding.cardinality === 'multiple' || binding.cardinality === 'ordered' || binding.base_type === 'directedPair') {
    field.append(node('p', '此响应使用结构化数据，请在下方“编辑响应 JSON”中填写。'));
    readers.set(id, () => current ?? null);
    $('json-details').open = true;
  } else {
    const input = node(binding.extended_text ? 'textarea' : 'input');
    if (input.tagName === 'INPUT') { input.type = ['integer', 'float'].includes(binding.base_type) ? 'number' : 'text'; input.step = binding.base_type === 'integer' ? '1' : 'any'; }
    if (binding.extended_text) {
      input.rows = Math.max(2, Math.min(30, binding.extended_text.expected_lines || 5));
      if (binding.extended_text.format === 'preformatted') input.style.whiteSpace = 'pre';
    }
    input.setAttribute('aria-label', id); input.placeholder = binding.extended_text?.placeholder || binding.placeholder || '填写作答'; input.value = current ?? '';
    input.addEventListener('input', changed); field.append(input);
    readers.set(id, () => input.value === '' ? null : ['integer', 'float'].includes(binding.base_type) ? Number(input.value) : input.value);
  }
  return field;
}
function response() { return Object.fromEntries([...readers].map(([id, read]) => [id, read()])); }
function action(type, extra = {}) {
  const time = clock(); const next = session.act({ type, time, ...extra }); lastAction = time;
  state = next; inputDirty = false; render(); return next;
}
function save() { action('save', { response: jsonDirty ? JSON.parse($('response-json').value) : response() }); status('作答已保存到当前会话。'); }
function render() {
  const part = planDescription.parts.find(entry => entry.identifier === state.part_identifier);
  const entry = planDescription.entries.find(entry => entry.identifier === state.current.identifier);
  const current = state.current, item = current.item;
  const currentIndex = state.items.findIndex(summary => summary.identifier === current.identifier);
  $('test-title').textContent = planDescription.title;
  $('part-label').textContent = `${state.part_identifier} · ${part.submission_mode === 'simultaneous' ? '整部分提交' : '逐题提交'}`;
  $('session-info').textContent = `${state.session_identifier} · ${state.completed ? '已完成' : state.paused ? '已暂停' : '进行中'} · 已用 ${Math.floor(state.part_elapsed)} 秒${part.max_time === null ? '' : ` / ${part.max_time} 秒`}`;
  $('item-position').textContent = `QUESTION ${currentIndex + 1} / ${state.items.length} · ${current.identifier}`;
  $('item-title').textContent = item.title;
  $('item-prompt').textContent = item.passage?.length ? item.passage.map(part => 'text' in part ? part.text : `（${part.response}）`).join('') : item.prompt || '';
  $('response-json').value = JSON.stringify(current.response, null, 2);
  clearImages(); readers = new Map(); jsonDirty = false; $('response-controls').replaceChildren();
  const bindings = item.responses || [{ ...item, identifier: item.response_identifier }];
  for (const binding of bindings) $('response-controls').append(createControl(binding, current.response[binding.identifier], bindings.length > 1, entry.path));
  const locked = state.completed || state.paused || (current.submitted && entry.control.max_attempts !== 0 && current.num_attempts >= entry.control.max_attempts);
  for (const field of $('response-controls').querySelectorAll('fieldset')) field.disabled = locked;
  for (const region of $('response-controls').querySelectorAll('[data-graphic-region]')) { region.setAttribute('tabindex',locked?'-1':'0'); region.setAttribute('aria-disabled',String(locked)); }
  $('response-json').disabled = locked;
  $('save-response').disabled = $('save-json').disabled = locked;
  $('submit-response').disabled = locked || part.submission_mode === 'simultaneous';
  $('next-item').disabled = state.completed || state.paused || currentIndex + 1 >= state.items.length || state.items[currentIndex + 1].part_identifier !== state.part_identifier;
  $('finish-part').disabled = state.completed || state.paused;
  $('pause-test').disabled = state.completed; $('pause-test').textContent = state.paused ? '继续作答' : '暂停';
  $('download-snapshot').disabled = false;
  $('item-nav').replaceChildren(...state.items.map((summary, index) => {
    const button = node('button', String(index + 1)); button.type = 'button';
    button.title = `${summary.identifier}${summary.submitted ? ' · 已提交' : summary.answered ? ' · 已作答' : ' · 未作答'}`;
    button.setAttribute('aria-label', `第 ${index + 1} 题，${summary.submitted ? '已提交' : summary.answered ? '已作答' : '未作答'}`);
    if (summary.identifier === current.identifier) button.setAttribute('aria-current', 'step');
    button.dataset.submitted = String(summary.submitted);
    const targetControl = planDescription.entries[index].control;
    const reviewBlocked = summary.submitted && !targetControl.allow_review && targetControl.max_attempts !== 0 && summary.num_attempts >= targetControl.max_attempts;
    button.disabled = state.completed || state.paused || reviewBlocked || part.navigation_mode !== 'nonlinear' || summary.part_identifier !== state.part_identifier;
    button.addEventListener('click', () => run(() => { if (inputDirty) save(); action('select', { identifier: summary.identifier }); status('已切换题目。'); })); return button;
  }));
  $('result').hidden = !current.result || (part.submission_mode === 'simultaneous' && !state.completed);
  if (!$('result').hidden) $('result').textContent = `本题得分：${current.result.score}`;
  $('feedback').replaceChildren();
  if (part.submission_mode !== 'simultaneous' || state.completed) {
    for (const feedback of current.feedback || []) $('feedback').append(node('p', typeof feedback === 'string' ? feedback : feedback.text || JSON.stringify(feedback)));
  }
  $('completion').hidden = !state.completed;
  if (state.completed) {
    const { report } = session.exportResult(new Date().toISOString());
    $('completion').querySelector('h2').textContent = report.has_errors ? '已交卷，部分评分处理失败' : report.all_items_scored === false ? '已交卷，仍有待评项目' : '测验已完成';
    $('completion').querySelectorAll('p')[1].textContent = report.has_errors ? '作答记录已保存。下载结果 JSON 可查看具体处理错误；分值按作者结果规则记录。' : report.all_items_scored === false ? '作答记录已保存，仍有待评项目。分值按作者结果规则记录，可下载标准结果继续处理。' : '全部评分已完成。可下载 QTI 结果 XML 与完整 JSON 记录。';
    $('outcome-summary').textContent = JSON.stringify(report.outcomes, null, 2);
  }
}

async function loadBuiltin(filename) {
  status('正在载入演示试卷…'); const result = await fetch(filename);
  if (!result.ok) throw new Error('演示包加载失败，请先构建前端资源。');
  await loadPackage(new Uint8Array(await result.arrayBuffer()));
}
$('load-sample').addEventListener('click', () => runAsync(() => loadBuiltin('runtime-test-package.zip')));
$('load-feedback-sample').addEventListener('click', () => runAsync(() => loadBuiltin('feedback-test-package.zip')));
$('load-graphic-sample').addEventListener('click', () => runAsync(() => loadBuiltin('graphic-test-package.zip')));
$('package-file').addEventListener('change', event => runAsync(async () => {
  const file = event.target.files[0]; if (!file) return;
  if (file.size > 8 * 1048576) throw new Error('ZIP 内容包超过 8 MiB。');
  await loadPackage(new Uint8Array(await file.arrayBuffer()));
}));
$('open-test').addEventListener('click', () => run(openPlan));
$('start-test').addEventListener('click', () => run(() => {
  const next = plan.startSession($('session-id').value); disposeSession(); session = next;
  clockBase = lastAction = 0; clockOrigin = performance.now(); state = session.describe(); inputDirty = false;
  render(); status('会话已开始。作答后先保存，再按照当前部分的模式提交。');
}));
$('save-response').addEventListener('click', () => run(save));
$('save-json').addEventListener('click', () => run(() => { action('save', { response: JSON.parse($('response-json').value) }); status('JSON 响应已保存。'); }));
$('response-json').addEventListener('input', () => {
  inputDirty = true; jsonDirty = true;
  $('result').hidden = true; $('feedback').replaceChildren();
  $('status').textContent = 'JSON 已修改，点击“保存 JSON 响应”写入会话。';
});
$('submit-response').addEventListener('click', () => run(() => { if (inputDirty) save(); action('submit'); status('本题已提交。'); }));
$('next-item').addEventListener('click', () => run(() => { if (inputDirty) save(); action('next'); status('已进入下一题。'); }));
$('finish-part').addEventListener('click', () => run(() => { if (inputDirty) save(); action('finish_part'); status(state.completed ? '测验已完成，可以导出标准结果。' : '当前部分已完成，已进入下一部分。'); }));
$('pause-test').addEventListener('click', () => run(() => { if (inputDirty) save(); action(state.paused ? 'resume' : 'pause'); status(state.paused ? '会话已暂停。可以下载快照，稍后恢复。' : '已继续作答。'); }));
$('download-snapshot').addEventListener('click', () => run(() => { if (inputDirty) save(); download('qti-session.json', session.snapshot(), 'application/json'); status('会话快照已下载。'); }));
$('snapshot-file').addEventListener('change', event => runAsync(async () => {
  const file = event.target.files[0]; if (!file) return;
  if (file.size > 8 * 1048576) throw new Error('会话快照超过 8 MiB。');
  const snapshot = await file.text(), next = plan.restoreSession(snapshot);
  disposeSession(); session = next; syncClock(snapshot); state = session.describe(); inputDirty = false;
  $('session-id').value = state.session_identifier; render(); status('会话已从快照恢复。');
}));
for (const format of ['xml', 'json']) $(`export-${format}`).addEventListener('click', () => run(() => {
  const { report, xml } = session.exportResult(new Date().toISOString());
  download(`qti-result.${format}`, format === 'xml' ? xml : JSON.stringify(report, null, 2), format === 'xml' ? 'application/xml' : 'application/json');
  status(`结果 ${format.toUpperCase()} 已下载。`);
}));
setInterval(() => {
  if (!session || !state || state.paused || state.completed) return;
  const part = planDescription.parts.find(entry => entry.identifier === state.part_identifier);
  const elapsed = state.part_elapsed + (clock() - lastAction);
  $('session-info').textContent = `${state.session_identifier} · 进行中 · 已用 ${Math.floor(elapsed)} 秒${part.max_time === null ? '' : ` / ${part.max_time} 秒`}`;
  if (part.max_time !== null && elapsed >= part.max_time) run(() => { action('tick'); status('当前部分时间已到，内核已处理保存的响应。'); });
}, 1000);
window.addEventListener('beforeunload', () => { clearImages(); disposePlan(); bundle?.dispose(); });
