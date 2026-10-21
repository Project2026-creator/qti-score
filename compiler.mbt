///|
/// Compile the supported QTI 3 item profile, including checked numeric rules.
/// Templates use a closed URI allowlist and are never downloaded or executed.
pub fn compile_item(
  xml : String,
  limits~ : Limits = Limits::default(),
) -> Item raise QtiError {
  let root = parse_document(xml, limits)
  if root.name() != "qti-assessment-item" ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(root.location(), "expected a QTI 3 qti-assessment-item")
  }
  root.only_attributes([
    "identifier", "title", "adaptive", "time-dependent", "label",
  ])
  root.only_children([
    "qti-response-declaration", "qti-outcome-declaration", "qti-item-body", "qti-response-processing",
  ])
  if xml_bool(root, "adaptive", default=false) ||
    xml_bool(root, "time-dependent", default=false) {
    raise Unsupported(root.location(), "adaptive or time-dependent items")
  }
  let item_id = identifier(root.required("identifier"), root.location())
  let title = root.required("title")
  let declaration = root.one("qti-response-declaration").unwrap()
  declaration.only_attributes(["identifier", "cardinality", "base-type"])
  declaration.only_children(["qti-correct-response", "qti-mapping"])
  let response_id = declaration.required("identifier")
  if response_id != "RESPONSE" {
    raise Unsupported(
      declaration.location(),
      "standard templates require response identifier RESPONSE",
    )
  }
  let cardinality = match declaration.required("cardinality") {
    "single" => Cardinality::Single
    "multiple" => Cardinality::Multiple
    "ordered" => Cardinality::Ordered
    other => raise Unsupported(declaration.location(), "cardinality '\{other}'")
  }
  let base_type = match declaration.required("base-type") {
    "identifier" => BaseType::Identifier
    "string" => BaseType::Text
    "integer" => BaseType::Integer
    "float" => BaseType::Float
    "directedPair" => BaseType::DirectedPair
    other => raise Unsupported(declaration.location(), "base-type '\{other}'")
  }
  let correct = match declaration.one("qti-correct-response", required=false) {
    None => None
    Some(n) => Some(parse_correct(n, cardinality, base_type))
  }
  if cardinality == Ordered && base_type != Identifier {
    raise Unsupported(
      declaration.location(),
      "ordered responses require identifier base-type in this profile",
    )
  }
  if base_type.is_numeric() && cardinality != Single {
    raise Unsupported(
      declaration.location(),
      "numeric responses require single cardinality",
    )
  }
  let mapping = match declaration.one("qti-mapping", required=false) {
    None => None
    Some(n) => {
      if cardinality == Ordered {
        raise Unsupported(
          n.location(),
          "ordered mappings are outside this profile",
        )
      }
      if base_type.is_numeric() {
        raise Unsupported(
          n.location(),
          "numeric mappings are outside this profile",
        )
      }
      Some(parse_mapping(n, base_type))
    }
  }
  let outcome = root.one("qti-outcome-declaration").unwrap()
  outcome.only_attributes([
    "identifier", "cardinality", "base-type", "normal-minimum", "normal-maximum",
  ])
  outcome.only_children(["qti-default-value"])
  if outcome.required("identifier") != "SCORE" ||
    outcome.required("cardinality") != "single" ||
    outcome.required("base-type") != "float" {
    raise Unsupported(
      outcome.location(),
      "expected one single float SCORE outcome",
    )
  }
  ignore(optional_number(outcome, "normal-minimum"))
  ignore(optional_number(outcome, "normal-maximum"))
  if outcome.one("qti-default-value", required=false) is Some(default_node) {
    default_node.only_attributes([])
    default_node.only_children(["qti-value"])
    let value = default_node.one("qti-value").unwrap()
    value.only_attributes([])
    if !value.children.is_empty() {
      raise InvalidItem(
        value.location(),
        "score default must contain text only",
      )
    }
    let text = value.content.to_string()
    let parsed = @string.parse_double(text.trim()) catch {
      _ => raise InvalidItem(value.location(), "invalid SCORE default")
    }
    if text.contains("_") || parsed.is_nan() || parsed.is_inf() {
      raise InvalidItem(value.location(), "invalid SCORE default")
    }
  }
  let processing = root.one("qti-response-processing").unwrap()
  let (template, numeric_rule) = if processing.attr("template") is Some(uri) {
    processing.only_attributes(["template"])
    processing.only_children([])
    (parse_template(uri), None)
  } else {
    if !base_type.is_numeric() {
      raise Unsupported(
        processing.location(),
        "inline rules require a numeric response",
      )
    }
    (NumericRules, Some(parse_numeric_rule(processing, correct, base_type)))
  }
  if base_type == Float && template != NumericRules {
    raise Unsupported(
      processing.location(),
      "float responses require numeric inline rules, not match_correct",
    )
  }
  if template == MatchCorrect && correct is None {
    raise InvalidItem(
      declaration.location(),
      "match_correct requires qti-correct-response",
    )
  }
  if template == MapResponse && mapping is None {
    raise InvalidItem(
      declaration.location(),
      "map_response requires qti-mapping",
    )
  }
  let body = root.one("qti-item-body").unwrap()
  body.only_attributes(["class", "id", "dir"])
  let interactions : Array[Node] = []
  collect_interactions(body, interactions, "")
  if interactions.length() != 1 {
    raise Unsupported(
      body.location(),
      "expected exactly one supported interaction",
    )
  }
  let interaction = interactions[0]
  let ordered = interaction.name() == "qti-order-interaction"
  let mut matching : MatchInteraction? = None
  let mut gap_passage : Array[GapPart]? = None
  let gap_match = interaction.name() == "qti-gap-match-interaction"
  if (base_type == DirectedPair) !=
    (interaction.name() == "qti-match-interaction" || gap_match) {
    raise InvalidItem(
      interaction.location(),
      "directedPair requires a match or gap-match interaction",
    )
  }
  if interaction.required("response-identifier") != response_id {
    raise InvalidItem(
      interaction.location(),
      "response-identifier does not match declaration",
    )
  }
  let choices : Array[Choice] = []
  let mut min_choices = 0
  let mut max_choices = 1
  let prompt = if interaction.name() == "qti-match-interaction" || gap_match {
    let spec = if gap_match {
      let (spec, passage) = parse_gap_interaction(interaction, cardinality)
      gap_passage = Some(passage)
      spec
    } else {
      parse_match_interaction(interaction, cardinality)
    }
    min_choices = spec.minimum
    max_choices = spec.maximum
    if correct is Some(values) {
      spec.validate(values) catch {
        error => raise InvalidItem(declaration.location(), error.message())
      }
    }
    if mapping is Some(m) {
      for entry in m.entries {
        ignore(
          spec.endpoints(entry.key) catch {
            error => raise InvalidItem(declaration.location(), error.message())
          },
        )
      }
    }
    matching = Some(spec)
    match interaction.one("qti-prompt", required=false) {
      Some(n) => n.all_text.to_string().trim().to_owned()
      None => title
    }
  } else if interaction.name() == "qti-choice-interaction" || ordered {
    if base_type != Identifier {
      raise InvalidItem(
        interaction.location(),
        "choice interaction requires identifier base-type",
      )
    }
    if (ordered && cardinality != Ordered) ||
      (!ordered && cardinality == Ordered) {
      raise InvalidItem(
        interaction.location(),
        "order interaction requires ordered cardinality; choice interaction requires single or multiple",
      )
    }
    interaction.only_attributes([
      "response-identifier", "shuffle", "min-choices", "max-choices", "class", "id",
      "orientation",
    ])
    interaction.only_children(["qti-prompt", "qti-simple-choice"])
    ignore(xml_bool(interaction, "shuffle", default=false))
    if !ordered {
      min_choices = nonnegative_int(interaction, "min-choices", default=0)
      max_choices = nonnegative_int(interaction, "max-choices")
    }
    for choice in interaction.children {
      if choice.name() != "qti-simple-choice" {
        continue
      }
      choice.only_attributes(["identifier", "fixed", "class", "id"])
      ignore(xml_bool(choice, "fixed", default=false))
      let id = identifier(choice.required("identifier"), choice.location())
      if choices.any(c => c.identifier == id) {
        raise InvalidItem(choice.location(), "duplicate choice '\{id}'")
      }
      choices.push({
        identifier: id,
        text: choice.all_text.to_string().trim().to_owned(),
      })
    }
    if ordered {
      let (minimum, maximum) = order_limits(interaction, choices.length())
      min_choices = minimum
      max_choices = maximum
    }
    let needed = if ordered { 1 } else { 2 }
    if choices.length() < needed {
      raise InvalidItem(
        interaction.location(),
        "interaction needs at least \{needed} choice(s)",
      )
    }
    if (cardinality == Single && max_choices != 1) ||
      min_choices > choices.length() ||
      (
        max_choices != 0 &&
        (max_choices > choices.length() || min_choices > max_choices)
      ) {
      raise InvalidItem(
        interaction.location(),
        "inconsistent min-choices/max-choices",
      )
    }
    match interaction.one("qti-prompt", required=false) {
      Some(n) => n.all_text.to_string().trim().to_owned()
      None => title
    }
  } else {
    if cardinality != Single || base_type == Identifier {
      raise Unsupported(
        interaction.location(),
        "text entry requires a single string, integer or float response",
      )
    }
    interaction.only_attributes([
      "response-identifier", "expected-length", "class", "id", "placeholder-text",
    ])
    interaction.only_children([])
    if interaction.attr("expected-length") is Some(_) {
      ignore(nonnegative_int(interaction, "expected-length"))
    }
    body.all_text.to_string().trim().to_owned()
  }
  if !choices.is_empty() {
    if correct is Some(values) {
      if ordered {
        let seen : Map[String, Bool] = Map([])
        for value in values {
          if seen.contains(value) {
            raise InvalidItem(
              declaration.location(),
              "duplicate ordered correct choice '\{value}'",
            )
          }
          seen[value] = true
        }
      }
      if values.length() < min_choices ||
        (max_choices != 0 && values.length() > max_choices) {
        raise InvalidItem(
          declaration.location(),
          "correct response violates choice limits",
        )
      }
      for value in values {
        if !choices.any(c => c.identifier == value) {
          raise InvalidItem(
            declaration.location(),
            "correct response references unknown choice '\{value}'",
          )
        }
      }
    }
    if mapping is Some(m) {
      for entry in m.entries {
        if !choices.any(c => c.identifier == entry.key) {
          raise InvalidItem(
            declaration.location(),
            "mapping references unknown choice '\{entry.key}'",
          )
        }
      }
    }
  }
  {
    identifier: item_id,
    title,
    response_identifier: response_id,
    cardinality,
    base_type,
    template,
    prompt,
    min_choices,
    max_choices,
    choices,
    correct,
    mapping,
    numeric_rule,
    matching,
    gap_passage,
    processing_source: processing.source(),
  }
}

