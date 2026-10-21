///|
test "hottext weighted matching uses identifier selections without changing their input" {
  let item = @qti.compile_item(fixture("hottext"))
  let values = ["Support", "Evidence"]
  let result = item.score(Multiple(values))
  assert_eq(result.score, 2.0)
  assert_eq(result.matches_correct, Some(true))
  assert_eq(item.score(Multiple(["Evidence"])).score, 1.0)
  assert_eq(item.score(Multiple(["Evidence", "Ranking"])).score, 0.0)
  assert_eq(item.explain(Multiple(values)).result, result)
  assert_eq(values, ["Support", "Evidence"])
}

///|
test "single hottext defaults to maximum one and supports a sole visible choice" {
  let xml = fixture("hottext-single")
  let item = @qti.compile_item(xml)
  assert_eq(item.max_choices, 1)
  assert_eq(item.score(Single("Feedback")).score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":\"Final\"}").score, 0.0)
  let sole = @qti.compile_item(
    xml.swap(
      "<qti-hottext identifier=\"Final\">期末总分</qti-hottext>", "期末总分",
    ),
  )
  assert_eq(sole.choices().length(), 1)
  assert_eq(sole.score(Single("Feedback")).score, 1.0)
}

///|
test "hottext rejects unknown selections and incompatible typed containers" {
  let multiple = @qti.compile_item(fixture("hottext"))
  for
    response in [
      @qti.Response::Single("Evidence"),
      Ordered(["Evidence"]),
      Multiple(["Unknown"]),
      Number(1.0),
    ] {
    invalid_match(multiple, response)
  }
  let single = @qti.compile_item(fixture("hottext-single"))
  invalid_match(single, Multiple(["Feedback"]))
  invalid_match(single, Single("feedback"))
}

///|
test "hottext rejects duplicate selected and correct identifiers without changing ordinary multi-choice" {
  let item = @qti.compile_item(fixture("hottext"))
  invalid_match(item, Multiple(["Evidence", "Evidence"]))
  rejected(
    fixture("hottext").swap(
      "<qti-value>Support</qti-value>", "<qti-value>Evidence</qti-value>",
    ),
    "invalid_item",
  )
  assert_eq(
    @qti.compile_item(fixture("multiple")).score(Multiple(["A", "A"])).score,
    1.0,
  )
}

///|
test "hottext choice limits validate nonempty input and keep empty responses unanswered" {
  let source = fixture("hottext")
  let minimum = @qti.compile_item(
    source.swap("min-choices=\"1\"", "min-choices=\"2\""),
  )
  invalid_match(minimum, Multiple(["Evidence"]))
  invalid_match(minimum, Multiple(["Evidence", "Support", "Ranking"]))
  for response in [@qti.Response::Null, Multiple([])] {
    assert_eq(minimum.score(response).score, 0.0)
    assert_eq(minimum.score(response).status, Unanswered)
  }
  let unlimited = @qti.compile_item(
    source.swap("max-choices=\"2\"", "max-choices=\"0\""),
  )
  assert_eq(
    unlimited.score(Multiple(["Evidence", "Support", "Ranking"])).score,
    1.0,
  )
  let high = @qti.compile_item(
    source.swap("max-choices=\"2\"", "max-choices=\"10\""),
  )
  assert_eq(high.max_choices, 10)
}

///|
test "hottext preserves mixed text entities CDATA inline text and passage positions" {
  let source = fixture("hottext-single")
    .swap(
      "学习者完成任务后，教师根据", "<![CDATA[甲<乙]]>&amp;<strong>中<span>间</span></strong>",
    )
    .swap("过程反馈</qti-hottext>", " <em>过程</em>反馈 </qti-hottext>")
  let item = @qti.compile_item(source)
  assert_eq(item.choices()[0].text, " 过程反馈 ")
  guard item.describe() is { "hottext": { "passage": Array(parts), .. }, .. } else {
    fail("missing passage")
  }
  let plain = parts
    .map(p => {
      match p {
        { "text": String(s), .. } => s
        { "choice": String(id), .. } => "[\{id}]"
        _ => "?"
      }
    })
    .join("")
  assert_eq(
    plain, "甲<乙&中间[Feedback]改进教学，而不是只看[Final]。\n",
  )
}

