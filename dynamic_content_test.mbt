///|
fn printed_item(
  base : String,
  cardinality : String,
  values : String,
  attrs : String,
) -> @qti.AssessmentItem raise @qti.QtiError {
  let defaults = if values == "" {
    ""
  } else {
    "<qti-default-value>\{values}</qti-default-value>"
  }
  @qti.compile_assessment_item(
    "<qti-assessment-item xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"print\" title=\"Print\"><qti-response-declaration identifier=\"RESPONSE\" cardinality=\"single\" base-type=\"identifier\"><qti-correct-response><qti-value>A</qti-value></qti-correct-response></qti-response-declaration><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-outcome-declaration identifier=\"VALUE\" cardinality=\"\{cardinality}\" base-type=\"\{base}\">\{defaults}</qti-outcome-declaration><qti-outcome-declaration identifier=\"NOTICE\" cardinality=\"single\" base-type=\"identifier\"><qti-default-value><qti-value>shown</qti-value></qti-default-value></qti-outcome-declaration><qti-item-body><qti-choice-interaction response-identifier=\"RESPONSE\" max-choices=\"1\"><qti-simple-choice identifier=\"A\">A</qti-simple-choice><qti-simple-choice identifier=\"B\">B</qti-simple-choice></qti-choice-interaction></qti-item-body><qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct\"/><qti-modal-feedback identifier=\"shown\" outcome-identifier=\"NOTICE\" show-hide=\"show\"><qti-content-body><p>BEGIN<qti-printed-variable identifier=\"VALUE\" \{attrs}/>END</p></qti-content-body></qti-modal-feedback></qti-assessment-item>",
  )
}

///|
fn printed_text(
  base : String,
  cardinality : String,
  values : String,
  attrs : String,
) -> String raise {
  let item = printed_item(base, cardinality, values, attrs)
  guard item.feedback_json("{}") is Array(messages) &&
    messages[0] is { "text": String(text), .. } else {
    fail("printed feedback missing")
  }
  text
}

///|
test "printed strings boolean pairs containers and NULL remain plain data" {
  assert_eq(
    printed_text(
      "string", "single", "<qti-value>&lt;script&gt; &amp; 中文 😀</qti-value>",
      "",
    ),
    "BEGIN<script> & 中文 😀END",
  )
  assert_eq(printed_text("string", "single", "", ""), "BEGINEND")
  assert_eq(
    printed_text("boolean", "single", "<qti-value>false</qti-value>", ""),
    "BEGINfalseEND",
  )
  assert_eq(
    printed_text("pair", "single", "<qti-value>Z A</qti-value>", ""),
    "BEGINA ZEND",
  )
  let values = "<qti-value>One</qti-value><qti-value>Two</qti-value>"
  assert_eq(
    printed_text("identifier", "multiple", values, ""),
    "BEGINOne;TwoEND",
  )
  assert_eq(
    printed_text("identifier", "ordered", values, "delimiter=\" &amp; \""),
    "BEGINOne & TwoEND",
  )
  assert_eq(
    printed_text("identifier", "ordered", values, "index=\"2\""),
    "BEGINTwoEND",
  )
  assert_eq(
    printed_text("identifier", "ordered", values, "index=\"3\""),
    "BEGINEND",
  )
}

///|
test "printed decimal formatting rounds the exact binary value with even ties" {
  for
    (value, places, expected) in [
      ("1.005", "2", "1.00"),
      ("2.675", "2", "2.67"),
      ("2.5", "0", "2"),
      ("3.5", "0", "4"),
      ("-2.5", "0", "-2"),
      ("-0.0001", "2", "-0.00"),
      ("0.1", "6", "0.100000"),
      ("5e-324", "12", "0.000000000000"),
      ("999.999", "2", "1000.00"),
    ] {
    assert_eq(
      printed_text(
        "float",
        "single",
        "<qti-value>\{value}</qti-value>",
        "format=\"%.\{places}f\"",
      ),
      "BEGIN\{expected}END",
    )
  }
  assert_eq(
    printed_text(
      "float", "single", "<qti-value>0.5</qti-value>", "format=\"%f\"",
    ),
    "BEGIN0.500000END",
  )
  let large = printed_text(
    "float", "single", "<qti-value>1.7976931348623157e308</qti-value>", "format=\"%.2f\"",
  )
  assert_true(
    large.length() > 310 && large.has_suffix(".00END") && !large.contains("inf"),
  )
}

