import { compileItem, evaluateItem, describeItem, QtiScoreError } from './index.mjs';
import type { Score, Explanation, BatchResult, ResponseObject, ItemDescription } from './index.mjs';

const item = compileItem('<xml/>');
const response: ResponseObject = { RESPONSE: ['A', 'B'] as const };
const score: Score = item.score(response);
const explanation: Explanation = item.explain({ RESPONSE: 100.5 });
const batch: BatchResult[] = item.scoreBatch([response, {}, { RESPONSE: null }] as const);
const metadata: ItemDescription = describeItem('<xml/>');
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
