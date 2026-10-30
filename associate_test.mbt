///|
test "associate canonicalizes endpoints in correct answers mappings and learner values" {
  let item = @qti.compile_item(fixture("associate"))
  assert_eq(item.base_type, Pair)
  let response = [
    "Memory Cognitivism", "ActiveLearning Constructivism", "Reinforcement Behaviorism",
  ]
  let full = item.score(Multiple(response))
  assert_eq(full.score, 3.0)
  assert_eq(full.matches_correct, Some(true))
  assert_eq(item.explain(Multiple(response)).result, full)
  assert_eq(response[0], "Memory Cognitivism")
  assert_eq(
    item.correct_response().unwrap()[0],
    "ActiveLearning Constructivism",
  )
  assert_eq(
    item.score(Multiple(["\tConstructivism \r\n ActiveLearning "])).score,
    1.0,
  )
  assert_eq(item.score(Multiple(["Behaviorism Cognitivism"])).score, 0.0)
  assert_eq(
    item.score(
      Multiple(["Constructivism ActiveLearning", "Behaviorism Cognitivism"]),
    ).score,
    0.5,
  )
}

///|
test "associate NULL and empty containers remain unanswered" {
  let item = @qti.compile_item(fixture("associate"))
  for input in ["{}", "{\"RESPONSE\":null}", "{\"RESPONSE\":[]}"] {
    let score = item.score_json(input)
    assert_eq(score.status, Unanswered)
    assert_eq(score.score, 0.0)
  }
}

///|
test "associate rejects self unknown malformed and reversed duplicate associations" {
  let item = @qti.compile_item(fixture("associate"))
  for
    pairs in [
      ["Memory Memory"],
      ["Unknown Memory"],
      ["memory Cognitivism"],
      ["Memory"],
      ["Memory Cognitivism Extra"],
      ["Memory\u{00a0}Cognitivism"],
      ["1Memory Cognitivism"],
      ["Memory Cognitivism", " Cognitivism\t Memory "],
      ["Constructivism ActiveLearning", "Constructivism Behaviorism"],
    ] {
    invalid_match(item, Multiple(pairs))
  }
  invalid_match(item, Single("Memory Cognitivism"))
  invalid_match(item, Number(1.0))
}

///|
test "associate match correct ignores container order and endpoint order" {
  let source = fixture("associate").swap(
    "map_response.xml", "match_correct.xml",
  )
  let item = @qti.compile_item(source)
  assert_eq(
    item.score(
      Multiple([
        "Memory Cognitivism", "ActiveLearning Constructivism", "Reinforcement Behaviorism",
      ]),
    ).score,
    1.0,
  )
  assert_eq(item.score(Multiple(["Memory Cognitivism"])).score, 0.0)
}

///|
test "associate supports single cardinality without changing response objects" {
  let source = fixture("associate")
    .swap("cardinality=\"multiple\"", "cardinality=\"single\"")
    .swap("max-associations=\"3\"", "max-associations=\"1\"")
    .swap(
      "<qti-value>Behaviorism Reinforcement</qti-value><qti-value>Cognitivism Memory</qti-value>",
      "",
    )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Single("ActiveLearning Constructivism")).score, 1.0)
  assert_eq(item.score(Single("")).status, Unanswered)
  invalid_match(item, Multiple(["ActiveLearning Constructivism"]))
}

///|
test "associate enforces minima maxima and unlimited endpoint counts" {
  let source = fixture("associate").swap("match-max=\"1\"", "match-max=\"0\"")
  let unlimited = @qti.compile_item(source)
  assert_eq(
    unlimited.score(Multiple(["Memory Cognitivism", "Memory Constructivism"])).score,
    0.5,
  )
  invalid_match(
    unlimited,
    Multiple([
      "Memory Cognitivism", "Memory Constructivism", "Memory Behaviorism", "Memory Reinforcement",
    ]),
  )
  let required = @qti.compile_item(
    source
    .swap(
      "max-associations=\"3\"", "min-associations=\"2\" max-associations=\"3\"",
    )
    .swap(
      "identifier=\"Memory\" match-max=\"0\"", "identifier=\"Memory\" match-min=\"1\" match-max=\"0\"",
    ),
  )
  invalid_match(required, Multiple(["Constructivism ActiveLearning"]))
  invalid_match(
    required,
    Multiple(["Constructivism ActiveLearning", "Behaviorism Reinforcement"]),
  )
  assert_eq(
    required.score(Multiple(["Memory Cognitivism", "Memory Constructivism"])).score,
    0.5,
  )
  assert_eq(required.score(Null).status, Unanswered)
}

///|
test "associate enforces both authored match groups for either endpoint order" {
  let source = fixture("associate")
    .swap(
      "identifier=\"Memory\" match-max", "identifier=\"Memory\" match-group=\"Cognitivism\" match-max",
    )
    .swap(
      "identifier=\"Constructivism\" match-max", "identifier=\"Constructivism\" match-group=\"ActiveLearning\" match-max",
    )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Multiple(["Memory Cognitivism"])).score, 1.0)
  invalid_match(item, Multiple(["Memory Behaviorism"]))
  invalid_match(item, Multiple(["Cognitivism Constructivism"]))
  invalid_match(item, Multiple(["Constructivism Cognitivism"]))
}

