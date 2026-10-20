///|
test "numeric branches award exact, absolute and relative credit in authored order" {
  let item = @qti.compile_item(fixture("numeric"))
  for
    (value, expected) in [
      (100.0, 2.0),
      (99.0, 1.0),
      (101.0, 1.0),
      (95.0, 0.5),
      (105.0, 0.5),
      (94.99, 0.0),
      (106.0, 0.0),
    ] {
    let score = item.score(Number(value))
    assert_eq(score.score, expected)
    assert_eq(item.explain(Number(value)).result, score)
  }
  assert_eq(item.score(Number(100.5)).matches_correct, Some(false))
  assert_eq(item.score(Number(100.0)).matches_correct, Some(true))
}

///|
test "numeric text and JSON numbers share scoring but text is validated" {
  let item = @qti.compile_item(fixture("numeric"))
  assert_eq(item.score(Single(" +1.005e2 ")).score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":100.5}").score, 1.0)
  for input in ["NaN", "Infinity", "1e999", "1_00", "100 mm", "--1"] {
    try item.score(Single(input)) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected invalid numeric response")
    }
  }
  for value in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    try item.score(Number(value)) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected non-finite response rejection")
    }
  }
}

///|
test "numeric NULL is evaluated by authored rules and remains unanswered" {
  let source = fixture("numeric").swap(
    "<qti-base-value base-type=\"float\">0</qti-base-value>", "<qti-base-value base-type=\"float\">0.25</qti-base-value>",
  )
  let item = @qti.compile_item(source)
  for response in [@qti.Response::Null, Single(""), Single("  \t ")] {
    let score = item.score(response)
    assert_eq(score.score, 0.25)
    assert_eq(score.status, Unanswered)
    assert_eq(score.matches_correct, Some(false))
  }
}

///|
test "asymmetric tolerance uses the first expression as reference" {
  let source = fixture("numeric").swap("tolerance=\"1\"", "tolerance=\"2 3\"")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Number(98.0)).score, 1.0)
  assert_eq(item.score(Number(103.0)).score, 1.0)
  assert_eq(item.score(Number(97.9)).score, 0.5)
  assert_eq(item.score(Number(103.1)).score, 0.5)
  let reversed = @qti.compile_item(
    source
    .swap(
      "<qti-correct identifier=\"RESPONSE\"/><qti-variable identifier=\"RESPONSE\"/></qti-equal>",
      "<qti-variable identifier=\"RESPONSE\"/><qti-correct identifier=\"RESPONSE\"/></qti-equal>",
    )
    .swap("tolerance-mode=\"relative\"", "tolerance-mode=\"absolute\""),
  )
  assert_eq(reversed.score(Number(98.0)).score, 1.0)
  assert_eq(reversed.score(Number(103.0)).score, 0.5)
}

///|
test "numeric tolerance bounds can be exclusive" {
  let item = @qti.compile_item(
    fixture("numeric").swap(
      "tolerance=\"1\"", "tolerance=\"1\" include-lower-bound=\"false\" include-upper-bound=\"false\"",
    ),
  )
  assert_eq(item.score(Number(99.0)).score, 0.5)
  assert_eq(item.score(Number(101.0)).score, 0.5)
  assert_eq(item.score(Number(99.5)).score, 1.0)
}

///|
test "relative tolerance is a percentage of a fixed reference, not of the answer" {
  let item = @qti.compile_item(
    fixture("numeric").swap("tolerance=\"5\"", "tolerance=\"10 20\""),
  )
  assert_eq(item.score(Number(90.0)).score, 0.5)
  assert_eq(item.score(Number(120.0)).score, 0.5)
  assert_eq(item.score(Number(89.9)).score, 0.0)
  assert_eq(item.score(Number(120.1)).score, 0.0)
}

///|
test "integer matching compares numeric values within the safe integer range" {
  let item = @qti.compile_item(fixture("integer"))
  for response in [@qti.Response::Single("0042"), Single(" +42 "), Number(42.0)] {
    assert_eq(item.score(response).score, 1.0)
  }
  assert_eq(item.score_json("{\"RESPONSE\":42}").score, 1.0)
  for source_value in ["9007199254740991", "-9007199254740991"] {
    let edge = @qti.compile_item(
      fixture("integer").swap(
        "<qti-value>42</qti-value>",
        "<qti-value>\{source_value}</qti-value>",
      ),
    )
    assert_eq(edge.score(Single(source_value)).score, 1.0)
    assert_eq(edge.score_json("{\"RESPONSE\":\{source_value}}").score, 1.0)
  }
  for value in ["42.5", "4.2e1", "9007199254740992", "4503599627370496.5"] {
    try item.score(Single(value)) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected invalid integer")
    }
    try item.score_json("{\"RESPONSE\":\{value}}") catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected invalid JSON integer")
    }
  }
}

