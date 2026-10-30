///|
fn test_plan_source(parts : String, attributes~ : String = "") -> String {
  "<qti-assessment-test xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"test\" title=\"Assessment\" \{attributes}>\{parts}</qti-assessment-test>"
}

///|
fn test_plan_part(
  content : String,
  id~ : String = "part",
  navigation~ : String = "linear",
  submission~ : String = "individual",
) -> String {
  "<qti-test-part identifier=\"\{id}\" navigation-mode=\"\{navigation}\" submission-mode=\"\{submission}\">\{content}</qti-test-part>"
}

///|
fn test_plan_section(content : String, id~ : String = "section") -> String {
  "<qti-assessment-section identifier=\"\{id}\" title=\"Section\" visible=\"true\">\{content}</qti-assessment-section>"
}

///|
fn test_plan_items() -> Map[String, @qti.AssessmentItem] raise {
  { "items/a.xml": @qti.compile_assessment_item(fixture("single")) }
}

///|
fn reject_test_plan(xml : String, code : String) -> Unit raise {
  let items = test_plan_items()
  try @qti.compile_assessment_test(xml, items) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("expected test-plan rejection")
  }
}

///|
test "test plan preserves parts nested sections and ordered references" {
  let a = "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/>"
  let b = "<qti-assessment-item-ref identifier=\"b\" href=\"items/a.xml\"/>"
  let xml = test_plan_source(
    test_plan_part(test_plan_section(a + test_plan_section(b, id="nested"))) +
    test_plan_part(
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"c\" href=\"items/a.xml\"/>",
        id="second",
      ),
      id="part2",
      navigation="nonlinear",
      submission="simultaneous",
    ),
  )
  let plan = @qti.compile_assessment_test(xml, test_plan_items())
  assert_eq(plan.identifier, "test")
  assert_eq(plan.title, "Assessment")
  assert_eq(plan.parts().length(), 2)
  assert_eq(plan.parts()[0].entry_count(), 2)
  assert_eq(plan.parts()[1].navigation_mode, @qti.NavigationMode::Nonlinear)
  assert_eq(plan.parts()[1].submission_mode, @qti.SubmissionMode::Simultaneous)
  assert_eq(plan.entries().map(e => e.identifier), ["a", "b", "c"])
  assert_eq(plan.entries().map(e => e.part_identifier), [
    "part", "part", "part2",
  ])
  assert_eq(plan.entries()[0].resource_id, "items/a.xml")
  let entries = plan.entries()
  entries.clear()
  let parts = plan.parts()
  parts.clear()
  assert_eq(plan.entries().length(), 3)
  assert_eq(plan.parts().length(), 2)
  let report = plan.describe().stringify()
  assert_false(report.contains("correct_response"))
  assert_false(report.contains("mapping"))
}

///|
test "test plan applies normative ISC defaults and attribute-wise inheritance" {
  let controls = "<qti-item-session-control max-attempts=\"3\" allow-review=\"false\" show-feedback=\"true\"/>"
  let section = test_plan_section(
    "<qti-item-session-control allow-skipping=\"false\"/><qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"><qti-item-session-control max-attempts=\"0\" validate-responses=\"true\"/></qti-assessment-item-ref>",
  )
  let plan = @qti.compile_assessment_test(
    test_plan_source(test_plan_part(controls + section)),
    test_plan_items(),
  )
  let control = plan.entries()[0].control
  assert_eq(control.max_attempts, 0)
  assert_false(control.allow_review)
  assert_true(control.show_feedback)
  assert_false(control.allow_skipping)
  assert_true(control.validate_responses)
  let defaults = @qti.ItemSessionControl::default()
  assert_eq(defaults.max_attempts, 1)
  assert_true(defaults.allow_review)
  assert_false(defaults.show_feedback)
  assert_true(defaults.allow_skipping)
  assert_false(defaults.validate_responses)
}

