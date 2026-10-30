///|
fn rr_test_report() -> Json {
  {
    "test_identifier": "TEST",
    "session_identifier": "SESSION_1",
    "candidate_identifier": "candidate_1",
    "datestamp": "2026-10-30T12:34:56.123Z",
    "outcomes": { "SCORE": 2 },
    "test_outcome_types": {
      "SCORE": { "base_type": "float", "cardinality": "single" },
    },
    "items": [
      {
        "identifier": "REF_1",
        "item_identifier": "ITEM_1",
        "sequence_index": 1,
        "session_status": "final",
        "num_attempts": 1,
        "duration": 12.5,
        "response": { "RESPONSE": "A" },
        "response_types": {
          "RESPONSE": { "base_type": "identifier", "cardinality": "single" },
        },
        "outcomes": { "SCORE": 2, "completionStatus": "completed" },
        "outcome_types": {
          "SCORE": { "base_type": "float", "cardinality": "single" },
          "completionStatus": {
            "base_type": "identifier",
            "cardinality": "single",
          },
        },
      },
    ],
  }
}

///|
fn rr_test_update(report : Json, key : String, value : Json) -> Json {
  guard report is Object(fields) else { return report }
  fields[key] = value
  report
}

///|
fn rr_test_item(report : Json) -> Json {
  guard report is { "items": [item], .. } else { return Json::null() }
  item
}

///|
fn rr_test_reject(report : Json) -> Unit raise {
  try @qti.assessment_result_xml(report) catch {
    @qti.InvalidResponse(_)
    | @qti.InvalidItem(_, _)
    | @qti.Unsupported(_, _)
    | @qti.LimitExceeded(_) => ()
    _ => fail("unexpected result export error")
  } noraise {
    _ => fail("expected invalid result report rejection")
  }
}

