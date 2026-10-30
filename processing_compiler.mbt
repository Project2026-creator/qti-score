///|
fn processing_base(node : Node) -> String raise QtiError {
  let base = node.required("base-type")
  if ![
      "boolean", "identifier", "string", "integer", "float", "directedPair", "pair",
    ].contains(base) {
    raise Unsupported(node.location(), "processing base-type '\{base}'")
  }
  base
}

///|
fn processing_cardinality(node : Node) -> Cardinality raise QtiError {
  match node.required("cardinality") {
    "single" => Single
    "multiple" => Multiple
    "ordered" => Ordered
    other =>
      raise Unsupported(node.location(), "processing cardinality '\{other}'")
  }
}

///|
fn processing_literal(node : Node, base : String) -> Json raise QtiError {
  if !node.children.is_empty() {
    raise InvalidItem(node.location(), "literal must contain text only")
  }
  let text = node.content.to_string()
  match base {
    "boolean" =>
      match text.trim().to_owned() {
        "true" | "1" => Json(true)
        "false" | "0" => Json(false)
        _ => raise InvalidItem(node.location(), "invalid boolean literal")
      }
    "integer" => Json(authored_number(text, Integer, node))
    "float" => Json(authored_number(text, Float, node))
    "identifier" => Json(identifier(text.trim().to_owned(), node.location()))
    "directedPair" => Json(authored_pair(text, node))
    "pair" => Json(authored_undirected_pair(text, node))
    _ => if text == "" { Json::null() } else { Json(text) }
  }
}

///|
fn processing_decl_value(
  node : Node?,
  kind : ProcessingType,
) -> Json raise QtiError {
  guard node is Some(node) else { return Json::null() }
  node.only_attributes([])
  node.only_children(["qti-value"])
  if kind.cardinality == Single && node.children.length() != 1 {
    raise InvalidItem(
      node.location(),
      "single default/correct requires one value",
    )
  }
  let values = node.children.map(n => {
    n.only_attributes([])
    processing_literal(n, kind.base)
  })
  if kind.cardinality == Single {
    values[0]
  } else if values.is_empty() {
    Json::null()
  } else {
    if values.any(v => v == Json::null()) {
      raise InvalidItem(node.location(), "container values cannot contain NULL")
    }
    Json(values)
  }
}

///|
fn processing_declarations(
  root : Node,
) -> Array[ProcessingDeclaration] raise QtiError {
  let result : Array[ProcessingDeclaration] = []
  let mut lookup_entries = 0
  for node in root.children {
    let response = node.name() == "qti-response-declaration"
    if !response && node.name() != "qti-outcome-declaration" {
      continue
    }
    node.only_attributes([
      "identifier", "cardinality", "base-type", "normal-minimum", "normal-maximum",
      "interpretation", "long-interpretation", "view", "mastery-value", "external-scored",
    ])
    if response &&
      node.children.any(child => {
        ["qti-interpolation-table", "qti-match-table"].contains(child.name())
      }) {
      raise InvalidItem(
        node.location(),
        "lookup tables require an outcome declaration",
      )
    }
    node.only_children(
      if response {
        ["qti-correct-response", "qti-default-value", "qti-mapping"]
      } else {
        ["qti-default-value", "qti-interpolation-table", "qti-match-table"]
      },
    )
    let id = identifier(node.required("identifier"), node.location())
    if ["completionStatus", "numAttempts", "duration"].contains(id) ||
      result.any(d => d.identifier == id) {
      raise InvalidItem(
        node.location(),
        "duplicate or built-in variable '\{id}'",
      )
    }
    if result.length() >= 128 {
      raise LimitExceeded("processing supports at most 128 declarations")
    }
    let kind = processing_type(
      processing_base(node),
      processing_cardinality(node),
    )
    let lookup_table = processing_lookup_declaration(node, kind)
    if lookup_table is Some(table) {
      lookup_entries += table.entries.length()
      if lookup_entries > 8192 {
        raise LimitExceeded("processing lookup tables exceed 8192 entries")
      }
    }
    ignore(optional_number(node, "normal-minimum"))
    ignore(optional_number(node, "normal-maximum"))
    let default_node = node.one("qti-default-value", required=false)
    let default_value = processing_decl_value(default_node, kind)
    let correct = processing_decl_value(
      node.one("qti-correct-response", required=false),
      kind,
    )
    let mapping = node
      .one("qti-mapping", required=false)
      .map(n => {
        if kind.base == "boolean" {
          raise Unsupported(n.location(), "boolean response mapping")
        }
        let base = match kind.base {
          "identifier" => Identifier
          "integer" => Integer
          "float" => Float
          "directedPair" => DirectedPair
          "pair" => Pair
          _ => Text
        }
        parse_mapping(n, base)
      })
    let external_scored = node.attr("external-scored")
    if external_scored is Some(mode) &&
      (response || !["human", "externalMachine"].contains(mode)) {
      raise InvalidItem(
        node.location(),
        "external-scored is an outcome attribute with human/externalMachine values",
      )
    }
    result.push({
      identifier: id,
      kind,
      response,
      default_value,
      correct,
      mapping,
      lookup_table,
      external_scored,
      source: node.source(),
    })
  }
  result
}

