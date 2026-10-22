import { downloadText } from './workspace.mjs';
import { selectRows, formatScore } from './results.mjs';

const $ = id => document.getElementById(id);

export function createBatchPanel() {
  let bundle;
  let result;
  let revision = 0;
  let page = 0;
  let sampleSource = null;
  const source = $('batch-source');

  function showError(error) {
    $('batch-error').hidden = !error;
    $('batch-error').textContent = error ? `${error.code || 'error'} · ${error.message || String(error)}` : '';
  }

  function clearResult() {
    result = null;
    $('batch-results').hidden = true;
    $('download-json').disabled = true;
    $('download-csv').disabled = true;
    $('download-items-csv').disabled = true;
    $('batch-rows').replaceChildren();
    $('attempt-summaries').replaceChildren();
    $('item-summaries').replaceChildren();
    $('item-chart').replaceChildren();
    $('row-search').value = '';
    $('row-status').value = 'all';
    $('row-resource').replaceChildren(new Option('全部资源', ''));
    page = 0;
    for (const id of ['metric-total', 'metric-scored', 'metric-errors', 'metric-unanswered', 'nav-result-count']) $(id).textContent = '—';
    showError(null);
  }

  function tableRow(parent, cells) {
    const row = document.createElement('tr');
    for (const value of cells) {
      const cell = document.createElement('td');
      cell.textContent = String(value ?? '—');
      row.append(cell);
    }
    parent.append(row);
  }

  function renderRows() {
    if (!result) return;
    const view = selectRows(result.report.rows, { query: $('row-search').value,
      status: $('row-status').value, resource: $('row-resource').value, page });
    page = view.page;
    const rows = document.createDocumentFragment();
    for (const entry of view.rows) {
      const location = entry.error?.location;
      const diagnostic = entry.error ? `${entry.error.code} · ${entry.error.message}` +
        (location ? `（XML ${location.line}:${location.column}）` : '') : '';
      tableRow(rows, [entry.line, entry.attempt_id, entry.resource_id,
        entry.ok ? (entry.result.status === 'unanswered' ? '未作答' : '已作答') : '错误',
        entry.result?.score, diagnostic]);
    }
    $('batch-rows').replaceChildren(rows);
    $('row-range').textContent = view.count ? `${view.start}–${view.start + view.rows.length - 1} / ${view.count} 条 · 第 ${page + 1} 页` : '没有匹配的评分记录';
    $('previous-rows').disabled = page === 0;
    $('next-rows').disabled = page + 1 >= view.pages;
  }

  function render(report) {
    $('metric-total').textContent = report.row_count;
    $('metric-scored').textContent = report.scored_count;
    $('metric-errors').textContent = report.error_count;
    $('metric-unanswered').textContent = report.unanswered_count;
    $('nav-result-count').textContent = report.row_count;
    $('batch-summary').textContent = `${report.row_count} 条记录 · ${report.scored_count} 条评分成功 · ${report.error_count} 条错误 · ${report.unassigned_count} 条未归属作答 · ${report.unassigned_resource_count} 条未归属题目`;
    const itemRows = document.createDocumentFragment();
    for (const item of report.items) {
      $('row-resource').append(new Option(item.resource_id, item.resource_id));
      tableRow(itemRows, [item.resource_id, `${item.scored_count} / ${item.row_count}`, item.error_count,
        item.unanswered_count, formatScore(item.score_mean), formatScore(item.score_min), formatScore(item.score_max),
        `${item.matched_count} / ${item.scored_count}（未声明 ${item.unclassified_count}）`]);
    }
    $('item-summaries').replaceChildren(itemRows);
    for (const item of report.items.slice(0, 12)) {
      const row = document.createElement('div'); row.className = 'chart-row';
      const label = document.createElement('span'); label.textContent = item.resource_id;
      const bar = document.createElement('div'); bar.className = 'chart-bar';
      bar.setAttribute('role', 'img');
      bar.setAttribute('aria-label', `${item.resource_id}：${item.answered_count} 条已作答，${item.unanswered_count} 条未作答，${item.error_count} 条错误`);
      for (const [state, count] of [['answered', item.answered_count], ['unanswered', item.unanswered_count], ['error', item.error_count]]) {
        const segment = document.createElement('span'); segment.className = `bar-${state}`;
        segment.style.width = `${count / item.row_count * 100}%`; bar.append(segment);
      }
      const count = document.createElement('small'); count.textContent = `${item.row_count} 条`;
      row.append(label, bar, count); $('item-chart').append(row);
    }
    const note = document.createElement('p'); note.className = 'batch-help';
    note.textContent = report.items.length ? '图示按首次出现顺序展示前 12 项；完整逐题统计见下表与 CSV。' : '暂无可归属题目的记录。';
    $('item-chart').append(note);
    for (const attempt of report.attempts) {
      tableRow($('attempt-summaries'), [attempt.attempt_id,
        `${attempt.scored_count} / ${attempt.row_count}`, attempt.error_count, attempt.score_sum,
        attempt.sum_error ? attempt.sum_error.message : attempt.all_rows_scored ? '所提交行均已评分' : '含失败行，当前为部分汇总']);
    }
    $('batch-results').hidden = false;
    $('download-json').disabled = false;
    $('download-csv').disabled = false;
    $('download-items-csv').disabled = false;
    renderRows();
  }

  for (const id of ['row-search', 'row-status', 'row-resource']) {
    $(id).addEventListener(id === 'row-search' ? 'input' : 'change', () => { page = 0; renderRows(); });
  }
  $('previous-rows').addEventListener('click', () => { --page; renderRows(); });
  $('next-rows').addEventListener('click', () => { ++page; renderRows(); });

  source.addEventListener('input', () => {
    ++revision;
    clearResult();
    $('batch-filename').textContent = '已编辑 JSONL';
  });

  $('run-batch').addEventListener('click', () => {
    ++revision;
    clearResult();
    if (!bundle) return;
    try {
      result = bundle.scoreAttempts(source.value);
      render(result.report);
    } catch (error) { showError(error); }
  });

  async function loadSource(readText, name) {
    const request = ++revision;
    clearResult();
    try {
      const text = await readText();
      if (request !== revision) return;
      if (text.length > 4194304) throw { code: 'limit_exceeded', message: '作答内容超过 4,194,304 个码元。' };
      source.value = text;
      $('batch-filename').textContent = name;
    } catch (error) { if (request === revision) showError(error); }
  }

  $('sample-attempts').addEventListener('click', () => loadSource(async () => {
    if (!sampleSource) throw new Error('请导入与当前题包对应的作答。');
    const response = await fetch(`../examples/${sampleSource}`);
    if (!response.ok) throw new Error('示例作答载入失败');
    return response.text();
  }, sampleSource || ''));

  $('open-attempts').addEventListener('click', () => $('attempts-input').click());
  $('attempts-input').addEventListener('change', event => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    loadSource(async () => {
      if (file.size > 16 * 1048576) throw { code: 'limit_exceeded', message: '作答文件超过 16 MiB 读取上限。' };
      return new TextDecoder('utf-8', { fatal: true }).decode(await file.arrayBuffer());
    }, file.name);
  });

  function download(format) {
    if (!result) return;
    const content = format === 'json' ? JSON.stringify(result.report, null, 2) + '\n' : '\uFEFF' + (format === 'items' ? result.itemsCsv : result.csv);
    downloadText(content, format === 'items' ? 'qti-score-items.csv' : `qti-score-results.${format}`,
      format === 'json' ? 'application/json;charset=utf-8' : 'text/csv;charset=utf-8');
  }
  $('download-json').addEventListener('click', () => download('json'));
  $('download-csv').addEventListener('click', () => download('csv'));
  $('download-items-csv').addEventListener('click', () => download('items'));

  return {
    setPackage(next, identifier = '', nextSample = null) {
      ++revision;
      bundle = next;
      sampleSource = nextSample;
      $('sample-attempts').disabled = !next || !sampleSource;
      clearResult();
      $('run-batch').disabled = !bundle;
      $('batch-package').textContent = bundle ? `当前题包：${identifier}` : '请先导入题包，再进行批量评分。';
    },
  };
}
