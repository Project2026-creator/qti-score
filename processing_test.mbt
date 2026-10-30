///|
fn processed_fixture() -> String {
  (
    #|<qti-assessment-item xmlns="http://www.imsglobal.org/xsd/imsqtiasi_v3p0" identifier="cross_response" title="Combined measurement" adaptive="false" time-dependent="false">
    #|<qti-response-declaration identifier="LEFT" cardinality="single" base-type="float"><qti-correct-response><qti-value>2</qti-value></qti-correct-response></qti-response-declaration>
    #|<qti-response-declaration identifier="RIGHT" cardinality="single" base-type="float"><qti-correct-response><qti-value>3</qti-value></qti-correct-response></qti-response-declaration>
    #|<qti-outcome-declaration identifier="SCORE" cardinality="single" base-type="float"/>
    #|<qti-outcome-declaration identifier="COPY" cardinality="single" base-type="float"/>
    #|<qti-outcome-declaration identifier="FEEDBACK" cardinality="single" base-type="identifier"/>
    #|<qti-outcome-declaration identifier="COMPLETE" cardinality="single" base-type="boolean"/>
    #|<qti-item-body><p>Left: <qti-text-entry-interaction response-identifier="LEFT"/> Right: <qti-text-entry-interaction response-identifier="RIGHT"/></p></qti-item-body>
    #|<qti-response-processing>
    #|<qti-set-outcome-value identifier="COMPLETE"><qti-and><qti-not><qti-is-null><qti-variable identifier="LEFT"/></qti-is-null></qti-not><qti-not><qti-is-null><qti-variable identifier="RIGHT"/></qti-is-null></qti-not></qti-and></qti-set-outcome-value>
    #|<qti-response-condition>
    #|<qti-response-if><qti-and><qti-equal><qti-variable identifier="LEFT"/><qti-correct identifier="LEFT"/></qti-equal><qti-equal><qti-variable identifier="RIGHT"/><qti-correct identifier="RIGHT"/></qti-equal></qti-and><qti-set-outcome-value identifier="SCORE"><qti-sum><qti-variable identifier="LEFT"/><qti-variable identifier="RIGHT"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier="FEEDBACK"><qti-base-value base-type="identifier">both</qti-base-value></qti-set-outcome-value></qti-response-if>
    #|<qti-response-else-if><qti-equal><qti-variable identifier="LEFT"/><qti-correct identifier="LEFT"/></qti-equal><qti-set-outcome-value identifier="SCORE"><qti-base-value base-type="float">1</qti-base-value></qti-set-outcome-value><qti-set-outcome-value identifier="FEEDBACK"><qti-base-value base-type="identifier">partial</qti-base-value></qti-set-outcome-value></qti-response-else-if>
    #|<qti-response-else><qti-set-outcome-value identifier="SCORE"><qti-base-value base-type="float">0</qti-base-value></qti-set-outcome-value><qti-set-outcome-value identifier="FEEDBACK"><qti-base-value base-type="identifier">retry</qti-base-value></qti-set-outcome-value></qti-response-else>
    #|</qti-response-condition>
    #|<qti-set-outcome-value identifier="COPY"><qti-variable identifier="SCORE"/></qti-set-outcome-value>
    #|</qti-response-processing>
    #|<qti-modal-feedback outcome-identifier="FEEDBACK" show-hide="show" identifier="both" title="Combined"><qti-content-body><p>Both <strong>measurements</strong> match.</p></qti-content-body></qti-modal-feedback>
    #|<qti-modal-feedback outcome-identifier="FEEDBACK" show-hide="hide" identifier="both"><qti-content-body><p>Review both measurements.</p></qti-content-body></qti-modal-feedback>
    #|</qti-assessment-item>
  )
}

///|
fn processing_program_fixture(declarations : String, rules : String) -> String {
  "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"program\" title=\"Program\">\{declarations}<qti-response-processing>\{rules}</qti-response-processing></qti-assessment-item>"
}

