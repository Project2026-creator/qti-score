///|
fn flow_test_bool(value : Bool) -> String {
  "<qti-base-value base-type=\"boolean\">\{value}</qti-base-value>"
}

///|
fn flow_test_pre(expression : String) -> String {
  "<qti-pre-condition>\{expression}</qti-pre-condition>"
}

///|
fn flow_test_branch(target : String, expression~ : String = "") -> String {
  let condition = if expression == "" {
    flow_test_bool(true)
  } else {
    expression
  }
  "<qti-branch-rule target=\"\{target}\">\{condition}</qti-branch-rule>"
}

///|
fn flow_test_ref(
  id : String,
  content~ : String = "",
  attributes~ : String = "",
) -> String {
  "<qti-assessment-item-ref identifier=\"\{id}\" href=\"items/a.xml\" \{attributes}>\{content}</qti-assessment-item-ref>"
}

///|
fn flow_test_section(
  id : String,
  children : String,
  control~ : String = "",
) -> String {
  "<qti-assessment-section identifier=\"\{id}\" title=\"\{id}\" visible=\"true\">\{control}\{children}</qti-assessment-section>"
}

///|
fn flow_test_part(
  id : String,
  sections : String,
  control~ : String = "",
  navigation~ : String = "linear",
  submission~ : String = "individual",
) -> String {
  test_plan_part(control + sections, id~, navigation~, submission~)
}

///|
fn flow_test_plan(
  parts : String,
  declarations~ : String = "",
  instructions~ : String = "",
  rules~ : String = "",
) -> @qti.AssessmentTest raise {
  let processing = if rules == "" {
    ""
  } else {
    "<qti-outcome-processing>\{rules}</qti-outcome-processing>"
  }
  @qti.compile_assessment_test(
    test_plan_source(declarations + instructions + parts + processing),
    test_plan_items(),
  )
}

///|
fn flow_test_action(
  session : @qti.TestSession,
  kind : String,
  time : Int32,
  answer? : String,
) -> Json raise {
  let action : Map[String, Json] = { "type": Json(kind), "time": Json(time) }
  if answer is Some(value) {
    action["response"] = { "RESPONSE": value }
  }
  session.act_json(Json(action).stringify())
}

///|
fn flow_test_answer(
  session : @qti.TestSession,
  time : Int32,
  answer~ : String = "A",
) -> Unit raise {
  ignore(flow_test_action(session, "save", time, answer~))
  ignore(flow_test_action(session, "submit", time + 1))
}

///|
fn flow_test_current(
  session : @qti.TestSession,
  expected : String,
) -> Unit raise {
  guard session.describe()
    is { "current": { "identifier": String(id), .. }, .. } else {
    fail("active session lacks its current item")
  }
  assert_eq(id, expected)
}

///|
fn flow_test_reject_action(
  session : @qti.TestSession,
  kind : String,
  time : Int32,
) -> Unit raise {
  let before = session.snapshot()
  let description = session.describe()
  try flow_test_action(session, kind, time) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("flow action returned an unexpected error")
  } noraise {
    _ => fail("invalid flow action succeeded")
  }
  assert_eq(session.snapshot(), before)
  assert_eq(session.describe(), description)
}

///|
fn flow_test_reject_compile(parts : String, code : String) -> Unit raise {
  let items = test_plan_items()
  try @qti.compile_assessment_test(test_plan_source(parts), items) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("invalid test flow compiled")
  }
}

///|
fn flow_test_rubric(text : String, view~ : String = "candidate") -> String {
  "<qti-rubric-block view=\"\{view}\"><qti-content-body><p>\{text}</p></qti-content-body></qti-rubric-block>"
}

