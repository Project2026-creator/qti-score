///|
fn Mapping::bounded_score(
  self : Mapping,
  raw : Double,
  steps : Array[ScoringStep]?,
) -> Double {
  let mut total = raw
  if self.lower_bound is Some(lo) && total < lo {
    total = lo
  }
  if self.upper_bound is Some(hi) && total > hi {
    total = hi
  }
  let lo : Json = match self.lower_bound {
    Some(n) => Json(n)
    None => Json::null()
  }
  let hi : Json = match self.upper_bound {
    Some(n) => Json(n)
    None => Json::null()
  }
  record_step(steps, "mapping_bounds", self.source, {
    "raw_score": raw,
    "lower": lo,
    "upper": hi,
    "score": total,
    "adjusted": total != raw,
  })
  total
}

///|
fn Mapping::score_numeric(
  self : Mapping,
  response : Double?,
  steps : Array[ScoringStep]?,
  source : SourceLocation,
) -> Double {
  guard response is Some(value) else {
    record_step(steps, "null_response", source, {
      "score": 0,
      "mapping_bounds_applied": false,
    })
    return 0.0
  }
  let mut mapped = self.default_value
  let mut entry_index : Json = Json::null()
  let mut entry_source = self.source
  for i, entry in self.entries {
    if entry.numeric_key == Some(value) {
      mapped = entry.value
      entry_index = Json(i)
      entry_source = entry.source
      break
    }
  }
  record_step(steps, "map_value", entry_source, {
    "value": value,
    "entry_index": entry_index,
    "used_default": entry_index == Json::null(),
    "contribution": mapped,
    "running_total": mapped,
  })
  self.bounded_score(mapped, steps)
}
