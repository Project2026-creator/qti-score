///|
test "composite text mapping and integer match combine authored contributions" {
  let item = @qti.compile_composite_item(fixture("composite"))
  for
    (input, expected) in [
      ("{\"PLATFORM\":\"LMS\",\"COUNT\":4}", 4.0),
      ("{\"PLATFORM\":\"lms\",\"COUNT\":\"04\"}", 3.0),
      ("{\"PLATFORM\":\"LMS\"}", 2.0),
      ("{\"COUNT\":4}", 2.0),
      ("{\"COUNT\":3}", 0.0),
      ("{}", 0.0),
    ] {
    let result = item.score_json(input)
    assert_eq(result.score, expected)
    assert_eq(item.explain_json(input).result, result)
  }
  assert_eq(item.score_json("{}").status, Unanswered)
  assert_eq(item.score_json("{\"COUNT\":3}").status, Answered)
  assert_eq(
    item.score_json("{\"PLATFORM\":\"LMS\",\"COUNT\":4}").matches_correct,
    Some(true),
  )
  assert_eq(
    item.score_json("{\"PLATFORM\":\"lms\",\"COUNT\":4}").matches_correct,
    Some(false),
  )
}

///|
test "composite numeric mappings and typed responses preserve input and missing members" {
  let item = @qti.compile_composite_item(fixture("composite-numeric"))
  let responses : Map[String, @qti.Response] = {
    "RATIO": Number(0.75),
    "TOTAL": Single("020"),
  }
  assert_eq(item.score_responses(responses).score, 3.0)
  assert_eq(item.explain_responses(responses).result.score, 3.0)
  assert_eq(responses["TOTAL"], Single("020"))
  assert_eq(item.score_json("{\"RATIO\":\"7e-1\"}").score, 1.0)
  assert_eq(item.score_json("{\"RATIO\":0.7500000000000001}").score, 0.0)
  assert_eq(
    item.score_json("{\"RATIO\":null,\"TOTAL\":\" \"}").status,
    Unanswered,
  )
}

///|
test "composite NULL guards skip positive mapping bounds and preserve literal whitespace" {
  let item = @qti.compile_composite_item(
    fixture("composite").swap("lower-bound=\"0\"", "lower-bound=\"1\""),
  )
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"PLATFORM\":\" \"}").score, 1.0)
  assert_eq(
    item.score_json("{\"PLATFORM\":\"\",\"COUNT\":\"\"}").status,
    Unanswered,
  )
  let trace = item.explain_json("{\"COUNT\":4}")
  assert_true(
    trace.steps.any(s => {
      s.operation == "composite_add" &&
      s.details
      is { "identifier": String("COUNT"), "contribution": Number(2.0, ..), .. }
    }),
  )
}

///|
test "composite malformed and unknown JSON fields fail without scoring a partial result" {
  let item = @qti.compile_composite_item(fixture("composite"))
  for
    input in [
      "[]", "{\"OTHER\":1}", "{\"COUNT\":4e0}", "{\"COUNT\":4.0}", "{\"COUNT\":4.5}",
      "{\"COUNT\":9007199254740992}", "{\"COUNT\":4,\"COUNT\":3}", "{\"COUNT\":[\"4\"]}",
      "{\"PLATFORM\":4}", "{\"COUNT\":true}", "{",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("invalid composite accepted")
    }
  }
}

///|
test "composite typed containers and nonfinite numbers fail validation" {
  let item = @qti.compile_composite_item(fixture("composite"))
  for
    response in [
      @qti.Response::Multiple([]),
      Ordered(["4"]),
      Number(1.0 / 0.0),
      Single("4e0"),
    ] {
    try item.score_responses({ "COUNT": response }) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("invalid scalar accepted")
    }
  }
}

