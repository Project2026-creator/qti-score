///|
priv struct ProcessingLookupEntry {
  threshold : Double
  include_boundary : Bool
  target : Json
} derive(Debug)

///|
priv struct ProcessingLookup {
  entries : Array[ProcessingLookupEntry]
  default_value : Json
} derive(Debug)

///|
fn processing_lookup_target(
  raw : String,
  base : String,
  node : Node,
) -> Json raise QtiError {
  if raw.length() > 65536 {
    raise LimitExceeded("lookup target exceeds 65536 UTF-16 units")
  }
  match base {
    "boolean" =>
      match raw.trim().to_owned() {
        "true" | "1" => Json(true)
        "false" | "0" => Json(false)
        _ => raise InvalidItem(node.location(), "invalid boolean lookup target")
      }
    "integer" => Json(authored_number(raw, Integer, node))
    "float" => Json(authored_number(raw, Float, node))
    "identifier" => Json(identifier(raw.trim().to_owned(), node.location()))
    "directedPair" => Json(authored_pair(raw, node))
    "string" => if raw == "" { Json::null() } else { Json(raw) }
    _ => raise Unsupported(node.location(), "lookup target base-type '\{base}'")
  }
}

///|
fn processing_lookup_declaration(
  node : Node,
  kind : ProcessingType,
) -> ProcessingLookup? raise QtiError {
  let tables = node.children.filter(child => {
    ["qti-interpolation-table", "qti-match-table"].contains(child.name())
  })
  if tables.length() > 1 {
    raise InvalidItem(
      node.location(),
      "an outcome can declare only one lookup table",
    )
  }
  guard tables.get(0) is Some(table) else { return None }
  if node.name() != "qti-outcome-declaration" {
    raise InvalidItem(
      node.location(),
      "lookup tables require an outcome declaration",
    )
  }
  if table.name() == "qti-match-table" {
    raise Unsupported(table.location(), "match-table lookup")
  }
  if kind.cardinality != Single {
    raise InvalidItem(
      node.location(),
      "lookup tables require single outcome cardinality",
    )
  }
  let mut seen_table = false
  for child in node.children {
    if child.name() == "qti-interpolation-table" {
      seen_table = true
    }
    if seen_table && child.name() == "qti-default-value" {
      raise InvalidItem(
        child.location(),
        "outcome default-value must precede the lookup table",
      )
    }
  }
  if table.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(table.location(), "lookup table in a different namespace")
  }
  table.only_attributes(["default-value"])
  table.only_children(["qti-interpolation-table-entry"])
  if table.content.to_string().trim() != "" {
    raise InvalidItem(table.location(), "unexpected lookup table text")
  }
  if table.children.is_empty() {
    raise InvalidItem(
      table.location(),
      "interpolation-table requires at least one entry",
    )
  }
  if table.children.length() > 1024 {
    raise LimitExceeded("interpolation-table exceeds 1024 entries")
  }
  let default_value = table
    .attr("default-value")
    .map(raw => processing_lookup_target(raw, kind.base, table))
    .unwrap_or(Json::null())
  let entries = table.children.map(entry => {
    if entry.element.name.namespace_uri != Some(qti_namespace) {
      raise Unsupported(
        entry.location(),
        "lookup table entry in a different namespace",
      )
    }
    entry.only_attributes(["source-value", "target-value", "include-boundary"])
    entry.only_children([])
    if entry.content.to_string().trim() != "" {
      raise InvalidItem(entry.location(), "unexpected lookup entry text")
    }
    {
      threshold: authored_number(entry.required("source-value"), Float, entry),
      include_boundary: xml_bool(entry, "include-boundary", default=true),
      target: processing_lookup_target(
        entry.required("target-value"),
        kind.base,
        entry,
      ),
    }
  })
  Some({ entries, default_value, })
}

///|
fn processing_lookup_rule(
  node : Node,
  declarations : Array[ProcessingDeclaration],
  test_mode~ : Bool = false,
  item_schemas~ : Array[ProcessingItemSchema]? = None,
) -> ProcessingRule raise QtiError {
  node.only_attributes(["identifier"])
  processing_arity(node, 1, 1)
  let declaration = processing_known(node, declarations)
  if declaration.response {
    raise InvalidItem(
      node.location(),
      "lookup-outcome-value cannot assign a response variable",
    )
  }
  if declaration.lookup_table is None {
    raise InvalidItem(
      node.location(),
      "lookup-outcome-value requires an outcome lookup table",
    )
  }
  let expression = processing_expression(
    node.children[0],
    declarations,
    test_mode~,
    item_schemas~,
  )
  if expression.kind is Some(kind) &&
    (kind.cardinality != Single || !kind.numeric()) {
    raise InvalidItem(
      node.location(),
      "lookup-outcome-value requires a single integer or float source",
    )
  }
  Lookup(declaration.identifier, expression, node.source())
}

///|
// QTI interpolation tables select threshold rows in authored order. They do
// not calculate a line between neighboring points. NULL has no matching row
// and uses the table's fallback, independently of the outcome's initial value.
fn ProcessingLookup::lookup(
  self : ProcessingLookup,
  input : Json,
  context : ProcessingContext,
  identifier : String,
  source : SourceLocation,
) -> Json raise QtiError {
  let mut index : Int32? = None
  let mut result = self.default_value
  if input != Json::null() {
    let number = processing_number(input)
    for i, entry in self.entries {
      context.consume()
      if number > entry.threshold ||
        (entry.include_boundary && number == entry.threshold) {
        index = Some(i)
        result = entry.target
        break
      }
    }
  }
  record_step(context.steps, "lookup_outcome_value", source, {
    "identifier": identifier,
    "source_value": input,
    "entry_index": match index {
      Some(i) => Json(i)
      None => Json::null()
    },
    "value": result,
  })
  processing_copy(result)
}
