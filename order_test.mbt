///|
test "ordered responses compare each position rather than an unordered bag" {
  let item = @qti.compile_item(fixture("order"))
  let correct = ["Analyze", "Design", "Develop", "Implement", "Evaluate"]
  assert_eq(item.cardinality, Ordered)
  assert_eq(item.min_choices, 5)
  assert_eq(item.max_choices, 5)
  assert_eq(item.score(Ordered(correct)).score, 1.0)
  let reversed = ["Evaluate", "Implement", "Develop", "Design", "Analyze"]
  let wrong = item.score(Ordered(reversed))
  assert_eq(wrong.score, 0.0)
  assert_eq(wrong.matches_correct, Some(false))
  assert_eq(wrong.status, Answered)
  assert_true(
    item.describe()
    is { "cardinality": String("ordered"), "correct_response"? : None, .. },
  )
}

///|
test "every permutation of a three-choice ordered item has exactly one winner" {
  let source = fixture("multiple")
    .swap("cardinality=\"multiple\"", "cardinality=\"ordered\"")
    .swap("qti-choice-interaction", "qti-order-interaction")
    .swap("map_response.xml", "match_correct.xml")
  // A compact independent three-choice item avoids sharing scorer logic.
  let xml = "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"permutations\" title=\"Order\"><qti-response-declaration identifier=\"RESPONSE\" cardinality=\"ordered\" base-type=\"identifier\"><qti-correct-response><qti-value>C</qti-value><qti-value>A</qti-value><qti-value>B</qti-value></qti-correct-response></qti-response-declaration><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-item-body><qti-order-interaction response-identifier=\"RESPONSE\"><qti-simple-choice identifier=\"A\">A</qti-simple-choice><qti-simple-choice identifier=\"B\">B</qti-simple-choice><qti-simple-choice identifier=\"C\">C</qti-simple-choice></qti-order-interaction></qti-item-body><qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct.xml\"/></qti-assessment-item>"
  let item = @qti.compile_item(xml)
  let permutations = [
    ["A", "B", "C"],
    ["A", "C", "B"],
    ["B", "A", "C"],
    ["B", "C", "A"],
    ["C", "A", "B"],
    ["C", "B", "A"],
  ]
  assert_eq(permutations.map(values => item.score(Ordered(values)).score), [
    0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
  ])
  // Ordered mappings remain explicitly unsupported.
  rejected(source, "unsupported")
}

///|
test "ordered JSON arrays use item context and leave generic parsing compatible" {
  let item = @qti.compile_item(fixture("order-subset"))
  assert_eq(item.score_json("{\"RESPONSE\":[\"Locate\",\"Adapt\"]}").score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":[\"Adapt\",\"Locate\"]}").score, 0.0)
  assert_eq(
    @qti.response_from_json({ "RESPONSE": ["Locate", "Adapt"] }),
    Multiple(["Locate", "Adapt"]),
  )
  assert_eq(
    item.explain_json("{\"RESPONSE\":[\"Locate\",\"Adapt\"]}").result.score,
    1.0,
  )
}

///|
test "ordered typed cardinality cannot be replaced by single or multiple" {
  let ordered = @qti.compile_item(fixture("order-subset"))
  for
    response in [
      @qti.Response::Single("Locate"),
      Multiple(["Locate", "Adapt"]),
      Number(1.0),
    ] {
    try ordered.score(response) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("expected ordered cardinality")
    }
  }
  for name in ["single", "multiple", "text", "integer"] {
    let item = @qti.compile_item(fixture(name))
    try item.score(Ordered([])) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("ordered container cannot change an item's cardinality")
    }
  }
}

///|
test "NULL and empty ordered containers bypass nonempty choice minimums" {
  let item = @qti.compile_item(fixture("order"))
  for response in [@qti.Response::Null, Ordered([])] {
    let score = item.score(response)
    assert_eq(score.status, Unanswered)
    assert_eq(score.score, 0.0)
    assert_eq(score.matches_correct, Some(false))
  }
  for source in ["{}", "{\"RESPONSE\":null}", "{\"RESPONSE\":[]}"] {
    assert_eq(item.score_json(source).status, Unanswered)
  }
}

///|
test "order defaults require every choice and ignore an otherwise lexical maximum" {
  for maximum in ["1", "0", "99"] {
    let xml = fixture("order").swap(
      "shuffle=\"false\"",
      "shuffle=\"false\" max-choices=\"\{maximum}\"",
    )
    let item = @qti.compile_item(xml)
    assert_eq(item.min_choices, 5)
    assert_eq(item.max_choices, 5)
    try item.score(Ordered(["Analyze"])) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("a maximum alone cannot request a subset")
    }
  }
  rejected(
    fixture("order").swap(
      "shuffle=\"false\"", "shuffle=\"false\" max-choices=\"-1\"",
    ),
    "invalid_item",
  )
}

