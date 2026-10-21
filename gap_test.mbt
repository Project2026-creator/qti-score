///|
test "gap matching scores reusable words with direction and unordered pair containers" {
  let item = @qti.compile_item(fixture("gap"))
  let values = ["Feedback G3", "Adjust G2", "Feedback G1"]
  let result = item.score(Multiple(values))
  assert_eq(result.score, 3.0)
  assert_eq(result.matches_correct, Some(true))
  assert_eq(item.explain(Multiple(values)).result, result)
  assert_eq(item.score(Multiple(["Feedback G1", "Rank G2"])).score, 0.5)
  assert_eq(item.score(Multiple(["Rank G1"])).score, 0.0)
  invalid_match(item, Multiple(["G1 Feedback"]))
  invalid_match(item, Multiple(["Feedback Missing"]))
}

///|
test "gap targets allow only one choice and word reuse respects its maximum" {
  let item = @qti.compile_item(fixture("gap"))
  invalid_match(item, Multiple(["Feedback G1", "Rank G1"]))
  invalid_match(item, Multiple(["Feedback G1", "Feedback G2", "Feedback G3"]))
  invalid_match(item, Multiple(["Feedback G1", " Feedback\tG1 "]))
  assert_eq(item.score(Multiple(["Feedback G1", "Feedback G3"])).score, 2.0)
  let unlimited = @qti.compile_item(
    fixture("gap").swap("match-max=\"2\"", "match-max=\"0\""),
  )
  assert_eq(
    unlimited.score(Multiple(["Feedback G1", "Feedback G2", "Feedback G3"])).score,
    1.5,
  )
}

///|
test "required gaps and word minima constrain nonempty responses while NULL remains unanswered" {
  let item = @qti.compile_item(fixture("gap"))
  invalid_match(item, Multiple(["Adjust G2"]))
  for response in [@qti.Response::Null, Multiple([])] {
    assert_eq(item.score(response).status, Unanswered)
    assert_eq(item.score(response).score, 0.0)
  }
  let minimum = @qti.compile_item(
    fixture("gap").swap(
      "identifier=\"Adjust\" match-max", "identifier=\"Adjust\" match-min=\"1\" match-max",
    ),
  )
  invalid_match(minimum, Multiple(["Feedback G1"]))
  assert_eq(minimum.score(Multiple(["Feedback G1", "Adjust G2"])).score, 2.0)
}

///|
test "gap match_correct compares complete directed pairs and ignores array order" {
  let item = @qti.compile_item(
    fixture("gap").swap("map_response.xml", "match_correct.xml"),
  )
  assert_eq(
    item.score(Multiple(["Feedback G3", "Feedback G1", "Adjust G2"])).score,
    1.0,
  )
  assert_eq(item.score(Multiple(["Feedback G1", "Adjust G2"])).score, 0.0)
}

///|
test "single gap responses use single containers and an effective maximum of one" {
  let item = @qti.compile_item(fixture("gap-single"))
  assert_eq(item.max_choices, 1)
  assert_eq(item.score(Single("Improve Goal")).score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":\"Rank Goal\"}").score, 0.0)
  assert_eq(item.score(Single("")).status, Unanswered)
  invalid_match(item, Multiple(["Improve Goal"]))
  invalid_match(item, Ordered(["Improve Goal"]))
  rejected(
    fixture("gap-single").swap(
      "response-identifier=\"RESPONSE\"", "response-identifier=\"RESPONSE\" max-associations=\"0\"",
    ),
    "invalid_item",
  )
}

///|
test "gap association limits reject invalid declarations and inconsistent authored responses" {
  let source = fixture("gap")
  for
    xml in [
      source.swap("max-associations=\"0\"", "max-associations=\"2\""),
      source.swap(
        "max-associations=\"0\"", "min-associations=\"4\" max-associations=\"3\"",
      ),
      source.swap("max-associations=\"0\"", ""),
      source.swap(
        "identifier=\"Feedback\" match-max=\"2\"", "identifier=\"Feedback\" match-min=\"3\" match-max=\"2\"",
      ),
      source.swap(
        "identifier=\"Feedback\" match-max=\"2\"", "identifier=\"Feedback\"",
      ),
      source.swap("required=\"true\"", "required=\"yes\""),
      source.swap(
        "<qti-value>Feedback G3</qti-value>", "<qti-value>Rank G1</qti-value>",
      ),
      source.swap("map-key=\"Feedback G1\"", "map-key=\"G1 Feedback\""),
    ] {
    rejected(xml, "invalid_item")
  }
}

