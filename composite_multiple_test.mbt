///|
fn reject_multiple_response(
  item : @qti.CompositeItem,
  response : String,
) -> Unit raise {
  try item.score_json(response) catch {
    error => assert_eq(error.code(), "invalid_response")
  } noraise {
    _ => fail("invalid multiple response accepted")
  }
}

///|
test "composite multiple mapping combines with scalar choice and integer" {
  let item = @qti.compile_composite_item(fixture("composite-multiple"))
  let result = item.score_json(
    @fs.read_file_to_string("examples/composite-multiple-response.json"),
  )
  assert_eq(result.score, 4.0)
  assert_eq(result.matches_correct, Some(true))
  assert_eq(result.status, Answered)
  assert_eq(
    item.explain_json("{\"EVIDENCE\":[\"Quiz\"],\"COUNT\":4}").result.score,
    2.0,
  )
  assert_eq(
    @qti.compile_assessment_item(fixture("composite-multiple")).score_json(
      "{\"EVIDENCE\":[\"Quiz\"]}",
    ).score,
    1.0,
  )
}

///|
test "multiple order is immaterial while duplicates retain match multiplicity" {
  let item = @qti.compile_composite_item(fixture("composite-multiple-required"))
  assert_eq(
    item.score_json(
      "{\"EVIDENCE\":[\"Feedback\",\"Quiz\"],\"TOOLS\":[\"Quiz\",\"Portfolio\"]}",
    ).matches_correct,
    Some(true),
  )
  let duplicate = item.score_json(
    "{\"EVIDENCE\":[\"Quiz\",\"Quiz\"],\"TOOLS\":[\"Quiz\",\"Quiz\"]}",
  )
  assert_eq(duplicate.score, 1.0)
  assert_eq(duplicate.matches_correct, Some(false))
  let repeated_correct = @qti.compile_composite_item(
    fixture("composite-multiple-required").swap(
      "<qti-value>Feedback</qti-value>", "<qti-value>Quiz</qti-value>",
    ),
  )
  assert_eq(
    repeated_correct.score_json(
      "{\"EVIDENCE\":[\"Quiz\",\"Quiz\"],\"TOOLS\":[\"Quiz\"]}",
    ).score,
    3.0,
  )
}

///|
test "mapping de-duplicates without mutating typed response containers" {
  let item = @qti.compile_composite_item(fixture("composite-multiple"))
  let selected = ["Quiz", "Quiz"]
  let responses : Map[String, @qti.Response] = {
    "EVIDENCE": Multiple(selected),
  }
  let explanation = item.explain_responses(responses)
  assert_eq(explanation.result.score, 1.0)
  assert_eq(selected, ["Quiz", "Quiz"])
  assert_eq(responses["EVIDENCE"], Multiple(["Quiz", "Quiz"]))
  assert_true(explanation.steps.any(s => s.operation == "duplicate_ignored"))
  assert_true(
    explanation.steps.any(s => {
      s.operation == "response" && s.details is { "count": Number(2, ..), .. }
    }),
  )
}

///|
test "optional empty multiple arrays are NULL and skip mapping bounds" {
  let item = @qti.compile_composite_item(
    fixture("composite-multiple").swap("lower-bound=\"0\"", "lower-bound=\"1\""),
  )
  for response in ["{}", "{\"EVIDENCE\":null}", "{\"EVIDENCE\":[]}"] {
    let result = item.score_json(response)
    assert_eq(result.score, 0.0)
    assert_eq(result.status, Unanswered)
    assert_eq(result.matches_correct, Some(false))
  }
  assert_eq(item.score_json("{\"EVIDENCE\":[\"Rank\"]}").score, 1.0)
  assert_eq(item.score_json("{\"EVIDENCE\":[],\"COUNT\":4}").status, Answered)
}