///|
fn processing_known(
  node : Node,
  declarations : Array[ProcessingDeclaration],
) -> ProcessingDeclaration raise QtiError {
  let id = node.required("identifier")
  match declarations.filter(d => d.identifier == id).get(0) {
    Some(d) => d
    None =>
      raise InvalidItem(
        node.location(),
        "undeclared processing variable '\{id}'",
      )
  }
}

///|
fn processing_arity(
  node : Node,
  minimum : Int32,
  maximum : Int32,
) -> Unit raise QtiError {
  if node.children.length() < minimum ||
    (maximum >= 0 && node.children.length() > maximum) {
    raise InvalidItem(node.location(), "invalid expression operand count")
  }
  if node.content.to_string().trim() != "" {
    raise InvalidItem(node.location(), "unexpected expression text")
  }
}

///|
fn processing_expect(
  node : Node,
  expression : ProcessingExpression,
  kind : ProcessingType,
) -> Unit raise QtiError {
  if expression.kind is Some(actual) && actual != kind {
    raise InvalidItem(
      node.location(),
      "processing type mismatch: expected \{kind.base} with declared cardinality",
    )
  }
}

///|
fn processing_expression(
  node : Node,
  declarations : Array[ProcessingDeclaration],
  test_mode~ : Bool = false,
  item_schemas~ : Array[ProcessingItemSchema]? = None,
) -> ProcessingExpression raise QtiError {
  if node.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(node.location(), "expression in a different namespace")
  }
  let name = node.name()
  let source = node.source()
  let boolean = processing_type("boolean", Single)
  if name == "qti-base-value" {
    node.only_attributes(["base-type"])
    let base = processing_base(node)
    return {
      expression: Literal(processing_literal(node, base)),
      kind: Some(processing_type(base, Single)),
      source,
    }
  }
  if name == "qti-null" {
    node.only_attributes([])
    node.only_children([])
    return { expression: Literal(Json::null()), kind: None, source, }
  }
  if ["qti-variable", "qti-correct", "qti-default", "qti-map-response"].contains(
      name,
    ) {
    node.only_attributes(
      if name == "qti-variable" {
        ["identifier", "weight-identifier"]
      } else {
        ["identifier"]
      },
    )
    node.only_children([])
    if name == "qti-variable" {
      let id = node.required("identifier")
      if test_mode && id.contains(".") {
        if declarations.any(d => d.identifier == id) {
          if item_schemas is Some(schemas) &&
            !processing_reference_candidates(id, schemas, None).is_empty() {
            raise InvalidItem(
              node.location(),
              "ambiguous local and prefixed item variable '\{id}'",
            )
          }
        } else {
          return processing_item_reference(node, item_schemas)
        }
      }
      if node.attr("weight-identifier") is Some(_) {
        raise InvalidItem(
          node.location(),
          "weight-identifier requires a prefixed item variable in test outcome processing",
        )
      }
    }
    let d = processing_known(node, declarations)
    if name == "qti-correct" && !d.response {
      raise InvalidItem(node.location(), "correct requires a response variable")
    }
    if name == "qti-map-response" && (!d.response || d.mapping is None) {
      raise InvalidItem(
        node.location(),
        "map-response requires a mapped response variable",
      )
    }
    return {
      expression: Reference(name, d.identifier),
      kind: Some(
        if name == "qti-map-response" {
          processing_type("float", Single)
        } else {
          d.kind
        },
      ),
      source,
    }
  }
  if name == "qti-test-variables" {
    if !test_mode {
      raise Unsupported(
        node.location(),
        "test-variables outside outcome processing",
      )
    }
    return processing_test_variables(node, item_schemas)
  }
  let supported = [
    "qti-is-null", "qti-not", "qti-and", "qti-or", "qti-match", "qti-equal", "qti-lt",
    "qti-lte", "qti-gt", "qti-gte", "qti-sum", "qti-product", "qti-subtract", "qti-divide",
    "qti-integer-divide", "qti-integer-modulus", "qti-multiple", "qti-ordered", "qti-member",
    "qti-container-size", "qti-integer-to-float", "qti-index", "qti-min", "qti-max",
    "qti-string-match",
  ]
  if !supported.contains(name) {
    raise Unsupported(node.location(), "processing expression '\{name}'")
  }
  let mut tolerance : NumericTolerance? = None
  if name == "qti-equal" {
    node.only_attributes([
      "tolerance-mode", "tolerance", "include-lower-bound", "include-upper-bound",
    ])
    tolerance = Some(processing_tolerance(node))
  } else if name == "qti-string-match" {
    node.only_attributes(["case-sensitive", "substring"])
    // Regex/locale semantics are not approximated by the typed evaluator.
    if !xml_bool(node, "case-sensitive", default=true) ||
      xml_bool(node, "substring", default=false) {
      raise Unsupported(
        node.location(),
        "case-folded or substring string-match",
      )
    }
  } else if name == "qti-index" {
    node.only_attributes(["n"])
    ignore(nonnegative_int(node, "n"))
  } else {
    node.only_attributes([])
  }
  let unary = [
    "qti-is-null", "qti-not", "qti-container-size", "qti-integer-to-float", "qti-index",
  ].contains(name)
  let binary = [
    "qti-match", "qti-equal", "qti-lt", "qti-lte", "qti-gt", "qti-gte", "qti-subtract",
    "qti-divide", "qti-integer-divide", "qti-integer-modulus", "qti-member", "qti-string-match",
  ].contains(name)
  let empty_container = name == "qti-multiple" || name == "qti-ordered"
  processing_arity(
    node,
    if unary {
      1
    } else if binary {
      2
    } else if empty_container {
      0
    } else {
      1
    },
    if unary {
      1
    } else if binary {
      2
    } else {
      -1
    },
  )
  let args = node.children.map(n => {
    processing_expression(n, declarations, test_mode~, item_schemas~)
  })
  let kind : ProcessingType? = if [
      "qti-is-null", "qti-not", "qti-and", "qti-or",
    ].contains(name) {
    if name != "qti-is-null" {
      for arg in args {
        processing_expect(node, arg, boolean)
      }
    }
    Some(boolean)
  } else if name == "qti-match" {
    if args[0].kind is Some(a) && args[1].kind is Some(b) && a != b {
      raise InvalidItem(
        node.location(),
        "match operands require the same base-type/cardinality",
      )
    }
    if args.any(a => a.kind is Some(k) && k.base == "float") {
      raise InvalidItem(
        node.location(),
        "match does not accept float; use equal",
      )
    }
    Some(boolean)
  } else if name == "qti-string-match" {
    for arg in args {
      processing_expect(node, arg, processing_type("string", Single))
    }
    Some(boolean)
  } else if ["qti-multiple", "qti-ordered"].contains(name) {
    let mut base : String? = None
    for arg in args {
      if arg.kind is Some(k) {
        if base is Some(b) && b != k.base {
          raise InvalidItem(
            node.location(),
            "container operand base-types differ",
          )
        }
        if name == "qti-ordered" && k.cardinality == Multiple {
          raise InvalidItem(node.location(), "ordered cannot contain multiple")
        }
        if name == "qti-multiple" && k.cardinality == Ordered {
          raise InvalidItem(node.location(), "multiple cannot contain ordered")
        }
        base = Some(k.base)
      }
    }
    base.map(b => {
      processing_type(
        b,
        if name == "qti-multiple" {
          Multiple
        } else {
          Ordered
        },
      )
    })
  } else if name == "qti-member" {
    if args[0].kind is Some(a) && a.cardinality != Single {
      raise InvalidItem(node.location(), "member first operand must be single")
    }
    if args[1].kind is Some(b) {
      if b.cardinality == Single {
        raise InvalidItem(node.location(), "member needs a container")
      }
      if args[0].kind is Some(a) && a.base != b.base {
        raise InvalidItem(node.location(), "member base-types differ")
      }
    }
    Some(boolean)
  } else if name == "qti-container-size" || name == "qti-index" {
    if args[0].kind is Some(k) && k.cardinality == Single {
      raise InvalidItem(node.location(), "operator requires a container")
    }
    if name == "qti-index" &&
      args[0].kind is Some(k) &&
      k.cardinality != Ordered {
      raise InvalidItem(node.location(), "index requires ordered cardinality")
    }
    if name == "qti-container-size" {
      Some(processing_type("integer", Single))
    } else {
      args[0].kind.map(k => processing_type(k.base, Single))
    }
  } else if name == "qti-integer-to-float" {
    processing_expect(node, args[0], processing_type("integer", Single))
    Some(processing_type("float", Single))
  } else {
    let aggregation = ["qti-sum", "qti-product", "qti-min", "qti-max"].contains(
      name,
    )
    let mut integer = true
    let mut has_type = false
    for arg in args {
      if arg.kind is Some(k) {
        has_type = true
        if !k.numeric() || (!aggregation && k.cardinality != Single) {
          raise InvalidItem(
            node.location(),
            "numeric operator requires numeric operands",
          )
        }
        if k.base == "float" {
          integer = false
        }
      }
    }
    if ["qti-integer-divide", "qti-integer-modulus"].contains(name) && !integer {
      raise InvalidItem(
        node.location(),
        "integer operator requires integer operands",
      )
    }
    if ["qti-equal", "qti-lt", "qti-lte", "qti-gt", "qti-gte"].contains(name) {
      Some(boolean)
    } else if !has_type &&
      !["qti-divide", "qti-integer-divide", "qti-integer-modulus"].contains(
        name,
      ) {
      None
    } else {
      Some(
        processing_type(
          if integer && name != "qti-divide" {
            "integer"
          } else {
            "float"
          },
          Single,
        ),
      )
    }
  }
  // Store an index as a numeric literal argument after type inference.
  let arguments = args.copy()
  if name == "qti-index" {
    let index = nonnegative_int(node, "n")
    if index == 0 {
      raise InvalidItem(node.location(), "index n is one-based")
    }
    arguments.push({
      expression: Literal(Json(index)),
      kind: Some(processing_type("integer", Single)),
      source,
    })
  }
  { expression: Operator(name, arguments, tolerance), kind, source, }
}

