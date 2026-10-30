///|
fn review_plan(
  item_name~ : String = "single",
  navigation~ : String = "nonlinear",
  submission~ : String = "individual",
  control~ : String = "",
  timed~ : Bool = false,
  two_items~ : Bool = true,
) -> @qti.AssessmentTest raise {
  let limits = if timed { "<qti-time-limits max-time=\"5\"/>" } else { "" }
  let second = if two_items {
    "<qti-assessment-item-ref identifier=\"b\" href=\"items/a.xml\"/>"
  } else {
    ""
  }
  let refs = "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/>" +
    second
  let source = test_plan_source(
    test_plan_part(
      limits + control + test_plan_section(refs),
      navigation~,
      submission~,
    ),
  )
  @qti.compile_assessment_test(source, {
    "items/a.xml": @qti.compile_assessment_item(fixture(item_name)),
  })
}

///|
fn review_action_rejected(
  session : @qti.TestSession,
  action : String,
) -> Unit raise {
  let before = session.snapshot()
  let description = session.describe()
  try session.act_json(action) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("expected session action InvalidResponse")
  } noraise {
    _ => fail("expected rejected session action")
  }
  assert_eq(session.snapshot(), before)
  assert_eq(session.describe(), description)
}

///|
test "session review select cannot bypass allow-skipping and failure is atomic" {
  let session = review_plan(
    control="<qti-item-session-control allow-skipping=\"false\"/>",
  ).new_session("s")
  review_action_rejected(
    session, "{\"type\":\"select\",\"time\":2,\"identifier\":\"b\"}",
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  let state = session.act_json(
    "{\"type\":\"select\",\"time\":3,\"identifier\":\"b\"}",
  )
  assert_true(state is { "current": { "identifier": "b", .. }, .. })
}

///|
test "session review next cannot reopen an item with review disabled" {
  let session = review_plan(
    control="<qti-item-session-control allow-review=\"false\"/>",
  ).new_session("s")
  ignore(
    session.act_json("{\"type\":\"select\",\"time\":1,\"identifier\":\"b\"}"),
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":2,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":3}"))
  ignore(
    session.act_json("{\"type\":\"select\",\"time\":4,\"identifier\":\"a\"}"),
  )
  review_action_rejected(session, "{\"type\":\"next\",\"time\":5}")
}

///|
test "session review numeric text and directed pair drafts export canonical result values" {
  for
    input in [
      ("numeric", "{\"RESPONSE\":\"100.5\"}", "<value>100.5</value>"),
      (
        "match-single", "{\"RESPONSE\":\"Portfolio   Growth\"}", "<value>Portfolio Growth</value>",
      ),
    ] {
    let session = review_plan(item_name=input.0, two_items=false).new_session(
      "s",
    )
    ignore(
      session.act_json(
        "{\"type\":\"save\",\"time\":1,\"response\":" + input.1 + "}",
      ),
    )
    ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
    ignore(session.act_json("{\"type\":\"finish_part\",\"time\":3}"))
    let xml = session.result_xml("2026-10-30T12:00:00Z")
    assert_true(xml.contains(input.2))
    assert_eq(
      session.describe(),
      review_plan(item_name=input.0, two_items=false)
      .restore_session(session.snapshot())
      .describe(),
    )
  }
}

///|
test "session review pause excludes suspended time and restore preserves duration" {
  let plan = review_plan(two_items=false, timed=true)
  let session = plan.new_session("s")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"pause\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"resume\",\"time\":100}"))
  ignore(session.act_json("{\"type\":\"submit\",\"time\":101}"))
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":102}"))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(report is { "items": [{ "duration": 4, .. }], .. })
  assert_eq(
    report,
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
  )
}

///|
test "session review repeated submit is idempotent and does not consume another attempt" {
  let session = review_plan(two_items=false).new_session("s")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  let state = session.act_json("{\"type\":\"submit\",\"time\":3}")
  assert_true(state is { "current": { "num_attempts": 1, .. }, .. })
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":4}"))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is { "items": [{ "num_attempts": 1, .. }], .. },
  )
}

///|
test "session review timeout finalizes required unanswered inline choice" {
  let session = review_plan(
    item_name="inline-choice-required",
    two_items=false,
    timed=true,
  ).new_session("s")
  let state = session.act_json("{\"type\":\"tick\",\"time\":9}")
  assert_true(state is { "completed": true, "timed_out": true, .. })
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "has_errors": true,
      "items": [{ "session_status": "pendingResponseProcessing", .. }],
      ..
    },
  )
  let xml = session.result_xml("2026-10-30T12:00:00Z")
  assert_true(xml.contains("sessionStatus=\"pendingResponseProcessing\""))
  assert_true(
    xml.contains(
      "identifier=\"SCORE\" cardinality=\"single\" baseType=\"float\"></outcomeVariable>",
    ),
  )
  assert_true(
    session
    .result_xml("2026-10-30T12:00:00Z")
    .contains("<candidateResponse></candidateResponse>"),
  )
}

///|
test "session review simultaneous finish failure leaves all responses unsubmitted" {
  let session = review_plan(
    submission="simultaneous",
    control="<qti-item-session-control allow-skipping=\"false\"/>",
  ).new_session("s")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(
    session.act_json("{\"type\":\"select\",\"time\":2,\"identifier\":\"b\"}"),
  )
  review_action_rejected(session, "{\"type\":\"finish_part\",\"time\":3}")
  assert_true(
    session.describe()
    is {
      "items": [
        { "submitted": false, "num_attempts": 0, .. },
        { "submitted": false, "num_attempts": 0, .. },
      ],
      ..
    },
  )
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":4}"))
  assert_true(
    session.report("2026-10-30T12:00:00Z")
    is {
      "items": [
        { "num_attempts": 1, "outcomes": { "SCORE": 1, .. }, .. },
        { "num_attempts": 1, "outcomes": { "SCORE": 1, .. }, .. },
      ],
      ..
    },
  )
}

///|
test "session review feedback remains hidden when delivery control disables it" {
  let session = review_plan(two_items=false).new_session("s")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  let state = session.act_json("{\"type\":\"submit\",\"time\":2}")
  assert_true(
    state is { "current": { "result": Null, "feedback": [], .. }, .. },
  )
}

///|
test "session review bounded history always leaves a restorable snapshot" {
  let plan = review_plan(item_name="text", two_items=false)
  let session = plan.new_session("s")
  let response : Json = { "RESPONSE": "x".repeat(65536) }
  let mut rejected = false
  let mut accepted = 0
  for i in 1..<=130 {
    if rejected {
      break
    }
    let action : Json = { "type": "save", "time": i, "response": response }
    try session.act_json(action.stringify()) catch {
      @qti.LimitExceeded(_) => rejected = true
      _ => fail("unexpected error before session history bound")
    } noraise {
      _ => accepted += 1
    }
  }
  assert_true(rejected)
  assert_true(accepted > 0 && accepted < 130)
  let snapshot = session.snapshot()
  assert_true(snapshot.length() <= 8388608)
  assert_eq(session.describe(), plan.restore_session(snapshot).describe())
}
