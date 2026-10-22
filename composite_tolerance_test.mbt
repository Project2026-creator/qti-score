///|
fn composite_tolerance_rejected(xml : String, code : String) -> Unit raise {
  try @qti.compile_composite_item(xml) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("invalid composite tolerance rule accepted")
  }
}

///|
test "composite tolerance tiers use only the first true branch per response" {
  let item = @qti.compile_composite_item(fixture("composite-tolerance"))
  for
    (value, score) in [
      (100.0, 3.0),
      (99.0, 2.0),
      (101.0, 2.0),
      (100.5, 2.0),
      (98.999, 1.0),
      (95.0, 1.0),
      (105.0, 1.0),
      (94.999, 0.0),
      (105.001, 0.0),
    ] {
    let response : Map[String, @qti.Response] = { "LENGTH": Number(value) }
    assert_eq(item.score_responses(response).score, score)
    let trace = item.explain_responses(response)
    assert_eq(trace.result.score, score)
    assert_true(
      trace.steps.filter(s => s.operation == "composite_add").length() <= 1,
    )
  }
  assert_eq(
    item.score_json("{\"UNIT\":\"cm\",\"LENGTH\":100,\"GROUPS\":4}").score,
    5.0,
  )
  assert_eq(
    item.score_json("{\"UNIT\":\"cm\",\"LENGTH\":100.5,\"GROUPS\":4}").score,
    4.0,
  )
}

///|
test "composite equality propagates NULL without adding a partial contribution" {
  let item = @qti.compile_composite_item(fixture("composite-tolerance"))
  for input in ["{}", "{\"LENGTH\":null}", "{\"LENGTH\":\" \"}"] {
    let trace = item.explain_json(input)
    assert_eq(trace.result.score, 0.0)
    assert_eq(trace.result.status, Unanswered)
    assert_true(
      trace.steps.any(s => {
        s.details
        is {
          "identifier": String("LENGTH"),
          "condition": { "reason": String("null_operand"), "matched": Null, .. },
          "selected": False,
          ..
        }
      }),
    )
    assert_true(!trace.steps.any(s => s.operation == "composite_add"))
  }
  assert_eq(item.score_json("{\"UNIT\":\"cm\"}").score, 1.0)
  assert_eq(item.score_json("{\"LENGTH\":0}").status, Answered)
}

///|
test "composite asymmetric tolerances and exclusive boundaries retain authored order" {
  let source = fixture("composite-tolerance").swap(
    "tolerance-mode=\"absolute\" tolerance=\"1\"", "tolerance-mode=\"absolute\" tolerance=\"2 3\" include-lower-bound=\"false\" include-upper-bound=\"false\"",
  )
  let item = @qti.compile_composite_item(source)
  for
    (value, score) in [
      (98.0, 1.0),
      (103.0, 1.0),
      (98.0001, 2.0),
      (102.9999, 2.0),
    ] {
    assert_eq(item.score_responses({ "LENGTH": Number(value) }).score, score)
  }
  let reversed = @qti.compile_composite_item(
    source
    .swap(
      "<qti-correct identifier=\"LENGTH\"/><qti-variable identifier=\"LENGTH\"/>",
      "<qti-variable identifier=\"LENGTH\"/><qti-correct identifier=\"LENGTH\"/>",
    )
    .swap("tolerance-mode=\"relative\"", "tolerance-mode=\"absolute\""),
  )
  // With x = the learner value, 97.5 + 3 includes the correct value 100.
  assert_eq(reversed.score_json("{\"LENGTH\":97.5}").score, 2.0)
}

///|
test "composite literal references work without correct declarations" {
  let source = fixture("composite-tolerance")
    .swap(
      "<qti-correct-response><qti-value>100</qti-value></qti-correct-response>",
      "",
    )
    .swap(
      "<qti-correct identifier=\"LENGTH\"/>", "<qti-base-value base-type=\"float\">100</qti-base-value>",
    )
  let item = @qti.compile_composite_item(source)
  assert_eq(item.score_json("{\"LENGTH\":100.5}").score, 2.0)
  assert_eq(item.score_json("{\"LENGTH\":100}").matches_correct, None)
  assert_eq(item.score_json("{\"LENGTH\":\"1e2\"}").score, 3.0)
}