///|
fn processing_rules(
  nodes : Array[Node],
  declarations : Array[ProcessingDeclaration],
  test_mode~ : Bool = false,
  item_schemas~ : Array[ProcessingItemSchema]? = None,
) -> Array[ProcessingRule] raise QtiError {
  let rules : Array[ProcessingRule] = []
  for node in nodes {
    if node.element.name.namespace_uri != Some(qti_namespace) {
      raise Unsupported(
        node.location(),
        "processing rule in a different namespace",
      )
    }
    if node.name() == "qti-set-outcome-value" {
      node.only_attributes(["identifier"])
      processing_arity(node, 1, 1)
      let declaration = processing_known(node, declarations)
      if declaration.response {
        raise InvalidItem(node.location(), "cannot assign a response variable")
      }
      let expression = processing_expression(
        node.children[0],
        declarations,
        test_mode~,
        item_schemas~,
      )
      processing_expect(node, expression, declaration.kind)
      rules.push(Assign(declaration.identifier, expression, node.source()))
    } else if node.name() == "qti-lookup-outcome-value" {
      rules.push(
        processing_lookup_rule(node, declarations, test_mode~, item_schemas~),
      )
    } else if node.name() ==
      (if test_mode {
        "qti-outcome-condition"
      } else {
        "qti-response-condition"
      }) {
      node.only_attributes([])
      let prefix = if test_mode { "qti-outcome-" } else { "qti-response-" }
      node.only_children([prefix + "if", prefix + "else-if", prefix + "else"])
      if node.children.is_empty() {
        raise InvalidItem(node.location(), "condition requires an if branch")
      }
      let branches : Array[ProcessingBranch] = []
      for i, branch in node.children {
        branch.only_attributes([])
        if branch.content.to_string().trim() != "" {
          raise InvalidItem(branch.location(), "unexpected conditional text")
        }
        let otherwise = branch.name() == prefix + "else"
        if (i == 0 && branch.name() != prefix + "if") ||
          (i > 0 && !otherwise && branch.name() != prefix + "else-if") ||
          (otherwise && i != node.children.length() - 1) {
          raise InvalidItem(
            branch.location(),
            "invalid conditional branch order",
          )
        }
        let predicate = if otherwise {
          None
        } else {
          if branch.children.is_empty() {
            raise InvalidItem(branch.location(), "if branch needs a predicate")
          }
          let expression = processing_expression(
            branch.children[0],
            declarations,
            test_mode~,
            item_schemas~,
          )
          processing_expect(
            branch,
            expression,
            processing_type("boolean", Single),
          )
          Some(expression)
        }
        let remaining : Array[Node] = []
        for j, child in branch.children {
          if otherwise || j > 0 {
            remaining.push(child)
          }
        }
        if remaining.is_empty() {
          raise InvalidItem(
            branch.location(),
            "branch requires a processing rule",
          )
        }
        branches.push({
          predicate,
          rules: processing_rules(
            remaining,
            declarations,
            test_mode~,
            item_schemas~,
          ),
          source: branch.source(),
        })
      }
      rules.push(Condition(branches))
    } else if node.name() ==
      (if test_mode { "qti-exit-test" } else { "qti-exit-response" }) {
      node.only_attributes([])
      node.only_children([])
      rules.push(Exit(node.source()))
    } else {
      raise Unsupported(node.location(), "processing rule '\{node.name()}'")
    }
  }
  rules
}

