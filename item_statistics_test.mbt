///|
test "item statistics group observed resources and retain failed rows" {
  let report = batch_bundle().score_attempts_jsonl(
    @fs.read_file_to_string("examples/package-attempts.jsonl"),
  )
  let items = report.items()
  assert_eq(items.map(s => s.resource_id), ["choice", "measurement", "essay"])
  assert_eq(items.map(s => s.row_count), [2, 3, 1])
  assert_eq(items.map(s => s.scored_count), [2, 2, 0])
  assert_eq(items.map(s => s.error_count), [0, 1, 1])
  assert_eq(items.map(s => s.score_mean), [Some(0.5), Some(0.75), None])
  assert_eq(items.map(s => s.score_min), [Some(0.0), Some(0.5), None])
  assert_eq(items.map(s => s.score_max), [Some(1.0), Some(1.0), None])
  assert_eq(items[0].answered_count, 1)
  assert_eq(items[0].unanswered_count, 1)
}

///|
test "unassignable resources are counted separately while unknown IDs remain errors" {
  let report = batch_bundle().score_attempts_jsonl(
    [
      "not-json",
      attempt("a", " missing", "{}"),
      attempt("b", "missing", "{}"),
      attempt("c", "choice", "{}"),
      "{\"resource_id\":\"choice\",\"response\":{}}",
    ].join("\n"),
  )
  assert_true(
    report.to_json() is { "unassigned_resource_count": Number(2.0, ..), .. },
  )
  let items = report.items()
  assert_eq(items.map(s => s.resource_id), ["missing", "choice"])
  assert_eq(items[0].score_mean, None)
  assert_eq(items[1].row_count, 2)
  assert_eq(items[1].scored_count, 1)
}

///|
test "duplicate submissions never become observed zero scores" {
  let report = batch_bundle().score_attempts_jsonl(
    [
      attempt("a", "choice", "{}"),
      attempt("a", "choice", "{\"RESPONSE\":\"A\"}"),
      attempt("b", "choice", "{\"RESPONSE\":\"A\"}"),
    ].join("\n"),
  )
  let stats = report.items()[0]
  assert_eq(stats.row_count, 3)
  assert_eq(stats.error_count, 2)
  assert_eq(stats.score_mean, Some(1.0))
  assert_eq(stats.matched_count, 1)
  assert_eq(stats.unmatched_count, 0)
}

///|
test "negative nonzero unanswered scores remain in the observed mean" {
  let xml = fixture("numeric").swap(
    "base-type=\"float\">0</qti-base-value>", "base-type=\"float\">-3</qti-base-value>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", "f.xml"))),
      ("f.xml", xml),
    ]),
  )
  let stats = bundle
    .score_attempts_jsonl(
      [attempt("a", "one", "{}"), attempt("b", "one", "{\"RESPONSE\":100}")].join(
        "\n",
      ),
    )
    .items()[0]
  assert_eq(stats.score_mean, Some(-0.5))
  assert_eq(stats.score_min, Some(-3.0))
  assert_eq(stats.score_max, Some(2.0))
  assert_eq(stats.unanswered_count, 1)
  assert_eq(stats.answered_count, 1)
  assert_eq(
    stats.matched_count + stats.unmatched_count + stats.unclassified_count,
    2,
  )
}

///|
test "means remain finite when ordinary finite score sums overflow" {
  let xml = fixture("numeric").swap(
    "base-type=\"float\">2</qti-base-value>", "base-type=\"float\">1e308</qti-base-value>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", "f.xml"))),
      ("f.xml", xml),
    ]),
  )
  let stats = bundle
    .score_attempts_jsonl(
      [
        attempt("a", "one", "{\"RESPONSE\":100}"),
        attempt("b", "one", "{\"RESPONSE\":100}"),
      ].join("\n"),
    )
    .items()[0]
  assert_eq(stats.score_mean, Some(1.0e308))
  assert_eq(stats.score_min, Some(1.0e308))
  assert_eq(stats.score_max, Some(1.0e308))
}

///|
test "opposite extreme scores cancel without overflowing the mean" {
  let xml = fixture("numeric")
    .swap(
      "base-type=\"float\">2</qti-base-value>", "base-type=\"float\">1e308</qti-base-value>",
    )
    .swap(
      "base-type=\"float\">0</qti-base-value>", "base-type=\"float\">-1e308</qti-base-value>",
    )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", "f.xml"))),
      ("f.xml", xml),
    ]),
  )
  let stats = bundle
    .score_attempts_jsonl(
      [attempt("a", "one", "{\"RESPONSE\":100}"), attempt("b", "one", "{}")].join(
        "\n",
      ),
    )
    .items()[0]
  assert_eq(stats.score_mean, Some(0.0))
  assert_eq(stats.score_min, Some(-1.0e308))
  assert_eq(stats.score_max, Some(1.0e308))
}

///|
test "empty batches have no fabricated item statistics" {
  let report = batch_bundle().score_attempts_jsonl("")
  assert_eq(report.items().length(), 0)
  assert_true(
    report.to_json()
    is { "items": [], "unassigned_resource_count": Number(0.0, ..), .. },
  )
  assert_eq(report.items_csv().split("\r\n").collect().length(), 2)
}

///|
test "item statistics copies and JSON do not reveal responses or rules" {
  let report = batch_bundle().score_attempts_jsonl(
    attempt("a", "choice", "{\"RESPONSE\":\"A\"}"),
  )
  report.items().clear()
  assert_eq(report.items().length(), 1)
  let json = report.items()[0].to_json().stringify()
  assert_false(json.contains("\"response\""))
  assert_false(json.contains("\"correct_response\""))
  assert_false(json.contains("\"steps\""))
}

///|
test "item CSV distinguishes missing statistics from real zero and protects text" {
  let report = batch_bundle().score_attempts_jsonl(
    [
      attempt("a", "choice", "{}"),
      attempt("b", "=resource", "{}"),
      attempt("c", "missing", "{}"),
    ].join("\n"),
  )
  let csv = report.items_csv()
  assert_true(csv.contains("\"'=resource\",1,0,1,0,0,"))
  assert_true(csv.contains("\"missing\",1,0,1,0,0,0,0,0,,,\r\n"))
  assert_eq(report.items()[0].score_mean, Some(0.0))
}
