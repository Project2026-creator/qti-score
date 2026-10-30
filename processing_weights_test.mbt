///|
fn processing_weight_fixture(declarations : String, rules : String) -> String {
  "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"weighted\" title=\"Weighted outcomes\">\{declarations}<qti-outcome-processing>\{rules}</qti-outcome-processing></qti-assessment-test>"
}

///|
fn processing_weight_declaration(base~ : String = "float") -> String {
  "<qti-outcome-declaration identifier=\"TOTAL\" cardinality=\"single\" base-type=\"\{base}\"/>"
}

///|
fn processing_weight_schemas() -> Json {
  [
    {
      "identifier": "A",
      "outcome_types": {
        "SCORE": { "base_type": "integer", "cardinality": "single" },
        "NOTE": { "base_type": "string", "cardinality": "single" },
        "BAG": { "base_type": "integer", "cardinality": "multiple" },
      },
      "response_types": {
        "ANSWER": { "base_type": "integer", "cardinality": "single" },
      },
      "categories": ["math", "core"],
      "section_identifiers": ["ROOT", "INNER"],
    },
    {
      "identifier": "B",
      "outcome_types": {
        "SCORE": { "base_type": "float", "cardinality": "single" },
      },
      "categories": ["math"],
      "section_identifiers": ["ROOT"],
    },
    {
      "identifier": "C",
      "outcome_types": {
        "SCORE": { "base_type": "integer", "cardinality": "single" },
      },
      "categories": ["math", "exclude"],
      "section_identifiers": ["ROOT", "INNER"],
    },
    {
      "identifier": "D",
      "outcome_types": {
        "NOTE": { "base_type": "string", "cardinality": "single" },
      },
      "categories": ["essay"],
      "section_identifiers": ["OTHER"],
    },
  ]
}

///|
fn processing_weight_items() -> Json {
  {
    "items": [
      {
        "identifier": "A",
        "outcomes": { "SCORE": 2, "NOTE": "review", "BAG": [1, 2] },
        "response": { "ANSWER": 4 },
        "submitted": true,
        "weights": { "W": 2.5 },
        "categories": ["math", "core"],
        "section_identifiers": ["ROOT", "INNER"],
      },
      {
        "identifier": "B",
        "outcomes": { "SCORE": 3.5 },
        "weights": { "W": -2 },
        "categories": ["math"],
        "section_identifiers": ["ROOT"],
      },
      {
        "identifier": "C",
        "outcomes": { "SCORE": 9 },
        "categories": ["math", "exclude"],
        "section_identifiers": ["ROOT", "INNER"],
      },
      {
        "identifier": "D",
        "outcomes": { "NOTE": "draft" },
        "categories": ["essay"],
        "section_identifiers": ["OTHER"],
      },
    ],
  }
}

///|
test "weighted variable references use typed item declarations and float promotion" {
  let xml = processing_weight_fixture(
    processing_weight_declaration(),
    "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-variable identifier=\"A.SCORE\" weight-identifier=\"W\"/><qti-variable identifier=\"B.SCORE\" weight-identifier=\"W\"/><qti-variable identifier=\"C.SCORE\" weight-identifier=\"W\"/></qti-sum></qti-set-outcome-value>",
  )
  let program = @qti.compile_processing_program(
    xml,
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), { "TOTAL": 7 })
  assert_eq(program.evaluate_json({ "items": [] }), { "TOTAL": Json::null() })
}

///|
test "weighted variables ignore nonnumeric variables and apply weights to numeric containers" {
  let declarations = processing_weight_declaration() +
    "<qti-outcome-declaration identifier=\"TEXT\" cardinality=\"single\" base-type=\"string\"/>"
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-variable identifier=\"A.BAG\" weight-identifier=\"W\"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"TEXT\"><qti-variable identifier=\"A.NOTE\" weight-identifier=\"W\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(declarations, rules),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), {
    "TOTAL": 7.5,
    "TEXT": "review",
  })
}

///|
test "weighted test variables filter by ancestor section and category sets before aggregation" {
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" section-identifier=\"ROOT\" include-category=\"science math\" exclude-category=\"exclude hidden\" weight-identifier=\"W\"/></qti-sum></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(processing_weight_declaration(), rules),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), { "TOTAL": -2 })
  let inner = rules.replace_all(
    old="section-identifier=\"ROOT\"",
    new="section-identifier=\"INNER\"",
  )
  let program = @qti.compile_processing_program(
    processing_weight_fixture(processing_weight_declaration(), inner),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), { "TOTAL": 5 })
}