///|
test "associate rejects ambiguous reverse mapping keys and invalid authored endpoints" {
  let source = fixture("associate")
  for
    xml in [
      source.swap(
        "map-key=\"Behaviorism Reinforcement\"", "map-key=\"ActiveLearning Constructivism\"",
      ),
      source.swap(
        "map-key=\"Behaviorism Reinforcement\"", "map-key=\"Memory Memory\"",
      ),
      source.swap(
        "<qti-value>Cognitivism Memory</qti-value>", "<qti-value>Memory Memory</qti-value>",
      ),
      source.swap(
        "identifier=\"Memory\" match-max", "identifier=\"Memory\" match-group=\"Unknown\" match-max",
      ),
      source.swap(
        "max-associations=\"3\"", "min-associations=\"4\" max-associations=\"3\"",
      ),
      source.swap("base-type=\"pair\"", "base-type=\"directedPair\""),
      source.swap("identifier=\"Memory\"", "identifier=\"Behaviorism\""),
    ] {
    try @qti.compile_item(xml) catch {
      error => assert_eq(error.code(), "invalid_item")
    } noraise {
      _ => fail("invalid associate item accepted")
    }
  }
}

///|
test "associate metadata is fresh and excludes correct pairs and scoring keys" {
  let item = @qti.compile_item(fixture("associate"))
  let metadata = item.describe()
  guard metadata
    is {
      "base_type": String("pair"),
      "association": { "choices": Array(choices), "shuffle": True, .. },
      ..
    } else {
    fail("association metadata missing")
  }
  assert_eq(choices.length(), 6)
  assert_true(choices[5] is { "fixed": True, .. })
  choices.clear()
  assert_true(
    item.describe() is { "association": { "choices": Array(fresh), .. }, .. } &&
    fresh.length() == 6,
  )
  assert_false(metadata.stringify().contains("mapped_value"))
  assert_false(metadata.stringify().contains("correct_response"))
}

///|
test "associate typed processing supports pair equality and canonical outcome assignment" {
  let xml = fixture("associate")
    .swap("RESPONSE", "LINKS")
    .swap(
      "<qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/map_response.xml\"/>",
      "<qti-response-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-map-response identifier=\"LINKS\"/></qti-set-outcome-value><qti-set-outcome-value identifier=\"PAIR\"><qti-base-value base-type=\"pair\">Memory Cognitivism</qti-base-value></qti-set-outcome-value></qti-response-processing>",
    )
    .swap(
      "<qti-item-body>", "<qti-outcome-declaration identifier=\"PAIR\" cardinality=\"single\" base-type=\"pair\"/><qti-item-body>",
    )
  let item = @qti.compile_assessment_item(xml)
  let result = item.outcomes_json("{\"LINKS\":[\"Memory Cognitivism\"]}")
  assert_eq(result, { "SCORE": 1, "PAIR": "Cognitivism Memory" })
  assert_true(item.describe() is { "association": _, .. })
  assert_true(item.outcomes_json("{}") is { "SCORE": Null, .. })
}

///|
test "pair expressions compare reverse endpoints in match member and mapped defaults" {
  let declarations =
    #|<qti-response-declaration identifier="P" cardinality="multiple" base-type="pair"><qti-correct-response><qti-value>A LongName</qti-value></qti-correct-response><qti-mapping default-value="-1"><qti-map-entry map-key="LongName A" mapped-value="2"/></qti-mapping></qti-response-declaration>
    #|<qti-outcome-declaration identifier="SCORE" cardinality="single" base-type="float"/>
    #|<qti-outcome-declaration identifier="MATCH" cardinality="single" base-type="boolean"/>
    #|<qti-outcome-declaration identifier="MEMBER" cardinality="single" base-type="boolean"/>
  let rules =
    #|<qti-set-outcome-value identifier="SCORE"><qti-map-response identifier="P"/></qti-set-outcome-value>
    #|<qti-set-outcome-value identifier="MATCH"><qti-match><qti-variable identifier="P"/><qti-correct identifier="P"/></qti-match></qti-set-outcome-value>
    #|<qti-set-outcome-value identifier="MEMBER"><qti-member><qti-base-value base-type="pair">LongName A</qti-base-value><qti-variable identifier="P"/></qti-member></qti-set-outcome-value>
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({ "P": ["LongName A"] }), {
    "SCORE": 2,
    "MATCH": true,
    "MEMBER": true,
  })
  assert_true(
    program.evaluate_json({ "P": ["Other LongName"] })
    is { "SCORE": Number(-1, ..), "MATCH": False, "MEMBER": False, .. },
  )
}

///|
test "associate rejects presentation features that would be lost by the plain text renderer" {
  for
    xml in [
      fixture("associate").swap(
        "identifier=\"Memory\" match-max", "identifier=\"Memory\" template-identifier=\"VISIBLE\" match-max",
      ),
      fixture("associate").swap(
        "identifier=\"Memory\" match-max", "identifier=\"Memory\" show-hide=\"hide\" match-max",
      ),
      fixture("associate").swap(
        "记忆加工", "<img src=\"image.png\" alt=\"memory\"/>",
      ),
    ] {
    try @qti.compile_item(xml) catch {
      error => assert_eq(error.code(), "unsupported")
    } noraise {
      _ => fail("unsupported associate presentation accepted")
    }
  }
}

///|
test "associate test session restores drafts and exports standard pair variables" {
  let plan = @qti.compile_assessment_test(
    fixture("associate-test"),
    Map([
      (
        "items/associate.xml",
        @qti.compile_assessment_item(fixture("associate")),
      ),
    ]),
  )
  let session = plan.new_session("pair-session")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":[\"Memory Cognitivism\"]}}",
    ),
  )
  let restored = plan.restore_session(session.snapshot())
  assert_eq(restored.describe(), session.describe())
  ignore(restored.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(restored.act_json("{\"type\":\"finish_part\",\"time\":3}"))
  let report = restored.report("2026-10-30T12:00:00Z")
  let xml = @qti.assessment_result_xml(report)
  assert_true(xml.contains("baseType=\"pair\""))
  assert_true(xml.contains("Cognitivism Memory"), msg=xml)
  assert_false(xml.contains("correctResponse"))
}