///|
test "flow entry evaluates part section and item preconditions with ordered AND and NULL" {
  let first = flow_test_part(
    "P1",
    flow_test_section("S1", flow_test_ref("A")),
    control=flow_test_pre(flow_test_bool(false)),
  )
  let second = flow_test_part(
    "P2",
    flow_test_section("S2", flow_test_ref("B")),
    control=flow_test_pre("<qti-null/>"),
  )
  let children = flow_test_ref(
      "C",
      content=flow_test_pre(flow_test_bool(true)) +
        flow_test_pre(flow_test_bool(false)),
    ) +
    flow_test_ref(
      "D",
      content=flow_test_pre(flow_test_bool(true)) + flow_test_pre("<qti-null/>"),
    ) +
    flow_test_ref(
      "E",
      content=flow_test_pre(flow_test_bool(true)) +
        flow_test_pre(flow_test_bool(true)),
    )
  let last = flow_test_part(
    "P3",
    flow_test_section(
      "S3",
      children,
      control=flow_test_pre(flow_test_bool(true)),
    ),
  )
  let plan = flow_test_plan(first + second + last)
  let session = plan.new_session("entry")
  flow_test_current(session, "E")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  assert_true(session.describe() is { "completed": true, .. })
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "has_errors": false,
      "all_items_scored": true,
      "items": [
        {
          "identifier": "A",
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        {
          "identifier": "B",
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        {
          "identifier": "C",
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        {
          "identifier": "D",
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        { "identifier": "E", "session_status": "final", "num_attempts": 1, .. },
      ],
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    report,
  )
}

///|
test "flow entry uses declared test defaults before any outcome processing runs" {
  let declarations = "<qti-outcome-declaration identifier=\"LEVEL\" cardinality=\"single\" base-type=\"integer\"><qti-default-value><qti-value>4</qti-value></qti-default-value></qti-outcome-declaration>"
  let condition = "<qti-match><qti-variable identifier=\"LEVEL\"/><qti-base-value base-type=\"integer\">4</qti-base-value></qti-match>"
  let plan = flow_test_plan(
    flow_test_part(
      "P",
      flow_test_section("S", flow_test_ref("A")),
      control=flow_test_pre(condition),
    ),
    declarations~,
  )
  flow_test_current(plan.new_session("defaults"), "A")
}

///|
test "flow section gates skip an entire required subtree without grading or skipping permission" {
  let hidden = flow_test_section(
    "blocked",
    flow_test_ref("A", attributes="required=\"true\"") + flow_test_ref("B"),
    control=flow_test_pre(flow_test_bool(false)) +
      "<qti-item-session-control allow-skipping=\"false\"/>",
  )
  let tail = flow_test_section("tail", flow_test_ref("C"))
  let plan = flow_test_plan(flow_test_part("P", hidden + tail))
  let session = plan.new_session("section_gate")
  flow_test_current(session, "C")
  assert_true(
    session.describe()
    is {
      "items": [
        {
          "identifier": "A",
          "presented": false,
          "skipped": true,
          "num_attempts": 0,
          ..
        },
        {
          "identifier": "B",
          "presented": false,
          "skipped": true,
          "num_attempts": 0,
          ..
        },
        { "identifier": "C", "presented": true, "skipped": false, .. },
      ],
      ..
    },
  )
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "finish_part", 3))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "items": [
        { "num_attempts": 0, "response": { "RESPONSE": Null, .. }, .. },
        { "num_attempts": 0, "response": { "RESPONSE": Null, .. }, .. },
        { "num_attempts": 1, "outcomes": { "SCORE": 1, .. }, .. },
      ],
      "all_items_scored": true,
      ..
    },
  )
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(
    xml.contains(
      "<itemResult identifier=\"A\" sequenceIndex=\"1\" datestamp=\"2026-10-30T12:00:00Z\" sessionStatus=\"initial\"",
    ),
  )
  assert_false(xml.contains("pendingExternalScoring"))
  assert_eq(
    plan.restore_session(session.snapshot()).result_xml("2026-10-30T12:00:00Z"),
    xml,
  )
}

