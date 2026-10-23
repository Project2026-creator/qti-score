///|
fn reject_composite_slider_response(
  item : @qti.CompositeItem,
  response : String,
) -> Unit raise {
  try item.score_json(response) catch {
    error => assert_eq(error.code(), "invalid_response")
  } noraise {
    _ => fail("invalid slider response accepted")
  }
}

///|
test "composite sliders combine integer match float tolerance and dropdown" {
  let item = @qti.compile_composite_item(fixture("composite-slider"))
  let full = @fs.read_file_to_string("examples/composite-slider-response.json")
  assert_eq(item.score_json(full).score, 5.0)
  assert_eq(item.score_json(full).matches_correct, Some(true))
  for
    (input, expected) in [
      ("{\"TIME\":40,\"RATIO\":0.7,\"ACTION\":\"Adapt\"}", 4.0),
      ("{\"TIME\":40,\"RATIO\":0.8,\"ACTION\":\"Adapt\"}", 4.0),
      ("{\"RATIO\":0.75}", 2.0),
    ] {
    let result = item.score_json(input)
    assert_eq(result.score, expected)
    assert_eq(item.explain_json(input).result, result)
    assert_eq(
      @qti.compile_assessment_item(fixture("composite-slider")).score_json(
        input,
      ),
      result,
    )
  }
}

///|
test "composite slider NULL differs from intentional zero and remains independent" {
  let item = @qti.compile_composite_item(fixture("composite-slider-continuous"))
  for
    input in [
      "{}", "{\"ZERO\":null,\"RATE\":null}", "{\"ZERO\":\"\",\"RATE\":\" \"}",
    ] {
    let result = item.score_json(input)
    assert_eq(result.score, 0.0)
    assert_eq(result.status, Unanswered)
  }
  assert_eq(item.score_json("{\"ZERO\":0}").score, 1.0)
  assert_eq(item.score_json("{\"ZERO\":0}").status, Answered)
  assert_eq(item.score_json("{\"ZERO\":null,\"RATE\":0.5}").score, 2.0)
  assert_eq(
    item.score_json("{\"ZERO\":0,\"RATE\":0.5}").matches_correct,
    Some(true),
  )
  assert_eq(item.score_json("{\"RATE\":0}").status, Answered)
}

///|
test "composite slider rejects bounds and grid errors before other contributions" {
  let item = @qti.compile_composite_item(fixture("composite-slider"))
  for
    input in [
      "{\"TIME\":-10,\"ACTION\":\"Adapt\"}", "{\"TIME\":110}", "{\"TIME\":35,\"RATIO\":0.75}",
      "{\"TIME\":40,\"RATIO\":0.73}", "{\"RATIO\":1.05}", "{\"RATIO\":-0.05}",
    ] {
    reject_composite_slider_response(item, input)
  }
  try item.score_json("{\"TIME\":35}") catch {
    error => assert_true(error.message().contains("TIME"))
  } noraise {
    _ => fail("off grid accepted")
  }
  assert_eq(item.score_json("{\"TIME\":100,\"RATIO\":1}").score, 0.0)
}

///|
test "composite integer slider rounds authored bounds outward and anchors steps" {
  let item = @qti.compile_composite_item(fixture("composite-slider-continuous"))
  assert_true(
    item.describe()
    is {
      "responses": [
        {
          "slider": {
            "lower_bound": Number(0, ..),
            "upper_bound": Number(10, ..),
            "step": Number(2, ..),
            ..
          },
          ..
        },
        _,
      ],
      ..
    },
  )
  assert_eq(item.score_json("{\"ZERO\":10}").status, Answered)
  reject_composite_slider_response(item, "{\"ZERO\":9}")
  let offset = @qti.compile_composite_item(
    fixture("composite-slider").swap(
      "lower-bound=\"0\" upper-bound=\"100\" step=\"10\"", "lower-bound=\"10\" upper-bound=\"42\" step=\"15\"",
    ),
  )
  assert_eq(offset.score_json("{\"TIME\":40}").score, 2.0)
  reject_composite_slider_response(offset, "{\"TIME\":42}")
}

