///|
fn flow_model_items() -> Map[String, AssessmentItem] raise QtiError {
  let xml = "<qti-assessment-item xmlns=\"\{qti_namespace}\" identifier=\"item\" title=\"Item\" adaptive=\"false\" time-dependent=\"false\"><qti-response-declaration identifier=\"RESPONSE\" cardinality=\"single\" base-type=\"identifier\"><qti-correct-response><qti-value>A</qti-value></qti-correct-response></qti-response-declaration><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-item-body><qti-choice-interaction response-identifier=\"RESPONSE\" max-choices=\"1\"><qti-simple-choice identifier=\"A\">First</qti-simple-choice><qti-simple-choice identifier=\"B\">Second</qti-simple-choice></qti-choice-interaction></qti-item-body><qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct.xml\"/></qti-assessment-item>"
  { "item.xml": compile_assessment_item(xml) }
}

///|
fn flow_model_xml(
  item_rule~ : String = "",
  second_rule~ : String = "",
  inner_rule~ : String = "",
  part_rule~ : String = "",
  assembly~ : String = "",
  navigation~ : String = "linear",
  submission~ : String = "individual",
) -> String {
  "<qti-assessment-test xmlns=\"\{qti_namespace}\" identifier=\"model\" title=\"Model\"><qti-test-part identifier=\"P\" navigation-mode=\"\{navigation}\" submission-mode=\"\{submission}\">\{part_rule}<qti-assessment-section identifier=\"OUTER\" title=\"Outer\" visible=\"true\">\{assembly}<qti-assessment-section identifier=\"INNER\" title=\"Inner\" visible=\"true\">\{inner_rule}<qti-assessment-item-ref identifier=\"A\" href=\"item.xml\">\{item_rule}</qti-assessment-item-ref><qti-assessment-item-ref identifier=\"B\" href=\"item.xml\">\{second_rule}</qti-assessment-item-ref></qti-assessment-section><qti-assessment-section identifier=\"NEXT\" title=\"Next\" visible=\"true\"><qti-assessment-item-ref identifier=\"C\" href=\"item.xml\"/></qti-assessment-section></qti-assessment-section></qti-test-part><qti-test-part identifier=\"P2\" navigation-mode=\"linear\" submission-mode=\"individual\"><qti-assessment-section identifier=\"LATER\" title=\"Later\" visible=\"true\"><qti-assessment-item-ref identifier=\"D\" href=\"item.xml\"/></qti-assessment-section></qti-test-part></qti-assessment-test>"
}

///|
fn flow_model_branch(target : String) -> String {
  "<qti-branch-rule target=\"\{target}\"><qti-base-value base-type=\"boolean\">true</qti-base-value></qti-branch-rule>"
}

///|
fn flow_model_pre() -> String {
  "<qti-pre-condition><qti-base-value base-type=\"boolean\">true</qti-base-value></qti-pre-condition>"
}

///|
fn flow_model_reject(xml : String, code : String) -> Unit raise {
  try compile_assessment_test(xml, flow_model_items()) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("invalid flow model compiled")
  }
}

///|
fn flow_model_source(
  id : String,
  kind : String,
  content~ : String = "",
  part~ : String = "P",
  prefix~ : String = "",
  parent~ : String? = None,
) -> TestFlowSource raise QtiError {
  let node = parse_document(
    "<qti-assessment-section xmlns=\"\{qti_namespace}\" identifier=\"\{id}\" title=\"Scope\" visible=\"true\">\{content}</qti-assessment-section>",
    Limits::default(),
  )
  {
    node,
    identifier: id,
    kind,
    part_identifier: part,
    prefix,
    parent_section: parent,
  }
}

///|
test "flow model retains all nonempty scopes and exact nested ranges" {
  let plan = compile_assessment_test(
    flow_model_xml(
      item_rule=flow_model_branch("NEXT"),
      inner_rule=flow_model_pre(),
      part_rule=flow_model_branch("P2"),
    ),
    flow_model_items(),
  )
  assert_eq(plan.flow.length(), 10)
  let ranges = plan.flow.map(s => (s.identifier, s.start, s.end))
  assert_true(ranges.contains(("P", 0, 3)))
  assert_true(ranges.contains(("OUTER", 0, 3)))
  assert_true(ranges.contains(("INNER", 0, 2)))
  assert_true(ranges.contains(("NEXT", 2, 3)))
  assert_true(ranges.contains(("P2", 3, 4)))
  let item = plan.flow.filter(s => s.identifier == "A")[0]
  assert_eq(item.parent_section, Some("INNER"))
  assert_eq(item.branches.map(b => b.target), ["NEXT"])
}

///|
test "flow model accepts forward branches at the exact exclusive scope boundary" {
  for
    xml in [
      flow_model_xml(item_rule=flow_model_branch("B")),
      flow_model_xml(inner_rule=flow_model_branch("NEXT")),
      flow_model_xml(part_rule=flow_model_branch("P2")),
    ] {
    ignore(compile_assessment_test(xml, flow_model_items()))
  }
}