///|
test "printed integers support decimal and explicit bases without unsafe conversion" {
  assert_eq(
    printed_text(
      "integer", "single", "<qti-value>255</qti-value>", "format=\"%i\" base=\"16\"",
    ),
    "BEGINffEND",
  )
  assert_eq(
    printed_text(
      "integer", "single", "<qti-value>-255</qti-value>", "format=\"%i\" base=\"16\"",
    ),
    "BEGIN-ffEND",
  )
  assert_eq(
    printed_text(
      "integer", "single", "<qti-value>5</qti-value>", "format=\"%i\" base=\"2\"",
    ),
    "BEGIN101END",
  )
  assert_eq(
    printed_text(
      "integer", "single", "<qti-value>9007199254740991</qti-value>", "format=\"%d\"",
    ),
    "BEGIN9007199254740991END",
  )
}

///|
test "printed variables reject invalid selectors and unsupported formats" {
  for
    (base, cardinality, attrs) in [
      ("float", "single", "format=\"%d\""),
      ("identifier", "multiple", "index=\"1\""),
      ("identifier", "ordered", "index=\"0\""),
      ("identifier", "single", "format=\"%.2f\""),
    ] {
    try printed_item(base, cardinality, "", attrs) catch {
      error => assert_eq(error.code(), "invalid_item")
    } noraise {
      _ => fail("invalid printed variable accepted")
    }
  }
  for
    attrs in [
      "format=\"%.13f\"", "format=\"%08.2f\"", "format=\"%e\"", "power-form=\"true\"",
      "base=\"1\"", "field=\"NAME\"",
    ] {
    try printed_item("float", "single", "", attrs) catch {
      error => assert_eq(error.code(), "unsupported")
    } noraise {
      _ => fail("unsupported printed variable accepted")
    }
  }
}

///|
test "dynamic body reveals only selected nested feedback and updates option text" {
  let item = @qti.compile_assessment_item(fixture("dynamic-feedback"))
  let initial = item.describe().stringify()
  assert_true(initial.contains("本题满分"))
  assert_false(initial.contains("回答正确"))
  assert_false(initial.contains("关键步骤"))
  let correct = item.presentation_json("{\"RESPONSE\":\"Adjust\"}").stringify()
  assert_true(correct.contains("得到 2.0 分"))
  assert_true(correct.contains("收集证据 → 调整教学"))
  assert_false(correct.contains("请重新思考"))
  let retry = item.presentation_json("{\"RESPONSE\":\"Rank\"}").stringify()
  assert_true(retry.contains("请重新思考"))
  assert_true(retry.contains("本次得分：0.0 / 2.0"))
  assert_false(retry.contains("关键步骤"))
  assert_false(correct.contains("qti-content:"))
  assert_eq(item.describe().stringify(), initial)
}

///|
test "printed content cannot refer to responses undeclared variables or foreign namespaces" {
  for
    xml in [
      fixture("dynamic-feedback").swap(
        "qti-printed-variable identifier=\"MAXSCORE\"", "qti-printed-variable identifier=\"RESPONSE\"",
      ),
      fixture("dynamic-feedback").swap(
        "qti-printed-variable identifier=\"MAXSCORE\"", "qti-printed-variable identifier=\"UNKNOWN\"",
      ),
    ] {
    try @qti.compile_processed_item(xml) catch {
      error => assert_eq(error.code(), "invalid_item")
    } noraise {
      _ => fail("invalid variable reference accepted")
    }
  }
  let foreign = fixture("dynamic-feedback").swap(
    "<qti-printed-variable", "<qti-printed-variable xmlns=\"urn:foreign\"",
  )
  try @qti.compile_processed_item(foreign) catch {
    error => assert_eq(error.code(), "unsupported")
  } noraise {
    _ => fail("foreign content accepted")
  }
}

///|
test "non adaptive feedback forbids nested interactions and block content in inline feedback" {
  for
    fragment in [
      "<qti-feedback-block identifier=\"correct\" outcome-identifier=\"NOTICE\"><qti-content-body><p>Hidden</p></qti-content-body></qti-feedback-block>",
      "<qti-text-entry-interaction response-identifier=\"RESPONSE\"/>",
    ] {
    let xml = fixture("dynamic-feedback").swap(
      " —— 回答正确，得到 ", fragment,
    )
    try @qti.compile_processed_item(xml) catch {
      error => assert_eq(error.code(), "invalid_item")
    } noraise {
      _ => fail("invalid feedback content accepted")
    }
  }
}

