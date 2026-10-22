import test from 'node:test';
import assert from 'node:assert/strict';
import { selectRows, formatScore } from './results.mjs';

const rows = [
  { line: 2, attempt_id: '学生甲', resource_id: 'choice', ok: true, result: { status: 'answered', score: -1 } },
  { line: 4, attempt_id: 'Student-B', resource_id: 'choice', ok: true, result: { status: 'unanswered', score: 0 } },
  { line: 6, attempt_id: null, resource_id: 'number', ok: false, error: { code: 'invalid_response', message: 'Integer required' } },
];
test('view filters combine status, resource and case-insensitive text without replacing errors with zero', () => {
  assert.deepEqual(selectRows(rows, { query: 'INTEGER', status: 'error', resource: 'number' }).rows, [rows[2]]);
  assert.equal(selectRows(rows, { status: 'answered', query: '学生' }).rows[0].result.score, -1);
  assert.equal(selectRows(rows, { query: 'student-b', status: 'unanswered' }).count, 1);
  assert.equal(selectRows(rows, { status: 'error', resource: 'choice' }).count, 0);
});
test('pagination preserves physical input lines and clamps stale pages', () => {
  assert.deepEqual(selectRows(rows, { pageSize: 2, page: 1 }).rows.map(row => row.line), [6]);
  assert.equal(selectRows(rows, { page: 8, pageSize: 2, status: 'answered' }).page, 0);
  assert.equal(selectRows(rows, { page: -1, pageSize: 2 }).start, 1);
});
test('empty views retain consistent navigation and export data remains unchanged', () => {
  const before = JSON.stringify(rows);
  const view = selectRows(rows, { query: '<script>' });
  assert.deepEqual([view.count, view.start, view.page, view.pages], [0, 0, 0, 1]);
  view.rows.push({});
  assert.equal(JSON.stringify(rows), before);
});
test('score formatting distinguishes missing from zero, preserves sign and finite extremes', () => {
  assert.equal(formatScore(null), '—');
  assert.equal(formatScore(0), '0');
  assert.equal(formatScore(-1.5), '-1.5');
  assert.equal(formatScore(1 / 3), '0.33333333');
  assert.equal(Number(formatScore(1e308)), 1e308);
});
