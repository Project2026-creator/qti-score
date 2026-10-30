///|
fn test_feedback_block(
  token : String,
  text : String,
  access~ : String = "during",
  show~ : String = "show",
  outcome~ : String = "NOTICE",
) -> String {
  "<qti-test-feedback access=\"\{access}\" outcome-identifier=\"\{outcome}\" show-hide=\"\{show}\" identifier=\"\{token}\" title=\"\{token}\"><qti-content-body><p>\{text}</p></qti-content-body></qti-test-feedback>"
}

///|
fn test_feedback_declaration(
  cardinality~ : String = "single",
  base~ : String = "identifier",
  initial~ : String = "",
) -> String {
  let default_value = if initial == "" {
    ""
  } else {
    "<qti-default-value><qti-value>\{initial}</qti-value></qti-default-value>"
  }
  "<qti-outcome-declaration identifier=\"NOTICE\" cardinality=\"\{cardinality}\" base-type=\"\{base}\">\{default_value}</qti-outcome-declaration>"
}

///|
fn test_feedback_set(token : String) -> String {
  "<qti-set-outcome-value identifier=\"NOTICE\"><qti-base-value base-type=\"identifier\">\{token}</qti-base-value></qti-set-outcome-value>"
}

///|
fn test_feedback_plan(
  parts : String,
  feedback~ : String = "",
  declaration~ : String = "",
  rules~ : String = "",
  items? : Map[String, @qti.AssessmentItem],
) -> @qti.AssessmentTest raise {
  let declarations = if declaration == "" {
    test_feedback_declaration()
  } else {
    declaration
  }
  let processing = if rules == "" {
    ""
  } else {
    "<qti-outcome-processing>\{rules}</qti-outcome-processing>"
  }
  @qti.compile_assessment_test(
    test_plan_source(declarations + parts + processing + feedback),
    items.unwrap_or(test_plan_items()),
  )
}

///|
fn test_feedback_state(session : @qti.TestSession) -> Json raise {
  guard session.describe() is { "test_feedback": feedback, .. } else {
    fail("session test_feedback is missing")
  }
  feedback
}

///|
fn test_feedback_part(
  id : String,
  ref_id : String,
  feedback : String,
  before~ : String = "",
  submission~ : String = "individual",
  navigation~ : String = "linear",
  ref_rules~ : String = "",
) -> String {
  flow_test_part(
    id,
    flow_test_section("S_\{id}", flow_test_ref(ref_id, content=ref_rules)) +
    feedback,
    control=before,
    submission~,
    navigation~,
  )
}

///|
fn test_feedback_empty(session : @qti.TestSession) -> Unit raise {
  assert_eq(test_feedback_state(session), {
    "during": [],
    "completed_parts": [],
    "at_end": [],
  })
}

///|
fn test_feedback_reject(source : String, code : String) -> Unit raise {
  let items = test_plan_items()
  try @qti.compile_assessment_test(source, items) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("invalid test feedback compiled")
  }
}

///|
test "test feedback waits for outcome processing and is independent of item feedback control" {
  let plan = test_feedback_plan(
    test_feedback_part(
      "P",
      "A",
      test_feedback_block("ready", "PART_READY"),
      before="<qti-item-session-control show-feedback=\"false\"/>",
    ),
    declaration=test_feedback_declaration(initial="ready"),
    feedback=test_feedback_block("ready", "TEST_READY") +
      test_feedback_block("ready", "TEST_END", access="atEnd"),
    rules=test_feedback_set("ready"),
  )
  let session = plan.new_session("first_op")
  test_feedback_empty(session)
  ignore(flow_test_action(session, "save", 1, answer="A"))
  test_feedback_empty(session)
  ignore(flow_test_action(session, "pause", 2))
  test_feedback_empty(session)
  ignore(flow_test_action(session, "resume", 3))
  ignore(flow_test_action(session, "submit", 4))
  assert_true(
    test_feedback_state(session)
    is {
      "during": [
        {
          "identifier": "ready",
          "scope": "test",
          "scope_identifier": "test",
          "access": "during",
          "text": "TEST_READY",
          ..
        },
        {
          "identifier": "ready",
          "scope": "part",
          "scope_identifier": "P",
          "text": "PART_READY",
          ..
        },
      ],
      "completed_parts": [],
      "at_end": [],
      ..
    },
  )
  let feedback = test_feedback_state(session)
  ignore(flow_test_action(session, "submit", 5))
  assert_eq(test_feedback_state(session), feedback)
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
}

