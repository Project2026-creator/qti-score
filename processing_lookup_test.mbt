///|
fn lookup_test_row(
  source : String,
  target : String,
  boundary? : String,
) -> String {
  let boundary_attribute = match boundary {
    Some(value) => " include-boundary=\"\{value}\""
    None => ""
  }
  "<qti-interpolation-table-entry source-value=\"\{source}\" target-value=\"\{target}\"\{boundary_attribute}/>"
}

///|
fn lookup_test_declaration(
  base : String,
  rows : String,
  fallback? : String,
  initial? : String,
  id~ : String = "TARGET",
) -> String {
  let default_attr = match fallback {
    Some(value) => " default-value=\"\{value}\""
    None => ""
  }
  let initial_value = match initial {
    Some(value) =>
      "<qti-default-value><qti-value>\{value}</qti-value></qti-default-value>"
    None => ""
  }
  "<qti-outcome-declaration identifier=\"\{id}\" cardinality=\"single\" base-type=\"\{base}\">\{initial_value}<qti-interpolation-table\{default_attr}>\{rows}</qti-interpolation-table></qti-outcome-declaration>"
}

///|
fn lookup_test_fixture(
  declaration : String,
  rules~ : String = "",
  source_base~ : String = "float",
) -> String {
  let operation = if rules == "" {
    "<qti-lookup-outcome-value identifier=\"TARGET\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>"
  } else {
    rules
  }
  processing_program_fixture(
    "<qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"\{source_base}\"/>" +
    declaration,
    operation,
  )
}

///|
fn lookup_test_reject(xml : String, code : String) -> Unit raise {
  try @qti.compile_processing_program(xml) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("invalid lookup program compiled")
  }
}

///|
test "lookup interpolation assigns scaled scores at authored thresholds without linear interpolation" {
  let rows = lookup_test_row("4", "100") +
    lookup_test_row("3", "75") +
    lookup_test_row("2", "50") +
    lookup_test_row("1", "25") +
    lookup_test_row("0", "0")
  let program = @qti.compile_processing_program(
    lookup_test_fixture(lookup_test_declaration("float", rows)),
  )
  assert_eq(program.evaluate_json({ "R": 4 }), { "TARGET": 100 })
  assert_eq(program.evaluate_json({ "R": 3.5 }), { "TARGET": 75 })
  assert_eq(program.evaluate_json({ "R": 2 }), { "TARGET": 50 })
  assert_eq(program.evaluate_json({ "R": 0 }), { "TARGET": 0 })
  assert_eq(program.evaluate_json({ "R": 1000 }), { "TARGET": 100 })
  assert_eq(program.evaluate_json({ "R": -1 }), { "TARGET": Json::null() })
  assert_eq(program.evaluate_json({}), { "TARGET": Json::null() })
}

///|
test "lookup honors open boundaries duplicate thresholds and document order" {
  let rows = lookup_test_row("80", "strict", boundary="false") +
    lookup_test_row("80", "inclusive") +
    lookup_test_row("0", "low")
  let program = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration("identifier", rows, fallback="missing"),
    ),
  )
  assert_eq(program.evaluate_json({ "R": 80.01 }), { "TARGET": "strict" })
  assert_eq(program.evaluate_json({ "R": 80 }), { "TARGET": "inclusive" })
  assert_eq(program.evaluate_json({ "R": 79.99 }), { "TARGET": "low" })
  let unsorted = lookup_test_row("0", "first") +
    lookup_test_row("100", "second")
  let program = @qti.compile_processing_program(
    lookup_test_fixture(lookup_test_declaration("identifier", unsorted)),
  )
  assert_eq(program.evaluate_json({ "R": 150 }), { "TARGET": "first" })
}

///|
test "lookup table fallback overwrites the outcome initial value for NULL and unmatched sources" {
  let declaration = lookup_test_declaration(
    "identifier",
    lookup_test_row("10", "matched"),
    fallback="fallback",
    initial="initial",
  )
  let program = @qti.compile_processing_program(
    lookup_test_fixture(declaration),
  )
  assert_eq(program.evaluate_json({ "R": 10 }), { "TARGET": "matched" })
  assert_eq(program.evaluate_json({ "R": -10 }), { "TARGET": "fallback" })
  assert_eq(program.evaluate_json({}), { "TARGET": "fallback" })
  let no_fallback = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration(
        "float",
        lookup_test_row("10", "100"),
        initial="999",
      ),
    ),
  )
  assert_eq(no_fallback.evaluate_json({}), { "TARGET": Json::null() })
  assert_eq(no_fallback.evaluate_json({ "R": -1 }), { "TARGET": Json::null() })
}

