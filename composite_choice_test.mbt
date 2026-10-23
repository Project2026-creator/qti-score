///|
fn reject_composite_choice(xml : String, code : String) -> Unit raise {
  try @qti.compile_composite_item(xml) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("invalid composite choice accepted")
  }
}

///|
test "single choice composes with dropdown text and numerical partial credit" {
  let item = @qti.compile_composite_item(fixture("composite-choice"))
  for
    (response, expected) in [
      ("{}", 0.0),
      ("{\"METHOD\":\"Formative\"}", 2.0),
      ("{\"ACTION\":\"Adapt\"}", 1.0),
      ("{\"RATIO\":75}", 2.0),
      ("{\"UNIT\":\"%\"}", 1.0),
      (
        "{\"METHOD\":\"Formative\",\"ACTION\":\"Adapt\",\"RATIO\":75,\"UNIT\":\"%\"}",
        6.0,
      ),
      (
        "{\"METHOD\":\"Formative\",\"ACTION\":\"Review\",\"RATIO\":74.5,\"UNIT\":\"%\"}",
        4.5,
      ),
      (
        "{\"METHOD\":\"Summative\",\"ACTION\":\"Ignore\",\"RATIO\":80,\"UNIT\":\"%\"}",
        1.0,
      ),
    ] {
    let result = item.score_json(response)
    assert_eq(result.score, expected)
    assert_eq(item.explain_json(response).result, result)
    assert_eq(
      @qti.compile_assessment_item(fixture("composite-choice")).score_json(
        response,
      ),
      result,
    )
  }
  assert_eq(item.score_json("{}").status, Unanswered)
  assert_eq(item.score_json("{\"METHOD\":\"Summative\"}").status, Answered)
  assert_eq(
    item.score_json(
      @fs.read_file_to_string("examples/composite-choice-response.json"),
    ).matches_correct,
    Some(true),
  )
}

///|
test "required scalar choice rejects missing normalized responses before scoring" {
  let item = @qti.compile_composite_item(fixture("composite-choice-required"))
  for
    response in [
      "{}", "{\"METHOD\":\"Formative\"}", "{\"METHOD\":\"Formative\",\"ACTION\":null}",
      "{\"METHOD\":\"Formative\",\"ACTION\":\"\"}",
    ] {
    try item.score_json(response) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("required selection missing")
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
test "choice identifiers retain exact case and independent option sets" {
  let item = @qti.compile_composite_item(fixture("composite-choice-required"))
  for
    response in [
      "{\"METHOD\":\"formative\",\"ACTION\":\"Adapt\"}", "{\"METHOD\":\" Formative\",\"ACTION\":\"Adapt\"}",
      "{\"METHOD\":\"Adapt\",\"ACTION\":\"Adapt\"}", "{\"METHOD\":[\"Formative\"],\"ACTION\":\"Adapt\"}",
      "{\"METHOD\":1,\"ACTION\":\"Adapt\"}", "{\"METHOD\":true,\"ACTION\":\"Adapt\"}",
    ] {
    try item.score_json(response) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("invalid identifier shape accepted")
    }
  }
}

///|
test "optional NULL bypasses mapping bounds while authored negatives remain" {
  let item = @qti.compile_composite_item(
    fixture("composite-choice")
    .swap("lower-bound=\"0\"", "lower-bound=\"-2\"")
    .swap("default-value=\"0\" lower-bound", "default-value=\"-1\" lower-bound"),
  )
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"METHOD\":\"\"}").score, 0.0)
  assert_eq(item.score_json("{\"METHOD\":\"Summative\"}").score, -1.0)
  assert_eq(item.score_json("{\"METHOD\":\"Formative\"}").score, 2.0)
}

