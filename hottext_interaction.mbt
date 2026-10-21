///|
priv enum HottextPart {
  Text(String)
  Choice(String)
} derive(Debug)

///|
fn HottextPart::describe(self : HottextPart) -> Json {
  match self {
    Text(text) => { "text": text }
    Choice(id) => { "choice": id }
  }
}

///|
// A bounded plain-text profile; authored markup is never returned as HTML.
fn plain_static_text(
  node : Node,
  inline~ : Bool = false,
) -> String raise QtiError {
  let text = StringBuilder()
  for part in node.parts {
    match part {
      Text(value) => text.write_string(value)
      Element(child) => {
        if child.name() == "qti-hottext" {
          raise InvalidItem(
            child.location(),
            "nested hottext choices are not allowed",
          )
        }
        let allowed = [
            "span", "strong", "em", "b", "i", "u", "sub", "sup", "br",
          ].contains(child.name()) ||
          (
            !inline &&
            ["p", "div", "blockquote", "ul", "ol", "li"].contains(child.name())
          )
        if !allowed ||
          ![Some(qti_namespace), Some("http://www.w3.org/1999/xhtml")].contains(
            child.element.name.namespace_uri,
          ) {
          raise Unsupported(
            child.location(),
            "plain text content '\{child.name()}'",
          )
        }
        child.only_attributes(["class", "id", "dir"])
        if child.name() == "br" {
          child.only_children([])
        }
        text.write_string(plain_static_text(child, inline~))
      }
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    text.write_string("\n")
  }
  text.to_string()
}

///|
fn candidate_instructions(node : Node) -> String raise QtiError {
  if node.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(node.location(), "rubric block namespace")
  }
  node.only_attributes(["view", "use", "class", "id", "dir"])
  if node.required("view") != "candidate" ||
    node.required("use") != "instructions" {
    raise Unsupported(
      node.location(),
      "only candidate instructions rubric blocks are supported",
    )
  }
  node.only_children(["qti-content-body"])
  let content = node.one("qti-content-body").unwrap()
  content.only_attributes(["class", "id", "dir"])
  plain_static_text(content).trim().to_owned()
}

///|
fn hottext_parts(
  node : Node,
  parts : Array[HottextPart],
  choices : Array[Choice],
  ids : Map[String, Bool],
) -> Unit raise QtiError {
  if node.name() == "qti-hottext" {
    node.only_attributes(["identifier", "class", "id", "dir"])
    let id = identifier(node.required("identifier"), node.location())
    if ids.contains(id) || id == "RESPONSE" || id == "SCORE" {
      raise InvalidItem(
        node.location(),
        "duplicate or reserved hottext choice '\{id}'",
      )
    }
    let text = plain_static_text(node, inline=true)
    if text.trim() == "" {
      raise InvalidItem(node.location(), "hottext choice needs visible text")
    }
    ids[id] = true
    choices.push({ identifier: id, text, })
    parts.push(Choice(id))
    return
  }
  if ![
      "p", "div", "blockquote", "ul", "ol", "li", "span", "strong", "em", "b", "i",
      "u", "sub", "sup", "br",
    ].contains(node.name()) {
    raise Unsupported(
      node.location(),
      "hottext passage content '\{node.name()}'",
    )
  }
  node.only_attributes(["class", "id", "dir"])
  if node.name() == "br" {
    node.only_children([])
  }
  for part in node.parts {
    match part {
      Text(text) => parts.push(Text(text))
      Element(child) => hottext_parts(child, parts, choices, ids)
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    parts.push(Text("\n"))
  }
}

///|
fn parse_hottext_interaction(
  node : Node,
  cardinality : Cardinality,
  choices : Array[Choice],
) -> (Array[HottextPart], Int32, Int32) raise QtiError {
  node.only_attributes([
    "response-identifier", "min-choices", "max-choices", "class", "id", "dir",
  ])
  node.only_children(["qti-prompt", "p", "div", "blockquote", "ul", "ol"])
  let parts : Array[HottextPart] = []
  let ids : Map[String, Bool] = Map([])
  for child in node.children {
    if child.name() == "qti-prompt" {
      child.only_attributes(["class", "id", "dir"])
      ignore(plain_static_text(child, inline=true))
    } else {
      hottext_parts(child, parts, choices, ids)
    }
  }
  let minimum = nonnegative_int(node, "min-choices", default=0)
  let maximum = nonnegative_int(node, "max-choices", default=1)
  if choices.is_empty() ||
    minimum > choices.length() ||
    (maximum != 0 && minimum > maximum) ||
    (cardinality == Single && maximum != 1) {
    raise InvalidItem(
      node.location(),
      "inconsistent hottext choice limits or cardinality",
    )
  }
  (parts, minimum, maximum)
}
