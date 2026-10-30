///|
priv struct PrintedValue {
  identifier : String
  base : String
  precision : Int32?
  radix : Int32
  integer_format : Bool
  index : Int32?
  delimiter : String
} derive(Debug)

///|
priv enum ContentPart {
  Text(String)
  Printed(PrintedValue)
  Feedback(String, String, Bool, Array[ContentPart])
} derive(Debug)

///|
priv struct DynamicPresentation {
  fragments : Array[Array[ContentPart]]
} derive(Debug)

///|
let content_marker = "\u{e000}qti-content:"

///|
fn content_has_feedback(parts : Array[ContentPart]) -> Bool {
  parts.any(part => {
    match part {
      Feedback(_) => true
      _ => false
    }
  })
}

///|
fn content_outcome(
  node : Node,
  program : ProcessingProgram,
  attribute : String,
) -> ProcessingDeclaration raise QtiError {
  let id = identifier(node.required(attribute), node.location())
  guard program.declaration(id) is Some(declaration) && !declaration.response else {
    raise InvalidItem(
      node.location(),
      "content requires a declared outcome variable '\{id}'",
    )
  }
  declaration
}

///|
fn content_show(node : Node) -> Bool raise QtiError {
  match node.attr("show-hide").unwrap_or("show") {
    "show" => true
    "hide" => false
    _ => raise InvalidItem(node.location(), "show-hide must be show or hide")
  }
}

///|
fn content_printed(
  node : Node,
  program : ProcessingProgram,
) -> PrintedValue raise QtiError {
  node.only_attributes([
    "identifier", "format", "base", "index", "delimiter", "power-form", "class",
    "id", "label", "dir",
  ])
  node.only_children([])
  let declaration = content_outcome(node, program, "identifier")
  let kind = declaration.kind
  if xml_bool(node, "power-form", default=false) {
    raise Unsupported(node.location(), "printed variable power form")
  }
  let index = if node.attr("index") is Some(_) {
    if kind.cardinality != Ordered {
      raise InvalidItem(
        node.location(),
        "printed index requires ordered cardinality",
      )
    }
    let value = nonnegative_int(node, "index")
    if value == 0 {
      raise InvalidItem(node.location(), "printed index is one-based")
    }
    Some(value)
  } else {
    None
  }
  let radix = nonnegative_int(node, "base", default=10)
  if radix < 2 || radix > 36 || (radix != 10 && kind.base != "integer") {
    raise Unsupported(
      node.location(),
      "printed integer base must be a literal from 2 to 36",
    )
  }
  let mut precision : Int32? = None
  let mut integer_format = false
  if node.attr("format") is Some(format) {
    if format == "%i" || format == "%d" {
      if kind.base != "integer" {
        raise InvalidItem(
          node.location(),
          "integer print format requires integer base type",
        )
      }
      integer_format = true
    } else if format == "%f" {
      precision = Some(6)
    } else if format.has_prefix("%.") && format.has_suffix("f") {
      let digits = format[2:format.length() - 1].to_owned()
      if digits == "" || !digits.iter().all(c => '0' <= c && c <= '9') {
        raise Unsupported(node.location(), "unsupported printed numeric format")
      }
      let places = @string.parse_int(digits[:]) catch {
        _ =>
          raise Unsupported(node.location(), "printed precision out of range")
      }
      if places > 12 {
        raise Unsupported(node.location(), "printed fixed precision exceeds 12")
      }
      precision = Some(places)
    } else {
      raise Unsupported(
        node.location(),
        "unsupported printed format '\{format}'",
      )
    }
    if !kind.numeric() {
      raise InvalidItem(
        node.location(),
        "numeric print format requires numeric base type",
      )
    }
  }
  if radix != 10 && !integer_format {
    raise Unsupported(node.location(), "nondecimal base requires %i format")
  }
  let delimiter = node.attr("delimiter").unwrap_or(";")
  if delimiter.length() > 256 {
    raise LimitExceeded("printed delimiter exceeds 256 UTF-16 units")
  }
  {
    identifier: declaration.identifier,
    base: kind.base,
    precision,
    radix,
    integer_format,
    index,
    delimiter,
  }
}