///|
test "metadata separates block prompt choices and surrounding passage" {
  let item = @qti.compile_composite_item(fixture("composite-choice"))
  assert_true(
    item.describe()
    is {
      "responses": [
        {
          "identifier": String("METHOD"),
          "choice": {
            "required": False,
            "orientation": String("vertical"),
            "choices": [_, _],
            ..
          },
          ..
        },
        { "inline_choice": _, .. },
        _,
        _,
      ],
      ..
    },
  )
  let serialized = item.describe().stringify()
  assert_false(serialized.contains("correct_response"))
  assert_false(serialized.contains("mapped_value"))
  guard item.describe() is { "passage": Array(parts), .. } else {
    fail("passage missing")
  }
  assert_eq(
    parts.filter(p => p is { "response": String("METHOD"), .. }).length(),
    1,
  )
  assert_false(
    parts.any(p => {
      p is { "text": String(t), .. } && t.contains("形成性评价")
    }),
  )
  guard item.describe()
    is {
      "responses": [{ "choice": { "choices": Array(choices), .. }, .. }, ..],
      ..
    } else {
    fail("choice missing")
  }
  choices.clear()
  assert_true(
    item.describe()
    is { "responses": [{ "choice": { "choices": [_, _], .. }, .. }, ..], .. },
  )
}

///|
test "single choice defaults and orientation follow independent field declarations" {
  let item = @qti.compile_composite_item(fixture("composite-choice-required"))
  assert_true(
    item.describe()
    is {
      "responses": [
        {
          "choice": {
            "orientation": String("horizontal"),
            "required": True,
            ..
          },
          ..
        },
        {
          "choice": { "orientation": String("vertical"), "required": True, .. },
          ..
        },
      ],
      ..
    },
  )
  for
    replacement in [
      "max-choices=\"0\"", "max-choices=\"2\"", "max-choices=\"-1\"",
    ] {
    reject_composite_choice(
      fixture("composite-choice").swap("max-choices=\"1\"", replacement),
      "invalid_item",
    )
  }
  reject_composite_choice(
    fixture("composite-choice").swap("min-choices=\"0\"", "min-choices=\"2\""),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice").swap(
      "orientation=\"vertical\"", "orientation=\"diagonal\"",
    ),
    "invalid_item",
  )
}

///|
test "choice declarations reject foreign correct answers and mapping keys" {
  reject_composite_choice(
    fixture("composite-choice").swap(
      "<qti-value>Formative</qti-value>", "<qti-value>Foreign</qti-value>",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice").swap(
      "map-key=\"Formative\"", "map-key=\"Foreign\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice").swap(
      "identifier=\"METHOD\" cardinality=\"single\" base-type=\"identifier\"", "identifier=\"METHOD\" cardinality=\"single\" base-type=\"string\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice").swap(
      "identifier=\"METHOD\" cardinality=\"single\"", "identifier=\"METHOD\" cardinality=\"multiple\"",
    ),
    "unsupported",
  )
}

///|
test "duplicate empty and unsupported choice content cannot compile" {
  let xml = fixture("composite-choice")
  reject_composite_choice(
    xml.swap(
      "qti-simple-choice identifier=\"Summative\"", "qti-simple-choice identifier=\"Formative\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    xml.swap(
      "<qti-simple-choice identifier=\"Summative\">总结性评价</qti-simple-choice>",
      "",
    ),
    "invalid_item",
  )
  reject_composite_choice(xml.swap("总结性评价", " "), "invalid_item")
  reject_composite_choice(
    xml.swap("总结性评价", "<img src=\"image.png\"/>"),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap("总结性评价", "<script>run()</script>"),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap("shuffle=\"false\"", "shuffle=\"invalid\""),
    "invalid_item",
  )
  reject_composite_choice(
    xml.swap("shuffle=\"false\"", "required=\"true\""),
    "unsupported",
  )
}