///|
test "lookup parses target and fallback values using the declared scalar type" {
  let integer = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration(
        "integer",
        lookup_test_row("0", "12"),
        fallback="-3",
      ),
      source_base="integer",
    ),
  )
  assert_eq(integer.evaluate_json({ "R": 2 }), { "TARGET": 12 })
  assert_eq(integer.evaluate_json({}), { "TARGET": -3 })
  let boolean = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration(
        "boolean",
        lookup_test_row("0", "1"),
        fallback="0",
      ),
    ),
  )
  assert_eq(boolean.evaluate_json({ "R": 2 }), { "TARGET": true })
  assert_eq(boolean.evaluate_json({ "R": -1 }), { "TARGET": false })
  let text = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration(
        "string",
        lookup_test_row("0", " a &amp; b "),
        fallback="",
      ),
    ),
  )
  assert_eq(text.evaluate_json({ "R": 0 }), { "TARGET": " a & b " })
  assert_eq(text.evaluate_json({}), { "TARGET": Json::null() })
  let pair = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration("directedPair", lookup_test_row("0", " A   B ")),
    ),
  )
  assert_eq(pair.evaluate_json({ "R": 0 }), { "TARGET": "A B" })
}

///|
test "lookup rule executes sequentially in conditions and can read its previous target value" {
  let declaration = lookup_test_declaration(
      "float",
      lookup_test_row("7", "100") + lookup_test_row("0", "50"),
      initial="7",
    ) +
    "<qti-outcome-declaration identifier=\"COPY\" cardinality=\"single\" base-type=\"float\"/>"
  let rules = "<qti-response-condition><qti-response-if><qti-base-value base-type=\"boolean\">true</qti-base-value><qti-lookup-outcome-value identifier=\"TARGET\"><qti-variable identifier=\"TARGET\"/></qti-lookup-outcome-value></qti-response-if></qti-response-condition><qti-set-outcome-value identifier=\"COPY\"><qti-variable identifier=\"TARGET\"/></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    lookup_test_fixture(declaration, rules~),
  )
  assert_eq(program.evaluate_json({}), { "TARGET": 100, "COPY": 100 })
  assert_eq(program.evaluate_json({}), { "TARGET": 100, "COPY": 100 })
}

///|
test "lookup test outcome rules consume item aggregates and publish multiple typed results" {
  let declarations = "<qti-outcome-declaration identifier=\"RAW\" cardinality=\"single\" base-type=\"float\"/>" +
    lookup_test_declaration(
      "float",
      lookup_test_row("4", "100") + lookup_test_row("0", "0"),
      id="PERCENT",
    ) +
    lookup_test_declaration(
      "identifier",
      lookup_test_row("3", "mastered") +
      lookup_test_row("1", "developing") +
      lookup_test_row("0", "review"),
      fallback="pending",
      id="LEVEL",
    )
  let rules = "<qti-set-outcome-value identifier=\"RAW\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum></qti-set-outcome-value><qti-lookup-outcome-value identifier=\"PERCENT\"><qti-variable identifier=\"RAW\"/></qti-lookup-outcome-value><qti-lookup-outcome-value identifier=\"LEVEL\"><qti-variable identifier=\"RAW\"/></qti-lookup-outcome-value>"
  let xml = "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"lookup\" title=\"Lookup\">\{declarations}<qti-outcome-processing>\{rules}</qti-outcome-processing></qti-assessment-test>"
  let program = @qti.compile_processing_program(xml)
  assert_eq(
    program.evaluate_json({
      "items": [
        { "identifier": "A", "outcomes": { "SCORE": 3 } },
        { "identifier": "B", "outcomes": { "SCORE": 1 } },
      ],
    }),
    { "RAW": 4, "PERCENT": 100, "LEVEL": "mastered" },
  )
  assert_eq(program.evaluate_json({ "items": [] }), {
    "RAW": Json::null(),
    "PERCENT": Json::null(),
    "LEVEL": "pending",
  })
  assert_true(!program.describe().stringify().contains("mastered"))
  assert_true(!program.describe().stringify().contains("interpolation"))
}

