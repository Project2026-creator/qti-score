///|
fn processing_renamed(
  node : Node,
  declaration~ : Bool = false,
) -> Node raise QtiError {
  parse_document(processing_node_xml(node, declaration~), Limits::default())
}

///|
fn processing_node_xml(
  node : Node,
  declaration~ : Bool = false,
  normalize_responses~ : Bool = true,
) -> String {
  if node.name() == "qti-extended-text-interaction" {
    let id = if normalize_responses {
      "RESPONSE"
    } else {
      node.attr("response-identifier").unwrap_or("")
    }
    let prompt = node.children
      .filter(n => n.name() == "qti-prompt")
      .map(n => n.all_text.to_string())
      .join("\n")
    return "<div xmlns=\"\{qti_namespace}\"><p>\{processing_escape(prompt)}</p><qti-text-entry-interaction response-identifier=\"\{processing_escape(id)}\" placeholder-text=\"\{processing_escape(node.attr("placeholder-text").unwrap_or(""))}\"/></div>"
  }
  let output = StringBuilder()
  output.write_string(
    "<\{node.name()} xmlns=\"\{processing_escape(node.element.name.namespace_uri.unwrap_or(""))}\"",
  )
  for index, attr in node.element.attributes {
    let value = if normalize_responses &&
      attr.name.namespace_uri is None &&
      (
        attr.name.local_name == "response-identifier" ||
        (declaration && attr.name.local_name == "identifier")
      ) {
      "RESPONSE"
    } else {
      attr.value
    }
    let name = match attr.name.namespace_uri {
      None => attr.name.local_name
      Some("http://www.w3.org/XML/1998/namespace") =>
        "xml:\{attr.name.local_name}"
      Some(uri) => {
        output.write_string(" xmlns:n\{index}=\"\{processing_escape(uri)}\"")
        "n\{index}:\{attr.name.local_name}"
      }
    }
    output.write_string(" \{name}=\"\{processing_escape(value)}\"")
  }
  output.write_string(">")
  for part in node.parts {
    match part {
      Text(text) => output.write_string(processing_escape(text))
      Element(child) =>
        output.write_string(processing_node_xml(child, normalize_responses~))
    }
  }
  output.write_string("</\{node.name()}>")
  output.to_string()
}

///|
fn processing_nodes(node : Node, name : String) -> Array[Node] {
  let result : Array[Node] = []
  if node.name() == name {
    result.push(node)
  }
  for child in node.children {
    result.append(processing_nodes(child, name))
  }
  result
}

///|
fn processing_extended(
  node : Node,
  program : ProcessingProgram,
) -> ProcessingExtended raise QtiError {
  if node.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(node.location(), "extended text namespace")
  }
  node.only_attributes([
    "response-identifier", "expected-length", "expected-lines", "placeholder-text",
    "format", "min-strings", "max-strings", "class", "id", "dir",
  ])
  node.only_children(["qti-prompt"])
  let id = node.required("response-identifier")
  guard program.declaration(id) is Some(d) &&
    d.response &&
    d.kind.base == "string" &&
    d.kind.cardinality == Single else {
    raise Unsupported(
      node.location(),
      "extended text currently requires a single string response",
    )
  }
  let format = node.attr("format").unwrap_or("plain")
  if !["plain", "preformatted"].contains(format) {
    raise Unsupported(node.location(), "extended text format '\{format}'")
  }
  let minimum = nonnegative_int(node, "min-strings", default=0)
  if minimum > 1 {
    raise InvalidItem(
      node.location(),
      "single extended text min-strings cannot exceed one",
    )
  }
  if node.attr("max-strings") is Some(_) &&
    nonnegative_int(node, "max-strings") != 1 {
    raise Unsupported(
      node.location(),
      "single extended text max-strings other than one",
    )
  }
  let expected_lines = node
    .attr("expected-lines")
    .map(_ => nonnegative_int(node, "expected-lines"))
  let expected_length = node
    .attr("expected-length")
    .map(_ => nonnegative_int(node, "expected-length"))
  let prompt = node
    .one("qti-prompt", required=false)
    .map(n => {
      n.only_attributes(["class", "id", "dir"])
      plain_static_text(n).trim().to_owned()
    })
    .unwrap_or("")
  {
    prompt,
    placeholder: node.attr("placeholder-text").unwrap_or(""),
    format,
    minimum,
    expected_lines,
    expected_length,
  }
}

