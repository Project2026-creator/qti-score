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
const { report, csv } = bundle.scoreAttempts(jsonl);
console.log(report.scored_count, report.error_count, report.attempts);
```

`scoreAttempts` returns a fresh `{report, csv}` from one MoonBit execution, with no persistent result handle. It accepts a JSONL string, not JavaScript response objects, so the core can reject duplicate JSON keys and preserve numeric spelling. Limits are 4,194,304 UTF-16 code units and 4096 nonblank rows; exceeding either throws. A line has a 1,048,576-code-unit limit and JSON depth 16; individual errors are retained and do not interrupt later rows. Blank lines and CRLF are accepted, and one leading BOM is removed. `attempt_id` must contain 1–256 code units and `resource_id` 1–4096, without edge whitespace or control characters. Unknown outer members are rejected. The response object is required; `{}` means unanswered.

Every occurrence of a duplicate `(attempt_id, resource_id)` pair is an error, including rows with validated identities but invalid response shapes. No occurrence wins silently. Output rows retain physical one-based line numbers and are discriminated by `ok`: success has a `Score` and null error; failure has null result and an `ErrorDetail`. Identities are null where validation failed. `unassigned_count` counts rows without a valid attempt ID. No raw response objects, authored answers or explanation traces are attached; error messages may describe invalid values.

Attempt summaries preserve first-appearance order and show row/error/answered counts plus the sum of successful rows' raw Double scores in input order. `all_rows_scored` refers only to submitted rows; omitted items are unknown. No full-test completion, weighting or maximum score is inferred. No successful rows means `score_sum:null`; nonfinite sequential addition also gives null and a `sum_error`. Individual results remain available. `report.has_errors` covers row and summary errors and does not make the method throw. Disposed packages and fatal input limits do throw.

CSV has a fixed 12-column detail header and CRLF endings, with failure scores left blank. Commas, quotes and line breaks are quoted. Formula-like text cells receive an apostrophe prefix (ASCII/fullwidth `= + - @`, including after whitespace, or leading tab/CR/LF); numeric scores are unchanged. JSON preserves exact identities and is preferred for lossless data interchange. Spreadsheet applications may change prefixes when resaving. Core CSV has no BOM; the host chooses its encoding. The browser demo downloads it as UTF-8 with a BOM.
