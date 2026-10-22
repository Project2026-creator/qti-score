///|
fn fallback_branch(weight : String) -> String {
  "<qti-response-else><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">\{weight}</qti-base-value></qti-sum></qti-set-outcome-value></qti-response-else>"
}

///|
fn fallback_rejected(xml : String, code : String) -> Unit raise {
  try @qti.compile_composite_item(xml) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("invalid fallback accepted")
  }
}

///|
test "composite fallback separates unanswered, correct, partial and incorrect credit" {
  let item = @qti.compile_composite_item(fixture("composite-fallback"))
  for
    (input, expected) in [
      ("{\"ACTION\":\"Adapt\",\"RATIO\":75}", 4.0),
      ("{\"ACTION\":\"Adapt\",\"RATIO\":74.5}", 3.0),
      ("{\"ACTION\":\"Adapt\",\"RATIO\":80}", 1.5),
      ("{\"ACTION\":\"Ignore\",\"RATIO\":75}", 1.0),
      ("{\"ACTION\":\"Ignore\",\"RATIO\":80}", -1.5),
      ("{\"RATIO\":75}", 2.0),
      ("{\"ACTION\":\"Adapt\"}", 2.0),
      ("{\"ACTION\":\"Ignore\"}", -1.0),
      ("{\"RATIO\":80}", -0.5),
      ("{}", 0.0),
    ] {
    assert_eq(item.score_json(input).score, expected)
    assert_eq(item.explain_json(input).result.score, expected)
  }
}

///|
test "composite first true branch prevents later fallback and lower tier credit" {
  let item = @qti.compile_composite_item(fixture("composite-fallback"))
  let trace = item.explain_json("{\"ACTION\":\"Adapt\",\"RATIO\":75}")
  assert_eq(trace.steps.filter(s => s.operation == "composite_add").length(), 2)
  assert_true(
    !trace.steps.any(s => {
      s.details is { "condition": { "operator": String("else"), .. }, .. }
    }),
  )
  let wrong = item.explain_json("{\"RATIO\":80}")
  assert_true(
    wrong.steps.any(s => {
      s.operation == "composite_condition" &&
      s.location.line > 0 &&
      s.details
      is {
        "identifier": String("RATIO"),
        "branch": Number(3.0, ..),
        "selected": True,
        "condition": { "operator": String("else"), "matched": True, .. },
        ..
      }
    }),
  )
  assert_eq(wrong.steps.filter(s => s.operation == "composite_add").length(), 2)
}

///|
test "composite authored NULL scores do not change response status or exact matching" {
  let pattern = "</qti-is-null><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">0</qti-base-value>"
  for (weight, total) in [("0.25", 0.5), ("-0.25", -0.5)] {
    let item = @qti.compile_composite_item(
      fixture("composite-fallback").swap(
        pattern,
        pattern.swap(">0</qti-base-value>", ">\{weight}</qti-base-value>"),
      ),
    )
    let result = item.score_json("{}")
    assert_eq(result.score, total)
    assert_eq(result.status, Unanswered)
    assert_eq(result.matches_correct, Some(false))
  }
  let item = @qti.compile_composite_item(fixture("composite-fallback"))
  let trace = item.explain_json("{\"ACTION\":\"\",\"RATIO\":\" \"}")
  assert_eq(trace.result.status, Unanswered)
  assert_true(
    trace.steps.any(s => {
      s.details
      is {
        "condition": { "operator": String("is_null"), "matched": True, .. },
        ..
      }
    }),
  )
  let text = @qti.compile_composite_item(
    fixture("composite")
    .swap(
      "<qti-not><qti-is-null><qti-variable identifier=\"PLATFORM\"/></qti-is-null></qti-not>",
      "<qti-is-null><qti-variable identifier=\"PLATFORM\"/></qti-is-null>",
    )
    .swap(
      "<qti-map-response identifier=\"PLATFORM\"/>", "<qti-base-value base-type=\"float\">0.25</qti-base-value>",
    ),
  )
  assert_eq(text.score_json("{}").score, 0.25)
  assert_eq(text.score_json("{\"PLATFORM\":\" \"}").score, 0.0)
  let integer = @qti.compile_composite_item(
    fixture("composite").swap(
      "<qti-match><qti-variable identifier=\"COUNT\"/><qti-correct identifier=\"COUNT\"/></qti-match>",
      "<qti-is-null><qti-variable identifier=\"COUNT\"/></qti-is-null>",
    ),
  )
  assert_eq(integer.score_json("{\"COUNT\":\" \"}").score, 2.0)
  assert_eq(integer.score_json("{\"COUNT\":0}").score, 0.0)
}