///|
test "QTI result XML uses standard namespace and ItemRef identifiers" {
  let xml = @qti.assessment_result_xml(rr_test_report())
  assert_true(xml.has_prefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
  assert_true(
    xml.contains(
      "<assessmentResult xmlns=\"http://www.imsglobal.org/xsd/imsqti_result_v3p0\"",
    ),
  )
  assert_true(xml.contains("<context sourcedId=\"candidate_1\">"))
  assert_true(xml.contains("<testResult identifier=\"TEST\""))
  assert_true(
    xml.contains("<itemResult identifier=\"REF_1\" sequenceIndex=\"1\""),
  )
  assert_true(
    xml.contains(
      "<responseVariable identifier=\"numAttempts\" cardinality=\"single\" baseType=\"integer\"><candidateResponse><value>1</value>",
    ),
  )
  assert_true(
    xml.contains(
      "<responseVariable identifier=\"duration\" cardinality=\"single\" baseType=\"float\"><candidateResponse><value>12.5</value>",
    ),
  )
  assert_false(xml.contains("ITEM_1"))
  assert_false(xml.contains("qti-assessment-result"))
}

///|
test "QTI result XML preserves ordered duplicates and exports NULL without values" {
  let report = rr_test_report()
  let item = rr_test_item(report)
  ignore(
    rr_test_update(item, "response", {
      "ORDER": ["B", "A", "B"],
      "EMPTY": Json::null(),
      "ZERO": 0,
    }),
  )
  ignore(
    rr_test_update(item, "response_types", {
      "ORDER": { "base_type": "identifier", "cardinality": "ordered" },
      "EMPTY": { "base_type": "string", "cardinality": "single" },
      "ZERO": { "base_type": "integer", "cardinality": "single" },
    }),
  )
  let xml = @qti.assessment_result_xml(report)
  assert_true(xml.contains("<value>B</value><value>A</value><value>B</value>"))
  assert_true(
    xml.contains(
      "identifier=\"EMPTY\" cardinality=\"single\" baseType=\"string\"><candidateResponse></candidateResponse>",
    ),
  )
  assert_true(
    xml.contains(
      "identifier=\"ZERO\" cardinality=\"single\" baseType=\"integer\"><candidateResponse><value>0</value>",
    ),
  )
  assert_false(xml.contains("<value>null</value>"))
}

///|
test "QTI result XML escapes Unicode text and ignores authored answer metadata" {
  let report = rr_test_report()
  let item = rr_test_item(report)
  ignore(
    rr_test_update(item, "response", {
      "TEXT": "中文 < & > \" '\n第二行\t😀",
    }),
  )
  ignore(
    rr_test_update(item, "response_types", {
      "TEXT": { "base_type": "string", "cardinality": "single" },
    }),
  )
  ignore(
    rr_test_update(item, "correct_response", { "SECRET": "ANSWER_SENTINEL" }),
  )
  ignore(rr_test_update(item, "trace", "TRACE_SENTINEL"))
  ignore(rr_test_update(report, "mapping", "MAPPING_SENTINEL"))
  let xml = @qti.assessment_result_xml(report)
  assert_true(
    xml.contains("中文 &lt; &amp; &gt; &quot; &apos;&#xA;第二行&#x9;😀"),
  )
  assert_false(xml.contains("SENTINEL"))
  assert_false(xml.contains("correctResponse"))
  assert_false(xml.contains("mapping"))
}

///|
test "QTI result XML validates calendar timestamps and anonymous identifiers" {
  for
    date in [
      "2025-02-29T12:00:00Z", "2026-13-01T12:00:00Z", "2026-10-30T24:00:00Z", "2026-10-30T12:00:60Z",
      "2026-10-30T12:00:00.Z", "2026-10-30T12:00:00+08:00", "2026-10-30",
    ] {
    rr_test_reject(rr_test_update(rr_test_report(), "datestamp", Json(date)))
  }
  assert_true(
    @qti.assessment_result_xml(
      rr_test_update(rr_test_report(), "datestamp", "2024-02-29T00:00:00Z"),
    ).contains("2024-02-29T00:00:00Z"),
  )
  rr_test_reject(
    rr_test_update(rr_test_report(), "session_identifier", "bad:id"),
  )
  rr_test_reject(
    rr_test_update(rr_test_report(), "candidate_identifier", "display name"),
  )
  let anonymous = @qti.assessment_result_xml(
    rr_test_update(rr_test_report(), "candidate_identifier", Json::null()),
  )
  assert_true(anonymous.contains("<context>"))
  assert_false(anonymous.contains("sourcedId"))
}

///|
test "QTI result XML rejects nonfinite fractional or invalid built-in values" {
  for
    update in [
      ("num_attempts", Json(-1)),
      ("num_attempts", Json(1.5)),
      ("duration", Json(-1)),
      ("duration", Json(1.0 / 0.0)),
      ("sequence_index", Json(0)),
      ("session_status", Json("closed")),
    ] {
    let report = rr_test_report()
    ignore(rr_test_update(rr_test_item(report), update.0, update.1))
    rr_test_reject(report)
  }
  let initial = rr_test_report()
  ignore(rr_test_update(rr_test_item(initial), "session_status", "initial"))
  rr_test_reject(initial)
}

///|
test "QTI result XML rejects mismatched types undeclared and reserved variables" {
  let cases : Array[(Json, Json)] = [
    (
      { "RESPONSE": 1 },
      { "RESPONSE": { "base_type": "identifier", "cardinality": "single" } },
    ),
    (
      { "RESPONSE": ["A"] },
      { "RESPONSE": { "base_type": "identifier", "cardinality": "single" } },
    ),
    (
      { "RESPONSE": "A" },
      { "RESPONSE": { "base_type": "identifier", "cardinality": "multiple" } },
    ),
    (
      { "EXTRA": "A" },
      { "RESPONSE": { "base_type": "identifier", "cardinality": "single" } },
    ),
    (
      { "duration": 3 },
      { "duration": { "base_type": "float", "cardinality": "single" } },
    ),
    (
      { "RESPONSE": "A" },
      { "RESPONSE": { "base_type": "file", "cardinality": "single" } },
    ),
  ]
  for entry in cases {
    let report = rr_test_report()
    let item = rr_test_item(report)
    ignore(rr_test_update(item, "response", entry.0))
    ignore(rr_test_update(item, "response_types", entry.1))
    rr_test_reject(report)
  }
}

///|
test "QTI result XML limits and duplicate ItemRef rejection are deterministic" {
  let report = rr_test_report()
  let item = rr_test_item(report)
  ignore(rr_test_update(report, "items", [item, item]))
  rr_test_reject(report)
  let report = rr_test_report()
  ignore(
    rr_test_update(
      report,
      "items",
      Json(Array::make(513, rr_test_item(report))),
    ),
  )
  rr_test_reject(report)
  assert_eq(
    @qti.assessment_result_xml(rr_test_report()),
    @qti.assessment_result_xml(rr_test_report()),
  )
}

///|
test "QTI result XML supports boolean numeric and directedPair results" {
  let report = rr_test_report()
  ignore(
    rr_test_update(report, "outcomes", {
      "PASS": true,
      "COUNT": 4,
      "MATCH": ["A B", "B C"],
    }),
  )
  ignore(
    rr_test_update(report, "test_outcome_types", {
      "PASS": { "base_type": "boolean", "cardinality": "single" },
      "COUNT": { "base_type": "integer", "cardinality": "single" },
      "MATCH": { "base_type": "directedPair", "cardinality": "multiple" },
    }),
  )
  let xml = @qti.assessment_result_xml(report)
  assert_true(xml.contains("<value>true</value>"))
  assert_true(xml.contains("<value>4</value>"))
  assert_true(xml.contains("<value>A B</value><value>B C</value>"))
}
