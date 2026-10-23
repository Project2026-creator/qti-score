///|
fn CompositeBinding::with_interaction(
  self : CompositeBinding,
  node : Node,
) -> CompositeBinding raise QtiError {
  if node.name() == "qti-choice-interaction" {
    if self.base_type != Identifier {
      raise InvalidItem(node.location(), "choice requires identifier base type")
    }
    let choices : Array[Choice] = []
    let spec = parse_composite_choice(node, choices, self.cardinality)
    return { ..self, choices, choice: Some(spec), }
  }
  if node.name() == "qti-inline-choice-interaction" {
    if self.base_type != Identifier || self.cardinality != Single {
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
      "identifier response requires inline choice or block choice",
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
    if self.choice is Some(spec) &&
      (
        values.length() < spec.min_choices ||
        (spec.max_choices != 0 && values.length() > spec.max_choices)
      ) {
      raise InvalidItem(
        "response '\{self.identifier}'",
        "correct response violates choice limits",
      )
    }
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
  let value = if self.cardinality == Multiple {
    match response {
      Null => CompositeValue::Null
      Multiple(values) => {
        if values.length() > 4096 || values.any(v => v.length() > 65536) {
          raise LimitExceeded(
            "response exceeds 4096 values or 65536 UTF-16 code units per value",
          )
        }
        if values.any(v => v == "") {
          raise InvalidResponse(
            "NULL members are not permitted in a multiple response",
          )
        }
        if values.is_empty() {
          CompositeValue::Null
        } else {
          CompositeValue::Values(values.copy())
        }
      }
      _ =>
        raise InvalidResponse(
          "response '\{self.identifier}' requires multiple cardinality",
        )
    }
  } else {
    composite_value(response, self.base_type)
  }
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
    if value is Values(ids) {
      let spec = self.choice.unwrap()
      if ids.length() < spec.min_choices ||
        (spec.max_choices != 0 && ids.length() > spec.max_choices) {
        raise InvalidResponse(
          "response '\{self.identifier}' violates choice limits",
        )
      }
      for id in ids {
        if !self.choices.any(c => c.identifier == id) {
          raise InvalidResponse(
            "unknown choice '\{id}' for response '\{self.identifier}'",
          )
        }
      }
    }
  }
  value
}

///|
// Composite choices are independent interactions. The surrounding
// passage stores their position; prompt and option text stay inside the block.
fn parse_composite_choice(
  node : Node,
  choices : Array[Choice],
  cardinality : Cardinality,
) -> CompositeChoice raise QtiError {
  node.only_attributes([
    "response-identifier", "shuffle", "min-choices", "max-choices", "orientation",
    "class", "id", "dir",
  ])
  node.only_children(["qti-prompt", "qti-simple-choice"])
  ignore(xml_bool(node, "shuffle", default=false))
  let minimum = nonnegative_int(node, "min-choices", default=0)
  let maximum = nonnegative_int(node, "max-choices", default=1)
  if (cardinality == Single && maximum != 1) ||
    (maximum != 0 && minimum > maximum) {
    raise InvalidItem(
      node.location(),
      "single choice requires max-choices=1; minimum cannot exceed a nonzero maximum",
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
      "composite choice needs at least two choices",
    )
  }
  if minimum > choices.length() || (maximum != 0 && maximum > choices.length()) {
    raise InvalidItem(node.location(), "choice limits exceed available choices")
  }
  {
    prompt,
    required: minimum > 0,
    orientation,
    min_choices: minimum,
    max_choices: maximum,
  }
}
