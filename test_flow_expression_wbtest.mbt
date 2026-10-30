///|
fn flow_expression_fixture(
  expression : String,
  declarations~ : String = "",
  branch~ : Bool = false,
) -> (Node, Node) raise QtiError {
  let name = if branch {
    "qti-branch-rule target=\"NEXT\""
  } else {
    "qti-pre-condition"
  }
  let close = if branch { "qti-branch-rule" } else { "qti-pre-condition" }
  let root = parse_document(
    "<qti-assessment-test xmlns=\"\{qti_namespace}\" identifier=\"flow\" title=\"Flow\">\{declarations}<qti-test-part identifier=\"P\" navigation-mode=\"linear\" submission-mode=\"individual\"><\{name}>\{expression}</\{close}></qti-test-part></qti-assessment-test>",
    Limits::default(),
  )
  (root.children[root.children.length() - 1].children[0], root)
}

///|
fn flow_expression_schemas() -> Json {
  [
    {
      "identifier": "Q",
      "outcome_types": {
        "SCORE": { "base_type": "float", "cardinality": "single" },
      },
      "response_types": {
        "ANSWER": { "base_type": "identifier", "cardinality": "single" },
      },
    },
  ]
}

///|
test "flow expression reads current outcomes without executing or resetting processing" {
  let declarations = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>0</qti-value></qti-default-value></qti-outcome-declaration>"
  let (node, root) = flow_expression_fixture(
    "<qti-gte><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">5</qti-base-value></qti-gte>",
    declarations~,
  )
  let predicate = test_flow_predicate(node, root)
  assert_true(predicate.evaluate({ "items": [] }, { "SCORE": 7 }))
  assert_true(!predicate.evaluate({ "items": [] }, { "SCORE": 0 }))
  assert_true(!predicate.evaluate({ "items": [] }, { "SCORE": Json::null() }))
  assert_true(!predicate.evaluate({ "items": [] }, {}))
  root.children.push(
    parse_document(
      "<qti-outcome-processing xmlns=\"\{qti_namespace}\"><qti-set-outcome-value identifier=\"SCORE\"><qti-divide><qti-base-value base-type=\"float\">1.0e308</qti-base-value><qti-base-value base-type=\"float\">1.0e-308</qti-base-value></qti-divide></qti-set-outcome-value></qti-outcome-processing>",
      Limits::default(),
    ),
  )
  let predicate = test_flow_predicate(node, root)
  assert_true(predicate.evaluate({ "items": [] }, { "SCORE": 8 }))
}

///|
test "flow expression initializes authored defaults separately from live outcomes" {
  let declarations = "<qti-outcome-declaration identifier=\"LEVEL\" cardinality=\"single\" base-type=\"integer\"><qti-default-value><qti-value>4</qti-value></qti-default-value></qti-outcome-declaration><qti-outcome-declaration identifier=\"TOTAL\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"FLAG\" cardinality=\"single\" base-type=\"boolean\"/>"
  let (node, root) = flow_expression_fixture(
    "<qti-match><qti-variable identifier=\"LEVEL\"/><qti-base-value base-type=\"integer\">4</qti-base-value></qti-match>",
    declarations~,
  )
  let predicate = test_flow_predicate(node, root)
  let initial = predicate.program.initial_outcomes()
  assert_eq(initial, { "LEVEL": 4, "TOTAL": 0, "FLAG": Json::null() })
  assert_true(predicate.evaluate({ "items": [] }, initial))
  assert_true(!predicate.evaluate({ "items": [] }, {}))
}

///|
test "flow expression combines item outcomes with last submitted responses" {
  let (node, root) = flow_expression_fixture(
    "<qti-and><qti-gte><qti-variable identifier=\"Q.SCORE\"/><qti-base-value base-type=\"float\">1</qti-base-value></qti-gte><qti-match><qti-variable identifier=\"Q.ANSWER\"/><qti-base-value base-type=\"identifier\">A</qti-base-value></qti-match></qti-and>",
    branch=true,
  )
  let predicate = test_flow_predicate(
    node,
    root,
    item_declarations=flow_expression_schemas(),
  )
  let submitted : Json = {
    "items": [
      {
        "identifier": "Q",
        "submitted": true,
        "outcomes": { "SCORE": 2 },
        "response": { "ANSWER": "A" },
      },
    ],
  }
  assert_true(predicate.evaluate(submitted, {}))
  assert_true(
    !predicate.evaluate(
      {
        "items": [
          {
            "identifier": "Q",
            "submitted": false,
            "outcomes": { "SCORE": 2 },
            "response": { "ANSWER": "A" },
          },
        ],
      },
      {},
    ),
  )
  assert_true(!predicate.evaluate({ "items": [] }, {}))
  assert_eq(submitted, {
    "items": [
      {
        "identifier": "Q",
        "submitted": true,
        "outcomes": { "SCORE": 2 },
        "response": { "ANSWER": "A" },
      },
    ],
  })
}

///|
test "flow expression resolves explicit source instances independently of global position" {
  let (node, root) = flow_expression_fixture(
    "<qti-equal><qti-variable identifier=\"Q.2.SCORE\"/><qti-base-value base-type=\"float\">3</qti-base-value></qti-equal>",
  )
  let predicate = test_flow_predicate(
    node,
    root,
    item_declarations=flow_expression_schemas(),
  )
  assert_true(
    predicate.evaluate(
      {
        "items": [
          {
            "identifier": "Q",
            "instance_index": 1,
            "sequence_index": 2,
            "outcomes": { "SCORE": 8 },
          },
          {
            "identifier": "Q",
            "instance_index": 2,
            "sequence_index": 5,
            "outcomes": { "SCORE": 3 },
          },
        ],
      },
      {},
    ),
  )
}

