///|
fn processing_identifier_list(
  value : String,
  node : Node,
) -> Array[String] raise QtiError {
  let raw = value
    .replace_all(old="\t", new=" ")
    .replace_all(old="\n", new=" ")
    .replace_all(old="\r", new=" ")
    .split(" ")
    .filter(s => s != "")
    .map(s => s.to_owned())
    .collect()
  let tokens = raw.map(s => identifier(s, node.location()))
  if tokens.is_empty() {
    raise InvalidItem(node.location(), "identifier list cannot be empty")
  }
  if tokens.length() > 128 {
    raise LimitExceeded("processing selector exceeds 128 identifiers")
  }
  tokens
}

///|
fn processing_metadata_identifiers(
  value : Json?,
  label : String,
) -> Array[String] raise QtiError {
  guard value is Some(value) else { return [] }
  guard value is Array(values) else {
    raise InvalidResponse("\{label} must be an identifier array")
  }
  if values.length() > 128 {
    raise LimitExceeded("\{label} exceeds 128 identifiers")
  }
  values.map(v => {
    guard v is String(id) else {
      raise InvalidResponse("\{label} contains a non-string identifier")
    }
    identifier(id, label) catch {
      _ => raise InvalidResponse("\{label} contains an invalid identifier")
    }
  })
}

///|
fn processing_item_schemas(
  input : Json,
) -> Array[ProcessingItemSchema]? raise QtiError {
  if input == Json::null() {
    return None
  }
  guard input is Array(items) else {
    raise InvalidItem("item declarations", "expected an array")
  }
  if items.length() > 4096 {
    raise LimitExceeded("processing metadata exceeds 4096 item references")
  }
  let schemas : Array[ProcessingItemSchema] = []
  for item in items {
    guard item is Object(fields) && fields.get("identifier") is Some(String(id)) else {
      raise InvalidItem(
        "item declarations", "item metadata requires an identifier",
      )
    }
    ignore(identifier(id, "item declarations"))
    let variables : Array[ProcessingItemVariable] = []
    for role in ["response_types", "outcome_types"] {
      guard fields.get(role) is Some(metadata) else { continue }
      guard metadata is Object(types) else {
        raise InvalidItem("item declarations", "variable types must be objects")
      }
      for name, declaration in types {
        ignore(identifier(name, "item declarations"))
        guard declaration
          is {
            "base_type": String(base),
            "cardinality": String(cardinality),
            ..
          } else {
          raise InvalidItem(
            "item declarations", "variable metadata requires base_type and cardinality",
          )
        }
        if ![
            "boolean", "identifier", "string", "integer", "float", "directedPair",
          ].contains(base) {
          raise Unsupported(
            "item declarations",
            "item variable base-type '\{base}'",
          )
        }
        let card : Cardinality = match cardinality {
          "single" => Single
          "multiple" => Multiple
          "ordered" => Ordered
          _ =>
            raise Unsupported(
              "item declarations",
              "item variable cardinality '\{cardinality}'",
            )
        }
        if variables.any(v => v.identifier == name) {
          raise InvalidItem(
            "item declarations",
            "duplicate item variable '\{name}'",
          )
        }
        if variables.length() >= 128 {
          raise LimitExceeded("processing item metadata exceeds 128 variables")
        }
        variables.push({
          identifier: name,
          kind: processing_type(base, card),
          response: role == "response_types",
        })
      }
    }
    let categories = processing_metadata_identifiers(
      fields.get("categories"),
      "item categories",
    ) catch {
      e => raise InvalidItem("item declarations", e.message())
    }
    let sections = processing_metadata_identifiers(
      fields.get("section_identifiers"),
      "item sections",
    ) catch {
      e => raise InvalidItem("item declarations", e.message())
    }
    if schemas.filter(s => s.identifier == id).get(0) is Some(previous) {
      if previous.variables.length() != variables.length() ||
        previous.variables.any(v => !variables.contains(v)) ||
        previous.categories != categories ||
        previous.section_identifiers != sections {
        raise InvalidItem(
          "item declarations",
          "inconsistent duplicate item metadata '\{id}'",
        )
      }
    } else {
      schemas.push({
        identifier: id,
        variables,
        categories,
        section_identifiers: sections,
      })
    }
  }
  Some(schemas)
}

///|
fn ProcessingTestVariables::includes(
  self : ProcessingTestVariables,
  categories : Array[String],
  sections : Array[String],
) -> Bool {
  self.section_identifier.map(id => sections.contains(id)).unwrap_or(true) &&
  (
    self.include_categories.is_empty() ||
    self.include_categories.any(c => categories.contains(c))
  ) &&
  !self.exclude_categories.any(c => categories.contains(c))
}