///|
test "interaction references cannot be undeclared duplicated or nested" {
  reject_composite_choice(
    fixture("composite-choice").swap(
      "response-identifier=\"METHOD\"", "response-identifier=\"Missing\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice-required").swap(
      "response-identifier=\"ACTION\"", "response-identifier=\"METHOD\"",
    ),
    "invalid_item",
  )
  reject_composite_choice(
    fixture("composite-choice").swap(
      "总结性评价", "<qti-text-entry-interaction response-identifier=\"UNIT\"/>",
    ),
    "unsupported",
  )
}

///|
test "prefixed namespaces and escaped option content remain plain text" {
  let xml = fixture("composite-choice").swap(
    "总结性评价", "<![CDATA[<script>text only</script>]]>",
  )
  let prefixed = xml
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</p>", "</h:p>")
  assert_eq(
    @qti.compile_composite_item(xml).describe(),
    @qti.compile_composite_item(prefixed).describe(),
  )
  assert_true(
    @qti.compile_composite_item(xml)
    .describe()
    .stringify()
    .contains("<script>text only</script>"),
  )
}

///|
test "repeated option IDs across independent choice blocks do not merge bindings" {
  let item = @qti.compile_composite_item(
    fixture("composite-choice-required")
    .swap("Formative", "Adapt")
    .swap("Summative", "Ignore"),
  )
  assert_eq(
    item.score_json("{\"METHOD\":\"Adapt\",\"ACTION\":\"Adapt\"}").score,
    2.0,
  )
  assert_eq(
    item.score_json("{\"METHOD\":\"Ignore\",\"ACTION\":\"Adapt\"}").score,
    1.0,
  )
}

///|
test "choice typed responses remain reusable after rejected attempts" {
  let item = @qti.compile_composite_item(fixture("composite-choice"))
  let response : Map[String, @qti.Response] = {
    "METHOD": Single("Formative"),
    "RATIO": Number(75.0),
  }
  assert_eq(item.score_responses(response).score, 4.0)
  assert_eq(item.explain_responses(response).result.score, 4.0)
  assert_eq(response["METHOD"], Single("Formative"))
  try item.score_responses({ "METHOD": Multiple(["Formative"]) }) catch {
    error => assert_eq(error.code(), "invalid_response")
  } noraise {
    _ => fail("multiple accepted")
  }
  assert_eq(item.score_responses(response).score, 4.0)
}

///|
test "choice prompts stay scoped and shuffle does not change identifier scoring" {
  let xml = fixture("composite-choice").swap(
    "shuffle=\"false\"", "shuffle=\"true\"",
  )
  let item = @qti.compile_composite_item(xml)
  assert_eq(item.score_json("{\"METHOD\":\"Formative\"}").score, 2.0)
  assert_true(
    item.describe()
    is {
      "responses": [
        {
          "choice": {
            "choices": [
              { "identifier": String("Formative"), .. },
              { "identifier": String("Summative"), .. },
            ],
            ..
          },
          ..
        },
        ..,
      ],
      ..
    },
  )
  reject_composite_choice(
    xml.swap("</qti-prompt>", "</qti-prompt><qti-prompt>Another</qti-prompt>"),
    "invalid_item",
  )
}

///|
test "choice package batches preserve invalid rows statistics and exports" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-choice-manifest.xml"),
      ),
      ("items/composite-choice.xml", fixture("composite-choice")),
      (
        "items/composite-choice-required.xml",
        fixture("composite-choice-required"),
      ),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-choice-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 6)
  assert_eq(report.error_count, 2)
  assert_eq(report.rows().map(row => row.result.map(r => r.score)), [
    Some(6.0),
    Some(2.0),
    Some(4.5),
    Some(1.0),
    Some(0.0),
    None,
    None,
    Some(0.0),
  ])
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(8.0),
    Some(4.5),
    Some(1.0),
    Some(0.0),
    None,
    None,
    Some(0.0),
  ])
  assert_eq(report.items()[0].score_mean, Some(2.875))
  assert_eq(report.items()[0].unanswered_count, 1)
  assert_true(report.items_csv().contains("\"mixed\",5,4,1"))
}