///|
test "composite sliders distinguish default integer grid from continuous float" {
  let integer = @qti.compile_composite_item(
    fixture("composite-slider").swap(" step=\"10\"", ""),
  )
  assert_eq(integer.score_json("{\"TIME\":35}").status, Answered)
  assert_true(
    integer.describe()
    is {
      "responses": [{ "slider": { "step": Number(1, ..), .. }, .. }, ..],
      ..
    },
  )
  let continuous = @qti.compile_composite_item(
    fixture("composite-slider-continuous"),
  )
  assert_eq(continuous.score_json("{\"RATE\":0.333}").status, Answered)
  assert_eq(continuous.score_json("{\"RATE\":0.55}").score, 1.0)
  assert_true(
    continuous.describe()
    is {
      "responses": [
        _,
        {
          "slider": {
            "step": Null,
            "reverse": True,
            "orientation": String("vertical"),
            ..
          },
          ..
        },
      ],
      ..
    },
  )
}

///|
test "composite fractional step roundoff never changes the authored response" {
  let item = @qti.compile_composite_item(
    fixture("composite-slider")
    .swap("<qti-value>0.75</qti-value>", "<qti-value>0.3</qti-value>")
    .swap("step=\"0.05\"", "step=\"0.1\""),
  )
  assert_eq(item.score_json("{\"RATIO\":0.3}").score, 2.0)
  assert_eq(
    item.score_json("{\"RATIO\":\"0.30000000000000004\"}").matches_correct,
    Some(false),
  )
  reject_composite_slider_response(item, "{\"RATIO\":0.3000000001}")
}

///|
test "composite slider correct responses must lie on the effective grid" {
  for
    xml in [
      fixture("composite-slider").swap(
        "<qti-value>40</qti-value>", "<qti-value>35</qti-value>",
      ),
      fixture("composite-slider").swap(
        "<qti-value>0.75</qti-value>", "<qti-value>1.05</qti-value>",
      ),
      fixture("composite-slider-continuous").swap(
        "<qti-value>0</qti-value>", "<qti-value>1</qti-value>",
      ),
    ] {
    reject_composite_choice(xml, "invalid_item")
  }
}

///|
test "composite slider authored attributes reuse numeric and resource limits" {
  let xml = fixture("composite-slider")
  for
    (old, replacement) in [
      (
        "lower-bound=\"0\" upper-bound=\"100\"", "lower-bound=\"100\" upper-bound=\"0\"",
      ),
      ("step=\"10\"", "step=\"0\""),
      ("step-label=\"true\"", "step-label=\"invalid\""),
      ("step-label=\"true\"", "orientation=\"diagonal\""),
      ("upper-bound=\"100\"", "upper-bound=\"NaN\""),
      (" lower-bound=\"0\"", ""),
    ] {
    reject_composite_choice(xml.swap(old, replacement), "invalid_item")
  }
  reject_composite_choice(
    xml.swap("step=\"10\"", "step=\"0.5\""),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap("step=\"10\"", "step=\"0.000001\""),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap(
      "upper-bound=\"100\" step=\"10\"", "upper-bound=\"2000000\" step=\"1\"",
    ),
    "limit_exceeded",
  )
}

///|
test "composite slider bindings reject nonnumeric and unknown or duplicate IDs" {
  let xml = fixture("composite-slider")
  reject_composite_choice(
    xml.swap(
      "identifier=\"TIME\" cardinality=\"single\" base-type=\"integer\"", "identifier=\"TIME\" cardinality=\"single\" base-type=\"string\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    xml.swap(
      "identifier=\"TIME\" cardinality=\"single\"", "identifier=\"TIME\" cardinality=\"multiple\"",
    ),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap("response-identifier=\"TIME\"", "response-identifier=\"Unknown\""),
    "invalid_item",
  )
  reject_composite_choice(
    xml.swap("response-identifier=\"RATIO\"", "response-identifier=\"TIME\""),
    "invalid_item",
  )
  reject_composite_choice(
    xml.swap("response-identifier=\"TIME\"", "response-identifier=\"ACTION\""),
    "invalid_item",
  )
}

