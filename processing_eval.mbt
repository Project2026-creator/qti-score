///|
priv struct ProcessingContext {
  program : ProcessingProgram
  variables : Map[String, Json]
  items : Array[Json]
  steps : Array[ScoringStep]?
  dynamic_bases : Map[String, String]
  mut remaining : Int32
}

///|
fn processing_copy(value : Json) -> Json {
  match value {
    Array(xs) => Json(xs.map(processing_copy))
    Object(fields) => {
      let copy : Map[String, Json] = Map([])
      for k, v in fields {
        copy[k] = processing_copy(v)
      }
      Json::object(copy)
    }
    _ => value
  }
}

///|
fn processing_json(input : String) -> Json raise QtiError {
  if input.length() > 1048576 {
    raise LimitExceeded("processing JSON exceeds 1048576 UTF-16 units")
  }
  @json.parse(
    input[:],
    max_nesting_depth=16,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise InvalidResponse("malformed processing JSON")
  }
}

///|
fn processing_scalar(
  value : Json,
  base : String,
  authored~ : Bool = false,
) -> Json raise QtiError {
  if value == Json::null() {
    return Json::null()
  }
  match (base, value) {
    ("boolean", True) | ("boolean", False) => value
    ("identifier", String(text)) => {
      if text == "" {
        return Json::null()
      }
      if text.length() > 65536 {
        raise LimitExceeded("processing string exceeds 65536 UTF-16 units")
      }
      ignore(
        identifier(text, "processing response") catch {
          _ => raise InvalidResponse("invalid identifier response")
        },
      )
      value
    }
    ("string", String(text)) => {
      if text.length() > 65536 {
        raise LimitExceeded("processing string exceeds 65536 UTF-16 units")
      }
      if text == "" {
        Json::null()
      } else {
        value
      }
    }
    ("directedPair", String(text)) =>
      if text == "" {
        Json::null()
      } else {
        Json(directed_pair(text))
      }
    ("integer" | "float", Number(number, repr~)) => {
      if number.is_nan() ||
        number.is_inf() ||
        (
          base == "integer" &&
          (number.trunc() != number || number.abs() > 9007199254740991.0)
        ) {
        raise InvalidResponse(
          "processing number is nonfinite or outside the safe integer range",
        )
      }
      if base == "integer" && !authored && repr is Some(raw) {
        ignore(
          numeric_value(raw, Integer) catch {
            _ =>
              raise InvalidResponse("JSON integer must use safe decimal digits")
          },
        )
      }
      Json(number)
    }
    ("integer" | "float", String(text)) => {
      if text.trim() == "" {
        return Json::null()
      }
      Json(
        numeric_value(text, if base == "integer" { Integer } else { Float }) catch {
          _ => raise InvalidResponse("invalid numeric processing response")
        },
      )
    }
    _ =>
      raise InvalidResponse(
        "processing value has the wrong base-type '\{base}'",
      )
  }
}

///|
fn processing_value(
  value : Json,
  kind : ProcessingType,
  authored~ : Bool = false,
) -> Json raise QtiError {
  if value == Json::null() {
    return value
  }
  if kind.cardinality == Single {
    return processing_scalar(value, kind.base, authored~)
  }
  guard value is Array(values) else {
    raise InvalidResponse("processing value requires a container")
  }
  if values.length() > 4096 {
    raise LimitExceeded("processing container exceeds 4096 values")
  }
  if values.is_empty() {
    return Json::null()
  }
  let normalized = values.map(v => processing_scalar(v, kind.base, authored~))
  if normalized.any(v => v == Json::null()) {
    raise InvalidResponse("NULL container members are not permitted")
  }
  Json(normalized)
}

///|
fn processing_result_value(
  value : Json,
  kind : ProcessingType,
) -> Json raise QtiError {
  if kind.numeric() {
    let values = match value {
      Array(xs) => xs
      _ => [value]
    }
    if values.any(v => v != Json::null() && !(v is Number(_))) {
      raise InvalidResponse(
        "numeric outcome variables must contain JSON numbers",
      )
    }
  }
  processing_value(value, kind, authored=true)
}

