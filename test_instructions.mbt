///|
// TestRubricBlock has an optional use attribute and a list of actor views.
// Candidate text uses the bounded static-content parser shared with items.
fn test_candidate_instruction(node : Node) -> String? raise QtiError {
  if node.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(node.location(), "rubric block namespace")
  }
  node.only_attributes(["view", "use", "class", "id", "dir"], allow_base=true)
  let views = node
    .required("view")
    .replace_all(old="\t", new=" ")
    .replace_all(old="\n", new=" ")
    .replace_all(old="\r", new=" ")
    .split(" ")
    .filter(view => !view.is_empty())
    .map(view => view.to_owned())
    .collect()
  if views.is_empty() ||
    !views.all(view => {
      ["author", "candidate", "proctor", "scorer", "testConstructor", "tutor"].contains(
        view,
      )
    }) {
    raise InvalidItem(node.location(), "invalid rubric view")
  }
  if node.attr("use") is Some(purpose) &&
    !["instructions", "navigation", "scoring"].contains(
      purpose.trim().to_owned(),
    ) {
    raise Unsupported(node.location(), "test rubric use '\{purpose}'")
  }
  if !views.contains("candidate") {
    return None
  }
  node.only_children(["qti-content-body"])
  let content = node.one("qti-content-body").unwrap()
  content.only_attributes(["class", "id", "dir"], allow_base=true)
  Some(plain_static_text(content).trim().to_owned())
}

///|
// Keep one block per active scope, in the authored rubric order.
fn test_scope_instructions(
  node : Node,
  scope_identifier : String,
  title : String,
  scope~ : String,
) -> Array[Json] raise QtiError {
  let texts : Array[String] = []
  for child in node.children {
    if child.name() == "qti-rubric-block" {
      if test_candidate_instruction(child) is Some(text) && !text.is_empty() {
        texts.push(text)
      }
    }
  }
  if texts.is_empty() {
    return []
  }
  [
    {
      "scope": scope,
      "scope_identifier": scope_identifier,
      "title": title,
      "text": texts.join("\n\n"),
    },
  ]
}