///|
test "test feedback freezes completed part feedback and keeps the next part during gate closed" {
  let part_feedback = test_feedback_block(
      "first",
      "FIRST_PART_END",
      access="atEnd",
    ) +
    test_feedback_block("second", "SECOND_PART_END", access="atEnd") +
    test_feedback_block("first", "FIRST_PART_DURING") +
    test_feedback_block("second", "SECOND_PART_DURING")
  let parts = test_feedback_part("P1", "A", part_feedback) +
    test_feedback_part("P2", "B", part_feedback)
  let rules = "<qti-outcome-condition><qti-outcome-if><qti-gte><qti-sum><qti-test-variables variable-identifier=\"SCORE\"/></qti-sum><qti-base-value base-type=\"float\">2</qti-base-value></qti-gte>" +
    test_feedback_set("second") +
    "</qti-outcome-if><qti-outcome-else>" +
    test_feedback_set("first") +
    "</qti-outcome-else></qti-outcome-condition>"
  let plan = test_feedback_plan(
    parts,
    rules~,
    feedback=test_feedback_block("first", "TEST_FIRST") +
      test_feedback_block("second", "TEST_SECOND") +
      test_feedback_block("second", "TEST_FINAL", access="atEnd"),
  )
  let session = plan.new_session("parts")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "finish_part", 3))
  assert_true(
    test_feedback_state(session)
    is {
      "during": [{ "scope": "test", "text": "TEST_FIRST", .. }],
      "completed_parts": [
        {
          "part_identifier": "P1",
          "completed_at": 3,
          "feedback": [{ "text": "FIRST_PART_END", .. }],
          ..
        },
      ],
      "at_end": [],
      ..
    },
  )
  let snapshot = session.snapshot()
  let restored = plan.restore_session(snapshot)
  assert_eq(test_feedback_state(restored), test_feedback_state(session))
  flow_test_answer(restored, 4)
  ignore(flow_test_action(restored, "finish_part", 6))
  let feedback = test_feedback_state(restored)
  assert_true(
    feedback
    is {
      "completed_parts": [
        {
          "part_identifier": "P1",
          "feedback": [{ "text": "FIRST_PART_END", .. }],
          ..
        },
        {
          "part_identifier": "P2",
          "feedback": [{ "text": "SECOND_PART_END", .. }],
          ..
        },
      ],
      "at_end": [{ "scope": "test", "text": "TEST_FINAL", .. }],
      ..
    },
  )
  assert_true(
    restored.report("2026-10-30T12:00:00Z") is { "test_feedback": reported, .. } &&
    reported == feedback,
  )
  assert_eq(
    plan.restore_session(restored.snapshot()).describe(),
    restored.describe(),
  )
  let xml = restored.result_xml("2026-10-30T12:00:00Z")
  assert_false(xml.contains("FIRST_PART_END"))
  assert_false(xml.contains("TEST_FINAL"))
}

