///|
fn instruction_scope_node(content : String) -> Node raise QtiError {
  parse_document(
    "<qti-test-part xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\" identifier=\"part\" navigation-mode=\"linear\" submission-mode=\"individual\">\{content}</qti-test-part>",
    Limits::default(),
  )
}

///|
fn instruction_rubric(content : String) -> String {
  "<qti-rubric-block view=\"candidate\" use=\"instructions\"><qti-content-body>\{content}</qti-content-body></qti-rubric-block>"
}

///|
test "test scope instructions combine direct safe blocks in document order" {
  let node = instruction_scope_node(
    instruction_rubric(
      "<p>先<strong>阅读</strong>说明。<br/>再作答。</p>",
    ) +
    "<qti-assessment-section identifier=\"nested\" title=\"Nested\" visible=\"true\">\{instruction_rubric("<p>Nested instructions</p>")}</qti-assessment-section>" +
    instruction_rubric(
      "<p>One &amp; two.</p><ul><li>First</li><li>Second</li></ul>",
    ),
  )
  let result = test_scope_instructions(node, "part", "Part title", scope="part")
  assert_true(
    result
    is [
      {
        "scope": String("part"),
        "scope_identifier": String("part"),
        "title": String("Part title"),
        "text": String(
          "先阅读说明。\n再作答。\n\nOne & two.\nFirst\nSecond"
        ),
        ..
      },
    ],
  )
}

///|
test "empty scope instructions are omitted and text entities remain literal" {
  assert_eq(
    test_scope_instructions(instruction_scope_node(""), "p", "P", scope="part"),
    [],
  )
  assert_eq(
    test_scope_instructions(
      instruction_scope_node(instruction_rubric(" <p> </p> ")),
      "s",
      "S",
      scope="section",
    ),
    [],
  )
  let result = test_scope_instructions(
    instruction_scope_node(
      instruction_rubric("<p>&lt;script&gt; &amp; text</p>"),
    ),
    "s",
    "S",
    scope="section",
  )
  assert_true(result is [{ "text": String("<script> & text"), .. }])
}

///|
test "test scope instructions reject active nested foreign and extended content" {
  for
    rubric in [
      "<qti-rubric-block view=\"candidate\" use=\"rubric\"><qti-content-body/></qti-rubric-block>",
      "<qti-rubric-block view=\"candidate\" use=\"ext:custom\"><qti-content-body/></qti-rubric-block>",
      instruction_rubric("<script>alert(1)</script>"),
      instruction_rubric("<p onclick=\"run()\">Text</p>"),
      instruction_rubric("<img src=\"https://example.org/a.png\"/>"),
      instruction_rubric("<x:p xmlns:x=\"urn:foreign\">Text</x:p>"),
      instruction_rubric("<qti-printed-variable identifier=\"SECRET\"/>"),
      instruction_rubric(instruction_rubric("<p>Nested</p>")),
      "<qti-rubric-block xmlns=\"urn:foreign\" view=\"candidate\" use=\"instructions\"><qti-content-body/></qti-rubric-block>",
    ] {
    let node = instruction_scope_node(rubric)
    try test_scope_instructions(node, "part", "Part", scope="part") catch {
      error => assert_eq(error.code(), "unsupported")
    } noraise {
      _ => fail("expected unsupported rubric content")
    }
  }
}

///|
test "test rubric views filter other actors and accept optional standard uses" {
  let source = "<qti-rubric-block view=\"candidate author\"><qti-content-body><p>Candidate text</p></qti-content-body></qti-rubric-block>"
  for
    suffix in [
      "", " use=\"instructions\"", " use=\"navigation\"", " use=\"scoring\"",
    ] {
    let node = instruction_scope_node(
      source.replace_all(
        old="view=\"candidate author\"",
        new="view=\"candidate author\"\{suffix}",
      ),
    )
    assert_true(
      test_scope_instructions(node, "test", "Test", scope="test")
      is [{ "scope": String("test"), "text": String("Candidate text"), .. }],
    )
  }
  let other = instruction_scope_node(
    "<qti-rubric-block view=\"scorer proctor\"><qti-content-body><p>Private scorer text</p></qti-content-body></qti-rubric-block>",
  )
  assert_eq(test_scope_instructions(other, "p", "P", scope="part"), [])
  let whitespace = instruction_scope_node(
    source.replace_all(
      old="candidate author",
      new=" author&#9;candidate&#10;tutor ",
    ),
  )
  assert_eq(
    test_scope_instructions(whitespace, "p", "P", scope="part").length(),
    1,
  )
}

///|
test "test scope instructions require one explicit content body" {
  for
    rubric in [
      "<qti-rubric-block view=\"candidate\" use=\"instructions\"/>", "<qti-rubric-block view=\"candidate\" use=\"instructions\"><qti-content-body/><qti-content-body/></qti-rubric-block>",
      "<qti-rubric-block use=\"instructions\"><qti-content-body/></qti-rubric-block>",
      "<qti-rubric-block view=\" \" use=\"instructions\"><qti-content-body/></qti-rubric-block>",
      "<qti-rubric-block view=\"candidate unknown\" use=\"instructions\"><qti-content-body/></qti-rubric-block>",
    ] {
    let node = instruction_scope_node(rubric)
    try test_scope_instructions(node, "part", "Part", scope="part") catch {
      error => assert_eq(error.code(), "invalid_item")
    } noraise {
      _ => fail("expected malformed rubric rejection")
    }
  }
}
