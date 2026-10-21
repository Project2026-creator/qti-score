///|
priv enum InlineChoicePart {
  Text(String)
  Response
} derive(Debug)

///|
priv struct InlineChoiceInteraction {
  passage : Array[InlineChoicePart]
  required : Bool
  label : String
  placeholder : String
} derive(Debug)

///|
fn InlineChoiceInteraction::describe(self : InlineChoiceInteraction) -> Json {
  {
    "passage": self.passage.map(part => {
      match part {
        Text(text) => { "text": text }
        Response => { "response": "RESPONSE" }
      }
    }),
    "required": self.required,
    "label": self.label,
    "placeholder": self.placeholder,
  }
}

///|
// Retain the response position without flattening the available choices into
// the surrounding text. Rubric instructions are described separately.
fn inline_choice_passage(
  node : Node,
  parts : Array[InlineChoicePart],
) -> Unit raise QtiError {
  if node.name() == "qti-inline-choice-interaction" {
    parts.push(Response)
    return
  }
  if node.name() == "qti-rubric-block" {
    return
  }
  if ![
      "qti-item-body", "p", "div", "blockquote", "ul", "ol", "li", "span", "strong",
      "em", "b", "i", "u", "sub", "sup", "br",
    ].contains(node.name()) {
    raise Unsupported(node.location(), "inline choice context '\{node.name()}'")
  }
  node.only_attributes(["class", "id", "dir"])
  if node.name() == "br" {
    node.only_children([])
  }
  for part in node.parts {
    match part {
      Text(text) =>
        if node.name() != "qti-item-body" || text.trim() != "" {
          parts.push(Text(text))
        }
      Element(child) => inline_choice_passage(child, parts)
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    parts.push(Text("\n"))
  }
}

///|
fn parse_inline_choice_interaction(
  node : Node,
  body : Node,
  choices : Array[Choice],
) -> InlineChoiceInteraction raise QtiError {
  node.only_attributes([
    "response-identifier", "shuffle", "required", "min-choices", "data-prompt", "class",
    "id", "dir",
  ])
  node.only_children(["qti-label", "qti-inline-choice"])
  if xml_bool(node, "shuffle", default=false) {
    raise Unsupported(node.location(), "shuffled inline choices")
  }
  let required = xml_bool(node, "required", default=false)
  let minimum = nonnegative_int(node, "min-choices", default=0)
  if minimum > 1 {
    raise InvalidItem(
      node.location(),
      "inline choice min-choices must be 0 or 1",
    )
  }
  let label = match node.one("qti-label", required=false) {
    Some(label) => {
      label.only_attributes(["class", "id", "dir"])
      plain_static_text(label, inline=true).trim().to_owned()
    }
    None => ""
  }
  let ids : Map[String, Bool] = Map([])
  for choice in node.children {
    if choice.name() != "qti-inline-choice" {
      continue
    }
    choice.only_attributes(["identifier", "fixed", "class", "id", "dir"])
    ignore(xml_bool(choice, "fixed", default=false))
    let id = identifier(choice.required("identifier"), choice.location())
    if ids.contains(id) || id == "RESPONSE" || id == "SCORE" {
      raise InvalidItem(
        choice.location(),
        "duplicate or reserved inline choice '\{id}'",
      )
    }
    let text = plain_static_text(choice, inline=true)
    if text.trim() == "" {
      raise InvalidItem(choice.location(), "inline choice needs visible text")
    }
    ids[id] = true
    choices.push({ identifier: id, text, })
  }
  if choices.is_empty() {
    raise InvalidItem(
      node.location(),
      "inline interaction needs at least one choice",
    )
  }
  let passage : Array[InlineChoicePart] = []
  inline_choice_passage(body, passage)
  {
    passage,
    required: required || minimum == 1,
    label,
    placeholder: node.attr("data-prompt").unwrap_or(""),
  }
}
