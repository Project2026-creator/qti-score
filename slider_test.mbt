///|
test "integer sliders map numerical responses and preserve exact-answer status" {
  let item = @qti.compile_item(fixture("slider"))
  for
    (value, expected) in [
      (40.0, 2.0),
      (30.0, 1.0),
      (50.0, 1.0),
      (0.0, 0.0),
      (100.0, 0.0),
    ] {
    let result = item.score(Number(value))
    assert_eq(result.score, expected)
    assert_eq(item.explain(Number(value)).result, result)
  }
  assert_eq(item.score(Single(" +0040 ")).matches_correct, Some(true))
  assert_eq(item.score(Single("030")).score, 1.0)
  assert_eq(item.score(Number(30.0)).matches_correct, Some(false))
  let trace = item.explain(Number(30.0))
  assert_true(
    trace.steps.any(s => {
      s.operation == "map_value" &&
      s.details
      is { "value": Number(30.0, ..), "contribution": Number(1.0, ..), .. }
    }),
  )
  assert_true(
    trace.steps.all(s => s.location.line > 0 && s.location.column > 0),
  )
}

///|
test "slider responses enforce bounds steps cardinality and strict integer spelling" {
  let item = @qti.compile_item(fixture("slider"))
  for
    response in [
      @qti.Response::Number(-10.0),
      Number(110.0),
      Number(45.0),
      Number(40.5),
      Number(1.0 / 0.0),
      Single("4e1"),
      Single("40.0"),
      Single("NaN"),
      Multiple(["40"]),
      Ordered(["40"]),
    ] {
    invalid_match(item, response)
  }
  for response in [@qti.Response::Null, Single(""), Single(" \t")] {
    assert_eq(item.score(response).status, Unanswered)
    assert_eq(item.score(response).score, 0.0)
  }
  assert_eq(item.score_json("{}").status, Unanswered)
}

///|
test "integer slider boundaries round outward and omitted step defaults to one" {
  let item = @qti.compile_item(
    fixture("slider").swap(
      "lower-bound=\"0\" upper-bound=\"100\" step=\"10\"", "lower-bound=\"0.8\" upper-bound=\"99.2\"",
    ),
  )
  assert_true(
    item.describe()
    is {
      "slider": {
        "lower_bound": Number(0.0, ..),
        "upper_bound": Number(100.0, ..),
        "step": Number(1.0, ..),
        ..
      },
      ..
    },
  )
  assert_eq(item.score(Number(0.0)).status, Answered)
  assert_eq(item.score(Number(100.0)).status, Answered)
  assert_eq(item.score(Number(41.0)).score, 0.0)
  let exact = @qti.compile_item(
    fixture("slider").swap("map_response.xml", "match_correct.xml"),
  )
  assert_eq(exact.score(Number(40.0)).score, 1.0)
  assert_eq(exact.score(Number(30.0)).score, 0.0)
}

///|
test "slider correct responses must be reachable on the authored grid" {
  let source = fixture("slider")
  rejected(
    source.swap("<qti-value>40</qti-value>", "<qti-value>45</qti-value>"),
    "invalid_item",
  )
  rejected(
    source.swap("<qti-value>40</qti-value>", "<qti-value>110</qti-value>"),
    "invalid_item",
  )
  let offset = @qti.compile_item(
    source.swap(
      "lower-bound=\"0\" upper-bound=\"100\" step=\"10\"", "lower-bound=\"10\" upper-bound=\"42\" step=\"15\"",
    ),
  )
  assert_eq(offset.score(Number(40.0)).score, 2.0)
  invalid_match(offset, Number(42.0))
}