///|
test "typed processing compiles cross response conditions and sequential multi outcome assignments" {
  let item = @qti.compile_processed_item(processed_fixture()) catch {
    e => fail(e.message())
  }
  assert_eq(item.identifier(), "cross_response")
  assert_eq(item.score_json("{\"LEFT\":2,\"RIGHT\":3}").score, 5.0)
  assert_eq(item.score_json("{\"LEFT\":2}").score, 1.0)
  assert_eq(item.score_json("{\"LEFT\":1,\"RIGHT\":3}").score, 0.0)
  assert_eq(item.score_json("{}").status, Unanswered)
  assert_eq(
    item.score_json("{\"LEFT\":2,\"RIGHT\":3}").matches_correct,
    Some(true),
  )
  let outcomes = item.outcomes_json("{\"LEFT\":2,\"RIGHT\":3}")
  assert_eq(outcomes, {
    "COMPLETE": true,
    "COPY": 5,
    "FEEDBACK": "both",
    "SCORE": 5,
  })
  assert_eq(
    item.explain_json("{\"LEFT\":2,\"RIGHT\":3}").result,
    item.score_json("{\"LEFT\":2,\"RIGHT\":3}"),
  )
  assert_true(
    item.explain_json("{\"LEFT\":2}").steps.any(s => {
      s.operation == "set_outcome_value"
    }),
  )
}

///|
test "typed feedback uses authored identifiers and safe text without leaking solutions in descriptions" {
  let item = @qti.compile_processed_item(processed_fixture())
  guard item.feedback_json("{\"LEFT\":2,\"RIGHT\":3}")
    is [
      {
        "identifier": String("both"),
        "text": String("Both measurements match."),
        ..
      },
    ] else {
    fail("correct modal feedback not selected")
  }
  guard item.feedback_json("{\"LEFT\":2}")
    is [{ "text": String("Review both measurements."), .. }] else {
    fail("hide feedback not selected")
  }
  let description = item.describe().stringify()
  assert_true(!description.contains("Both measurements match"))
  assert_true(!description.contains("correct"))
  assert_true(!description.contains("default_value"))
  guard item.describe()
    is {
      "kind": String("composite"),
      "declarations": Array(declarations),
      "responses": [_, _],
      ..
    } else {
    fail("missing metadata")
  }
  assert_eq(declarations.length(), 6)
  if item.describe() is { "responses": Array(responses), .. } {
    responses.clear()
  }
  guard item.describe() is { "responses": [_, _], .. } else {
    fail("caller mutated compiled description")
  }
}

///|
test "typed validation runs independently of response processing and rejects all malformed inputs" {
  let item = @qti.compile_processed_item(processed_fixture())
  item.validate_json("{\"LEFT\":2}")
  for
    input in [
      "[]", "{\"EXTRA\":1}", "{\"LEFT\":true}", "{\"LEFT\":[]}", "{\"LEFT\":\"NaN\"}",
      "{\"LEFT\":2,\"LEFT\":3}",
    ] {
    try item.validate_json(input) catch {
      _ => ()
    } noraise {
      _ => fail("invalid input accepted")
    }
  }
}

///|
test "typed evaluator propagates NULL and three valued boolean logic" {
  let declarations = "<qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"boolean\"/><qti-outcome-declaration identifier=\"A\" cardinality=\"single\" base-type=\"boolean\"/><qti-outcome-declaration identifier=\"B\" cardinality=\"single\" base-type=\"boolean\"/><qti-outcome-declaration identifier=\"C\" cardinality=\"single\" base-type=\"boolean\"/>"
  let rules = "<qti-set-outcome-value identifier=\"A\"><qti-and><qti-variable identifier=\"R\"/><qti-base-value base-type=\"boolean\">false</qti-base-value></qti-and></qti-set-outcome-value><qti-set-outcome-value identifier=\"B\"><qti-or><qti-variable identifier=\"R\"/><qti-base-value base-type=\"boolean\">true</qti-base-value></qti-or></qti-set-outcome-value><qti-set-outcome-value identifier=\"C\"><qti-not><qti-variable identifier=\"R\"/></qti-not></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({}), {
    "A": false,
    "B": true,
    "C": Json::null(),
  })
  assert_eq(program.evaluate_json({ "R": true }), {
    "A": false,
    "B": true,
    "C": false,
  })
}

