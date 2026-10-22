# QTI Score JavaScript SDK

ESM wrapper around the compiled MoonBit scorer. The package has no runtime dependencies and performs no network or file I/O. It supports Node.js 18+ and modern browsers with ES modules and private class fields.

From the repository root, run `python tools/project.py build-sdk`. The standalone package is written to `_build/sdk/qti-score/`, including the generated core, type declarations and licenses. That directory can be copied to another application or installed with `npm install /absolute/path/to/_build/sdk/qti-score`. The package is marked private and has not been published to npm.

```js
import { compileItem, QtiScoreError } from '@project2026-creator/qti-score';

const item = compileItem(xmlText);
try {
  const score = item.score({ RESPONSE: 100.5 });
  const diagnostic = item.explain({ RESPONSE: 100.5 });
  const batch = item.scoreBatch([{ RESPONSE: 100 }, { RESPONSE: 'bad' }, {}]);
  console.log(score, diagnostic, batch);
} catch (error) {
  if (!(error instanceof QtiScoreError)) throw error;
  console.error(error.code, error.message, error.location);
} finally {
  item.dispose();
}
```

`compileItem` parses XML once. The returned object provides `describe`, `score`, `explain`, `scoreBatch`, `dispose` and a `disposed` getter. `describe` returns a fresh metadata object without correct answers or mapping rules. At most 256 compiled objects may be live in one loaded core module; dispose objects when finished. Disposal is idempotent; use after disposal throws `QtiScoreError` with code `disposed`. A released handle is never reused for a different item.

`evaluateItem(xml, response)` scores a single attempt without allocating a persistent handle. `describeItem(xml)` returns metadata. Scoring failures throw `QtiScoreError`; `scoreBatch` instead returns one `{index, ok, result}` or `{index, ok, error}` entry for every attempt, continuing after individual failures. Indices start at zero; a batch may contain at most 4096 attempts. An invalid batch container or a disposed item throws before processing.

Responses are plain objects with an optional `RESPONSE` member: string, finite number, string array, or null. Missing members mean NULL. Numeric values are accepted only by numeric items. Integer responses are restricted to `[-9007199254740991, 9007199254740991]`; textual integers use decimal digits with an optional sign and no fraction or exponent. JavaScript values already rounded before calling the SDK cannot be recovered; use decimal strings when the original input spelling matters. Undefined values, NaN, infinity, sparse response arrays, accessors and non-data values are rejected rather than silently converted to NULL.

`explain` explicitly returns `{result, steps}`. Steps include source locations, mapping contributions and numeric branch decisions. These are developer diagnostics that may reveal scoring rules. Regular `score` and metadata contain no trace. For numeric items `matches_correct` means exact numeric equality with the declared correct response; tolerance credit may be nonzero while it is false.

QTI support is the documented subset in the repository README. Numeric rules contain one response condition with ordered branches, `qti-equal`/`qti-is-null` predicates and literal float SCORE assignments. Relative tolerance uses a fixed nonnegative first operand; other expressions and negative relative references are rejected explicitly. This package does not claim full QTI conformance.

## Ordered responses

QTI `qti-order-interaction` is supported with `ordered/identifier` declarations and `match_correct`. Pass the ordered identifiers as a string array, for example `item.score({RESPONSE:['Locate','Adapt']})`. The core checks each position; a different order with the same identifiers does not match. No per-position partial credit or ordered mapping is inferred. `describe().cardinality` can now be `ordered`; metadata choices remain in authored display order and do not reveal the correct sequence.

If `min-choices` is omitted, all choices must be ordered and `max-choices` is ignored semantically (its numeric syntax is still checked). With an explicit minimum, it must be at least one; the maximum defaults to the available choice count, with `1 <= min <= max <= count`. Metadata exposes the effective bounds. Nonempty responses must fit that range and contain unique, known choice identifiers. Null, an omitted RESPONSE, or an empty array is unanswered; a scalar, an empty-string member or a duplicate is an error. Explanation steps add `comparison:'ordered'` to the existing `match_correct` operation and share the normal scorer.

Imported packages and `scoreAttempts` interpret arrays using each item's cardinality, so no new JSONL shape is needed. The standalone SDK has no JavaScript order scorer. Version 0.5.0 expands `ItemDescription.cardinality` to `'single' | 'multiple' | 'ordered'`; exhaustive consumers should handle the additional case. The browser demo offers keyboard buttons for complete and subset orders, initially leaving the response unanswered. Presentation shuffling, graphical ordering and other ordered base types are outside this demo's supported profile.