///|
test "test feedback uses exact identifier membership and NULL hide defaults" {
  for cardinality in ["single", "multiple"] {
    let rules = if cardinality == "single" {
      "<qti-set-outcome-value identifier=\"NOTICE\"><qti-null/></qti-set-outcome-value>"
    } else {
      "<qti-set-outcome-value identifier=\"NOTICE\"><qti-multiple><qti-base-value base-type=\"identifier\">ready</qti-base-value><qti-base-value base-type=\"identifier\">other</qti-base-value></qti-multiple></qti-set-outcome-value>"
    }
    let plan = test_feedback_plan(
      test_feedback_part("P", "A", ""),
      declaration=test_feedback_declaration(cardinality~),
      rules~,
      feedback=test_feedback_block("ready", "MATCH") +
        test_feedback_block("ready", "NO_MATCH", show="hide") +
        test_feedback_block("Ready", "CASE_SENSITIVE", show="hide"),
    )
    let session = plan.new_session("membership")
    flow_test_answer(session, 1)
    let expected = if cardinality == "single" { "NO_MATCH" } else { "MATCH" }
    assert_true(
      test_feedback_state(session)
      is {
        "during": [
          { "text": String(first), .. },
          { "text": "CASE_SENSITIVE", .. },
        ],
        ..
      } &&
      first == expected,
    )
  }
}

///|
test "test feedback simultaneous mode waits until the whole part is submitted" {
  let plan = test_feedback_plan(
    test_feedback_part(
      "P",
      "A",
      test_feedback_block("ready", "PART_END", access="atEnd"),
      submission="simultaneous",
      navigation="nonlinear",
    ),
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "TEST_DURING") +
      test_feedback_block("ready", "TEST_END", access="atEnd"),
  )
  let session = plan.new_session("simultaneous")
  ignore(flow_test_action(session, "save", 1, answer="A"))
  ignore(flow_test_action(session, "tick", 2))
  test_feedback_empty(session)
  ignore(flow_test_action(session, "finish_part", 3))
  assert_true(
    test_feedback_state(session)
    is {
      "completed_parts": [{ "feedback": [{ "text": "PART_END", .. }], .. }],
      "at_end": [{ "text": "TEST_END", .. }],
      ..
    },
  )
}

///|
test "test feedback normal outcome errors are atomic and forced errors suppress new feedback" {
  let declaration = test_feedback_declaration(initial="ready") +
    "<qti-outcome-declaration identifier=\"OVERFLOW\" cardinality=\"single\" base-type=\"float\"/>"
  let rules = test_feedback_set("ready") +
    "<qti-set-outcome-value identifier=\"OVERFLOW\"><qti-product><qti-base-value base-type=\"float\">1e308</qti-base-value><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product></qti-set-outcome-value>"
  let plan = test_feedback_plan(
    test_feedback_part(
      "P",
      "A",
      test_feedback_block(
        "ready",
        "UNRELIABLE_PART",
        access="atEnd",
        show="hide",
      ),
      before="<qti-time-limits max-time=\"5\"/>",
    ),
    declaration~,
    rules~,
    feedback=test_feedback_block("ready", "UNRELIABLE_DURING", show="hide") +
      test_feedback_block(
        "ready",
        "UNRELIABLE_END",
        access="atEnd",
        show="hide",
      ),
  )
  let session = plan.new_session("error")
  ignore(flow_test_action(session, "save", 1, answer="A"))
  let snapshot = session.snapshot()
  let description = session.describe()
  try flow_test_action(session, "submit", 2) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("unexpected outcome processing error")
  } noraise {
    _ => fail("overflow submission succeeded")
  }
  assert_eq(session.snapshot(), snapshot)
  assert_eq(session.describe(), description)
  ignore(flow_test_action(session, "tick", 5))
  assert_true(
    test_feedback_state(session) is { "during": [], "at_end": [], .. },
  )
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "has_errors": true,
      "test_processing_error": { "code": "invalid_response", .. },
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
  assert_true(
    session.result_xml("2026-10-30T12:00:00Z").contains("assessmentResult"),
  )
}

///|
test "test feedback manual pending may present a real pending marker without a final score" {
  let plan = test_feedback_plan(
    test_feedback_part("P", "A", ""),
    items={
      "items/a.xml": @qti.compile_assessment_item(fixture("extended-text")),
    },
    rules="<qti-set-outcome-value identifier=\"NOTICE\"><qti-variable identifier=\"A.REVIEW\"/></qti-set-outcome-value>",
    feedback=test_feedback_block("pending", "AWAITING_REVIEW", access="atEnd"),
  )
  let session = plan.new_session("manual_pending")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"REFLECTION\":\"Evidence submitted for review.\"}}",
    ),
  )
  ignore(flow_test_action(session, "submit", 2))
  ignore(flow_test_action(session, "finish_part", 3))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "all_items_scored": false,
      "has_errors": false,
      "items": [
        {
          "session_status": "pendingExternalScoring",
          "outcomes": { "SCORE": Null, .. },
          ..
        },
      ],
      "test_feedback": { "at_end": [{ "text": "AWAITING_REVIEW", .. }], .. },
      ..
    },
  )
}