///|
fn processing_escape(text : String) -> String {
  text
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&apos;")
}

///|
// Reuse the established interaction compiler and validation without executing
// its scoring rule. The synthetic zero mapping is private to this validator.
fn processing_validator(
  root : Node,
  declaration : Node,
  interaction : Node,
  single_body : Node?,
) -> Item raise QtiError {
  let base = declaration.required("base-type")
  let cardinality = declaration.required("cardinality")
  if base == "boolean" {
    raise Unsupported(interaction.location(), "boolean interaction binding")
  }
  let mut mapping_key = "__validation__"
  if base == "integer" || base == "float" {
    mapping_key = "0"
  }
  if base == "identifier" {
    let options = processing_nodes(interaction, "qti-simple-choice") +
      processing_nodes(interaction, "qti-hottext") +
      processing_nodes(interaction, "qti-hotspot-choice") +
      processing_nodes(interaction, "qti-inline-choice")
    if options.is_empty() {
      raise InvalidItem(
        interaction.location(),
        "identifier interaction has no options",
      )
    }
    mapping_key = options[0].required("identifier")
  }
  if base == "directedPair" {
    let kind = if cardinality == "single" {
      Cardinality::Single
    } else {
      Cardinality::Multiple
    }
    let spec = if interaction.name() == "qti-gap-match-interaction" {
      parse_gap_interaction(interaction, kind).0
    } else if interaction.name() == "qti-graphic-gap-match-interaction" {
      parse_graphic_gap_interaction(interaction, kind).1
    } else {
      parse_match_interaction(interaction, kind)
    }
    mapping_key = "\{spec.sources[0].identifier} \{spec.targets[0].identifier}"
  }
  let synthetic = parse_document(
    "<qti-assessment-item xmlns=\"\{qti_namespace}\" identifier=\"validation\" title=\"validation\"><qti-response-declaration identifier=\"RESPONSE\" cardinality=\"single\" base-type=\"string\"><qti-mapping default-value=\"0\"><qti-map-entry map-key=\"\{processing_escape(mapping_key)}\" mapped-value=\"0\"/></qti-mapping></qti-response-declaration><qti-outcome-declaration identifier=\"SCORE\" cardinality=\"single\" base-type=\"float\"/><qti-item-body/><qti-response-processing template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/map_response\"/></qti-assessment-item>",
    Limits::default(),
  )
  let renamed = processing_renamed(declaration, declaration=true)
  let children = renamed.children.filter(n => {
    n.name() == "qti-correct-response" ||
    (n.name() == "qti-mapping" && cardinality != "ordered")
  })
  if cardinality == "ordered" {
    if !children.any(n => n.name() == "qti-correct-response") {
      let options = processing_nodes(interaction, "qti-simple-choice")
      let (minimum, _) = order_limits(interaction, options.length())
      let values = options[:minimum]
        .to_owned()
        .map(n => {
          "<qti-value>\{processing_escape(n.required("identifier"))}</qti-value>"
        })
        .join("")
      let correct = parse_document(
        "<qti-correct-response xmlns=\"\{qti_namespace}\">\{values}</qti-correct-response>",
        Limits::default(),
      )
      children.push(correct)
    }
  } else if !children.any(n => n.name() == "qti-mapping") {
    children.push(synthetic.children[0].children[0])
  }
  let response = { ..renamed, children, }
  let body = match single_body {
    Some(body) => processing_renamed(body)
    None => {
      let renamed_interaction = processing_renamed(interaction)
      {
        ..synthetic.one("qti-item-body").unwrap(),
        children: [renamed_interaction],
        parts: [Element(renamed_interaction)],
        all_text: interaction.all_text,
      }
    }
  }
  let processing = if cardinality == "ordered" {
    parse_document(
      "<qti-response-processing xmlns=\"\{qti_namespace}\" template=\"https://purl.imsglobal.org/spec/qti/v3p0/rptemplates/match_correct\"/>",
      Limits::default(),
    )
  } else {
    synthetic.one("qti-response-processing").unwrap()
  }
  let validator_root = {
    ..root,
    children: [
      response,
      synthetic.one("qti-outcome-declaration").unwrap(),
      body,
      processing,
    ],
  }
  compile_single_root(validator_root)
}

