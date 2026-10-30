///|
priv struct TestFlowSource {
  node : Node
  identifier : String
  kind : String
  part_identifier : String
  prefix : String
  parent_section : String?
}

///|
priv struct TestFlowBranch {
  target : String
  predicate : TestFlowPredicate
} derive(Debug)

///|
priv struct TestFlowScope {
  identifier : String
  kind : String
  part_identifier : String
  start : Int32
  end : Int32
  parent_section : String?
  preconditions : Array[TestFlowPredicate]
  branches : Array[TestFlowBranch]
} derive(Debug)

///|
// A branch target after selection or shuffling has no defined portable meaning.
// This profile accepts item/section flow only over a fixed assembled sequence.
fn test_flow_fixed(nodes : Array[TestAssemblyNode]) -> Unit raise QtiError {
  for node in nodes {
    match node.kind {
      Leaf(_) => ()
      Section(children~, selection~, shuffle~, ..) => {
        if selection is Some(_) || shuffle {
          raise Unsupported(
            node.identifier,
            "conditional item/section navigation with selection or shuffling",
          )
        }
        test_flow_fixed(children)
      }
    }
  }
}

///|
fn test_flow_resolve_target(
  target : String,
  source : TestFlowSource,
  scope : TestFlowScope,
  scopes : Array[TestFlowScope],
  sources : Array[TestFlowSource],
) -> String raise QtiError {
  let location = source.node.location()
  if target == "EXIT_TEST" || target == "EXIT_TESTPART" {
    return target
  }
  if target == "EXIT_SECTION" {
    if scope.kind == "part" {
      raise InvalidItem(location, "EXIT_SECTION cannot be used by a test part")
    }
    if scope.kind == "section" {
      raise Unsupported(location, "EXIT_SECTION on a section branch")
    }
    guard scope.parent_section is Some(parent) &&
      scopes.any(s => {
        s.identifier == parent &&
        s.kind == "section" &&
        s.part_identifier == scope.part_identifier &&
        s.start <= scope.start &&
        s.end >= scope.end
      }) else {
      raise InvalidItem(location, "EXIT_SECTION requires an enclosing section")
    }
    return target
  }
  let prefixed = source.prefix + target
  let resolved = if source.prefix != "" &&
    scopes.any(s => s.identifier == prefixed) {
    prefixed
  } else {
    target
  }
  guard scopes.filter(s => s.identifier == resolved).get(0) is Some(destination) else {
    raise InvalidItem(
      location,
      "branch target '\{target}' is missing from the compiled test",
    )
  }
  if scope.kind == "part" {
    if destination.kind != "part" || destination.start < scope.end {
      raise InvalidItem(
        location, "test-part branches must target a later test part",
      )
    }
  } else {
    if destination.kind == "part" ||
      destination.part_identifier != scope.part_identifier ||
      destination.start < scope.end {
      raise InvalidItem(
        location, "item/section branches must target an unpresented item or section in the same part",
      )
    }
    if sources.filter(s => s.identifier == resolved).get(0)
      is Some(target_source) &&
      target_source.prefix != "" &&
      target_source.identifier + "." != target_source.prefix {
      raise Unsupported(
        location, "branch targets inside an external section reference",
      )
    }
  }
  resolved
}

///|
fn test_compile_flow(
  sources : Array[TestFlowSource],
  root : Node,
  entries : Array[TestEntry],
  parts : Array[TestPart],
  item_declarations : Json,
) -> Array[TestFlowScope] raise QtiError {
  if sources.length() > 8192 {
    raise LimitExceeded("test flow source exceeds 8192 scopes")
  }
  let scopes : Array[TestFlowScope] = []
  let context = test_flow_context(root, item_declarations)
  let identifiers : Map[String, Bool] = Map([])
  let mut condition_count = 0
  for source in sources {
    if !["part", "section", "item"].contains(source.kind) {
      raise InvalidItem(source.node.location(), "unknown test flow scope kind")
    }
    if identifiers.contains(source.identifier) {
      raise InvalidItem(
        source.node.location(),
        "duplicate test flow scope identifier",
      )
    }
    identifiers[source.identifier] = true
    guard parts.filter(p => p.identifier == source.part_identifier).get(0)
      is Some(part) else {
      raise InvalidItem(
        source.node.location(),
        "test flow scope refers to an unknown part",
      )
    }
    let active = source.kind == "part" || part.navigation_mode == Linear
    let preconditions : Array[TestFlowPredicate] = []
    let branches : Array[TestFlowBranch] = []
    for child in source.node.children {
      if !["qti-pre-condition", "qti-branch-rule"].contains(child.name()) {
        continue
      }
      condition_count += 1
      if condition_count > 1024 {
        raise LimitExceeded(
          "test flow exceeds 1024 conditions and branch rules",
        )
      }
      let predicate = test_flow_predicate(child, root, compiled=Some(context))
      if child.name() == "qti-pre-condition" {
        preconditions.push(predicate)
      } else {
        branches.push({ target: child.required("target"), predicate, })
      }
    }
    let has_conditions = !preconditions.is_empty() || !branches.is_empty()
    if active && has_conditions && source.prefix != "" {
      raise Unsupported(
        source.node.location(),
        "conditional navigation inside an external section reference",
      )
    }
    if active &&
      has_conditions &&
      source.kind != "part" &&
      part.submission_mode == Simultaneous {
      raise Unsupported(
        source.node.location(),
        "item/section conditions in a simultaneous-submission part",
      )
    }
    let indices : Array[Int32] = []
    if source.kind == "part" {
      if source.identifier != part.identifier ||
        part.start < 0 ||
        part.count < 0 ||
        part.start + part.count > entries.length() {
        raise InvalidItem(
          source.node.location(),
          "invalid test-part flow range",
        )
      }
      for index in part.start..<(part.start + part.count) {
        indices.push(index)
      }
    } else {
      for index, entry in entries {
        let matches = if source.kind == "section" {
          entry.section_identifiers.contains(source.identifier)
        } else {
          entry.source_identifier == source.identifier
        }
        if matches {
          if entry.part_identifier != source.part_identifier {
            raise InvalidItem(
              source.node.location(),
              "flow scope crosses test-part boundaries",
            )
          }
          indices.push(index)
        }
      }
    }
    if indices.is_empty() {
      if has_conditions {
        raise Unsupported(
          source.node.location(),
          "conditions on an empty or unselected flow scope",
        )
      }
      continue
    }
    let start = indices[0]
    let end = indices[indices.length() - 1] + 1
    if active && has_conditions && end - start != indices.length() {
      raise Unsupported(
        source.node.location(),
        "conditions on a fragmented flow scope",
      )
    }
    scopes.push({
      identifier: source.identifier,
      kind: source.kind,
      part_identifier: source.part_identifier,
      start,
      end,
      parent_section: source.parent_section,
      preconditions: if active {
        preconditions
      } else {
        []
      },
      branches: if active {
        branches
      } else {
        []
      },
    })
  }
  for scope in scopes {
    guard sources.filter(s => s.identifier == scope.identifier).get(0)
      is Some(source) else {
      abort("compiled flow scope has no source")
    }
    for index, branch in scope.branches {
      scope.branches[index] = {
        target: test_flow_resolve_target(
          branch.target,
          source,
          scope,
          scopes,
          sources,
        ),
        predicate: branch.predicate,
      }
    }
  }
  scopes
}
