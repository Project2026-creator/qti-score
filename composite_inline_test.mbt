///|
fn composite_inline_rejected(xml : String, code : String) -> Unit raise {
  try @qti.compile_composite_item(xml) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("invalid mixed composite accepted")
  }
}

///|
test "composite inline choice mappings combine with independent numeric tolerance tiers" {
  let item = @qti.compile_composite_item(fixture("composite-inline"))
  for
    (input, expected) in [
      ("{\"ACTION\":\"Adapt\",\"RATIO\":75}", 4.0),
      ("{\"ACTION\":\"Review\",\"RATIO\":75}", 2.5),
      ("{\"ACTION\":\"Adapt\",\"RATIO\":74.5}", 3.0),
      ("{\"ACTION\":\"Ignore\",\"RATIO\":74.5}", 1.0),
      ("{\"ACTION\":\"Adapt\"}", 2.0),
      ("{\"RATIO\":75}", 2.0),
      ("{}", 0.0),
    ] {
    let result = item.score_json(input)
    assert_eq(result.score, expected)
    assert_eq(item.explain_json(input).result, result)
  }
  assert_eq(item.score_json("{}").status, Unanswered)
  assert_eq(item.score_json("{\"ACTION\":\"Ignore\"}").status, Answered)
  assert_eq(
    item.score_json("{\"ACTION\":\"Adapt\",\"RATIO\":75}").matches_correct,
    Some(true),
  )
}

///|
test "composite inline identifiers are case sensitive even with default map flags" {
  let item = @qti.compile_composite_item(
    fixture("composite-inline").swap("Review", "adapt"),
  )
  assert_eq(item.score_json("{\"ACTION\":\"Adapt\"}").score, 2.0)
  assert_eq(item.score_json("{\"ACTION\":\"adapt\"}").score, 0.5)
  try item.score_json("{\"ACTION\":\"ADAPT\"}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("identifier case was folded")
  }
}

///|
test "composite required inline choices reject every normalized missing response" {
  let item = @qti.compile_composite_item(fixture("composite-inline-required"))
  for
    input in [
      "{}", "{\"METHOD\":\"Formative\"}", "{\"METHOD\":\"Formative\",\"ACTION\":null}",
      "{\"METHOD\":\"Formative\",\"ACTION\":\"\"}",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("missing required choice scored")
    }
  }
  assert_eq(
    item.score_json("{\"METHOD\":\"Formative\",\"ACTION\":\"Adapt\"}").score,
    2.0,
  )
  assert_eq(
    item.score_json("{\"METHOD\":\"Summative\",\"ACTION\":\"Ignore\"}").score,
    0.0,
  )
}

///|
test "composite optional inline NULL skips mapping bounds and preserves field status" {
  let item = @qti.compile_composite_item(
    fixture("composite-inline").swap("lower-bound=\"0\"", "lower-bound=\"1\""),
  )
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"ACTION\":\"\",\"RATIO\":75}").score, 2.0)
  assert_eq(item.score_json("{\"ACTION\":\"Ignore\"}").score, 1.0)
  let trace = item.explain_json("{\"RATIO\":75}")
  assert_true(
    trace.steps.any(s => {
      s.operation == "response" &&
      s.details
      is { "identifier": String("ACTION"), "status": String("unanswered"), .. }
    }),
  )
}

///|
test "composite inline choices validate scalar shape, selected ID and independent option sets" {
  let item = @qti.compile_composite_item(fixture("composite-inline-required"))
  for
    input in [
      "{\"METHOD\":\"Adapt\",\"ACTION\":\"Adapt\"}", "{\"METHOD\":\"Formative\",\"ACTION\":\"Formative\"}",
      "{\"METHOD\":\"Formative\",\"ACTION\":\" Adapt\"}", "{\"METHOD\":\"Formative\",\"ACTION\":[\"Adapt\"]}",
      "{\"METHOD\":\"Formative\",\"ACTION\":1}", "{\"METHOD\":\"Formative\",\"ACTION\":true}",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("invalid choice scored")
    }
  }
}

///|
test "composite inline descriptions preserve authored positions without flattening option labels" {
  let item = @qti.compile_composite_item(fixture("composite-inline"))
  let metadata = item.describe()
  assert_true(
    metadata
    is {
      "responses": [
        {
          "identifier": String("ACTION"),
          "base_type": String("identifier"),
          "inline_choice": {
            "required": False,
            "label": String("学习行动"),
            "choices": [_, _, _],
            ..
          },
          ..
        },
        { "identifier": String("RATIO"), "base_type": String("float"), .. },
      ],
      ..
    },
  )
  guard metadata is { "passage": Array(passage), .. } else {
    fail("missing passage")
  }
  assert_eq(passage.filter(p => p is { "response": _, .. }).length(), 2)
  assert_true(
    !Json(passage).stringify().contains("调整策略并再次尝试"),
  )
  assert_true(
    !metadata.stringify().contains("mapped-value") &&
    !metadata.stringify().contains("correct"),
  )
  guard metadata is { "responses": Array(bindings), .. } else {
    fail("missing responses")
  }
  bindings.clear()
  assert_true(item.describe() is { "responses": [_, _], .. })
  assert_eq(item.score_json("{\"ACTION\":\"Adapt\"}").score, 2.0)
}