///|
test "composite slider metadata is fresh and keeps prompts inside each binding" {
  let item = @qti.compile_composite_item(fixture("composite-slider"))
  let description = item.describe()
  assert_false(description.stringify().contains("correct_response"))
  assert_false(description.stringify().contains("tolerance"))
  guard description
    is {
      "responses": [
        { "slider": Object(slider), .. },
        { "slider": _, .. },
        { "inline_choice": _, .. },
      ],
      "passage": Array(parts),
      ..
    } else {
    fail("missing slider metadata")
  }
  assert_false(
    parts.any(p => p is { "text": String(s), .. } && s.contains("50 分钟")),
  )
  slider.clear()
  assert_true(
    item.describe()
    is {
      "responses": [{ "slider": { "step": Number(10, ..), .. }, .. }, ..],
      ..
    },
  )
  assert_false(
    @qti.compile_composite_item(fixture("composite"))
    .describe()
    .stringify()
    .contains("slider"),
  )
}

///|
test "composite slider prompts accept safe namespaced static text only" {
  let xml = fixture("composite-slider").swap(
    "50 分钟课程中", "<![CDATA[<script>text only</script>]]><em>50 分钟课程中</em>",
  )
  let prefixed = xml
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<p xmlns=\"http://www.w3.org/1999/xhtml\">")
    .swap("<em>", "<em xmlns=\"http://www.w3.org/1999/xhtml\">")
  let item = @qti.compile_composite_item(xml)
  assert_eq(item.describe(), @qti.compile_composite_item(prefixed).describe())
  assert_true(
    item.describe().stringify().contains("<script>text only</script>"),
  )
  reject_composite_choice(
    xml.swap(
      "50 分钟课程中</em>", "50 分钟课程中</em><img src=\"x.png\"/>",
    ),
    "unsupported",
  )
}

///|
test "composite slider scalar response validation retains exact integer lexical rules" {
  let item = @qti.compile_composite_item(fixture("composite-slider"))
  for
    input in [
      "{\"TIME\":[\"40\"]}", "{\"RATIO\":true}", "{\"TIME\":40.5}", "{\"TIME\":\"4e1\"}",
      "{\"RATIO\":\"NaN\"}", "{\"RATIO\":\"Infinity\"}", "{\"TIME\":40,\"TIME\":50}",
      "{\"Unknown\":40}",
    ] {
    reject_composite_slider_response(item, input)
  }
  assert_eq(
    item.score_json("{\"TIME\":\"040\",\"RATIO\":\"7.5e-1\"}").score,
    4.0,
  )
  let responses : Map[String, @qti.Response] = {
    "TIME": Number(40.0),
    "RATIO": Single("0.75"),
  }
  assert_eq(item.explain_responses(responses).result.score, 4.0)
  assert_eq(responses["RATIO"], Single("0.75"))
}

///|
test "composite slider mapping NULL and negative default values remain authored" {
  let item = @qti.compile_composite_item(
    fixture("composite-slider-continuous").swap(
      "default-value=\"0\"", "default-value=\"-1\" lower-bound=\"-2\" upper-bound=\"2\"",
    ),
  )
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"ZERO\":0}").score, 1.0)
  assert_eq(item.score_json("{\"ZERO\":2}").score, -1.0)
  assert_eq(item.score_json("{\"ZERO\":2,\"RATE\":0.5}").score, 1.0)
  reject_composite_slider_response(item, "{\"ZERO\":3,\"RATE\":0.5}")
}

///|
test "composite slider package batches isolate grid failures and preserve statistics" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-slider-manifest.xml"),
      ),
      ("items/composite-slider.xml", fixture("composite-slider")),
      (
        "items/composite-slider-continuous.xml",
        fixture("composite-slider-continuous"),
      ),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-slider-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 7)
  assert_eq(report.error_count, 3)
  assert_eq(report.rows().map(r => r.result.map(s => s.score)), [
    Some(5.0),
    Some(3.0),
    Some(4.0),
    Some(0.0),
    Some(1.0),
    None,
    None,
    None,
    Some(1.0),
    Some(0.0),
  ])
  assert_eq(report.attempts()[0].score_sum, Some(8.0))
  assert_eq(report.items()[0].score_mean, Some(3.0))
  assert_eq(report.items()[1].score_mean, Some(1.25))
  assert_eq(report.items()[1].unanswered_count, 1)
  assert_true(report.items_csv().contains("\"mixed\",5,3,2"))
}