///|
test "flow direct item branch still evaluates target ancestor gates" {
  let source = flow_test_section(
    "source",
    flow_test_ref("A", content=flow_test_branch("B")),
  )
  let blocked = flow_test_section(
    "blocked",
    flow_test_ref("B") + flow_test_ref("C"),
    control=flow_test_pre(flow_test_bool(false)) +
      flow_test_rubric("BLOCKED_INSTRUCTIONS"),
  )
  let tail = flow_test_section("tail", flow_test_ref("D"))
  let plan = flow_test_plan(flow_test_part("P", source + blocked + tail))
  let session = plan.new_session("target_ancestor")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "D")
  assert_false(session.describe().stringify().contains("BLOCKED_INSTRUCTIONS"))
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "next", 6))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "items": [
        { "identifier": "A", "num_attempts": 1, .. },
        { "identifier": "B", "num_attempts": 0, .. },
        { "identifier": "C", "num_attempts": 0, .. },
        { "identifier": "D", "num_attempts": 1, .. },
      ],
      ..
    },
  )
}

///|
test "flow branches evaluate in order and only the first true rule takes effect" {
  let branches = flow_test_branch("D", expression=flow_test_bool(false)) +
    flow_test_branch("D", expression="<qti-null/>") +
    flow_test_branch("C") +
    flow_test_branch("D")
  let children = flow_test_ref("A", content=branches) +
    flow_test_ref("B") +
    flow_test_ref("C") +
    flow_test_ref("D")
  let plan = flow_test_plan(
    flow_test_part("P", flow_test_section("S", children)),
  )
  let session = plan.new_session("first_true")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "C")
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "finish_part", 6))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "items": [
        { "identifier": "A", "num_attempts": 1, .. },
        { "identifier": "B", "num_attempts": 0, .. },
        { "identifier": "C", "num_attempts": 1, .. },
        { "identifier": "D", "num_attempts": 0, .. },
      ],
      ..
    },
  )
}

///|
test "flow item branches are not overwritten by branches on an enclosing completed section" {
  let first = flow_test_section(
    "first",
    flow_test_ref("A", content=flow_test_branch("B")),
    control=flow_test_branch("EXIT_TEST"),
  )
  let second = flow_test_section("second", flow_test_ref("B"))
  let session = flow_test_plan(flow_test_part("P", first + second)).new_session(
    "item_precedence",
  )
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  assert_true(session.describe() is { "completed": false, .. })
  flow_test_current(session, "B")
}

///|
test "flow natural section exit evaluates inner section branches before outer branches" {
  let inner = flow_test_section(
    "inner",
    flow_test_ref("A"),
    control=flow_test_branch("C"),
  )
  let outer = flow_test_section("outer", inner, control=flow_test_branch("D"))
  let rest = flow_test_section(
    "rest",
    flow_test_ref("B") + flow_test_ref("C") + flow_test_ref("D"),
  )
  let session = flow_test_plan(flow_test_part("P", outer + rest)).new_session(
    "section_order",
  )
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "C")
}

///|
test "flow item EXIT_SECTION exits its closest containing section" {
  let inner = flow_test_section(
    "inner",
    flow_test_ref("A", content=flow_test_branch("EXIT_SECTION")) +
    flow_test_ref("B"),
  )
  let outer = flow_test_section("outer", inner + flow_test_ref("C"))
  let tail = flow_test_section("tail", flow_test_ref("D"))
  let plan = flow_test_plan(flow_test_part("P", outer + tail))
  let session = plan.new_session("exit_section")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "C")
  assert_true(
    session.describe()
    is {
      "items": [
        _,
        { "identifier": "B", "skipped": true, "presented": false, .. },
        _,
        _,
      ],
      ..
    },
  )
}

