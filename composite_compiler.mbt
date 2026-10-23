///|
pub fn compile_composite_item(
  xml : String,
  limits~ : Limits = Limits::default(),
) -> CompositeItem raise QtiError {
  compile_composite_root(parse_document(xml, limits))
}

///|
fn compile_composite_root(root : Node) -> CompositeItem raise QtiError {
  if root.name() != "qti-assessment-item" ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(root.location(), "expected a QTI 3 assessment item")
  }
  root.only_attributes([
    "identifier", "title", "adaptive", "time-dependent", "label",
  ])
  root.only_children([
    "qti-response-declaration", "qti-outcome-declaration", "qti-item-body", "qti-response-processing",
  ])
  if xml_bool(root, "adaptive", default=false) ||
    xml_bool(root, "time-dependent", default=false) {
    raise Unsupported(
      root.location(),
      "adaptive or time-dependent composite items",
    )
  }
  let declarations = root.children.filter(n => {
    n.name() == "qti-response-declaration"
  })
  if declarations.length() < 2 {
    raise InvalidItem(
      root.location(),
      "composite requires at least two responses",
    )
  }
  if declarations.length() > 8 {
    raise LimitExceeded("composite supports at most eight responses")
  }
  let bindings : Array[CompositeBinding] = []
  for declaration in declarations {
    declaration.only_attributes(["identifier", "cardinality", "base-type"])
    declaration.only_children(["qti-correct-response", "qti-mapping"])
    let id = identifier(
      declaration.required("identifier"),
      declaration.location(),
    )
    if id == "SCORE" || bindings.any(b => b.identifier == id) {
      raise InvalidItem(
        declaration.location(),
        "duplicate or reserved response identifier",
      )
    }
    let cardinality = match declaration.required("cardinality") {
      "single" => Cardinality::Single
      "multiple" => Cardinality::Multiple
      _ =>
        raise Unsupported(
          declaration.location(),
          "composite supports single or multiple cardinality",
        )
    }
    let base_type = match declaration.required("base-type") {
      "identifier" => BaseType::Identifier
      "string" => BaseType::Text
      "integer" => BaseType::Integer
      "float" => BaseType::Float
      _ =>
        raise Unsupported(
          declaration.location(),
          "composite supports text/numeric entry, inline choice, block choice and sliders only",
        )
    }
    if cardinality == Multiple && base_type != Identifier {
      raise Unsupported(
        declaration.location(),
        "multiple composite responses require identifier base type",
      )
    }
    let correct = declaration
      .one("qti-correct-response", required=false)
      .map(n => parse_correct(n, cardinality, base_type))
    let mapping = declaration
      .one("qti-mapping", required=false)
      .map(n => parse_mapping(n, base_type))
    bindings.push({
      identifier: id,
      cardinality,
      base_type,
      correct,
      mapping,
      placeholder: "",
      choices: [],
      inline_choice: None,
      choice: None,
      slider: None,
      source: declaration.source(),
    })
  }
  let outcome = root.one("qti-outcome-declaration").unwrap()
  outcome.only_attributes([
    "identifier", "cardinality", "base-type", "normal-minimum", "normal-maximum",
  ])
  outcome.only_children([])
  if outcome.required("identifier") != "SCORE" ||
    outcome.required("cardinality") != "single" ||
    outcome.required("base-type") != "float" {
    raise Unsupported(
      outcome.location(),
      "composite requires one single float SCORE",
    )
  }
  ignore(optional_number(outcome, "normal-minimum"))
  ignore(optional_number(outcome, "normal-maximum"))
  let body = root.one("qti-item-body").unwrap()
  let interactions : Array[Node] = []
  collect_interactions(body, interactions, "")
  let passage : Array[CompositePart] = []
  let seen : Map[String, Bool] = Map([])
  composite_passage(body, bindings, passage, seen)
  if seen.length() != bindings.length() {
    raise InvalidItem(
      body.location(),
      "every composite response needs exactly one interaction",
    )
  }
  for binding in bindings {
    binding.validate_choice_declaration()
  }
  let processing = root.one("qti-response-processing").unwrap()
  let rules = parse_composite_rules(processing, bindings)
  {
    identifier: identifier(root.required("identifier"), root.location()),
    title: root.required("title"),
    bindings,
    passage,
    rules,
    instructions: body.children
    .filter(n => n.name() == "qti-rubric-block")
    .map(n => candidate_instructions(n)),
    source: processing.source(),
  }
}