///|
fn content_parts(
  node : Node,
  program : ProcessingProgram,
  inline~ : Bool = false,
) -> Array[ContentPart] raise QtiError {
  let result : Array[ContentPart] = []
  for part in node.parts {
    match part {
      Text(text) =>
        if node.name() != "qti-content-body" || text.trim() != "" {
          result.push(Text(text))
        }
      Element(child) => {
        let name = child.name()
        let uri = child.element.name.namespace_uri
        if node.name() == "qti-content-body" &&
          ["qti-printed-variable", "qti-feedback-inline"].contains(name) {
          raise InvalidItem(
            child.location(),
            "inline feedback content requires an inline context such as p or span",
          )
        }
        if name.has_prefix("qti-") && uri != Some(qti_namespace) {
          raise Unsupported(child.location(), "dynamic content namespace")
        }
        if name == "qti-printed-variable" {
          result.push(Printed(content_printed(child, program)))
        } else if name == "qti-feedback-inline" || name == "qti-feedback-block" {
          if inline && name == "qti-feedback-block" {
            raise InvalidItem(
              child.location(),
              "inline feedback cannot contain block feedback",
            )
          }
          child.only_attributes(
            [
              "outcome-identifier", "identifier", "show-hide", "class", "id", "dir",
            ],
            allow_base=true,
          )
          let declaration = content_outcome(
            child, program, "outcome-identifier",
          )
          if declaration.kind.base != "identifier" ||
            declaration.kind.cardinality == Ordered {
            raise InvalidItem(
              child.location(),
              "feedback requires a single/multiple identifier outcome",
            )
          }
          let id = identifier(child.required("identifier"), child.location())
          let contents = if name == "qti-feedback-block" {
            child.only_children(["qti-content-body"])
            match child.one("qti-content-body", required=false) {
              Some(body) => {
                body.only_attributes(["class", "id", "dir"], allow_base=true)
                content_parts(body, program)
              }
              None => []
            }
          } else {
            content_parts(child, program, inline=true)
          }
          result.push(
            Feedback(declaration.identifier, id, content_show(child), contents),
          )
        } else {
          if child.attr("response-identifier") is Some(_) ||
            name.has_suffix("-interaction") {
            raise InvalidItem(
              child.location(),
              "non-adaptive feedback cannot contain interactions",
            )
          }
          let allowed = [
              "span", "strong", "em", "b", "i", "u", "sub", "sup", "br",
            ].contains(name) ||
            (
              !inline &&
              ["p", "div", "blockquote", "ul", "ol", "li"].contains(name)
            )
          if !allowed ||
            ![Some(qti_namespace), Some("http://www.w3.org/1999/xhtml")].contains(
              uri,
            ) {
            raise Unsupported(
              child.location(),
              "dynamic text content '\{name}'",
            )
          }
          child.only_attributes(["class", "id", "dir"])
          if name == "br" {
            child.only_children([])
          }
          result.append(content_parts(child, program, inline~))
          if ["p", "div", "blockquote", "li", "br"].contains(name) {
            result.push(Text("\n"))
          }
        }
      }
    }
  }
  result
}

///|
fn content_matches(outcomes : Json, outcome : String, id : String) -> Bool {
  let value = match outcomes {
    Object(fields) => fields.get(outcome).unwrap_or(Json::null())
    _ => Json::null()
  }
  value == Json(id) || (value is Array(values) && values.contains(Json(id)))
}

///|
// Round the exact IEEE-754 value to decimal places, with nearest/even ties.
// Integer arithmetic avoids overflow and the double rounding of n * 10^p.
fn content_fixed(value : Double, places : Int32) -> String {
  let bits = value.reinterpret_as_uint64()
  let exp = ((bits >> 52) & 2047UL).to_int()
  let fraction = bits & 4503599627370495UL
  let significand = if exp == 0 {
    fraction
  } else {
    fraction + 4503599627370496UL
  }
  let binary_exp = (if exp == 0 { -1074 } else { exp - 1075 }) + places
  let mut integer = @bigint.BigInt::from_uint64(significand)
  for _ in 0..<places {
    integer = integer * @bigint.BigInt::from_int(5)
  }
  if binary_exp >= 0 {
    integer = integer << binary_exp
  } else {
    let quotient = integer >> -binary_exp
    let remainder = integer - (quotient << -binary_exp)
    let half = @bigint.BigInt::from_int(1) << (-binary_exp - 1)
    integer = if remainder > half ||
      (
        remainder == half &&
        quotient % @bigint.BigInt::from_int(2) != @bigint.BigInt::from_int(0)
      ) {
      quotient + @bigint.BigInt::from_int(1)
    } else {
      quotient
    }
  }
  let mut text = integer.to_string()
  while text.length() <= places {
    text = "0" + text
  }
  if places > 0 {
    text = text[:text.length() - places].to_owned() +
      "." +
      text[text.length() - places:].to_owned()
  }
  if bits >> 63 != 0UL {
    "-" + text
  } else {
    text
  }
}

///|
fn PrintedValue::scalar(self : PrintedValue, value : Json) -> String {
  match value {
    Null => ""
    String(text) => text
    True => "true"
    False => "false"
    Number(number, ..) =>
      if self.precision is Some(places) {
        content_fixed(number, places)
      } else if self.integer_format {
        @bigint.BigInt::from_int64(number.to_int64()).to_string(
          radix=self.radix,
        )
      } else {
        number.to_string()
      }
    _ => ""
  }
}

