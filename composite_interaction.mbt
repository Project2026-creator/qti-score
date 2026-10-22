///|
fn CompositeBinding::with_interaction(
  self : CompositeBinding,
  node : Node,
) -> CompositeBinding raise QtiError {
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
      "identifier response requires inline choice",
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
  if self.inline_choice is None {
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
  if self.inline_choice is Some(spec) {
    if value == Null && spec.required {
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