For development, run `npm ci --prefix sdk --ignore-scripts` from the repository root, then `python tools/project.py check`. TypeScript is a development dependency only.

## Import content packages

```js
import { importPackage } from '@project2026-creator/qti-score';

const bundle = importPackage(zipBytes); // Uint8Array, including Node Buffer
try {
  console.log(bundle.describe()); // each item is ready, unsupported, or invalid
  console.log(bundle.resourceFiles('choice')); // declared files + transitive dependencies
  const bytes = bundle.readFile('assets/note.txt'); // fresh Uint8Array, exact ZIP path
  const item = bundle.getItem('choice'); // manifest resource ID, not item ID
  try { console.log(item.score({ RESPONSE: 'A' })); }
  finally { item.dispose(); }
} finally { bundle.dispose(); }
```

ZIP parsing, URI resolution, dependency checks and item compilation run in MoonBit. The SDK copies the input before import and returns fresh reports, file lists and byte arrays. It does not fetch referenced URLs, extract files onto disk, execute assets or render HTML. Source XML may contain author answers; `readFile` is an explicit raw-file operation.

Limits are 8 MiB compressed input, 512 entries, 4 MiB per expanded file and 16 MiB total expanded data. At most 4 packages may be live per core module. Failed imports consume no handle. Each `getItem` creates an independent compiled handle within the shared 256-item limit; dispose that item separately. Opened items remain usable after their parent package is disposed. Package disposal is idempotent; later operations throw `disposed`.

`describe()` includes package identifier, files, resources, dependencies, bounded resource issues and item compatibility entries. A `ready` entry has item metadata and no error; other entries carry an error with source position where available. `getItem` rethrows that error. Unknown IDs and missing files throw `invalid_package`. A readable package with unsupported items still imports successfully. ZIP corruption, invalid paths or malformed manifests fail the import.

The supported packaging subset requires root `imsmanifest.xml`, accepts QTI 3 and common CP namespaces, resolves local `href` and inherited `xml:base`, and compiles `imsqti_item_xmlv3p0` resources. File paths are case-sensitive. Manifest URIs are decoded once; ZIP names are not decoded. Entry points must be listed in their resource's files. External URLs, fragments, queries, encoded separators and root escapes are rejected. Other resource types remain available as files and metadata; organizations, metadata semantics, test sequencing, full schema validation and asset rendering are outside this subset. See the repository README for the precise limits and namespaces.

## Score attempts across package items

```js
const jsonl = [
  { attempt_id: 'class-01', resource_id: 'choice', response: { RESPONSE: 'A' } },
  { attempt_id: 'class-01', resource_id: 'measurement', response: { RESPONSE: 100.5 } },
].map(row => JSON.stringify(row)).join('\n');
const { report, csv, itemsCsv } = bundle.scoreAttempts(jsonl);
console.log(report.scored_count, report.error_count, report.attempts);
console.log(report.items, itemsCsv); // observed per-resource statistics
```

`scoreAttempts` returns a fresh `{report, csv, itemsCsv}` from one MoonBit execution, with no persistent result handle. It accepts a JSONL string, not JavaScript response objects, so the core can reject duplicate JSON keys and preserve numeric spelling. Limits are 4,194,304 UTF-16 code units and 4096 nonblank rows; exceeding either throws. A line has a 1,048,576-code-unit limit and JSON depth 16; individual errors are retained and do not interrupt later rows. Blank lines and CRLF are accepted, and one leading BOM is removed. `attempt_id` must contain 1–256 code units and `resource_id` 1–4096, without edge whitespace or control characters. Unknown outer members are rejected. The response object is required; `{}` means unanswered.

Every occurrence of a duplicate `(attempt_id, resource_id)` pair is an error, including rows with validated identities but invalid response shapes. No occurrence wins silently. Output rows retain physical one-based line numbers and are discriminated by `ok`: success has a `Score` and null error; failure has null result and an `ErrorDetail`. Identities are null where validation failed. `unassigned_count` counts rows without a valid attempt ID. No raw response objects, authored answers or explanation traces are attached; error messages may describe invalid values.