///|
test "composite tolerance success stays independent of exact correct matching" {
  let item = @qti.compile_composite_item(fixture("composite-tolerance"))
  assert_eq(
    item.score_json("{\"UNIT\":\"cm\",\"LENGTH\":100.5,\"GROUPS\":4}").matches_correct,
    Some(false),
  )
  assert_eq(
    item.score_json("{\"UNIT\":\"cm\",\"LENGTH\":100,\"GROUPS\":4}").matches_correct,
    Some(true),
  )
  assert_eq(
    item.score_json("{\"UNIT\":\"CM\",\"LENGTH\":100,\"GROUPS\":4}").score,
    4.0,
  )
}

///|
test "composite tolerance rejects invalid author parameters before scoring" {
  let source = fixture("composite-tolerance")
  for replacement in ["0", "-1", "NaN", "1 2 3", "1e309"] {
    composite_tolerance_rejected(
      source.swap("tolerance=\"1\"", "tolerance=\"\{replacement}\""),
      "invalid_item",
    )
  }
  composite_tolerance_rejected(
    source.swap("tolerance-mode=\"relative\"", "tolerance-mode=\"unknown\""),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source.swap("tolerance-mode=\"absolute\"", "tolerance-mode=\"exact\""),
    "unsupported",
  )
  composite_tolerance_rejected(
    source.swap(
      "tolerance=\"1\"", "tolerance=\"1\" include-upper-bound=\"maybe\"",
    ),
    "invalid_item",
  )
}

///|
test "composite numeric predicates reject text and cross-response references" {
  let source = fixture("composite-tolerance")
  composite_tolerance_rejected(
    source
    .swap("<qti-match>", "<qti-equal>")
    .swap("</qti-match>", "</qti-equal>"),
    "unsupported",
  )
  composite_tolerance_rejected(
    source.swap(
      "<qti-correct identifier=\"LENGTH\"/>", "<qti-correct identifier=\"GROUPS\"/>",
    ),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source.swap(
      "<qti-correct identifier=\"LENGTH\"/>", "<qti-variable identifier=\"LENGTH\"/>",
    ),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source.swap(
      "<qti-variable identifier=\"LENGTH\"/>", "<qti-base-value base-type=\"float\">100</qti-base-value>",
    ),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source.swap(
      "<qti-correct-response><qti-value>100</qti-value></qti-correct-response>",
      "",
    ),
    "invalid_item",
  )
}

///|
test "composite relative comparisons require a nonnegative fixed first operand" {
  let source = fixture("composite-tolerance")
  composite_tolerance_rejected(
    source.swap(
      "<qti-correct identifier=\"LENGTH\"/><qti-variable identifier=\"LENGTH\"/>",
      "<qti-variable identifier=\"LENGTH\"/><qti-correct identifier=\"LENGTH\"/>",
    ),
    "unsupported",
  )
  composite_tolerance_rejected(
    source.swap("<qti-value>100</qti-value>", "<qti-value>-100</qti-value>"),
    "unsupported",
  )
  composite_tolerance_rejected(
    source
    .swap("<qti-value>100</qti-value>", "<qti-value>1e308</qti-value>")
    .swap("tolerance=\"5\"", "tolerance=\"1000\""),
    "invalid_item",
  )
}

///|
test "composite branch ordering and same-response ownership are validated" {
  let source = fixture("composite-tolerance")
  composite_tolerance_rejected(
    source
    .swap("<qti-response-else-if>", "<qti-response-if>")
    .swap("</qti-response-else-if>", "</qti-response-if>"),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source
    .swap("<qti-response-else-if>", "<qti-response-else>")
    .swap("</qti-response-else-if>", "</qti-response-else>"),
    "invalid_item",
  )
  composite_tolerance_rejected(
    source.swap(
      "tolerance=\"1\"><qti-correct identifier=\"LENGTH\"/><qti-variable identifier=\"LENGTH\"/>",
      "tolerance=\"1\"><qti-correct identifier=\"GROUPS\"/><qti-variable identifier=\"GROUPS\"/>",
    ),
    "invalid_item",
  )
}

