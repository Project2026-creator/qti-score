///|
fn fixture(name : String) -> String raise {
  @fs.read_file_to_string("examples/\{name}.xml")
}

///|
fn String::swap(self : String, old : String, new : String) -> String raise {
  assert_true(self.contains(old))
  self.replace_all(old=old[:], new=new[:])
}

///|
test "single choice correct, wrong and unknown selections" {
  let item = @qti.compile_item(fixture("single"))
  assert_eq(item.score(Single("A")).score, 1.0)
  assert_eq(item.score(Single("B")).score, 0.0)
  assert_eq(item.score(Single("A")).matches_correct, Some(true))
  try item.score(Single("missing")) catch {
    e => assert_eq(e.code(), "invalid_response")
  } noraise {
    _ => fail("expected unknown choice rejection")
  }
}

///|
test "NULL is distinct from a wrong answer" {
  let item = @qti.compile_item(fixture("single"))
  assert_eq(item.score(Null).status, Unanswered)
  assert_eq(item.score(Single("")).status, Unanswered)
  assert_eq(item.score(Single("B")).status, Answered)
  assert_eq(item.score(Null).score, 0.0)
}

///|
test "map_response partial credit, penalty and omitted default keys" {
  let item = @qti.compile_item(fixture("multiple"))
  assert_eq(item.score(Multiple(["A"])).score, 1.0)
  assert_eq(item.score(Multiple(["C", "A"])).score, 2.0)
  assert_eq(item.score(Multiple(["A", "B"])).score, 0.0)
  assert_eq(item.score(Multiple(["A", "D"])).score, 0.0)
  assert_eq(item.score(Multiple(["A", "C"])).matches_correct, Some(true))
}

///|
test "mapping counts each duplicate input value only once" {
  let item = @qti.compile_item(fixture("multiple"))
  assert_eq(item.score(Multiple(["A", "A"])).score, 1.0)
  assert_eq(item.score(Multiple(["A", "A", "C"])).score, 2.0)
  assert_eq(item.score(Multiple(["A", "A", "C"])).matches_correct, Some(false))
}

///|
test "multiple match is unordered bag equality, not set equality" {
  let source = fixture("multiple").swap("map_response.xml", "match_correct.xml")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Multiple(["C", "A"])).score, 1.0)
  assert_eq(item.score(Multiple(["A", "A", "C"])).score, 0.0)
  assert_eq(item.score(Multiple(["A"])).score, 0.0)
}

///|
test "mapping bounds apply after summing, not to each entry" {
  let source = fixture("multiple").swap(
    "upper-bound=\"2\"", "upper-bound=\"1.5\"",
  )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Multiple(["A", "C"])).score, 1.5)
  assert_eq(item.score(Multiple(["B"])).score, 0.0)
}

///|
test "NULL bypasses even a positive mapping lower bound" {
  let source = fixture("multiple").swap(
    "lower-bound=\"0\"", "lower-bound=\"0.5\"",
  )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Null).score, 0.0)
  assert_eq(item.score(Multiple([])).score, 0.0)
  assert_eq(item.score(Multiple(["B"])).score, 0.5)
}

///|
test "text mapping uses authored case sensitivity and preserves whitespace" {
  let item = @qti.compile_item(fixture("text"))
  assert_eq(item.score(Single("LMS")).score, 1.0)
  assert_eq(item.score(Single("lms")).score, 0.5)
  assert_eq(item.score(Single("LmS")).score, 0.5)
  assert_eq(item.score(Single(" LMS ")).score, 0.0)
  assert_eq(item.score(Single("学习管理系统")).score, 1.0)
  assert_eq(item.score(Single("lms")).matches_correct, Some(false))
}

///|
test "Unicode case folding handles expansions and non-Latin letters" {
  let source = fixture("text").swap("map-key=\"lms\"", "map-key=\"Straße\"")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Single("STRASSE")).score, 0.5)
  let greek = @qti.compile_item(source.swap("Straße", "Σ"))
  assert_eq(greek.score(Single("ς")).score, 0.5)
  assert_eq(greek.score(Single("σ")).score, 0.5)
}

///|
test "identifier mappings remain case sensitive" {
  let source = fixture("multiple").swap("identifier=\"D\"", "identifier=\"a\"")
  let item = @qti.compile_item(source)
  assert_eq(item.score(Multiple(["a"])).score, 0.0)
}

///|
test "wrong response shapes and NULL container members are rejected" {
  let single = @qti.compile_item(fixture("single"))
  let multiple = @qti.compile_item(fixture("multiple"))
  let single_errors : Array[@qti.Response] = [Multiple(["A"]), Multiple([])]
  for response in single_errors {
    try single.score(response) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected single cardinality rejection")
    }
  }
  let multiple_errors : Array[@qti.Response] = [Single("A"), Multiple([""])]
  for response in multiple_errors {
    try multiple.score(response) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected multiple cardinality rejection")
    }
  }
}

///|
test "selection limits are checked for nonempty attempts" {
  let source = fixture("multiple").swap(
    "max-choices=\"0\"", "min-choices=\"2\" max-choices=\"2\"",
  )
  let item = @qti.compile_item(source)
  for values in [["A"], ["A", "B", "C"]] {
    try item.score(Multiple(values)) catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("expected selection limit rejection")
    }
  }
  assert_eq(item.score(Null).score, 0.0)
}

///|
test "correct response is optional for mapping and has no invented truth value" {
  let source = fixture("multiple").swap(
    "<qti-correct-response><qti-value>A</qti-value><qti-value>C</qti-value></qti-correct-response>",
    "",
  )
  let item = @qti.compile_item(source)
  assert_eq(item.score(Multiple(["A"])).matches_correct, None)
  assert_eq(item.score(Null).matches_correct, None)
  assert_eq(item.score(Multiple(["A"])).score, 1.0)
}

///|
test "compiled items expose defensive copies" {
  let item = @qti.compile_item(fixture("single"))
  item.choices().clear()
  item.correct_response().unwrap().clear()
  assert_eq(item.choices().length(), 3)
  assert_eq(item.score(Single("A")).score, 1.0)
}

///|
test "normal-maximum is metadata and does not rescale match_correct" {
  let item = @qti.compile_item(
    fixture("single").swap("normal-maximum=\"1\"", "normal-maximum=\"100\""),
  )
  assert_eq(item.score(Single("A")).score, 1.0)
}