///|
test "subset orders enforce inclusive count limits and exact sequence length" {
  let item = @qti.compile_item(fixture("order-subset"))
  assert_eq(item.min_choices, 2)
  assert_eq(item.max_choices, 3)
  assert_eq(item.score(Ordered(["Locate", "Adapt"])).score, 1.0)
  assert_eq(item.score(Ordered(["Locate", "Adapt", "Rank"])).score, 0.0)
  for
    response in [
      ["Locate"],
      ["Locate", "Adapt", "Rank", "Skip"],
      ["Locate", "Locate"],
      ["Locate", "missing"],
      ["Locate", ""],
    ] {
    try item.score(Ordered(response)) catch {
      error => assert_eq(error.code(), "invalid_response")
    } noraise {
      _ => fail("expected invalid order response")
    }
  }
  let no_max = @qti.compile_item(
    fixture("order-subset").swap(" max-choices=\"3\"", ""),
  )
  assert_eq(no_max.max_choices, 4)
  assert_eq(
    no_max.score(Ordered(["Locate", "Adapt", "Rank", "Skip"])).score,
    0.0,
  )
}

///|
test "invalid ordered declarations and presentation structures fail explicitly" {
  let source = fixture("order-subset")
  for
    xml in [
      source.swap("min-choices=\"2\"", "min-choices=\"0\""),
      source.swap("min-choices=\"2\"", "min-choices=\"5\""),
      source.swap("max-choices=\"3\"", "max-choices=\"1\""),
      source.swap("max-choices=\"3\"", "max-choices=\"0\""),
      source.swap("max-choices=\"3\"", "max-choices=\"5\""),
      source.swap("shuffle=\"false\"", "orientation=\"diagonal\""),
      source.swap(
        "<qti-value>Adapt</qti-value>", "<qti-value>Locate</qti-value>",
      ),
      source.swap(
        "<qti-value>Adapt</qti-value>", "<qti-value>Unknown</qti-value>",
      ),
      source.swap("qti-order-interaction", "qti-choice-interaction"),
      source.swap("cardinality=\"ordered\"", "cardinality=\"multiple\""),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(
    source.swap("base-type=\"identifier\"", "base-type=\"string\""),
    "unsupported",
  )
  rejected(source.swap("match_correct.xml", "map_response.xml"), "invalid_item")
  rejected(
    source.swap("qti-order-interaction", "qti-graphic-order-interaction"),
    "unsupported",
  )
}

///|
test "ordered explanation identifies positional comparison without changing scoring" {
  let item = @qti.compile_item(fixture("order-subset"))
  let values = ["Adapt", "Locate"]
  let explanation = item.explain(Ordered(values))
  assert_eq(explanation.result, item.score(Ordered(values)))
  let step = explanation.steps.last().unwrap()
  assert_eq(step.operation, "match_correct")
  assert_true(
    step.details
    is {
      "comparison": String("ordered"),
      "matched": False,
      "score": Number(0.0, ..),
      ..
    },
  )
  assert_true(step.location.line > 0)
  assert_eq(values, ["Adapt", "Locate"])
}

///|
test "ordered package resources keep sequence semantics in batch and CSV results" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/order-manifest.xml"),
      ),
      ("items/order.xml", fixture("order")),
      ("items/order-subset.xml", fixture("order-subset")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/order-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 3)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [Some(2.0), Some(0.0)])
  assert_eq(report.rows()[3].error.unwrap().code(), "invalid_response")
  assert_true(report.to_csv().contains("false,,,,\"invalid_response\""))
}

///|
test "ordered metadata and authored answers cannot mutate the compiled sequence" {
  let item = @qti.compile_item(fixture("order-subset"))
  item.correct_response().unwrap().clear()
  item.choices().clear()
  let values = ["Locate", "Adapt"]
  assert_eq(item.score(Ordered(values)).score, 1.0)
  values.clear()
  assert_eq(item.correct_response().unwrap(), ["Locate", "Adapt"])
}

///|
test "order interactions accept one choice but reject empty or repeated choice declarations" {
  let singleton = fixture("order-subset")
    .swap("<qti-value>Adapt</qti-value>", "")
    .swap(
      "min-choices=\"2\" max-choices=\"3\"", "min-choices=\"1\" max-choices=\"1\"",
    )
    .swap(
      "<qti-simple-choice identifier=\"Adapt\">调整教学支持</qti-simple-choice>",
      "",
    )
    .swap(
      "<qti-simple-choice identifier=\"Rank\">公开学习者排名</qti-simple-choice>",
      "",
    )
    .swap(
      "<qti-simple-choice identifier=\"Skip\">跳过反馈</qti-simple-choice>",
      "",
    )
  let item = @qti.compile_item(singleton)
  assert_eq(item.choices().length(), 1)
  assert_eq(item.score(Ordered(["Locate"])).score, 1.0)
  let choice = "<qti-simple-choice identifier=\"Locate\">定位学习困难</qti-simple-choice>"
  rejected(singleton.swap(choice, ""), "invalid_item")
  rejected(singleton.swap(choice, choice + choice), "invalid_item")
}