///|
test "composite tier count is bounded without changing the response limit" {
  let extra = StringBuilder()
  for _ in 0..<128 {
    extra.write_string(
      "<qti-response-else-if><qti-equal><qti-variable identifier=\"LENGTH\"/><qti-correct identifier=\"LENGTH\"/></qti-equal><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">1</qti-base-value></qti-sum></qti-set-outcome-value></qti-response-else-if>",
    )
  }
  composite_tolerance_rejected(
    fixture("composite-tolerance").swap(
      "</qti-response-else-if>",
      "</qti-response-else-if>" + extra.to_string(),
    ),
    "limit_exceeded",
  )
}

///|
test "composite comparison explanations retain interval, branch and XML location" {
  let item = @qti.compile_composite_item(fixture("composite-tolerance"))
  let trace = item.explain_json("{\"LENGTH\":100.5}")
  assert_true(
    trace.steps.any(s => {
      s.operation == "composite_condition" &&
      s.location.line > 0 &&
      s.details
      is {
        "identifier": String("LENGTH"),
        "branch": Number(1.0, ..),
        "selected": True,
        "condition": {
          "mode": String("absolute"),
          "reference": Number(100.0, ..),
          "value": Number(100.5, ..),
          "lower": Number(99.0, ..),
          "upper": Number(101.0, ..),
          ..
        },
        ..
      }
    }),
  )
  assert_eq(
    trace.steps
    .filter(s => {
      s.details is { "identifier": String("LENGTH"), "selected": _, .. }
    })
    .length(),
    2,
  )
  let info = item.describe().stringify()
  assert_true(
    !info.contains("tolerance") &&
    !info.contains("correct") &&
    !info.contains("branches"),
  )
}

///|
test "composite numeric tiers keep invalid attempts isolated and score reset" {
  let item = @qti.compile_composite_item(fixture("composite-tolerance"))
  assert_eq(item.score_json("{\"LENGTH\":100}").score, 3.0)
  for
    input in [
      "{\"UNIT\":\"cm\",\"LENGTH\":\"bad\"}", "{\"GROUPS\":4.5}", "{\"LENGTH\":true}",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("invalid attempt scored")
    }
  }
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"LENGTH\":100.5}").score, 2.0)
}

///|
test "composite comparison overflow fails the attempt and negative weights remain finite" {
  let source = fixture("composite-tolerance")
    .swap(
      "<qti-correct identifier=\"LENGTH\"/><qti-variable identifier=\"LENGTH\"/>",
      "<qti-variable identifier=\"LENGTH\"/><qti-correct identifier=\"LENGTH\"/>",
    )
    .swap("tolerance-mode=\"relative\"", "tolerance-mode=\"absolute\"")
    .swap("tolerance=\"1\"", "tolerance=\"1e308\"")
  let item = @qti.compile_composite_item(source)
  try item.score_json("{\"LENGTH\":1e308}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("overflow accepted")
  }
  let negative = @qti.compile_composite_item(
    fixture("composite-tolerance").swap(
      "<qti-base-value base-type=\"float\">3</qti-base-value>", "<qti-base-value base-type=\"float\">-1.5</qti-base-value>",
    ),
  )
  assert_eq(negative.score_json("{\"LENGTH\":100}").score, -1.5)
}

///|
test "composite tolerance package batches share core evaluation and row-local errors" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-tolerance-manifest.xml"),
      ),
      ("items/composite-tolerance.xml", fixture("composite-tolerance")),
      ("items/composite.xml", fixture("composite")),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-tolerance-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 6)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(7.0),
    Some(4.0),
    Some(1.0),
    None,
    Some(0.0),
    Some(3.0),
  ])
}