///|
test "typed evaluator preserves containers multiplicity order and NULL arithmetic" {
  let declarations = "<qti-response-declaration identifier=\"R\" cardinality=\"multiple\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"TOTAL\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"COUNT\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"HAS\" cardinality=\"single\" base-type=\"boolean\"/><qti-outcome-declaration identifier=\"DIV\" cardinality=\"single\" base-type=\"float\"/>"
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-variable identifier=\"R\"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"COUNT\"><qti-container-size><qti-variable identifier=\"R\"/></qti-container-size></qti-set-outcome-value><qti-set-outcome-value identifier=\"HAS\"><qti-member><qti-base-value base-type=\"integer\">2</qti-base-value><qti-variable identifier=\"R\"/></qti-member></qti-set-outcome-value><qti-set-outcome-value identifier=\"DIV\"><qti-divide><qti-base-value base-type=\"integer\">1</qti-base-value><qti-base-value base-type=\"integer\">0</qti-base-value></qti-divide></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({ "R": [1, 2, 2] }), {
    "COUNT": 3,
    "DIV": Json::null(),
    "HAS": true,
    "TOTAL": 5,
  })
  assert_eq(program.evaluate_json({}), {
    "COUNT": 0,
    "DIV": Json::null(),
    "HAS": Json::null(),
    "TOTAL": Json::null(),
  })
}

///|
test "typed compiler rejects wrong types unknown variables unsupported operators and malformed branch order" {
  for
    xml in [
      processed_fixture().replace_all(
        old="<qti-variable identifier=\"SCORE\"/>",
        new="<qti-variable identifier=\"FEEDBACK\"/>",
      ),
      processed_fixture().replace_all(
        old="<qti-base-value base-type=\"float\">1</qti-base-value>",
        new="<qti-base-value base-type=\"integer\">1</qti-base-value>",
      ),
      processed_fixture().replace_all(
        old="<qti-variable identifier=\"LEFT\"/>",
        new="<qti-variable identifier=\"UNKNOWN\"/>",
      ),
      processed_fixture().replace_all(old="qti-sum", new="qti-custom-operator"),
      processed_fixture().replace_all(
        old="qti-response-else-if",
        new="qti-response-if",
      ),
      processed_fixture().replace_all(
        old="<strong>measurements</strong>",
        new="<script>alert(1)</script>",
      ),
    ] {
    try @qti.compile_processed_item(xml) catch {
      _ => ()
    } noraise {
      _ => fail("invalid typed item accepted")
    }
  }
}

///|
test "typed test outcome processing gathers referenced item scores and resets defaults" {
  let xml = "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"test\" title=\"Test\"><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum></qti-set-outcome-value></qti-outcome-processing></qti-assessment-test>"
  let program = @qti.compile_processing_program(xml)
  let input : Json = {
    "items": [
      { "identifier": "one", "outcomes": { "SCORE": 2.0 } },
      { "identifier": "two", "outcomes": { "SCORE": 3.0 } },
      { "identifier": "three", "outcomes": { "SCORE": Json::null() } },
    ],
  }
  assert_eq(program.evaluate_json(input), { "SCORE": 5 })
  assert_eq(program.evaluate_json({ "items": [] }), { "SCORE": Json::null() })
  try program.evaluate_json({ "SCORE": 99 }) catch {
    _ => ()
  } noraise {
    _ => fail("caller supplied test outcome")
  }
}

///|
test "typed processing preserves existing template and inline rule example results" {
  for
    name in [
      "single", "multiple", "text", "order", "match", "gap", "hottext", "inline-choice",
      "numeric", "slider", "composite", "composite-choice", "composite-inline", "composite-multiple",
      "composite-slider", "composite-tolerance", "composite-fallback",
    ] {
    let xml = fixture(name)
    let input = @fs.read_file_to_string("examples/\{name}-response.json")
    let expected = @qti.compile_assessment_item(xml).score_json(input)
    let item = @qti.compile_processed_item(xml) catch {
      e => fail("\{name}: \{e.message()}")
    }
    assert_eq(item.score_json(input), expected)
    item.validate_json(input)
    assert_eq(item.feedback_json(input), Json::array([]))
  }
}

///|
test "typed processing validation does not evaluate an authored division by zero" {
  let xml = processed_fixture()
    .replace_all(old="qti-sum", new="qti-divide")
    .replace_all(old="<qti-value>3</qti-value>", new="<qti-value>0</qti-value>")
  let item = @qti.compile_processed_item(xml)
  item.validate_json("{\"LEFT\":2,\"RIGHT\":0}")
  guard item.outcomes_json("{\"LEFT\":2,\"RIGHT\":0}")
    is { "SCORE": Null, "COPY": Null, .. } else {
    fail("NULL division did not propagate")
  }
  try item.score_json("{\"LEFT\":2,\"RIGHT\":0}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("NULL SCORE silently became zero")
  }
}