///|
test "dynamic session presents the last accepted outcomes while drafts remain unprocessed" {
  let xml = test_plan_source(
    test_plan_part(
      "<qti-item-session-control max-attempts=\"2\" show-feedback=\"true\"/>" +
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"D\" href=\"items/dynamic.xml\"/>",
      ),
    ),
  )
  let plan = @qti.compile_assessment_test(xml, {
    "items/dynamic.xml": @qti.compile_assessment_item(
      fixture("dynamic-feedback"),
    ),
  })
  let session = plan.new_session("dynamic-drafts")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"Adjust\"}}",
    ),
  )
  assert_false(session.describe().stringify().contains("回答正确"))
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  assert_true(session.describe().stringify().contains("得到 2.0 分"))
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":3,\"response\":{\"RESPONSE\":\"Rank\"}}",
    ),
  )
  assert_true(session.describe().stringify().contains("得到 2.0 分"))
  let restored = plan.restore_session(session.snapshot())
  assert_eq(restored.describe(), session.describe())
  ignore(restored.act_json("{\"type\":\"submit\",\"time\":4}"))
  assert_true(restored.describe().stringify().contains("请重新思考"))
  assert_false(restored.describe().stringify().contains("回答正确"))
}

///|
test "test and frozen part feedback print accepted values" {
  let first = test_feedback_part(
    "P",
    "A",
    test_feedback_block(
      "ready",
      "Part <qti-printed-variable identifier=\"SCORE\" format=\"%.1f\"/>",
      access="atEnd",
    ),
  )
  let second = test_feedback_part("Q", "B", "")
  let rules = test_feedback_set("ready") +
    "<qti-set-outcome-value identifier=\"SCORE\"><qti-sum><qti-test-variables variable-identifier=\"SCORE\" base-type=\"float\"/></qti-sum></qti-set-outcome-value>"
  let end_feedback = test_feedback_block(
    "ready",
    "Final <qti-printed-variable identifier=\"SCORE\" format=\"%.1f\"/> accepted",
    access="atEnd",
  )
  let plan = test_feedback_plan(
    first + second,
    rules~,
    feedback=end_feedback,
    declaration=test_feedback_declaration() +
      "<qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/>",
  )
  let session = plan.new_session("frozen-printed")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  ignore(session.act_json("{\"type\":\"finish_part\",\"time\":3}"))
  let before = session.describe().stringify()
  assert_true(before.contains("Part 1.0"))
  let restored = plan.restore_session(session.snapshot())
  ignore(
    restored.act_json(
      "{\"type\":\"save\",\"time\":4,\"response\":{\"RESPONSE\":\"A\"}}",
    ),
  )
  ignore(restored.act_json("{\"type\":\"submit\",\"time\":5}"))
  ignore(restored.act_json("{\"type\":\"finish_part\",\"time\":6}"))
  let after = restored.describe().stringify()
  assert_true(after.contains("Part 1.0"))
  assert_true(after.contains("Final 2.0 accepted"))
}

///|
test "item feedback control hides dynamic option hints and modal feedback together" {
  let xml = test_plan_source(
    test_plan_part(
      "<qti-item-session-control show-feedback=\"false\"/>" +
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"D\" href=\"items/dynamic.xml\"/>",
      ),
    ),
  )
  let plan = @qti.compile_assessment_test(xml, {
    "items/dynamic.xml": @qti.compile_assessment_item(
      fixture("dynamic-feedback"),
    ),
  })
  let session = plan.new_session("no-dynamic-feedback")
  ignore(
    session.act_json(
      "{\"type\":\"save\",\"time\":1,\"response\":{\"RESPONSE\":\"Adjust\"}}",
    ),
  )
  ignore(session.act_json("{\"type\":\"submit\",\"time\":2}"))
  let state = session.describe()
  assert_false(state.stringify().contains("回答正确"))
  assert_false(state.stringify().contains("关键步骤"))
  assert_true(
    state
    is { "current": { "feedback": Array(messages), "result": Null, .. }, .. } &&
    messages.is_empty(),
  )
}

///|
test "printed strings cannot trigger another dynamic fragment expansion" {
  let item = @qti.compile_assessment_item(
    fixture("dynamic-feedback").swap(
      "<qti-value>收集证据</qti-value>", "<qti-value>\u{e000}qti-content:0\u{e001}</qti-value>",
    ),
  )
  let presentation = item.presentation_json("{\"RESPONSE\":\"Adjust\"}")
  assert_true(presentation.stringify().contains("qti-content:0"))
}

///|
test "oversized printed content has an explicit marker and preserves Unicode boundaries" {
  let value = StringBuilder()
  for _ in 0..<32768 {
    value.write_string("😀")
  }
  let rendered = printed_text(
    "string",
    "single",
    "<qti-value>\{value.to_string()}</qti-value>",
    "",
  )
  assert_true(rendered.length() <= 65536)
  assert_true(rendered.has_suffix("…[content limit]"))
  assert_false(rendered.contains("\u{fffd}"))
}