///|
fn processing_passage(node : Node, parts : Array[CompositePart]) -> Unit {
  if node.name() == "qti-rubric-block" {
    return
  }
  if node.attr("response-identifier") is Some(id) {
    parts.push(Response(id))
    return
  }
  for part in node.parts {
    match part {
      Text(text) =>
        if node.name() != "qti-item-body" || text.trim() != "" {
          parts.push(Text(text))
        }
      Element(child) => processing_passage(child, parts)
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    parts.push(Text("\n"))
  }
}

///|
pub fn compile_processed_item(
  xml : String,
  limits~ : Limits = Limits::default(),
) -> ProcessedItem raise QtiError {
  let root = parse_document(xml, limits)
  if root.name() != "qti-assessment-item" ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(root.location(), "expected a QTI 3 assessment item")
  }
  root.only_attributes([
    "identifier", "title", "adaptive", "time-dependent", "label",
  ])
  root.only_children([
    "qti-response-declaration", "qti-outcome-declaration", "qti-item-body", "qti-response-processing",
    "qti-modal-feedback",
  ])
  if xml_bool(root, "adaptive", default=false) ||
    xml_bool(root, "time-dependent", default=false) {
    raise Unsupported(
      root.location(),
      "adaptive or time-dependent processing items",
    )
  }
  let program = processing_program_root(root)
  guard program.declaration("SCORE") is Some(score) &&
    !score.response &&
    score.kind.cardinality == Single &&
    score.kind.numeric() else {
    raise Unsupported(
      root.location(),
      "host scoring requires a single numeric SCORE outcome",
    )
  }
  let body = root.one("qti-item-body").unwrap()
  body.only_attributes(["class", "id", "dir"])
  let interactions : Array[Node] = []
  let extended_nodes = processing_nodes(body, "qti-extended-text-interaction")
  let extended_specs : Map[String, ProcessingExtended] = Map([])
  for node in extended_nodes {
    extended_specs[node.required("response-identifier")] = processing_extended(
      node, program,
    )
  }
  let checked_body = if extended_nodes.is_empty() {
    body
  } else {
    parse_document(processing_node_xml(body, normalize_responses=false), limits)
  }
  collect_interactions(checked_body, interactions, "")
  let responses = root.children.filter(n => {
    n.name() == "qti-response-declaration"
  })
  if responses.is_empty() || responses.length() > 32 {
    raise LimitExceeded("processed item requires between 1 and 32 responses")
  }
  if interactions.length() != responses.length() {
    raise InvalidItem(
      body.location(),
      "every declared response needs exactly one interaction",
    )
  }
  let bindings : Array[ProcessingBinding] = []
  for declaration in responses {
    let id = declaration.required("identifier")
    let matches = interactions.filter(n => {
      n.attr("response-identifier") == Some(id)
    })
    if matches.length() != 1 {
      raise InvalidItem(
        declaration.location(),
        "response must have exactly one matching interaction",
      )
    }
    if program.declaration(id).unwrap().default_value != Json::null() {
      raise Unsupported(
        declaration.location(),
        "response defaults require attempt initialization",
      )
    }
    let original = extended_nodes
      .filter(n => n.attr("response-identifier") == Some(id))
      .get(0)
      .unwrap_or(matches[0])
    bindings.push({
      identifier: id,
      validator: processing_validator(
        root,
        declaration,
        original,
        if responses.length() == 1 {
          Some(body)
        } else {
          None
        },
      ),
      extended: extended_specs.get(id),
    })
  }
  let feedback : Array[ProcessingFeedback] = []
  for node in root.children {
    if node.name() != "qti-modal-feedback" {
      continue
    }
    node.only_attributes([
      "outcome-identifier", "show-hide", "identifier", "title", "class", "id", "dir",
    ])
    let id = identifier(node.required("identifier"), node.location())
    let outcome = node.required("outcome-identifier")
    guard program.declaration(outcome) is Some(d) &&
      !d.response &&
      d.kind.base == "identifier" &&
      d.kind.cardinality != Ordered else {
      raise InvalidItem(
        node.location(),
        "feedback requires a single/multiple identifier outcome",
      )
    }
    let show = match node.required("show-hide") {
      "show" => true
      "hide" => false
      _ => raise InvalidItem(node.location(), "show-hide must be show or hide")
    }
    let text = match node.one("qti-content-body", required=false) {
      Some(content) => {
        node.only_children(["qti-content-body"])
        content.only_attributes(["class", "id", "dir"])
        plain_static_text(content)
      }
      None => plain_static_text(node)
    }
    feedback.push({
      identifier: id,
      outcome,
      show,
      title: node.attr("title").unwrap_or(""),
      text: text.trim().to_owned(),
    })
  }
  let passage : Array[CompositePart] = []
  processing_passage(body, passage)
  {
    item_identifier: identifier(root.required("identifier"), root.location()),
    title: root.required("title"),
    program,
    bindings,
    passage,
    feedback,
    instructions: body.children
    .filter(n => n.name() == "qti-rubric-block")
    .map(candidate_instructions),
  }
}

