///|
/// Parse {"RESPONSE": string | finite number | string[] | null}.
/// An omitted RESPONSE is NULL. Other response identifiers are rejected.
pub fn response_from_json(json : Json) -> Response raise QtiError {
  guard json is Object(fields) else {
    raise InvalidResponse("expected a JSON object with a RESPONSE member")
  }
  for key, _ in fields {
    if key != "RESPONSE" {
      raise InvalidResponse("unknown response identifier '\{key}'")
    }
  }
  match fields.get("RESPONSE") {
    None | Some(Null) => Null
    Some(String(value)) => Single(value)
    Some(Number(value, ..)) => {
      if value.is_nan() || value.is_inf() {
        raise InvalidResponse("numeric response must be finite")
      }
      Number(value)
    }
    Some(Array(values)) => {
      if values.length() > 4096 {
        raise LimitExceeded("at most 4096 response values are supported")
      }
      let strings : Array[String] = []
      for value in values {
        guard value is String(s) else {
          raise InvalidResponse("multiple response members must be strings")
        }
        strings.push(s)
      }
      Multiple(strings)
    }
    _ =>
      raise InvalidResponse(
        "RESPONSE must be a string, a finite number, an array of strings, or null",
      )
  }
}

///|
/// Score a JSON-encoded response, reusing an already compiled item.
pub fn Item::score_json(
  self : Item,
  response_json : String,
) -> Score raise QtiError {
  self.score(self.parse_response_json(response_json))
}

///|
pub fn Item::explain_json(
  self : Item,
  response_json : String,
) -> Explanation raise QtiError {
  self.explain(self.parse_response_json(response_json))
}

///|
fn Item::parse_response_json(
  self : Item,
  response_json : String,
) -> Response raise QtiError {
  if response_json.length() > 1048576 {
    raise LimitExceeded("response JSON exceeds 1048576 UTF-16 code units")
  }
  let parsed = @json.parse(
    response_json[:],
    max_nesting_depth=16,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise InvalidResponse("malformed response JSON")
  }
  if self.base_type == Integer &&
    parsed is { "RESPONSE": Number(_, repr~), .. } &&
    repr is Some(raw) {
    ignore(
      numeric_value(raw, Integer) catch {
        _ =>
          raise InvalidResponse(
            "JSON integer must be safe decimal integer digits",
          )
      },
    )
  }
  match response_from_json(parsed) {
    Multiple(values) if self.cardinality == Ordered => Ordered(values)
    response => response
  }
}

///|
pub impl ToJson for Score with fn to_json(self) {
  let matches_correct : Json = match self.matches_correct {
    Some(value) => Json(value)
    None => Json::null()
  }
  {
    "score": self.score,
    "status": match self.status {
      Unanswered => "unanswered"
      Answered => "answered"
    },
    "matches_correct": matches_correct,
  }
}

///|
/// Description contains plain text and choice IDs, without correct responses
/// or mapping keys. It is suitable for a host UI, not an HTML renderer.
pub fn Item::describe(self : Item) -> Json {
  let choices = self.choices.map(c => {
    "identifier": c.identifier,
    "text": c.text,
  })
  let description : Json = {
    "identifier": self.identifier,
    "title": self.title,
    "response_identifier": self.response_identifier,
    "cardinality": match self.cardinality {
      Single => "single"
      Multiple => "multiple"
      Ordered => "ordered"
    },
    "base_type": self.base_type.name(),
    "template": match self.template {
      MatchCorrect => "match_correct"
      MapResponse => "map_response"
      NumericRules => "numeric_rules"
    },
    "prompt": self.prompt,
    "min_choices": self.min_choices,
    "max_choices": self.max_choices,
    "choices": choices,
  }
  if self.matching is Some(spec) && description is Object(fields) {
    if self.gap_passage is Some(passage) {
      let gap_description = spec.describe()
      if gap_description is Object(details) {
        details["passage"] = Json(passage.map(part => part.describe()))
      }
      fields["gap_matching"] = gap_description
    } else {
      fields["matching"] = spec.describe()
    }
  }
  if description is Object(fields) {
    if self.graphic is Some(spec) {
      fields["graphic"] = spec.describe()
    }
    if self.slider is Some(spec) {
      fields["slider"] = spec.describe()
    }
    if self.inline_choice is Some(spec) {
      fields["inline_choice"] = spec.describe()
    }
    if self.hottext_passage is Some(passage) {
      fields["hottext"] = { "passage": passage.map(part => part.describe()) }
    }
    if !self.instructions.is_empty() {
      fields["instructions"] = Json(self.instructions.copy())
    }
  }
  description
}

///|
pub fn QtiError::code(self : QtiError) -> String {
  match self {
    InvalidXml(_, _, _) => "invalid_xml"
    InvalidItem(_, _) => "invalid_item"
    InvalidPackage(_, _) => "invalid_package"
    Unsupported(_, _) => "unsupported"
    InvalidResponse(_) => "invalid_response"
    LimitExceeded(_) => "limit_exceeded"
  }
}

///|
pub fn QtiError::message(self : QtiError) -> String {
  match self {
    InvalidXml(message, line, column) => "\{message} at \{line}:\{column}"
    InvalidItem(location, message)
    | InvalidPackage(location, message)
    | Unsupported(location, message) => "\{location}: \{message}"
    InvalidResponse(message) | LimitExceeded(message) => message
  }
}

///|
pub impl ToJson for QtiError with fn to_json(self) {
  let location : Json = match self.location() {
    Some(source) => source.to_json()
    None => Json::null()
  }
  { "code": self.code(), "message": self.message(), "location": location }
}

///|
/// XML parsing and item-compilation errors carry a source position when known.
pub fn QtiError::location(self : QtiError) -> SourceLocation? {
  match self {
    InvalidXml(_, line, column) => Some({ line, column, })
    InvalidItem(location, _)
    | InvalidPackage(location, _)
    | Unsupported(location, _) => {
      let mut suffix = ""
      for part in location.split(" at ") {
        suffix = part.to_owned()
      }
      let parts = suffix.split(":").collect()
      if parts.length() != 2 {
        return None
      }
      try {
        let line = @string.parse_int(parts[0])
        let column = @string.parse_int(parts[1])
        if line > 0 && column > 0 {
          Some({ line, column, })
        } else {
          None
        }
      } catch {
        _ => None
      }
    }
    _ => None
  }
}

///|
/// No-throw JSON boundary for JavaScript and other string-based hosts.
pub fn evaluate_json(xml : String, response_json : String) -> String {
  let result : Json = try {
    let item = compile_assessment_item(xml)
    let score = item.score_json(response_json)
    { "ok": true, "item": item.describe(), "result": score }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
/// Compile and describe without submitting an attempt.
pub fn describe_json(xml : String) -> String {
  let result : Json = {
    "ok": true,
    "item": compile_assessment_item(xml).describe(),
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
/// Explicit developer-diagnostic boundary; normal evaluate_json has no trace.
pub fn explain_json(xml : String, response_json : String) -> String {
  let result : Json = try {
    let item = compile_assessment_item(xml)
    let explanation = item.explain_json(response_json)
    {
      "ok": true,
      "item": item.describe(),
      "result": explanation.result,
      "steps": explanation.steps,
    }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}