///|
fn processing_reference_candidates(
  id : String,
  schemas : Array[ProcessingItemSchema],
  weight_identifier : String?,
) -> Array[ProcessingItemReference] {
  let matches : Array[ProcessingItemReference] = []
  for schema in schemas {
    let prefix = schema.identifier + "."
    if !id.has_prefix(prefix) {
      continue
    }
    let variable_id = id[prefix.length():].to_owned()
    if schema.variables.filter(v => v.identifier == variable_id).get(0)
      is Some(variable) {
      matches.push({
        identifier: schema.identifier,
        instance_index: None,
        variable,
        weight_identifier,
      })
    }
    let parts = variable_id.split(".").map(s => s.to_owned()).collect()
    if parts.length() < 2 {
      continue
    }
    let number = numeric_value(parts[0], Integer) catch { _ => continue }
    if number <= 0.0 || number > 4096.0 {
      continue
    }
    let index = number.to_int()
    if index.to_string() != parts[0] {
      continue
    }
    let indexed_variable = variable_id[parts[0].length() + 1:].to_owned()
    if schema.variables.filter(v => v.identifier == indexed_variable).get(0)
      is Some(variable) {
      matches.push({
        identifier: schema.identifier,
        instance_index: Some(index),
        variable,
        weight_identifier,
      })
    }
  }
  matches
}

///|
fn processing_item_reference(
  node : Node,
  schemas : Array[ProcessingItemSchema]?,
) -> ProcessingExpression raise QtiError {
  let id = identifier(node.required("identifier"), node.location())
  guard schemas is Some(schemas) else {
    raise Unsupported(
      node.location(),
      "prefixed item variables require item declaration metadata",
    )
  }
  let weight_identifier = node
    .attr("weight-identifier")
    .map(w => identifier(w, node.location()))
  let matches = processing_reference_candidates(id, schemas, weight_identifier)
  if matches.length() > 1 {
    raise InvalidItem(
      node.location(),
      "ambiguous prefixed item variable '\{id}'",
    )
  }
  guard matches.get(0) is Some(reference) else {
    raise InvalidItem(
      node.location(),
      "unknown item variable or invalid instance prefix '\{id}'",
    )
  }
  let kind = if weight_identifier is Some(_) &&
    reference.variable.kind.numeric() {
    processing_type("float", reference.variable.kind.cardinality)
  } else {
    reference.variable.kind
  }
  {
    expression: ItemReference(reference),
    kind: Some(kind),
    source: node.source(),
  }
}

///|
fn processing_test_variables(
  node : Node,
  schemas : Array[ProcessingItemSchema]?,
) -> ProcessingExpression raise QtiError {
  node.only_attributes([
    "variable-identifier", "base-type", "section-identifier", "include-category",
    "exclude-category", "weight-identifier",
  ])
  node.only_children([])
  let variable_identifier = identifier(
    node.required("variable-identifier"),
    node.location(),
  )
  let base_filter = node.attr("base-type").map(_ => processing_base(node))
  let weight_identifier = node
    .attr("weight-identifier")
    .map(w => identifier(w, node.location()))
  if weight_identifier is Some(_) &&
    base_filter is Some(base) &&
    base != "float" {
    raise InvalidItem(
      node.location(),
      "weighted test-variables requires float or omitted base-type",
    )
  }
  let selector : ProcessingTestVariables = {
    variable_identifier,
    base_filter,
    section_identifier: node
    .attr("section-identifier")
    .map(s => identifier(s, node.location())),
    include_categories: node
    .attr("include-category")
    .map(s => processing_identifier_list(s, node))
    .unwrap_or([]),
    exclude_categories: node
    .attr("exclude-category")
    .map(s => processing_identifier_list(s, node))
    .unwrap_or([]),
    weight_identifier,
    schemas,
  }
  let base = if weight_identifier is Some(_) {
    "float"
  } else if base_filter is Some(base) {
    base
  } else {
    guard schemas is Some(schemas) else {
      raise Unsupported(
        node.location(),
        "test-variables without base-type requires item declaration metadata",
      )
    }
    let floating = schemas.any(s => {
      selector.includes(s.categories, s.section_identifiers) &&
      s.variables.any(v => {
        v.identifier == variable_identifier &&
        v.kind.cardinality == Single &&
        v.kind.base == "float"
      })
    })
    if floating {
      "float"
    } else {
      "integer"
    }
  }
  {
    expression: TestVariables(selector),
    kind: Some(processing_type(base, Multiple)),
    source: node.source(),
  }
}