///|
test "selection limits count raw entries before mapping de-duplication" {
  let item = @qti.compile_composite_item(fixture("composite-multiple"))
  reject_multiple_response(
    item, "{\"EVIDENCE\":[\"Quiz\",\"Feedback\",\"Rank\"],\"COUNT\":4}",
  )
  reject_multiple_response(item, "{\"EVIDENCE\":[\"Quiz\",\"Quiz\",\"Quiz\"]}")
  assert_eq(item.score_json("{\"EVIDENCE\":[\"Quiz\",\"Quiz\"]}").score, 1.0)
}

///|
test "required groups reject omitted NULL and empty before contributing score" {
  let item = @qti.compile_composite_item(fixture("composite-multiple-required"))
  for
    response in [
      "{}", "{\"EVIDENCE\":null,\"TOOLS\":[\"Quiz\"]}", "{\"EVIDENCE\":[],\"TOOLS\":[\"Quiz\"]}",
      "{\"EVIDENCE\":[\"Quiz\"],\"TOOLS\":[\"Quiz\"]}", "{\"EVIDENCE\":[\"Quiz\",\"Feedback\"]}",
      "{\"EVIDENCE\":[\"Quiz\",\"Feedback\"],\"TOOLS\":[]}",
    ] {
    reject_multiple_response(item, response)
  }
  assert_eq(
    item.score_json(
      @fs.read_file_to_string(
        "examples/composite-multiple-required-response.json",
      ),
    ).score,
    4.0,
  )
}

///|
test "zero maximum permits all authored choices and repeated values" {
  let item = @qti.compile_composite_item(fixture("composite-multiple-required"))
  assert_eq(
    item.score_json(
      "{\"EVIDENCE\":[\"Quiz\",\"Feedback\"],\"TOOLS\":[\"Quiz\",\"Portfolio\",\"Poster\",\"Quiz\"]}",
    ).score,
    4.0,
  )
}

///|
test "multiple responses reject scalar ordered and malformed array shapes" {
  let item = @qti.compile_composite_item(fixture("composite-multiple"))
  for
    response in [
      "{\"EVIDENCE\":\"Quiz\"}", "{\"EVIDENCE\":\"\"}", "{\"EVIDENCE\":1}", "{\"EVIDENCE\":true}",
      "{\"EVIDENCE\":[null]}", "{\"EVIDENCE\":[1]}", "{\"EVIDENCE\":[\"\"]}", "{\"EVIDENCE\":[[\"Quiz\"]]}",
    ] {
    reject_multiple_response(item, response)
  }
  try item.score_responses({ "EVIDENCE": Ordered(["Quiz"]) }) catch {
    error => assert_eq(error.code(), "invalid_response")
  } noraise {
    _ => fail("ordered accepted")
  }
  reject_multiple_response(item, "{\"ACTION\":[\"Adapt\"]}")
}

///|
test "choice IDs are exact and scoped to independent multiple groups" {
  let item = @qti.compile_composite_item(fixture("composite-multiple-required"))
  for
    response in [
      "{\"EVIDENCE\":[\"Quiz\",\"Portfolio\"],\"TOOLS\":[\"Quiz\"]}", "{\"EVIDENCE\":[\"quiz\",\"Feedback\"],\"TOOLS\":[\"Quiz\"]}",
      "{\"EVIDENCE\":[\" Quiz\",\"Feedback\"],\"TOOLS\":[\"Quiz\"]}", "{\"EVIDENCE\":[\"Quiz\",\"Feedback\"],\"TOOLS\":[\"Rank\"]}",
    ] {
    reject_multiple_response(item, response)
  }
}

///|
test "multiple metadata contains count limits but no author scoring secrets" {
  let item = @qti.compile_composite_item(fixture("composite-multiple"))
  assert_true(
    item.describe()
    is {
      "responses": [
        {
          "cardinality": String("multiple"),
          "choice": {
            "min_choices": Number(0, ..),
            "max_choices": Number(2, ..),
            "required": False,
            ..
          },
          ..
        },
        { "cardinality": String("single"), .. },
        _,
      ],
      ..
    },
  )
  let serialized = item.describe().stringify()
  assert_false(serialized.contains("mapped_value"))
  assert_false(serialized.contains("correct_response"))
  guard item.describe()
    is {
      "responses": [{ "choice": { "choices": Array(choices), .. }, .. }, ..],
      ..
    } else {
    fail("missing choices")
  }
  choices.clear()
  assert_true(
    item.describe()
    is { "responses": [{ "choice": { "choices": [_, _, _], .. }, .. }, ..], .. },
  )
}

