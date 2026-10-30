///|
priv struct ProcessingContext {
  program : ProcessingProgram
  variables : Map[String, Json]
  items : Array[Json]
  steps : Array[ScoringStep]?
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
    Reference(mode, id) =>
      if mode == "qti-test-variables" {
        let kind = self.kind.unwrap()
        let values : Array[Json] = []
        for item in context.items {
          context.consume()
          guard item is { "outcomes": Object(outcomes), .. } else {
            raise InvalidResponse("test item requires an outcomes object")
          }
          if outcomes.get(id) is Some(value) && value != Json::null() {
            if value is Array(_) {
              continue
            }
            values.push(processing_scalar(value, kind.base, authored=true))
          }
        }
        if values.is_empty() {
          Json::null()
        } else {
          Json(values)
        }
      } else {
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
              Json(
                mapping.score_values(values, base, context.steps, self.source),
              )
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
      if self.kind is Some(kind) && kind.base == "integer" {
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
fn ProcessingProgram::evaluate(
  self : ProcessingProgram,
  input : Json,
  steps : Array[ScoringStep]?,
) -> Json raise QtiError {
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
        if ids.contains(id) {
          raise InvalidResponse("duplicate test item reference '\{id}'")
        }
        ids[id] = true
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
      variables[declaration.identifier] = if declaration.default_value ==
        Json::null() &&
        declaration.kind.numeric() &&
        declaration.kind.cardinality == Single {
        Json(0.0)
      } else {
        processing_copy(declaration.default_value)
      }
    }
  }
  let context : ProcessingContext = {
    program: self,
    variables,
    items,
    steps,
    remaining: 16384,
  }
  ignore(processing_execute(self.rules, context))
  let result : Map[String, Json] = Map([])
  for d in self.declarations {
    if !d.response {
      result[d.identifier] = processing_copy(variables[d.identifier])
    }
  }
  Json::object(result)
}

///|
/// Evaluate item responses as an object. For test programs use
/// {"items":[{"identifier":"itemRef","outcomes":{"SCORE":2.0}}]}.
/// Outcome variables cannot be supplied by the caller and reset on every run.
pub fn ProcessingProgram::evaluate_json(
  self : ProcessingProgram,
  variables : Json,
) -> Json raise QtiError {
  self.evaluate(variables, None)
}
