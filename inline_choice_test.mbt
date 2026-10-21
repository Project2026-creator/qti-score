///|
test "inline choice scores selected identifiers with both standard templates" {
  let exact = @qti.compile_item(fixture("inline-choice"))
  assert_eq(exact.score(Single("Improve")).score, 1.0)
  assert_eq(exact.score(Single("Rank")).score, 0.0)
  let mapped = @qti.compile_item(fixture("inline-choice-required"))
  assert_eq(mapped.score(Single("Adapt")).score, 2.0)
  let partial = mapped.explain_json("{\"RESPONSE\":\"Review\"}")
  assert_eq(partial.result.score, 0.5)
  assert_eq(partial.result.matches_correct, Some(false))
  assert_eq(partial.result, mapped.score(Single("Review")))
  assert_true(partial.steps.any(s => s.operation == "map_value"))
  assert_eq(mapped.score(Single("Ignore")).score, 0.0)
}

///|
test "optional inline choice NULL is unanswered without applying mapping defaults" {
  let item = @qti.compile_item(fixture("inline-choice"))
  assert_eq(item.min_choices, 0)
  assert_eq(item.max_choices, 1)
  for response in [@qti.Response::Null, Single("")] {
    assert_eq(item.score(response).status, Unanswered)
    assert_eq(item.score(response).score, 0.0)
  }
  assert_eq(item.score_json("{}").status, Unanswered)
  let mapped = @qti.compile_item(
    fixture("inline-choice-required")
    .swap("required=\"true\"", "required=\"false\"")
    .swap("lower-bound=\"0\"", "lower-bound=\"1\""),
  )
  assert_eq(mapped.score(Null).score, 0.0)
  assert_eq(mapped.score(Single("Ignore")).score, 1.0)
}

///|
test "required and minimum-one inline choices reject empty selections while optional items keep NULL" {
  let source = fixture("inline-choice-required")
  for
    xml in [
      source,
      source.swap("required=\"true\"", "required=\"1\""),
      source.swap("required=\"true\"", "min-choices=\"1\""),
      source.swap("required=\"true\"", "required=\"false\" min-choices=\"1\""),
      source.swap("required=\"true\"", "required=\"true\" min-choices=\"0\""),
    ] {
    let item = @qti.compile_item(xml)
    assert_eq(item.min_choices, 1)
    assert_true(
      item.describe() is { "inline_choice": { "required": True, .. }, .. },
    )
    invalid_match(item, Null)
    invalid_match(item, Single(""))
    assert_eq(item.score(Single("Adapt")).score, 2.0)
    try item.score_json("{}") catch {
      e => assert_eq(e.code(), "invalid_response")
    } noraise {
      _ => fail("required choice accepted omitted response")
    }
  }
  assert_eq(
    @qti.compile_item(fixture("hottext")).score(Null).status,
    Unanswered,
  )
}

///|
test "inline choice rejects unknown identifiers text numeric and multiple containers" {
  let item = @qti.compile_item(fixture("inline-choice"))
  for
    response in [
      @qti.Response::Single("Unknown"),
      Single("improve"),
      Single("改进教学"),
      Single(" Improve "),
      Number(1.0),
      Multiple(["Improve"]),
      Multiple([]),
      Ordered(["Improve"]),
    ] {
    invalid_match(item, response)
  }
}

///|
test "inline context preserves ordered text but excludes choices labels and instructions" {
  let xml = fixture("inline-choice")
    .swap(
      "形成性评价在学习过程中收集证据，帮助教师", "<![CDATA[甲<乙]]>&amp;<strong>中<span>间</span></strong><br/>",
    )
    .swap(
      "改进教学</qti-inline-choice>", " <em>改进</em>教学 </qti-inline-choice>",
    )
    .swap("，并为学习者提供及时反馈。", "后文")
  let item = @qti.compile_item(xml)
  assert_eq(item.choices()[0].text, " 改进教学 ")
  guard item.describe()
    is {
      "inline_choice": {
        "passage": Array(parts),
        "label": String("评价目的"),
        "placeholder": String("请选择评价目的"),
        ..
      },
      "instructions": [_],
      ..
    } else {
    fail("missing inline metadata")
  }
  let text = parts
    .map(p => {
      match p {
        { "text": String(s), .. } => s
        { "response": String(id), .. } => "[\{id}]"
        _ => "?"
      }
    })
    .join("")
  assert_eq(text, "甲<乙&中间\n[RESPONSE]后文\n")
}

