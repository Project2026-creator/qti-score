///|
fn graphic_reject(source : String) -> Unit raise {
  try @qti.compile_item(source) catch {
    @qti.InvalidItem(_, _) | @qti.Unsupported(_, _) | @qti.LimitExceeded(_) =>
      ()
    _ => fail("unexpected graphic compiler error")
  } noraise {
    _ => fail("expected graphic compiler rejection")
  }
}

///|
fn graphic_response_reject(item : @qti.Item, response : String) -> Unit raise {
  try item.score_json(response) catch {
    @qti.InvalidResponse(_) => ()
    _ => fail("unexpected graphic response error")
  } noraise {
    _ => fail("expected graphic response rejection")
  }
}

///|
test "hotspot selects region identifiers and describes safe image geometry" {
  let item = @qti.compile_item(fixture("hotspot"))
  assert_eq(item.score_json("{\"RESPONSE\":\"Collaboration\"}").score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":\"Reading\"}").score, 0.0)
  assert_eq(item.score_json("{\"RESPONSE\":null}").status, @qti.Unanswered)
  assert_eq(item.choices().map(choice => choice.identifier), [
    "Reading", "Collaboration", "Presentation",
  ])
  let description = item.describe()
  assert_true(
    description
    is {
      "graphic": {
        "kind": "hotspot",
        "object": {
          "data": "graphic-map.svg",
          "type": "image/svg+xml",
          "width": 640,
          "height": 360,
          ..
        },
        "regions": Array(regions),
        ..
      },
      ..
    } &&
    regions.length() == 3,
  )
  let text = description.stringify()
  assert_false(text.contains("correct_response"))
  assert_false(text.contains("map_key"))
  graphic_response_reject(item, "{\"RESPONSE\":\"480,130\"}")
  graphic_response_reject(item, "{\"RESPONSE\":[\"Reading\"]}")
}

///|
test "hotspot multiple selection has bounded distinct IDs and standard defaults" {
  let source = fixture("hotspot")
    .swap(
      "identifier=\"RESPONSE\" cardinality=\"single\"", "identifier=\"RESPONSE\" cardinality=\"multiple\"",
    )
    .swap(
      "<qti-hotspot-interaction response-identifier=\"RESPONSE\">", "<qti-hotspot-interaction response-identifier=\"RESPONSE\" max-choices=\"2\" min-choices=\"1\">",
    )
  let item = @qti.compile_item(source)
  assert_eq(item.score_json("{\"RESPONSE\":[\"Collaboration\"]}").score, 1.0)
  graphic_response_reject(
    item, "{\"RESPONSE\":[\"Reading\",\"Collaboration\",\"Presentation\"]}",
  )
  graphic_response_reject(
    item, "{\"RESPONSE\":[\"Collaboration\",\"Collaboration\"]}",
  )
  assert_eq(@qti.compile_item(fixture("hotspot")).max_choices, 1)
  assert_eq(@qti.compile_item(fixture("hotspot")).min_choices, 0)
}

///|
test "graphic gap matches directed endpoints and applies partial mapping" {
  let item = @qti.compile_item(fixture("graphic-gap"))
  assert_eq(
    item.score_json(
      @fs.read_file_to_string("examples/graphic-gap-response.json"),
    ).score,
    3.0,
  )
  assert_eq(item.score_json("{\"RESPONSE\":[\"Read Reading\"]}").score, 1.0)
  assert_eq(item.score_json("{\"RESPONSE\":[\"Discuss Reading\"]}").score, 0.0)
  graphic_response_reject(item, "{\"RESPONSE\":[\"Reading Read\"]}")
  graphic_response_reject(
    item, "{\"RESPONSE\":[\"Read Reading\",\"Read Collaboration\"]}",
  )
  graphic_response_reject(
    item, "{\"RESPONSE\":[\"Read Reading\",\"Discuss Reading\"]}",
  )
  assert_true(
    item.describe()
    is {
      "graphic": { "kind": "graphic_gap_match", "regions": Array(regions), .. },
      "matching": _,
      ..
    } &&
    regions.length() == 3,
  )
}

