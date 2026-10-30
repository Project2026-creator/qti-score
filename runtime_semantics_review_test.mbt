///|
test "runtime semantics allow-review false does not forbid remaining attempts" {
  let session = review_plan(
    two_items=false,
    control="<qti-item-session-control max-attempts=\"2\" allow-review=\"false\"/>",
  ).new_session("review_remaining_attempt")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"RESPONSE\":\"B\"}}",
    ),
  )
  let state = session.act_json("{\"type\":\"submit\",\"time\":4}")
  assert_true(state is { "current": { "num_attempts": 2, .. }, .. })
  review_action_rejected(
    session, "{\"type\":\"save\",\"time\":5,\"response\":{\"RESPONSE\":\"A\"}}",
  )
}

///|
test "runtime semantics manual pending preserves independent authored test defaults" {
  let manual = @qti.compile_assessment_item(fixture("extended-text"))
  let source = "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"manual_test\" title=\"Manual test\"><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"MAXSCORE\" cardinality=\"single\" base-type=\"float\"><qti-default-value><qti-value>10</qti-value></qti-default-value></qti-outcome-declaration><qti-outcome-declaration identifier=\"FORM\" cardinality=\"single\" base-type=\"identifier\"><qti-default-value><qti-value>version_one</qti-value></qti-default-value></qti-outcome-declaration><qti-test-part identifier=\"p\" navigation-mode=\"linear\" submission-mode=\"individual\"><qti-assessment-section identifier=\"s\" title=\"Section\" visible=\"true\"><qti-assessment-item-ref identifier=\"manual\" href=\"manual.xml\"/></qti-assessment-section></qti-test-part><qti-outcome-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum></qti-set-outcome-value></qti-outcome-processing></qti-assessment-test>"
  let plan = @qti.compile_assessment_test(source, { "manual.xml": manual })
  let session = plan.new_session("manual_defaults")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"REFLECTION\":\"A classroom reflection.\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":3}"))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "all_items_scored": false,
      "outcomes": { "SCORE": Null, "MAXSCORE": 10, "FORM": "version_one", .. },
      ..
    },
  )
}

///|
test "runtime semantics failed test outcome processing leaves simultaneous part uncommitted" {
  let source = "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"overflow_test\" title=\"Outcome overflow\"><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-test-part identifier=\"p\" navigation-mode=\"nonlinear\" submission-mode=\"simultaneous\"><qti-assessment-section identifier=\"s\" title=\"Section\" visible=\"true\"><qti-assessment-item-ref identifier=\"a\" href=\"single.xml\"/><qti-assessment-item-ref identifier=\"b\" href=\"single.xml\"/></qti-assessment-section></qti-test-part><qti-outcome-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-product><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product></qti-set-outcome-value></qti-outcome-processing></qti-assessment-test>"
  let plan = @qti.compile_assessment_test(source, {
    "single.xml": @qti.compile_assessment_item(fixture("single")),
  })
  let session = plan.new_session("overflow_atomic")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(
    session.act_json("{\"type\":\"select\",\"time\":2,\"identifier\":\"b\"}"),
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  review_action_rejected(session, "{\"type\":\"finish_part\",\"time\":4}")
}

///|
fn semantics_overflow_plan(
  submission~ : String,
  timed~ : Bool = false,
) -> @qti.AssessmentTest raise {
  let limits = if timed { "<qti-time-limits max-time=\"5\"/>" } else { "" }
  let part = test_plan_part(
    limits +
    test_plan_section(
      "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/><qti-assessment-item-ref identifier=\"b\" href=\"items/a.xml\"/>",
    ),
    navigation="nonlinear",
    submission~,
  )
  let declaration = "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>"
  let rules = "<qti-outcome-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-product><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum><qti-base-value base-type=\"float\">1e308</qti-base-value></qti-product></qti-set-outcome-value></qti-outcome-processing>"
  @qti.compile_assessment_test(
    test_plan_source(declaration + part + rules),
    test_plan_items(),
  )
}

///|
test "runtime semantics individual aggregate failure preserves the previous committed attempt" {
  let plan = semantics_overflow_plan(submission="individual")
  let session = plan.new_session("individual_atomic")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"next\",\"time\":3}"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":4,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  review_action_rejected(session, "{\"type\":\"submit\",\"time\":5}")
  assert_eq(
    session.describe(),
    plan.restore_session(session.snapshot()).describe(),
  )
  assert_true(
    session.describe()
    is {
      "items": [
        { "submitted": true, "num_attempts": 1, .. },
        { "submitted": false, "num_attempts": 0, .. },
      ],
      ..
    },
  )
}

///|
test "runtime semantics timeout preserves exportability after test aggregate failure" {
  let plan = semantics_overflow_plan(submission="simultaneous", timed=true)
  let session = plan.new_session("force_aggregate_failure")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(
    session.act_json("{\"type\":\"select\",\"time\":2,\"identifier\":\"b\"}"),
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  let state = session.act_json("{\"type\":\"tick\",\"time\":9}")
  assert_true(state is { "completed": true, "timed_out": true, .. })
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "has_errors": true,
      "outcomes": { "SCORE": Null, .. },
      "items": [
        { "outcomes": { "SCORE": 1, .. }, .. },
        { "outcomes": { "SCORE": 1, .. }, .. },
      ],
      ..
    },
  )
  assert_true(
    session.result_xml("2026-10-30T12:00:00Z").contains("<testResult"),
  )
  assert_eq(
    report,
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
  )
}