///|
fn processing_default_outcome(declaration : ProcessingDeclaration) -> Json {
  if declaration.default_value == Json::null() &&
    declaration.kind.numeric() &&
    declaration.kind.cardinality == Single {
    Json(0.0)
  } else {
    processing_copy(declaration.default_value)
  }
}

///|
// Initial test outcomes are available to entry conditions before any submission.
// Initializing them must not execute the author's outcome-processing rules.
fn ProcessingProgram::initial_outcomes(self : ProcessingProgram) -> Json {
  let outcomes : Map[String, Json] = Map([])
  for declaration in self.declarations {
    if !declaration.response {
      outcomes[declaration.identifier] = processing_default_outcome(declaration)
    }
  }
  Json::object(outcomes)
}

///|
fn ProcessingContext::consume(self : ProcessingContext) -> Unit raise QtiError {
  self.remaining -= 1
  if self.remaining < 0 {
    raise LimitExceeded("processing exceeds 16384 evaluation operations")
  }
}

///|
fn processing_number(value : Json) -> Double raise QtiError {
  guard value is Number(number, ..) else {
    raise InvalidResponse("numeric expression did not return a number")
  }
  number
}

///|
fn processing_numbers(value : Json) -> Array[Double] raise QtiError {
  match value {
    Array(values) => values.map(processing_number)
    _ => [processing_number(value)]
  }
}

