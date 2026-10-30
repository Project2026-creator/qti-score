///|
fn invalid_match(item : @qti.Item, response : @qti.Response) -> Unit raise {
  try item.score(response) catch {
    error => assert_eq(error.code(), "invalid_response")
  } noraise {
    _ => fail("expected invalid association")
  }
}

///|
test "matching maps weighted directed pairs and compares the unordered container" {
  let item = @qti.compile_item(fixture("match"))
  assert_eq(item.base_type, DirectedPair)
  assert_eq(item.score(Multiple(["Quiz Diagnose"])).score, 1.0)
  assert_eq(
    item.score(Multiple(["Quiz Diagnose", "Portfolio Diagnose"])).score,
    0.5,
  )
  assert_eq(item.score(Multiple(["Quiz Growth"])).score, 0.0)
  let full = ["Observation Diagnose", "Portfolio Growth", "Quiz Diagnose"]
  let result = item.score(Multiple(full))
  assert_eq(result.score, 3.0)
  assert_eq(result.matches_correct, Some(true))
  assert_eq(item.explain(Multiple(full)).result, result)
}

///|
test "directed pairs collapse XML whitespace in responses answers and mappings" {
  let xml = fixture("match").swap("Quiz Diagnose", "  Quiz&#x9;  Diagnose  ")
  let item = @qti.compile_item(xml)
  let values = ["\tQuiz \n Diagnose\r "]
  assert_eq(item.score(Multiple(values)).score, 1.0)
  assert_eq(values, ["\tQuiz \n Diagnose\r "])
  assert_eq(item.correct_response().unwrap()[0], "Quiz Diagnose")
  let explanation = item.explain(Multiple(values))
  assert_true(
    explanation.steps.any(s => {
      s.details is { "value": String("Quiz Diagnose"), .. }
    }),
  )
}

///|
test "match responses reject reverse same-set unknown and malformed endpoints" {
  let item = @qti.compile_item(fixture("match"))
  for
    value in [
      "Diagnose Quiz", "Quiz Portfolio", "Quiz Missing", "quiz Diagnose", "Quiz",
      "Quiz Diagnose Growth", "Quiz\u{00a0}Diagnose", "1Quiz Diagnose", " ",
    ] {
    invalid_match(item, Multiple([value]))
  }
  invalid_match(item, Single("Quiz Diagnose"))
  invalid_match(item, Ordered(["Quiz Diagnose"]))
  invalid_match(item, Number(1.0))
}

///|
test "duplicate associations cannot be counted twice even after normalization" {
  let item = @qti.compile_item(fixture("match"))
  invalid_match(item, Multiple(["Quiz Diagnose", " Quiz\tDiagnose "]))
}

///|
test "source and target association maxima are independently enforced" {
  let source = fixture("match")
  let item = @qti.compile_item(source)
  invalid_match(item, Multiple(["Quiz Diagnose", "Quiz Growth"]))
  let target_limited = @qti.compile_item(
    source.swap(
      "identifier=\"Growth\" match-max=\"0\"", "identifier=\"Growth\" match-max=\"1\"",
    ),
  )
  invalid_match(
    target_limited,
    Multiple(["Portfolio Growth", "Observation Growth"]),
  )
  assert_eq(
    item.score(Multiple(["Quiz Diagnose", "Observation Diagnose"])).score,
    2.0,
  )
}

///|
test "global and per-choice minima apply to nonempty associations but NULL remains unanswered" {
  let xml = fixture("match")
    .swap(
      "max-associations=\"3\"", "min-associations=\"2\" max-associations=\"3\"",
    )
    .swap(
      "identifier=\"Portfolio\" match-max", "identifier=\"Portfolio\" match-min=\"1\" match-max",
    )
  let item = @qti.compile_item(xml)
  invalid_match(item, Multiple(["Portfolio Growth"]))
  invalid_match(item, Multiple(["Quiz Diagnose", "Observation Diagnose"]))
  assert_eq(
    item.score(Multiple(["Quiz Diagnose", "Portfolio Growth"])).score,
    2.0,
  )
  for response in [@qti.Response::Null, Multiple([])] {
    let result = item.score(response)
    assert_eq(result.status, Unanswered)
    assert_eq(result.score, 0.0)
  }
  let target_min = @qti.compile_item(
    fixture("match").swap(
      "identifier=\"Growth\" match-max", "identifier=\"Growth\" match-min=\"1\" match-max",
    ),
  )
  invalid_match(target_min, Multiple(["Quiz Diagnose"]))
}

