import { compileItem, evaluateItem, describeItem, importPackage, QtiScoreError } from './index.mjs';
import type { Score, Explanation, BatchResult, ResponseObject, ItemDescription } from './index.mjs';

const item = compileItem('<xml/>');
const response: ResponseObject = { RESPONSE: ['A', 'B'] as const };
const score: Score = item.score(response);
const explanation: Explanation = item.explain({ RESPONSE: 100.5 });
const batch: BatchResult[] = item.scoreBatch([response, {}, { RESPONSE: null }] as const);
const metadata: ItemDescription = describeItem('<xml/>');
if (metadata.cardinality === 'ordered') {
  const firstChoice: string = metadata.choices[0].identifier;
  void firstChoice;
}
const oneShot: Score = evaluateItem('<xml/>', { RESPONSE: 'A' });
for (const row of batch) {
  if (row.ok) { const value: number = row.result.score; void value; }
  else { const code: string = row.error.code; void code; }
}
// @ts-expect-error boolean responses are not part of the supported API
item.score({ RESPONSE: true });
// @ts-expect-error response members must be strings, not numeric arrays
item.score({ RESPONSE: [1, 2] });
// @ts-expect-error compiled item disposal state is read-only
item.disposed = false;
// @ts-expect-error scores are read-only values
score.score = 99;
const error: Error = new QtiScoreError({ code: 'invalid_response', message: 'bad', location: null });
void [score, explanation, metadata, oneShot, error];
item.dispose();
const bundle = importPackage(new Uint8Array());
for (const entry of bundle.describe().items) {
  if (entry.status === 'ready') { const title: string = entry.item.title; void title; }
  else { const code: string = entry.error.code; void code; }
}
const files: string[] = bundle.resourceFiles('resource-id');
const bytes: Uint8Array = bundle.readFile(files[0]);
const evaluation = bundle.scoreAttempts('');
const csv: string = evaluation.csv;
for (const row of evaluation.report.rows) {
  if (row.ok) { const value: number = row.result.score; void value; }
  else { const code: string = row.error.code; void code; }
}
const sum: number | null = evaluation.report.attempts[0]?.score_sum ?? null;
// @ts-expect-error raw JSONL must be a string
bundle.scoreAttempts([]);
// @ts-expect-error report counters are read-only
evaluation.report.scored_count = 0;
void [csv, sum];
bundle.getItem('resource-id').dispose();
// @ts-expect-error ZIP input must be bytes
importPackage('archive.zip');
// @ts-expect-error disposal state is read-only
bundle.disposed = false;
void bytes;
bundle.dispose();
