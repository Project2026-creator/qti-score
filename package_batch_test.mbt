///|
fn batch_bundle() -> @qti.ContentPackage raise {
  @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/package-manifest.xml"),
      ),
      ("items/single.xml", fixture("single")),
      ("items/numeric.xml", fixture("numeric")),
      ("items/essay.xml", fixture("essay")),
      ("assets/note.txt", "shared"),
    ]),
  )
}

///|
fn attempt(id : String, resource : String, response : String) -> String {
  let prefix : Json = { "attempt_id": id, "resource_id": resource }
  prefix.stringify().strip_suffix("}").unwrap().to_owned() +
  ",\"response\":" +
  response +
  "}"
}

///|
test "package batch isolates errors and sums successful rows for each attempt" {
  let report = batch_bundle().score_attempts_jsonl(
    @fs.read_file_to_string("examples/package-attempts.jsonl"),
  )
  assert_eq(report.row_count, 6)
  assert_eq(report.attempt_count, 3)
  assert_eq(report.scored_count, 4)
  assert_eq(report.error_count, 2)
  assert_eq(report.answered_count, 3)
  assert_eq(report.unanswered_count, 1)
  assert_eq(report.unassigned_count, 0)
  guard report.to_json()
    is { "rows": Array(json_rows), "attempts": Array(json_attempts), .. } else {
    fail("expected report")
  }
  assert_true(
    json_rows[0]
    is {
      "attempt_id": String("class-01"),
      "result": { "score": Number(1.0, ..), .. },
      "error": Null,
      ..
    },
  )
  assert_true(
    json_rows[3] is { "error": { "code": String("invalid_response"), .. }, .. },
  )
  assert_true(
    json_attempts[0] is { "score_sum": Number(2.0, ..), "sum_error": Null, .. },
  )
  assert_true(report.has_errors)
  assert_eq(report.rows()[3].error.unwrap().code(), "invalid_response")
  assert_eq(report.rows()[4].error.unwrap().code(), "unsupported")
  assert_eq(report.rows()[4].error.unwrap().location().unwrap().line, 7)
  let summaries = report.attempts()
  assert_eq(summaries.map(s => s.score_sum), [Some(2.0), Some(0.0), Some(0.5)])
  assert_eq(summaries.map(s => s.all_rows_scored), [true, false, false])
  assert_true(
    report.to_json() is { "rows": Array(rows), .. } &&
    rows[3] is { "ok": False, "result": Null, .. },
  )
}

///|
test "blank lines, CRLF and one leading BOM retain physical line numbers" {
  let rows = [
    attempt("a", "choice", "{}"),
    attempt("b", "choice", "{\"RESPONSE\":\"A\"}"),
  ]
  let report = batch_bundle().score_attempts_jsonl(
    "\uFEFF\r\n\n" + rows[0] + "\r\n \t\r\n" + rows[1] + "\r\n",
  )
  assert_eq(report.rows().map(r => r.line), [3, 5])
  assert_eq(report.scored_count, 2)
  assert_eq(report.unanswered_count, 1)
  assert_false(report.has_errors)
}

///|
test "malformed and unidentifiable rows do not interrupt later valid input" {
  let jsonl = [
    "{oops}",
    "[]",
    "{\"attempt_id\":7,\"resource_id\":\"choice\",\"response\":{}}",
    "{\"attempt_id\":\"extra\",\"resource_id\":\"choice\",\"response\":{},\"extra\":true}",
    attempt("shape", "choice", "null"),
    attempt("unknown", "missing", "{}"),
    attempt("last", "choice", "{\"RESPONSE\":\"A\"}"),
  ].join("\n")
  let report = batch_bundle().score_attempts_jsonl(jsonl)
  assert_eq(report.row_count, 7)
  assert_eq(report.scored_count, 1)
  assert_eq(report.unassigned_count, 3)
  assert_eq(report.attempt_count, 4)
  assert_eq(report.rows()[5].error.unwrap().code(), "invalid_package")
  assert_eq(report.rows()[6].result.unwrap().score, 1.0)
}

///|
test "all duplicate attempt resource pairs are errors even when responses differ" {
  let report = batch_bundle().score_attempts_jsonl(
    [
      attempt("a", "choice", "{\"RESPONSE\":\"A\"}"),
      attempt("a", "choice", "{\"RESPONSE\":\"B\"}"),
      attempt("a", "measurement", "{\"RESPONSE\":100}"),
      attempt("b", "choice", "{}"),
      attempt("c", "choice", "false"),
      attempt("c", "choice", "{}"),
    ].join("\n"),
  )
  assert_eq(report.scored_count, 2)
  for index in [0, 1, 4, 5] {
    assert_true(
      report.rows()[index].error
      .unwrap()
      .message()
      .contains("duplicate attempt_id"),
    )
    assert_true(report.rows()[index].result is None)
  }
  assert_eq(report.attempts()[0].score_sum, Some(2.0))
  assert_false(report.attempts()[0].all_rows_scored)
  assert_eq(report.attempts()[2].score_sum, None)
}

///|
test "duplicate JSON members are never collapsed before batch validation" {
  let report = batch_bundle().score_attempts_jsonl(
    [
      "{\"attempt_id\":\"a\",\"attempt_id\":\"b\",\"resource_id\":\"choice\",\"response\":{}}",
      attempt("c", "choice", "{\"RESPONSE\":\"A\",\"RESPONSE\":\"B\"}"),
      attempt("d", "choice", "{}"),
    ].join("\n"),
  )
  assert_eq(report.scored_count, 1)
  assert_eq(report.unassigned_count, 2)
}