///|
test "zero maximum is unlimited while missing maximum defaults to one" {
  let unlimited = @qti.compile_item(
    fixture("match")
    .swap("max-associations=\"3\"", "max-associations=\"0\"")
    .swap("match-max=\"1\"", "match-max=\"0\""),
  )
  assert_eq(
    unlimited.score(
      Multiple([
        "Quiz Diagnose", "Quiz Growth", "Portfolio Growth", "Observation Diagnose",
      ]),
    ).score,
    2.5,
  )
  let single = @qti.compile_item(fixture("match-single"))
  assert_eq(single.max_choices, 1)
  assert_eq(single.score(Single("Portfolio Growth")).score, 1.0)
  assert_eq(single.score(Single("Quiz Growth")).score, 0.0)
  invalid_match(single, Multiple(["Portfolio Growth"]))
  let multi = @qti.compile_item(
    fixture("match-single").swap(
      "cardinality=\"single\" base-type=\"directedPair\"", "cardinality=\"multiple\" base-type=\"directedPair\"",
    ),
  )
  invalid_match(multi, Multiple(["Quiz Growth", "Portfolio Growth"]))
}

///|
test "matching match_correct is order independent but direction sensitive" {
  let item = @qti.compile_item(
    fixture("match").swap("map_response.xml", "match_correct.xml"),
  )
  assert_eq(
    item.score(
      Multiple(["Portfolio Growth", "Quiz Diagnose", "Observation Diagnose"]),
    ).score,
    1.0,
  )
  assert_eq(item.score(Multiple(["Quiz Diagnose"])).score, 0.0)
}

///|
test "invalid match declarations and association bounds fail during compilation" {
  let source = fixture("match")
  for
    xml in [
      source.swap(
        "max-associations=\"3\"", "min-associations=\"4\" max-associations=\"3\"",
      ),
      source.swap("max-associations=\"3\"", "max-associations=\"-1\""),
      source.swap("identifier=\"Growth\"", "identifier=\"Diagnose\""),
      source.swap("identifier=\"Growth\"", "identifier=\"Quiz\""),
      source.swap("identifier=\"Growth\"", "identifier=\"SCORE\""),
      source.swap("match-max=\"1\"", "match-min=\"2\" match-max=\"1\""),
      source.swap("match-max=\"1\"", ""),
      source.swap("base-type=\"directedPair\"", "base-type=\"string\""),
      source.swap(
        "<qti-simple-match-set>", "<qti-simple-match-set/><qti-simple-match-set>",
      ),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(
    fixture("match-single").swap(
      "response-identifier=\"RESPONSE\"", "response-identifier=\"RESPONSE\" max-associations=\"0\"",
    ),
    "invalid_item",
  )
}

///|
test "authored pair keys are validated by direction and normalized uniqueness" {
  let source = fixture("match")
  for
    xml in [
      source.swap(
        "<qti-value>Quiz Diagnose</qti-value>", "<qti-value>Diagnose Quiz</qti-value>",
      ),
      source.swap(
        "<qti-value>Quiz Diagnose</qti-value>", "<qti-value>Quiz</qti-value>",
      ),
      source.swap(
        "<qti-value>Portfolio Growth</qti-value>", "<qti-value>Quiz Diagnose</qti-value>",
      ),
      source.swap("map-key=\"Quiz Diagnose\"", "map-key=\"Missing Diagnose\""),
      source.swap(
        "map-key=\"Portfolio Growth\"", "map-key=\" Quiz&#x9;Diagnose \"",
      ),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(
    source.swap("match-max=\"1\"", "match-max=\"1\" match-group=\"Diagnose\""),
    "unsupported",
  )
  rejected(
    source.swap("qti-match-interaction", "qti-associate-interaction"),
    "invalid_item",
  )
}

///|
test "pair mapping is case sensitive even with case-sensitive false" {
  let xml = fixture("match")
    .swap(
      "map-key=\"Portfolio Growth\"", "map-key=\"Portfolio Growth\" case-sensitive=\"false\"",
    )
    .swap(
      "</qti-simple-match-set>\n  </qti-match-interaction>", "<qti-simple-associable-choice identifier=\"growth\" match-max=\"0\">Other</qti-simple-associable-choice></qti-simple-match-set>\n  </qti-match-interaction>",
    )
  let item = @qti.compile_item(xml)
  assert_eq(item.score(Multiple(["Portfolio growth"])).score, 0.0)
}

///|
test "matching metadata is fresh and omits correct pairs and mapping values" {
  let item = @qti.compile_item(fixture("match"))
  let description = item.describe()
  assert_true(
    description
    is {
      "matching": { "sets": Array(sets), .. },
      "correct_response"? : None,
      ..
    } &&
    sets.length() == 2,
  )
  if description is Object(fields) {
    fields.clear()
  }
  assert_true(
    item.describe()
    is { "matching": { "max_associations": Number(3.0, ..), .. }, .. },
  )
  assert_eq(item.choices(), [])
}

///|
test "matching package batch retains partial scores NULL and local failures" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/match-manifest.xml"),
      ),
      ("items/match.xml", fixture("match")),
      ("items/match-single.xml", fixture("match-single")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/match-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 3)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(3.0),
    Some(0.5),
    None,
    Some(0.0),
  ])
  assert_eq(report.rows()[2].error.unwrap().code(), "invalid_response")
  assert_true(report.to_csv().contains("false,,,,\"invalid_response\""))
}