///|
test "flow expression preserves NULL three valued logic without truthiness" {
  let declarations = "<qti-outcome-declaration identifier=\"FLAG\" cardinality=\"single\" base-type=\"boolean\"/>"
  for
    expression in [
      "<qti-null/>", "<qti-variable identifier=\"FLAG\"/>", "<qti-not><qti-variable identifier=\"FLAG\"/></qti-not>",
      "<qti-and><qti-base-value base-type=\"boolean\">true</qti-base-value><qti-variable identifier=\"FLAG\"/></qti-and>",
    ] {
    let (node, root) = flow_expression_fixture(expression, declarations~)
    let predicate = test_flow_predicate(node, root)
    assert_true(!predicate.evaluate({ "items": [] }, { "FLAG": Json::null() }))
  }
  let (node, root) = flow_expression_fixture(
    "<qti-or><qti-base-value base-type=\"boolean\">true</qti-base-value><qti-variable identifier=\"FLAG\"/></qti-or>",
    declarations~,
  )
  assert_true(
    test_flow_predicate(node, root).evaluate({ "items": [] }, {
      "FLAG": Json::null(),
    }),
  )
}

///|
test "flow expression validates exactly one single boolean expression" {
  for
    expression in [
      "", "<qti-base-value base-type=\"boolean\">true</qti-base-value><qti-base-value base-type=\"boolean\">false</qti-base-value>",
      "<qti-base-value base-type=\"integer\">1</qti-base-value>", "<qti-multiple><qti-base-value base-type=\"boolean\">true</qti-base-value></qti-multiple>",
      "<qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">0</qti-base-value></qti-set-outcome-value>",
      "unexpected<qti-base-value base-type=\"boolean\">true</qti-base-value>",
    ] {
    let (node, root) = flow_expression_fixture(expression)
    try test_flow_predicate(node, root) catch {
      _ => ()
    } noraise {
      _ => fail("invalid flow expression accepted")
    }
  }
}

///|
test "flow expression rejects outcome only aggregates and weights in condition scope" {
  for
    expression in [
      "<qti-is-null><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-is-null>",
      "<qti-gte><qti-variable identifier=\"Q.SCORE\" weight-identifier=\"W\"/><qti-base-value base-type=\"float\">1</qti-base-value></qti-gte>",
    ] {
    let (node, root) = flow_expression_fixture(expression)
    try
      test_flow_predicate(
        node,
        root,
        item_declarations=flow_expression_schemas(),
      )
    catch {
      Unsupported(_, _) => ()
      _ => fail("flow scope rejection must identify unsupported context")
    } noraise {
      _ => fail("outcome only expression accepted in flow")
    }
  }
}

///|
test "flow expression rejects forged live outcomes and malformed item environments" {
  let declarations = "<qti-outcome-declaration identifier=\"TOTAL\" cardinality=\"single\" base-type=\"float\"/>"
  let (node, root) = flow_expression_fixture(
    "<qti-gte><qti-variable identifier=\"TOTAL\"/><qti-base-value base-type=\"float\">1</qti-base-value></qti-gte>",
    declarations~,
  )
  let predicate = test_flow_predicate(node, root)
  let invalid : Array[Json] = [
    Json::null(),
    [],
    { "UNKNOWN": 1 },
    { "TOTAL": "2" },
    { "TOTAL": true },
  ]
  for outcomes in invalid {
    try predicate.evaluate({ "items": [] }, outcomes) catch {
      _ => ()
    } noraise {
      _ => fail("invalid live test outcomes accepted")
    }
  }
  try
    predicate.evaluate(
      { "items": [{ "identifier": "Q", "outcomes": {}, "submitted": "yes" }] },
      { "TOTAL": 2 },
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("invalid flow environment accepted")
  }
}

///|
test "flow expression cached context compiles many predicates with isolated schema metadata" {
  let declarations = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>"
  let (_, root) = flow_expression_fixture("<qti-null/>", declarations~)
  let schemas : Array[Json] = []
  for i in 0..<256 {
    schemas.push({
      "identifier": "Q\{i}",
      "outcome_types": {
        "POINTS": { "base_type": "integer", "cardinality": "single" },
        "SCORE": { "base_type": "float", "cardinality": "single" },
        "FLAG": { "base_type": "boolean", "cardinality": "single" },
        "LABEL": { "base_type": "string", "cardinality": "single" },
      },
    })
  }
  let compiler = test_flow_context(root, Json(schemas))
  // Later edits to caller-owned metadata cannot change this compiled context.
  guard schemas[255] is Object(fields) &&
    fields.get("outcome_types") is Some(Object(types)) &&
    types.get("POINTS") is Some(Object(points)) else {
    fail("test item type metadata is missing")
  }
  fields["identifier"] = Json("RENAMED")
  points["base_type"] = Json("string")
  for i in 0..<128 {
    let id = "Q\{if i == 127 { 255 } else { i }}"
    let node = parse_document(
      "<qti-pre-condition xmlns=\"\{qti_namespace}\"><qti-and><qti-gte><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">5</qti-base-value></qti-gte><qti-gte><qti-variable identifier=\"\{id}.POINTS\"/><qti-base-value base-type=\"integer\">3</qti-base-value></qti-gte></qti-and></qti-pre-condition>",
      Limits::default(),
    )
    let predicate = test_flow_predicate(node, root, compiled=Some(compiler))
    let input : Json = {
      "items": [{ "identifier": id, "outcomes": { "POINTS": 4 } }],
    }
    assert_true(predicate.evaluate(input, { "SCORE": 7 }))
    assert_true(!predicate.evaluate(input, { "SCORE": 4 }))
  }
  assert_eq(compiler.program.initial_outcomes(), { "SCORE": 0 })
}
