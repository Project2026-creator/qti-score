///|
priv struct TestCompiler {
  items : Map[String, AssessmentItem]
  item_errors : Map[String, QtiError]
  resource_ids : Map[String, String]
  section_sources : Map[String, Bytes]
  section_errors : Map[String, QtiError]
  ids : Map[String, Bool]
  entries : Array[TestEntry]
  section_stack : Array[String]
  limits : Limits
  mut expanded : Int32
}

///|
/// Compile a fixed-order QTI 3 test against precompiled items keyed by local
/// normalized href. External section references require ContentPackage.
pub fn compile_assessment_test(
  xml : String,
  items : Map[String, AssessmentItem],
  limits~ : Limits = Limits::default(),
) -> AssessmentTest raise QtiError {
  let resource_ids : Map[String, String] = Map([])
  for path, _ in items {
    if resolve_package_uri("", path) != path {
      raise InvalidItem("items", "item keys must be normalized local paths")
    }
    resource_ids[path] = path
  }
  compile_test_document(
    xml,
    "",
    items,
    Map([]),
    resource_ids,
    Map([]),
    Map([]),
    limits,
  )
}

///|
fn test_register_id(
  compiler : TestCompiler,
  node : Node,
  prefix : String,
) -> String raise QtiError {
  compiler.expanded += 1
  if compiler.expanded > compiler.limits.max_elements {
    raise LimitExceeded("expanded test exceeds max_elements")
  }
  let local_id = identifier(node.required("identifier"), node.location())
  let id = prefix + local_id
  if id.length() > 256 {
    raise LimitExceeded("expanded test identifier exceeds 256 code units")
  }
  if compiler.ids.contains(id) {
    raise InvalidItem(node.location(), "duplicate test identifier '\{id}'")
  }
  compiler.ids[id] = true
  id
}

///|
fn test_control(
  node : Node,
  inherited : ItemSessionControl,
) -> ItemSessionControl raise QtiError {
  match node.one("qti-item-session-control", required=false) {
    None => inherited
    Some(control) => {
      control.only_attributes([
        "max-attempts", "allow-review", "show-feedback", "allow-skipping", "validate-responses",
        "show-solution", "allow-comment",
      ])
      control.only_children([])
      if xml_bool(control, "show-solution", default=false) ||
        xml_bool(control, "allow-comment", default=false) {
        raise Unsupported(
          control.location(),
          "solutions and candidate comments",
        )
      }
      let max_attempts = match control.attr("max-attempts") {
        None => inherited.max_attempts
        Some(text) => {
          let trimmed = text.trim()
          if trimmed.is_empty() ||
            !trimmed.iter().all(c => '0' <= c && c <= '9') {
            raise InvalidItem(control.location(), "invalid max-attempts")
          }
          @string.parse_int(trimmed) catch {
            _ => raise InvalidItem(control.location(), "invalid max-attempts")
          }
        }
      }
      {
        max_attempts,
        allow_review: xml_bool(
          control,
          "allow-review",
          default=inherited.allow_review,
        ),
        show_feedback: xml_bool(
          control,
          "show-feedback",
          default=inherited.show_feedback,
        ),
        allow_skipping: xml_bool(
          control,
          "allow-skipping",
          default=inherited.allow_skipping,
        ),
        validate_responses: xml_bool(
          control,
          "validate-responses",
          default=inherited.validate_responses,
        ),
      }
    }
  }
}

///|
fn test_max_time(node : Node) -> Double? raise QtiError {
  match node.one("qti-time-limits", required=false) {
    None => None
    Some(time) => {
      time.only_attributes(["min-time", "max-time", "allow-late-submission"])
      time.only_children([])
      if optional_number(time, "min-time").unwrap_or(0.0) != 0.0 ||
        xml_bool(time, "allow-late-submission", default=false) {
        raise Unsupported(time.location(), "minimum time or late submission")
      }
      let max_time = optional_number(time, "max-time")
      if max_time is Some(value) && value < 0.0 {
        raise InvalidItem(time.location(), "max-time must be non-negative")
      }
      max_time
    }
  }
}