///|
test "typed processing exit stops subsequent assignments and outcomes reset on each run" {
  let declarations = "<qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"integer\"><qti-default-value><qti-value>7</qti-value></qti-default-value></qti-outcome-declaration>"
  let rules = "<qti-response-condition><qti-response-if><qti-is-null><qti-variable identifier=\"R\"/></qti-is-null><qti-exit-response/></qti-response-if></qti-response-condition><qti-set-outcome-value identifier=\"SCORE\"><qti-variable identifier=\"R\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({ "R": 2 }), { "SCORE": 2 })
  assert_eq(program.evaluate_json({}), { "SCORE": 7 })
  assert_eq(program.evaluate_json({ "R": 0 }), { "SCORE": 0 })
  assert_eq(program.evaluate_json({}), { "SCORE": 7 })
}

///|
test "typed processing rejects nonfinite results and unsafe authored and response integers" {
  let declarations = "<qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"integer\"/>"
  let rules = "<qti-set-outcome-value identifier=\"SCORE\"><qti-product><qti-variable identifier=\"R\"/><qti-base-value base-type=\"integer\">2</qti-base-value></qti-product></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  for
    input in [
      "{\"R\":2.0}", "{\"R\":2e0}", "{\"R\":9007199254740992}", "{\"R\":9007199254740991}",
      "{\"R\":true}",
    ] {
    try
      program.evaluate_json(@json.parse(input, preserve_number_repr=true))
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid integer accepted")
    }
  }
  let overflow = processing_program_fixture(
    declarations.replace_all(old="integer", new="float"),
    rules.replace_all(old="integer\">2", new="float\">1e308"),
  )
  let program = @qti.compile_processing_program(overflow)
  try program.evaluate_json({ "R": 1.0e308 }) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("nonfinite outcome accepted")
  }
}

///|
test "typed processing match compares ordered sequences and bags with multiplicity" {
  let declarations = "<qti-response-declaration identifier=\"A\" cardinality=\"multiple\" base-type=\"identifier\"/><qti-response-declaration identifier=\"B\" cardinality=\"multiple\" base-type=\"identifier\"/><qti-outcome-declaration identifier=\"MATCH\" cardinality=\"single\" base-type=\"boolean\"/>"
  let rules = "<qti-set-outcome-value identifier=\"MATCH\"><qti-match><qti-variable identifier=\"A\"/><qti-variable identifier=\"B\"/></qti-match></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(
    program.evaluate_json({ "A": ["x", "x", "y"], "B": ["y", "x", "x"] }),
    { "MATCH": true },
  )
  assert_eq(program.evaluate_json({ "A": ["x", "x"], "B": ["x", "y"] }), {
    "MATCH": false,
  })
  let ordered = @qti.compile_processing_program(
    processing_program_fixture(
      declarations.replace_all(old="multiple", new="ordered"),
      rules,
    ),
  )
  assert_eq(ordered.evaluate_json({ "A": ["x", "y"], "B": ["y", "x"] }), {
    "MATCH": false,
  })
  assert_eq(ordered.evaluate_json({ "A": [], "B": [] }), {
    "MATCH": Json::null(),
  })
}

///|
test "typed processing NULL expressions remain assignable and container constructors omit NULL" {
  let declarations = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"IDS\" cardinality=\"ordered\" base-type=\"identifier\"/><qti-outcome-declaration identifier=\"FIRST\" cardinality=\"single\" base-type=\"identifier\"/>"
  let rules = "<qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-null/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"IDS\"><qti-ordered><qti-null/><qti-base-value base-type=\"identifier\">first</qti-base-value><qti-base-value base-type=\"identifier\">second</qti-base-value></qti-ordered></qti-set-outcome-value><qti-set-outcome-value identifier=\"FIRST\"><qti-index n=\"2\"><qti-variable identifier=\"IDS\"/></qti-index></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({}), {
    "SCORE": Json::null(),
    "IDS": ["first", "second"],
    "FIRST": "second",
  })
}

///|
test "typed default expression distinguishes numeric initialization from an authored default" {
  let declarations = "<qti-outcome-declaration identifier=\"INITIAL\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"NONE\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"AUTHORED\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>2</qti-value></qti-default-value></qti-outcome-declaration><qti-outcome-declaration identifier=\"COPY\" cardinality=\"single\" base-type=\"float\"/>"
  let rules = "<qti-set-outcome-value identifier=\"NONE\"><qti-default identifier=\"INITIAL\"/></qti-set-outcome-value><qti-set-outcome-value identifier=\"COPY\"><qti-default identifier=\"AUTHORED\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({}), {
    "INITIAL": 0,
    "NONE": Json::null(),
    "AUTHORED": 2,
    "COPY": 2,
  })
}