///|
test "flow EXIT_TESTPART advances through later part gates without presenting excluded items" {
  let first = flow_test_part(
    "P1",
    flow_test_section(
      "S1",
      flow_test_ref("A", content=flow_test_branch("EXIT_TESTPART")) +
      flow_test_ref("B"),
    ),
  )
  let skipped = flow_test_part(
    "P2",
    flow_test_section("S2", flow_test_ref("C")),
    control=flow_test_pre(flow_test_bool(false)),
  )
  let last = flow_test_part("P3", flow_test_section("S3", flow_test_ref("D")))
  let plan = flow_test_plan(first + skipped + last)
  let session = plan.new_session("exit_part")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "D")
  assert_true(
    session.describe()
    is {
      "part_identifier": "P3",
      "items": [
        _,
        { "identifier": "B", "skipped": true, .. },
        { "identifier": "C", "skipped": true, .. },
        _,
      ],
      ..
    },
  )
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "finish_part", 6))
  assert_true(session.describe() is { "completed": true, .. })
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    session.report("2026-10-30T12:00:00Z"),
  )
}

///|
test "flow EXIT_TEST completes early without creating attempts for remaining required items" {
  let first = flow_test_part(
    "P1",
    flow_test_section(
      "S1",
      flow_test_ref("A", content=flow_test_branch("EXIT_TEST")) +
      flow_test_ref("B", attributes="required=\"true\""),
    ),
  )
  let last = flow_test_part(
    "P2",
    flow_test_section("S2", flow_test_ref("C")),
    control="<qti-item-session-control allow-skipping=\"false\"/>",
  )
  let session = flow_test_plan(first + last).new_session("exit_test")
  // No draft: next ends the presented empty attempt, then branches.
  ignore(flow_test_action(session, "next", 1))
  assert_true(session.describe() is { "completed": true, .. })
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "has_errors": false,
      "all_items_scored": true,
      "items": [
        { "identifier": "A", "num_attempts": 1, "session_status": "final", .. },
        {
          "identifier": "B",
          "num_attempts": 0,
          "session_status": "initial",
          ..
        },
        {
          "identifier": "C",
          "num_attempts": 0,
          "session_status": "initial",
          ..
        },
      ],
      ..
    },
  )
}

///|
test "flow requires a dirty individual response to be submitted and does not resubmit a clean attempt" {
  let section = flow_test_section(
    "S",
    flow_test_ref("A", content=flow_test_branch("B")) + flow_test_ref("B"),
  )
  let plan = flow_test_plan(flow_test_part("P", section))
  let session = plan.new_session("submit_once")
  ignore(flow_test_action(session, "save", 1, answer="A"))
  flow_test_reject_action(session, "next", 3)
  ignore(flow_test_action(session, "submit", 2))
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "B")
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "next", 6))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "items": [
        { "identifier": "A", "num_attempts": 1, .. },
        { "identifier": "B", "num_attempts": 1, .. },
      ],
      ..
    },
  )
}

///|
test "flow predicate evaluation errors leave attempts time state and snapshot unchanged" {
  let overflow = "<qti-gt><qti-product><qti-base-value base-type=\"float\">1e308</qti-base-value><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product><qti-base-value base-type=\"float\">0</qti-base-value></qti-gt>"
  let section = flow_test_section(
    "S",
    flow_test_ref("A", content=flow_test_branch("B", expression=overflow)) +
    flow_test_ref("B"),
  )
  let session = flow_test_plan(flow_test_part("P", section)).new_session(
    "failed_flow",
  )
  flow_test_reject_action(session, "next", 9)
}

///|
test "flow conditions on nonlinear items and sections are ignored while part conditions remain active" {
  let children = flow_test_ref(
      "A",
      content=flow_test_pre(flow_test_bool(false)) +
        flow_test_branch("EXIT_TEST"),
    ) +
    flow_test_ref("B")
  let first = flow_test_part(
    "P1",
    flow_test_section("S1", flow_test_ref("excluded")),
    navigation="nonlinear",
    control=flow_test_pre(flow_test_bool(false)),
  )
  let second = flow_test_part(
    "P2",
    flow_test_section(
      "S2",
      children,
      control=flow_test_pre(flow_test_bool(false)) +
        flow_test_branch("EXIT_TEST"),
    ),
    navigation="nonlinear",
  )
  let session = flow_test_plan(first + second).new_session("nonlinear_ignored")
  flow_test_current(session, "A")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "B")
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "finish_part", 6))
  assert_true(session.describe() is { "completed": true, .. })
}