///|
pub fn ProcessedItem::identifier(self : ProcessedItem) -> String {
  self.item_identifier
}

///|
pub fn ProcessedItem::describe(self : ProcessedItem) -> Json {
  let description = if self.bindings.length() == 1 {
    let result = self.bindings[0].validator.describe()
    if result is Object(fields) {
      fields["response_identifier"] = Json(self.bindings[0].identifier)
      if self.bindings[0].extended is Some(spec) {
        fields["extended_text"] = spec.describe()
      }
    }
    result
  } else {
    let responses = self.bindings.map(binding => {
      let description = binding.validator.describe()
      guard description is Object(fields) else {
        abort("description object expected")
      }
      let result : Json = {
        "identifier": binding.identifier,
        "base_type": fields["base_type"],
        "cardinality": fields["cardinality"],
        "prompt": fields["prompt"],
        "placeholder": "",
      }
      if result is Object(details) {
        if binding.extended is Some(spec) {
          details["extended_text"] = spec.describe()
        }
        for
          key in [
            "slider", "inline_choice", "matching", "gap_matching", "hottext", "graphic",
          ] {
          if fields.get(key) is Some(value) {
            details[key] = value
            if key == "inline_choice" && value is Object(inline_fields) {
              inline_fields["choices"] = fields["choices"]
            }
            if key == "slider" && value is Object(slider_fields) {
              slider_fields["prompt"] = fields["prompt"]
            }
          }
        }
        if fields["choices"] is Array(choices) &&
          !choices.is_empty() &&
          !fields.contains("slider") &&
          !fields.contains("inline_choice") &&
          !fields.contains("hottext") &&
          !fields.contains("graphic") &&
          !fields.contains("matching") &&
          !fields.contains("gap_matching") {
          details["choice"] = {
            "prompt": fields["prompt"],
            "choices": choices,
            "required": false,
            "orientation": "vertical",
            "min_choices": fields["min_choices"],
            "max_choices": fields["max_choices"],
          }
        }
      }
      result
    })
    {
      "kind": "composite",
      "identifier": self.item_identifier,
      "title": self.title,
      "prompt": self.title,
      "responses": responses,
      "passage": self.passage.map(p => {
        match p {
          Text(text) => { "text": text }
          Response(id) => { "response": id }
        }
      }),
    }
  }
  if description is Object(fields) {
    fields["identifier"] = Json(self.item_identifier)
    fields["title"] = Json(self.title)
    fields["template"] = Json("typed_rules")
    fields["declarations"] = self.program.describe()
    fields["has_feedback"] = Json(!self.feedback.is_empty())
    if self.program.declaration("SCORE") is Some(score) {
      fields["external_scoring"] = Json(score.external_scored is Some(_))
      if score.external_scored is Some(mode) {
        fields["external_scored"] = Json(mode)
      }
    }
    if !self.instructions.is_empty() {
      fields["instructions"] = Json(self.instructions.copy())
    }
  }
  description
}