///|
test "invalid multiple declaration interaction and authored choice limits reject" {
  let xml = fixture("composite-multiple")
  for
    (old, replacement) in [
      ("max-choices=\"2\"", "max-choices=\"-1\""),
      ("max-choices=\"2\"", "max-choices=\"1\""),
      ("max-choices=\"2\"", "max-choices=\"4\""),
      ("min-choices=\"0\"", "min-choices=\"3\""),
      ("<qti-value>Feedback</qti-value>", "<qti-value>Unknown</qti-value>"),
      ("map-key=\"Quiz\"", "map-key=\"Unknown\""),
    ] {
    reject_composite_choice(xml.swap(old, replacement), "invalid_item")
  }
  reject_composite_choice(
    xml.swap(
      "cardinality=\"multiple\" base-type=\"identifier\"", "cardinality=\"multiple\" base-type=\"string\"",
    ),
    "unsupported",
  )
  reject_composite_choice(
    xml.swap("cardinality=\"multiple\"", "cardinality=\"ordered\""),
    "unsupported",
  )
  reject_composite_choice(
    fixture("composite-inline").swap(
      "cardinality=\"single\" base-type=\"identifier\"", "cardinality=\"multiple\" base-type=\"identifier\"",
    ),
    "invalid_item",
  )
}

///|
test "multiple default maximum remains one without silently becoming unlimited" {
  let xml = fixture("composite-choice")
    .swap(
      "identifier=\"METHOD\" cardinality=\"single\"", "identifier=\"METHOD\" cardinality=\"multiple\"",
    )
    .swap("max-choices=\"1\"", "")
  let item = @qti.compile_composite_item(xml)
  assert_eq(item.score_json("{\"METHOD\":[\"Formative\"]}").score, 2.0)
  reject_multiple_response(item, "{\"METHOD\":[\"Formative\",\"Summative\"]}")
}

///|
test "multiple container limits apply to typed API without JSON limits" {
  let item = @qti.compile_composite_item(fixture("composite-multiple-required"))
  for values in [Array::make(4097, "Quiz"), ["x".repeat(65537)]] {
    try
      item.score_responses({
        "EVIDENCE": Multiple(["Quiz", "Feedback"]),
        "TOOLS": Multiple(values),
      })
    catch {
      error => assert_eq(error.code(), "limit_exceeded")
    } noraise {
      _ => fail("oversized response accepted")
    }
  }
  assert_eq(
    item.score_responses({
      "EVIDENCE": Multiple(["Quiz", "Feedback"]),
      "TOOLS": Multiple(Array::make(4096, "Quiz")),
    }).score,
    3.0,
  )
}

///|
test "multiple package rows preserve independent failures and valid subsequent rows" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/composite-multiple-manifest.xml"),
      ),
      ("items/composite-multiple.xml", fixture("composite-multiple")),
      (
        "items/composite-multiple-required.xml",
        fixture("composite-multiple-required"),
      ),
    ]),
  )
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/composite-multiple-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 7)
  assert_eq(report.error_count, 3)
  assert_eq(report.rows().map(r => r.result.map(s => s.score)), [
    Some(4.0),
    Some(4.0),
    Some(2.0),
    Some(1.0),
    Some(0.0),
    None,
    None,
    None,
    Some(1.0),
    Some(2.0),
  ])
  assert_eq(report.attempts()[0].score_sum, Some(8.0))
  assert_eq(report.items()[0].score_mean, Some(1.8))
  assert_eq(report.items()[0].unanswered_count, 1)
  assert_true(report.items_csv().contains("\"mixed\",7,5,2"))
}