Attempt summaries preserve first-appearance order and show row/error/answered counts plus the sum of successful rows' raw Double scores in input order. `all_rows_scored` refers only to submitted rows; omitted items are unknown. No full-test completion, weighting or maximum score is inferred. No successful rows means `score_sum:null`; nonfinite sequential addition also gives null and a `sum_error`. Individual results remain available. `report.has_errors` covers row and summary errors and does not make the method throw. Disposed packages and fatal input limits do throw.

CSV has a fixed 12-column detail header and CRLF endings, with failure scores left blank. Commas, quotes and line breaks are quoted. Formula-like text cells receive an apostrophe prefix (ASCII/fullwidth `= + - @`, including after whitespace, or leading tab/CR/LF); numeric scores are unchanged. JSON preserves exact identities and is preferred for lossless data interchange. Spreadsheet applications may change prefixes when resaving. Core CSV has no BOM; the host chooses its encoding. The browser demo downloads it as UTF-8 with a BOM.

Version 0.16.0 adds `report.items`, `report.unassigned_resource_count` and `itemsCsv`; existing detail rows, attempt sums and detail CSV retain their semantics. Item summaries group validated resource IDs in first-seen order, including unknown resources and failed attempts. Unvalidated resource IDs remain on their detail rows and are counted separately. Unsubmitted items are not fabricated. Each summary includes row, scored, error, answered, unanswered and standard-response match counts, plus mean/minimum/maximum successful scores. Successful unanswered submissions and authored penalties participate; error rows never become zero scores. An item with no successful scores has null statistics (blank CSV cells). The mean uses scaled Double arithmetic to avoid ordinary sum overflow and retains floating-point rounding. Standard-response matching is independent of score, pass/fail and maximum marks. These are descriptive batch statistics, not item difficulty, reliability or test completion estimates. No responses, answer keys or traces are added to the report. `itemsCsv` uses CRLF and the same formula-prefix protection as detail CSV.

## Directed matching

Version 0.6.0 supports `qti-match-interaction` with single/multiple `directedPair` responses. Pass a pair as `'Source Target'` for single cardinality or an array of such strings for multiple cardinality. Array order is insignificant; endpoint order is significant. XML whitespace is collapsed and identifiers remain case sensitive. `match_correct` awards one point for a complete match; `map_response` uses the existing weighted mapping and bounds.

`describe().matching` exposes two `sets` of choices (sources, then targets), their `match_min`/`match_max`, and overall `min_associations`/`max_associations`. Zero maxima mean unlimited; the overall maximum defaults to one, and single cardinality requires that maximum. Each choice must author `match-max`. Nonempty responses must satisfy both global and per-choice limits. Null and empty containers remain unanswered. Reversed, same-set, unknown and duplicate pairs fail with `invalid_response`; unsupported `match-group` and dynamic choice attributes fail during compilation. Metadata contains no correct pairs or mapping entries and is freshly allocated for each call.

The `base_type` union adds `'directedPair'`; `matching` is optional for existing item kinds. No new response object shape or JavaScript scoring implementation is added. Package, batch, explanation and disposal APIs work unchanged.

## Gap matching

Version 0.7.0 supports text `qti-gap-match-interaction`: `gap_matching` exposes the same two choice sets and association limits as matching, plus a document-ordered `passage` of `{text:string}` or `{gap:string}` parts. The first set contains words, the second contains gaps. Text is plain data, never HTML. Each gap has maximum one association; a required gap has minimum one. Words can be reused according to their authored `match-max`/`match-min`. Overall maximum defaults to one (zero means unlimited), so multi-gap authors should specify it explicitly. Multiple gaps require multiple cardinality. Null remains unanswered and is scored by the template.

Responses use the existing string-pair API, e.g. `{RESPONSE:['Feedback G1','Adjust G2','Feedback G3']}` or a string for a single gap. Reversed/unknown/duplicate pairs, duplicate gap occupancy, missing required gaps in nonempty responses and excess word use are errors. Metadata is fresh, without correct pairs, and keeps prompt/word-bank text outside the passage. Existing item kinds retain their previous metadata shape. The browser demo uses inline native selects and a contextual text preview; image choices, dynamic visibility, match-group and arbitrary HTML rendering are outside this profile.

## Composite text/numeric items

Version 0.11.0 extends the existing compileItem/getItem/score/explain/scoreBatch and package batch entry points to composite items. Responses are plain objects keyed by authored response identifiers, e.g. `{PLATFORM:'LMS',COUNT:4}`. Known omitted/null fields are unanswered; any invalid field rejects the entire attempt. JavaScript accessors, undefined/nonfinite values and unknown core identifiers are rejected, never silently omitted. At most eight fields are encoded. Existing single items still reject fields other than RESPONSE.