///|
test "inline metadata is isolated and absent on other item types" {
  let item = @qti.compile_item(fixture("inline-choice"))
  let description = item.describe()
  if description is Object(fields) {
    fields.clear()
  }
  item.choices().clear()
  assert_eq(item.choices().length(), 3)
  assert_true(
    item.describe()
    is {
      "inline_choice": { "passage": Array(parts), .. },
      "correct_response"? : None,
      "mapping"? : None,
      ..
    } &&
    parts.filter(p => p is { "response": String("RESPONSE"), .. }).length() == 1,
  )
  assert_true(
    @qti.compile_item(fixture("single")).describe()
    is { "inline_choice"? : None, .. },
  )
  assert_eq(item.score(Single("Improve")).score, 1.0)
}

///|
test "inline choice accepts one choice default label and XML namespace prefixes" {
  let source = fixture("inline-choice")
    .swap(
      "<qti-inline-choice identifier=\"Rank\">公布排名</qti-inline-choice>",
      "",
    )
    .swap(
      "<qti-inline-choice identifier=\"Archive\">归档材料</qti-inline-choice>",
      "",
    )
    .swap("<qti-label>评价目的</qti-label>", "")
    .swap(" data-prompt=\"请选择评价目的\"", "")
    .swap("identifier=\"Improve\">", "identifier=\"Improve\" fixed=\"true\">")
  let item = @qti.compile_item(source)
  assert_eq(item.choices().length(), 1)
  assert_true(
    item.describe()
    is {
      "inline_choice": { "label": String(""), "placeholder": String(""), .. },
      ..
    },
  )
  let prefixed = source
    .swap("xmlns=", "xmlns:q=")
    .swap("<qti-", "<q:qti-")
    .swap("</qti-", "</q:qti-")
    .swap("<p>", "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\">")
    .swap("</p>", "</h:p>")
  assert_eq(@qti.compile_item(prefixed).describe(), item.describe())
}

///|
test "inline declarations reject bad references duplicate choices and incompatible types" {
  let source = fixture("inline-choice")
  for
    xml in [
      source.swap("identifier=\"Rank\"", "identifier=\"Improve\""),
      source.swap("identifier=\"Rank\"", "identifier=\"RESPONSE\""),
      source.swap("identifier=\"Rank\"", "identifier=\"SCORE\""),
      source.swap(
        "<qti-value>Improve</qti-value>", "<qti-value>Missing</qti-value>",
      ),
      source.swap(
        "cardinality=\"single\" base-type=\"identifier\"", "cardinality=\"multiple\" base-type=\"identifier\"",
      ),
      source.swap("base-type=\"identifier\"", "base-type=\"string\""),
      source.swap("改进教学</qti-inline-choice>", " </qti-inline-choice>"),
      source.swap(
        "response-identifier=\"RESPONSE\"", "response-identifier=\"OTHER\"",
      ),
    ] {
    rejected(xml, "invalid_item")
  }
  rejected(
    fixture("inline-choice-required").swap(
      "map-key=\"Review\"", "map-key=\"Missing\"",
    ),
    "invalid_item",
  )
  rejected(
    source
    .swap("qti-inline-choice identifier=\"", "span id=\"")
    .swap("</qti-inline-choice>", "</span>"),
    "unsupported",
  )
}