///|
test "graphic gap permits repeated pairs when source and hotspot limits allow" {
  let source = fixture("graphic-gap")
    .swap("match-max=\"1\"", "match-max=\"0\"")
    .swap(
      "<qti-value>Read Reading</qti-value><qti-value>Discuss Collaboration</qti-value><qti-value>Share Presentation</qti-value>",
      "<qti-value>Read Reading</qti-value><qti-value>Read Reading</qti-value>",
    )
  let item = @qti.compile_item(source)
  let score = item.score_json(
    "{\"RESPONSE\":[\"Read Reading\",\"Read Reading\"]}",
  )
  assert_eq(score.score, 1.0)
  assert_eq(score.matches_correct, Some(true))
  assert_eq(
    item.score_json("{\"RESPONSE\":[\"Read Reading\"]}").matches_correct,
    Some(false),
  )
}

///|
test "graphic shapes preserve circle rectangle ellipse and polygon geometry" {
  let source = fixture("hotspot")
  for
    replacement in [
      (
        "shape=\"circle\" coords=\"320,290,45\"", "shape=\"ellipse\" coords=\"320,290,45,30\"",
      ),
      (
        "shape=\"circle\" coords=\"320,290,45\"", "shape=\"poly\" coords=\"275,245,365,245,320,335\"",
      ),
    ] {
    let item = @qti.compile_item(source.swap(replacement.0, replacement.1))
    assert_eq(item.score_json("{\"RESPONSE\":\"Collaboration\"}").score, 1.0)
  }
  for
    coordinates in [
      "10,20", "10,20,0", "10,-20,5", "10,20,5.5", "10,20,5%", "10, 20,5", "NaN,20,5",
      "10,20,1000001",
    ] {
    graphic_reject(
      source.swap("coords=\"320,290,45\"", "coords=\"" + coordinates + "\""),
    )
  }
  graphic_reject(
    source.swap(
      "shape=\"circle\" coords=\"320,290,45\"", "shape=\"rect\" coords=\"10,20,5,15\"",
    ),
  )
  graphic_reject(
    source.swap(
      "shape=\"circle\" coords=\"320,290,45\"", "shape=\"default\" coords=\"0,0,0\"",
    ),
  )
}

///|
test "graphic images retain item-relative URIs and reject active or external resources" {
  let source = fixture("hotspot")
  let relative = @qti.compile_item(
    source.swap("src=\"graphic-map.svg\"", "src=\"../assets/graphic-map.svg\""),
  )
  assert_true(
    relative.describe()
    is {
      "graphic": { "object": { "data": "../assets/graphic-map.svg", .. }, .. },
      ..
    },
  )
  for
    path in [
      "https://example.org/image.svg", "//example.org/image.svg", "data:image/svg+xml;base64,AAAA",
      "javascript:alert(1)", "file:///image.svg", "C:/image.svg", "/absolute.svg",
      "%252e%252e/image.svg", "image.svg%3Fq=1", "image.svg#fragment",
    ] {
    graphic_reject(
      source.swap("src=\"graphic-map.svg\"", "src=\"" + path + "\""),
    )
  }
  graphic_reject(source.swap("height=\"360\"", "height=\"0\""))
  graphic_reject(source.swap("width=\"640\"", "width=\"16385\""))
  graphic_reject(source.swap("<img src=", "<img onload=\"alert(1)\" src="))
  graphic_reject(
    fixture("graphic-gap").swap("type=\"image/svg+xml\"", "type=\"text/html\""),
  )
}

///|
test "graphic gap image choices produce safe presentation metadata" {
  let source = fixture("graphic-gap").swap(
    "<qti-gap-text identifier=\"Read\" match-max=\"1\">独立阅读资料</qti-gap-text>",
    "<qti-gap-img identifier=\"Read\" match-max=\"1\"><img src=\"graphic-map.svg\" alt=\"独立阅读资料\" width=\"80\" height=\"45\"/></qti-gap-img>",
  )
  let item = @qti.compile_item(source)
  assert_eq(
    item.score_json(
      @fs.read_file_to_string("examples/graphic-gap-response.json"),
    ).score,
    3.0,
  )
  assert_true(
    item.describe()
    is {
      "graphic": {
        "gap_images": [
          {
            "identifier": "Read",
            "image": { "alternative": "独立阅读资料", .. },
            ..
          },
        ],
        ..
      },
      ..
    },
  )
}

