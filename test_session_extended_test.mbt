///|
fn feedback_plan() -> @qti.AssessmentTest raise {
  let items : Map[String, @qti.AssessmentItem] = Map([])
  for name in ["dependent-response", "extended-text-scored", "extended-text"] {
    items["items/\{name}.xml"] = @qti.compile_assessment_item(fixture(name))
  }
  @qti.compile_assessment_test(fixture("feedback-test"), items)
}

///|
test "feedback runtime completes cross response and text items while preserving manual pending outcomes" {
  let plan = feedback_plan()
  let result = plan.run_actions_json(
    @fs.read_file_to_string("examples/feedback-actions.json"),
  )
  guard result
    is {
      "state": { "completed": True, .. },
      "report": {
        "all_items_scored": False,
        "has_errors": False,
        "outcomes": { "SCORE": Null, "MAXSCORE": Number(7, ..), .. },
        "items": [
          {
            "identifier": String("evidence-combination"),
            "session_status": String("final"),
            "outcomes": {
              "SCORE": Number(5, ..),
              "COMPLETE": True,
              "FEEDBACK": String("both"),
              ..
            },
            ..
          },
          {
            "identifier": String("formative-summary"),
            "session_status": String("final"),
            "outcomes": {
              "SCORE": Number(2, ..),
              "FEEDBACK": String("matched"),
              ..
            },
            ..
          },
          {
            "identifier": String("reflection-review"),
            "session_status": String("pendingExternalScoring"),
            "outcomes": { "SCORE": Null, "REVIEW": String("pending"), .. },
            "processing_error": Null,
            ..
          },
        ],
        ..
      },
      "xml": String(xml),
      ..
    } else {
    fail("feedback workflow did not retain pending manual scoring")
  }
  assert_true(xml.contains("pendingExternalScoring"))
  assert_true(xml.contains("reflection-review"))
  guard result is { "snapshot": String(snapshot), .. } else {
    fail("snapshot missing")
  }
  let restored = plan.restore_session(snapshot)
  guard result is { "state": state, "report": report, .. } else {
    fail("result missing")
  }
  assert_eq(restored.describe(), state)
  assert_eq(
    restored.report(
      "2026-10-30T12:00:00Z",
      candidate_identifier="demo-feedback-candidate",
    ),
    report,
  )
}

///|
test "feedback runtime reveals authored feedback after individual submission and restores it" {
  let plan = feedback_plan()
  let session = plan.new_session("demo-feedback-replay")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"LEFT\":2,\"RIGHT\":3}}",
    ),
  )
  guard session.describe()
    is { "current": { "result": Null, "feedback": [], .. }, .. } else {
    fail("draft leaked a score or feedback")
  }
  let state = session.act_json("{\"type\":\"submit\",\"time\":2}")
  guard state
    is {
      "current": {
        "result": { "score": Number(5, ..), .. },
        "feedback": [
          {
            "identifier": String("both"),
            "title": String("两项证据均已核对"),
            ..
          },
        ],
        ..
      },
      ..
    } else {
    fail("authored cross response feedback missing")
  }
  let restored = plan.restore_session(session.snapshot())
  assert_eq(restored.describe(), state)
  ignore(restored.act_json("{\"type\":\"next\",\"time\":3}"))
  ignore(
    restored.act_json(
      "{\"type\":\"save\",\"time\":4,\"response\":{\"NOTES\":\"形成性评价用于在教学过程中收集反馈并调整教学。\"}}",
    ),
  )
  let second = restored.act_json("{\"type\":\"submit\",\"time\":5}")
  guard second
    is {
      "current": {
        "result": { "score": Number(2, ..), .. },
        "feedback": [{ "identifier": String("matched"), .. }],
        ..
      },
      ..
    } else {
    fail("rule scored long text feedback missing")
  }
}

///|
test "feedback runtime accepts a submitted human scored response without substituting zero" {
  let plan = feedback_plan()
  let session = plan.new_session("demo-manual-scoring")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"LEFT\":2,\"RIGHT\":3}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"next\",\"time\":3}"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":4,\"response\":{\"NOTES\":\"形成性评价用于在教学过程中收集反馈并调整教学。\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":5}"))
  ignore(session.act_json("{\"type\":\"next\",\"time\":6}"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":7,\"response\":{\"REFLECTION\":\"演示反思：根据学习证据调整讲解。\"}}",
    ),
  )
  let pending = session.act_json("{\"type\":\"submit\",\"time\":8}")
  guard pending
    is {
      "current": {
        "submitted": True,
        "dirty": False,
        "num_attempts": Number(1, ..),
        "result": Null,
        ..
      },
      ..
    } else {
    fail("manual response was not submitted independently of grading")
  }
  let restored = plan.restore_session(session.snapshot())
  assert_eq(restored.describe(), pending)
  ignore(restored.act_json("{\"type\":\"finish_part\",\"time\":9}"))
  guard restored.report("2026-10-30T12:00:00Z")
    is {
      "all_items_scored": False,
      "outcomes": { "SCORE": Null, "MAXSCORE": Number(7, ..), .. },
      "items": [
        _,
        _,
        { "num_attempts": Number(1, ..), "outcomes": { "SCORE": Null, .. }, .. },
      ],
      ..
    } else {
    fail("manual pending score changed during completion")
  }
}

///|
test "feedback runtime allows the authored second attempt and rejects a third attempt" {
  let session = feedback_plan().new_session("demo-feedback-attempts")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"LEFT\":2,\"RIGHT\":1}}",
    ),
  )
  let partial = session.act_json("{\"type\":\"submit\",\"time\":2}")
  guard partial
    is {
      "current": {
        "result": { "score": Number(1, ..), .. },
        "feedback": [{ "identifier": String("partial"), .. }],
        ..
      },
      ..
    } else {
    fail("partial feedback missing")
  }
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"LEFT\":2,\"RIGHT\":3}}",
    ),
  )
  let corrected = session.act_json("{\"type\":\"submit\",\"time\":4}")
  guard corrected
    is {
      "current": {
        "num_attempts": Number(2, ..),
        "result": { "score": Number(5, ..), .. },
        ..
      },
      ..
    } else {
    fail("second attempt was not graded")
  }
  try
    session.act_json(
      "{\"type\":\"save\",\"time\":5,\"response\":{\"LEFT\":2,\"RIGHT\":2}}",
    )
  catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("third attempt accepted")
  }
}