///|
test "typed integer conversion and floor division preserve negative arithmetic semantics" {
  let declarations = "<qti-outcome-declaration identifier=\"FLOAT\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"DIV\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"MOD\" cardinality=\"single\" base-type=\"integer\"/>"
  let operands = "<qti-base-value base-type=\"integer\">-5</qti-base-value><qti-base-value base-type=\"integer\">2</qti-base-value>"
  let rules = "<qti-set-outcome-value identifier=\"DIV\"><qti-integer-divide>\{operands}</qti-integer-divide></qti-set-outcome-value><qti-set-outcome-value identifier=\"MOD\"><qti-integer-modulus>\{operands}</qti-integer-modulus></qti-set-outcome-value><qti-set-outcome-value identifier=\"FLOAT\"><qti-integer-to-float><qti-variable identifier=\"DIV\"/></qti-integer-to-float></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({}), { "FLOAT": -3, "DIV": -3, "MOD": 1 })
}

///|
test "typed feedback supports multiple identifiers and rejects nonidentifier outcome bindings" {
  let xml = processed_fixture()
    .replace_all(
      old="identifier=\"FEEDBACK\" cardinality=\"single\"",
      new="identifier=\"FEEDBACK\" cardinality=\"multiple\"",
    )
    .replace_all(
      old="<qti-base-value base-type=\"identifier\">both</qti-base-value>",
      new="<qti-multiple><qti-base-value base-type=\"identifier\">both</qti-base-value><qti-base-value base-type=\"identifier\">extra</qti-base-value></qti-multiple>",
    )
    .replace_all(
      old="<qti-base-value base-type=\"identifier\">partial</qti-base-value>",
      new="<qti-multiple><qti-base-value base-type=\"identifier\">partial</qti-base-value></qti-multiple>",
    )
    .replace_all(
      old="<qti-base-value base-type=\"identifier\">retry</qti-base-value>",
      new="<qti-multiple><qti-base-value base-type=\"identifier\">retry</qti-base-value></qti-multiple>",
    )
  let item = @qti.compile_processed_item(xml)
  guard item.feedback_json("{\"LEFT\":2,\"RIGHT\":3}")
    is [{ "title": String("Combined"), .. }] else {
    fail("multiple identifier feedback not displayed")
  }
  let invalid = processed_fixture().replace_all(
    old="outcome-identifier=\"FEEDBACK\"",
    new="outcome-identifier=\"SCORE\"",
  )
  try @qti.compile_processed_item(invalid) catch {
    e => assert_eq(e.code(), "invalid_item")
  } noraise {
    _ => fail("numeric feedback outcome accepted")
  }
}

///|
test "typed static content escapes all occurrences and preserves explicit arbitrary response identifiers" {
  let xml = fixture("text")
    .replace_all(old="RESPONSE", new="WORD")
    .replace_all(
      old="<qti-item-body>",
      new="<qti-item-body><p>A &amp; B &amp; C &lt; D &lt; E</p>",
    )
    .replace_all(
      old="<qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/map_response.xml\"/>",
      new="<qti-response-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-map-response identifier=\"WORD\"/></qti-set-outcome-value></qti-response-processing>",
    )
  let item = @qti.compile_processed_item(xml)
  guard item.describe()
    is { "response_identifier": String("WORD"), "prompt": String(prompt), .. } else {
    fail("arbitrary response identifier missing")
  }
  assert_true(prompt.contains("A & B & C < D < E"))
  item.validate_json("{\"WORD\":\"test\"}")
}

///|
test "typed response containers and XML limits fail explicitly" {
  let program = @qti.compile_processing_program(
    processing_program_fixture(
      "<qti-response-declaration identifier=\"R\" cardinality=\"multiple\" base-type=\"string\"/>",
      "",
    ),
  )
  let too_many : Array[Json] = Array::make(4097, Json("x"))
  try program.evaluate_json({ "R": too_many }) catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("oversize container accepted")
  }
  try program.evaluate_json({ "R": [Json::null()] }) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("NULL member accepted")
  }
  try
    @qti.compile_processed_item(processed_fixture(), limits={
      max_characters: 100,
      max_depth: 128,
      max_elements: 30000,
    })
  catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("XML input limit ignored")
  }
}

