import { compileItem, evaluateItem, describeItem, importPackage, QtiScoreError } from './index.mjs';
import type { Score, Explanation, BatchResult, ResponseObject, ItemDescription } from './index.mjs';

const item = compileItem('<xml/>');
const response: ResponseObject = { RESPONSE: ['A', 'B'] as const };
const score: Score = item.score(response);
const explanation: Explanation = item.explain({ RESPONSE: 100.5 });
const batch: BatchResult[] = item.scoreBatch([response, {}, { RESPONSE: null }] as const);
const metadata: ItemDescription = describeItem('<xml/>');
if (metadata.kind === 'composite') {
  const id: string = metadata.responses[0].identifier;
  const multi: ResponseObject = { PLATFORM: 'LMS', COUNT: 4 };
  for (const binding of metadata.responses) {
    if (binding.cardinality === 'multiple') {
      const limits: readonly number[] = [binding.choice.min_choices, binding.choice.max_choices];
      const selections: ResponseObject = { [binding.identifier]: ['Evidence', 'Feedback'] as const };
      // @ts-expect-error multiple choice limits are immutable
      binding.choice.min_choices = 0;
      void [limits, selections];
    }
    if (binding.slider) {
      const kind: 'integer' | 'float' = binding.base_type;
      const bounds: readonly number[] = [binding.slider.lower_bound, binding.slider.upper_bound];
      const prompt: string = binding.slider.prompt;
      // @ts-expect-error slider metadata is immutable
      binding.slider.step = 1;
      void [kind, bounds, prompt];
    } else if (binding.inline_choice) {
      const required: boolean = binding.inline_choice.required;
      const choice: string = binding.inline_choice.choices[0].identifier;
      // @ts-expect-error composite choice metadata is immutable
      binding.inline_choice.choices[0].identifier = 'changed';
      void [required, choice];
    } else if (binding.choice) {
      const required: boolean = binding.choice.required;
      const orientation: 'horizontal' | 'vertical' = binding.choice.orientation;
      const option: string = binding.choice.choices[0].identifier;
      // @ts-expect-error choice metadata is immutable
      binding.choice.choices[0].identifier = 'changed';
      void [required, orientation, option];
    } else {
      const entryType: 'string' | 'integer' | 'float' = binding.base_type;
      void entryType;
    }
  }
  // @ts-expect-error composite descriptions do not expose single-item choices
  metadata.choices[0];
  void [id, multi];
}
if (metadata.slider) {
  const step: number | null = metadata.slider.step;
  const orientation: 'horizontal' | 'vertical' = metadata.slider.orientation;
  const reverse: boolean = metadata.slider.reverse;
  const lower: number = metadata.slider.lower_bound;
  // @ts-expect-error slider metadata is read-only
  metadata.slider.lower_bound = -1;
  void [step, orientation, reverse, lower];
}
if (metadata.inline_choice) {
  for (const part of metadata.inline_choice.passage) {
    const text: string = 'text' in part ? part.text : part.response;
    void text;
  }
  const required: boolean = metadata.inline_choice.required;
  const label: string = metadata.inline_choice.label;
  const placeholder: string = metadata.inline_choice.placeholder;
  // @ts-expect-error inline metadata is read-only
  metadata.inline_choice.required = false;
  void [required, label, placeholder];
}
if (metadata.hottext) {
  for (const part of metadata.hottext.passage) {
    const text: string = 'text' in part ? part.text : part.choice;
    void text;
  }
  const instructions: readonly string[] = metadata.instructions ?? [];
  void instructions;
}
if (metadata.gap_matching) {
  for (const part of metadata.gap_matching.passage) {
    const text: string = 'text' in part ? part.text : part.gap;
    void text;
  }
}
if (metadata.base_type === 'directedPair' && metadata.matching) {
  const limit: number = metadata.matching.sets[0][0].match_max;
  const pair: ResponseObject = { RESPONSE: ['Quiz Diagnose'] };
  void [limit, pair];
}
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
const itemsCsv: string = evaluation.itemsCsv;
for (const summary of evaluation.report.items) {
  const mean: number | null = summary.score_mean;
  const id: string = summary.resource_id;
  // @ts-expect-error item summaries are read-only result values
  summary.score_mean = 12;
  void [mean, id, itemsCsv];
}
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
