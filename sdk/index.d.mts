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
export type InlineChoicePassagePart = { readonly text: string } | { readonly response: string };
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
export interface GraphicImageDescription {
  readonly data: string;
  readonly type: 'image/svg+xml' | 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif';
  readonly width: number | null;
  readonly height: number | null;
  readonly alternative: string;
}
export interface GraphicRegionDescription {
  readonly identifier: string;
  readonly label: string;
  readonly shape: 'rect' | 'circle' | 'ellipse' | 'poly';
  readonly coords: readonly number[];
  readonly match_min: number;
  readonly match_max: number;
}
export interface GraphicBaseDescription {
  readonly object: GraphicImageDescription;
  readonly regions: readonly GraphicRegionDescription[];
  readonly gap_images: readonly { readonly identifier: string; readonly image: GraphicImageDescription }[];
}
export type GraphicDescription =
  | (GraphicBaseDescription & { readonly kind: 'hotspot'; readonly min_choices: number; readonly max_choices: number })
  | (GraphicBaseDescription & { readonly kind: 'graphic_gap_match'; readonly min_associations: number; readonly max_associations: number });
export interface ExtendedTextDescription {
  readonly prompt: string;
  readonly placeholder: string;
  readonly format: 'plain' | 'preformatted';
  readonly min_strings: number;
  readonly expected_lines?: number;
  readonly expected_length?: number;
}
export interface ProcessingDeclarationDescription extends VariableTypeDescription {
  readonly identifier: string;
  readonly role: 'response' | 'outcome';
}
export interface AuthoredProcessingMetadata {
  readonly declarations?: readonly ProcessingDeclarationDescription[];
  readonly has_feedback?: boolean;
  readonly external_scoring?: boolean;
  readonly external_scored?: 'human' | 'externalMachine';
}
export interface SingleItemDescription extends AuthoredProcessingMetadata {
  readonly kind?: 'single';
  readonly identifier: string;
  readonly title: string;
  readonly response_identifier: string;
  readonly cardinality: 'single' | 'multiple' | 'ordered';
  readonly base_type: 'identifier' | 'string' | 'integer' | 'float' | 'directedPair';
  readonly template: 'match_correct' | 'map_response' | 'numeric_rules' | 'typed_rules';
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
  readonly extended_text?: ExtendedTextDescription;
  readonly graphic?: GraphicDescription;
}
export interface CompositeEntryDescription {
  readonly identifier: string;
  readonly cardinality: 'single';
  readonly base_type: 'string' | 'integer' | 'float';
  readonly placeholder: string;
  readonly inline_choice?: never;
  readonly choice?: never;
  readonly slider?: never;
}
export interface CompositeInlineChoiceDescription {
  readonly identifier: string;
  readonly cardinality: 'single';
  readonly base_type: 'identifier';
  readonly placeholder: string;
  readonly choice?: never;
  readonly slider?: never;
  readonly inline_choice: {
    readonly required: boolean;
    readonly label: string;
    readonly choices: readonly Choice[];
  };
}
export interface CompositeChoiceDescription {
  readonly identifier: string;
  readonly cardinality: 'single';
  readonly base_type: 'identifier';
  readonly placeholder: string;
  readonly inline_choice?: never;
  readonly slider?: never;
  readonly choice: {
    readonly required: boolean;
    readonly prompt: string;
    readonly orientation: 'horizontal' | 'vertical';
    readonly choices: readonly Choice[];
  };
}
export interface CompositeMultipleChoiceDescription {
  readonly identifier: string;
  readonly cardinality: 'multiple';
  readonly base_type: 'identifier';
  readonly placeholder: string;
  readonly inline_choice?: never;
  readonly slider?: never;
  readonly choice: {
    readonly required: boolean;
    readonly prompt: string;
    readonly orientation: 'horizontal' | 'vertical';
    readonly min_choices: number;
    readonly max_choices: number;
    readonly choices: readonly Choice[];
  };
}
export interface CompositeSliderDescription {
  readonly identifier: string;
  readonly cardinality: 'single';
  readonly base_type: 'integer' | 'float';
  readonly placeholder: string;
  readonly inline_choice?: never;
  readonly choice?: never;
  readonly slider: SliderDescription & { readonly prompt: string };
}
export type CompositeResponseDescription = CompositeEntryDescription | CompositeInlineChoiceDescription | CompositeChoiceDescription | CompositeMultipleChoiceDescription | CompositeSliderDescription;
export interface CompositeItemDescription extends AuthoredProcessingMetadata {
  readonly kind: 'composite';
  readonly identifier: string;
  readonly title: string;
  readonly prompt: string;
  readonly template: 'composite_rules';
  readonly responses: readonly CompositeResponseDescription[];
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
  readonly extended_text?: never;
  readonly graphic?: never;
}
export interface ProcessedCompositeResponseDescription extends VariableTypeDescription {
  readonly identifier: string;
  readonly prompt: string;
  readonly placeholder: string;
  readonly extended_text?: ExtendedTextDescription;
  readonly graphic?: GraphicDescription;
  readonly choice?: { readonly required: boolean; readonly prompt: string; readonly orientation: 'horizontal' | 'vertical'; readonly choices: readonly Choice[]; readonly min_choices: number; readonly max_choices: number };
  readonly slider?: SliderDescription;
  readonly inline_choice?: InlineChoiceDescription;
  readonly matching?: MatchDescription;
  readonly gap_matching?: GapMatchDescription;
  readonly hottext?: HottextDescription;
}
export interface ProcessedCompositeItemDescription extends AuthoredProcessingMetadata {
  readonly kind: 'composite';
  readonly identifier: string;
  readonly title: string;
  readonly prompt: string;
  readonly template: 'typed_rules';
  readonly responses: readonly ProcessedCompositeResponseDescription[];
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
  readonly extended_text?: never;
  readonly graphic?: never;
}
export type ItemDescription = SingleItemDescription | CompositeItemDescription | ProcessedCompositeItemDescription;
export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue };
export interface ScoringStep {
  readonly operation: 'response' | 'null_response' | 'match_correct' | 'duplicate_ignored' | 'map_value' | 'mapping_bounds' | 'numeric_condition' | 'set_score' | 'composite_condition' | 'composite_add' | 'set_outcome_value' | 'processing_condition' | 'exit_processing';
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
  getTest(resourceId: string, options?: { readonly seed?: number }): CompiledTest;
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
  readonly items: readonly ItemSummary[];
  readonly unassigned_resource_count: number;
}
export interface ItemSummary {
  readonly resource_id: string;
  readonly row_count: number;
  readonly scored_count: number;
  readonly error_count: number;
  readonly answered_count: number;
  readonly unanswered_count: number;
  readonly matched_count: number;
  readonly unmatched_count: number;
  readonly unclassified_count: number;
  readonly score_mean: number | null;
  readonly score_min: number | null;
  readonly score_max: number | null;
}
export interface PackageBatchEvaluation {
  readonly report: PackageBatchReport;
  readonly csv: string;
  readonly itemsCsv: string;
}