///|
test "typed extended text accepts plain prose with pending manual review and authored feedback" {
  let item = @qti.compile_processed_item(fixture("extended-text"))
  let input = @fs.read_file_to_string("examples/extended-text-response.json")
  item.validate_json(input)
  guard item.describe()
    is { "external_scoring": True, "external_scored": String("human"), .. } else {
    fail("external scoring metadata missing")
  }
  assert_eq(item.outcomes_json(input), {
    "SCORE": Json::null(),
    "REVIEW": "pending",
  })
  guard item.feedback_json(input)
    is [
      {
        "identifier": String("pending"),
        "title": String("作答已提交"),
        ..
      },
    ] else {
    fail("pending review feedback missing")
  }
  guard item.describe()
    is {
      "response_identifier": String("REFLECTION"),
      "extended_text": {
        "format": String("plain"),
        "expected_lines": Number(6, ..),
        "expected_length": Number(240, ..),
        "min_strings": Number(1, ..),
        ..
      },
      ..
    } else {
    fail("extended text hints missing")
  }
  try item.validate_json("{}") catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("required extended text accepted NULL")
  }
  try item.score_json(input) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("pending manual review acquired a numeric score")
  }
}

///|
test "typed extended text preserves whitespace lines and exact authored scoring" {
  let item = @qti.compile_processed_item(fixture("extended-text-preformatted"))
  let input = @fs.read_file_to_string(
    "examples/extended-text-preformatted-response.json",
  )
  assert_eq(item.score_json(input).score, 1.0)
  assert_eq(
    item.score_json("{\"OUTLINE\":\"收集反馈 分析证据 调整教学\"}").score,
    0.0,
  )
  assert_eq(item.score_json("{}").status, Unanswered)
  guard item.describe()
    is { "extended_text": { "format": String("preformatted"), .. }, .. } else {
    fail("preformatted metadata missing")
  }
}

///|
test "typed extended text hint lengths do not truncate valid content" {
  let xml = fixture("extended-text")
    .replace_all(old="expected-length=\"240\"", new="expected-length=\"1\"")
    .replace_all(old="expected-lines=\"6\"", new="expected-lines=\"1\"")
  let item = @qti.compile_processed_item(xml)
  let response : Json = {
    "REFLECTION": "First line\nSecond line\nThird line & <text>",
  }
  item.validate_json(response.stringify())
  assert_eq(item.outcomes_json(response.stringify()), {
    "SCORE": Json::null(),
    "REVIEW": "pending",
  })
}

///|
test "typed extended text rejects unsupported rich text pattern masks containers and invalid minima" {
  for
    xml in [
      fixture("extended-text").replace_all(
        old="format=\"plain\"",
        new="format=\"xhtml\"",
      ),
      fixture("extended-text").replace_all(
        old="format=\"plain\"",
        new="pattern-mask=\"[A-Z]+\"",
      ),
      fixture("extended-text").replace_all(
        old="min-strings=\"1\"",
        new="min-strings=\"2\"",
      ),
      fixture("extended-text").replace_all(
        old="cardinality=\"single\" base-type=\"string\"",
        new="cardinality=\"multiple\" base-type=\"string\"",
      ),
      fixture("extended-text").replace_all(
        old="expected-lines=\"6\"",
        new="expected-lines=\"-1\"",
      ),
      fixture("extended-text").replace_all(
        old="<qti-prompt>",
        new="<qti-prompt><script>alert(1)</script>",
      ),
    ] {
    try @qti.compile_processed_item(xml) catch {
      _ => ()
    } noraise {
      _ => fail("invalid extended text accepted")
    }
  }
}

///|
test "typed composite supports extended text alongside numeric entry" {
  let xml = processed_fixture()
    .replace_all(
      old="identifier=\"LEFT\" cardinality=\"single\" base-type=\"float\"",
      new="identifier=\"LEFT\" cardinality=\"single\" base-type=\"string\"",
    )
    .replace_all(
      old="<qti-text-entry-interaction response-identifier=\"LEFT\"/>",
      new="<qti-extended-text-interaction response-identifier=\"LEFT\" expected-lines=\"4\"><qti-prompt>Explain your response</qti-prompt></qti-extended-text-interaction>",
    )
    .replace_all(
      old="<qti-equal><qti-variable identifier=\"LEFT\"/><qti-correct identifier=\"LEFT\"/></qti-equal>",
      new="<qti-match><qti-variable identifier=\"LEFT\"/><qti-correct identifier=\"LEFT\"/></qti-match>",
    )
    .replace_all(
      old="<qti-sum><qti-variable identifier=\"LEFT\"/><qti-variable identifier=\"RIGHT\"/></qti-sum>",
      new="<qti-variable identifier=\"RIGHT\"/>",
    )
  let item = @qti.compile_processed_item(xml)
  assert_eq(item.score_json("{\"LEFT\":\"2\",\"RIGHT\":3}").score, 3.0)
  guard item.describe()
    is {
      "responses": [
        { "extended_text": { "expected_lines": Number(4, ..), .. }, .. },
        _,
      ],
      ..
    } else {
    fail("composite extended text metadata missing")
  }
}