///|
test "slider attributes reject invalid numbers steps booleans orientations and excessive grids" {
  let source = fixture("slider")
  for
    xml in [
      source.swap(
        "lower-bound=\"0\" upper-bound=\"100\"", "lower-bound=\"100\" upper-bound=\"0\"",
      ),
      source.swap("lower-bound=\"0\"", "lower-bound=\"-1\""),
      source.swap("upper-bound=\"100\"", "upper-bound=\"NaN\""),
      source.swap("upper-bound=\"100\"", "upper-bound=\"9007199254740992\""),
      source.swap("step=\"10\"", "step=\"0\""),
      source.swap("step=\"10\"", "step=\"-1\""),
      source.swap("step-label=\"true\"", "step-label=\"yes\""),
      source.swap("step-label=\"true\"", "orientation=\"diagonal\""),
      source.swap("step-label=\"true\"", "reverse=\"yes\""),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(source.swap("step=\"10\"", "step=\"0.5\""), "unsupported")
  rejected(
    source.swap(
      "upper-bound=\"100\" step=\"10\"", "upper-bound=\"2000000\" step=\"1\"",
    ),
    "limit_exceeded",
  )
  rejected(source.swap(" lower-bound=\"0\"", ""), "invalid_item")
}

///|
test "slider metadata preserves presentation hints and is isolated from compilation" {
  let item = @qti.compile_item(
    fixture("slider").swap(
      "step-label=\"true\"", "step-label=\"1\" orientation=\"vertical\" reverse=\"1\"",
    ),
  )
  let description = item.describe()
  assert_true(
    description
    is {
      "slider": {
        "orientation": String("vertical"),
        "reverse": True,
        "step_label": True,
        ..
      },
      "correct_response"? : None,
      "mapping"? : None,
      ..
    },
  )
  if description is Object(fields) {
    fields.clear()
  }
  assert_true(item.describe() is { "slider": { "reverse": True, .. }, .. })
  assert_eq(item.score(Number(40.0)).score, 2.0)
  assert_true(
    @qti.compile_item(fixture("numeric")).describe() is { "slider"? : None, .. },
  )
}

///|
test "slider context keeps safe mixed text and excludes separate candidate instructions" {
  let source = fixture("slider")
    .swap(
      "<qti-slider-interaction", "<p><![CDATA[甲<乙]]>&amp;<strong>上下文</strong><br/>后文</p><qti-slider-interaction",
    )
    .swap(
      "一节 50 分钟的课程中，", "<em>一节</em> 50 分钟的课程中，",
    )
  let item = @qti.compile_item(source)
  assert_true(item.prompt.has_prefix("甲<乙&上下文\n后文\n一节 50"))
  assert_true(!item.prompt.contains("移动滑杆"))
  assert_true(item.describe() is { "instructions": [_], .. })
  for
    xml in [
      source.swap("<qti-prompt>", "<qti-prompt><script>run()</script>"),
      source.swap(
        "<qti-item-body>", "<qti-item-body><p><img src=\"x.png\"/></p>",
      ),
      source.swap(
        "step-label=\"true\"", "step-label=\"true\" template-identifier=\"T\"",
      ),
      source.swap(
        "<qti-slider-interaction", "<qti-slider-interaction xmlns=\"urn:foreign\"",
      ),
    ] {
    rejected(xml, "unsupported")
  }
  let prefixed = source
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</p>", "</h:p>")
    .swap("<strong>", "<h:strong xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</strong>", "</h:strong>")
    .swap("<br/>", "<h:br xmlns:h=\"http://www.w3.org/1999/xhtml\"/>")
    .swap("<em>", "<h:em xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</em>", "</h:em>")
  assert_eq(@qti.compile_item(prefixed).describe(), item.describe())
}

///|
test "floating slider constraints precede existing numeric scoring rules" {
  let item = @qti.compile_item(fixture("slider-float"))
  for
    (value, expected) in [
      (0.75, 2.0),
      (0.7, 1.0),
      (0.8, 1.0),
      (0.5, 0.0),
      (0.0, 0.0),
      (1.0, 0.0),
    ] {
    assert_eq(item.score(Number(value)).score, expected)
    assert_eq(item.explain(Number(value)).result.score, expected)
  }
  invalid_match(item, Number(0.74))
  invalid_match(item, Number(1.1))
  assert_eq(item.score(Null).status, Unanswered)
  assert_eq(item.score(Single("7.5e-1")).matches_correct, Some(true))
}

///|
test "floating sliders without step have a continuous scale and authored NULL scoring" {
  let item = @qti.compile_item(
    fixture("slider-float")
    .swap(" step=\"0.05\"", "")
    .swap(
      "<qti-base-value base-type=\"float\">0</qti-base-value>", "<qti-base-value base-type=\"float\">0.25</qti-base-value>",
    ),
  )
  assert_true(item.describe() is { "slider": { "step": Null, .. }, .. })
  assert_eq(item.score(Number(0.743)).score, 1.0)
  assert_eq(item.score(Null).score, 0.25)
  assert_eq(item.score(Null).status, Unanswered)
  invalid_match(item, Number(-0.001))
}

///|
test "a constant slider range still distinguishes an endpoint response from NULL" {
  let item = @qti.compile_item(
    fixture("slider").swap(
      "lower-bound=\"0\" upper-bound=\"100\"", "lower-bound=\"40\" upper-bound=\"40\"",
    ),
  )
  assert_eq(item.score(Number(40.0)).status, Answered)
  assert_eq(item.score(Number(40.0)).score, 2.0)
  assert_eq(item.score(Null).status, Unanswered)
  invalid_match(item, Number(30.0))
}

///|
test "floating grid arithmetic handles decimal steps without accepting adjacent off-grid values" {
  let source = fixture("slider-float")
    .swap("<qti-value>0.75</qti-value>", "<qti-value>0.3</qti-value>")
    .swap("step=\"0.05\"", "step=\"0.1\"")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Number(0.3)).score, 2.0)
  assert_eq(
    item.score(Number(0.30000000000000004)).matches_correct,
    Some(false),
  )
  invalid_match(item, Number(0.300001))
  let huge = @qti.compile_item(
    source
    .swap(
      "lower-bound=\"0\" upper-bound=\"1\" step=\"0.1\"", "lower-bound=\"1000000000000000\" upper-bound=\"1000000000000001\" step=\"0.25\"",
    )
    .swap(
      "<qti-value>0.3</qti-value>", "<qti-value>1000000000000000.5</qti-value>",
    ),
  )
  invalid_match(huge, Number(1000000000000000.125))
  assert_eq(huge.score(Number(1000000000000000.5)).score, 2.0)
}

