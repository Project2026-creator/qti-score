///|
priv struct TestAssemblySelection {
  select : Int32
  with_replacement : Bool
}

///|
priv enum TestAssemblyKind {
  Leaf(Int32)
  Section(
    children~ : Array[TestAssemblyNode],
    selection~ : TestAssemblySelection?,
    shuffle~ : Bool,
    visible~ : Bool,
    keep_together~ : Bool
  )
}

///|
priv struct TestAssemblyNode {
  identifier : String
  required : Bool
  fixed : Bool
  kind : TestAssemblyKind
}

///|
priv struct TestAssemblyBlock {
  fixed : Bool
  indices : Array[Int32]
  // A fixed invisible, ungrouped section has no single parent shuffle slot.
  // Reject that combination if its contents reach a shuffled ancestor.
  transparent_fixed : String?
}

///|
priv struct TestAssemblyState {
  mut random_state : Int64
  mut expanded : Int32
  mut leaves : Int32
}

///|
// A fixed 31-bit LCG with checked Int64 intermediates gives the same stream on
// every backend. This is reproducible assembly, not a source of secret entropy.
fn TestAssemblyState::draw(self : TestAssemblyState, bound : Int32) -> Int32 {
  let range = 2147483648L
  let width = bound.to_int64()
  let ceiling = range - range % width
  for ;; {
    self.random_state = (self.random_state * 1103515245L + 12345L) % range
    if self.random_state < ceiling {
      return (self.random_state % width).to_int()
    }
  }
}

///|
fn test_assembly_validate(
  nodes : Array[TestAssemblyNode],
  identifiers : Map[String, Bool],
  depth : Int32,
  count : Array[Int32],
) -> Unit raise QtiError {
  if depth > 64 {
    raise LimitExceeded("test assembly nesting exceeds 64")
  }
  for node in nodes {
    count[0] += 1
    if count[0] > 8192 {
      raise LimitExceeded("test assembly source exceeds 8192 nodes")
    }
    ignore(identifier(node.identifier, "test assembly"))
    if identifiers.contains(node.identifier) {
      raise InvalidItem(node.identifier, "duplicate assembly source identifier")
    }
    identifiers[node.identifier] = true
    match node.kind {
      Leaf(index) =>
        if index < 0 {
          raise InvalidItem(node.identifier, "negative assembly source index")
        }
      Section(children~, selection~, ..) => {
        if selection is Some(rule) {
          if rule.select < 0 {
            raise InvalidItem(
              node.identifier,
              "selection count must be nonnegative",
            )
          }
          if rule.select > 512 {
            raise LimitExceeded("section selection exceeds 512 instances")
          }
          let required = children.filter(child => child.required).length()
          if rule.select < required {
            raise InvalidItem(
              node.identifier,
              "selection omits required children",
            )
          }
          if rule.select > children.length() && !rule.with_replacement {
            raise InvalidItem(
              node.identifier,
              "selection exceeds available children",
            )
          }
          if rule.select > 0 && children.is_empty() {
            raise InvalidItem(
              node.identifier,
              "cannot select from an empty section",
            )
          }
        }
        test_assembly_validate(children, identifiers, depth + 1, count)
      }
    }
  }
}

///|
fn test_assembly_counts(
  children : Array[TestAssemblyNode],
  selection : TestAssemblySelection?,
  state : TestAssemblyState,
) -> Array[Int32] {
  guard selection is Some(rule) else {
    return Array::make(children.length(), 1)
  }
  let counts = Array::make(children.length(), 0)
  let optional : Array[Int32] = []
  let mut remaining = rule.select
  for index, child in children {
    if child.required {
      counts[index] = 1
      remaining -= 1
    } else {
      optional.push(index)
    }
  }
  // BPIG 4.5.1 recommends exhausting distinct children before creating clones.
  // Partial Fisher-Yates makes all remaining non-required children equiprobable.
  let distinct = Int32::min(remaining, optional.length())
  for i in 0..<distinct {
    let picked = i + state.draw(optional.length() - i)
    let previous = optional[i]
    optional[i] = optional[picked]
    optional[picked] = previous
    counts[optional[i]] = 1
  }
  remaining -= distinct
  // Only a with-replacement rule can leave a positive remainder here. Every
  // source child, including required children, is equally eligible per draw.
  for _ in 0..<remaining {
    counts[state.draw(children.length())] += 1
  }
  counts
}

///|
fn test_assembly_shuffle(
  blocks : Array[TestAssemblyBlock],
  state : TestAssemblyState,
) -> Unit raise QtiError {
  let movable : Array[Int32] = []
  for index, block in blocks {
    if block.transparent_fixed is Some(id) {
      raise Unsupported(
        id, "fixed invisible ungrouped section inside a shuffled section",
      )
    }
    if !block.fixed {
      movable.push(index)
    }
  }
  // Fixed positions refer to the selected sequence, not gaps in source XML.
  for i = movable.length() - 1; i > 0; i = i - 1 {
    let other = state.draw(i + 1)
    let previous = blocks[movable[i]]
    blocks[movable[i]] = blocks[movable[other]]
    blocks[movable[other]] = previous
  }
}

///|
fn test_assembly_flatten(blocks : Array[TestAssemblyBlock]) -> Array[Int32] {
  let result : Array[Int32] = []
  for block in blocks {
    for index in block.indices {
      result.push(index)
    }
  }
  result
}

///|
fn test_assembly_node(
  node : TestAssemblyNode,
  state : TestAssemblyState,
) -> Array[TestAssemblyBlock] raise QtiError {
  state.expanded += 1
  if state.expanded > 32768 {
    raise LimitExceeded("test assembly exceeds 32768 expanded nodes")
  }
  match node.kind {
    Leaf(index) => {
      state.leaves += 1
      if state.leaves > 512 {
        raise LimitExceeded("test assembly exceeds 512 item instances")
      }
      [{ fixed: node.fixed, indices: [index], transparent_fixed: None, }]
    }
    Section(children~, selection~, shuffle~, visible~, keep_together~) => {
      let counts = test_assembly_counts(children, selection, state)
      let blocks : Array[TestAssemblyBlock] = []
      // Restore source order after sampling. A subsection counts as one draw;
      // each selected clone independently executes its own assembly rules.
      for index, child in children {
        for _ in 0..<counts[index] {
          for block in test_assembly_node(child, state) {
            blocks.push(block)
          }
        }
      }
      if shuffle {
        test_assembly_shuffle(blocks, state)
      }
      if visible || keep_together {
        [
          {
            fixed: node.fixed,
            indices: test_assembly_flatten(blocks),
            transparent_fixed: None,
          },
        ]
      } else if node.fixed {
        blocks.map(block => {
          ..block,
          transparent_fixed: Some(node.identifier),
        })
      } else {
        blocks
      }
    }
  }
}

///|
// Assemble one part's top-level sections in document order. Source indices
// deliberately repeat for cloned ItemRefs; the caller assigns runtime instance
// identities and retains the source ItemRef for QTI result reports.
fn assemble_test_nodes(
  nodes : Array[TestAssemblyNode],
  seed : Int32,
) -> Array[Int32] raise QtiError {
  if seed < 0 {
    raise InvalidResponse("test assembly seed must be in 0..2147483647")
  }
  test_assembly_validate(nodes, Map([]), 0, [0])
  let state : TestAssemblyState = {
    random_state: seed.to_int64(),
    expanded: 0,
    leaves: 0,
  }
  let blocks : Array[TestAssemblyBlock] = []
  for node in nodes {
    for block in test_assembly_node(node, state) {
      blocks.push(block)
    }
  }
  test_assembly_flatten(blocks)
}
