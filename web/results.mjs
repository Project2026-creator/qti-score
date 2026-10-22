/** Filter a report view without mutating the scored batch or export data. */
export function selectRows(rows, { query = '', status = 'all', resource = '', page = 0, pageSize = 50 } = {}) {
  const needle = query.trim().toLocaleLowerCase();
  const filtered = rows.filter(row => {
    const state = row.ok ? row.result.status : 'error';
    return (status === 'all' || state === status) && (!resource || row.resource_id === resource) &&
      (!needle || [row.attempt_id, row.resource_id, row.item_id, row.error?.code, row.error?.message]
        .some(value => String(value ?? '').toLocaleLowerCase().includes(needle)));
  });
  const last = Math.max(0, Math.ceil(filtered.length / pageSize) - 1);
  const current = Math.min(Math.max(0, page), last);
  return { rows: filtered.slice(current * pageSize, (current + 1) * pageSize),
    count: filtered.length, page: current, pages: last + 1, start: filtered.length ? current * pageSize + 1 : 0 };
}

export function formatScore(value) {
  if (value === null || value === undefined) return '—';
  return Number.isInteger(value) ? String(value) : Number(value.toPrecision(8)).toString();
}