///|
fn parse_template(uri : String) -> Template raise QtiError {
  for
    prefix in [
      "https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/", "http://purl.imsglobal.org/spec/qti/v3p0/rptemplates/",
      "https://www.imsglobal.org/question/qti_v3p0/rptemplates/", "http://www.imsglobal.org/question/qti_v3p0/rptemplates/",
    ] {
    if uri == prefix + "match_correct" || uri == prefix + "match_correct.xml" {
      return MatchCorrect
    }
    if uri == prefix + "map_response" || uri == prefix + "map_response.xml" {
      return MapResponse
    }
  }
  raise Unsupported("qti-response-processing", "template '\{uri}'")
}

///|
fn parse_correct(
  node : Node,
  cardinality : Cardinality,
  base_type : BaseType,
) -> Array[String] raise QtiError {
  node.only_attributes([])
  node.only_children(["qti-value"])
  if node.children.is_empty() ||
    (cardinality == Single && node.children.length() != 1) {
    raise InvalidItem(
      node.location(),
      "correct response has invalid cardinality",
    )
  }
  let values : Array[String] = []
  for child in node.children {
    child.only_attributes([])
    if !child.children.is_empty() {
      raise InvalidItem(child.location(), "qti-value must contain text only")
    }
    let value = child.content.to_string()
    if base_type == Identifier {
      values.push(identifier(value.trim().to_owned(), child.location()))
    } else if base_type == DirectedPair {
      values.push(authored_pair(value, child))
    } else if base_type.is_numeric() {
      ignore(authored_number(value, base_type, child))
      values.push(value.trim().to_owned())
    } else {
      if value == "" {
        raise InvalidItem(child.location(), "empty correct string is NULL")
      }
      values.push(value)
    }
  }
  values
}

