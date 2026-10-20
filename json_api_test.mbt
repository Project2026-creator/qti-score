///|
test "JSON score output has primitive booleans and null, not Option encoding" {
  let item = @qti.compile_item(fixture("single"))
  let result = item.score_json("{\"RESPONSE\":\"A\"}").to_json()
  assert_eq(result, {
    "score": 1,
    "status": "answered",
    "matches_correct": true,
  })
  assert_eq(item.score_json("{}").score, 0.0)
  assert_eq(item.score_json("{\"RESPONSE\":null}").status, Unanswered)
}

///|
test "malformed JSON, duplicate keys and unknown response IDs are rejected" {
  let item = @qti.compile_item(fixture("single"))
  for
    input in [
      "{", "[]", "{\"RESPONSE\":true}", "{\"OTHER\":\"A\"}", "{\"RESPONSE\":\"A\",\"RESPONSE\":\"B\"}",
      "{\"RESPONSE\":[1]}",
    ] {
    try item.score_json(input) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected invalid response JSON")
    }
  }
}

///|
test "JSON host boundary returns structured errors without throwing" {
  let text = @qti.evaluate_json("<bad/>", "{}")
  let output = @json.parse(text[:])
  guard output is { "ok": False, "error": { "code": String(code), .. }, .. } else {
    fail("expected error envelope")
  }
  assert_eq(code, "unsupported")
}

///|
test "JSON host and typed API score the same attempt" {
  let text = @qti.evaluate_json(fixture("text"), "{\"RESPONSE\":\"lms\"}")
  let output = @json.parse(text[:])
  guard output
    is { "ok": True, "result": { "score": Number(score, ..), .. }, .. } else {
    fail("expected scoring envelope")
  }
  assert_eq(score, 0.5)
}

///|
test "describe returns metadata without exposing correct responses" {
  let output = @qti.describe_json(fixture("multiple"))
  assert_true(!output.contains("correct_response"))
  assert_true(!output.contains("map-key"))
  assert_true(output.contains("feedback"))
}
