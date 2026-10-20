///|
fn BaseType::is_numeric(self : BaseType) -> Bool {
  self == Integer || self == Float
}

///|
// The integer profile is deliberately restricted to the exact JSON/JS range.
// Validate lexical integers before converting them to Double.
fn numeric_value(text : String, base_type : BaseType) -> Double raise {
  let trimmed = text.trim().to_owned()
  if trimmed == "" || trimmed.contains("_") {
    fail("expected a finite decimal number")
  }
  if base_type == Integer {
    let digits = if trimmed.has_prefix("+") || trimmed.has_prefix("-") {
      trimmed[1:].to_owned()
    } else {
      trimmed
    }
    if digits == "" || !digits.iter().all(c => '0' <= c && c <= '9') {
      fail("integer must use decimal digits without fraction or exponent")
    }
    let value = @string.parse_int64(trimmed[:], base=10)
    if value < -9007199254740991L || value > 9007199254740991L {
      fail("integer exceeds the exact JSON/JS range")
    }
    return value.to_double()
  }
  let value = @string.parse_double(trimmed[:])
  if value.is_nan() || value.is_inf() {
    fail("number must be finite")
  }
  value
}

///|
fn authored_number(
  text : String,
  base_type : BaseType,
  node : Node,
) -> Double raise QtiError {
  numeric_value(text, base_type) catch {
    _ =>
      raise InvalidItem(
        node.location(),
        "invalid finite \{base_type.name()} value",
      )
  }
}

///|
fn BaseType::name(self : BaseType) -> String {
  match self {
    Identifier => "identifier"
    Text => "string"
    Integer => "integer"
    Float => "float"
  }
}