///|
test "composite NULL numerical predicates proceed to authored else when no NULL branch exists" {
  let source = fixture("composite-tolerance").swap(
    "</qti-response-else-if>\n    </qti-response-condition>",
    "</qti-response-else-if>" +
    fallback_branch("-1") +
    "\n    </qti-response-condition>",
  )
  let item = @qti.compile_composite_item(source)
  let trace = item.explain_json("{}")
  assert_eq(trace.result.score, -1.0)
  assert_eq(trace.result.status, Unanswered)
  assert_true(
    trace.steps.any(s => {
      s.details
      is {
        "condition": { "reason": String("null_operand"), .. },
        "selected": False,
        ..
      }
    }),
  )
  assert_true(
    trace.steps.any(s => {
      s.details
      is {
        "condition": { "operator": String("else"), .. },
        "selected": True,
        ..
      }
    }),
  )
}

///|
test "composite required input validation runs before NULL or else rules" {
  let item = @qti.compile_composite_item(
    fixture("composite-fallback").swap(
      "response-identifier=\"ACTION\">", "response-identifier=\"ACTION\" required=\"true\">",
    ),
  )
  for
    input in ["{}", "{\"RATIO\":75}", "{\"ACTION\":null}", "{\"ACTION\":\"\"}"] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("required input bypassed")
    }
  }
  assert_eq(item.score_json("{\"ACTION\":\"Ignore\"}").score, -1.0)
}

///|
test "composite else is unique and last and cannot replace the owning response-if" {
  let source = fixture("composite-fallback")
  fallback_rejected(
    source.swap(
      "</qti-response-else>",
      "</qti-response-else>" + fallback_branch("0"),
    ),
    "invalid_item",
  )
  fallback_rejected(
    source
    .swap("<qti-response-if>", "<qti-response-else>")
    .swap("</qti-response-if>", "</qti-response-else>"),
    "invalid_item",
  )
  fallback_rejected(
    source.swap(
      fallback_branch("-1"),
      fallback_branch("-1") + "<qti-response-else-if/>",
    ),
    "invalid_item",
  )
}

///|
test "composite else only accepts one literal contribution to SCORE" {
  let source = fixture("composite-fallback")
  fallback_rejected(
    source.swap(fallback_branch("-1"), "<qti-response-else/>"),
    "invalid_item",
  )
  fallback_rejected(
    source.swap(
      fallback_branch("-1"),
      fallback_branch("-1").swap(
        "<qti-base-value base-type=\"float\">-1</qti-base-value>", "<qti-map-response identifier=\"ACTION\"/>",
      ),
    ),
    "unsupported",
  )
  fallback_rejected(
    source.swap(
      fallback_branch("-1"),
      fallback_branch("-1").swap(
        "identifier=\"SCORE\"", "identifier=\"ACTION\"",
      ),
    ),
    "unsupported",
  )
  fallback_rejected(
    source.swap(
      fallback_branch("-1"),
      fallback_branch("-1").swap(
        "<qti-sum><qti-variable identifier=\"SCORE\"/>", "<qti-sum><qti-variable identifier=\"ACTION\"/>",
      ),
    ),
    "invalid_item",
  )
}