///|
test "graphic compilation rejects schema order duplicate regions and incompatible declarations" {
  let source = fixture("hotspot")
  graphic_reject(
    source.swap(
      "</qti-hotspot-interaction>", "<qti-prompt>Late prompt</qti-prompt></qti-hotspot-interaction>",
    ),
  )
  graphic_reject(
    source.swap(
      "<qti-value>Collaboration</qti-value>", "<qti-value>Unknown</qti-value>",
    ),
  )
  graphic_reject(
    source.swap(
      "identifier=\"Reading\" shape=", "identifier=\"Collaboration\" shape=",
    ),
  )
  graphic_reject(
    source.swap("cardinality=\"single\"", "cardinality=\"ordered\""),
  )
  graphic_reject(
    source.swap("base-type=\"identifier\"", "base-type=\"string\""),
  )
  graphic_reject(
    source.swap(
      "<qti-hotspot-choice identifier=\"Reading\"", "<qti-hotspot-choice match-max=\"1\" identifier=\"Reading\"",
    ),
  )
  graphic_reject(
    source.swap(
      "<qti-hotspot-interaction response-identifier=\"RESPONSE\">", "<qti-hotspot-interaction response-identifier=\"RESPONSE\" min-choices=\"2\">",
    ),
  )
  graphic_reject(
    fixture("graphic-gap").swap(
      "cardinality=\"multiple\"", "cardinality=\"single\"",
    ),
  )
  graphic_reject(
    fixture("graphic-gap").swap(
      "match-max=\"1\">独立阅读资料", "match-min=\"2\" match-max=\"1\">独立阅读资料",
    ),
  )
  graphic_reject(
    fixture("graphic-gap").swap(
      "map-key=\"Read Reading\"", "map-key=\"Read Unknown\"",
    ),
  )
}

///|
test "processed graphic interactions reuse geometry and endpoint validation" {
  for name in ["hotspot", "graphic-gap"] {
    let source = fixture(name)
    let marker = if name == "hotspot" {
      "match_correct"
    } else {
      "map_response"
    }
    let authored = source.swap(
      "<qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/" +
      marker +
      ".xml\"/>",
      "<qti-response-processing><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">2</qti-base-value></qti-set-outcome-value></qti-response-processing>",
    )
    let item = @qti.compile_processed_item(authored)
    let response = @fs.read_file_to_string(
      "examples/" + name + "-response.json",
    )
    assert_eq(item.score_json(response).score, 2.0)
    assert_true(item.describe().stringify().contains("\"graphic\""))
    let invalid = if name == "hotspot" {
      "{\"RESPONSE\":\"Unknown\"}"
    } else {
      "{\"RESPONSE\":[\"Reading Read\"]}"
    }
    try item.score_json(invalid) catch {
      @qti.InvalidResponse(_) => ()
      _ => fail("unexpected processed graphic validation error")
    } noraise {
      _ => fail("expected invalid processed graphic response")
    }
  }
}

///|
test "graphic namespace validation rejects spoofed QTI and HTML local names" {
  let source = fixture("hotspot")
  graphic_reject(
    source.swap(
      "<qti-hotspot-choice identifier=\"Reading\"", "<f:qti-hotspot-choice xmlns:f=\"urn:foreign\" identifier=\"Reading\"",
    ),
  )
  graphic_reject(
    source.swap(
      "<qti-hotspot-choice identifier=\"Reading\"", "<h:qti-hotspot-choice xmlns:h=\"http://www.w3.org/1999/xhtml\" identifier=\"Reading\"",
    ),
  )
  graphic_reject(
    source.swap("<img src=", "<f:img xmlns:f=\"urn:foreign\" src="),
  )
  graphic_reject(
    source.swap(
      "观察学习空间示意图", "<f:span xmlns:f=\"urn:foreign\">观察学习空间示意图</f:span>",
    ),
  )
  graphic_reject(
    fixture("graphic-gap")
    .swap("<object data=", "<f:object xmlns:f=\"urn:foreign\" data=")
    .swap("</object>", "</f:object>"),
  )
  let xhtml = source.swap(
    "<img src=", "<h:img xmlns:h=\"http://www.w3.org/1999/xhtml\" src=",
  )
  assert_eq(
    @qti.compile_item(xhtml).score_json("{\"RESPONSE\":\"Collaboration\"}").score,
    1.0,
  )
}
