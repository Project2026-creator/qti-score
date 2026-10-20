export type ResponseObject = { RESPONSE?: string | number | readonly string[] | null };
export interface SourceLocation { readonly line: number; readonly column: number }
export interface ErrorDetail { readonly code: string; readonly message: string; readonly location: SourceLocation | null }
export interface Score {
  readonly score: number;
  readonly status: 'answered' | 'unanswered';
  readonly matches_correct: boolean | null;
}
export interface Choice { readonly identifier: string; readonly text: string }
export interface ItemDescription {
  readonly identifier: string;
  readonly title: string;
  readonly response_identifier: 'RESPONSE';
  readonly cardinality: 'single' | 'multiple';
  readonly base_type: 'identifier' | 'string' | 'integer' | 'float';
  readonly template: 'match_correct' | 'map_response' | 'numeric_rules';
  readonly prompt: string;
  readonly min_choices: number;
  readonly max_choices: number;
  readonly choices: readonly Choice[];
}
export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue };
export interface ScoringStep {
  readonly operation: 'response' | 'null_response' | 'match_correct' | 'duplicate_ignored' | 'map_value' | 'mapping_bounds' | 'numeric_condition' | 'set_score';
  readonly location: SourceLocation;
  readonly details: Readonly<Record<string, JsonValue>>;
}
export interface Explanation { readonly result: Score; readonly steps: readonly ScoringStep[] }
export type BatchResult =
  | { readonly index: number; readonly ok: true; readonly result: Score }
  | { readonly index: number; readonly ok: false; readonly error: ErrorDetail };
export class QtiScoreError extends Error {
  constructor(detail: ErrorDetail);
  readonly name: 'QtiScoreError';
  readonly code: string;
  readonly location: SourceLocation | null;
}
export interface CompiledItem {
  readonly disposed: boolean;
  describe(): ItemDescription;
  score(response: ResponseObject): Score;
  explain(response: ResponseObject): Explanation;
  scoreBatch(responses: readonly ResponseObject[]): BatchResult[];
  dispose(): void;
}
export function compileItem(xml: string): CompiledItem;
export function evaluateItem(xml: string, response: ResponseObject): Score;
export function describeItem(xml: string): ItemDescription;