///|
test "flow model rejects self backward ancestor cross part and missing targets" {
  for
    xml in [
      flow_model_xml(item_rule=flow_model_branch("A")),
      flow_model_xml(second_rule=flow_model_branch("A")),
      flow_model_xml(inner_rule=flow_model_branch("B")),
      flow_model_xml(item_rule=flow_model_branch("OUTER")),
      flow_model_xml(item_rule=flow_model_branch("P2")),
      flow_model_xml(item_rule=flow_model_branch("D")),
      flow_model_xml(part_rule=flow_model_branch("C")),
      flow_model_xml(part_rule=flow_model_branch("P")),
      flow_model_xml(item_rule=flow_model_branch("MISSING")),
    ] {
    flow_model_reject(xml, "invalid_item")
  }
}

///|
test "flow model checks special branch targets by owning scope" {
  ignore(
    compile_assessment_test(
      flow_model_xml(item_rule=flow_model_branch("EXIT_SECTION")),
      flow_model_items(),
    ),
  )
  for target in ["EXIT_TEST", "EXIT_TESTPART"] {
    ignore(
      compile_assessment_test(
        flow_model_xml(item_rule=flow_model_branch(target)),
        flow_model_items(),
      ),
    )
    ignore(
      compile_assessment_test(
        flow_model_xml(inner_rule=flow_model_branch(target)),
        flow_model_items(),
      ),
    )
    ignore(
      compile_assessment_test(
        flow_model_xml(part_rule=flow_model_branch(target)),
        flow_model_items(),
      ),
    )
  }
  flow_model_reject(
    flow_model_xml(inner_rule=flow_model_branch("EXIT_SECTION")),
    "unsupported",
  )
  flow_model_reject(
    flow_model_xml(part_rule=flow_model_branch("EXIT_SECTION")),
    "invalid_item",
  )
}

///|
test "flow model ignores nonlinear rules after structural and type validation" {
  let plan = compile_assessment_test(
    flow_model_xml(
      item_rule=flow_model_branch("MISSING"),
      inner_rule=flow_model_pre(),
      navigation="nonlinear",
    ),
    flow_model_items(),
  )
  assert_true(
    plan.flow
    .filter(s => s.kind != "part")
    .all(s => s.preconditions.is_empty() && s.branches.is_empty()),
  )
  flow_model_reject(
    flow_model_xml(
      item_rule="<qti-pre-condition><qti-base-value base-type=\"integer\">1</qti-base-value></qti-pre-condition>",
      navigation="nonlinear",
    ),
    "invalid_item",
  )
}

///|
test "flow model gates simultaneous item flow without blocking test part flow" {
  flow_model_reject(
    flow_model_xml(item_rule=flow_model_pre(), submission="simultaneous"),
    "unsupported",
  )
  flow_model_reject(
    flow_model_xml(
      inner_rule=flow_model_branch("EXIT_TEST"),
      submission="simultaneous",
    ),
    "unsupported",
  )
  ignore(
    compile_assessment_test(
      flow_model_xml(part_rule=flow_model_pre(), submission="simultaneous"),
      flow_model_items(),
    ),
  )
  ignore(
    compile_assessment_test(
      flow_model_xml(
        item_rule=flow_model_pre(),
        navigation="nonlinear",
        submission="simultaneous",
      ),
      flow_model_items(),
    ),
  )
}

///|
test "flow model gates selection and effective shuffle only for active item section flow" {
  for
    assembly in [
      "<qti-selection select=\"2\"/>", "<qti-ordering shuffle=\"true\"/>",
    ] {
    flow_model_reject(
      flow_model_xml(item_rule=flow_model_pre(), assembly~),
      "unsupported",
    )
    ignore(
      compile_assessment_test(
        flow_model_xml(
          item_rule=flow_model_pre(),
          assembly~,
          navigation="nonlinear",
        ),
        flow_model_items(),
      ),
    )
  }
  ignore(
    compile_assessment_test(
      flow_model_xml(
        item_rule=flow_model_pre(),
        assembly="<qti-ordering shuffle=\"false\"/>",
      ),
      flow_model_items(),
    ),
  )
}