///|
test "inline constraints validate attribute values and reject unknown behavior" {
  let source = fixture("inline-choice")
  for
    attribute in [
      "required=\"yes\"", "shuffle=\"yes\"", "min-choices=\"2\"", "min-choices=\"-1\"",
    ] {
    rejected(
      source.swap(
        "response-identifier=\"RESPONSE\"",
        "response-identifier=\"RESPONSE\" " + attribute,
      ),
      "invalid_item",
    )
  }
  for
    attribute in [
      "shuffle=\"true\"", "max-choices=\"1\"", "template-identifier=\"T\"",
    ] {
    rejected(
      source.swap(
        "response-identifier=\"RESPONSE\"",
        "response-identifier=\"RESPONSE\" " + attribute,
      ),
      "unsupported",
    )
  }
  rejected(
    source.swap(
      "identifier=\"Improve\">", "identifier=\"Improve\" fixed=\"yes\">",
    ),
    "invalid_item",
  )
}

///|
test "inline choice rejects active dynamic media and unexpected context" {
  let source = fixture("inline-choice")
  for
    xml in [
      source.swap(
        "identifier=\"Improve\">", "identifier=\"Improve\" show-hide=\"hide\">",
      ),
      source.swap(
        "改进教学</qti-inline-choice>", "<qti-printed-variable identifier=\"X\"/></qti-inline-choice>",
      ),
      source.swap(
        "改进教学</qti-inline-choice>", "<img src=\"x.png\"/></qti-inline-choice>",
      ),
      source.swap(
        "改进教学</qti-inline-choice>", "<p>nested block</p></qti-inline-choice>",
      ),
      source.swap(
        "<qti-item-body>", "<qti-item-body><p><img src=\"x.png\"/></p>",
      ),
      source.swap(
        "形成性评价在", "<a href=\"https://example.org\">外链</a>形成性评价在",
      ),
      source.swap("<qti-label>", "<qti-label><script>run()</script>"),
      source.swap(
        "<qti-inline-choice identifier=\"Improve\">", "<qti-inline-choice xmlns=\"http://www.w3.org/1999/xhtml\" identifier=\"Improve\">",
      ),
    ] {
    rejected(xml, "unsupported")
  }
}

///|
test "inline elements stay in their interaction and composite items remain unsupported" {
  let source = fixture("inline-choice")
  rejected(
    source.swap(
      "<qti-item-body>", "<qti-item-body><qti-inline-choice identifier=\"Stray\">stray</qti-inline-choice>",
    ),
    "invalid_item",
  )
  rejected(
    source.swap(
      "<qti-item-body>", "<qti-item-body><qti-label>stray</qti-label>",
    ),
    "invalid_item",
  )
  rejected(
    source.swap(
      "<qti-label>评价目的</qti-label>", "<qti-label>One</qti-label><qti-label>Two</qti-label>",
    ),
    "invalid_item",
  )
  rejected(
    source.swap(
      "<qti-item-body>", "<qti-item-body><qti-inline-choice-interaction response-identifier=\"RESPONSE\"><qti-inline-choice identifier=\"Extra\">extra</qti-inline-choice></qti-inline-choice-interaction>",
    ),
    "unsupported",
  )
}

///|
test "inline package batches preserve required-response errors optional NULL and partial scores" {
  let bundle = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        @fs.read_file_to_string("examples/inline-choice-manifest.xml"),
      ),
      ("items/inline-choice.xml", fixture("inline-choice")),
      ("items/inline-choice-required.xml", fixture("inline-choice-required")),
    ]),
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
  let report = bundle.score_attempts_jsonl(
    @fs.read_file_to_string("examples/inline-choice-attempts.jsonl"),
  )
  assert_eq(report.scored_count, 4)
  assert_eq(report.error_count, 2)
  assert_eq(report.attempts().map(a => a.score_sum), [
    Some(3.0),
    Some(0.5),
    None,
    Some(0.0),
    None,
  ])
  assert_true(report.to_csv().contains("inline choice requires a selection"))
}