///|
test "composite is-null requires exactly one declared response variable and keeps branch ownership" {
  let source = fixture("composite-fallback")
  fallback_rejected(
    source.swap(
      "<qti-is-null><qti-variable identifier=\"ACTION\"/></qti-is-null>", "<qti-is-null><qti-variable identifier=\"ACTION\"/><qti-variable identifier=\"ACTION\"/></qti-is-null>",
    ),
    "invalid_item",
  )
  fallback_rejected(
    source.swap(
      "<qti-is-null><qti-variable identifier=\"ACTION\"/></qti-is-null>", "<qti-is-null><qti-variable identifier=\"OTHER\"/></qti-is-null>",
    ),
    "invalid_item",
  )
  fallback_rejected(
    source.swap(
      "<qti-is-null><qti-variable identifier=\"ACTION\"/></qti-is-null>", "<qti-is-null><qti-variable identifier=\"RATIO\"/></qti-is-null>",
    ),
    "invalid_item",
  )
  fallback_rejected(
    source.swap(
      "<qti-is-null><qti-variable identifier=\"ACTION\"/></qti-is-null>", "<qti-is-null><qti-correct identifier=\"ACTION\"/></qti-is-null>",
    ),
    "unsupported",
  )
}

///|
test "composite fallback never turns invalid response values into wrong-answer scores" {
  let item = @qti.compile_composite_item(fixture("composite-fallback"))
  for
    input in [
      "{\"RATIO\":\"bad\"}", "{\"ACTION\":\"Unknown\"}", "{\"RATIO\":[]}", "{\"OTHER\":1}",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("invalid input became a penalty")
    }
  }
  assert_eq(item.score_json("{\"ACTION\":\"Ignore\",\"RATIO\":80}").score, -1.5)
  assert_eq(item.score_json("{}").score, 0.0)
  assert_true(!item.describe().stringify().contains("operator"))
}

///|
test "composite fallback weights and accumulated results must remain finite" {
  let source = fixture("composite-fallback")
  for weight in ["NaN", "Infinity", "1e309"] {
    fallback_rejected(
      source.swap(fallback_branch("-1"), fallback_branch(weight)),
      "invalid_item",
    )
  }
  let item = @qti.compile_composite_item(
    source
    .swap(fallback_branch("-1"), fallback_branch("1e308"))
    .swap(fallback_branch("-0.5"), fallback_branch("1e308")),
  )
  try item.score_json("{\"ACTION\":\"Ignore\",\"RATIO\":80}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("sum overflow accepted")
  }
}

///|
test "composite branch budget includes the trailing else and accepts exactly 128 branches" {
  let extra = StringBuilder()
  let branch = "<qti-response-else-if><qti-is-null><qti-variable identifier=\"RATIO\"/></qti-is-null><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">0</qti-base-value></qti-sum></qti-set-outcome-value></qti-response-else-if>"
  for _ in 0..<124 {
    extra.write_string(branch)
  }
  let at_limit = fixture("composite-fallback").swap(
    fallback_branch("-0.5"),
    extra.to_string() + fallback_branch("-0.5"),
  )
  assert_eq(
    @qti.compile_composite_item(at_limit).score_json("{\"RATIO\":80}").score,
    -0.5,
  )
  fallback_rejected(
    at_limit.swap(fallback_branch("-0.5"), branch + fallback_branch("-0.5")),
    "limit_exceeded",
  )
}

///|
test "composite fallback package batch preserves negative, unanswered and failed rows" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-fallback-manifest.xml"),
      ),
      ("items/composite-fallback.xml", fixture("composite-fallback")),
      (
        "items/composite-inline-required.xml",
        fixture("composite-inline-required"),
      ),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-fallback-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 6)
  assert_eq(report.error_count, 2)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(6.0),
    Some(1.5),
    Some(1.0),
    Some(0.0),
    None,
    None,
    Some(-1.5),
  ])
}