export interface ItemSessionControl {
  readonly max_attempts: number;
  readonly allow_review: boolean;
  readonly show_feedback: boolean;
  readonly allow_skipping: boolean;
  readonly validate_responses: boolean;
}
export interface TestPartDescription {
  readonly identifier: string;
  readonly navigation_mode: 'linear' | 'nonlinear';
  readonly submission_mode: 'individual' | 'simultaneous';
  readonly max_time: number | null;
  readonly entry_count: number;
  readonly control: ItemSessionControl;
}
export interface TestEntryDescription {
  readonly identifier: string;
  readonly source_identifier: string;
  readonly instance_index: number;
  readonly part_identifier: string;
  readonly resource_id: string;
  readonly path: string;
  readonly control: ItemSessionControl;
  readonly item: ItemDescription;
  readonly section_identifiers: readonly string[];
  readonly categories: readonly string[];
  readonly weights: Readonly<Record<string, number>>;
}
export interface VariableTypeDescription {
  readonly base_type: string;
  readonly cardinality: 'single' | 'multiple' | 'ordered';
}
export interface TestDescription {
  readonly identifier: string;
  readonly title: string;
  readonly parts: readonly TestPartDescription[];
  readonly entries: readonly TestEntryDescription[];
  readonly item_count: number;
  readonly outcome_types: Readonly<Record<string, VariableTypeDescription>>;
  readonly assembly_seed: number;
  readonly candidate_count: number;
}
export type SessionAction =
  | { readonly type: 'save'; readonly time: number; readonly response: ResponseObject }
  | { readonly type: 'select'; readonly time: number; readonly identifier: string }
  | { readonly type: 'submit' | 'next' | 'finish_part' | 'pause' | 'resume' | 'tick'; readonly time: number };
export interface SessionItemSummary {
  readonly identifier: string;
  readonly part_identifier: string;
  readonly submitted: boolean;
  readonly answered: boolean;
  readonly dirty: boolean;
  readonly num_attempts: number;
}
export interface SessionDescription {
  readonly test_identifier: string;
  readonly session_identifier: string;
  readonly completed: boolean;
  readonly paused: boolean;
  readonly timed_out: boolean;
  readonly part_identifier: string;
  readonly part_elapsed: number;
  readonly current: {
    readonly identifier: string;
    readonly item: ItemDescription;
    readonly response: ResponseObject;
    readonly submitted: boolean;
    readonly dirty: boolean;
    readonly num_attempts: number;
    readonly result: Score | null;
    readonly feedback: readonly JsonValue[];
  };
  readonly items: readonly SessionItemSummary[];
}
export interface CompiledTest {
  readonly disposed: boolean;
  describe(): TestDescription;
  startSession(identifier: string, options?: { readonly now?: number }): TestSession;
  restoreSession(snapshot: string): TestSession;
  dispose(): void;
}
export interface TestSession {
  readonly disposed: boolean;
  act(action: SessionAction): SessionDescription;
  describe(): SessionDescription;
  snapshot(): string;
  exportResult(datestamp: string, options?: { readonly candidateIdentifier?: string }): { readonly report: JsonValue; readonly xml: string };
  dispose(): void;
}
