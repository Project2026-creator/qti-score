///|
fn assembly_integration_ref(
  id : String,
  attributes~ : String = "",
  href~ : String = "items/a.xml",
  content~ : String = "",
) -> String {
  "<qti-assessment-item-ref identifier=\"\{id}\" href=\"\{href}\" \{attributes}>\{content}</qti-assessment-item-ref>"
}

///|
fn assembly_integration_section(
  id : String,
  content : String,
  attributes~ : String = "",
) -> String {
  "<qti-assessment-section identifier=\"\{id}\" title=\"Section\" visible=\"true\" \{attributes}>\{content}</qti-assessment-section>"
}

///|
fn assembly_integration_source(
  sections : String,
  declarations~ : String = "",
  rules~ : String = "",
) -> String {
  let processing = if rules == "" {
    ""
  } else {
    "<qti-outcome-processing>\{rules}</qti-outcome-processing>"
  }
  test_plan_source(
    declarations +
    test_plan_part(sections, navigation="nonlinear", submission="simultaneous") +
    processing,
  )
}

///|
fn assembly_integration_declaration(id : String) -> String {
  "<qti-outcome-declaration identifier=\"\{id}\" cardinality=\"single\" base-type=\"float\"/>"
}

///|
fn assembly_integration_rule(id : String, expression : String) -> String {
  "<qti-set-outcome-value identifier=\"\{id}\">\{expression}</qti-set-outcome-value>"
}

///|
fn assembly_integration_complete(
  plan : @qti.AssessmentTest,
  answers : Array[String],
) -> @qti.TestSession raise {
  let session = plan.new_session("assembly_session")
  assert_eq(plan.entries().length(), answers.length())
  let individual = plan.parts()[0].submission_mode ==
    @qti.SubmissionMode::Individual
  let stride = if individual { 3 } else { 2 }
  for i, entry in plan.entries() {
    let select : Json = {
      "type": "select",
      "time": i * stride + 1,
      "identifier": entry.identifier,
    }
    ignore(session.act_json(select.stringify()))
    let save : Json = {
      "type": "save",
      "time": i * stride + 2,
      "response": { "RESPONSE": answers[i] },
    }
    ignore(session.act_json(save.stringify()))
    if individual {
      let submit : Json = { "type": "submit", "time": i * stride + 3 }
      ignore(session.act_json(submit.stringify()))
    }
  }
  let finish : Json = {
    "type": "finish_part",
    "time": answers.length() * stride + 1,
  }
  ignore(session.act_json(finish.stringify()))
  session
}

///|
fn assembly_integration_reject(source : String, code : String) -> Unit raise {
  let items = test_plan_items()
  try @qti.compile_assessment_test(source, items) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("invalid assembled test accepted")
  }
}

///|
test "assembled test compilation reproduces its seeded selection order and identity" {
  let children = Array::makei(10, i => assembly_integration_ref("Q\{i}")).join(
    "",
  )
  let source = assembly_integration_source(
    assembly_integration_section(
      "pool",
      "<qti-selection select=\"6\"/><qti-ordering shuffle=\"true\"/>" + children,
    ),
  )
  let first = @qti.compile_assessment_test(source, test_plan_items(), seed=0)
  let replay = @qti.compile_assessment_test(source, test_plan_items(), seed=0)
  let different = @qti.compile_assessment_test(
    source,
    test_plan_items(),
    seed=1,
  )
  assert_eq(first.describe(), replay.describe())
  assert_eq(first.identity(), replay.identity())
  assert_false(first.identity() == different.identity())
  assert_false(
    first.entries().map(e => e.source_identifier) ==
    different.entries().map(e => e.source_identifier),
  )
  assert_true(
    first.describe()
    is { "assembly_seed": 0, "candidate_count": 10, "item_count": 6, .. },
  )
  assert_eq(
    different.entries().map(e => e.identifier),
    @qti.compile_assessment_test(source, test_plan_items(), seed=1)
    .entries()
    .map(e => e.identifier),
  )
}