///|
fn parse_mapping(node : Node, base_type : BaseType) -> Mapping raise QtiError {
  node.only_attributes(["default-value", "lower-bound", "upper-bound"])
  node.only_children(["qti-map-entry"])
  let default_value = optional_number(node, "default-value").unwrap_or(0.0)
  let lower_bound = optional_number(node, "lower-bound")
  let upper_bound = optional_number(node, "upper-bound")
  if lower_bound is Some(lo) && upper_bound is Some(hi) && lo > hi {
    raise InvalidItem(node.location(), "lower-bound exceeds upper-bound")
  }
  if node.children.is_empty() {
    raise InvalidItem(node.location(), "mapping needs at least one map entry")
  }
  let entries : Array[MapEntry] = []
  for child in node.children {
    child.only_attributes(["map-key", "mapped-value", "case-sensitive"])
    child.only_children([])
    let key = if base_type == DirectedPair {
      authored_pair(child.required("map-key"), child)
    } else {
      child.required("map-key")
    }
    if base_type == Identifier {
      ignore(identifier(key, child.location()))
    }
    let case_sensitive = xml_bool(child, "case-sensitive", default=false)
    let folded_key = @casefold.casefold(key)
    if entries.any(e => {
        e.key == key ||
        (
          base_type == Text &&
          !case_sensitive &&
          !e.case_sensitive &&
          e.folded_key == folded_key
        )
      }) {
      raise InvalidItem(
        child.location(),
        "duplicate or ambiguous map-key '\{key}'",
      )
    }
    entries.push({
      key,
      folded_key,
      value: number(child, "mapped-value"),
      case_sensitive,
      source: child.source(),
    })
  }
  { entries, default_value, lower_bound, upper_bound, source: node.source(), }
}