The composite profile supports 2–8 single string/integer/float text entries or single identifier inline choices, one float SCORE, and an explicit zero initialization followed by one response-condition per response. Non-NULL responses may add map-response; exact non-float matches may add a literal weight. The assignment is sum(SCORE, contribution), evaluated in authored order. Defaults, unsupported operators, other outcomes and unsupported composite/media interactions are explicitly rejected. NULL guards prevent accidental substitution of zero for the standard sum operator's NULL propagation. Integer lexical rules, numeric mapping equality, string case folding and mapping bounds reuse the existing core.

Version 0.12.0 adds numeric qti-equal predicates and response-else-if tiers (at most 128 branches per response). Only the first true branch contributes; unmatched/NULL predicates continue, and without a trailing else there is no contribution. Each equal has exactly one variable and compares against its own correct value or a numeric literal. Exact/absolute/relative tolerances, asymmetric bounds and inclusion flags share the single-response numeric implementation; relative comparison requires a fixed nonnegative first operand. Cross-response references, constant-only comparisons and general expressions are rejected. All branches in a condition must own the same response.

For `examples/composite-tolerance.xml`, `{UNIT:'cm',LENGTH:100.5,GROUPS:4}` scores 4; exact length 100 scores 5, without adding the lower tiers too. `matches_correct` remains exact and independent of tolerant credit. `explain()` adds a zero-based branch and numeric condition details to composite_condition; regular scores and descriptions retain their previous shape and do not expose scoring rules. The new example and mixed package use the existing SDK and batch APIs.

Version 0.13.0 adds composite inline choices alongside text/numeric entries. Identifier responses carry `inline_choice:{required,label,choices}` and a placeholder; entry descriptions remain unchanged. `CompositeResponseDescription` is a discriminated union: narrow `base_type === 'identifier'` to access inline choices. Callers exhaustively matching prior composite base types must handle this new branch. Options are isolated per response, case-sensitive and validated both at compilation (correct/mapping references) and at scoring (learner IDs). Option text stays out of the common passage, and returned objects cannot mutate compiled choices.

For `examples/composite-inline.xml`, `{ACTION:'Adapt',RATIO:75}` scores 4, while `{ACTION:'Review',RATIO:74.5}` scores 1.5. Optional NULL choices skip their mapping bounds. Required or min-choices=1 fields reject omissions/null/empty strings for the entire attempt, without stopping subsequent batch rows. Numeric/array/boolean/foreign choice values are invalid. Static labels/options and shuffle rejection reuse the single-item implementation; media, dynamic content and multi-value dropdowns are outside this profile. Existing compile/getItem/score/explain/batch/dispose methods and core public signatures remain unchanged.

Version 0.14.0 adds explicit is-null(variable) branches and an optional unique trailing response-else. Both add a finite literal contribution via sum(SCORE, weight); they do not replace prior accumulated credit. The 128-branch limit includes else. Every condition still belongs to one response, with at least an initial response-if; general expressions, standalone else and extra outcomes are unsupported. Only the first true branch runs. A NULL predicate is not true and proceeds to later branches/else; authors who want to distinguish missing from wrong answers should write an explicit is-null branch first.

`examples/composite-fallback.xml` scores `{ACTION:'Adapt',RATIO:80}` as 1.5 and `{ACTION:'Ignore',RATIO:80}` as -1.5; `{}` scores unanswered zero. Authors may assign nonzero NULL credit without changing status. Required validation and invalid-response errors happen before scoring and cannot become fallback penalties. Score and description shapes stay unchanged; explicit traces add condition operators is_null/else with branch/XML positions. Package JSON/CSV exports preserve negative numerical scores, unanswered states and blank scores for failures. No new SDK method or public core signature is introduced.

`ItemDescription` is now `SingleItemDescription | CompositeItemDescription`. Check `metadata.kind === 'composite'` before using `responses`/`passage`; the other branch retains the old metadata shape and omits kind. Code that directly accesses single-only properties should narrow this union. Composite metadata has no fabricated single response identifier or choices and never returns correct values/mappings. Returned arrays/objects are isolated. All known correct values must match for matches_correct=true; if any correct response is absent it is null. Status is answered when at least one normalized scalar is non-NULL.