///|
fn composite_passage(
  node : Node,
  bindings : Array[CompositeBinding],
  parts : Array[CompositePart],
  seen : Map[String, Bool],
) -> Unit raise QtiError {
  if node.name() == "qti-rubric-block" {
    return
  }
  if node.name() == "qti-text-entry-interaction" ||
    node.name() == "qti-inline-choice-interaction" ||
    node.name() == "qti-choice-interaction" ||
    node.name() == "qti-slider-interaction" {
    let id = node.required("response-identifier")
    let mut found = false
    for i, binding in bindings {
      if binding.identifier == id {
        if seen.contains(id) {
          raise InvalidItem(
            node.location(),
            "duplicate entry for response '\{id}'",
          )
        }
        seen[id] = true
        bindings[i] = binding.with_interaction(node)
        found = true
      }
    }
    if !found {
      raise InvalidItem(
        node.location(),
        "entry references an undeclared response '\{id}'",
      )
    }
    parts.push(Response(id))
    return
  }
  if ![
      "qti-item-body", "p", "div", "blockquote", "ul", "ol", "li", "span", "strong",
      "em", "b", "i", "u", "sub", "sup", "br",
    ].contains(node.name()) {
    raise Unsupported(node.location(), "composite context '\{node.name()}'")
  }
  node.only_attributes(["class", "id", "dir"])
  if node.name() == "br" {
    node.only_children([])
  }
  for part in node.parts {
    match part {
      Text(text) =>
        if node.name() != "qti-item-body" || text.trim() != "" {
          parts.push(Text(text))
        }
      Element(child) => composite_passage(child, bindings, parts, seen)
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    parts.push(Text("\n"))
  }
}

///|
fn composite_ref(
  node : Node,
  name : String,
  id : String,
) -> Unit raise QtiError {
  if node.name() != name {
    raise Unsupported(node.location(), "expected '\{name}'")
  }
  node.only_attributes(["identifier"])
  node.only_children([])
  if node.required("identifier") != id {
    raise InvalidItem(node.location(), "inconsistent response reference")
  }
}

///|
fn composite_literal(node : Node) -> Double raise QtiError {
  if node.name() != "qti-base-value" {
    raise Unsupported(node.location(), "expected float literal")
  }
  node.only_attributes(["base-type"])
  if node.required("base-type") != "float" || !node.children.is_empty() {
    raise Unsupported(node.location(), "expected literal float")
  }
  authored_number(node.content.to_string(), Float, node)
}

///|
fn parse_composite_rules(
  node : Node,
  bindings : Array[CompositeBinding],
) -> Array[CompositeRule] raise QtiError {
  node.only_attributes([])
  node.only_children(["qti-set-outcome-value", "qti-response-condition"])
  if node.children.length() != bindings.length() + 1 {
    raise Unsupported(
      node.location(),
      "expected SCORE initialization and one guarded rule per response",
    )
  }
  let init = node.children[0]
  init.only_attributes(["identifier"])
  init.only_children(["qti-base-value"])
  if init.name() != "qti-set-outcome-value" ||
    init.required("identifier") != "SCORE" ||
    composite_literal(init.one("qti-base-value").unwrap()) != 0.0 {
    raise Unsupported(
      init.location(),
      "composite SCORE must initialize to zero",
    )
  }
  let used : Map[String, Bool] = Map([])
  let rules : Array[CompositeRule] = []
  for index = 1; index < node.children.length(); index = index + 1 {
    let condition = node.children[index]
    condition.only_attributes([])
    condition.only_children([
      "qti-response-if", "qti-response-else-if", "qti-response-else",
    ])
    if condition.name() != "qti-response-condition" ||
      condition.children.is_empty() {
      raise Unsupported(
        condition.location(),
        "expected guarded response condition",
      )
    }
    if condition.children.length() > 128 {
      raise LimitExceeded("composite response exceeds 128 branches")
    }
    let branches : Array[CompositeBranch] = []
    let mut binding_index = -1
    for i, branch in condition.children {
      if branch.name() == "qti-response-else" {
        if i == 0 || i != condition.children.length() - 1 {
          raise InvalidItem(
            branch.location(),
            "response-else must be last after response-if",
          )
        }
        branch.only_attributes([])
        branch.only_children(["qti-set-outcome-value"])
        let weight = composite_literal(
          composite_contribution(branch.one("qti-set-outcome-value").unwrap()),
        )
        branches.push({ credit: Otherwise(weight), source: branch.source(), })
        continue
      }
      let expected = if i == 0 {
        "qti-response-if"
      } else {
        "qti-response-else-if"
      }
      if branch.name() != expected {
        raise InvalidItem(branch.location(), "invalid composite branch order")
      }
      let (current, compiled) = parse_composite_branch(branch, bindings)
      if i == 0 {
        binding_index = current
      } else if current != binding_index {
        raise InvalidItem(
          branch.location(),
          "branches must use the same response",
        )
      }
      branches.push(compiled)
    }
    let id = bindings[binding_index].identifier
    if used.contains(id) {
      raise InvalidItem(
        condition.location(),
        "duplicate scoring rule for response '\{id}'",
      )
    }
    used[id] = true
    rules.push({ binding: binding_index, branches, })
  }
  rules
}

///|
fn parse_composite_branch(
  branch : Node,
  bindings : Array[CompositeBinding],
) -> (Int32, CompositeBranch) raise QtiError {
  branch.only_attributes([])
  branch.only_children([
    "qti-not", "qti-match", "qti-equal", "qti-is-null", "qti-set-outcome-value",
  ])
  if branch.children.length() != 2 ||
    branch.children[1].name() != "qti-set-outcome-value" {
    raise Unsupported(
      branch.location(),
      "expected one predicate and one SCORE assignment",
    )
  }
  let predicate = branch.children[0]
  let variable = if predicate.name() == "qti-not" {
    predicate.only_attributes([])
    predicate.only_children(["qti-is-null"])
    let null_test = predicate.one("qti-is-null").unwrap()
    null_test.only_attributes([])
    null_test.only_children(["qti-variable"])
    null_test.one("qti-variable").unwrap()
  } else if predicate.name() == "qti-match" {
    predicate.only_attributes([])
    predicate.only_children(["qti-variable", "qti-correct"])
    ignore(predicate.one("qti-correct"))
    predicate.one("qti-variable").unwrap()
  } else if predicate.name() == "qti-is-null" {
    predicate.only_attributes([])
    predicate.only_children(["qti-variable"])
    predicate.one("qti-variable").unwrap()
  } else if predicate.name() == "qti-equal" {
    // Exactly one variable identifies the response owned by this condition.
    // The shared numeric parser validates its other operand and tolerances.
    predicate.one("qti-variable").unwrap()
  } else {
    raise Unsupported(predicate.location(), "unsupported composite predicate")
  }
  let id = variable.required("identifier")
  composite_ref(variable, "qti-variable", id)
  let mut binding_index = -1
  for i, binding in bindings {
    if binding.identifier == id {
      binding_index = i
    }
  }
  if binding_index < 0 {
    raise InvalidItem(variable.location(), "unknown scoring response '\{id}'")
  }
  let binding = bindings[binding_index]
  let assignment = branch.children[1]
  let term = composite_contribution(assignment)
  let credit = if predicate.name() == "qti-not" {
    if binding.mapping is None {
      raise InvalidItem(term.location(), "map-response requires a mapping")
    }
    composite_ref(term, "qti-map-response", id)
    CompositeCredit::Mapped
  } else if predicate.name() == "qti-is-null" {
    CompositeCredit::Unanswered(composite_literal(term))
  } else if predicate.name() == "qti-equal" {
    if !binding.base_type.is_numeric() {
      raise Unsupported(
        predicate.location(),
        "qti-equal requires a numeric response",
      )
    }
    if predicate.one("qti-correct", required=false) is Some(correct) {
      composite_ref(correct, "qti-correct", id)
    }
    let comparison = parse_numeric_test(
      predicate,
      binding.correct,
      binding.base_type,
      response_id=id,
    )
    CompositeCredit::Compared(comparison, composite_literal(term))
  } else {
    composite_ref(predicate.one("qti-correct").unwrap(), "qti-correct", id)
    if binding.correct is None {
      raise InvalidItem(
        predicate.location(),
        "match requires a correct response",
      )
    }
    if binding.base_type == Float {
      raise Unsupported(
        predicate.location(),
        "qti-match is not supported for float",
      )
    }
    CompositeCredit::Matched(composite_literal(term))
  }
  (binding_index, { credit, source: branch.source(), })
}

///|
fn composite_contribution(assignment : Node) -> Node raise QtiError {
  if assignment.name() != "qti-set-outcome-value" {
    raise Unsupported(assignment.location(), "expected SCORE assignment")
  }
  assignment.only_attributes(["identifier"])
  assignment.only_children(["qti-sum"])
  if assignment.required("identifier") != "SCORE" {
    raise Unsupported(
      assignment.location(),
      "only SCORE assignment is supported",
    )
  }
  let sum = assignment.one("qti-sum").unwrap()
  sum.only_attributes([])
  sum.only_children(["qti-variable", "qti-map-response", "qti-base-value"])
  if sum.children.length() != 2 {
    raise Unsupported(sum.location(), "expected SCORE plus one contribution")
  }
  composite_ref(sum.children[0], "qti-variable", "SCORE")
  sum.children[1]
}