///|
test "composite inline metadata marks required and min-choices independently" {
  let item = @qti.compile_composite_item(fixture("composite-inline-required"))
  assert_true(
    item.describe()
    is {
      "responses": [
        { "inline_choice": { "required": True, .. }, .. },
        { "inline_choice": { "required": True, .. }, .. },
      ],
      ..
    },
  )
  let optional = @qti.compile_composite_item(
    fixture("composite-inline-required")
    .swap("required=\"true\"", "required=\"false\"")
    .swap("min-choices=\"1\"", "min-choices=\"0\""),
  )
  assert_eq(optional.score_json("{}").status, Unanswered)
}

///|
test "composite inline correct responses and mappings must reference declared options" {
  let source = fixture("composite-inline")
  for
    xml in [
      source.swap(
        "<qti-value>Adapt</qti-value>", "<qti-value>Missing</qti-value>",
      ),
      source.swap("map-key=\"Review\"", "map-key=\"Missing\""),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => {
        assert_eq(e.code(), "invalid_item")
        assert_true(e.location() is Some({ line: 3, .. }))
      }
    } noraise {
      _ => fail("undeclared choice accepted")
    }
  }
}

///|
test "composite inline interaction and declaration types must agree" {
  composite_inline_rejected(
    fixture("composite-inline").swap(
      "base-type=\"identifier\"", "base-type=\"string\"",
    ),
    "invalid_item",
  )
  composite_inline_rejected(
    fixture("composite-inline").swap(
      "base-type=\"float\"", "base-type=\"identifier\"",
    ),
    "invalid_item",
  )
  composite_inline_rejected(
    fixture("composite-inline").swap(
      "response-identifier=\"ACTION\"", "response-identifier=\"RATIO\"",
    ),
    "invalid_item",
  )
  composite_inline_rejected(
    fixture("composite-inline").swap(
      "cardinality=\"single\" base-type=\"identifier\"", "cardinality=\"multiple\" base-type=\"identifier\"",
    ),
    "unsupported",
  )
}

///|
test "composite inline option validation reuses static text and shuffle restrictions" {
  let source = fixture("composite-inline")
  for
    xml in [
      source.swap("identifier=\"Review\"", "identifier=\"Adapt\""),
      source.swap("identifier=\"Review\"", "identifier=\"ACTION\""),
      source.swap("identifier=\"Review\"", "identifier=\"SCORE\""),
      source.swap("只重读反馈", " "),
      source.swap("data-prompt=\"请选择行动\"", "min-choices=\"2\""),
    ] {
    composite_inline_rejected(xml, "invalid_item")
  }
  composite_inline_rejected(
    source.swap("data-prompt=\"请选择行动\"", "shuffle=\"true\""),
    "unsupported",
  )
  composite_inline_rejected(
    source.swap("只重读反馈", "<img src=\"x\"/>"),
    "unsupported",
  )
}

///|
test "composite inline keys remain scoped while the same ID may be used by separate fields" {
  let item = @qti.compile_composite_item(
    fixture("composite-inline-required").swap("Summative", "Ignore"),
  )
  assert_eq(
    item.score_json("{\"METHOD\":\"Ignore\",\"ACTION\":\"Ignore\"}").score,
    0.0,
  )
  assert_eq(
    item.score_json("{\"METHOD\":\"Formative\",\"ACTION\":\"Adapt\"}").score,
    2.0,
  )
}

///|
test "composite inline namespaces, CDATA and hostile text remain plain metadata" {
  let source = fixture("composite-inline").swap(
    "只重读反馈", "<![CDATA[<script>example</script>]]>",
  )
  let prefixed = source
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</p>", "</h:p>")
  let a = @qti.compile_composite_item(source)
  let b = @qti.compile_composite_item(prefixed)
  assert_eq(a.describe(), b.describe())
  assert_true(a.describe().stringify().contains("<script>example</script>"))
  assert_eq(a.score_json("{\"ACTION\":\"Review\"}").score, 0.5)
}

///|
test "composite inline typed APIs preserve responses and recover after invalid attempts" {
  let item = @qti.compile_composite_item(fixture("composite-inline"))
  let input : Map[String, @qti.Response] = {
    "ACTION": Single("Adapt"),
    "RATIO": Number(75.0),
  }
  assert_eq(item.score_responses(input).score, 4.0)
  assert_eq(input["ACTION"], Single("Adapt"))
  try item.score_responses({ "ACTION": Multiple(["Adapt"]) }) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("array accepted")
  }
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.explain_responses(input).result.score, 4.0)
}

///|
test "composite inline packages preserve required errors in batch rows and summaries" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-inline-manifest.xml"),
      ),
      ("items/composite-inline.xml", fixture("composite-inline")),
      (
        "items/composite-inline-required.xml",
        fixture("composite-inline-required"),
      ),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-inline-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 6)
  assert_eq(report.error_count, 2)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(6.0),
    Some(1.5),
    Some(2.0),
    None,
    None,
    Some(0.0),
    Some(0.0),
  ])
}
