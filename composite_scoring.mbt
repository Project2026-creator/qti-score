///|
priv enum CompositeValue {
  Null
  Text(String)
  Number(Double)
} derive(Eq)

///|
fn composite_value(
  response : Response,
  base_type : BaseType,
) -> CompositeValue raise QtiError {
  match response {
    Null => Null
    Single(text) => {
      if text.length() > 65536 {
        raise LimitExceeded("response exceeds 65536 UTF-16 code units")
      }
      if text == "" || (base_type.is_numeric() && text.trim() == "") {
        return Null
      }
      if base_type == Text || base_type == Identifier {
        return Text(text)
      }
      Number(
        numeric_value(text, base_type) catch {
          _ =>
            raise InvalidResponse("invalid finite \{base_type.name()} response")
        },
      )
    }
    Number(value) => {
      if !base_type.is_numeric() ||
        value.is_nan() ||
        value.is_inf() ||
        (
          base_type == Integer &&
          (value.trunc() != value || value.abs() > 9007199254740991.0)
        ) {
        raise InvalidResponse("invalid numeric response for composite entry")
      }
      Number(value)
    }
    _ => raise InvalidResponse("composite entries require scalar responses")
  }
}

///|
fn CompositeBinding::matches(
  self : CompositeBinding,
  value : CompositeValue,
) -> Bool? {
  self.correct.map(values => {
    match value {
      Null => false
      Text(text) => text == values[0]
      Number(number) =>
        number ==
        (numeric_value(values[0], self.base_type) catch {
          _ => abort("invalid compiled correct number")
        })
    }
  })
}

///|
pub fn CompositeItem::score_responses(
  self : CompositeItem,
  responses : Map[String, Response],
) -> Score raise QtiError {
  self.execute_responses(responses, None)
}

///|
pub fn CompositeItem::explain_responses(
  self : CompositeItem,
  responses : Map[String, Response],
) -> Explanation raise QtiError {
  let steps : Array[ScoringStep] = []
  let result = self.execute_responses(responses, Some(steps))
  { result, steps, }
}

///|
fn CompositeItem::execute_responses(
  self : CompositeItem,
  responses : Map[String, Response],
  steps : Array[ScoringStep]?,
) -> Score raise QtiError {
  for id, _ in responses {
    if !self.bindings.any(b => b.identifier == id) {
      raise InvalidResponse("unknown response identifier '\{id}'")
    }
  }
  let values = self.bindings.map(b => {
    b.response_value(responses.get(b.identifier).unwrap_or(Response::Null))
  })
  let mut all_correct = Some(true)
  for i, binding in self.bindings {
    let value = values[i]
    match binding.matches(value) {
      None => all_correct = None
      Some(false) if all_correct is Some(_) => all_correct = Some(false)
      _ => ()
    }
    record_step(steps, "response", binding.source, {
      "identifier": binding.identifier,
      "status": if value == Null {
        "unanswered"
      } else {
        "answered"
      },
      "count": if value == Null {
        0
      } else {
        1
      },
    })
  }
  let mut total = 0.0
  record_step(steps, "set_score", self.source, { "score": 0 })
  for rule in self.rules {
    let binding = self.bindings[rule.binding]
    let value = values[rule.binding]
    for branch_index, branch in rule.branches {
      let (selected, condition) : (Bool, Json?) = match branch.credit {
        Mapped => (value != Null, None)
        Matched(_) => (binding.matches(value) == Some(true), None)
        Compared(comparison, _) => {
          let response = match value {
            Number(n) => Some(n)
            _ => None
          }
          let correct = binding.correct.map(v => {
            numeric_value(v[0], binding.base_type) catch {
              _ => abort("invalid compiled correct number")
            }
          })
          let (matched, details) = comparison.evaluate(response, correct)
          (matched == Some(true), Some(details))
        }
      }
      let detail : Json = {
        "identifier": binding.identifier,
        "selected": selected,
      }
      if detail is Object(fields) {
        if rule.branches.length() > 1 || condition is Some(_) {
          fields["branch"] = Json(branch_index)
        }
        if condition is Some(comparison) {
          fields["condition"] = comparison
        }
      }
      record_step(steps, "composite_condition", branch.source, detail)
      if !selected {
        continue
      }
      let contribution = match branch.credit {
        Matched(weight) | Compared(_, weight) => weight
        Mapped =>
          match value {
            Text(text) =>
              binding.mapping
              .unwrap()
              .score_values([text], binding.base_type, steps, branch.source)
            Number(n) =>
              binding.mapping
              .unwrap()
              .score_numeric(Some(n), steps, branch.source)
            Null => abort("NULL response passed non-NULL guard")
          }
      }
      total += contribution
      if total.is_nan() || total.is_inf() {
        raise InvalidResponse("composite score exceeds finite range")
      }
      record_step(steps, "composite_add", branch.source, {
        "identifier": binding.identifier,
        "contribution": contribution,
        "score": total,
      })
      // QTI response-else-if stops at the first true branch of this condition.
      break
    }
  }

  {
    score: total,
    status: if values.all(v => v == Null) {
      Unanswered
    } else {
      Answered
    },
    matches_correct: all_correct,
  }
}

///|
fn CompositeItem::parse_responses(
  self : CompositeItem,
  input : String,
) -> Map[String, Response] raise QtiError {
  if input.length() > 1048576 {
    raise LimitExceeded("response JSON exceeds 1048576 UTF-16 code units")
  }
  let json = @json.parse(
    input[:],
    max_nesting_depth=16,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise InvalidResponse("malformed response JSON")
  }
  guard json is Object(fields) else {
    raise InvalidResponse("expected a composite response object")
  }
  let responses : Map[String, Response] = Map([])
  for id, value in fields {
    let mut base_type : BaseType? = None
    for binding in self.bindings {
      if binding.identifier == id {
        base_type = Some(binding.base_type)
      }
    }
    guard base_type is Some(kind) else {
      raise InvalidResponse("unknown response identifier '\{id}'")
    }
    if kind == Integer && value is Number(_, repr~) && repr is Some(raw) {
      ignore(
        numeric_value(raw, Integer) catch {
          _ =>
            raise InvalidResponse(
              "JSON integer must be safe decimal integer digits",
            )
        },
      )
    }
    responses[id] = response_from_json({ "RESPONSE": value })
  }
  responses
}

///|
pub fn CompositeItem::score_json(
  self : CompositeItem,
  input : String,
) -> Score raise QtiError {
  self.score_responses(self.parse_responses(input))
}

///|
pub fn CompositeItem::explain_json(
  self : CompositeItem,
  input : String,
) -> Explanation raise QtiError {
  self.explain_responses(self.parse_responses(input))
}