///|
test "assembled required fixed and subsection selections retain their combined semantics" {
  let group = assembly_integration_section(
    "group",
    assembly_integration_ref("G1") + assembly_integration_ref("G2"),
    attributes="required=\"true\" keep-together=\"false\"",
  )
  let section = assembly_integration_section(
    "root",
    "<qti-selection select=\"2\"/><qti-ordering shuffle=\"true\"/>" +
    assembly_integration_ref("excluded", attributes="fixed=\"true\"") +
    assembly_integration_ref(
      "anchor",
      attributes="required=\"true\" fixed=\"true\"",
    ) +
    assembly_integration_ref("optional") +
    group,
  )
  for seed in [0, 1, 42, 2147483647] {
    let plan = @qti.compile_assessment_test(
      assembly_integration_source(section),
      test_plan_items(),
      seed~,
    )
    assert_eq(plan.entries().map(e => e.source_identifier), [
      "anchor", "G1", "G2",
    ])
    assert_eq(plan.parts()[0].entry_count(), 3)
    assert_true(
      plan.describe() is { "candidate_count": 5, "item_count": 3, .. },
    )
  }
}

///|
test "assembled tests validate all source candidates even if selection excludes them" {
  let selected = assembly_integration_ref("A", attributes="required=\"true\"")
  let missing = assembly_integration_ref("unused", href="items/missing.xml")
  assembly_integration_reject(
    assembly_integration_source(
      assembly_integration_section(
        "pool",
        "<qti-selection select=\"1\"/>" + selected + missing,
      ),
    ),
    "invalid_package",
  )
  let invalid = assembly_integration_section(
    "invalid", "<qti-selection select=\"1\"/>",
  )
  assembly_integration_reject(
    assembly_integration_source(
      assembly_integration_section(
        "pool",
        "<qti-selection select=\"1\"/>" + selected + invalid,
      ),
    ),
    "invalid_item",
  )
  let unsupported = assembly_integration_ref(
    "unused",
    attributes="proprietary=\"yes\"",
  )
  assembly_integration_reject(
    assembly_integration_source(
      assembly_integration_section(
        "pool",
        "<qti-selection select=\"1\"/>" + selected + unsupported,
      ),
    ),
    "unsupported",
  )
}

///|
test "assembled test can select a bounded form from more than 512 authored references" {
  let candidates = Array::makei(700, i => {
    assembly_integration_ref(
      "Q\{i}",
      attributes=if i == 0 { "required=\"true\"" } else { "" },
    )
  }).join("")
  let source = assembly_integration_source(
    assembly_integration_section(
      "bank",
      "<qti-selection select=\"1\"/>" + candidates,
    ),
  )
  let plan = @qti.compile_assessment_test(source, test_plan_items(), seed=42)
  assert_eq(plan.entries().map(e => e.source_identifier), ["Q0"])
  assert_true(
    plan.describe() is { "candidate_count": 700, "item_count": 1, .. },
  )
  let report = assembly_integration_complete(plan, ["A"]).report(
    "2026-10-30T12:00:00Z",
  )
  assert_true(
    report
    is {
      "items": [{ "identifier": "Q0", "outcomes": { "SCORE": 1, .. }, .. }],
      ..
    },
  )
  let broken = source.replace_all(
    old=assembly_integration_ref("Q699"),
    new=assembly_integration_ref("Q699", href="items/missing.xml"),
  )
  assembly_integration_reject(broken, "invalid_package")
}

///|
test "assembled compilation rejects a negative seed before returning a plan" {
  let source = assembly_integration_source(
    assembly_integration_section("root", assembly_integration_ref("A")),
  )
  try @qti.compile_assessment_test(source, test_plan_items(), seed=-1) catch {
    @qti.InvalidItem(_, _) => ()
    _ => fail("negative compilation seed returned wrong error")
  } noraise {
    _ => fail("negative compilation seed accepted")
  }
}

