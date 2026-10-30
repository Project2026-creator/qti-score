///|
test "flow standard template SCORE defaults survive entry gates and initial result export" {
  let item = @qti.compile_assessment_item(
    fixture("single").replace(
      old="normal-maximum=\"1\"/>",
      new="normal-maximum=\"1\"><qti-default-value><qti-value>9</qti-value></qti-default-value></qti-outcome-declaration>",
    ),
  )
  let gate = flow_test_pre(
    "<qti-equal><qti-variable identifier=\"A.SCORE\"/><qti-base-value base-type=\"float\">9</qti-base-value></qti-equal>",
  )
  let source = test_plan_source(
    flow_test_part(
      "P",
      flow_test_section(
        "S",
        flow_test_ref("A", content=gate) +
        flow_test_ref("B", content=flow_test_pre(flow_test_bool(false))),
      ),
    ),
  )
  let plan = @qti.compile_assessment_test(source, { "items/a.xml": item })
  let session = plan.new_session("defaults")
  flow_test_current(session, "A")
  flow_test_answer(session, 1)
  ignore(flow_test_action(session, "next", 3))
  let report = session.report("2026-10-30T12:00:00Z")
  assert_true(
    report
    is {
      "items": [
        { "outcomes": { "SCORE": 1, .. }, "num_attempts": 1, .. },
        {
          "outcomes": { "SCORE": 9, .. },
          "num_attempts": 0,
          "session_status": "initial",
          ..
        },
      ],
      ..
    },
  )
  assert_eq(
    report,
    plan.restore_session(session.snapshot()).report("2026-10-30T12:00:00Z"),
  )
  let changed = @qti.compile_assessment_test(source, {
    "items/a.xml": @qti.compile_assessment_item(fixture("single")),
  })
  assert_false(changed.identity() == plan.identity())
}
