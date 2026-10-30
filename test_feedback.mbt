///|
priv struct TestFeedback {
  identifier : String
  outcome_identifier : String
  scope : String
  scope_identifier : String
  access : String
  show : Bool
  title : String
  content : Array[ContentPart]
} derive(Debug)

///|
fn test_feedback_scope(
  node : Node,
  scope : String,
  scope_identifier : String,
  program : ProcessingProgram?,
  feedback : Array[TestFeedback],
) -> Unit raise QtiError {
  for child in node.children {
    if child.name() != "qti-test-feedback" {
      continue
    }
    if child.element.name.namespace_uri != Some(qti_namespace) {
      raise Unsupported(child.location(), "test feedback namespace")
    }
    child.only_attributes(
      [
        "identifier", "outcome-identifier", "show-hide", "access", "title", "class",
        "id", "dir",
      ],
      allow_base=true,
    )
    child.only_children(["qti-content-body"])
    if !processing_nodes(child, "qti-feedback-inline").is_empty() ||
      !processing_nodes(child, "qti-feedback-block").is_empty() {
      raise InvalidItem(
        child.location(),
        "item feedback cannot be nested inside test feedback",
      )
    }
    if child.content.to_string().trim() != "" {
      raise InvalidItem(
        child.location(),
        "test feedback text requires qti-content-body",
      )
    }
    let id = identifier(child.required("identifier"), child.location())
    let outcome_identifier = identifier(
      child.required("outcome-identifier"),
      child.location(),
    )
    guard program is Some(program) &&
      program.declaration(outcome_identifier) is Some(declaration) &&
      !declaration.response &&
      declaration.kind.base == "identifier" &&
      declaration.kind.cardinality != Ordered else {
      raise InvalidItem(
        child.location(),
        "test feedback requires a single/multiple identifier test outcome",
      )
    }
    let show = match child.required("show-hide") {
      "show" => true
      "hide" => false
      _ => raise InvalidItem(child.location(), "show-hide must be show or hide")
    }
    let access = child.required("access")
    if access != "during" && access != "atEnd" {
      raise InvalidItem(
        child.location(),
        "feedback access must be during or atEnd",
      )
    }
    let content = match child.one("qti-content-body", required=false) {
      Some(content) => {
        content.only_attributes(["class", "id", "dir"], allow_base=true)
        content_parts(content, program)
      }
      None => []
    }
    if child.all_text.to_string().length() > 65536 {
      raise LimitExceeded("test feedback text exceeds 65536 UTF-16 units")
    }
    if feedback.length() >= 256 {
      raise LimitExceeded("test exceeds 256 feedback blocks")
    }
    feedback.push({
      identifier: id,
      outcome_identifier,
      scope,
      scope_identifier,
      access,
      show,
      title: child.attr("title").unwrap_or(""),
      content,
    })
  }
}

///|
fn compile_test_feedback(
  root : Node,
  program : ProcessingProgram?,
) -> Array[TestFeedback] raise QtiError {
  let feedback : Array[TestFeedback] = []
  test_feedback_scope(
    root,
    "test",
    root.required("identifier"),
    program,
    feedback,
  )
  for part in root.children {
    if part.name() == "qti-test-part" {
      test_feedback_scope(
        part,
        "part",
        part.required("identifier"),
        program,
        feedback,
      )
    }
  }
  feedback
}

///|
fn test_visible_feedback(
  feedback : Array[TestFeedback],
  scope : String,
  scope_identifier : String,
  access : String,
  outcomes : Json,
) -> Array[Json] {
  let result : Array[Json] = []
  for block in feedback {
    if block.scope != scope ||
      block.scope_identifier != scope_identifier ||
      block.access != access {
      continue
    }
    let value = match outcomes {
      Object(fields) =>
        fields.get(block.outcome_identifier).unwrap_or(Json::null())
      _ => Json::null()
    }
    let matching = value == Json(block.identifier) ||
      (value is Array(values) && values.contains(Json(block.identifier)))
    if matching == block.show {
      result.push({
        "identifier": block.identifier,
        "outcome_identifier": block.outcome_identifier,
        "scope": scope,
        "scope_identifier": scope_identifier,
        "access": access,
        "title": block.title,
        "text": content_render(block.content, outcomes).trim().to_owned(),
      })
    }
  }
  result
}
