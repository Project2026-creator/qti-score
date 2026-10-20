///|
/// Parse a response object of the form {"RESPONSE": string | string[] | null}.
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
        "RESPONSE must be a string, an array of strings, or null",
      )
  }
}

///|
/// Score a JSON-encoded response, reusing an already compiled item.
pub fn Item::score_json(
  self : Item,
  response_json : String,
) -> Score raise QtiError {
  if response_json.length() > 1048576 {
    raise LimitExceeded("response JSON exceeds 1048576 UTF-16 code units")
  }
  let parsed = @json.parse(
    response_json[:],
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise InvalidResponse("malformed response JSON")
  }
  self.score(response_from_json(parsed))
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
  {
    "identifier": self.identifier,
    "title": self.title,
    "response_identifier": self.response_identifier,
    "cardinality": match self.cardinality {
      Single => "single"
      Multiple => "multiple"
    },
    "base_type": match self.base_type {
      Identifier => "identifier"
      Text => "string"
    },
    "template": match self.template {
      MatchCorrect => "match_correct"
      MapResponse => "map_response"
    },
    "prompt": self.prompt,
    "min_choices": self.min_choices,
    "max_choices": self.max_choices,
    "choices": choices,
  }
}

///|
pub fn QtiError::code(self : QtiError) -> String {
  match self {
    InvalidXml(_, _, _) => "invalid_xml"
    InvalidItem(_, _) => "invalid_item"
    Unsupported(_, _) => "unsupported"
    InvalidResponse(_) => "invalid_response"
    LimitExceeded(_) => "limit_exceeded"
  }
}

///|
pub fn QtiError::message(self : QtiError) -> String {
  match self {
    InvalidXml(message, line, column) => "\{message} at \{line}:\{column}"
    InvalidItem(location, message) | Unsupported(location, message) =>
      "\{location}: \{message}"
    InvalidResponse(message) | LimitExceeded(message) => message
  }
}

///|
pub impl ToJson for QtiError with fn to_json(self) {
  let location : Json = match self {
    InvalidXml(_, line, column) => { "line": line, "column": column }
    _ => Json::null()
  }
  { "code": self.code(), "message": self.message(), "location": location }
}

///|
/// No-throw JSON boundary for JavaScript and other string-based hosts.
pub fn evaluate_json(xml : String, response_json : String) -> String {
  let result : Json = try {
    let item = compile_item(xml)
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
  let result : Json = { "ok": true, "item": compile_item(xml).describe() } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}