///|
test "composite descriptions retain passage order but isolate scoring rules and copies" {
  let item = @qti.compile_composite_item(
    fixture("composite").swap(
      "学习管理系统的常用英文缩写是 ", "<![CDATA[甲<乙]]>&amp;<strong>前文</strong>",
    ),
  )
  let description = item.describe()
  guard description
    is {
      "kind": String("composite"),
      "responses": [_, _],
      "passage": Array(parts),
      "instructions": [_],
      "mapping"? : None,
      ..
    } else {
    fail("missing composite metadata")
  }
  let text = parts
    .map(p => {
      match p {
        { "text": String(s), .. } => s
        { "response": String(id), .. } => "[\{id}]"
        _ => "?"
      }
    })
    .join("")
  assert_true(text.has_prefix("甲<乙&前文[PLATFORM]。\n"))
  assert_true(text.contains("[COUNT]"))
  if description is Object(fields) {
    fields.clear()
  }
  assert_true(item.describe() is { "responses": [_, _], .. })
  assert_eq(item.score_json("{\"COUNT\":4}").score, 2.0)
}

///|
test "composite compiler rejects missing duplicated and incompatible bindings" {
  let source = fixture("composite")
  for
    xml in [
      source.swap(
        "identifier=\"COUNT\" cardinality", "identifier=\"PLATFORM\" cardinality",
      ),
      source.swap(
        "identifier=\"COUNT\" cardinality", "identifier=\"SCORE\" cardinality",
      ),
      source.swap(
        "response-identifier=\"COUNT\"", "response-identifier=\"OTHER\"",
      ),
      source.swap(
        "response-identifier=\"COUNT\"", "response-identifier=\"PLATFORM\"",
      ),
      source.swap(
        "<qti-text-entry-interaction response-identifier=\"COUNT\" expected-length=\"3\" placeholder-text=\"填写整数\"/>",
        "",
      ),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => assert_eq(e.code(), "invalid_item")
    } noraise {
      _ => fail("invalid bindings accepted")
    }
  }
  for
    xml in [
      source.swap(
        "cardinality=\"single\" base-type=\"integer\"", "cardinality=\"multiple\" base-type=\"integer\"",
      ),
      source.swap("base-type=\"integer\"", "base-type=\"identifier\""),
      source.swap("<qti-item-body>", "<qti-item-body><script>run()</script>"),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => assert_eq(e.code(), "unsupported")
    } noraise {
      _ => fail("unsupported composite accepted")
    }
  }
}

///|
test "composite rules reject unguarded maps ignored responses and wrong variable references" {
  let source = fixture("composite")
  for
    xml in [
      source.swap(
        "<qti-sum><qti-variable identifier=\"SCORE\"/>", "<qti-sum><qti-variable identifier=\"COUNT\"/>",
      ),
      source.swap(
        "<qti-map-response identifier=\"PLATFORM\"/>", "<qti-map-response identifier=\"COUNT\"/>",
      ),
      source.swap(
        "<qti-correct identifier=\"COUNT\"/>", "<qti-correct identifier=\"PLATFORM\"/>",
      ),
      source.swap(
        "<qti-match><qti-variable identifier=\"COUNT\"/>", "<qti-match><qti-variable identifier=\"OTHER\"/>",
      ),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => assert_eq(e.code(), "invalid_item")
    } noraise {
      _ => fail("bad rule accepted")
    }
  }
  for
    xml in [
      source.swap(
        "<qti-base-value base-type=\"float\">0</qti-base-value>", "<qti-base-value base-type=\"float\">1</qti-base-value>",
      ),
      source.swap(
        "<qti-response-processing>", "<qti-response-processing template=\"match_correct\">",
      ),
      source.swap("base-type=\"integer\"", "base-type=\"float\""),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => assert_eq(e.code(), "unsupported")
    } noraise {
      _ => fail("unsupported rule accepted")
    }
  }
}