///|
test "weighted test variables explicit base type matches declarations without numeric coercion" {
  let xml = processing_weight_fixture(
    processing_weight_declaration(),
    "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum></qti-set-outcome-value>",
  )
  let program = @qti.compile_processing_program(
    xml,
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), { "TOTAL": 3.5 })
  let int_xml = xml.replace_all(
    old="base-type=\"float\"",
    new="base-type=\"integer\"",
  )
  let integers = @qti.compile_processing_program(
    int_xml,
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(integers.evaluate_json(processing_weight_items()), { "TOTAL": 11 })
}

///|
test "weighted omitted base type accepts numeric singles and ignores missing null and container values" {
  let declarations = processing_weight_declaration() +
    "<qti-outcome-declaration identifier=\"COUNT\" cardinality=\"single\" base-type=\"integer\"/>"
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"COUNT\"><qti-container-size><qti-test-variables variable-identifier=\"BAG\" base-type=\"integer\"/></qti-container-size></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(declarations, rules),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), {
    "TOTAL": 14.5,
    "COUNT": 0,
  })
  assert_eq(
    program.evaluate_json({
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": Json::null() } },
        { "identifier": "D", "outcomes": { "NOTE": "not numeric" } },
      ],
    }),
    { "TOTAL": Json::null(), "COUNT": 0 },
  )
}

///|
test "weighted omitted base type retains exact integer arithmetic when float items are absent" {
  let schemas : Json = [
    {
      "identifier": "A",
      "outcome_types": {
        "SCORE": { "base_type": "integer", "cardinality": "single" },
      },
    },
    {
      "identifier": "B",
      "outcome_types": {
        "SCORE": { "base_type": "float", "cardinality": "single" },
      },
    },
    {
      "identifier": "C",
      "outcome_types": {
        "SCORE": { "base_type": "integer", "cardinality": "single" },
      },
    },
    {
      "identifier": "D",
      "outcome_types": {
        "SCORE": { "base_type": "integer", "cardinality": "single" },
      },
    },
  ]
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum></qti-set-outcome-value>",
    ),
    item_declarations=schemas,
  )
  assert_eq(
    program.evaluate_json({
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 9007199254740991.0 } },
        { "identifier": "B", "outcomes": { "SCORE": Json::null() } },
        { "identifier": "C", "outcomes": { "SCORE": 2 } },
        { "identifier": "D", "outcomes": { "SCORE": -9007199254740991.0 } },
      ],
    }),
    { "TOTAL": 2 },
  )
}

///|
test "weighted item response references use only last submitted response values" {
  let xml = processing_weight_fixture(
    processing_weight_declaration(base="integer"),
    "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.ANSWER\"/></qti-set-outcome-value>",
  )
  let program = @qti.compile_processing_program(
    xml,
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(program.evaluate_json(processing_weight_items()), { "TOTAL": 4 })
  assert_eq(
    program.evaluate_json({
      "items": [
        {
          "identifier": "A",
          "outcomes": {},
          "response": { "ANSWER": "4" },
          "submitted": true,
        },
      ],
    }),
    { "TOTAL": 4 },
  )
  assert_eq(
    program.evaluate_json({
      "items": [
        {
          "identifier": "A",
          "outcomes": {},
          "response": { "ANSWER": 99 },
          "submitted": false,
        },
      ],
    }),
    { "TOTAL": Json::null() },
  )
  assert_eq(
    program.evaluate_json({
      "items": [{ "identifier": "A", "outcomes": {}, "submitted": true }],
    }),
    { "TOTAL": Json::null() },
  )
}

///|
test "weighted repeated item references distinguish source instance from global sequence" {
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.2.SCORE\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      rules,
    ),
    item_declarations=processing_weight_schemas(),
  )
  let items : Json = {
    "items": [
      {
        "identifier": "A",
        "instance_identifier": "A-copy-1",
        "instance_index": 1,
        "sequence_index": 2,
        "submission_mode": "individual",
        "submitted": true,
        "outcomes": { "SCORE": 7 },
      },
      {
        "identifier": "A",
        "instance_identifier": "A-copy-2",
        "instance_index": 2,
        "sequence_index": 5,
        "submission_mode": "individual",
        "submitted": true,
        "outcomes": { "SCORE": 3 },
      },
    ],
  }
  assert_eq(program.evaluate_json(items), { "TOTAL": 3 })
  let ambiguous = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      rules.replace_all(old="A.2.SCORE", new="A.SCORE"),
    ),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(ambiguous.evaluate_json(items), { "TOTAL": Json::null() })
  let missing = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      rules.replace_all(old="A.2.SCORE", new="A.3.SCORE"),
    ),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(missing.evaluate_json(items), { "TOTAL": Json::null() })
}