///|
test "test plan resolves xml base and bounded part time" {
  let xml = test_plan_source(
    test_plan_part(
      "<qti-time-limits max-time=\"90.5\"/>" +
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"a\" xml:base=\"../items/\" href=\"./a.xml\"/>",
      ),
    ),
    attributes="xml:base=\"tests/\"",
  )
  let plan = @qti.compile_assessment_test(xml, test_plan_items())
  assert_eq(plan.parts()[0].max_time, Some(90.5))
  assert_eq(plan.entries()[0].path, "items/a.xml")
}

///|
test "test plan rejects missing duplicate IDs invalid modes controls and references" {
  reject_test_plan(test_plan_source(""), "invalid_item")
  for
    (content, code) in [
      (
        "<qti-assessment-item-ref identifier=\"a\" href=\"missing.xml\"/>", "invalid_package",
      ),
      (
        "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/><qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/>",
        "invalid_item",
      ),
      (
        "<qti-assessment-item-ref identifier=\"a\" href=\"https://example.org/a.xml\"/>",
        "invalid_package",
      ),
      (
        "<qti-assessment-item-ref identifier=\"a\" href=\"../a.xml\"/>", "invalid_package",
      ),
      ("<qti-item-session-control max-attempts=\"-1\"/>", "invalid_item"),
      (
        "<qti-item-session-control max-attempts=\"9999999999999\"/>", "invalid_item",
      ),
      ("<qti-item-session-control allow-review=\"yes\"/>", "invalid_item"),
    ] {
    reject_test_plan(
      test_plan_source(test_plan_part(test_plan_section(content))),
      code,
    )
  }
  reject_test_plan(
    test_plan_source(test_plan_part(test_plan_section(""), navigation="random")),
    "invalid_item",
  )
  reject_test_plan(
    test_plan_source(
      test_plan_part(test_plan_section(""), submission="deferred"),
    ),
    "invalid_item",
  )
  reject_test_plan(
    test_plan_source(test_plan_part("<qti-time-limits max-time=\"-1\"/>")),
    "invalid_item",
  )
}

///|
test "test plan explicitly rejects unsupported flow and session features" {
  for
    extra in [
      "<qti-branch-rule target=\"EXIT_TEST\"/>", "<qti-pre-condition/>", "<qti-time-limits max-time=\"1\"/>",
      "<qti-item-session-control show-solution=\"true\"/>", "<qti-item-session-control allow-comment=\"true\"/>",
    ] {
    reject_test_plan(
      test_plan_source(test_plan_part(test_plan_section(extra))),
      "unsupported",
    )
  }
  reject_test_plan(
    test_plan_source(test_plan_part("<qti-time-limits min-time=\"1\"/>")),
    "unsupported",
  )
  reject_test_plan(
    test_plan_source(
      test_plan_part("<qti-time-limits allow-late-submission=\"true\"/>"),
    ),
    "unsupported",
  )
}

///|
test "test identity binds rules and is stable with fresh compilations" {
  let xml = test_plan_source(
    test_plan_part(
      test_plan_section(
        "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/>",
      ),
    ),
  )
  let first = @qti.compile_assessment_test(xml, test_plan_items())
  let same = @qti.compile_assessment_test(xml, test_plan_items())
  assert_eq(first.identity(), same.identity())
  let changed = fixture("single").replace_all(
    old="<qti-value>A</qti-value>"[:],
    new="<qti-value>B</qti-value>"[:],
  )
  let second = @qti.compile_assessment_test(xml, {
    "items/a.xml": @qti.compile_assessment_item(changed),
  })
  assert_false(first.identity() == second.identity())
  inspect(
    first.identity(),
    content=(
      #|qti-test-v2-10379208663322914227
    ),
  )
}

///|
fn test_plan_package(
  test_xml : String,
  section_xml : String,
  section2~ : String = "",
) -> @qti.ContentPackage raise {
  let section_resource = "<resource identifier=\"sec\" type=\"imsqti_section_xmlv3p0\" href=\"sections/s.xml\"><file href=\"sections/s.xml\"/></resource>"
  let section2_resource = if section2 == "" {
    ""
  } else {
    "<resource identifier=\"sec2\" type=\"imsqti_section_xmlv3p0\" href=\"sections/s2.xml\"><file href=\"sections/s2.xml\"/></resource>"
  }
  let xml = manifest(
    "<resource identifier=\"exam\" type=\"imsqti_test_xmlv3p0\" href=\"tests/t.xml\"><file href=\"tests/t.xml\"/></resource>" +
    section_resource +
    section2_resource +
    item_resource("item", "items/a.xml"),
  )
  let files = [
    ("imsmanifest.xml", xml),
    ("tests/t.xml", test_xml),
    ("sections/s.xml", section_xml),
    ("items/a.xml", fixture("single")),
  ]
  if section2 != "" {
    files.push(("sections/s2.xml", section2))
  }
  @qti.read_content_package(content_zip(files))
}