///|
test "runtime semantics safe integer modulus retains exact remainder" {
  let declarations = "<qti-outcome-declaration identifier=\"RESULT\" cardinality=\"single\" base-type=\"integer\"/>"
  let rules = "<qti-set-outcome-value identifier=\"RESULT\"><qti-integer-modulus><qti-base-value base-type=\"integer\">-9007199254740991</qti-base-value><qti-base-value base-type=\"integer\">3002399751580331</qti-base-value></qti-integer-modulus></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  assert_eq(program.evaluate_json({}), { "RESULT": 2 })
}

///|
test "runtime semantics integer sum cannot silently round an unsafe intermediate" {
  let declarations = "<qti-outcome-declaration identifier=\"RESULT\" cardinality=\"single\" base-type=\"integer\"/>"
  let rules = "<qti-set-outcome-value identifier=\"RESULT\"><qti-sum><qti-base-value base-type=\"integer\">9007199254740991</qti-base-value><qti-base-value base-type=\"integer\">2</qti-base-value><qti-base-value base-type=\"integer\">-9007199254740991</qti-base-value></qti-sum></qti-set-outcome-value>"
  let program = @qti.compile_processing_program(
    processing_program_fixture(declarations, rules),
  )
  try program.evaluate_json({}) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("unexpected integer precision error")
  } noraise {
    result => assert_eq(result, { "RESULT": 2 })
  }
}

///|
test "runtime semantics external human score remains pending with a numeric default" {
  let source = fixture("extended-text").swap(
    "<qti-set-outcome-value identifier=\"SCORE\"><qti-null/></qti-set-outcome-value>",
    "",
  )
  let item = @qti.compile_assessment_item(source)
  let xml = test_plan_source(
    test_plan_part(
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"manual\" href=\"manual.xml\"/>",
      ),
    ),
  )
  let session = @qti.compile_assessment_test(xml, { "manual.xml": item }).new_session(
    "manual_numeric_default",
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"REFLECTION\":\"Reflection awaiting a human scorer.\"}}",
    ),
  )
  let submitted = session.act_json("{\"type\":\"submit\",\"time\":2}")
  assert_true(
    submitted is { "current": { "submitted": true, "result": Null, .. }, .. },
  )
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":3}"))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "all_items_scored": false,
      "items": [{ "session_status": "pendingExternalScoring", .. }],
      ..
    },
  )
}

///|
test "runtime semantics accepts standard human scored item without response processing" {
  let xml = "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"manual_no_processing\" title=\"Manual item\"><qti-response-declaration identifier=\"R\" cardinality=\"single\" base-type=\"string\"/><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\" external-scored=\"human\"/><qti-item-body><qti-extended-text-interaction response-identifier=\"R\"><qti-prompt>Write a reflection.</qti-prompt></qti-extended-text-interaction></qti-item-body></qti-assessment-item>"
  let item = @qti.compile_processed_item(xml)
  assert_true(item.describe() is { "external_scoring": true, .. })
}

///|
test "runtime semantics identifier bounds are checked before creating an unexportable test" {
  let test_id = "T" + "x".repeat(255)
  let reference_id = "R" + "x".repeat(255)
  let source = test_plan_source(
    test_plan_part(
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"" +
        reference_id +
        "\" href=\"items/a.xml\"/>",
      ),
    ),
  ).swap("identifier=\"test\"", "identifier=\"" + test_id + "\"")
  let plan = @qti.compile_assessment_test(source, test_plan_items())
  assert_eq(plan.identifier, test_id)
  assert_eq(plan.entries()[0].identifier, reference_id)
  let session = plan.new_session("identifier_bound")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":3}"))
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(xml.contains("<testResult identifier=\"" + test_id + "\""))
  assert_true(xml.contains("<itemResult identifier=\"" + reference_id + "\""))
  for
    invalid in [
      source.swap(test_id, test_id + "x"),
      source.swap(reference_id, reference_id + "x"),
    ] {
    try @qti.compile_assessment_test(invalid, test_plan_items()) catch {
      @qti.LimitExceeded(_) => ()
      _ => fail("expected compile-time identifier size rejection")
    } noraise {
      _ => fail("257-character identifier compiled")
    }
  }
}

///|
test "runtime semantics known templates ignore fallback locations and unknown templates stay rejected" {
  let template = "https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct.xml"
  let source = fixture("single").swap(
    "template=\"" + template + "\"",
    "template=\"" +
    template +
    "\" template-location=\"https://example.invalid/never-fetch.xml\"",
  )
  assert_eq(
    @qti.compile_item(source).score_json("{\"RESPONSE\":\"A\"}").score,
    1.0,
  )
  assert_eq(
    @qti.compile_processed_item(source).score_json("{\"RESPONSE\":\"A\"}").score,
    1.0,
  )
  let unknown = source.swap(
    template, "https://example.invalid/unknown-template.xml",
  )
  try @qti.compile_item(unknown) catch {
    @qti.Unsupported(_, _) => ()
    _ => fail("expected unsupported unknown template")
  } noraise {
    _ => fail("unknown template fallback was accepted")
  }
  try @qti.compile_processed_item(unknown) catch {
    @qti.Unsupported(_, _) => ()
    _ => fail("expected unsupported unknown processed template")
  } noraise {
    _ => fail("unknown processed template fallback was accepted")
  }
}