///|
test "flow part branching observes simultaneous outcomes only after complete submission" {
  let condition = "<qti-gte><qti-variable identifier=\"SCORE\"/><qti-base-value base-type=\"float\">2</qti-base-value></qti-gte>"
  let first = flow_test_part(
    "P1",
    flow_test_section("S1", flow_test_ref("A") + flow_test_ref("B")),
    navigation="nonlinear",
    submission="simultaneous",
    control=flow_test_branch("P3", expression=condition),
  )
  let skipped = flow_test_part(
    "P2",
    flow_test_section("S2", flow_test_ref("C")),
  )
  let last = flow_test_part(
    "P3",
    flow_test_section("S3", flow_test_ref("D")),
    control=flow_test_pre(condition),
  )
  let plan = flow_test_plan(
    first + skipped + last,
    declarations="<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>",
    rules="<qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum></qti-set-outcome-value>",
  )
  let session = plan.new_session("part_simultaneous")
  ignore(flow_test_action(session, "save", 1, answer="A"))
  ignore(flow_test_action(session, "next", 2))
  assert_true(
    session.describe()
    is {
      "part_identifier": "P1",
      "current": { "identifier": "B", .. },
      "items": [
        { "identifier": "A", "submitted": false, "num_attempts": 0, .. },
        _,
        _,
        _,
      ],
      ..
    },
  )
  ignore(flow_test_action(session, "save", 3, answer="A"))
  ignore(flow_test_action(session, "finish_part", 4))
  flow_test_current(session, "D")
  flow_test_answer(session, 5)
  ignore(flow_test_action(session, "finish_part", 7))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "outcomes": { "SCORE": 3, .. },
      "items": [
        { "identifier": "A", "num_attempts": 1, .. },
        { "identifier": "B", "num_attempts": 1, .. },
        {
          "identifier": "C",
          "num_attempts": 0,
          "session_status": "initial",
          ..
        },
        { "identifier": "D", "num_attempts": 1, .. },
      ],
      ..
    },
  )
}

///|
test "flow rejects backward cross-part missing or ambiguous branch targets and unsupported combinations" {
  for target in ["A", "missing", "S"] {
    let children = flow_test_ref("A") +
      flow_test_ref("B", content=flow_test_branch(target))
    flow_test_reject_compile(
      flow_test_part("P", flow_test_section("S", children)),
      "invalid_item",
    )
  }
  let cross = flow_test_part(
      "P1",
      flow_test_section("S1", flow_test_ref("A", content=flow_test_branch("B"))),
    ) +
    flow_test_part("P2", flow_test_section("S2", flow_test_ref("B")))
  flow_test_reject_compile(cross, "invalid_item")
  let section_exit = flow_test_section(
    "S",
    flow_test_ref("A"),
    control=flow_test_branch("EXIT_SECTION"),
  )
  flow_test_reject_compile(flow_test_part("P", section_exit), "unsupported")
  let conditional = flow_test_ref(
    "A",
    content=flow_test_pre(flow_test_bool(true)),
  )
  flow_test_reject_compile(
    flow_test_part(
      "P",
      flow_test_section("S", conditional),
      submission="simultaneous",
    ),
    "unsupported",
  )
  for
    assembly in [
      "<qti-selection select=\"1\"/>", "<qti-ordering shuffle=\"true\"/>", "<qti-selection select=\"2\" with-replacement=\"true\"/>",
    ] {
    flow_test_reject_compile(
      flow_test_part("P", flow_test_section("S", conditional, control=assembly)),
      "unsupported",
    )
  }
}