///|
test "test feedback forced response errors suppress new messages and preserve valid earlier part history" {
  let feedback = test_feedback_block("ready", "VALID_PART_END", access="atEnd")
  let first = test_feedback_part("P1", "A", feedback)
  let second = test_feedback_part(
    "P2",
    "B",
    feedback,
    before="<qti-time-limits max-time=\"5\"/>",
  ).replace(old="href=\"items/a.xml\"", new="href=\"items/b.xml\"")
  let plan = test_feedback_plan(
    first + second,
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "VALID_DURING") +
      test_feedback_block("ready", "INVALID_FINAL", access="atEnd"),
    items={
      "items/a.xml": @qti.compile_assessment_item(fixture("single")),
      "items/b.xml": @qti.compile_assessment_item(
        fixture("single").replace(
          old="<qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct.xml\"/>",
          new="<qti-response-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-product><qti-base-value base-type=\"float\">1e308</qti-base-value><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product></qti-set-outcome-value></qti-response-processing>",
        ),
      ),
    },
  )
  let session = plan.new_session("response_error")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "finish_part", 3))
  assert_true(
    test_feedback_state(session)
    is { "during": [{ "text": "VALID_DURING", .. }], .. },
  )
  ignore(flow_test_action(session, "save", 4, answer="A"))
  ignore(flow_test_action(session, "tick", 9))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "has_errors": true,
      "test_processing_error": Null,
      "items": [
        _,
        {
          "session_status": "pendingResponseProcessing",
          "processing_error": { "code": "invalid_response", .. },
          ..
        },
      ],
      "test_feedback": {
        "during": [],
        "at_end": [],
        "completed_parts": [
          {
            "part_identifier": "P1",
            "completed_at": 3,
            "feedback": [{ "text": "VALID_PART_END", .. }],
            ..
          },
          { "part_identifier": "P2", "completed_at": 9, "feedback": [], .. },
        ],
        ..
      },
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
  assert_true(
    session
    .result_xml("2026-10-30T12:00:00Z")
    .contains("pendingResponseProcessing"),
  )
}

///|
test "test feedback is included in the session identity binding" {
  let part = test_feedback_part("P", "A", "")
  let original = test_feedback_plan(
    part,
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "ORIGINAL", access="atEnd"),
  )
  let changed = test_feedback_plan(
    part,
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "CHANGED", access="atEnd"),
  )
  let session = original.new_session("bound_feedback")
  assert_true(original.identity() != changed.identity())
  try changed.restore_session(session.snapshot()) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("unexpected changed feedback restore error")
  } noraise {
    _ => fail("snapshot accepted changed feedback content")
  }
}

///|
test "test feedback part finalization is rolled back if its later branch fails" {
  let overflow = "<qti-gt><qti-product><qti-base-value base-type=\"float\">1e308</qti-base-value><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product><qti-base-value base-type=\"float\">0</qti-base-value></qti-gt>"
  let first = test_feedback_part(
    "P1",
    "A",
    test_feedback_block("ready", "VALID_PART", access="atEnd"),
    before=flow_test_branch("EXIT_TEST", expression=overflow) +
      "<qti-time-limits max-time=\"5\"/>",
  )
  let second = test_feedback_part("P2", "B", "")
  let plan = test_feedback_plan(
    first + second,
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "VALID_DURING") +
      test_feedback_block("ready", "INVALID_END", access="atEnd"),
  )
  let session = plan.new_session("feedback_atomic")
  flow_test_answer(session, 1)
  let before = session.describe()
  let snapshot = session.snapshot()
  try flow_test_action(session, "finish_part", 3) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("unexpected branch failure")
  } noraise {
    _ => fail("overflow branch succeeded")
  }
  assert_eq(session.describe(), before)
  assert_eq(session.snapshot(), snapshot)
  assert_true(test_feedback_state(session) is { "completed_parts": [], .. })
  ignore(flow_test_action(session, "tick", 9))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "has_errors": true,
      "test_processing_error": { "code": "invalid_response", .. },
      "test_feedback": {
        "during": [],
        "at_end": [],
        "completed_parts": [
          {
            "part_identifier": "P1",
            "feedback": [{ "text": "VALID_PART", .. }],
            ..
          },
        ],
        ..
      },
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
}