///|
test "lookup rules integrate item scoring and feedback while metadata omits tables" {
  let declarations = "<qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"float\"/>" +
    lookup_test_declaration(
      "float",
      lookup_test_row("3", "100") + lookup_test_row("0", "0"),
      id="SCORE",
    ) +
    lookup_test_declaration(
      "identifier",
      lookup_test_row("3", "success") + lookup_test_row("0", "retry"),
      id="LEVEL",
    )
  let rules = "<qti-lookup-outcome-value identifier=\"SCORE\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value><qti-lookup-outcome-value identifier=\"LEVEL\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>"
  let xml = "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"lookup_item\" title=\"Lookup item\" adaptive=\"false\" time-dependent=\"false\">\{declarations}<qti-item-body><p>Value <qti-text-entry-interaction response-identifier=\"R\"/></p></qti-item-body><qti-response-processing>\{rules}</qti-response-processing><qti-modal-feedback outcome-identifier=\"LEVEL\" identifier=\"success\" show-hide=\"show\"><qti-content-body><p>Threshold reached.</p></qti-content-body></qti-modal-feedback></qti-assessment-item>"
  let item = @qti.compile_processed_item(xml)
  assert_eq(item.score_json("{\"R\":3}").score, 100.0)
  assert_eq(item.outcomes_json("{}"), {
    "SCORE": Json::null(),
    "LEVEL": Json::null(),
  })
  assert_true(
    item.feedback_json("{\"R\":3}") is [{ "identifier": String("success"), .. }],
  )
  assert_true(
    item.explain_json("{\"R\":3}").steps.any(step => {
      step.operation == "lookup_outcome_value"
    }),
  )
  assert_true(!item.describe().stringify().contains("success"))
  assert_true(!item.describe().stringify().contains("target-value"))
  assert_eq(
    @qti.compile_assessment_item(xml).score_json("{\"R\":3}").score,
    100.0,
  )
}

///|
test "lookup rejects missing tables response assignment and nonnumeric or container sources" {
  let declaration = lookup_test_declaration("float", lookup_test_row("0", "1"))
  for
    expression in [
      "<qti-base-value base-type=\"boolean\">true</qti-base-value>", "<qti-base-value base-type=\"string\">3</qti-base-value>",
      "<qti-multiple><qti-base-value base-type=\"integer\">3</qti-base-value></qti-multiple>",
      "<qti-ordered><qti-base-value base-type=\"float\">3</qti-base-value></qti-ordered>",
    ] {
    lookup_test_reject(
      lookup_test_fixture(
        declaration,
        rules="<qti-lookup-outcome-value identifier=\"TARGET\">\{expression}</qti-lookup-outcome-value>",
      ),
      "invalid_item",
    )
  }
  lookup_test_reject(
    lookup_test_fixture(
      "<qti-outcome-declaration identifier=\"TARGET\" cardinality=\"single\" base-type=\"float\"/>",
    ),
    "invalid_item",
  )
  lookup_test_reject(
    lookup_test_fixture(
      declaration,
      rules="<qti-lookup-outcome-value identifier=\"R\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>",
    ),
    "invalid_item",
  )
  lookup_test_reject(
    lookup_test_fixture(
      declaration,
      rules="<qti-lookup-outcome-value identifier=\"MISSING\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>",
    ),
    "invalid_item",
  )
}

///|
test "lookup rejects expression nesting and incorrect operand counts" {
  let declaration = lookup_test_declaration("float", lookup_test_row("0", "1"))
  lookup_test_reject(
    lookup_test_fixture(
      declaration,
      rules="<qti-set-outcome-value identifier=\"TARGET\"><qti-lookup-outcome-value identifier=\"TARGET\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value></qti-set-outcome-value>",
    ),
    "unsupported",
  )
  for children in ["", "<qti-null/><qti-null/>", "text<qti-null/>"] {
    lookup_test_reject(
      lookup_test_fixture(
        declaration,
        rules="<qti-lookup-outcome-value identifier=\"TARGET\">\{children}</qti-lookup-outcome-value>",
      ),
      "invalid_item",
    )
  }
}