///|
fn test_walk_section(
  compiler : TestCompiler,
  section : Node,
  base : String,
  inherited : ItemSessionControl,
  part_id : String,
  prefix : String,
  depth : Int32,
  register~ : Bool = true,
) -> Unit raise QtiError {
  if depth > compiler.limits.max_depth {
    raise LimitExceeded("expanded test exceeds max_depth")
  }
  if register {
    ignore(test_register_id(compiler, section, prefix))
  } else {
    ignore(identifier(section.required("identifier"), section.location()))
  }
  section.only_attributes(
    ["identifier", "title", "visible", "keep-together", "required", "fixed"],
    allow_base=true,
  )
  section.only_children([
    "qti-item-session-control", "qti-assessment-section", "qti-assessment-section-ref",
    "qti-assessment-item-ref",
  ])
  ignore(section.required("title"))
  ignore(section.required("visible"))
  ignore(xml_bool(section, "visible", default=true))
  ignore(xml_bool(section, "keep-together", default=true))
  ignore(xml_bool(section, "required", default=false))
  ignore(xml_bool(section, "fixed", default=false))
  let base = section.package_base(base)
  let control = test_control(section, inherited)
  for child in section.children {
    match child.name() {
      "qti-assessment-section" =>
        test_walk_section(
          compiler,
          child,
          base,
          control,
          part_id,
          prefix,
          depth + 1,
        )
      "qti-assessment-section-ref" => {
        child.only_attributes(["identifier", "href"], allow_base=true)
        child.only_children([])
        let id = test_register_id(compiler, child, prefix)
        let path = resolve_package_uri(
          child.package_base(base),
          child.required("href"),
        )
        if compiler.section_stack.contains(path) {
          raise InvalidPackage(
            child.location(),
            "section reference cycle at '\{path}'",
          )
        }
        if compiler.section_errors.get(path) is Some(error) {
          raise error
        }
        guard compiler.section_sources.get(path) is Some(bytes) else {
          raise InvalidPackage(
            child.location(),
            "no QTI 3 section resource for '\{path}'",
          )
        }
        let source = @utf8.decode(bytes[:], ignore_bom=true) catch {
          _ => raise InvalidPackage(path, "section XML must be UTF-8")
        }
        let root = parse_document(source, compiler.limits)
        if root.name() != "qti-assessment-section" ||
          root.element.name.namespace_uri != Some(qti_namespace) {
          raise InvalidPackage(path, "expected a QTI 3 section document")
        }
        compiler.section_stack.push(path)
        test_walk_section(
          compiler,
          root,
          path,
          control,
          part_id,
          id + ".",
          depth + 1,
          register=false,
        )
        ignore(compiler.section_stack.pop())
      }
      "qti-assessment-item-ref" => {
        child.only_attributes(
          ["identifier", "href", "required", "fixed"],
          allow_base=true,
        )
        child.only_children(["qti-item-session-control"])
        ignore(xml_bool(child, "required", default=false))
        ignore(xml_bool(child, "fixed", default=false))
        let id = test_register_id(compiler, child, prefix)
        let path = resolve_package_uri(
          child.package_base(base),
          child.required("href"),
        )
        if compiler.item_errors.get(path) is Some(error) {
          raise error
        }
        guard compiler.items.get(path) is Some(item) &&
          compiler.resource_ids.get(path) is Some(resource_id) else {
          raise InvalidPackage(
            child.location(),
            "no compiled QTI 3 item resource for '\{path}'",
          )
        }
        if compiler.entries.length() >= 512 {
          raise LimitExceeded("test exceeds 512 item references")
        }
        compiler.entries.push({
          identifier: id,
          part_identifier: part_id,
          resource_id,
          path,
          control: test_control(child, control),
          item,
        })
      }
      _ => ()
    }
  }
}

