///|
let qti_namespace = "http://www.imsglobal.org/xsd/imsqtiasi_v3p0"

///|
priv enum NodePart {
  Text(String)
  Element(Node)
}

///|
priv struct Node {
  element : @xml.NamespaceElement
  line : Int32
  column : Int32
  children : Array[Node]
  parts : Array[NodePart]
  content : StringBuilder
  all_text : StringBuilder
}

///|
fn node(element : @xml.NamespaceElement, span : @xml.SourceSpan) -> Node {
  {
    element,
    line: span.start.line,
    column: span.start.column,
    children: [],
    parts: [],
    content: StringBuilder(),
    all_text: StringBuilder(),
  }
}

///|
fn Node::name(self : Node) -> String {
  self.element.name.local_name
}

///|
fn Node::attr(self : Node, name : String) -> String? {
  for attr in self.element.attributes {
    if attr.name.namespace_uri is None && attr.name.local_name == name {
      return Some(attr.value)
    }
  }
  None
}

///|
fn Node::location(self : Node) -> String {
  "\{self.name()} at \{self.line}:\{self.column}"
}

///|
fn Node::required(self : Node, name : String) -> String raise QtiError {
  match self.attr(name) {
    Some(value) if value != "" => value
    _ => raise InvalidItem(self.location(), "missing attribute '\{name}'")
  }
}

///|
fn Node::only_attributes(
  self : Node,
  allowed : Array[String],
  allow_base~ : Bool = false,
) -> Unit raise QtiError {
  for attr in self.element.attributes {
    match attr.name.namespace_uri {
      None =>
        if !allowed.contains(attr.name.local_name) {
          raise Unsupported(
            self.location(),
            "attribute '\{attr.name.local_name}'",
          )
        }
      Some("http://www.w3.org/XML/1998/namespace") =>
        if !["lang", "space"].contains(attr.name.local_name) &&
          !(allow_base && attr.name.local_name == "base") {
          raise Unsupported(
            self.location(),
            "XML attribute '\{attr.name.local_name}'",
          )
        }
      Some("http://www.w3.org/2001/XMLSchema-instance") =>
        if attr.name.local_name != "schemaLocation" {
          raise Unsupported(
            self.location(),
            "XSI attribute '\{attr.name.local_name}'",
          )
        }
      Some(uri) =>
        raise Unsupported(self.location(), "attribute namespace '\{uri}'")
    }
  }
}

///|
fn Node::only_children(
  self : Node,
  allowed : Array[String],
  ns_uri~ : String = qti_namespace,
) -> Unit raise QtiError {
  if self.content.to_string().trim() != "" {
    raise InvalidItem(self.location(), "unexpected text content")
  }
  for child in self.children {
    if child.element.name.namespace_uri != Some(ns_uri) ||
      !allowed.contains(child.name()) {
      raise Unsupported(
        child.location(),
        "element '\{child.element.name.qualified_name}'",
      )
    }
  }
}

///|
fn Node::one(
  self : Node,
  name : String,
  required~ : Bool = true,
  ns_uri~ : String = qti_namespace,
) -> Node? raise QtiError {
  let matches = self.children.filter(n => {
    n.name() == name && n.element.name.namespace_uri == Some(ns_uri)
  })
  if matches.length() > 1 {
    raise InvalidItem(self.location(), "duplicate '\{name}'")
  }
  if required && matches.is_empty() {
    raise InvalidItem(self.location(), "missing '\{name}'")
  }
  matches.get(0)
}

///|
fn parse_document(input : String, limits : Limits) -> Node raise QtiError {
  if limits.max_characters <= 0 ||
    limits.max_depth <= 0 ||
    limits.max_elements <= 0 {
    raise InvalidItem("limits", "limits must be positive")
  }
  if limits.max_depth > 256 {
    raise InvalidItem("limits", "max_depth cannot exceed 256")
  }
  if input.length() > limits.max_characters {
    raise LimitExceeded("XML exceeds max_characters=\{limits.max_characters}")
  }
  let reader = @xml.NamespaceReader::from_string(input)
  let stack : Array[Node] = []
  let mut root : Node? = None
  let mut count = 0
  while true {
    let event = reader.read_event() catch {
      @xml.XmlError::At(error~, span~) =>
        raise InvalidXml(error.to_string(), span.start.line, span.start.column)
    }
    match event.kind {
      Start(element) | Empty(element) => {
        count += 1
        if count > limits.max_elements {
          raise LimitExceeded("XML exceeds max_elements=\{limits.max_elements}")
        }
        if stack.length() + 1 > limits.max_depth {
          raise LimitExceeded("XML exceeds max_depth=\{limits.max_depth}")
        }
        let current = node(element, event.span)
        if stack.last() is Some(parent) {
          parent.children.push(current)
          parent.parts.push(Element(current))
        } else {
          root = Some(current)
        }
        if event.kind is Start(_) {
          stack.push(current)
        }
      }
      End(_) => ignore(stack.pop())
      Text(text) | CData(text) => {
        // Keep each element's direct text, and a separate flattened body is
        // constructed later in document order.
        if stack.last() is Some(parent) {
          parent.content.write_string(text)
          parent.parts.push(Text(text))
        }
        for parent in stack {
          parent.all_text.write_string(text)
        }
      }
      DocType(_) => raise Unsupported("XML", "DOCTYPE declarations")
      PI(..) => raise Unsupported("XML", "processing instructions")
      Decl(..) | Comment(_) => ()
      Eof => break
    }
  }
  match root {
    Some(value) => value
    None => raise InvalidItem("XML", "no root element")
  }
}

///|
fn xml_bool(
  node : Node,
  attribute : String,
  default~ : Bool,
) -> Bool raise QtiError {
  match node.attr(attribute) {
    None => default
    Some("true" | "1") => true
    Some("false" | "0") => false
    Some(_) =>
      raise InvalidItem(node.location(), "invalid boolean '\{attribute}'")
  }
}

///|
fn number(node : Node, attribute : String) -> Double raise QtiError {
  let text = node.required(attribute)
  // MoonBit's parser also accepts underscores and non-finite values; QTI
  // scoring numbers here must be ordinary finite XML numeric literals.
  if text.contains("_") {
    raise InvalidItem(node.location(), "invalid number '\{attribute}'")
  }
  let value = @string.parse_double(text.trim()) catch {
    _ => raise InvalidItem(node.location(), "invalid number '\{attribute}'")
  }
  if value.is_nan() || value.is_inf() {
    raise InvalidItem(node.location(), "non-finite number '\{attribute}'")
  }
  value
}

///|
fn optional_number(node : Node, attribute : String) -> Double? raise QtiError {
  match node.attr(attribute) {
    None => None
    Some(_) => Some(number(node, attribute))
  }
}

///|
fn identifier(value : String, location : String) -> String raise QtiError {
  // This profile uses ASCII QTI identifiers. Text responses remain Unicode.
  let mut i = 0
  for c in value.iter() {
    let valid = ('a' <= c && c <= 'z') ||
      ('A' <= c && c <= 'Z') ||
      c == '_' ||
      (i > 0 && (('0' <= c && c <= '9') || c == '-' || c == '.'))
    if !valid {
      raise InvalidItem(
        location,
        "unsupported identifier '\{value}' (use ASCII NCNames)",
      )
    }
    i += 1
  }
  if value == "" {
    raise InvalidItem(location, "empty identifier")
  }
  value
}
