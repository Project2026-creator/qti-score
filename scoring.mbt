///|
/// Score one attempt. Empty responses are always scored as zero by both
/// supported templates. Multiple match uses bag equality; mapping counts each
/// distinct input value only once. An invalid selection raises QtiError rather
/// than awarding a score for a response that could not be submitted.
pub fn Item::score(self : Item, response : Response) -> Score raise QtiError {
  let values : Array[String] = match response {
    Null => []
    Single(s) => {
      if self.cardinality != Single {
        raise InvalidResponse("expected a multiple response")
      }
      if s == "" {
        []
      } else {
        [s]
      }
    }
    Multiple(xs) => {
      if self.cardinality != Multiple {
        raise InvalidResponse("expected a single response")
      }
      if xs.any(s => s == "") {
        raise InvalidResponse(
          "NULL members are not permitted in a multiple response",
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
  if values.is_empty() {
    return {
      score: 0.0,
      status: Unanswered,
      matches_correct: self.correct.map(_ => false),
    }
  }
  // Selection cardinality counts selections, while map_response de-duplicates
  // values for scoring. Duplicates are retained for exact bag match.
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
  let matches_correct = self.correct.map(correct => bag_equal(values, correct))
  let score = match self.template {
    MatchCorrect => if matches_correct == Some(true) { 1.0 } else { 0.0 }
    MapResponse => {
      let mapping = self.mapping.unwrap()
      let seen : Map[String, Bool] = Map([])
      let mut total = 0.0
      for value in values {
        if seen.contains(value) {
          continue
        }
        seen[value] = true
        let mut mapped = mapping.default_value
        for entry in mapping.entries {
          let equal = if self.base_type == Identifier || entry.case_sensitive {
            value == entry.key
          } else {
            @casefold.casefold(value) == entry.folded_key
          }
          if equal {
            mapped = entry.value
            break
          }
        }
        total += mapped
        if total.is_inf() || total.is_nan() {
          raise InvalidResponse("mapped score exceeds finite numeric range")
        }
      }
      if mapping.lower_bound is Some(lo) && total < lo {
        total = lo
      }
      if mapping.upper_bound is Some(hi) && total > hi {
        total = hi
      }
      total
    }
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