///|
test "assembled clones have distinct runtime identities without colliding with authored identifiers" {
  let repeated = assembly_integration_section(
    "clones",
    "<qti-selection select=\"4\" with-replacement=\"true\"/>" +
    assembly_integration_ref("Q"),
  )
  let authored = ["_qti_instance_2", "_qti_instance_3", "_qti_instance_4"]
    .map(id => assembly_integration_ref(id))
    .join("")
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(
      repeated + assembly_integration_section("authored", authored),
    ),
    test_plan_items(),
  )
  let seen : Map[String, Bool] = Map([])
  for entry in plan.entries() {
    assert_false(seen.contains(entry.identifier))
    seen[entry.identifier] = true
    if entry.source_identifier == "Q" {
      assert_true(entry.instance_index >= 1 && entry.instance_index <= 4)
    } else {
      assert_eq(entry.identifier, entry.source_identifier)
      assert_eq(entry.instance_index, 1)
    }
  }
  assert_eq(
    plan
    .entries()
    .filter(e => e.source_identifier == "Q")
    .map(e => e.instance_index),
    [1, 2, 3, 4],
  )
  assert_eq(plan.entries().length(), 7)
  let session = assembly_integration_complete(plan, [
    "A", "B", "A", "B", "A", "A", "A",
  ])
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    session.report("2026-10-30T12:00:00Z"),
  )
}

///|
test "assembled clones of a maximum length ItemRef remain executable and exportable" {
  let source_id = "Q" + "x".repeat(255)
  let section = assembly_integration_section(
    "clones",
    "<qti-selection select=\"2\" with-replacement=\"true\"/>" +
    assembly_integration_ref(source_id),
  )
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(section),
    test_plan_items(),
  )
  assert_eq(plan.entries().map(e => e.source_identifier), [source_id, source_id])
  assert_eq(plan.entries()[0].identifier, source_id)
  assert_true(plan.entries()[1].identifier.length() <= 256)
  assert_false(plan.entries()[0].identifier == plan.entries()[1].identifier)
  let session = assembly_integration_complete(plan, ["A", "B"])
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(xml.contains("identifier=\"\{source_id}\" sequenceIndex=\"1\""))
  assert_true(xml.contains("identifier=\"\{source_id}\" sequenceIndex=\"2\""))
}

///|
test "assembled snapshots bind both seed and exact compiled execution order" {
  let refs = Array::makei(6, i => assembly_integration_ref("Q\{i}")).join("")
  let source = assembly_integration_source(
    assembly_integration_section(
      "pool",
      "<qti-ordering shuffle=\"true\"/>" + refs,
    ),
  )
  let plan = @qti.compile_assessment_test(source, test_plan_items(), seed=42)
  let session = plan.new_session("saved_assembly")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  let snapshot = session.snapshot()
  let original = session.describe()
  let recompiled = @qti.compile_assessment_test(
    source,
    test_plan_items(),
    seed=42,
  )
  assert_eq(recompiled.restore_session(snapshot).describe(), original)
  assert_eq(recompiled.restore_session(snapshot).snapshot(), snapshot)
  let other = @qti.compile_assessment_test(source, test_plan_items(), seed=43)
  try other.restore_session(snapshot) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("cross-seed restore returned wrong error")
  } noraise {
    _ => fail("snapshot restored against another seed")
  }
  let tampered = @json.parse(snapshot)
  guard tampered is Object(fields) else { fail("snapshot must be an object") }
  fields["assembly_seed"] = 43
  try plan.restore_session(tampered.stringify()) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("tampered seed returned wrong error")
  } noraise {
    _ => fail("snapshot restored with a forged assembly seed")
  }
  assert_eq(session.describe(), original)
  assert_eq(session.snapshot(), snapshot)
}