///|
fn compile_test_document(
  xml : String,
  base : String,
  items : Map[String, AssessmentItem],
  item_errors : Map[String, QtiError],
  resource_ids : Map[String, String],
  section_sources : Map[String, Bytes],
  section_errors : Map[String, QtiError],
  limits : Limits,
) -> AssessmentTest raise QtiError {
  let root = parse_document(xml, limits)
  if root.name() != "qti-assessment-test" ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(root.location(), "expected a QTI 3 qti-assessment-test")
  }
  root.only_attributes(["identifier", "title"], allow_base=true)
  root.only_children([
    "qti-outcome-declaration", "qti-test-part", "qti-outcome-processing",
  ])
  let id = identifier(root.required("identifier"), root.location())
  let title = root.required("title")
  let base = root.package_base(base)
  let test_parts = root.children.filter(child => child.name() == "qti-test-part")
  if test_parts.is_empty() {
    raise InvalidItem(root.location(), "test requires at least one test part")
  }
  let compiler : TestCompiler = {
    items,
    item_errors,
    resource_ids,
    section_sources,
    section_errors,
    ids: Map([]),
    entries: [],
    section_stack: [],
    limits,
    expanded: 0,
  }
  compiler.ids[id] = true
  let parts : Array[TestPart] = []
  for part in test_parts {
    part.only_attributes(
      ["identifier", "navigation-mode", "submission-mode"],
      allow_base=true,
    )
    part.only_children([
      "qti-item-session-control", "qti-time-limits", "qti-assessment-section", "qti-assessment-section-ref",
    ])
    let part_id = test_register_id(compiler, part, "")
    let navigation_mode = match part.required("navigation-mode") {
      "linear" => NavigationMode::Linear
      "nonlinear" => NavigationMode::Nonlinear
      _ => raise InvalidItem(part.location(), "invalid navigation-mode")
    }
    let submission_mode = match part.required("submission-mode") {
      "individual" => SubmissionMode::Individual
      "simultaneous" => SubmissionMode::Simultaneous
      _ => raise InvalidItem(part.location(), "invalid submission-mode")
    }
    let control = test_control(part, ItemSessionControl::default())
    let max_time = test_max_time(part)
    let start = compiler.entries.length()
    // A synthetic section shares the part children so both levels resolve
    // section references through exactly the same checked traversal.
    for section in part.children {
      if section.name() == "qti-assessment-section" {
        test_walk_section(
          compiler,
          section,
          part.package_base(base),
          control,
          part_id,
          "",
          1,
        )
      } else if section.name() == "qti-assessment-section-ref" {
        // Top-level section references are processed by a synthetic section
        // whose attributes satisfy the same structural requirements.
        let wrapper = parse_document(
          "<qti-assessment-section xmlns=\"\{qti_namespace}\" identifier=\"_root\" title=\"Root\" visible=\"true\"/>",
          limits,
        )
        wrapper.children.push(section)
        test_walk_section(
          compiler,
          wrapper,
          part.package_base(base),
          control,
          part_id,
          "",
          0,
          register=false,
        )
      }
    }
    let count = compiler.entries.length() - start
    if count == 0 {
      raise InvalidItem(
        part.location(),
        "test part must resolve at least one item",
      )
    }
    parts.push({
      identifier: part_id,
      navigation_mode,
      submission_mode,
      max_time,
      control,
      start,
      count,
    })
  }
  let processing = if root.one("qti-outcome-processing", required=false)
    is Some(_) {
    Some(processing_program_root(root))
  } else {
    let declarations = processing_declarations(root)
    if declarations.is_empty() {
      None
    } else {
      Some(ProcessingProgram::{ declarations, rules: [], test_mode: true, })
    }
  }
  let identity = test_identity(xml, compiler.entries)
  {
    identifier: id,
    title,
    parts,
    entries: compiler.entries,
    identity,
    processing,
  }
}

///|
fn test_identity(xml : String, entries : Array[TestEntry]) -> String {
  // FNV-1a over UTF-8 with unsigned wrapping arithmetic is backend independent.
  // The full compiled item includes rules; learner metadata alone cannot bind
  // a saved session to the scoring semantics used to create it.
  let mut hash : UInt64 = 14695981039346656037UL
  for byte in @utf8.encode(xml) {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  for entry in entries {
    for
      byte in @utf8.encode(
        "\{entry.identifier}\n\{entry.path}\n\{Repr(entry.control)}\n\{Repr(entry.item)}",
      ) {
      hash = (hash ^ byte.to_uint64()) * 1099511628211UL
    }
  }
  "qti-test-v1-\{hash}"
}