///|
fn processing_bag_equal(a : Array[Json], b : Array[Json]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let used : Array[Bool] = Array::make(b.length(), false)
  for value in a {
    let mut found = false
    for i, other in b {
      if !used[i] && value == other {
        used[i] = true
        found = true
        break
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
fn processing_integer_add(a : Int64, b : Int64) -> Int64 raise QtiError {
  if (b > 0L && a > 9223372036854775807L - b) ||
    (b < 0L && a < -9223372036854775808L - b) {
    raise InvalidResponse(
      "integer intermediate exceeds the checked Int64 range",
    )
  }
  a + b
}

///|
fn processing_integer_product(a : Int64, b : Int64) -> Int64 raise QtiError {
  if a == 0L || b == 0L {
    return 0L
  }
  let overflow = if a > 0L {
    if b > 0L {
      a > 9223372036854775807L / b
    } else {
      b < -9223372036854775808L / a
    }
  } else if b > 0L {
    a < -9223372036854775808L / b
  } else {
    a < 9223372036854775807L / b
  }
  if overflow {
    raise InvalidResponse("integer product exceeds the checked Int64 range")
  }
  a * b
}

///|
// Input integers are exactly representable JSON numbers. Keep arithmetic in
// Int64 until the result has passed the public safe-integer boundary check.
fn processing_integer_operation(
  name : String,
  numbers : Array[Double],
) -> Json raise QtiError {
  let integers = numbers.map(n => n.to_int64())
  let a = integers[0]
  let result = match name {
    "qti-sum" => {
      let mut total = 0L
      for n in integers {
        total = processing_integer_add(total, n)
      }
      total
    }
    "qti-product" => {
      let mut total = 1L
      for n in integers {
        total = processing_integer_product(total, n)
      }
      total
    }
    "qti-subtract" => processing_integer_add(a, -integers[1])
    "qti-integer-divide" | "qti-integer-modulus" => {
      let b = integers[1]
      // The zero divisor has already produced NULL before this helper runs.
      let quotient = a / b
      let remainder = a % b
      let adjust = remainder != 0L && (a < 0L) != (b < 0L)
      if name == "qti-integer-divide" {
        if adjust {
          quotient - 1L
        } else {
          quotient
        }
      } else if adjust {
        remainder + b
      } else {
        remainder
      }
    }
    "qti-min" => {
      let mut minimum = a
      for n in integers {
        if n < minimum {
          minimum = n
        }
      }
      minimum
    }
    "qti-max" => {
      let mut maximum = a
      for n in integers {
        if n > maximum {
          maximum = n
        }
      }
      maximum
    }
    _ => abort("unknown compiled integer operator")
  }
  if result < -9007199254740991L || result > 9007199254740991L {
    raise InvalidResponse(
      "processing integer result exceeds the exact JSON/JS range",
    )
  }
  Json(result.to_double())
}

///|
fn ProcessingExpression::evaluate(
  self : ProcessingExpression,
  context : ProcessingContext,
) -> Json raise QtiError {
  context.consume()
  match self.expression {
    Literal(value) => processing_copy(value)
    ItemReference(reference) => reference.evaluate(context)
    TestVariables(selector) => selector.evaluate(context, self.source)
    Reference(mode, id) => {
      let declaration = context.program.declaration(id).unwrap()
      match mode {
        "qti-variable" => processing_copy(context.variables[id])
        "qti-correct" => processing_copy(declaration.correct)
        "qti-default" => processing_copy(declaration.default_value)
        "qti-map-response" => {
          let value = context.variables[id]
          if value == Json::null() {
            return Json::null()
          }
          let mapping = declaration.mapping.unwrap()
          if declaration.kind.numeric() {
            if value is Array(values) {
              // Mapping de-duplicates numeric values before summing.
              let seen : Array[Double] = []
              let mut total = 0.0
              for value in values {
                let n = processing_number(value)
                if seen.contains(n) {
                  continue
                }
                seen.push(n)
                let matched = mapping.entries
                  .filter(e => e.numeric_key == Some(n))
                  .get(0)
                total += matched
                  .map(e => e.value)
                  .unwrap_or(mapping.default_value)
              }
              if total.is_nan() || total.is_inf() {
                raise InvalidResponse("mapping exceeds finite range")
              }
              Json(mapping.bounded_score(total, context.steps))
            } else {
              Json(
                mapping.score_numeric(
                  Some(processing_number(value)),
                  context.steps,
                  self.source,
                ),
              )
            }
          } else {
            let values = match value {
              String(s) => [s]
              Array(xs) =>
                xs.map(v => {
                  guard v is String(s) else {
                    abort("validated mapped response is not text")
                  }
                  s
                })
              _ => abort("validated mapped response has invalid type")
            }
            let base = match declaration.kind.base {
              "identifier" => Identifier
              "directedPair" => DirectedPair
              _ => Text
            }
            Json(mapping.score_values(values, base, context.steps, self.source))
          }
        }
        _ => abort("unknown compiled variable reference")
      }
    }
    Operator(name, args, tolerance) => {
      let values = args.map(arg => arg.evaluate(context))
      if name == "qti-is-null" {
        return Json(values[0] == Json::null())
      }
      if name == "qti-container-size" {
        return Json(
          match values[0] {
            Array(xs) => xs.length()
            _ => 0
          },
        )
      }
      if name == "qti-multiple" || name == "qti-ordered" {
        let contents : Array[Json] = []
        for value in values {
          match value {
            Null => ()
            Array(xs) => contents.append(xs)
            _ => contents.push(value)
          }
          if contents.length() > 4096 {
            raise LimitExceeded("constructed container exceeds 4096 values")
          }
        }
        return if contents.is_empty() { Json::null() } else { Json(contents) }
      }
      if name == "qti-and" || name == "qti-or" {
        let decisive = if name == "qti-and" { Json(false) } else { Json(true) }
        if values.contains(decisive) {
          return decisive
        }
        return if values.contains(Json::null()) {
          Json::null()
        } else {
          Json(name == "qti-and")
        }
      }
      if values.contains(Json::null()) {
        return Json::null()
      }
      if name == "qti-not" {
        return Json(values[0] == Json(false))
      }
      if name == "qti-match" || name == "qti-string-match" {
        let matched = if args[0].kind is Some(k) && k.cardinality == Multiple {
          guard values[0] is Array(a) && values[1] is Array(b) else {
            abort("validated match container expected")
          }
          processing_bag_equal(a, b)
        } else {
          values[0] == values[1]
        }
        return Json(matched)
      }
      if name == "qti-member" {
        guard values[1] is Array(xs) else {
          abort("compiled member needs a container")
        }
        return Json(xs.contains(values[0]))
      }
      if name == "qti-index" {
        guard values[0] is Array(xs) else {
          abort("compiled index needs a container")
        }
        let index = processing_number(values[1]).to_int() - 1
        return xs.get(index).unwrap_or(Json::null())
      }
      if name == "qti-integer-to-float" {
        return values[0]
      }
      let numbers : Array[Double] = []
      for value in values {
        numbers.append(processing_numbers(value))
      }
      let x = numbers[0]
      if name == "qti-equal" {
        let y = numbers[1]
        let tolerance = tolerance.unwrap()
        if tolerance.mode == "exact" {
          return Json(x == y)
        }
        let width_lower = if tolerance.mode == "relative" {
          x.abs() * tolerance.lower / 100.0
        } else {
          tolerance.lower
        }
        let width_upper = if tolerance.mode == "relative" {
          x.abs() * tolerance.upper / 100.0
        } else {
          tolerance.upper
        }
        let lo = x - width_lower
        let hi = x + width_upper
        if lo.is_inf() || hi.is_inf() {
          raise InvalidResponse("numeric tolerance exceeds finite range")
        }
        return Json(
          (if tolerance.include_lower { y >= lo } else { y > lo }) &&
          (if tolerance.include_upper { y <= hi } else { y < hi }),
        )
      }
      if ["qti-lt", "qti-lte", "qti-gt", "qti-gte"].contains(name) {
        let y = numbers[1]
        return Json(
          match name {
            "qti-lt" => x < y
            "qti-lte" => x <= y
            "qti-gt" => x > y
            _ => x >= y
          },
        )
      }
      if ["qti-divide", "qti-integer-divide", "qti-integer-modulus"].contains(
          name,
        ) &&
        numbers[1] == 0.0 {
        return Json::null()
      }
      if self.runtime_base(context) == Some("integer") {
        return processing_integer_operation(name, numbers)
      }
      let result = match name {
        "qti-sum" => {
          let mut total = 0.0
          for n in numbers {
            total += n
          }
          total
        }
        "qti-product" => {
          let mut total = 1.0
          for n in numbers {
            total *= n
          }
          total
        }
        "qti-subtract" => x - numbers[1]
        "qti-divide" => x / numbers[1]
        "qti-integer-divide" => (x / numbers[1]).floor()
        "qti-integer-modulus" => x - (x / numbers[1]).floor() * numbers[1]
        "qti-min" => {
          let mut minimum = x
          for n in numbers {
            if n < minimum {
              minimum = n
            }
          }
          minimum
        }
        "qti-max" => {
          let mut maximum = x
          for n in numbers {
            if n > maximum {
              maximum = n
            }
          }
          maximum
        }
        _ => abort("unknown compiled numeric operator")
      }
      if result.is_nan() ||
        result.is_inf() ||
        (
          self.kind is Some(k) &&
          k.base == "integer" &&
          result.abs() > 9007199254740991.0
        ) {
        raise InvalidResponse(
          "processing result exceeds finite numeric/safe integer range",
        )
      }
      Json(result)
    }
  }
}

///|
fn processing_execute(
  rules : Array[ProcessingRule],
  context : ProcessingContext,
) -> Bool raise QtiError {
  for rule in rules {
    context.consume()
    match rule {
      Assign(id, expression, source) => {
        let value = expression.evaluate(context)
        context.variables[id] = processing_copy(value)
        record_step(context.steps, "set_outcome_value", source, {
          "identifier": id,
          "value": value,
        })
      }
      Condition(branches) =>
        for index, branch in branches {
          let selected = branch.predicate
            .map(p => p.evaluate(context) == Json(true))
            .unwrap_or(true)
          record_step(context.steps, "processing_condition", branch.source, {
            "branch": index,
            "selected": selected,
          })
          if selected {
            if processing_execute(branch.rules, context) {
              return true
            }
            break
          }
        }
      Exit(source) => {
        record_step(context.steps, "exit_processing", source, {})
        return true
      }
    }
  }
  false
}

///|
fn ProcessingProgram::context(
  self : ProcessingProgram,
  input : Json,
  steps : Array[ScoringStep]?,
  current_outcomes~ : Json? = None,
) -> ProcessingContext raise QtiError {
  guard input is Object(fields) else {
    raise InvalidResponse("processing environment must be an object")
  }
  let variables : Map[String, Json] = Map([])
  let items : Array[Json] = []
  for key, value in fields {
    if self.test_mode && key == "items" {
      guard value is Array(values) else {
        raise InvalidResponse("test environment items must be an array")
      }
      if values.length() > 4096 {
        raise LimitExceeded("test environment exceeds 4096 items")
      }
      let ids : Map[String, Bool] = Map([])
      for item in values {
        guard item is { "identifier": String(id), "outcomes": Object(_), .. } else {
          raise InvalidResponse(
            "test environment items require identifier and outcomes",
          )
        }
        guard item is Object(metadata) else {
          abort("validated item must be an object")
        }
        for name in ["instance_index", "sequence_index", "submission_index"] {
          if metadata.get(name) is Some(value) {
            guard value is Number(n, ..) &&
              !n.is_inf() &&
              !n.is_nan() &&
              n.trunc() == n &&
              n >= (if name == "submission_index" { 0.0 } else { 1.0 }) &&
              n <=
              (if name == "submission_index" { 2147483647.0 } else { 4096.0 }) else {
              raise InvalidResponse(
                "item \{name} must be a safe positive integer",
              )
            }
          }
        }
        if metadata.get("submitted") is Some(value) &&
          value != Json(true) &&
          value != Json(false) {
          raise InvalidResponse("item submitted must be boolean")
        }
        if metadata.get("submission_mode") is Some(mode) &&
          mode != Json("individual") &&
          mode != Json("simultaneous") {
          raise InvalidResponse("invalid item submission_mode")
        }
        if metadata.get("response") is Some(value) && !(value is Object(_)) {
          raise InvalidResponse("item response must be an object")
        }
        ignore(
          processing_metadata_identifiers(
            metadata.get("categories"),
            "item categories",
          ),
        )
        ignore(
          processing_metadata_identifiers(
            metadata.get("section_identifiers"),
            "item sections",
          ),
        )
        if metadata.get("weights") is Some(value) {
          guard value is Object(weights) else {
            raise InvalidResponse("item weights must be an object")
          }
          for _, weight in weights {
            guard weight is Number(n, ..) && !n.is_nan() && !n.is_inf() else {
              raise InvalidResponse("item weights must be finite JSON numbers")
            }
          }
        }
        let index = processing_item_index(item, "instance_index", 1)
        let identity = "\{id}:\{index}"
        if ids.contains(identity) {
          raise InvalidResponse("duplicate test item instance '\{id}'")
        }
        ids[identity] = true
        items.push(item)
      }
    } else {
      guard self.declaration(key) is Some(d) && d.response else {
        raise InvalidResponse("unknown response variable '\{key}'")
      }
      variables[key] = processing_value(value, d.kind)
    }
  }
  for declaration in self.declarations {
    if declaration.response {
      if !variables.contains(declaration.identifier) {
        variables[declaration.identifier] = Json::null()
      }
    } else {
      variables[declaration.identifier] = if current_outcomes is Some(_) {
        Json::null()
      } else {
        processing_default_outcome(declaration)
      }
    }
  }
  if current_outcomes is Some(outcomes) {
    guard outcomes is Object(values) else {
      raise InvalidResponse("current test outcomes must be an object")
    }
    for id, value in values {
      guard self.declaration(id) is Some(declaration) && !declaration.response else {
        raise InvalidResponse("unknown test outcome variable '\{id}'")
      }
      variables[id] = processing_result_value(value, declaration.kind)
    }
  }
  {
    program: self,
    variables,
    items,
    steps,
    dynamic_bases: Map([]),
    remaining: 16384,
  }
}

///|
fn ProcessingProgram::evaluate(
  self : ProcessingProgram,
  input : Json,
  steps : Array[ScoringStep]?,
) -> Json raise QtiError {
  let context = self.context(input, steps)
  ignore(processing_execute(self.rules, context))
  let result : Map[String, Json] = Map([])
  for d in self.declarations {
    if !d.response {
      result[d.identifier] = processing_copy(context.variables[d.identifier])
    }
  }
  Json::object(result)
}

///|
/// Evaluate item responses as an object. Test inputs contain an `items` array
/// with each source identifier, outcomes and last submitted response object.
/// Repeated sources also provide a one-based `instance_index`; submission
/// metadata distinguishes the last simultaneous submission from saved drafts.
/// Item weights are finite numbers keyed by their authored identifiers.
/// Outcome variables cannot be supplied by the caller and reset on every run.
pub fn ProcessingProgram::evaluate_json(
  self : ProcessingProgram,
  variables : Json,
) -> Json raise QtiError {
  self.evaluate(variables, None)
}