///|
fn processing_program_root(
  root : Node,
  item_declarations~ : Json = Json::null(),
) -> ProcessingProgram raise QtiError {
  let test_mode = root.name() == "qti-assessment-test"
  let declarations = processing_declarations(root)
  let item_schemas = processing_item_schemas(item_declarations)
  let processing = root.one(
    if test_mode {
      "qti-outcome-processing"
    } else {
      "qti-response-processing"
    },
    required=false,
  )
  guard processing is Some(processing) else {
    return { declarations, rules: [], test_mode, }
  }
  let rules = if processing.attr("template") is Some(uri) {
    if test_mode {
      raise Unsupported(processing.location(), "outcome processing template")
    }
    processing.only_attributes(["template", "template-location"])
    processing.only_children([])
    let template = parse_template(uri)
    let responses = declarations.filter(d => d.response)
    if responses.length() != 1 || responses[0].identifier != "RESPONSE" {
      raise InvalidItem(
        processing.location(),
        "standard template requires one RESPONSE declaration",
      )
    }
    let response = responses[0]
    if template == MatchCorrect &&
      (response.correct == Json::null() || response.kind.base == "float") {
      raise InvalidItem(
        processing.location(),
        "match_correct requires a non-float correct response",
      )
    }
    if template == MapResponse && response.mapping is None {
      raise InvalidItem(
        processing.location(),
        "map_response requires response mapping",
      )
    }
    let non_null = if template == MatchCorrect {
      "<qti-response-condition><qti-response-if><qti-match><qti-variable identifier=\"RESPONSE\"/><qti-correct identifier=\"RESPONSE\"/></qti-match><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">1</qti-base-value></qti-set-outcome-value></qti-response-if><qti-response-else><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">0</qti-base-value></qti-set-outcome-value></qti-response-else></qti-response-condition>"
    } else {
      "<qti-set-outcome-value identifier=\"SCORE\"><qti-map-response identifier=\"RESPONSE\"/></qti-set-outcome-value>"
    }
    let normalized = parse_document(
      "<qti-response-processing xmlns=\"\{qti_namespace}\"><qti-response-condition><qti-response-if><qti-is-null><qti-variable identifier=\"RESPONSE\"/></qti-is-null><qti-set-outcome-value identifier=\"SCORE\"><qti-base-value base-type=\"float\">0</qti-base-value></qti-set-outcome-value></qti-response-if><qti-response-else>\{non_null}</qti-response-else></qti-response-condition></qti-response-processing>",
      Limits::default(),
    )
    processing_rules(normalized.children, declarations)
  } else {
    processing.only_attributes([])
    if processing.content.to_string().trim() != "" {
      raise InvalidItem(processing.location(), "unexpected processing text")
    }
    processing_rules(
      processing.children,
      declarations,
      test_mode~,
      item_schemas~,
    )
  }
  { declarations, rules, test_mode, }
}

