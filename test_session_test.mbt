///|
fn runtime_plan() -> @qti.AssessmentTest raise {
  let items = Map([
    (
      "items/single.xml",
      @qti.compile_assessment_item(
        @fs.read_file_to_string("examples/single.xml"),
      ),
    ),
    (
      "items/multiple.xml",
      @qti.compile_assessment_item(
        @fs.read_file_to_string("examples/multiple.xml"),
      ),
    ),
    (
      "items/numeric.xml",
      @qti.compile_assessment_item(
        @fs.read_file_to_string("examples/numeric.xml"),
      ),
    ),
  ])
  @qti.compile_assessment_test(
    @fs.read_file_to_string("examples/runtime-test.xml"),
    items,
  )
}

///|
test "runtime complete authored test keeps repeated resource instances and total" {
  let plan = runtime_plan()
  let result = plan.run_actions_json(
    @fs.read_file_to_string("examples/runtime-actions.json"),
  )
  assert_true(
    result
    is {
      "state": { "completed": True, .. },
      "report": {
        "outcomes": { "SCORE": Number(4, ..), .. },
        "items": Array(items),
        ..
      },
      ..
    } &&
    items.length() == 4,
  )
  assert_true(
    result is { "xml": String(xml), .. } &&
    xml.contains("assessmentResult") &&
    xml.contains("formative-1") &&
    xml.contains("formative-2"),
  )
}

///|
test "runtime drafts never expose a grade and simultaneous defers submission" {
  let session = runtime_plan().new_session("drafts")
  let state = session.act_json(
    "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
  )
  assert_true(
    state is { "current": { "result": Null, "submitted": False, .. }, .. },
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"next\",\"time\":3}"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":4,\"response\":{\"RESPONSE\":[\"A\",\"C\"]}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":5}"))
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":6}"))
  let state = session.act_json(
    "{\"type\":\"save\",\"time\":7,\"response\":{\"RESPONSE\":\"A\"}}",
  )
  assert_true(
    state is { "current": { "submitted": False, "result": Null, .. }, .. },
  )
  assert_true(
    try {
      ignore(session.act_json("{\"type\":\"submit\",\"time\":8}"))
      false
    } catch {
      @qti.InvalidResponse(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(session.result_xml("2026-10-30T12:00:00Z"))
      false
    } catch {
      @qti.InvalidResponse(_) => true
      _ => false
    },
  )
}

///|
test "runtime snapshot replay restores exact state and rejects changed test" {
  let plan = runtime_plan()
  let session = plan.new_session("resume")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"pause\",\"time\":2}"))
  let snapshot = session.snapshot()
  let restored = plan.restore_session(snapshot)
  assert_eq(restored.describe(), session.describe())
  ignore(restored.act_json("{\"type\":\"resume\",\"time\":20}"))
  ignore(restored.act_json("{\"type\":\"submit\",\"time\":21}"))
  assert_true(
    restored.describe()
    is { "current": { "num_attempts": Number(1, ..), .. }, .. },
  )
  let changed = snapshot.replace(old=plan.identity(), new="different")
  assert_true(
    try {
      ignore(plan.restore_session(changed))
      false
    } catch {
      @qti.InvalidResponse(_) => true
      _ => false
    },
  )
}

///|
test "runtime duplicate submission is idempotent and attempts are bounded" {
  let session = runtime_plan().new_session("attempts")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"submit\",\"time\":3}"))
  assert_true(
    session.describe()
    is { "current": { "num_attempts": Number(1, ..), .. }, .. },
  )
  let state = session.act_json(
    "{\"type\":\"save\",\"time\":4,\"response\":{\"RESPONSE\":\"B\"}}",
  )
  assert_true(
    state is { "current": { "result": Null, "feedback": Array([]), .. }, .. },
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":5}"))
  assert_true(
    session.describe()
    is { "current": { "num_attempts": Number(2, ..), .. }, .. },
  )
  assert_true(
    try {
      ignore(
        session.act_json(
          "{\"type\":\"save\",\"time\":6,\"response\":{\"RESPONSE\":\"A\"}}",
        ),
      )
      false
    } catch {
      @qti.InvalidResponse(_) => true
      _ => false
    },
  )
}

///|
test "runtime rejects skipped required navigation and invalid clocks atomically" {
  let session = runtime_plan().new_session("invalid")
  let before = session.snapshot()
  for
    input in [
      "{\"type\":\"next\",\"time\":1}", "{\"type\":\"select\",\"time\":1,\"identifier\":\"evidence\"}",
      "{\"type\":\"tick\",\"time\":-1}", "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"UNKNOWN\"}}",
    ] {
    assert_true(
      try {
        ignore(session.act_json(input))
        false
      } catch {
        @qti.InvalidResponse(_) => true
        _ => false
      },
    )
    assert_eq(session.snapshot(), before)
  }
}

///|
test "runtime state responses are defensive copies" {
  let session = runtime_plan().new_session("copies")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  let state = session.describe()
  if state is { "current": { "response": Object(response), .. }, .. } {
    response["RESPONSE"] = Json("B")
  }
  assert_true(
    session.describe()
    is { "current": { "response": { "RESPONSE": String("A"), .. }, .. }, .. },
  )
}