///|
fn ProcessedItem::validated(
  self : ProcessedItem,
  input : String,
) -> Json raise QtiError {
  let parsed = processing_json(input)
  guard parsed is Object(fields) else {
    raise InvalidResponse("expected a response object")
  }
  for id, _ in fields {
    if !self.bindings.any(b => b.identifier == id) {
      raise InvalidResponse("unknown response identifier '\{id}'")
    }
  }
  for binding in self.bindings {
    let value = fields.get(binding.identifier).unwrap_or(Json::null())
    if binding.extended is Some(spec) &&
      spec.minimum == 1 &&
      (value == Json::null() || value == Json("")) {
      raise InvalidResponse(
        "extended text response '\{binding.identifier}' requires a nonempty string",
      )
    }
    let response : Json = { "RESPONSE": value }
    binding.validator.validate_json(response.stringify())
  }
  parsed
}

///|
pub fn ProcessedItem::validate_json(
  self : ProcessedItem,
  input : String,
) -> Unit raise QtiError {
  ignore(self.validated(input))
}

///|
fn ProcessedItem::result(
  self : ProcessedItem,
  input : Json,
  outcomes : Json,
) -> Score raise QtiError {
  if self.program.declaration("SCORE") is Some(declaration) &&
    declaration.external_scored is Some(_) {
    raise InvalidResponse(
      "SCORE requires external scoring; authored outcomes remain available through outcomes_json",
    )
  }
  guard input is Object(fields) && outcomes is Object(results) else {
    abort("validated response/outcome objects expected")
  }
  guard results.get("SCORE") is Some(Number(score, ..)) else {
    raise InvalidResponse(
      "SCORE is NULL after response processing; inspect outcomes_json for the authored result",
    )
  }
  let mut any_answer = false
  let mut all_correct = Some(true)
  for declaration in self.program.declarations {
    if !declaration.response {
      continue
    }
    let value = processing_value(
      fields.get(declaration.identifier).unwrap_or(Json::null()),
      declaration.kind,
    )
    if value != Json::null() {
      any_answer = true
    }
    if declaration.correct == Json::null() {
      all_correct = None
    } else if all_correct is Some(_) {
      let matches = match (value, declaration.correct) {
        (Array(a), Array(b)) if declaration.kind.cardinality == Multiple =>
          processing_bag_equal(a, b)
        _ => value != Json::null() && value == declaration.correct
      }
      if !matches {
        all_correct = Some(false)
      }
    }
  }
  {
    score,
    status: if any_answer {
      Answered
    } else {
      Unanswered
    },
    matches_correct: all_correct,
  }
}

///|
pub fn ProcessedItem::score_json(
  self : ProcessedItem,
  input : String,
) -> Score raise QtiError {
  let parsed = self.validated(input)
  self.result(parsed, self.program.evaluate_json(parsed))
}

///|
pub fn ProcessedItem::explain_json(
  self : ProcessedItem,
  input : String,
) -> Explanation raise QtiError {
  let parsed = self.validated(input)
  let steps : Array[ScoringStep] = []
  let outcomes = self.program.evaluate(parsed, Some(steps))
  { result: self.result(parsed, outcomes), steps, }
}

///|
pub fn ProcessedItem::outcomes_json(
  self : ProcessedItem,
  input : String,
) -> Json raise QtiError {
  self.program.evaluate_json(self.validated(input))
}

///|
pub fn ProcessedItem::feedback_json(
  self : ProcessedItem,
  input : String,
) -> Json raise QtiError {
  let outcomes = self.outcomes_json(input)
  guard outcomes is Object(fields) else { abort("outcomes object expected") }
  Json(
    self.feedback
    .filter(f => {
      let value = fields[f.outcome]
      let matching = value == Json(f.identifier) ||
        (value is Array(xs) && xs.contains(Json(f.identifier)))
      matching == f.show
    })
    .map(f => {
      "identifier": f.identifier,
      "outcome_identifier": f.outcome,
      "title": f.title,
      "text": f.text,
    }),
  )
}