///|
test "numeric types, correct values and rules fail closed" {
  let source = fixture("numeric")
  for bad in ["NaN", "1e999", "1_00"] {
    rejected(
      source.swap("<qti-value>100</qti-value>", "<qti-value>\{bad}</qti-value>"),
      "invalid_item",
    )
  }
  rejected(source.swap("tolerance=\"1\"", "tolerance=\"0\""), "invalid_item")
  rejected(
    source.swap("tolerance=\"1\"", "tolerance=\"1 2 3\""),
    "invalid_item",
  )
  rejected(source.swap("tolerance=\"1\"", "tolerance=\"-1\""), "invalid_item")
  rejected(
    source.swap("tolerance-mode=\"absolute\"", "tolerance-mode=\"other\""),
    "invalid_item",
  )
  rejected(
    source.swap("<qti-equal>", "<qti-equal tolerance=\"1\">"),
    "unsupported",
  )
  rejected(source.swap("qti-is-null", "qti-not"), "unsupported")
  rejected(
    source.swap(
      "<qti-variable identifier=\"RESPONSE\"/>", "<qti-variable identifier=\"OTHER\"/>",
    ),
    "unsupported",
  )
  rejected(
    source.swap(
      "cardinality=\"single\" base-type=\"float\">", "cardinality=\"multiple\" base-type=\"float\">",
    ),
    "unsupported",
  )
}

///|
test "relative profile rejects a variable or negative reference at compilation" {
  let source = fixture("numeric")
  rejected(
    source.swap(
      "tolerance-mode=\"relative\" tolerance=\"5\"><qti-correct identifier=\"RESPONSE\"/>",
      "tolerance-mode=\"relative\" tolerance=\"5\"><qti-variable identifier=\"RESPONSE\"/>",
    ),
    "unsupported",
  )
  rejected(
    source.swap("<qti-value>100</qti-value>", "<qti-value>-100</qti-value>"),
    "unsupported",
  )
}

///|
test "literal numeric comparison works without a declared correct response" {
  let source = fixture("numeric")
    .swap(
      "<qti-correct-response><qti-value>100</qti-value></qti-correct-response>",
      "",
    )
    .swap(
      "<qti-correct identifier=\"RESPONSE\"/>", "<qti-base-value base-type=\"integer\">100</qti-base-value>",
    )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Number(100.0)).score, 2.0)
  assert_eq(item.score(Number(100.0)).matches_correct, None)
  assert_eq(item.score(Null).matches_correct, None)
  rejected(
    fixture("numeric").swap(
      "<qti-correct-response><qti-value>100</qti-value></qti-correct-response>",
      "",
    ),
    "invalid_item",
  )
}

///|
test "numeric rules require a final else and one literal SCORE per branch" {
  let source = fixture("numeric")
  rejected(
    source.swap("qti-response-else>", "qti-response-else-if>"),
    "invalid_item",
  )
  rejected(
    source.swap(
      "<qti-set-outcome-value identifier=\"SCORE\">", "<qti-set-outcome-value identifier=\"FEEDBACK\">",
    ),
    "unsupported",
  )
  rejected(
    source.swap(
      "<qti-base-value base-type=\"float\">2</qti-base-value>", "<qti-sum/>",
    ),
    "unsupported",
  )
  rejected(
    fixture("integer").swap("base-type=\"integer\"", "base-type=\"float\""),
    "unsupported",
  )
}

///|
test "absolute comparisons support negative references and zero is a valid reference" {
  let negative = @qti.compile_item(
    fixture("numeric")
    .swap("<qti-value>100</qti-value>", "<qti-value>-100</qti-value>")
    .swap("tolerance-mode=\"relative\"", "tolerance-mode=\"absolute\""),
  )
  assert_eq(negative.score(Number(-100.0)).score, 2.0)
  assert_eq(negative.score(Number(-99.5)).score, 1.0)
  assert_eq(negative.score(Number(-104.0)).score, 0.5)
  let zero = @qti.compile_item(
    fixture("numeric").swap(
      "<qti-value>100</qti-value>", "<qti-value>0</qti-value>",
    ),
  )
  assert_eq(zero.score(Number(-0.0)).score, 2.0)
  assert_eq(zero.score(Number(0.5)).score, 1.0)
  assert_eq(zero.score(Number(1.1)).score, 0.0)
}

///|
test "overflowing authored intervals fail compilation and response-dependent overflow fails scoring" {
  rejected(
    fixture("numeric")
    .swap("<qti-value>100</qti-value>", "<qti-value>1e308</qti-value>")
    .swap("tolerance=\"5\"", "tolerance=\"100\""),
    "invalid_item",
  )
  let dynamic = @qti.compile_item(
    fixture("numeric").swap(
      "tolerance-mode=\"absolute\" tolerance=\"1\"><qti-correct identifier=\"RESPONSE\"/><qti-variable identifier=\"RESPONSE\"/>",
      "tolerance-mode=\"absolute\" tolerance=\"1e308\"><qti-variable identifier=\"RESPONSE\"/><qti-correct identifier=\"RESPONSE\"/>",
    ),
  )
  try dynamic.score(Number(1.0e308)) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("expected response-dependent interval overflow")
  }
}