///|
test "weighted simultaneous repeated reference chooses last submission with stable tie order" {
  let xml = processing_weight_fixture(
    processing_weight_declaration(base="integer"),
    "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.SCORE\"/></qti-set-outcome-value>",
  )
  let program = @qti.compile_processing_program(
    xml,
    item_declarations=processing_weight_schemas(),
  )
  let items : Json = {
    "items": [
      {
        "identifier": "A",
        "instance_index": 1,
        "submission_mode": "simultaneous",
        "submission_index": 3,
        "submitted": true,
        "outcomes": { "SCORE": 8 },
      },
      {
        "identifier": "A",
        "instance_index": 2,
        "submission_mode": "simultaneous",
        "submission_index": 1,
        "submitted": true,
        "outcomes": { "SCORE": 2 },
      },
      {
        "identifier": "A",
        "instance_index": 3,
        "submission_mode": "simultaneous",
        "submission_index": 4,
        "submitted": false,
        "outcomes": { "SCORE": 99 },
      },
    ],
  }
  assert_eq(program.evaluate_json(items), { "TOTAL": 8 })
}

///|
test "weighted test variables include every selected source instance" {
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" weight-identifier=\"W\"/></qti-sum></qti-set-outcome-value>",
    ),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(
    program.evaluate_json({
      "items": [
        {
          "identifier": "A",
          "instance_index": 1,
          "outcomes": { "SCORE": 2 },
          "weights": { "W": 0 },
        },
        { "identifier": "A", "instance_index": 2, "outcomes": { "SCORE": 3 } },
      ],
    }),
    { "TOTAL": 3 },
  )
}

///|
test "weighted invalid references and undefined weight combinations fail at compile time" {
  for
    expression in [
      "<qti-variable identifier=\"UNKNOWN.SCORE\"/>", "<qti-variable identifier=\"A.MISSING\"/>",
      "<qti-variable identifier=\"A.0.SCORE\"/>", "<qti-variable identifier=\"A.01.SCORE\"/>",
      "<qti-variable identifier=\"TOTAL\" weight-identifier=\"W\"/>", "<qti-test-variables variable-identifier=\"SCORE\" base-type=\"integer\" weight-identifier=\"W\"/>",
      "<qti-test-variables variable-identifier=\"NOTE\" base-type=\"string\" weight-identifier=\"W\"/>",
      "<qti-test-variables variable-identifier=\"A.SCORE\" base-type=\"float\"/>",
    ] {
    try
      @qti.compile_processing_program(
        processing_weight_fixture(
          processing_weight_declaration(),
          "<qti-set-outcome-value identifier=\"TOTAL\">\{expression}</qti-set-outcome-value>",
        ),
        item_declarations=processing_weight_schemas(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid weighted expression accepted")
    }
  }
}

///|
test "weighted values reject malformed runtime metadata and numeric strings" {
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.SCORE\" weight-identifier=\"W\"/></qti-set-outcome-value>",
    ),
    item_declarations=processing_weight_schemas(),
  )
  let inputs : Array[Json] = [
    { "items": [{ "identifier": "A", "outcomes": { "SCORE": "2" } }] },
    {
      "items": [
        {
          "identifier": "A",
          "outcomes": { "SCORE": 2 },
          "weights": { "W": "2" },
        },
      ],
    },
    {
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 2 }, "instance_index": 0 },
      ],
    },
    {
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 2 }, "submitted": "yes" },
      ],
    },
    {
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 2 } },
        { "identifier": "A", "outcomes": { "SCORE": 3 } },
      ],
    },
  ]
  for input in inputs {
    try program.evaluate_json(input) catch {
      _ => ()
    } noraise {
      _ => fail("invalid processing environment accepted")
    }
  }
}