///|
test "flow model rejects empty conditional scopes and invalid source ownership" {
  let xml = flow_model_xml()
  let root = parse_document(xml, Limits::default())
  let plan = compile_assessment_test(xml, flow_model_items())
  let empty = flow_model_source("EMPTY", "section", content=flow_model_pre())
  try test_compile_flow([empty], root, plan.entries, plan.parts, []) catch {
    Unsupported(_, _) => ()
    _ => fail("empty conditional scope returned the wrong error")
  } noraise {
    _ => fail("empty conditional scope compiled")
  }
  let invalid = [
    flow_model_source("INNER", "unknown"),
    flow_model_source("INNER", "section", part="MISSING"),
  ]
  for source in invalid {
    try test_compile_flow([source], root, plan.entries, plan.parts, []) catch {
      InvalidItem(_, _) => ()
      _ => fail("invalid flow source returned the wrong error")
    } noraise {
      _ => fail("invalid flow source compiled")
    }
  }
  let ownerless = flow_model_source(
    "A",
    "item",
    content=flow_model_branch("EXIT_SECTION"),
  )
  try test_compile_flow([ownerless], root, plan.entries, plan.parts, []) catch {
    InvalidItem(_, _) => ()
    _ => fail("ownerless EXIT_SECTION returned the wrong error")
  } noraise {
    _ => fail("ownerless EXIT_SECTION compiled")
  }
  let empty_parent = flow_model_source("EMPTY", "section")
  let missing_owner = flow_model_source(
    "A",
    "item",
    content=flow_model_branch("EXIT_SECTION"),
    parent=Some("EMPTY"),
  )
  try
    test_compile_flow(
      [empty_parent, missing_owner],
      root,
      plan.entries,
      plan.parts,
      [],
    )
  catch {
    InvalidItem(_, _) => ()
    _ => fail("empty parent EXIT_SECTION returned the wrong error")
  } noraise {
    _ => fail("EXIT_SECTION with an empty omitted parent compiled")
  }
}

///|
test "flow model permits external reference root targets and rejects internal descendants" {
  let xml = flow_model_xml()
  let root = parse_document(xml, Limits::default())
  let plan = compile_assessment_test(xml, flow_model_items())
  let source = flow_model_source(
    "A",
    "item",
    content=flow_model_branch("NEXT"),
    parent=Some("INNER"),
  )
  let external_child = flow_model_source(
    "NEXT",
    "section",
    prefix="EXT.",
    parent=Some("OUTER"),
  )
  try
    test_compile_flow(
      [source, external_child],
      root,
      plan.entries,
      plan.parts,
      [],
    )
  catch {
    Unsupported(_, _) => ()
    _ => fail("external descendant returned the wrong error")
  } noraise {
    _ => fail("external descendant target compiled")
  }
  let external_root = flow_model_source(
    "NEXT",
    "section",
    prefix="NEXT.",
    parent=Some("OUTER"),
  )
  let scopes = test_compile_flow(
    [source, external_root],
    root,
    plan.entries,
    plan.parts,
    [],
  )
  assert_eq(scopes[0].branches[0].target, "NEXT")
  let active_external = flow_model_source(
    "INNER",
    "section",
    content=flow_model_pre(),
    prefix="EXT.",
  )
  try
    test_compile_flow([active_external], root, plan.entries, plan.parts, [])
  catch {
    Unsupported(_, _) => ()
    _ => fail("external active flow returned the wrong error")
  } noraise {
    _ => fail("external active flow compiled")
  }
}

///|
test "flow model rejects fragmented conditional ranges and duplicate sources" {
  let xml = flow_model_xml()
  let root = parse_document(xml, Limits::default())
  let plan = compile_assessment_test(xml, flow_model_items())
  let entries = plan.entries.copy()
  entries[1] = { ..entries[1], section_identifiers: ["OUTER"], }
  entries[2] = { ..entries[2], section_identifiers: ["OUTER", "INNER"], }
  let source = flow_model_source("INNER", "section", content=flow_model_pre())
  try test_compile_flow([source], root, entries, plan.parts, []) catch {
    Unsupported(_, _) => ()
    _ => fail("fragmented flow range returned the wrong error")
  } noraise {
    _ => fail("fragmented conditional range compiled")
  }
  let duplicate = flow_model_source("INNER", "section")
  try
    test_compile_flow([duplicate, duplicate], root, plan.entries, plan.parts, [])
  catch {
    InvalidItem(_, _) => ()
    _ => fail("duplicate flow source returned the wrong error")
  } noraise {
    _ => fail("duplicate flow source compiled")
  }
}

///|
test "flow model bounds the total number of compiled predicates" {
  let xml = flow_model_xml()
  let root = parse_document(xml, Limits::default())
  let plan = compile_assessment_test(xml, flow_model_items())
  let source = flow_model_source("A", "item", parent=Some("INNER"))
  let predicate = parse_document(
    "<qti-pre-condition xmlns=\"\{qti_namespace}\"><qti-base-value base-type=\"boolean\">true</qti-base-value></qti-pre-condition>",
    Limits::default(),
  )
  for _ in 0..<1025 {
    source.node.children.push(predicate)
  }
  try test_compile_flow([source], root, plan.entries, plan.parts, []) catch {
    LimitExceeded(_) => ()
    _ => fail("predicate limit returned the wrong error")
  } noraise {
    _ => fail("oversized flow predicate set compiled")
  }
}
