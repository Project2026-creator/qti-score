const $ = id => document.getElementById(id);

export function createBatchPanel() {
  let bundle;
  let result;
  let revision = 0;
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
    $('batch-rows').replaceChildren();
    $('attempt-summaries').replaceChildren();
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

  function render(report) {
    $('batch-summary').textContent = `${report.row_count} 条记录 · ${report.scored_count} 条评分成功 · ${report.error_count} 条错误 · ${report.unassigned_count} 条未归属作答`;
    for (const entry of report.rows) {
      const location = entry.error?.location;
      const diagnostic = entry.error ? `${entry.error.code} · ${entry.error.message}` +
        (location ? `（XML ${location.line}:${location.column}）` : '') : '';
      tableRow($('batch-rows'), [entry.line, entry.attempt_id, entry.resource_id,
        entry.ok ? (entry.result.status === 'unanswered' ? '未作答' : '已作答') : '错误',
        entry.result?.score, diagnostic]);
    }
    for (const attempt of report.attempts) {
      tableRow($('attempt-summaries'), [attempt.attempt_id,
        `${attempt.scored_count} / ${attempt.row_count}`, attempt.error_count, attempt.score_sum,
        attempt.sum_error ? attempt.sum_error.message : attempt.all_rows_scored ? '所提交行均已评分' : '含失败行，当前为部分汇总']);
    }
    $('batch-results').hidden = false;
    $('download-json').disabled = false;
    $('download-csv').disabled = false;
  }

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
    const response = await fetch('../examples/package-attempts.jsonl');
    if (!response.ok) throw new Error('示例作答载入失败');
    return response.text();
  }, 'package-attempts.jsonl'));

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
    const content = format === 'json' ? JSON.stringify(result.report, null, 2) + '\n' : '\uFEFF' + result.csv;
    const blob = new Blob([content], { type: format === 'json' ? 'application/json;charset=utf-8' : 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `qti-score-results.${format}`;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  $('download-json').addEventListener('click', () => download('json'));
  $('download-csv').addEventListener('click', () => download('csv'));

  return {
    setPackage(next, identifier = '') {
      ++revision;
      bundle = next;
      clearResult();
      $('run-batch').disabled = !bundle;
      $('batch-package').textContent = bundle ? `当前题包：${identifier}` : '请先导入题包，再进行批量评分。';
    },
  };
}