///|
test "batch preserves numeric spelling before integer response validation" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        manifest(
          item_resource("integer", "i.xml") + item_resource("float", "f.xml"),
        ),
      ),
      ("i.xml", fixture("integer")),
      ("f.xml", fixture("numeric")),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    [
      attempt("a", "integer", "{\"RESPONSE\":42.0}"),
      attempt("b", "integer", "{\"RESPONSE\":4503599627370496.5}"),
      attempt("c", "integer", "{\"RESPONSE\":42}"),
      attempt("d", "float", "{\"RESPONSE\":1e309}"),
    ].join("\n"),
  )
  assert_eq(report.scored_count, 1)
  assert_eq(report.rows()[2].result.unwrap().score, 1.0)
  for index in [0, 1, 3] {
    assert_eq(report.rows()[index].error.unwrap().code(), "invalid_response")
  }
}

///|
test "invalid identities are not trimmed or silently merged" {
  let rows = [
    attempt(" a", "choice", "{}"),
    attempt("", "choice", "{}"),
    attempt("a\nb", "choice", "{}"),
    attempt("a\u0085b", "choice", "{}"),
    attempt("a", " choice", "{}"),
    attempt("学生", "choice", "{}"),
  ]
  let report = batch_bundle().score_attempts_jsonl(rows.join("\n"))
  assert_eq(report.scored_count, 1)
  assert_eq(report.unassigned_count, 4)
  assert_eq(report.attempts()[1].attempt_id, "学生")
}

///|
test "empty batch is a valid empty report with a CSV header" {
  let report = batch_bundle().score_attempts_jsonl("\uFEFF\n  \n")
  assert_eq(report.row_count, 0)
  assert_eq(report.attempt_count, 0)
  assert_false(report.has_errors)
  assert_eq(report.to_csv().split("\r\n").collect().length(), 2)
}

///|
test "fatal row and input limits differ from isolated long-line errors" {
  let bundle = batch_bundle()
  let row = attempt("a", "choice", "{}")
  for
    source in [
      Array::make(4097, row).join("\n"),
      Array::make(4194305, " ").join(""),
    ] {
    try bundle.score_attempts_jsonl(source) catch {
      error => assert_eq(error.code(), "limit_exceeded")
    } noraise {
      _ => fail("expected fatal batch limit")
    }
  }
  let source = Array::make(1048577, "x").join("") + "\n" + row
  let report = bundle.score_attempts_jsonl(source)
  assert_eq(report.rows()[0].error.unwrap().code(), "limit_exceeded")
  assert_eq(report.scored_count, 1)
}

///|
test "authored nonzero NULL scores and negative values contribute unchanged" {
  let xml = fixture("numeric").swap(
    "base-type=\"float\">0</qti-base-value>", "base-type=\"float\">-3</qti-base-value>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", "f.xml"))),
      ("f.xml", xml),
    ]),
  )
  let report = bundle.score_attempts_jsonl(attempt("a", "one", "{}"))
  assert_eq(report.unanswered_count, 1)
  assert_eq(report.attempts()[0].score_sum, Some(-3.0))
  assert_true(report.to_csv().contains(",true,-3,unanswered,"))
}

///|
test "overflowing sums are null with a summary error while individual scores remain" {
  let xml = fixture("numeric").swap(
    "base-type=\"float\">2</qti-base-value>", "base-type=\"float\">1e308</qti-base-value>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        manifest(item_resource("one", "f.xml") + item_resource("two", "f.xml")),
      ),
      ("f.xml", xml),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    [
      attempt("a", "one", "{\"RESPONSE\":100}"),
      attempt("a", "two", "{\"RESPONSE\":100}"),
    ].join("\n"),
  )
  assert_eq(report.scored_count, 2)
  assert_eq(report.error_count, 0)
  assert_true(report.has_errors)
  let summary = report.attempts()[0]
  assert_true(summary.all_rows_scored)
  assert_eq(summary.score_sum, None)
  assert_eq(summary.sum_error.unwrap().code(), "limit_exceeded")
  assert_true(report.to_json().stringify().contains("\"score_sum\":null"))
}

///|
test "CSV quotes identities and prefixes spreadsheet formula introducers" {
  let ids = ["学生,\"A\"", "=1+2", "+1", "-x", "@name", "＝1"]
  let report = batch_bundle().score_attempts_jsonl(
    ids.map(id => attempt(id, "choice", "{}")).join("\n"),
  )
  let csv = report.to_csv()
  assert_true(csv.contains("\"学生,\"\"A\"\"\""))
  assert_true(csv.contains("\"'=1+2\""))
  assert_true(csv.contains("\"'+1\""))
  assert_true(csv.contains("\"'-x\""))
  assert_true(csv.contains("\"'@name\""))
  assert_true(csv.contains("\"'＝1\""))
  assert_eq(report.rows()[1].attempt_id, Some("=1+2"))
}

///|
test "batch results are stable copies and report export never adds traces or input" {
  let bundle = batch_bundle()
  let source = attempt("a", "choice", "{\"RESPONSE\":\"A\"}")
  let report = bundle.score_attempts_jsonl(source)
  report.rows().clear()
  report.attempts().clear()
  guard report.to_json()
    is { "rows": Array(rows), "attempts": Array(attempts), .. } else {
    fail("expected arrays")
  }
  rows.clear()
  attempts.clear()
  assert_eq(report.rows().length(), 1)
  assert_eq(report.attempts().length(), 1)
  assert_eq(report.to_csv(), bundle.score_attempts_jsonl(source).to_csv())
  assert_false(report.to_json().stringify().contains("\"response\""))
  assert_false(report.to_json().stringify().contains("\"steps\""))
}