///|
test "flow candidate instructions follow test part and ancestor section order for every item" {
  let inner = flow_test_section(
    "inner",
    flow_test_ref("A") + flow_test_ref("B"),
    control=flow_test_rubric("INNER"),
  )
  let outer = flow_test_section(
    "outer",
    inner,
    control=flow_test_rubric("OUTER") +
      flow_test_rubric("SCORER_SECRET", view="scorer"),
  )
  let tail = flow_test_section(
    "tail",
    flow_test_ref("C"),
    control=flow_test_rubric("TAIL"),
  )
  let plan = flow_test_plan(
    flow_test_part("P", outer + tail, control=flow_test_rubric("PART")),
    instructions=flow_test_rubric("TEST"),
  )
  assert_false(plan.describe().stringify().contains("SCORER_SECRET"))
  let session = plan.new_session("instructions")
  for time in [1, 4] {
    assert_true(
      session.describe()
      is {
        "current": {
          "instructions": [
            { "scope": "test", "text": "TEST", .. },
            { "scope": "part", "text": "PART", .. },
            {
              "scope": "section",
              "scope_identifier": "outer",
              "text": "OUTER",
              ..
            },
            {
              "scope": "section",
              "scope_identifier": "inner",
              "text": "INNER",
              ..
            },
          ],
          ..
        },
        ..
      },
    )
    flow_test_answer(session, time)
    ignore(flow_test_action(session, "next", time + 2))
  }
  flow_test_current(session, "C")
  assert_true(
    session.describe()
    is {
      "current": {
        "instructions": [
          { "scope": "test", "text": "TEST", .. },
          { "scope": "part", "text": "PART", .. },
          { "scope": "section", "scope_identifier": "tail", "text": "TAIL", .. },
        ],
        ..
      },
      ..
    },
  )
  assert_false(session.describe().stringify().contains("SCORER_SECRET"))
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
}

///|
test "flow all false entry gates complete an unpresented test and preserve declared defaults" {
  let first = flow_test_part(
    "P1",
    flow_test_section("S1", flow_test_ref("A")),
    control=flow_test_pre(flow_test_bool(false)),
  )
  let second = flow_test_part(
    "P2",
    flow_test_section(
      "S2",
      flow_test_ref("B"),
      control=flow_test_pre(flow_test_bool(false)),
    ),
  )
  let last = flow_test_part(
    "P3",
    flow_test_section(
      "S3",
      flow_test_ref("C", content=flow_test_pre("<qti-null/>")),
    ),
  )
  let declaration = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>10</qti-value></qti-default-value></qti-outcome-declaration>"
  let plan = flow_test_plan(first + second + last, declarations=declaration)
  let session = plan.new_session("all_excluded")
  assert_true(session.describe() is { "completed": true, .. })
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "has_errors": false,
      "all_items_scored": true,
      "outcomes": { "SCORE": 10, .. },
      "items": [
        {
          "identifier": "A",
          "presented": false,
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        {
          "identifier": "B",
          "presented": false,
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
        {
          "identifier": "C",
          "presented": false,
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
      ],
      ..
    },
  )
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_false(xml.contains("sessionStatus=\"final\""))
  assert_false(xml.contains("pendingExternalScoring"))
  assert_eq(
    plan.restore_session(session.snapshot()).result_xml("2026-10-30T12:00:00Z"),
    xml,
  )
}

///|
test "flow trailing rejected item gates still trigger an entered section exit branch" {
  let first = flow_test_section(
    "first",
    flow_test_ref("A") +
    flow_test_ref("B", content=flow_test_pre(flow_test_bool(false))),
    control=flow_test_branch("D"),
  )
  let rest = flow_test_section("rest", flow_test_ref("C") + flow_test_ref("D"))
  let plan = flow_test_plan(flow_test_part("P", first + rest))
  let session = plan.new_session("trailing_gates")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "D")
  assert_true(
    session.describe()
    is {
      "items": [
        _,
        { "identifier": "B", "skipped": true, "presented": false, .. },
        { "identifier": "C", "skipped": true, "presented": false, .. },
        _,
      ],
      ..
    },
  )
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "next", 6))
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    session.report("2026-10-30T12:00:00Z"),
  )
}