///|
fn PrintedValue::render(self : PrintedValue, outcomes : Json) -> String {
  let value = match outcomes {
    Object(fields) => fields.get(self.identifier).unwrap_or(Json::null())
    _ => Json::null()
  }
  match value {
    Array(values) =>
      if self.index is Some(index) {
        values.get(index - 1).map(v => self.scalar(v)).unwrap_or("")
      } else {
        // Limit before joining a container of potentially large strings.
        let text = StringBuilder()
        let mut length = 0
        for index, value in values {
          if index > 0 {
            text.write_string(self.delimiter)
            length += self.delimiter.length()
          }
          let scalar = self.scalar(value)
          text.write_string(scalar)
          length += scalar.length()
          if length > 65536 {
            break
          }
        }
        text.to_string()
      }
    _ => self.scalar(value)
  }
}

///|
fn content_render(
  parts : Array[ContentPart],
  outcomes : Json,
  allow_feedback~ : Bool = true,
) -> String {
  let text = StringBuilder()
  let mut length = 0
  for part in parts {
    let value = match part {
      Text(text) => text
      Printed(spec) => spec.render(outcomes)
      Feedback(outcome, id, show, children) =>
        if allow_feedback && content_matches(outcomes, outcome, id) == show {
          content_render(children, outcomes, allow_feedback~)
        } else {
          ""
        }
    }
    if length + value.length() > 65536 {
      let clipped = StringBuilder()
      let mut units_used = 0
      for c in (text.to_string() + value).iter() {
        let units = if c.to_int() > 65535 { 2 } else { 1 }
        if units_used + units > 65520 {
          break
        }
        clipped.write_char(c)
        units_used += units
      }
      clipped.write_string("…[content limit]")
      return clipped.to_string()
    }
    text.write_string(value)
    length += value.length()
  }
  text.to_string()
}

///|
fn content_clip(text : String) -> String {
  if text.length() <= 65536 {
    return text
  }
  let clipped = StringBuilder()
  let mut used = 0
  for c in text.iter() {
    let units = if c.to_int() > 65535 { 2 } else { 1 }
    if used + units > 65520 {
      break
    }
    clipped.write_char(c)
    used += units
  }
  clipped.write_string("…[content limit]")
  clipped.to_string()
}

///|
// Replace dynamic nodes with private tokens before compiling interaction text.
// All original tokens are rejected so authored text cannot address a fragment.
fn content_body(
  node : Node,
  program : ProcessingProgram,
  fragments : Array[Array[ContentPart]],
) -> Node raise QtiError {
  let parts : Array[NodePart] = []
  let children : Array[Node] = []
  let content = StringBuilder()
  let all_text = StringBuilder()
  for part in node.parts {
    match part {
      Text(text) => {
        parts.push(Text(text))
        content.write_string(text)
        all_text.write_string(text)
      }
      Element(child) =>
        if ["qti-printed-variable", "qti-feedback-inline", "qti-feedback-block"].contains(
            child.name(),
          ) {
          if fragments.length() >= 256 {
            raise LimitExceeded("item exceeds 256 dynamic fragments")
          }
          let wrapper = { ..node, parts: [Element(child)], }
          let compiled = content_parts(wrapper, program)
          let marker = "\{content_marker}\{fragments.length()}\u{e001}"
          fragments.push(compiled)
          parts.push(Text(marker))
          content.write_string(marker)
          all_text.write_string(marker)
        } else {
          let rendered = content_body(child, program, fragments)
          children.push(rendered)
          parts.push(Element(rendered))
          all_text.write_string(rendered.all_text.to_string())
        }
    }
  }
  { ..node, parts, children, content, all_text, }
}

///|
fn DynamicPresentation::text(
  self : DynamicPresentation,
  template : String,
  outcomes : Json,
  allow_feedback : Bool,
) -> String {
  let result = StringBuilder()
  let pieces = template.split(content_marker).to_array()
  result.write_stringview(pieces[0])
  let mut length = pieces[0].length()
  if length > 65536 {
    return content_clip(result.to_string())
  }
  for i in 1..<pieces.length() {
    let piece = pieces[i]
    let end = piece.find("\u{e001}").unwrap_or(-1)
    if end < 0 {
      result.write_string(content_marker)
      result.write_stringview(piece)
      continue
    }
    let index = @string.parse_int(piece[:end]) catch { _ => -1 }
    let rendered = self.fragments
      .get(index)
      .map(fragment => content_render(fragment, outcomes, allow_feedback~))
      .unwrap_or("")
    let suffix = piece[end + 1:]
    if length + rendered.length() + suffix.length() > 65536 {
      return content_clip(result.to_string() + rendered + suffix.to_owned())
    }
    result.write_string(rendered)
    result.write_stringview(suffix)
    length += rendered.length() + suffix.length()
  }
  result.to_string()
}

///|
fn DynamicPresentation::describe(
  self : DynamicPresentation,
  value : Json,
  outcomes : Json,
  allow_feedback~ : Bool = true,
) -> Json {
  match value {
    String(text) => Json(self.text(text, outcomes, allow_feedback))
    Array(values) =>
      Json(values.map(v => self.describe(v, outcomes, allow_feedback~)))
    Object(fields) => {
      let result : Map[String, Json] = Map([])
      for id, value in fields {
        result[id] = self.describe(value, outcomes, allow_feedback~)
      }
      Json::object(result)
    }
    _ => value
  }
}
