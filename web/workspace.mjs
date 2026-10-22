const $ = id => document.getElementById(id);

export function downloadText(content, filename, type = 'application/json;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function createWorkspace() {
  $('editor-mount').append($('editor-template').content.cloneNode(true));
  const views = { workbench: '题目工作台', package: '题包资源', results: '结果分析' };
  const records = [];
  const sourcePanel = document.querySelector('.source-panel');
  sourcePanel.hidden = true;

  function show(view) {
    if (!Object.hasOwn(views, view)) return;
    for (const name of Object.keys(views)) $(`view-${name}`).hidden = name !== view;
    for (const button of document.querySelectorAll('button[data-view]')) {
      if (button.dataset.view === view) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    }
    $('view-label').textContent = views[view];
    window.scrollTo({ top: 0, behavior: 'auto' });
  }
  for (const button of document.querySelectorAll('button[data-view], button[data-go]')) {
    button.addEventListener('click', () => show(button.dataset.view || button.dataset.go));
  }

  const examples = [...document.querySelectorAll('[data-example]')];
  $('example-search').addEventListener('input', () => {
    const query = $('example-search').value.trim().toLocaleLowerCase();
    let visible = 0;
    for (const button of examples) {
      button.hidden = !`${button.textContent} ${button.dataset.example}`.toLocaleLowerCase().includes(query);
      if (!button.hidden) ++visible;
    }
    $('example-count').textContent = `${visible} / ${examples.length} 道`;
    $('example-empty').hidden = visible > 0;
  });
  $('toggle-source').addEventListener('click', () => {
    sourcePanel.hidden = !sourcePanel.hidden;
    $('editor-mount').classList.toggle('source-visible', !sourcePanel.hidden);
    $('toggle-source').setAttribute('aria-pressed', String(!sourcePanel.hidden));
    $('toggle-source').textContent = sourcePanel.hidden ? '查看 XML' : '收起 XML';
  });
  $('download-xml').addEventListener('click', () => downloadText($('xml-source').value, 'qti-item.xml', 'application/xml;charset=utf-8'));

  function renderHistory() {
    const list = $('score-history');
    list.replaceChildren();
    for (const record of [...records].reverse()) {
      const row = document.createElement('li');
      const detail = document.createElement('div');
      const title = document.createElement('strong');
      title.textContent = record.title;
      const response = document.createElement('code');
      response.textContent = JSON.stringify(record.response);
      const state = document.createElement('small');
      state.textContent = `${record.item_id} · ${record.result.status === 'unanswered' ? '未作答' : '已作答'}`;
      detail.append(title, response, state);
      const score = document.createElement('span');
      score.className = 'history-score';
      score.textContent = `${record.result.score} 分`;
      row.append(detail, score);
      list.append(row);
    }
    $('history-empty').hidden = records.length > 0;
    $('clear-history').disabled = !records.length;
    $('download-history').disabled = !records.length;
  }
  $('clear-history').addEventListener('click', () => { records.length = 0; renderHistory(); });
  $('download-history').addEventListener('click', () => downloadText(JSON.stringify({
    format: 'qti-score-session-v1', records,
  }, null, 2) + '\n', 'qti-score-session.json'));

  return {
    show,
    setItem(description) { $('workspace-item').textContent = description?.title || '题目预览'; },
    record(description, response, result) {
      records.push(JSON.parse(JSON.stringify({ created_at: new Date().toISOString(),
        item_id: description.identifier, title: description.title, response, result })));
      if (records.length > 20) records.shift();
      renderHistory();
    },
  };
}