///|
test "package test compiles repeated external sections with distinct instance identifiers" {
  let source = test_plan_source(
    test_plan_part(
      "<qti-assessment-section-ref identifier=\"r1\" href=\"../sections/s.xml\"/><qti-assessment-section-ref identifier=\"r2\" href=\"../sections/s.xml\"/>",
    ),
  )
  let section = "<qti-assessment-section xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"s\" title=\"Section\" visible=\"true\"><qti-item-session-control max-attempts=\"2\"/><qti-assessment-item-ref identifier=\"a\" href=\"../items/a.xml\"/></qti-assessment-section>"
  let bundle = test_plan_package(source, section)
  let before = bundle.describe().stringify()
  let plan = bundle.compile_test("exam")
  assert_eq(plan.entries().map(e => e.identifier), ["r1.a", "r2.a"])
  assert_eq(plan.entries()[0].resource_id, "item")
  assert_eq(plan.entries()[0].control.max_attempts, 2)
  assert_eq(bundle.describe().stringify(), before)
  try bundle.compile_test("item") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("expected wrong resource kind")
  }
}

///|
test "package test rejects section reference cycles and missing or mismatched resources" {
  let source = test_plan_source(
    test_plan_part(
      "<qti-assessment-section-ref identifier=\"r\" href=\"../sections/s.xml\"/>",
    ),
  )
  let cyclic = "<qti-assessment-section xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"s\" title=\"Section\" visible=\"true\"><qti-assessment-section-ref identifier=\"r\" href=\"s2.xml\"/></qti-assessment-section>"
  let second = cyclic.replace_all(old="s2.xml"[:], new="s.xml"[:])
  let bundle = test_plan_package(source, cyclic, section2=second)
  try bundle.compile_test("exam") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("expected section cycle")
  }
  let wrong = source.replace_all(
    old="../sections/s.xml"[:],
    new="../items/a.xml"[:],
  )
  let wrong_bundle = test_plan_package(wrong, cyclic)
  try wrong_bundle.compile_test("exam") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("expected resource kind mismatch")
  }
  reject_test_plan(source, "invalid_package")
}

///|
test "test plan enforces supplied XML and expansion depth limits" {
  let xml = test_plan_source(
    test_plan_part(
      test_plan_section(
        test_plan_section(
          "<qti-assessment-item-ref identifier=\"a\" href=\"items/a.xml\"/>",
          id="nested",
        ),
      ),
    ),
  )
  let items = test_plan_items()
  try
    @qti.compile_assessment_test(xml, items, limits={
      max_characters: 100000,
      max_depth: 3,
      max_elements: 1000,
    })
  catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("expected XML depth limit")
  }
}

///|
test "test plan bounds expanded references to result reporting capacity" {
  let references = Array::makei(512, i => {
    "<qti-assessment-item-ref identifier=\"i\{i}\" href=\"items/a.xml\"/>"
  })
  let items = test_plan_items()
  let accepted = @qti.compile_assessment_test(
    test_plan_source(test_plan_part(test_plan_section(references.join("")))),
    items,
  )
  assert_eq(accepted.entries().length(), 512)
  references.push(
    "<qti-assessment-item-ref identifier=\"overflow\" href=\"items/a.xml\"/>",
  )
  try
    @qti.compile_assessment_test(
      test_plan_source(test_plan_part(test_plan_section(references.join("")))),
      items,
    )
  catch {
    e => assert_eq(e.code(), "limit_exceeded")
  } noraise {
    _ => fail("expected expanded reference limit")
  }
}
