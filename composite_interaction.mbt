///|
fn CompositeBinding::with_interaction(
  self : CompositeBinding,
  node : Node,
) -> CompositeBinding raise QtiError {
  if node.name() == "qti-choice-interaction" {
    if self.base_type != Identifier {
      raise InvalidItem(node.location(), "choice requires single identifier")
    }
    let choices : Array[Choice] = []
    let spec = parse_composite_choice(node, choices)
    return { ..self, choices, choice: Some(spec), }
  }
  if node.name() == "qti-inline-choice-interaction" {
    if self.base_type != Identifier {
      raise InvalidItem(
        node.location(),
        "inline choice requires single identifier",
      )
    }
    let choices : Array[Choice] = []
    // The composite owns the surrounding passage. Passing the interaction as
    // its own body reuses option validation without flattening other fields.
    let spec = parse_inline_choice_interaction(
      node,
      node,
      choices,
      response_id=self.identifier,
    )
    return {
      ..self,
      choices,
      inline_choice: Some(spec),
      placeholder: spec.placeholder,
    }
  }
  if self.base_type == Identifier {
    raise InvalidItem(
      node.location(),
      "identifier response requires inline choice or single choice",
    )
  }
  node.only_attributes([
    "response-identifier", "expected-length", "placeholder-text", "class", "id",
    "dir",
  ])
  node.only_children([])
  if node.attr("expected-length") is Some(_) {
    ignore(nonnegative_int(node, "expected-length"))
  }
  { ..self, placeholder: node.attr("placeholder-text").unwrap_or(""), }
}

///|
fn CompositeBinding::validate_choice_declaration(
  self : CompositeBinding,
) -> Unit raise QtiError {
  if self.base_type != Identifier {
    return
  }
  if self.correct is Some(values) {
    for value in values {
      if !self.choices.any(c => c.identifier == value) {
        raise InvalidItem(
          "response '\{self.identifier}' at \{self.source.line}:\{self.source.column}",
          "correct response references unknown choice '\{value}'",
        )
      }
    }
  }
  if self.mapping is Some(mapping) {
    for entry in mapping.entries {
      if !self.choices.any(c => c.identifier == entry.key) {
        raise InvalidItem(
          "response '\{self.identifier}' at \{self.source.line}:\{self.source.column}",
          "mapping references unknown choice '\{entry.key}'",
        )
      }
    }
  }
}

///|
fn CompositeBinding::response_value(
  self : CompositeBinding,
  response : Response,
) -> CompositeValue raise QtiError {
  let value = composite_value(response, self.base_type)
  if self.base_type == Identifier {
    let required = match (self.inline_choice, self.choice) {
      (Some(spec), _) => spec.required
      (_, Some(spec)) => spec.required
      _ => false
    }
    if value == Null && required {
      raise InvalidResponse(
        "response '\{self.identifier}' requires a selection",
      )
    }
    if value is Text(id) && !self.choices.any(c => c.identifier == id) {
      raise InvalidResponse(
        "unknown choice '\{id}' for response '\{self.identifier}'",
      )
    }
  }
  value
}

///|
// Composite choices are independent scalar interactions. The surrounding
// passage stores their position; prompt and option text stay inside the block.
fn parse_composite_choice(
  node : Node,
  choices : Array[Choice],
) -> CompositeChoice raise QtiError {
  node.only_attributes([
    "response-identifier", "shuffle", "min-choices", "max-choices", "orientation",
    "class", "id", "dir",
  ])
  node.only_children(["qti-prompt", "qti-simple-choice"])
  ignore(xml_bool(node, "shuffle", default=false))
  let minimum = nonnegative_int(node, "min-choices", default=0)
  let maximum = nonnegative_int(node, "max-choices", default=1)
  if maximum != 1 || minimum > 1 {
    raise InvalidItem(
      node.location(),
      "composite single choice requires max-choices=1 and min-choices=0 or 1",
    )
  }
  let orientation = node.attr("orientation").unwrap_or("vertical")
  if !["horizontal", "vertical"].contains(orientation) {
    raise InvalidItem(node.location(), "invalid choice orientation")
  }
  let prompt = match node.one("qti-prompt", required=false) {
    Some(prompt) => {
      prompt.only_attributes(["class", "id", "dir"])
      plain_static_text(prompt).trim().to_owned()
    }
    None => ""
  }
  for choice in node.children {
    if choice.name() != "qti-simple-choice" {
      continue
    }
    choice.only_attributes(["identifier", "fixed", "class", "id", "dir"])
    ignore(xml_bool(choice, "fixed", default=false))
    let id = identifier(choice.required("identifier"), choice.location())
    if choices.any(c => c.identifier == id) {
      raise InvalidItem(choice.location(), "duplicate choice '\{id}'")
    }
    let text = plain_static_text(choice).trim().to_owned()
    if text == "" {
      raise InvalidItem(choice.location(), "choice needs visible text")
    }
    choices.push({ identifier: id, text, })
  }
  if choices.length() < 2 {
    raise InvalidItem(
      node.location(),
      "composite single choice needs at least two choices",
    )
  }
  { prompt, required: minimum == 1, orientation, }
}