///|
test "numeric mappings detect semantically duplicate keys rather than just duplicate spelling" {
  let source = fixture("slider")
  rejected(source.swap("map-key=\"30\"", "map-key=\"+0040\""), "invalid_item")
  let floats = source.swap("base-type=\"integer\"", "base-type=\"float\"")
  rejected(floats.swap("map-key=\"30\"", "map-key=\"4e1\""), "invalid_item")
  rejected(
    floats
    .swap("map-key=\"40\"", "map-key=\"-0\"")
    .swap("map-key=\"30\"", "map-key=\"0.0\""),
    "invalid_item",
  )
}

///|
test "numeric mappings validate key types finite contributions and optional correct responses" {
  let source = fixture("slider")
  for
    key in [
      "NaN", "Infinity", "1e999", "40.0", "4e1", "40x", "9007199254740992",
    ] {
    rejected(
      source.swap("map-key=\"40\"", "map-key=\"\{key}\""),
      "invalid_item",
    )
  }
  rejected(
    source.swap("mapped-value=\"2\"", "mapped-value=\"Infinity\""),
    "invalid_item",
  )
  let absent = @qti.compile_item(
    source.swap(
      "<qti-correct-response><qti-value>40</qti-value></qti-correct-response>", "",
    ),
  )
  assert_eq(absent.score(Number(40.0)).score, 2.0)
  assert_eq(absent.score(Number(40.0)).matches_correct, None)
}