Developer traces add composite_condition and composite_add with the response identifier; raw scoring returns only the existing Score shape. Compiled handle limits, disposal, independent package item lifetimes and batch error isolation remain unchanged. The browser presents inline text fields, preserves scalar input spelling and can clear all responses.

## Numeric sliders and mappings

Version 0.10.0 adds `qti-slider-interaction` for single integer/float responses, with no new response type or SDK method. `describe().slider` contains effective `lower_bound`, `upper_bound`, `step` (null for a continuous float scale), `step_label`, `orientation` and `reverse`. Descriptions are independent copies and omit scoring rules. Other item kinds omit this field.

Finite nonnegative bounds are required; integer bounds round outward and remain safe integers. Integer step defaults to one; omitted float step means continuous input. An explicit step must be positive, and integral/safe for integer responses. Nonempty responses and correct answers must lie within bounds and on the grid anchored at the lower bound. A nonaligned upper endpoint is not automatically valid. Discrete grids are limited to 1,048,576 intervals; steps below floating-point resolution are rejected. Float grid checks allow bounded arithmetic roundoff (at most 1e-8 of a step); this never changes the response or the scorer's equality/tolerance rules.

The browser range starts at the lower bound with no recorded answer. Move it, type a value or adopt its current position to answer; clear restores NULL. Manual text is preserved for core validation even if the range visually snaps to a different position. Native keyboard, vertical/reverse hints and a current-value description are supported. Tick labels are requested only for horizontal scales with at most 20 intervals. Authored response defaults, zero steps, fractional integer steps and dynamic/media context remain outside the supported profile.

`map_response` now supports single numeric text entry as well as sliders. Keys are parsed as the declared numeric type; semantically duplicate spellings are invalid. Integer text keeps its strict decimal/safe-range rules; float keys use IEEE 754 value equality with no scoring epsilon. Numeric NULL gets zero without applying mapping bounds. Other numeric inline rules retain their authored NULL scores. Integer match_correct remains available; float match_correct remains unsupported. Explanations reuse map_value/mapping_bounds, with a numeric `details.value` for numeric mapping.

## Inline choice

Version 0.9.0 supports one `qti-inline-choice-interaction` per item with single/identifier responses, e.g. `{RESPONSE:'Improve'}`. Both standard templates work unchanged. `describe().inline_choice` adds an ordered `passage` of `{text:string}` and one `{response:'RESPONSE'}`, plus `required`, `label` (static qti-label), and `placeholder` (data-prompt). Label and placeholder default to empty strings. Candidate options and separate instructions are excluded from the context; metadata cannot mutate the compiled item.

Optional NULL, empty string and omitted RESPONSE are unanswered zeroes. `required=true` or `min-choices=1` makes an empty response an `invalid_response` error. Either constraint requires selection; minimum must be zero or one. This validation is specific to inline choice and does not change other item kinds. In package batch reports, a required omission has no score, whereas an optional omission remains an unanswered zero. The native browser select shows the authored label and placeholder and supports keyboard selection and clear/reset.

One choice is valid. Unknown/case-mismatched IDs, wrong containers and duplicate/reserved authored IDs are rejected. Only static text context is supported; shuffle=true, dynamic content, media and composite items are explicitly rejected. Other item descriptions omit `inline_choice`; existing response types, methods, disposal and package APIs are unchanged.

## Contextual hottext and candidate instructions

Version 0.8.0 supports `qti-hottext-interaction` with single/multiple identifier responses. Select IDs, not literal text or offsets: `{RESPONSE:['Evidence','Support']}` or a string for single cardinality. The core checks known unique IDs and min/max choices, then reuses match_correct or map_response. Maximum defaults to one (zero means unlimited), minimum to zero; single requires maximum one. Null and empty matching containers remain unanswered. Ordinary multiple-choice duplicate semantics are unchanged.

`describe().hottext.passage` is an ordered array of `{text:string}` and `{choice:string}` parts; choices reference `describe().choices`. Metadata and caller response arrays are isolated from internal state. Dynamic choices, nested selectable fragments, media and response defaults are rejected. The browser uses native inline checkboxes/radios with keyboard access and clear/reset controls, without a JavaScript scorer.

Static item-body rubric blocks with `view="candidate" use="instructions"` and one `qti-content-body` are also supported across item kinds. Their plain text appears in optional `instructions:string[]`; other actors/purposes, nested/active content and embedded interactions are rejected. Raw HTML is never rendered. These metadata fields are additive; existing methods and response types remain unchanged.
