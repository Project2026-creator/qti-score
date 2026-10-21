///|
priv enum GapPart {
  Text(String)
  Gap(String)
} derive(Debug)

///|
fn GapPart::describe(self : GapPart) -> Json {
  match self {
    Text(text) => { "text": text }
    Gap(id) => { "gap": id }
  }
}

///|
fn gap_identifier(
  node : Node,
  ids : Map[String, Bool],
) -> String raise QtiError {
  let id = identifier(node.required("identifier"), node.location())
  if ids.contains(id) || id == "RESPONSE" || id == "SCORE" {
    raise InvalidItem(
      node.location(),
      "duplicate or reserved gap identifier '\{id}'",
    )
  }
  ids[id] = true
  id
}

///|
fn gap_text_content(node : Node) -> Unit raise QtiError {
  for child in node.children {
    if !["span", "strong", "em", "b", "i", "u", "sub", "sup", "br"].contains(
        child.name(),
      ) {
      raise Unsupported(
        child.location(),
        "gap-text/prompt content '\{child.name()}'",
      )
    }
    child.only_attributes(["class", "id", "dir"])
    gap_text_content(child)
  }
}

///|
fn gap_passage_parts(
  node : Node,
  parts : Array[GapPart],
  gaps : Array[MatchChoice],
  ids : Map[String, Bool],
) -> Unit raise QtiError {
  if node.name() == "qti-gap" {
    node.only_attributes([
      "identifier", "required", "label", "class", "id", "dir",
    ])
    node.only_children([])
    let id = gap_identifier(node, ids)
    let required = xml_bool(node, "required", default=false)
    gaps.push({
      identifier: id,
      text: node.attr("label").unwrap_or(id),
      minimum: if required {
        1
      } else {
        0
      },
      maximum: 1,
    })
    parts.push(Gap(id))
    return
  }
  if ![
      "p", "div", "blockquote", "ul", "ol", "li", "span", "strong", "em", "b", "i",
      "u", "sub", "sup", "br",
    ].contains(node.name()) {
    raise Unsupported(node.location(), "gap passage content '\{node.name()}'")
  }
  node.only_attributes(["class", "id", "dir"])
  for part in node.parts {
    match part {
      Text(text) => parts.push(Text(text))
      Element(child) => gap_passage_parts(child, parts, gaps, ids)
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    parts.push(Text("\n"))
  }
}

///|
fn parse_gap_interaction(
  node : Node,
  cardinality : Cardinality,
) -> (MatchInteraction, Array[GapPart]) raise QtiError {
  node.only_attributes([
    "response-identifier", "shuffle", "min-associations", "max-associations", "class",
    "id",
  ])
  node.only_children([
    "qti-prompt", "qti-gap-text", "p", "div", "blockquote", "ul", "ol",
  ])
  ignore(xml_bool(node, "shuffle", default=false))
  let minimum = nonnegative_int(node, "min-associations", default=0)
  let maximum = nonnegative_int(node, "max-associations", default=1)
  if cardinality == Ordered ||
    (maximum != 0 && minimum > maximum) ||
    (cardinality == Single && maximum != 1) {
    raise InvalidItem(
      node.location(),
      "inconsistent gap association limits or cardinality",
    )
  }
  let ids : Map[String, Bool] = Map([])
  let choices : Array[MatchChoice] = []
  for child in node.children {
    if child.name() == "qti-gap-text" {
      child.only_attributes([
        "identifier", "match-min", "match-max", "class", "id",
      ])
      gap_text_content(child)
      let id = gap_identifier(child, ids)
      let lo = nonnegative_int(child, "match-min", default=0)
      let hi = nonnegative_int(child, "match-max")
      if hi != 0 && lo > hi {
        raise InvalidItem(child.location(), "match-min exceeds match-max")
      }
      choices.push({
        identifier: id,
        text: child.all_text.to_string().trim().to_owned(),
        minimum: lo,
        maximum: hi,
      })
    } else if child.name() == "qti-prompt" {
      child.only_attributes(["class", "id", "dir"])
      gap_text_content(child)
    }
  }
  let passage : Array[GapPart] = []
  let gaps : Array[MatchChoice] = []
  for part in node.parts {
    match part {
      Text(_) => () // Formatting outside passage blocks is not passage text.
      Element(child) =>
        if child.name() != "qti-prompt" && child.name() != "qti-gap-text" {
          gap_passage_parts(child, passage, gaps, ids)
        }
    }
  }
  if choices.is_empty() || gaps.is_empty() {
    raise InvalidItem(
      node.location(),
      "gap match needs choices and passage gaps",
    )
  }
  if cardinality == Single && gaps.length() != 1 {
    raise InvalidItem(
      node.location(),
      "multiple passage gaps require multiple cardinality",
    )
  }
  (match_interaction(choices, gaps, minimum, maximum), passage)
}
