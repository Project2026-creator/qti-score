///|
fn rejected(xml : String, code : String) -> Unit raise {
  try @qti.compile_item(xml) catch {
    e => assert_eq(e.code(), code)
  } noraise {
    _ => fail("expected \{code}")
  }
}

///|
test "default and prefixed QTI namespaces compile equivalently" {
  let source = fixture("single")
  let prefixed = source
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
  let a = @qti.compile_item(source)
  let b = @qti.compile_item(prefixed)
  assert_eq(a.describe(), b.describe())
  assert_eq(a.score(Single("A")), b.score(Single("A")))
}

///|
test "XML entities, CDATA and mixed text retain their content" {
  let source = fixture("text")
    .swap(
      "<qti-value>LMS</qti-value>", "<qti-value><![CDATA[A & B]]></qti-value>",
    )
    .swap("map-key=\"LMS\"", "map-key=\"A &amp; B\"")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Single("A & B")).score, 1.0)
  assert_eq(item.score(Single("A & B")).matches_correct, Some(true))
}

///|
test "malformed XML carries a one-based source location" {
  try @qti.compile_item("<bad>\n</other>") catch {
    @qti.InvalidXml(_, line, column) => {
      assert_true(line >= 1)
      assert_true(column >= 1)
    }
    _ => fail("expected XML diagnostic")
  } noraise {
    _ => fail("expected malformed XML rejection")
  }
}

///|
test "wrong namespaces and QTI 2 documents are rejected" {
  rejected(
    fixture("single").swap("imsqtiasi_v3p0", "imsqti_v2p2"),
    "unsupported",
  )
  rejected(
    fixture("single").swap(
      " xmlns=\"http://www.imsglobal.org/xsd/imsqtiasi_v3p0\"", "",
    ),
    "unsupported",
  )
}

///|
test "a fake QTI interaction in XHTML namespace is rejected" {
  rejected(
    fixture("single").swap(
      "<qti-choice-interaction ", "<qti-choice-interaction xmlns=\"http://www.w3.org/1999/xhtml\" ",
    ),
    "unsupported",
  )
}

///|
test "duplicate declarations are not silently chosen" {
  let source = fixture("single").swap(
    "<qti-item-body>", "<qti-outcome-declaration identifier=\"OTHER\" cardinality=\"single\" base-type=\"float\"/><qti-item-body>",
  )
  rejected(source, "invalid_item")
}

///|
test "inline response processing cannot be ignored behind a template" {
  let source = fixture("single").swap(
    "match_correct.xml\"/>", "match_correct.xml\"><qti-response-condition/></qti-response-processing>",
  )
  rejected(source, "unsupported")
}

///|
test "template URLs use exact allowlist matching" {
  rejected(
    fixture("single").swap(
      "https://purl.imsglobal.org/", "https://example.org/",
    ),
    "unsupported",
  )
  let legacy = fixture("single").swap(
    "https://purl.imsglobal.org/spec/qti/v3p0/", "https://www.imsglobal.org/question/qti_v3p0/",
  )
  assert_eq(@qti.compile_item(legacy).score(Single("A")).score, 1.0)
  let extensionless = fixture("single").swap(
    "match_correct.xml", "match_correct",
  )
  assert_eq(@qti.compile_item(extensionless).score(Single("A")).score, 1.0)
}

///|
test "templates require RESPONSE and float SCORE" {
  rejected(
    fixture("single").swap("identifier=\"RESPONSE\"", "identifier=\"OTHER\""),
    "unsupported",
  )
  rejected(
    fixture("single").swap("identifier=\"SCORE\"", "identifier=\"RESULT\""),
    "unsupported",
  )
  rejected(
    fixture("single").swap("base-type=\"float\"", "base-type=\"integer\""),
    "unsupported",
  )
}