///|
test "test feedback skipped parts have no completion history while early exit completes the active scope" {
  let part_feedback = test_feedback_block(
    "ready",
    "PART_COMPLETE",
    access="atEnd",
  )
  let parts = test_feedback_part(
      "P1",
      "A",
      part_feedback,
      before=flow_test_pre(flow_test_bool(false)),
    ) +
    test_feedback_part(
      "P2",
      "B",
      part_feedback,
      ref_rules=flow_test_branch("EXIT_TEST"),
    ) +
    test_feedback_part("P3", "C", part_feedback)
  let plan = test_feedback_plan(
    parts,
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "TEST_COMPLETE", access="atEnd"),
  )
  let session = plan.new_session("early_exit")
  flow_test_current(session, "B")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  assert_true(
    test_feedback_state(session)
    is {
      "completed_parts": [
        {
          "part_identifier": "P2",
          "feedback": [{ "text": "PART_COMPLETE", .. }],
          ..
        },
      ],
      "at_end": [{ "text": "TEST_COMPLETE", .. }],
      ..
    },
  )
  assert_eq(
    plan.restore_session(session.snapshot()).describe(),
    session.describe(),
  )
}

///|
test "test feedback all gated parts complete the test using authored outcome defaults" {
  let plan = test_feedback_plan(
    test_feedback_part(
      "P",
      "A",
      test_feedback_block("ready", "UNVISITED_PART", access="atEnd"),
      before=flow_test_pre(flow_test_bool(false)),
    ),
    declaration=test_feedback_declaration(initial="ready"),
    feedback=test_feedback_block("ready", "NO_DURING") +
      test_feedback_block("ready", "TEST_COMPLETE", access="atEnd"),
  )
  let session = plan.new_session("all_gated")
  assert_true(
    test_feedback_state(session)
    is {
      "during": [],
      "completed_parts": [],
      "at_end": [{ "text": "TEST_COMPLETE", .. }],
      ..
    },
  )
  assert_true(session.describe() is { "completed": true, .. })
}

///|
test "test feedback returned JSON does not let callers mutate session feedback or restored history" {
  let plan = test_feedback_plan(
    test_feedback_part(
      "P",
      "A",
      test_feedback_block("ready", "PART_END", access="atEnd"),
    ),
    rules=test_feedback_set("ready"),
    feedback=test_feedback_block("ready", "TEST_END", access="atEnd"),
  )
  let session = plan.new_session("isolation")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "finish_part", 3))
  let before = session.describe()
  let exposed = test_feedback_state(session)
  if exposed is Object(fields) {
    fields["during"] = ["forged"]
    if fields["at_end"] is Array(blocks) &&
      !blocks.is_empty() &&
      blocks[0] is Object(block) {
      block["text"] = Json("forged")
      blocks.clear()
    }
    if fields["completed_parts"] is Array(history) &&
      !history.is_empty() &&
      history[0] is Object(part) {
      part["feedback"] = ["forged"]
      history.clear()
    }
  }
  assert_eq(session.describe(), before)
  let report = session.report("2026-10-30T12:00:00Z")
  if report is Object(fields) {
    fields["test_feedback"] = Json::null()
  }
  assert_eq(session.describe(), before)
  assert_eq(plan.restore_session(session.snapshot()).describe(), before)
}

