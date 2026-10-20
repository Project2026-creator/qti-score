///|
test "explanations share the exact scoring path across existing item types" {
  for
    (name, responses) in [
      ("single", [@qti.Response::Single("A"), Single("B"), Null]),
      (
        "multiple",
        [Multiple(["A", "A", "C"]), Multiple(["B"]), Multiple(["D"]), Null],
      ),
      ("text", [Single("LMS"), Single("lms"), Single(" LMS "), Null]),
    ] {
    let item = @qti.compile_item(fixture(name))
    for response in responses {
      let explanation = item.explain(response)
      assert_eq(explanation.result, item.score(response))
      assert_true(explanation.steps.length() >= 2)
      assert_true(
        explanation.steps.all(s => s.location.line > 0 && s.location.column > 0),
      )
    }
  }
}

///|
test "mapping explanations expose duplicate skipping, default contribution and bounds" {
  let item = @qti.compile_item(fixture("multiple"))
  let explanation = item.explain(Multiple(["A", "A", "D"]))
  let operations = explanation.steps.map(s => s.operation)
  assert_true(operations.contains("duplicate_ignored"))
  assert_true(
    explanation.steps.any(s => {
      s.operation == "map_value" &&
      s.details
      is { "used_default": True, "contribution": Number(-1.0, ..), .. }
    }),
  )
  let bounds = item.explain(Multiple(["B"])).steps.last().unwrap()
  assert_eq(bounds.operation, "mapping_bounds")
  assert_true(
    bounds.details
    is {
      "adjusted": True,
      "raw_score": Number(-1.0, ..),
      "score": Number(0.0, ..),
      ..
    },
  )
  let empty = item.explain(Null)
  assert_eq(empty.steps.last().unwrap().operation, "null_response")
  assert_true(!empty.steps.any(s => s.operation == "mapping_bounds"))
}

///|
test "normal JSON output omits traces while explicit explanation agrees" {
  let source = fixture("numeric")
  let normal = @json.parse(@qti.evaluate_json(source, "{\"RESPONSE\":104}")[:])
  let diagnostic = @json.parse(
    @qti.explain_json(source, "{\"RESPONSE\":104}")[:],
  )
  assert_true(normal is { "steps"? : None, .. })
  guard normal is { "result": result, .. } else { fail("expected score") }
  guard diagnostic is { "result": explained, "steps": Array(steps), .. } else {
    fail("expected explanation")
  }
  assert_eq(result, explained)
  assert_true(steps.length() > 2)
  let item = @qti.compile_item(source)
  item.explain_json("{}").steps.clear()
  assert_true(item.explain_json("{}").steps.length() > 0)
}

///|
test "semantic compilation errors expose structured source positions" {
  let source = fixture("numeric").swap("tolerance=\"1\"", "tolerance=\"-1\"")
  try @qti.compile_item(source) catch {
    error => {
      assert_eq(error.code(), "invalid_item")
      let location = error.location().unwrap()
      assert_true(location.line > 1)
      assert_true(location.column > 0)
      assert_true(
        error.to_json()
        is {
          "location": { "line": Number(_, ..), "column": Number(_, ..), .. },
          ..
        },
      )
    }
  } noraise {
    _ => fail("expected tolerance error")
  }
}