///|
test "unsupported cardinalities, invalid numeric declarations and custom interactions fail closed" {
  rejected(
    fixture("single").swap("cardinality=\"single\"", "cardinality=\"record\""),
    "unsupported",
  )
  rejected(
    fixture("text").swap("base-type=\"string\"", "base-type=\"float\""),
    "invalid_item",
  )
  rejected(
    fixture("single").swap("qti-choice-interaction", "qti-custom-interaction"),
    "unsupported",
  )
}

///|
test "adaptive flags, template processing and extra scoring attributes are rejected" {
  rejected(
    fixture("single").swap("adaptive=\"false\"", "adaptive=\"true\""),
    "unsupported",
  )
  rejected(
    fixture("single").swap(
      "<qti-item-body>", "<qti-template-processing/><qti-item-body>",
    ),
    "unsupported",
  )
  rejected(
    fixture("single").swap(
      "base-type=\"identifier\"", "base-type=\"identifier\" weight=\"2\"",
    ),
    "unsupported",
  )
}

///|
test "missing correct answer and missing mapping are rejected" {
  rejected(
    fixture("single").swap(
      "<qti-correct-response><qti-value>A</qti-value></qti-correct-response>", "",
    ),
    "invalid_item",
  )
  rejected(
    fixture("single").swap("match_correct.xml", "map_response.xml"),
    "invalid_item",
  )
}

///|
test "non-finite numbers, invalid bounds and duplicate map keys are rejected" {
  for bad in ["NaN", "Infinity", "1e999", "1_000"] {
    rejected(
      fixture("multiple").swap("upper-bound=\"2\"", "upper-bound=\"\{bad}\""),
      "invalid_item",
    )
  }
  rejected(
    fixture("multiple").swap("lower-bound=\"0\"", "lower-bound=\"3\""),
    "invalid_item",
  )
  rejected(
    fixture("multiple").swap("map-key=\"B\"", "map-key=\"A\""),
    "invalid_item",
  )
}

///|
test "invalid choice bindings, duplicate IDs and unknown correct values are rejected" {
  rejected(
    fixture("single").swap(
      "response-identifier=\"RESPONSE\"", "response-identifier=\"OTHER\"",
    ),
    "invalid_item",
  )
  rejected(
    fixture("single").swap("identifier=\"B\"", "identifier=\"A\""),
    "invalid_item",
  )
  rejected(
    fixture("single").swap(
      "<qti-value>A</qti-value>", "<qti-value>UNKNOWN</qti-value>",
    ),
    "invalid_item",
  )
}

///|
test "mapping default-value defaults to zero" {
  let source = fixture("multiple").swap("default-value=\"-1\" ", "")
  assert_eq(@qti.compile_item(source).score(Multiple(["D"])).score, 0.0)
}

///|
test "DTD and non-XML processing instructions are outside the profile" {
  rejected(
    "<!DOCTYPE qti-assessment-item>" +
    fixture("single").swap("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", ""),
    "unsupported",
  )
  rejected(
    fixture("single").swap("<qti-item-body>", "<?engine run?><qti-item-body>"),
    "unsupported",
  )
}

///|
test "malformed attributes, multiple roots and trailing text are XML failures" {
  rejected(
    fixture("single").swap(
      "title=\"形成性评价\"", "title=\"x\" title=\"y\"",
    ),
    "invalid_xml",
  )
  rejected(fixture("single") + "<another/>", "invalid_xml")
  rejected(fixture("single") + "tail", "invalid_xml")
}

///|
test "custom resource budgets limit input before compiling" {
  let source = fixture("single")
  for
    limits in [
      @qti.Limits::{ max_characters: 20, max_depth: 128, max_elements: 30000, },
      @qti.Limits::{
        max_characters: 1048576,
        max_depth: 2,
        max_elements: 30000,
      },
      @qti.Limits::{ max_characters: 1048576, max_depth: 128, max_elements: 2, },
    ] {
    try @qti.compile_item(source, limits~) catch {
      e => assert_eq(e.code(), "limit_exceeded")
    } noraise {
      _ => fail("expected resource budget rejection")
    }
  }
}