///|
test "hottext declarations reject invalid identifiers types limits and missing choices" {
  let source = fixture("hottext")
  for
    xml in [
      source.swap("identifier=\"Ranking\"", "identifier=\"Evidence\""),
      source.swap("identifier=\"Ranking\"", "identifier=\"SCORE\""),
      source.swap("base-type=\"identifier\"", "base-type=\"string\""),
      source.swap("min-choices=\"1\"", "min-choices=\"4\""),
      source.swap("max-choices=\"2\"", "max-choices=\"bad\""),
      source.swap(
        "收集学习证据</qti-hottext>", "<qti-hottext identifier=\"Nested\">嵌套</qti-hottext></qti-hottext>",
      ),
      source.swap("收集学习证据</qti-hottext>", " </qti-hottext>"),
      source.swap(
        "<qti-value>Support</qti-value>", "<qti-value>Missing</qti-value>",
      ),
      source.swap("map-key=\"Support\"", "map-key=\"Missing\""),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(
    fixture("hottext-single").swap(
      "response-identifier=\"RESPONSE\"", "response-identifier=\"RESPONSE\" max-choices=\"0\"",
    ),
    "invalid_item",
  )
  rejected(
    source.swap("cardinality=\"multiple\"", "cardinality=\"ordered\""),
    "unsupported",
  )
  let none = fixture("hottext-single")
    .swap("qti-hottext identifier=\"Feedback\"", "span")
    .swap("qti-hottext identifier=\"Final\"", "span")
    .swap("</qti-hottext>", "</span>")
  rejected(none, "invalid_item")
}

///|
test "hottext stays within its own interaction and unsupported dynamic content fails" {
  rejected(
    fixture("single").swap(
      "<qti-item-body>", "<qti-item-body><p><qti-hottext identifier=\"X\">stray</qti-hottext></p>",
    ),
    "invalid_item",
  )
  let source = fixture("hottext-single")
  for
    xml in [
      source.swap(
        "identifier=\"Feedback\">", "identifier=\"Feedback\" template-identifier=\"T\">",
      ),
      source.swap(
        "identifier=\"Feedback\">", "identifier=\"Feedback\" show-hide=\"hide\">",
      ),
      source.swap(
        "过程反馈</qti-hottext>", "<img src=\"x.png\"/></qti-hottext>",
      ),
      source.swap(
        "<qti-hottext identifier=\"Feedback\">", "<qti-hottext xmlns=\"http://www.w3.org/1999/xhtml\" identifier=\"Feedback\">",
      ),
      source.swap(
        "<qti-correct-response>", "<qti-default-value><qti-value>Feedback</qti-value></qti-default-value><qti-correct-response>",
      ),
    ] {
    rejected(xml, "unsupported")
  }
}

///|
test "hottext match_correct is unordered and independent of authored display order" {
  let item = @qti.compile_item(
    fixture("hottext").swap("map_response.xml", "match_correct.xml"),
  )
  assert_eq(item.score(Multiple(["Support", "Evidence"])).score, 1.0)
  assert_eq(item.score(Multiple(["Evidence"])).score, 0.0)
  assert_eq(item.score(Multiple(["Ranking"])).score, 0.0)
}

///|
test "candidate instruction blocks retain safe plain text and omit no supported instruction" {
  let source = fixture("hottext-single").swap(
    "选择一个片段，", "&lt;script&gt;&amp;<strong>说明</strong>选择一个片段，",
  )
  let item = @qti.compile_item(source)
  assert_true(
    item.describe() is { "instructions": [String(s)], .. } &&
    s.has_prefix("<script>&说明"),
  )
  let choice_item = @qti.compile_item(
    fixture("single").swap(
      "<qti-item-body>", "<qti-item-body><qti-rubric-block use=\"instructions\" view=\"candidate\"><qti-content-body><p>One</p><p>Two</p></qti-content-body></qti-rubric-block>",
    ),
  )
  assert_true(
    choice_item.describe() is { "instructions": [String("One\nTwo")], .. },
  )
  assert_eq(choice_item.score(Single("A")).score, 1.0)
}

///|
test "rubrics reject other actors purposes nested blocks and active content" {
  let source = fixture("hottext-single")
  for
    xml in [
      source.swap("view=\"candidate\"", "view=\"scorer\""),
      source.swap("view=\"candidate\"", "view=\"candidate author\""),
      source.swap("use=\"instructions\"", "use=\"rubric\""),
      source.swap(
        "<qti-content-body>", "<qti-content-body><script>run()</script>",
      ),
      source.swap("<qti-content-body>", "<qti-content-body><qti-rubric-block/>"),
      source.swap(
        "<qti-content-body>", "<qti-content-body><x:p xmlns:x=\"urn:foreign\">hidden</x:p>",
      ),
      source.swap(
        "<qti-content-body>", "<qti-content-body><qti-text-entry-interaction response-identifier=\"RESPONSE\"/>",
      ),
    ] {
    rejected(xml, "unsupported")
  }
  rejected(source.swap("view=\"candidate\" ", ""), "invalid_item")
}

///|
test "hottext metadata arrays cannot change compiled choices instructions or text positions" {
  let item = @qti.compile_item(fixture("hottext"))
  item.choices().clear()
  let description = item.describe()
  if description is Object(fields) {
    fields.clear()
  }
  assert_eq(item.choices().length(), 3)
  assert_true(
    item.describe()
    is {
      "hottext": { "passage": Array(parts), .. },
      "instructions": [_],
      "correct_response"? : None,
      ..
    } &&
    parts.length() == 10,
  )
  assert_eq(item.score(Multiple(["Evidence", "Support"])).score, 2.0)
}

///|
test "hottext package batches preserve partial marks row-local errors and NULL" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/hottext-manifest.xml"),
      ),
      ("items/hottext.xml", fixture("hottext")),
      ("items/hottext-single.xml", fixture("hottext-single")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/hottext-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 4)
  assert_eq(report.error_count, 1)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(3.0),
    Some(1.0),
    None,
    Some(0.0),
  ])
  assert_true(report.to_csv().contains("false,,,,\"invalid_response\""))
}