///|
test "numeric map_response applies default and bounds only to answered input" {
  let item = @qti.compile_item(
    fixture("slider").swap(
      "lower-bound=\"0\" upper-bound=\"2\"", "lower-bound=\"1\" upper-bound=\"1.5\"",
    ),
  )
  assert_eq(item.score(Number(40.0)).score, 1.5)
  assert_eq(item.score(Number(0.0)).score, 1.0)
  let empty = item.explain(Null)
  assert_eq(empty.result.score, 0.0)
  assert_true(empty.steps.any(s => s.operation == "null_response"))
  assert_true(!empty.steps.any(s => s.operation == "mapping_bounds"))
  let negative = @qti.compile_item(
    fixture("slider")
    .swap(" lower-bound=\"0\" upper-bound=\"2\"", "")
    .swap("mapped-value=\"2\"", "mapped-value=\"-2\""),
  )
  assert_eq(negative.score(Number(40.0)).score, -2.0)
}

///|
test "floating mapping uses numeric equality with no scoring tolerance or case conversion" {
  let source = fixture("slider")
    .swap("base-type=\"integer\"", "base-type=\"float\"")
    .swap("<qti-value>40</qti-value>", "<qti-value>0.3</qti-value>")
    .swap("map-key=\"40\"", "map-key=\"3e-1\" case-sensitive=\"true\"")
    .swap(
      "lower-bound=\"0\" upper-bound=\"100\" step=\"10\"", "lower-bound=\"0\" upper-bound=\"1\" step=\"0.1\"",
    )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Single("0.30")).score, 2.0)
  assert_eq(item.score(Number(0.30000000000000004)).score, 0.0)
  assert_eq(
    item.score(Number(0.30000000000000004)).matches_correct,
    Some(false),
  )
}

///|
test "numeric text entry also shares the new numerical mapping implementation" {
  let source = fixture("slider")
    .swap(
      "<qti-slider-interaction response-identifier=\"RESPONSE\" lower-bound=\"0\" upper-bound=\"100\" step=\"10\" step-label=\"true\">",
      "<qti-text-entry-interaction response-identifier=\"RESPONSE\"/><!--",
    )
    .swap("</qti-slider-interaction>", "-->")
  let integer = @qti.compile_item(source)
  assert_eq(integer.score(Single("0040")).score, 2.0)
  assert_eq(integer.score(Number(45.0)).score, 0.0)
  let floating = @qti.compile_item(
    source.swap("base-type=\"integer\"", "base-type=\"float\""),
  )
  assert_eq(floating.score(Single("4e1")).score, 2.0)
  assert_eq(floating.score(Null).score, 0.0)
}

///|
test "slider bindings and unsupported defaults remain explicit errors" {
  let source = fixture("slider")
  rejected(
    source.swap("base-type=\"integer\"", "base-type=\"string\""),
    "invalid_item",
  )
  rejected(
    source.swap(
      "cardinality=\"single\" base-type=\"integer\"", "cardinality=\"multiple\" base-type=\"integer\"",
    ),
    "unsupported",
  )
  rejected(
    source.swap(
      "<qti-correct-response>", "<qti-default-value><qti-value>40</qti-value></qti-default-value><qti-correct-response>",
    ),
    "unsupported",
  )
  rejected(
    source
    .swap("base-type=\"integer\"", "base-type=\"float\"")
    .swap("map_response.xml", "match_correct.xml"),
    "unsupported",
  )
  rejected(
    source.swap(
      "<qti-prompt>", "<qti-prompt><qti-text-entry-interaction response-identifier=\"RESPONSE\"/>",
    ),
    "unsupported",
  )
  rejected(
    source.swap("<qti-prompt>", "<qti-prompt>One</qti-prompt><qti-prompt>"),
    "invalid_item",
  )
}

///|
test "slider package batches preserve partial scores and isolate invalid numerical responses" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/slider-manifest.xml"),
      ),
      ("items/slider.xml", fixture("slider")),
      ("items/slider-float.xml", fixture("slider-float")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/slider-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 5)
  assert_eq(report.error_count, 2)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(4.0),
    Some(2.0),
    None,
    None,
    Some(0.0),
  ])
  assert_true(
    report.to_csv().contains("slider response does not lie on its step grid"),
  )
}