///|
test "gap identifiers cannot collide with choices other gaps or item variables" {
  let source = fixture("gap")
  for
    xml in [
      source.swap("identifier=\"G3\"", "identifier=\"G2\""),
      source.swap("identifier=\"G3\"", "identifier=\"Feedback\""),
      source.swap("identifier=\"Rank\"", "identifier=\"Feedback\""),
      source.swap("identifier=\"G3\"", "identifier=\"SCORE\""),
      source.swap("identifier=\"Rank\"", "identifier=\"RESPONSE\""),
    ] {
    rejected(xml, "invalid_item")
  }
}

///|
test "gap structure rejects absent choices gaps and single cardinality with multiple gaps" {
  let single = fixture("gap-single")
  rejected(
    single.swap("<qti-gap identifier=\"Goal\" label=\"目的\"/>", ""),
    "invalid_item",
  )
  rejected(
    single.swap(
      "<qti-gap identifier=\"Goal\" label=\"目的\"/>", "<qti-gap identifier=\"Goal\"/><qti-gap identifier=\"Other\"/>",
    ),
    "invalid_item",
  )
  rejected(
    single.swap(
      "<qti-gap identifier=\"Goal\" label=\"目的\"/>", "<qti-gap identifier=\"Goal\">not empty</qti-gap>",
    ),
    "invalid_item",
  )
  let no_choices = single
    .swap(
      "<qti-gap-text identifier=\"Improve\" match-max=\"1\">改进学习</qti-gap-text>",
      "",
    )
    .swap(
      "<qti-gap-text identifier=\"Rank\" match-max=\"1\">公开排名</qti-gap-text>",
      "",
    )
  rejected(no_choices, "invalid_item")
}

///|
test "gap elements cannot escape their interaction and unsupported content is explicit" {
  rejected(
    fixture("single").swap(
      "<qti-item-body>", "<qti-item-body><p><qti-gap identifier=\"G\"/></p>",
    ),
    "invalid_item",
  )
  let source = fixture("gap-single")
  for
    xml in [
      source.swap("qti-gap-text", "qti-gap-img"),
      source.swap(
        "identifier=\"Improve\" match-max", "identifier=\"Improve\" match-group=\"Goal\" match-max",
      ),
      source.swap(
        "identifier=\"Goal\"", "identifier=\"Goal\" match-group=\"Improve\"",
      ),
      source.swap(
        "identifier=\"Goal\"", "identifier=\"Goal\" template-identifier=\"T\"",
      ),
      source.swap("<p>", "<p style=\"display:none\">"),
      source.swap(
        "改进学习</qti-gap-text>", "<qti-gap identifier=\"Nested\"/></qti-gap-text>",
      ),
    ] {
    rejected(xml, "unsupported")
  }
  rejected(
    source.swap(
      "identifier=\"Goal\"", "xmlns=\"http://www.w3.org/1999/xhtml\" identifier=\"Goal\"",
    ),
    "unsupported",
  )
}

///|
test "mixed XML content retains text entities CDATA inline formatting and gap order" {
  let source = fixture("gap-single").swap(
    "评价的主要目的是", "<![CDATA[甲<乙]]>&amp;<strong>中<span>间</span></strong>",
  )
  let item = @qti.compile_item(source)
  let description = item.describe()
  guard description is { "gap_matching": { "passage": Array(parts), .. }, .. } else {
    fail("missing passage")
  }
  // Check the relative order, not only the presence of text pieces.
  let plain = parts
    .map(p => {
      match p {
        { "text": String(s), .. } => s
        { "gap": String(id), .. } => "[\{id}]"
        _ => "?"
      }
    })
    .join("")
  assert_eq(plain, "甲<乙&中间[Goal]。\n")
}

///|
test "gap metadata excludes bank and prompt from passage and remains fresh" {
  let item = @qti.compile_item(fixture("gap"))
  let description = item.describe()
  assert_true(
    description
    is {
      "matching"? : None,
      "gap_matching": { "passage": Array(parts), "sets": Array(sets), .. },
      ..
    } &&
    sets.length() == 2 &&
    parts.length() == 10,
  )
  if description is Object(fields) {
    fields.clear()
  }
  assert_true(
    item.describe()
    is { "gap_matching": { "max_associations": Number(0.0, ..), .. }, .. },
  )
  let values = [" Feedback\tG1 "]
  assert_eq(item.score(Multiple(values)).score, 1.0)
  assert_eq(values, [" Feedback\tG1 "])
}

///|
test "gap package batch preserves partial scores per-row errors and unanswered status" {
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", @fs.read_file_to_string("examples/gap-manifest.xml")),
      ("items/gap.xml", fixture("gap")),
      ("items/gap-single.xml", fixture("gap-single")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/gap-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 4)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(4.0),
    Some(0.5),
    None,
    Some(0.0),
  ])
  assert_true(report.to_csv().contains("false,,,,\"invalid_response\""))
}
