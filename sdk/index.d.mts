export type ResponseValue = string | number | readonly string[] | null;
export type ResponseObject = Readonly<Partial<Record<string, ResponseValue>>>;
export interface SourceLocation { readonly line: number; readonly column: number }
export interface ErrorDetail { readonly code: string; readonly message: string; readonly location: SourceLocation | null }
export interface Score {
  readonly score: number;
  readonly status: 'answered' | 'unanswered';
  readonly matches_correct: boolean | null;
}
export interface Choice { readonly identifier: string; readonly text: string }
export interface MatchChoice extends Choice { readonly match_min: number; readonly match_max: number }
export interface MatchDescription {
  readonly min_associations: number;
  readonly max_associations: number;
  readonly sets: readonly [readonly MatchChoice[], readonly MatchChoice[]];
}
export type GapPassagePart = { readonly text: string } | { readonly gap: string };
export interface GapMatchDescription extends MatchDescription { readonly passage: readonly GapPassagePart[] }
export type HottextPassagePart = { readonly text: string } | { readonly choice: string };
export interface HottextDescription { readonly passage: readonly HottextPassagePart[] }
export type InlineChoicePassagePart = { readonly text: string } | { readonly response: 'RESPONSE' };
export interface InlineChoiceDescription {
  readonly passage: readonly InlineChoicePassagePart[];
  readonly required: boolean;
  readonly label: string;
  readonly placeholder: string;
}
export interface SliderDescription {
  readonly lower_bound: number;
  readonly upper_bound: number;
  readonly step: number | null;
  readonly step_label: boolean;
  readonly orientation: 'horizontal' | 'vertical';
  readonly reverse: boolean;
}
export interface SingleItemDescription {
  readonly kind?: 'single';
  readonly identifier: string;
  readonly title: string;
  readonly response_identifier: 'RESPONSE';
  readonly cardinality: 'single' | 'multiple' | 'ordered';
  readonly base_type: 'identifier' | 'string' | 'integer' | 'float' | 'directedPair';
  readonly template: 'match_correct' | 'map_response' | 'numeric_rules';
  readonly prompt: string;
  readonly min_choices: number;
  readonly max_choices: number;
  readonly choices: readonly Choice[];
  readonly matching?: MatchDescription;
  readonly gap_matching?: GapMatchDescription;
  readonly hottext?: HottextDescription;
  readonly inline_choice?: InlineChoiceDescription;
  readonly slider?: SliderDescription;
  readonly instructions?: readonly string[];
}
export interface CompositeItemDescription {
  readonly kind: 'composite';
  readonly identifier: string;
  readonly title: string;
  readonly prompt: string;
  readonly template: 'composite_rules';
  readonly responses: readonly { readonly identifier: string; readonly cardinality: 'single'; readonly base_type: 'string' | 'integer' | 'float'; readonly placeholder: string }[];
  readonly passage: readonly ({ readonly text: string } | { readonly response: string })[];
  readonly instructions?: readonly string[];
  readonly response_identifier?: never;
  readonly cardinality?: never;
  readonly base_type?: never;
  readonly choices?: never;
  readonly min_choices?: never;
  readonly max_choices?: never;
  readonly slider?: never;
  readonly hottext?: never;
  readonly inline_choice?: never;
  readonly matching?: never;
  readonly gap_matching?: never;
}
export type ItemDescription = SingleItemDescription | CompositeItemDescription;
export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue };
export interface ScoringStep {
  readonly operation: 'response' | 'null_response' | 'match_correct' | 'duplicate_ignored' | 'map_value' | 'mapping_bounds' | 'numeric_condition' | 'set_score' | 'composite_condition' | 'composite_add';
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

export interface PackageResource {
  readonly identifier: string;
  readonly type: string;
  readonly href: string | null;
  readonly files: readonly string[];
  readonly dependencies: readonly string[];
  readonly resolved_file_count: number;
  readonly issues: readonly ErrorDetail[];
}
export type PackageItem =
  | { readonly resource_id: string; readonly path: string; readonly status: 'ready'; readonly item: ItemDescription; readonly error: null }
  | { readonly resource_id: string; readonly path: string | null; readonly status: 'unsupported' | 'invalid'; readonly item: null; readonly error: ErrorDetail };
export interface PackageDescription {
  readonly identifier: string;
  readonly file_count: number;
  readonly files: readonly string[];
  readonly resources: readonly PackageResource[];
  readonly items: readonly PackageItem[];
  readonly ready_count: number;
}
export interface ContentPackage {
  readonly disposed: boolean;
  describe(): PackageDescription;
  getItem(resourceId: string): CompiledItem;
  resourceFiles(resourceId: string): string[];
  readFile(path: string): Uint8Array;
  scoreAttempts(jsonl: string): PackageBatchEvaluation;
  dispose(): void;
}
export function importPackage(bytes: Uint8Array): ContentPackage;

export type PackageBatchRow = {
  readonly line: number;
  readonly attempt_id: string | null;
  readonly resource_id: string | null;
  readonly item_id: string | null;
} & (
  | { readonly ok: true; readonly result: Score; readonly error: null }
  | { readonly ok: false; readonly result: null; readonly error: ErrorDetail }
);
export interface AttemptSummary {
  readonly attempt_id: string;
  readonly row_count: number;
  readonly scored_count: number;
  readonly error_count: number;
  readonly answered_count: number;
  readonly unanswered_count: number;
  readonly all_rows_scored: boolean;
  readonly score_sum: number | null;
  readonly sum_error: ErrorDetail | null;
}
export interface PackageBatchReport {
  readonly package_identifier: string;
  readonly row_count: number;
  readonly attempt_count: number;
  readonly scored_count: number;
  readonly error_count: number;
  readonly answered_count: number;
  readonly unanswered_count: number;
  readonly unassigned_count: number;
  readonly has_errors: boolean;
  readonly rows: readonly PackageBatchRow[];
  readonly attempts: readonly AttemptSummary[];
}
export interface PackageBatchEvaluation {
  readonly report: PackageBatchReport;
  readonly csv: string;
}