///|
/// Compile typed processing from an item or test document. This API validates
/// declarations and processing; compile_processed_item additionally validates
/// the item body and its interactions.
///
/// For test programs, item_declarations is an array of metadata objects with
/// identifier, outcome_types, response_types, categories and section_identifiers.
/// Variable types have base_type and cardinality fields. Include candidates
/// that selection may omit so references to unselected items evaluate to NULL.
/// Bound metadata is required for prefixed item references and for inferring
/// the base-type of an untyped test-variables expression.
pub fn compile_processing_program(
  xml : String,
  limits~ : Limits = Limits::default(),
  item_declarations~ : Json = Json::null(),
) -> ProcessingProgram raise QtiError {
  let root = parse_document(xml, limits)
  if !["qti-assessment-item", "qti-assessment-test"].contains(root.name()) ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(root.location(), "expected QTI assessment item/test")
  }
  processing_program_root(root, item_declarations~)
}

///|
fn processing_tolerance(node : Node) -> NumericTolerance raise QtiError {
  let mode = node.attr("tolerance-mode").unwrap_or("exact")
  if !["exact", "absolute", "relative"].contains(mode) {
    raise InvalidItem(node.location(), "invalid tolerance-mode")
  }
  let mut lower = 0.0
  let mut upper = 0.0
  if mode != "exact" {
    let parts = node
      .required("tolerance")
      .split(" ")
      .filter(s => s != "")
      .map(s => s.to_owned())
      .collect()
    if parts.length() != 1 && parts.length() != 2 {
      raise InvalidItem(node.location(), "tolerance requires one or two values")
    }
    lower = authored_number(parts[0], Float, node)
    upper = if parts.length() == 1 {
      lower
    } else {
      authored_number(parts[1], Float, node)
    }
    if lower < 0.0 || upper < 0.0 {
      raise InvalidItem(node.location(), "negative tolerance")
    }
  } else if node.attr("tolerance") is Some(_) {
    raise InvalidItem(node.location(), "tolerance on exact comparison")
  }
  {
    mode,
    lower,
    upper,
    include_lower: xml_bool(node, "include-lower-bound", default=true),
    include_upper: xml_bool(node, "include-upper-bound", default=true),
  }
}