///|
test "assembled individual repeated source references require an explicit source instance" {
  let declarations = assembly_integration_declaration("SECOND") +
    assembly_integration_declaration("UNQUALIFIED")
  let rules = assembly_integration_rule(
      "SECOND", "<qti-variable identifier=\"Q.2.SCORE\"/>",
    ) +
    assembly_integration_rule(
      "UNQUALIFIED", "<qti-variable identifier=\"Q.SCORE\"/>",
    )
  let repeated = assembly_integration_section(
    "clones",
    "<qti-selection select=\"2\" with-replacement=\"true\"/>" +
    assembly_integration_ref("Q"),
  )
  let sections = assembly_integration_section(
      "intro",
      assembly_integration_ref("P"),
    ) +
    repeated
  let source = assembly_integration_source(sections, declarations~, rules~).replace_all(
    old="submission-mode=\"simultaneous\"",
    new="submission-mode=\"individual\"",
  )
  let plan = @qti.compile_assessment_test(source, test_plan_items())
  let session = assembly_integration_complete(plan, ["A", "A", "B"])
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "outcomes": { "SECOND": 0, "UNQUALIFIED": Null, .. },
      "has_errors": false,
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    report,
  )
}

///|
test "assembled repeated source results preserve independent grades and source instance references" {
  let declarations = ["FIRST", "SECOND", "LAST", "SCORE"]
    .map(id => assembly_integration_declaration(id))
    .join("")
  let rules = assembly_integration_rule(
      "FIRST", "<qti-variable identifier=\"Q.1.SCORE\"/>",
    ) +
    assembly_integration_rule(
      "SECOND", "<qti-variable identifier=\"Q.2.SCORE\"/>",
    ) +
    assembly_integration_rule("LAST", "<qti-variable identifier=\"Q.SCORE\"/>") +
    assembly_integration_rule(
      "SCORE", "<qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum>",
    )
  let repeated = assembly_integration_section(
    "clones",
    "<qti-selection select=\"2\" with-replacement=\"true\"/>" +
    assembly_integration_ref("Q"),
  )
  let sections = assembly_integration_section(
      "intro",
      assembly_integration_ref("P"),
    ) +
    repeated +
    assembly_integration_section("tail", assembly_integration_ref("R"))
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(sections, declarations~, rules~),
    test_plan_items(),
  )
  let session = assembly_integration_complete(plan, ["A", "A", "B", "A"])
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "outcomes": { "FIRST": 1, "SECOND": 0, "LAST": 0, "SCORE": 3, .. },
      "items": [
        { "identifier": "P", "sequence_index": 1, "instance_index": 1, .. },
        {
          "identifier": "Q",
          "sequence_index": 2,
          "instance_index": 1,
          "response": { "RESPONSE": "A", .. },
          "outcomes": { "SCORE": 1, .. },
          ..
        },
        {
          "identifier": "Q",
          "sequence_index": 3,
          "instance_index": 2,
          "response": { "RESPONSE": "B", .. },
          "outcomes": { "SCORE": 0, .. },
          ..
        },
        { "identifier": "R", "sequence_index": 4, "instance_index": 1, .. },
      ],
      ..
    },
  )
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(xml.contains("<itemResult identifier=\"Q\" sequenceIndex=\"2\""))
  assert_true(xml.contains("<itemResult identifier=\"Q\" sequenceIndex=\"3\""))
  assert_false(xml.contains("_qti_instance_"))
  assert_eq(
    plan.restore_session(session.snapshot()).result_xml("2026-10-30T12:00:00Z"),
    xml,
  )
}

///|
test "assembled outcome processing retains declarations of candidates not selected for the form" {
  let section = assembly_integration_section(
    "pool",
    "<qti-selection select=\"1\"/>" +
    assembly_integration_ref("P", attributes="required=\"true\"") +
    assembly_integration_ref("Q"),
  )
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(
      section,
      declarations=assembly_integration_declaration("UNSELECTED"),
      rules=assembly_integration_rule(
        "UNSELECTED", "<qti-variable identifier=\"Q.SCORE\"/>",
      ),
    ),
    test_plan_items(),
  )
  let report = assembly_integration_complete(plan, ["A"]).report(
    "2026-10-30T12:00:00Z",
  )
  assert_true(
    report
    is {
      "outcomes": { "UNSELECTED": Null, .. },
      "items": [{ "identifier": "P", .. }],
      ..
    },
  )
}

