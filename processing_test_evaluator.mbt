///|
fn processing_item_field(item : Json, name : String) -> Json? {
  match item {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn processing_item_submitted(item : Json) -> Bool {
  processing_item_field(item, "submitted") != Some(Json(false))
}

///|
fn processing_item_index(item : Json, name : String, fallback : Int32) -> Int32 {
  match processing_item_field(item, name) {
    Some(Number(n, ..)) => n.to_int()
    _ => fallback
  }
}

///|
fn processing_typed_item_value(
  item : Json,
  variable : ProcessingItemVariable,
) -> Json raise QtiError {
  if variable.response && !processing_item_submitted(item) {
    return Json::null()
  }
  let value = match
    processing_item_field(
      item,
      if variable.response {
        "response"
      } else {
        "outcomes"
      },
    ) {
    Some(Object(fields)) =>
      fields.get(variable.identifier).unwrap_or(Json::null())
    _ => Json::null()
  }
  if variable.kind.numeric() && !variable.response {
    let values = match value {
      Array(xs) => xs
      _ => [value]
    }
    if values.any(v => v != Json::null() && !(v is Number(_))) {
      raise InvalidResponse("numeric item variables must contain JSON numbers")
    }
  }
  processing_value(value, variable.kind, authored=true)
}

///|
fn processing_weight(item : Json, id : String?) -> Double raise QtiError {
  guard id is Some(id) else { return 1.0 }
  guard processing_item_field(item, "weights") is Some(Object(weights)) else {
    return 1.0
  }
  guard weights.get(id) is Some(value) else { return 1.0 }
  guard value is Number(weight, ..) && !weight.is_inf() && !weight.is_nan() else {
    raise InvalidResponse("item weights must be finite JSON numbers")
  }
  weight
}

///|
fn processing_apply_weight(
  value : Json,
  weight : Double,
) -> Json raise QtiError {
  if value == Json::null() {
    return value
  }
  if value is Array(values) {
    return Json(values.map(v => processing_apply_weight(v, weight)))
  }
  let result = processing_number(value) * weight
  if result.is_inf() || result.is_nan() {
    raise InvalidResponse(
      "weighted item variable exceeds the finite numeric range",
    )
  }
  Json(result)
}

///|
fn ProcessingItemReference::evaluate(
  self : ProcessingItemReference,
  context : ProcessingContext,
) -> Json raise QtiError {
  let matches = context.items.filter(item => {
    processing_item_field(item, "identifier") == Some(Json(self.identifier))
  })
  let selected = if self.instance_index is Some(index) {
    matches
    .filter(item => processing_item_index(item, "instance_index", 1) == index)
    .get(0)
  } else if matches.length() <= 1 {
    matches.get(0)
  } else {
    // An unqualified reference to repeated individual-submission instances is
    // undefined in QTI. NULL leaves that ambiguity visible to authored rules.
    if matches.any(item => {
        processing_item_field(item, "submission_mode") !=
        Some(Json("simultaneous"))
      }) {
      return Json::null()
    }
    let mut last : Json? = None
    let mut order = -1
    for item in matches {
      context.consume()
      if processing_item_submitted(item) {
        let index = processing_item_index(item, "submission_index", 0)
        if index >= order {
          last = Some(item)
          order = index
        }
      }
    }
    last
  }
  guard selected is Some(item) else { return Json::null() }
  let value = processing_typed_item_value(item, self.variable)
  if self.weight_identifier is Some(_) && self.variable.kind.numeric() {
    processing_apply_weight(
      value,
      processing_weight(item, self.weight_identifier),
    )
  } else {
    value
  }
}

///|
fn ProcessingTestVariables::variable(
  self : ProcessingTestVariables,
  item : Json,
) -> ProcessingItemVariable? raise QtiError {
  guard processing_item_field(item, "identifier") is Some(String(id)) else {
    return None
  }
  if self.schemas is Some(schemas) {
    guard schemas.filter(s => s.identifier == id).get(0) is Some(schema) else {
      return None
    }
    return schema.variables
      .filter(v => v.identifier == self.variable_identifier)
      .get(0)
  }
  // Legacy callers with an explicit base-type can still provide outcomes only.
  // New callers should bind declarations to distinguish integer and float.
  if processing_item_field(item, "outcome_types") is Some(_) ||
    processing_item_field(item, "response_types") is Some(_) {
    let schemas = processing_item_schemas(Json([item]))
    guard schemas is Some(schemas) && schemas.get(0) is Some(schema) else {
      return None
    }
    return schema.variables
      .filter(v => v.identifier == self.variable_identifier)
      .get(0)
  }
  guard processing_item_field(item, "outcomes") is Some(Object(outcomes)) &&
    outcomes.contains(self.variable_identifier) else {
    return None
  }
  let base = self.base_filter.unwrap_or("float")
  let value = outcomes[self.variable_identifier]
  if value is Array(_) {
    return None
  }
  Some({
    identifier: self.variable_identifier,
    kind: processing_type(base, Single),
    response: false,
  })
}

///|
fn ProcessingTestVariables::evaluate(
  self : ProcessingTestVariables,
  context : ProcessingContext,
  source : SourceLocation,
) -> Json raise QtiError {
  let values : Array[Json] = []
  let mut integer = true
  for item in context.items {
    context.consume()
    let schema = if self.schemas is Some(schemas) {
      schemas
      .filter(s => {
        processing_item_field(item, "identifier") == Some(Json(s.identifier))
      })
      .get(0)
    } else {
      None
    }
    let categories = if schema is Some(schema) {
      schema.categories
    } else {
      processing_metadata_identifiers(
        processing_item_field(item, "categories"),
        "item categories",
      )
    }
    let sections = if schema is Some(schema) {
      schema.section_identifiers
    } else {
      processing_metadata_identifiers(
        processing_item_field(item, "section_identifiers"),
        "item sections",
      )
    }
    if !self.includes(categories, sections) {
      continue
    }
    guard self.variable(item) is Some(variable) else { continue }
    if variable.kind.cardinality != Single {
      continue
    }
    if self.base_filter is Some(base) {
      if variable.kind.base != base {
        continue
      }
    } else if !variable.kind.numeric() {
      continue
    }
    let value = processing_typed_item_value(item, variable)
    if value == Json::null() {
      continue
    }
    if self.weight_identifier is Some(_) {
      values.push(
        processing_apply_weight(
          value,
          processing_weight(item, self.weight_identifier),
        ),
      )
      integer = false
    } else {
      values.push(value)
      if variable.kind.base != "integer" {
        integer = false
      }
    }
  }
  context.dynamic_bases["\{source.line}:\{source.column}"] = if integer {
    "integer"
  } else {
    "float"
  }
  if values.is_empty() {
    Json::null()
  } else {
    Json(values)
  }
}

///|
fn ProcessingExpression::runtime_base(
  self : ProcessingExpression,
  context : ProcessingContext,
) -> String? {
  match self.expression {
    TestVariables(selector) =>
      if selector.base_filter is None && selector.weight_identifier is None {
        context.dynamic_bases.get("\{self.source.line}:\{self.source.column}")
      } else {
        self.kind.map(k => k.base)
      }
    Operator(name, args, _) =>
      if [
          "qti-sum", "qti-product", "qti-subtract", "qti-min", "qti-max", "qti-multiple",
          "qti-ordered", "qti-index",
        ].contains(name) &&
        self.kind is Some(k) &&
        k.numeric() {
        if args.any(a => a.runtime_base(context) == Some("float")) {
          Some("float")
        } else {
          Some("integer")
        }
      } else {
        self.kind.map(k => k.base)
      }
    _ => self.kind.map(k => k.base)
  }
}