///|
test "typed processing rejects foreign expression namespaces and unexpected rule text" {
  let declaration = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>"
  for
    rules in [
      "<qti-set-outcome-value xmlns=\"urn:foreign\" identifier=\"SCORE\"><qti-base-value base-type=\"float\">1</qti-base-value></qti-set-outcome-value>",
      "<qti-set-outcome-value identifier=\"SCORE\"><qti-base-value xmlns=\"urn:foreign\" base-type=\"float\">1</qti-base-value></qti-set-outcome-value>",
      "<qti-response-condition><qti-response-if>ignored text<qti-base-value base-type=\"boolean\">true</qti-base-value><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">1</qti-base-value></qti-set-outcome-value></qti-response-if></qti-response-condition>",
    ] {
    try
      @qti.compile_processing_program(
        processing_program_fixture(declaration, rules),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("foreign or ignored processing content accepted")
    }
  }
}

///|
test "typed processing stops bounded evaluation before exposing partially assigned outcomes" {
  let declaration = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>"
  let operand = "<qti-base-value base-type=\"float\">1</qti-base-value>"
  let assignment = "<qti-set-outcome-value identifier=\"SCORE\"><qti-sum>\{Array::make(5, operand).join("")}</qti-sum></qti-set-outcome-value>"
  let xml = processing_program_fixture(
    declaration,
    Array::make(3000, assignment).join(""),
  )
  let program = @qti.compile_processing_program(xml, limits={
    max_characters: 2097152,
    max_depth: 128,
    max_elements: 30000,
  })
  try program.evaluate_json({}) catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("operation limit ignored")
  }
}

///|
test "typed external scoring metadata accepts only defined outcome vocabulary" {
  for value in ["true", "automatic", "manual", "false"] {
    let xml = fixture("extended-text").replace_all(
      old="external-scored=\"human\"",
      new="external-scored=\"\{value}\"",
    )
    try @qti.compile_processed_item(xml) catch {
      e => assert_eq(e.code(), "invalid_item")
    } noraise {
      _ => fail("invalid external scoring vocabulary accepted")
    }
  }
  let item = @qti.compile_processed_item(
    fixture("extended-text").replace_all(
      old="external-scored=\"human\"",
      new="external-scored=\"externalMachine\"",
    ),
  )
  guard item.describe()
    is {
      "external_scoring": True,
      "external_scored": String("externalMachine"),
      ..
    } else {
    fail("external machine scoring metadata missing")
  }
}

///|
test "typed composite metadata retains inline choice options and slider prompts" {
  let inline_item = @qti.compile_processed_item(fixture("composite-inline"))
  guard inline_item.describe() is { "responses": Array(responses), .. } else {
    fail("composite response metadata missing")
  }
  assert_true(
    responses.any(r => {
      r is { "inline_choice": { "choices": Array(choices), .. }, .. } &&
      !choices.is_empty()
    }),
  )
  let slider_item = @qti.compile_processed_item(fixture("composite-slider"))
  guard slider_item.describe() is { "responses": Array(responses), .. } else {
    fail("composite sliders missing")
  }
  for response in responses {
    if response is { "slider": { "prompt": String(prompt), .. }, .. } {
      assert_true(prompt != "")
    }
  }
}