///|
test "test feedback declarations and required attributes are checked before execution" {
  let part = test_feedback_part("P", "A", "")
  for
    declaration in [
      test_feedback_declaration(base="string"),
      test_feedback_declaration(base="float"),
      test_feedback_declaration(cardinality="ordered"),
    ] {
    test_feedback_reject(
      test_plan_source(
        declaration + part + test_feedback_block("ready", "TEXT"),
      ),
      "invalid_item",
    )
  }
  let valid = test_feedback_block("ready", "TEXT")
  for
    missing in [
      " access=\"during\"", " outcome-identifier=\"NOTICE\"", " show-hide=\"show\"",
      " identifier=\"ready\"",
    ] {
    test_feedback_reject(
      test_plan_source(
        test_feedback_declaration() + part + valid.replace(old=missing, new=""),
      ),
      "invalid_item",
    )
  }
  for
    invalid in [
      valid.replace(old="access=\"during\"", new="access=\"at-end\""),
      valid.replace(old="show-hide=\"show\"", new="show-hide=\"toggle\""),
      valid.replace(old="identifier=\"ready\"", new="identifier=\"1ready\""),
      valid.replace(
        old="outcome-identifier=\"NOTICE\"",
        new="outcome-identifier=\"MISSING\"",
      ),
    ] {
    test_feedback_reject(
      test_plan_source(test_feedback_declaration() + part + invalid),
      "invalid_item",
    )
  }
}

///|
test "test feedback rejects foreign namespaces active content and unsupported assets" {
  let part = test_feedback_part("P", "A", "")
  let valid = test_feedback_block("ready", "TEXT")
  for
    fragment in [
      valid.replace(
        old="<qti-test-feedback ",
        new="<qti-test-feedback xmlns=\"urn:foreign\" ",
      ),
      valid.replace(
        old="<qti-content-body>",
        new="<qti-content-body xmlns=\"urn:foreign\">",
      ),
      valid.replace(old="<p>", new="<p xmlns=\"urn:foreign\">"),
      valid.replace(old="TEXT", new="<script>alert(1)</script>"),
      valid.replace(old="<p>", new="<p onclick=\"alert(1)\">"),
      valid.replace(
        old="<qti-content-body>",
        new="<qti-stylesheet href=\"theme.css\" type=\"text/css\"/><qti-content-body>",
      ),
    ] {
    test_feedback_reject(
      test_plan_source(test_feedback_declaration() + part + fragment),
      "unsupported",
    )
  }
}

///|
test "test feedback rejects interactions in non adaptive content" {
  test_feedback_reject(
    test_plan_source(
      test_feedback_declaration() +
      test_feedback_part("P", "A", "") +
      test_feedback_block(
        "ready", "<qti-choice-interaction response-identifier=\"NOTICE\" max-choices=\"1\"><qti-simple-choice identifier=\"ready\">answer</qti-simple-choice></qti-choice-interaction>",
      ),
    ),
    "invalid_item",
  )
}

///|
test "test feedback body is optional and harmless static markup becomes plain candidate text" {
  let feedback = "<qti-test-feedback access=\"atEnd\" outcome-identifier=\"NOTICE\" show-hide=\"show\" identifier=\"ready\"/>" +
    test_feedback_block(
      "ready",
      "Hello <strong>learner</strong> &amp; peer.<br/>Next step.",
      access="atEnd",
    )
  let plan = test_feedback_plan(
    test_feedback_part("P", "A", ""),
    rules=test_feedback_set("ready"),
    feedback~,
  )
  let session = plan.new_session("static_text")
  ignore(flow_test_action(session, "finish_part", 1))
  guard test_feedback_state(session) is { "at_end": Array(blocks), .. } else {
    fail("completed test feedback is missing")
  }
  assert_true(
    blocks.any(block => {
      block is { "text": String(text), .. } &&
      text.contains("Hello learner & peer.") &&
      text.contains("Next step.") &&
      !text.contains("<strong>")
    }),
  )
}