///|
fn nonnegative_int(
  node : Node,
  attribute : String,
  default? : Int32,
) -> Int32 raise QtiError {
  let text = match node.attr(attribute) {
    None =>
      match default {
        Some(n) => return n
        None => raise InvalidItem(node.location(), "missing '\{attribute}'")
      }
    Some(s) => s
  }
  if text == "" || !text.iter().all(c => '0' <= c && c <= '9') {
    raise InvalidItem(
      node.location(),
      "invalid nonnegative integer '\{attribute}'",
    )
  }
  @string.parse_int(text[:]) catch {
    _ =>
      raise InvalidItem(node.location(), "integer out of range '\{attribute}'")
  }
}

///|
fn collect_interactions(
  node : Node,
  found : Array[Node],
  parent : String,
  inside_gap~ : Bool = false,
) -> Unit raise QtiError {
  let name = node.name()
  let uri = node.element.name.namespace_uri
  if uri != Some(qti_namespace) && uri != Some("http://www.w3.org/1999/xhtml") {
    raise Unsupported(node.location(), "body namespace '\{uri.unwrap_or("")}'")
  }
  if name.has_prefix("qti-") && uri != Some(qti_namespace) {
    raise Unsupported(node.location(), "QTI element in a different namespace")
  }
  if (name == "qti-simple-choice" || name == "qti-prompt") &&
    parent != "qti-choice-interaction" &&
    parent != "qti-order-interaction" &&
    !(name == "qti-prompt" &&
    ["qti-match-interaction", "qti-gap-match-interaction"].contains(parent)) {
    raise InvalidItem(
      node.location(),
      "element must be a child of a choice or order interaction",
    )
  }
  if name == "qti-gap-text" && parent != "qti-gap-match-interaction" {
    raise InvalidItem(
      node.location(),
      "gap-text must be a direct child of gap-match interaction",
    )
  }
  if name == "qti-gap" && !inside_gap {
    raise InvalidItem(
      node.location(),
      "gap must be inside a gap-match interaction",
    )
  }
  if (name == "qti-simple-match-set" && parent != "qti-match-interaction") ||
    (name == "qti-simple-associable-choice" && parent != "qti-simple-match-set") {
    raise InvalidItem(node.location(), "misplaced match interaction element")
  }
  if name == "qti-item-body" && parent != "" {
    raise InvalidItem(node.location(), "nested item body")
  }
  if name == "qti-choice-interaction" ||
    name == "qti-text-entry-interaction" ||
    name == "qti-order-interaction" ||
    name == "qti-match-interaction" ||
    name == "qti-gap-match-interaction" {
    found.push(node)
  } else if ![
      "qti-item-body", "qti-simple-choice", "qti-prompt", "qti-simple-match-set",
      "qti-gap-text", "qti-gap", "qti-simple-associable-choice", "p", "div", "span",
      "br", "blockquote", "strong", "em", "b", "i", "u", "sub", "sup", "ul", "ol",
      "li", "img", "a", "table", "thead", "tbody", "tr", "th", "td",
    ].contains(name) {
    raise Unsupported(node.location(), "body element '\{name}'")
  }
  for child in node.children {
    collect_interactions(
      child,
      found,
      name,
      inside_gap=inside_gap || name == "qti-gap-match-interaction",
    )
  }
}