///|
test "typed integer arithmetic keeps exact large remainders and cancelling sums" {
  let declarations = "<qti-response-declaration identifier=\"A\" cardinality=\"single\" base-type=\"integer\"/><qti-response-declaration identifier=\"B\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"DIV\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"MOD\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"SUM\" cardinality=\"single\" base-type=\"integer\"/>"
  let operands = "<qti-variable identifier=\"A\"/><qti-variable identifier=\"B\"/>"
  let rules = "<qti-set-outcome-value identifier=\"DIV\"><qti-integer-divide>\{operands}</qti-integer-divide></qti-set-outcome-value><qti-set-outcome-value identifier=\"MOD\"><qti-integer-modulus>\{operands}</qti-integer-modulus></qti-set-outcome-value><qti-set-outcome-value identifier=\"SUM\"><qti-sum><qti-base-value base-type=\"integer\">9007199254740991</qti-base-value><qti-base-value base-type=\"integer\">2</qti-base-value><qti-base-value base-type=\"integer\">-9007199254740991</qti-base-value></qti-sum></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  for
    (input, quotient, remainder) in [
      ("{\"A\":-9007199254740991,\"B\":3002399751580331}", -3.0, 2.0),
      ("{\"A\":9007199254740991,\"B\":-3002399751580331}", -3.0, -2.0),
      (
        "{\"A\":-9007199254740991,\"B\":-3002399751580331}", 2.0, -3002399751580329.0,
      ),
      (
        "{\"A\":9007199254740991,\"B\":3002399751580331}", 2.0, 3002399751580329.0,
      ),
    ] {
    assert_eq(
      program.evaluate_json(@json.parse(input, preserve_number_repr=true)),
      { "DIV": quotient, "MOD": remainder, "SUM": 2 },
    )
  }
  assert_eq(program.evaluate_json({ "A": 4, "B": 0 }), {
    "DIV": Json::null(),
    "MOD": Json::null(),
    "SUM": 2,
  })
}

///|
test "typed integer intermediate and public result range errors never round or wrap" {
  let declarations = "<qti-outcome-declaration identifier=\"RESULT\" cardinality=\"single\" base-type=\"integer\"/>"
  let maximum = "<qti-base-value base-type=\"integer\">9007199254740991</qti-base-value>"
  let literal_two = "<qti-base-value base-type=\"integer\">2</qti-base-value>"
  for
    expression in [
      "<qti-product>\{maximum}\{maximum}</qti-product>",
      "<qti-product>\{maximum}\{literal_two}</qti-product>",
      "<qti-sum>\{maximum}\{literal_two}</qti-sum>",
      "<qti-sum>\{Array::make(1025, maximum).join("")}</qti-sum>",
    ] {
    let rules = "<qti-set-outcome-value identifier=\"RESULT\">\{expression}</qti-set-outcome-value>"
    let program = @qti.compile_processing_program(
      processing_program_fixture(declarations, rules),
    )
    try program.evaluate_json({}) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("integer overflow rounded or wrapped instead of failing")
    }
  }
}

///|
test "typed external scoring allows omitted response processing without reporting a numeric grade" {
  for
    (default_value, expected) in [
      ("", 0.0),
      ("<qti-default-value><qti-value>2.5</qti-value></qti-default-value>", 2.5),
    ] {
    let xml = "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"manual_without_processing\" title=\"Manual response\"><qti-response-declaration identifier=\"TEXT\" cardinality=\"single\" base-type=\"string\"/><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\" external-scored=\"human\">\{default_value}</qti-outcome-declaration><qti-item-body><qti-extended-text-interaction response-identifier=\"TEXT\" expected-lines=\"4\"><qti-prompt>Explain your reasoning.</qti-prompt></qti-extended-text-interaction></qti-item-body></qti-assessment-item>"
    let item = @qti.compile_processed_item(xml)
    item.validate_json("{\"TEXT\":\"A reasoned response.\"}")
    assert_eq(item.outcomes_json("{\"TEXT\":\"A reasoned response.\"}"), {
      "SCORE": expected,
    })
    try item.score_json("{\"TEXT\":\"A reasoned response.\"}") catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("external default became a numeric grade")
    }
    try item.explain_json("{\"TEXT\":\"A reasoned response.\"}") catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("external default became a numeric explanation result")
    }
  }
}

///|
test "typed processing permits omitted test outcome processing and preserves authored defaults" {
  let xml = "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"defaults\" title=\"Defaults\"><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>9.5</qti-value></qti-default-value></qti-outcome-declaration><qti-outcome-declaration identifier=\"FORM\" cardinality=\"single\" base-type=\"identifier\"><qti-default-value><qti-value>version_one</qti-value></qti-default-value></qti-outcome-declaration></qti-assessment-test>"
  let program = @qti.compile_processing_program(xml)
  assert_eq(program.evaluate_json({ "items": [] }), {
    "SCORE": 9.5,
    "FORM": "version_one",
  })
}