///|
test "lookup rejects invalid target lexemes nonfinite numbers and malformed table shapes" {
  for
    declaration in [
      lookup_test_declaration("integer", lookup_test_row("0", "1.5")),
      lookup_test_declaration("boolean", lookup_test_row("0", "yes")),
      lookup_test_declaration(
        "identifier",
        lookup_test_row("0", "bad identifier"),
      ),
      lookup_test_declaration("directedPair", lookup_test_row("0", "A")),
      lookup_test_declaration(
        "float",
        lookup_test_row("0", "1"),
        fallback="NaN",
      ),
      lookup_test_declaration("float", lookup_test_row("INF", "1")),
      lookup_test_declaration("float", lookup_test_row("NaN", "1")),
      lookup_test_declaration("float", ""),
      lookup_test_declaration(
        "float",
        lookup_test_row("0", "1", boundary="yes"),
      ),
      lookup_test_declaration("float", lookup_test_row("0", "1")).replace_all(
        old="cardinality=\"single\"",
        new="cardinality=\"multiple\"",
      ),
      "<qti-outcome-declaration identifier=\"TARGET\" cardinality=\"single\" base-type=\"float\"><qti-interpolation-table><qti-interpolation-table-entry source-value=\"0\" target-value=\"1\"/></qti-interpolation-table><qti-default-value><qti-value>3</qti-value></qti-default-value></qti-outcome-declaration>",
    ] {
    lookup_test_reject(lookup_test_fixture(declaration), "invalid_item")
  }
}

///|
test "lookup keeps match tables unsupported and rejects duplicate lookup declarations" {
  let interpolation = "<qti-interpolation-table>" +
    lookup_test_row("0", "1") +
    "</qti-interpolation-table>"
  let match_table = "<qti-match-table><qti-match-table-entry source-value=\"0\" target-value=\"float\"/></qti-match-table>"
  let wrapper = "<qti-outcome-declaration identifier=\"TARGET\" cardinality=\"single\" base-type=\"identifier\">"
  lookup_test_reject(
    lookup_test_fixture(wrapper + match_table + "</qti-outcome-declaration>"),
    "unsupported",
  )
  lookup_test_reject(
    lookup_test_fixture(
      wrapper + interpolation + interpolation + "</qti-outcome-declaration>",
    ),
    "invalid_item",
  )
  lookup_test_reject(
    lookup_test_fixture(
      wrapper + interpolation + match_table + "</qti-outcome-declaration>",
    ),
    "invalid_item",
  )
}

///|
test "lookup bounds each table total declarations and runtime scan work" {
  let rows = StringBuilder()
  for _ in 0..<1024 {
    rows.write_string(lookup_test_row("1000", "1"))
  }
  let thousand = rows.to_string()
  lookup_test_reject(
    lookup_test_fixture(
      lookup_test_declaration("float", thousand + lookup_test_row("1000", "1")),
    ),
    "limit_exceeded",
  )
  let declarations = StringBuilder()
  for i in 0..<9 {
    declarations.write_string(
      lookup_test_declaration("float", thousand, id="T\{i}"),
    )
  }
  lookup_test_reject(
    lookup_test_fixture(
      declarations.to_string(),
      rules="<qti-lookup-outcome-value identifier=\"T0\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>",
    ),
    "limit_exceeded",
  )
  let rules = StringBuilder()
  for _ in 0..<17 {
    rules.write_string(
      "<qti-lookup-outcome-value identifier=\"TARGET\"><qti-variable identifier=\"R\"/></qti-lookup-outcome-value>",
    )
  }
  let program = @qti.compile_processing_program(
    lookup_test_fixture(
      lookup_test_declaration("float", thousand),
      rules=rules.to_string(),
    ),
  )
  try program.evaluate_json({ "R": 0 }) catch {
    @qti.LimitExceeded(_) => ()
    _ => fail("lookup scan work returned the wrong error")
  } noraise {
    _ => fail("unbounded lookup scan work succeeded")
  }
}
