///|
fn Mapping::score_values(
  self : Mapping,
  values : Array[String],
  base_type : BaseType,
  steps : Array[ScoringStep]?,
  processing_source : SourceLocation,
) -> Double raise QtiError {
  let seen : Map[String, Bool] = Map([])
  let mut total = 0.0
  for value in values {
    if seen.contains(value) {
      record_step(steps, "duplicate_ignored", processing_source, {
        "value": value,
      })
      continue
    }
    seen[value] = true
    let mut mapped = self.default_value
    let mut entry_index : Json = Json::null()
    let mut entry_source = self.source
    for i, entry in self.entries {
      let equal = if base_type != Text || entry.case_sensitive {
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
  self.bounded_score(total, steps)
}
