///|
/// Score without collecting developer diagnostics.
pub fn Item::score(self : Item, response : Response) -> Score raise QtiError {
  self.execute(response, None)
}

///|
/// Execute the same scorer with an explicit developer trace. Trace details can
/// reveal mapping rules; hosts decide whether to expose them to their users.
pub fn Item::explain(
  self : Item,
  response : Response,
) -> Explanation raise QtiError {
  let steps : Array[ScoringStep] = []
  let result = self.execute(response, Some(steps))
  { result, steps, }
}

///|
fn record_step(
  steps : Array[ScoringStep]?,
  operation : String,
  location : SourceLocation,
  details : Json,
) -> Unit {
  if steps is Some(steps) {
    steps.push({ operation, location, details, })
  }
}

///|
fn Item::execute(
  self : Item,
  response : Response,
  steps : Array[ScoringStep]?,
) -> Score raise QtiError {
  let values : Array[String] = match response {
    Null => []
    Number(value) => {
      if !self.base_type.is_numeric() {
        raise InvalidResponse("numeric response requires a numeric item")
      }
      if value.is_inf() || value.is_nan() {
        raise InvalidResponse("numeric response must be finite")
      }
      if self.base_type == Integer &&
        (value.abs() > 9007199254740991.0 || value.trunc() != value) {
        raise InvalidResponse("integer response must be a safe integer")
      }
      [value.to_string()]
    }
    Single(s) => {
      if self.cardinality != Single {
        raise InvalidResponse("string response requires single cardinality")
      }
      if s == "" || (self.base_type.is_numeric() && s.trim() == "") {
        []
      } else {
        [s]
      }
    }
    Multiple(xs) => {
      if self.cardinality != Multiple {
        raise InvalidResponse("multiple response requires multiple cardinality")
      }
      if xs.any(s => s == "") {
        raise InvalidResponse(
          "NULL members are not permitted in a multiple response",
        )
      }
      xs.copy()
    }
    Ordered(xs) => {
      if self.cardinality != Ordered {
        raise InvalidResponse("ordered response requires ordered cardinality")
      }
      if xs.any(s => s == "") {
        raise InvalidResponse(
          "NULL members are not permitted in an ordered response",
        )
      }
      xs.copy()
    }
  }
  if values.length() > 4096 || values.any(v => v.length() > 65536) {
    raise LimitExceeded(
      "response exceeds 4096 values or 65536 UTF-16 code units per value",
    )
  }
  if self.base_type == DirectedPair {
    for i, value in values {
      values[i] = directed_pair(value)
    }
  }
  let empty = values.is_empty()
  record_step(steps, "response", self.processing_source, {
    "status": if empty {
      "unanswered"
    } else {
      "answered"
    },
    "count": values.length(),
  })
  if self.base_type.is_numeric() {
    let numeric = if empty {
      None
    } else {
      // JSON numbers are validated before use; textual integers have stricter
      // lexical rules than the decimal spelling produced by Number::to_string.
      Some(
        match response {
          Number(n) => n
          _ =>
            numeric_value(values[0], self.base_type) catch {
              _ =>
                raise InvalidResponse(
                  "invalid finite \{self.base_type.name()} response",
                )
            }
        },
      )
    }
    if self.slider is Some(spec) && numeric is Some(value) {
      spec.validate(value)
    }
    let correct = self.correct.map(xs => {
      numeric_value(xs[0], self.base_type) catch {
        _ => abort("compiled numeric correct response is invalid")
      }
    })
    let matches_correct = correct.map(c => numeric == Some(c))
    let score = if self.template == NumericRules {
      self.numeric_rule.unwrap().score(numeric, correct, steps)
    } else if self.template == MapResponse {
      self.mapping
      .unwrap()
      .score_numeric(numeric, steps, self.processing_source)
    } else {
      let score = if matches_correct == Some(true) { 1.0 } else { 0.0 }
      record_step(steps, "match_correct", self.processing_source, {
        "matched": matches_correct == Some(true),
        "score": score,
      })
      score
    }
    return {
      score,
      status: if empty {
        Unanswered
      } else {
        Answered
      },
      matches_correct,
    }
  }
  if empty {
    if self.inline_choice is Some(spec) && spec.required {
      raise InvalidResponse("inline choice requires a selection")
    }
    record_step(steps, "null_response", self.processing_source, {
      "score": 0,
      "mapping_bounds_applied": false,
    })
    return {
      score: 0.0,
      status: Unanswered,
      matches_correct: self.correct.map(_ => false),
    }
  }
  // Selection limits count selections; mappings de-duplicate only for scoring.
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
  if self.cardinality == Ordered || self.hottext_passage is Some(_) {
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
  let matches_correct = self.correct.map(correct => {
    if self.cardinality == Ordered {
      values == correct
    } else {
      bag_equal(values, correct)
    }
  })
  let score = match self.template {
    MatchCorrect => {
      let score = if matches_correct == Some(true) { 1.0 } else { 0.0 }
      let details : Json = if self.cardinality == Ordered {
        {
          "matched": matches_correct == Some(true),
          "score": score,
          "comparison": "ordered",
        }
      } else {
        { "matched": matches_correct == Some(true), "score": score }
      }
      record_step(steps, "match_correct", self.processing_source, details)
      score
    }
    MapResponse => {
      let mapping = self.mapping.unwrap()
      let seen : Map[String, Bool] = Map([])
      let mut total = 0.0
      for value in values {
        if seen.contains(value) {
          record_step(steps, "duplicate_ignored", self.processing_source, {
            "value": value,
          })
          continue
        }
        seen[value] = true
        let mut mapped = mapping.default_value
        let mut entry_index : Json = Json::null()
        let mut entry_source = mapping.source
        for i, entry in mapping.entries {
          let equal = if self.base_type != Text || entry.case_sensitive {
            value == entry.key
          } else {
            @casefold.casefold(value) == entry.folded_key
          }
          if equal {
            mapped = entry.value
            entry_index = Json(i)
            entry_source = entry.source
            break
          }
        }
        total += mapped
        if total.is_inf() || total.is_nan() {
          raise InvalidResponse("mapped score exceeds finite numeric range")
        }
        record_step(steps, "map_value", entry_source, {
          "value": value,
          "entry_index": entry_index,
          "used_default": entry_index == Json::null(),
          "contribution": mapped,
          "running_total": total,
        })
      }
      mapping.bounded_score(total, steps)
    }
    NumericRules => abort("non-numeric item has numeric rules")
  }
  { score, status: Answered, matches_correct, }
}

///|
fn bag_equal(left : Array[String], right : Array[String]) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let a = left.copy()
  let b = right.copy()
  a.sort()
  b.sort()
  a == b
}