///|
test "composite missing correct values or mappings are diagnosed at compile time" {
  for
    xml in [
      fixture("composite").swap(
        "<qti-correct-response><qti-value>4</qti-value></qti-correct-response>",
        "",
      ),
      fixture("composite-numeric").swap(
        "<qti-map-entry map-key=\"0.7\" mapped-value=\"1\"/>", "<qti-map-entry map-key=\"0.750\" mapped-value=\"1\"/>",
      ),
    ] {
    try @qti.compile_composite_item(xml) catch {
      e => assert_eq(e.code(), "invalid_item")
    } noraise {
      _ => fail("bad declaration accepted")
    }
  }
  let absent = @qti.compile_composite_item(
    fixture("composite-numeric").swap(
      "<qti-correct-response><qti-value>20</qti-value></qti-correct-response>", "",
    ),
  )
  assert_eq(
    absent.score_json("{\"RATIO\":0.75,\"TOTAL\":20}").matches_correct,
    None,
  )
}

///|
test "composite attempts initialize SCORE on every invocation and reject sum overflow" {
  let item = @qti.compile_composite_item(fixture("composite"))
  assert_eq(item.score_json("{\"COUNT\":4}").score, 2.0)
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"COUNT\":4}").score, 2.0)
  let overflow = @qti.compile_composite_item(
    fixture("composite")
    .swap(" upper-bound=\"2\"", "")
    .swap("mapped-value=\"2\"", "mapped-value=\"1e308\"")
    .swap(
      "<qti-base-value base-type=\"float\">2</qti-base-value>", "<qti-base-value base-type=\"float\">1e308</qti-base-value>",
    ),
  )
  try overflow.score_json("{\"PLATFORM\":\"LMS\",\"COUNT\":4}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("overflow accepted")
  }
}

///|
test "unified assessment entry point preserves old Item and single metadata APIs" {
  let single = @qti.compile_assessment_item(fixture("single"))
  assert_eq(single.describe(), @qti.compile_item(fixture("single")).describe())
  assert_eq(single.identifier(), "formative")
  let composite = @qti.compile_assessment_item(fixture("composite"))
  assert_eq(composite.score_json("{\"COUNT\":4}").score, 2.0)
  assert_true(composite is @qti.AssessmentItem::Composite(_))
  rejected(fixture("composite"), "invalid_item")
}

///|
test "composite package resources and batch exports use the unified scorer" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-manifest.xml"),
      ),
      ("items/composite.xml", fixture("composite")),
      ("items/composite-numeric.xml", fixture("composite-numeric")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  assert_eq(
    bundle.assessment_item("platform").score_json("{\"COUNT\":4}").score,
    2.0,
  )
  try bundle.item("platform") catch {
    e => assert_eq(e.code(), "unsupported")
  } noraise {
    _ => fail("legacy item silently accepted composite")
  }
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 5)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(7.0),
    Some(3.0),
    Some(1.0),
    None,
    Some(0.0),
  ])
}

///|
test "composite limits reject oversized response sets and scalar text" {
  let declarations = StringBuilder()
  for i = 0; i < 7; i = i + 1 {
    declarations.write_string(
      "<qti-response-declaration identifier=\"EXTRA\{i}\" cardinality=\"single\" base-type=\"string\"/>",
    )
  }
  let source = fixture("composite").swap(
    "<qti-item-body>",
    declarations.to_string() + "<qti-item-body>",
  )
  try @qti.compile_composite_item(source) catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("too many responses accepted")
  }
  let long = StringBuilder()
  for _ in 0..<65537 {
    long.write_string("x")
  }
  let item = @qti.compile_composite_item(fixture("composite"))
  try item.score_responses({ "PLATFORM": Single(long.to_string()) }) catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("oversized value accepted")
  }
}

///|
test "composite negative weights and independent namespaces remain deterministic" {
  let source = fixture("composite").swap(
    "<qti-base-value base-type=\"float\">2</qti-base-value>", "<qti-base-value base-type=\"float\">-1.5</qti-base-value>",
  )
  let item = @qti.compile_composite_item(source)
  assert_eq(item.score_json("{\"COUNT\":4}").score, -1.5)
  let prefixed = source
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</p>", "</h:p>")
  assert_eq(@qti.compile_composite_item(prefixed).describe(), item.describe())
}