///|
test "flow timeout remains exportable when a part exit predicate fails" {
  let overflow = "<qti-gt><qti-product><qti-base-value base-type=\"float\">1e308</qti-base-value><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product><qti-base-value base-type=\"float\">0</qti-base-value></qti-gt>"
  let section = flow_test_section(
    "S",
    flow_test_ref("A", content=flow_test_pre(flow_test_bool(true))) +
    flow_test_ref("B"),
  )
  let part = flow_test_part(
    "P",
    section,
    control=flow_test_branch("EXIT_TEST", expression=overflow) +
      "<qti-time-limits max-time=\"5\"/>",
  )
  let plan = flow_test_plan(part)
  let session = plan.new_session("timeout_predicate")
  ignore(flow_test_action(session, "save", 1, answer="A"))
  ignore(flow_test_action(session, "tick", 9))
  assert_true(
    session.describe() is { "completed": true, "timed_out": true, .. },
  )
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "has_errors": true,
      "test_processing_error": { "code": "invalid_response", .. },
      "items": [
        {
          "identifier": "A",
          "session_status": "final",
          "num_attempts": 1,
          "duration": 5,
          "outcomes": { "SCORE": 1, .. },
          ..
        },
        {
          "identifier": "B",
          "session_status": "initial",
          "num_attempts": 0,
          "duration": 0,
          ..
        },
      ],
      ..
    },
  )
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(xml.contains("sessionStatus=\"initial\""))
  assert_eq(
    plan.restore_session(session.snapshot()).result_xml("2026-10-30T12:00:00Z"),
    xml,
  )
}

///|
test "flow item EXIT_TESTPART finishes its part before evaluating the part branch" {
  let first = flow_test_part(
    "P1",
    flow_test_section(
      "S1",
      flow_test_ref("A", content=flow_test_branch("EXIT_TESTPART")) +
      flow_test_ref("B"),
    ),
    control=flow_test_branch("P3"),
  )
  let second = flow_test_part("P2", flow_test_section("S2", flow_test_ref("C")))
  let last = flow_test_part("P3", flow_test_section("S3", flow_test_ref("D")))
  let plan = flow_test_plan(first + second + last)
  let session = plan.new_session("two_stage_part_exit")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  flow_test_current(session, "D")
  assert_true(
    session.describe()
    is {
      "part_identifier": "P3",
      "items": [
        { "identifier": "A", "submitted": true, "num_attempts": 1, .. },
        {
          "identifier": "B",
          "presented": false,
          "skipped": true,
          "num_attempts": 0,
          ..
        },
        {
          "identifier": "C",
          "presented": false,
          "skipped": true,
          "num_attempts": 0,
          ..
        },
        { "identifier": "D", "presented": true, .. },
      ],
      ..
    },
  )
  flow_test_answer(session, 4)
  ignore(flow_test_action(session, "finish_part", 6))
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    session.report("2026-10-30T12:00:00Z"),
  )
}

///|
test "flow free presented empty item submission still records one completed attempt" {
  let plan = flow_test_plan(
    flow_test_part("P", flow_test_section("S", flow_test_ref("A"))),
  )
  let session = plan.new_session("empty_attempt")
  ignore(flow_test_action(session, "finish_part", 2))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "has_errors": false,
      "all_items_scored": true,
      "items": [
        {
          "identifier": "A",
          "presented": true,
          "session_status": "final",
          "num_attempts": 1,
          "duration": 2,
          "response": { "RESPONSE": Null, .. },
          "outcomes": { "SCORE": 0, .. },
          ..
        },
      ],
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    report,
  )
}

///|
test "flow first entry sees a selected item implicit numeric outcome default without grading it" {
  let condition = "<qti-gte><qti-variable identifier=\"Q.SCORE\"/><qti-base-value base-type=\"float\">0</qti-base-value></qti-gte>"
  let plan = flow_test_plan(
    flow_test_part(
      "P",
      flow_test_section(
        "S",
        flow_test_ref("Q", content=flow_test_pre(condition)),
      ),
    ),
  )
  let session = plan.new_session("initial_item_default")
  flow_test_current(session, "Q")
  assert_true(
    session.describe()
    is {
      "completed": false,
      "current": { "submitted": false, "num_attempts": 0, "result": Null, .. },
      "items": [{ "identifier": "Q", "presented": true, "skipped": false, .. }],
      ..
    },
  )
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "items": [
        {
          "identifier": "Q",
          "num_attempts": 1,
          "outcomes": { "SCORE": 1, .. },
          ..
        },
      ],
      ..
    },
  )
}