///|
test "assembled standard aggregate accepts a legal dotted ItemRef identifier" {
  let section = assembly_integration_section(
    "pool",
    assembly_integration_ref("bank.Q"),
  )
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(
      section,
      declarations=assembly_integration_declaration("SCORE"),
      rules=assembly_integration_rule(
        "SCORE", "<qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum>",
      ),
    ),
    test_plan_items(),
  )
  let report = assembly_integration_complete(plan, ["A"]).report(
    "2026-10-30T12:00:00Z",
  )
  assert_true(
    report
    is {
      "outcomes": { "SCORE": 1, .. },
      "items": [{ "identifier": "bank.Q", .. }],
      ..
    },
  )
}

///|
test "assembled weighted aggregates filter declared numeric types sections and category intersections" {
  let integer_source = fixture("single")
    .replace_all(old="base-type=\"float\"", new="base-type=\"integer\"")
    .replace_all(
      old="<qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct.xml\"/>",
      new="<qti-response-processing><qti-response-condition><qti-response-if><qti-match><qti-variable identifier=\"RESPONSE\"/><qti-correct identifier=\"RESPONSE\"/></qti-match><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"integer\">1</qti-base-value></qti-set-outcome-value></qti-response-if><qti-response-else><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"integer\">0</qti-base-value></qti-set-outcome-value></qti-response-else></qti-response-condition></qti-response-processing>",
    )
  let integer = @qti.compile_assessment_item(integer_source)
  let floating = @qti.compile_assessment_item(fixture("single"))
  let inner = assembly_integration_section(
    "INNER",
    assembly_integration_ref(
      "A",
      href="items/int.xml",
      attributes="category=\"math core\"",
      content="<qti-weight identifier=\"W\" value=\"2\"/>",
    ) +
    assembly_integration_ref(
      "C",
      href="items/int.xml",
      attributes="category=\"math exclude\"",
    ),
  )
  let sections = assembly_integration_section(
    "ROOT",
    inner +
    assembly_integration_ref(
      "B",
      attributes="category=\"math\"",
      content="<qti-weight identifier=\"W\" value=\"0.5\"/>",
    ),
  )
  let declarations = ["ALL", "FLOATONLY", "INNERW"]
    .map(id => assembly_integration_declaration(id))
    .join("")
  let rules = assembly_integration_rule(
      "ALL", "<qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum>",
    ) +
    assembly_integration_rule(
      "FLOATONLY", "<qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum>",
    ) +
    assembly_integration_rule(
      "INNERW", "<qti-sum><qti-test-variables variable-identifier=\"SCORE\" section-identifier=\"INNER\" include-category=\"math\" exclude-category=\"exclude\" weight-identifier=\"W\"/></qti-sum>",
    )
  let plan = @qti.compile_assessment_test(
    assembly_integration_source(sections, declarations~, rules~),
    { "items/a.xml": floating, "items/int.xml": integer },
  )
  let report = assembly_integration_complete(plan, ["A", "A", "A"]).report(
    "2026-10-30T12:00:00Z",
  )
  assert_true(
    report is { "outcomes": { "ALL": 3, "FLOATONLY": 1, "INNERW": 2, .. }, .. },
  )
}

///|
test "assembled tests reject fixed transparent sections reaching a parent shuffle" {
  let transparent = "<qti-assessment-section identifier=\"transparent\" title=\"Hidden grouping\" visible=\"false\" keep-together=\"false\" fixed=\"true\">" +
    assembly_integration_ref("Q") +
    "</qti-assessment-section>"
  assembly_integration_reject(
    assembly_integration_source(
      assembly_integration_section(
        "root",
        "<qti-ordering shuffle=\"true\"/>" + transparent,
      ),
    ),
    "unsupported",
  )
  let promoted = "<qti-assessment-section identifier=\"promoted\" title=\"Hidden grouping\" visible=\"false\" keep-together=\"false\">\{transparent}</qti-assessment-section>"
  assembly_integration_reject(
    assembly_integration_source(
      assembly_integration_section(
        "root",
        "<qti-ordering shuffle=\"true\"/>" + promoted,
      ),
    ),
    "unsupported",
  )
}
