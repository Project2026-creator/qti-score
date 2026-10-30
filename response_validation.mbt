///|
/// Validate a response without running response processing or producing feedback.
pub fn Item::validate_json(self : Item, input : String) -> Unit raise QtiError {
  ignore(self.validated_values(self.parse_response_json(input)))
}

///|
fn Item::validated_values(
  self : Item,
  response : Response,
) -> Array[String] raise QtiError {
  let values : Array[String] = match response {
    Null => []
    Number(value) => {
      if !self.base_type.is_numeric() || value.is_nan() || value.is_inf() {
        raise InvalidResponse(
          "numeric response requires a finite numeric value",
        )
      }
      if self.base_type == Integer &&
        (value.abs() > 9007199254740991.0 || value.trunc() != value) {
        raise InvalidResponse("integer response must be a safe integer")
      }
      [value.to_string()]
    }
    Single(value) => {
      if self.cardinality != Single {
        raise InvalidResponse("string response requires single cardinality")
      }
      if value == "" || (self.base_type.is_numeric() && value.trim() == "") {
        []
      } else {
        [value]
      }
    }
    Multiple(values) => {
      if self.cardinality != Multiple {
        raise InvalidResponse("multiple response requires multiple cardinality")
      }
      if values.any(v => v == "") {
        raise InvalidResponse(
          "NULL members are not permitted in a multiple response",
        )
      }
      values.copy()
    }
    Ordered(values) => {
      if self.cardinality != Ordered {
        raise InvalidResponse("ordered response requires ordered cardinality")
      }
      if values.any(v => v == "") {
        raise InvalidResponse(
          "NULL members are not permitted in an ordered response",
        )
      }
      values.copy()
    }
  }
  if values.length() > 4096 || values.any(v => v.length() > 65536) {
    raise LimitExceeded("response value limit exceeded")
  }
  if self.base_type == DirectedPair {
    for i, value in values {
      values[i] = directed_pair(value)
    }
  }
  if self.base_type == Pair {
    for i, value in values {
      values[i] = undirected_pair(value)
    }
  }
  if self.base_type.is_numeric() {
    if !values.is_empty() {
      let value = match response {
        Number(value) => value
        _ =>
          numeric_value(values[0], self.base_type) catch {
            _ => raise InvalidResponse("invalid numeric response")
          }
      }
      if self.slider is Some(spec) {
        spec.validate(value)
      }
    }
    return values
  }
  if values.is_empty() {
    if self.inline_choice is Some(spec) && spec.required {
      raise InvalidResponse("inline choice requires a selection")
    }
    return values
  }
  if self.max_choices != 0 && values.length() > self.max_choices {
    raise InvalidResponse("more responses than max-choices=\{self.max_choices}")
  }
  if values.length() < self.min_choices {
    raise InvalidResponse(
      "fewer responses than min-choices=\{self.min_choices}",
    )
  }
  if !self.choices.is_empty() {
    for value in values {
      if !self.choices.any(c => c.identifier == value) {
        raise InvalidResponse("unknown choice '\{value}'")
      }
    }
  }
  if self.cardinality == Ordered ||
    self.hottext_passage is Some(_) ||
    (self.graphic is Some(spec) && spec.kind == "hotspot") {
    let seen : Map[String, Bool] = Map([])
    for value in values {
      if seen.contains(value) {
        raise InvalidResponse("duplicate ordered/hottext choice '\{value}'")
      }
      seen[value] = true
    }
  }
  if self.matching is Some(spec) {
    spec.validate(values)
  }
  if self.association is Some(spec) {
    spec.validate(values)
  }
  values
}

///|
pub fn CompositeItem::validate_json(
  self : CompositeItem,
  input : String,
) -> Unit raise QtiError {
  let responses = self.parse_responses(input)
  for binding in self.bindings {
    ignore(
      binding.response_value(
        responses.get(binding.identifier).unwrap_or(Response::Null),
      ),
    )
  }
}

///|
pub fn AssessmentItem::validate_json(
  self : AssessmentItem,
  input : String,
) -> Unit raise QtiError {
  match self {
    Single(item) => item.validate_json(input)
    Composite(item) => item.validate_json(input)
    Processed(item) => item.validate_json(input)
  }
}

///|
pub fn AssessmentItem::outcomes_json(
  self : AssessmentItem,
  input : String,
) -> Json raise QtiError {
  match self {
    Processed(item) => item.outcomes_json(input)
    _ => { "SCORE": self.score_json(input).score }
  }
}

///|
pub fn AssessmentItem::feedback_json(
  self : AssessmentItem,
  input : String,
) -> Json raise QtiError {
  match self {
    Processed(item) => item.feedback_json(input)
    _ => {
      self.validate_json(input)
      Json::array([])
    }
  }
}

///|
pub fn AssessmentItem::response_types_json(self : AssessmentItem) -> Json {
  let result : Map[String, Json] = Map([])
  match self {
    Single(item) =>
      result[item.response_identifier] = {
        "base_type": item.base_type.name(),
        "cardinality": match item.cardinality {
          Single => "single"
          Multiple => "multiple"
          Ordered => "ordered"
        },
      }
    Composite(item) =>
      for binding in item.bindings {
        result[binding.identifier] = {
          "base_type": binding.base_type.name(),
          "cardinality": match binding.cardinality {
            Single => "single"
            Multiple => "multiple"
            Ordered => "ordered"
          },
        }
      }
    Processed(item) =>
      return processing_types(item.program.describe(), "response")
  }
  Json::object(result)
}

///|
pub fn AssessmentItem::outcome_types_json(self : AssessmentItem) -> Json {
  match self {
    Processed(item) => processing_types(item.program.describe(), "outcome")
    _ => { "SCORE": { "base_type": "float", "cardinality": "single" } }
  }
}