///|
test "weighted test references do not reinterpret dotted local item response names" {
  let xml = processing_program_fixture(
    "<qti-response-declaration identifier=\"R.VALUE\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"integer\"/>",
    "<qti-set-outcome-value identifier=\"SCORE\"><qti-variable identifier=\"R.VALUE\"/></qti-set-outcome-value>",
  )
  let item_program = @qti.compile_processing_program(xml)
  assert_eq(item_program.evaluate_json({ "R.VALUE": 6 }), { "SCORE": 6 })
  let test_xml = processing_weight_fixture(
    "<qti-outcome-declaration identifier=\"R.VALUE\" cardinality=\"single\" base-type=\"integer\"/>",
    "",
  )
  let local_program = @qti.compile_processing_program(
    test_xml,
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(local_program.evaluate_json({ "items": [] }), { "R.VALUE": 0 })
  let ambiguous = processing_weight_fixture(
    "<qti-outcome-declaration identifier=\"A.SCORE\" cardinality=\"single\" base-type=\"integer\"/><qti-outcome-declaration identifier=\"TOTAL\" cardinality=\"single\" base-type=\"integer\"/>",
    "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.SCORE\"/></qti-set-outcome-value>",
  )
  try
    @qti.compile_processing_program(
      ambiguous,
      item_declarations=processing_weight_schemas(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("ambiguous dotted test reference accepted")
  }
}

///|
test "weighted dotted source and variable names resolve by registered declarations" {
  let schemas : Json = [
    {
      "identifier": "SECTION.A",
      "outcome_types": {
        "R.VALUE": { "base_type": "integer", "cardinality": "single" },
      },
    },
  ]
  let direct = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"SECTION.A.R.VALUE\"/></qti-set-outcome-value>",
    ),
    item_declarations=schemas,
  )
  let input : Json = {
    "items": [{ "identifier": "SECTION.A", "outcomes": { "R.VALUE": 4 } }],
  }
  assert_eq(direct.evaluate_json(input), { "TOTAL": 4 })
  let gather = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"R.VALUE\" base-type=\"integer\"/></qti-sum></qti-set-outcome-value>",
    ),
    item_declarations=schemas,
  )
  assert_eq(gather.evaluate_json(input), { "TOTAL": 4 })
  let ambiguous_schemas : Json = [
    {
      "identifier": "A",
      "outcome_types": {
        "R.VALUE": { "base_type": "integer", "cardinality": "single" },
      },
    },
    {
      "identifier": "A.R",
      "outcome_types": {
        "VALUE": { "base_type": "integer", "cardinality": "single" },
      },
    },
  ]
  try
    @qti.compile_processing_program(
      processing_weight_fixture(
        processing_weight_declaration(base="integer"),
        "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"A.R.VALUE\"/></qti-set-outcome-value>",
      ),
      item_declarations=ambiguous_schemas,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("ambiguous dotted source reference accepted")
  }
}

///|
test "weighted test variable response lookup excludes unsubmitted drafts and supports nonnumeric filters" {
  let declarations = processing_weight_declaration(base="integer") +
    "<qti-outcome-declaration identifier=\"NOTES\" cardinality=\"multiple\" base-type=\"string\"/>"
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"ANSWER\" base-type=\"integer\"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"NOTES\"><qti-test-variables variable-identifier=\"NOTE\" base-type=\"string\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(declarations, rules),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(
    program.evaluate_json({
      "items": [
        {
          "identifier": "A",
          "outcomes": { "NOTE": "review" },
          "response": { "ANSWER": "4" },
          "submitted": false,
        },
        {
          "identifier": "D",
          "outcomes": { "NOTE": "draft" },
          "submitted": true,
        },
      ],
    }),
    { "TOTAL": Json::null(), "NOTES": ["review", "draft"] },
  )
}

///|
test "weighted selectors use compiled section and category metadata" {
  let rules = "<qti-set-outcome-value identifier=\"TOTAL\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"integer\" section-identifier=\"INNER\" include-category=\"core\"/></qti-sum></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(base="integer"),
      rules,
    ),
    item_declarations=processing_weight_schemas(),
  )
  assert_eq(
    program.evaluate_json({
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 2 } },
        {
          "identifier": "C",
          "outcomes": { "SCORE": 9 },
          "categories": ["core"],
        },
      ],
    }),
    { "TOTAL": 2 },
  )
}

///|
test "weighted processing rejects nonfinite products and oversized instance metadata" {
  let program = @qti.compile_processing_program(
    processing_weight_fixture(
      processing_weight_declaration(),
      "<qti-set-outcome-value identifier=\"TOTAL\"><qti-variable identifier=\"B.SCORE\" weight-identifier=\"W\"/></qti-set-outcome-value>",
    ),
    item_declarations=processing_weight_schemas(),
  )
  let inputs : Array[Json] = [
    {
      "items": [
        {
          "identifier": "B",
          "outcomes": { "SCORE": 1.0e308 },
          "weights": { "W": 1.0e308 },
        },
      ],
    },
    {
      "items": [
        {
          "identifier": "B",
          "outcomes": { "SCORE": 2 },
          "instance_index": 9007199254740991.0,
        },
      ],
    },
    {
      "items": [
        {
          "identifier": "B",
          "outcomes": { "SCORE": 2 },
          "submission_index": 9007199254740991.0,
        },
      ],
    },
  ]
  for input in inputs {
    try program.evaluate_json(input) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe weighted environment accepted")
    }
  }
}