///|
test "flow typed initial defaults are visible to gates but excluded from submitted outcome aggregates" {
  let item_source = "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"typed_defaults\" title=\"Typed initial defaults\"><qti-response-declaration identifier=\"RESPONSE\" cardinality=\"single\" base-type=\"identifier\"><qti-correct-response><qti-value>A</qti-value></qti-correct-response></qti-response-declaration><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>7</qti-value></qti-default-value></qti-outcome-declaration><qti-outcome-declaration identifier=\"LEVEL\" cardinality=\"single\" base-type=\"integer\"><qti-default-value><qti-value>4</qti-value></qti-default-value></qti-outcome-declaration><qti-item-body><qti-choice-interaction response-identifier=\"RESPONSE\" shuffle=\"false\" max-choices=\"1\"><qti-simple-choice identifier=\"A\">A</qti-simple-choice><qti-simple-choice identifier=\"B\">B</qti-simple-choice></qti-choice-interaction></qti-item-body><qti-response-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">1</qti-base-value></qti-set-outcome-value></qti-response-processing></qti-assessment-item>"
  let typed = @qti.AssessmentItem::Processed(
    @qti.compile_processed_item(item_source),
  )
  let future = @qti.AssessmentItem::Processed(
    @qti.compile_processed_item(
      item_source.replace_all(
        old="<qti-value>7</qti-value>",
        new="<qti-value>17</qti-value>",
      ),
    ),
  )
  let condition = "<qti-and><qti-gte><qti-variable identifier=\"Q.SCORE\"/><qti-base-value base-type=\"float\">7</qti-base-value></qti-gte><qti-match><qti-variable identifier=\"Q.LEVEL\"/><qti-base-value base-type=\"integer\">4</qti-base-value></qti-match></qti-and>"
  let first = flow_test_ref(
    "Q",
    content=flow_test_pre(condition) + flow_test_branch("EXIT_TEST"),
  )
  let last = flow_test_ref("R").replace_all(
    old="items/a.xml",
    new="items/r.xml",
  )
  let declarations = "<qti-outcome-declaration identifier=\"SUM\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"COUNT\" cardinality=\"single\" base-type=\"integer\"/>"
  let rules = "<qti-outcome-processing><qti-set-outcome-value identifier=\"SUM\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum></qti-set-outcome-value><qti-set-outcome-value identifier=\"COUNT\"><qti-container-size><qti-test-variables variable-identifier=\"SCORE\"/></qti-container-size></qti-set-outcome-value></qti-outcome-processing>"
  let source = test_plan_source(
    declarations +
    flow_test_part("P", flow_test_section("S", first + last)) +
    rules,
  )
  let plan = @qti.compile_assessment_test(source, {
    "items/a.xml": typed,
    "items/r.xml": future,
  })
  let session = plan.new_session("typed_initial_default")
  flow_test_current(session, "Q")
  assert_true(
    session.describe()
    is {
      "completed": false,
      "current": { "submitted": false, "num_attempts": 0, .. },
      ..
    },
  )
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "outcomes": { "SUM": 1, "COUNT": 1, .. },
      "has_errors": false,
      "all_items_scored": true,
      "items": [
        {
          "identifier": "Q",
          "num_attempts": 1,
          "outcomes": { "SCORE": 1, "LEVEL": 4, .. },
          ..
        },
        {
          "identifier": "R",
          "presented": false,
          "num_attempts": 0,
          "session_status": "initial",
          "outcomes": { "SCORE": 17, "LEVEL": 4, .. },
          ..
        },
      ],
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
    report,
  )
}
