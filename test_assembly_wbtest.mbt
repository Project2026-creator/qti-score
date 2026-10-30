///|
fn assembly_leaf(
  index : Int32,
  required~ : Bool = false,
  fixed~ : Bool = false,
) -> TestAssemblyNode {
  { identifier: "I\{index}", required, fixed, kind: Leaf(index), }
}

///|
fn assembly_section(
  name : String,
  children : Array[TestAssemblyNode],
  select? : Int32,
  replacement~ : Bool = false,
  shuffle~ : Bool = false,
  visible~ : Bool = true,
  keep~ : Bool = true,
  required~ : Bool = false,
  fixed~ : Bool = false,
) -> TestAssemblyNode {
  {
    identifier: name,
    required,
    fixed,
    kind: Section(
      children~,
      selection=select.map(count => {
        select: count,
        with_replacement: replacement,
      }),
      shuffle~,
      visible~,
      keep_together=keep,
    ),
  }
}

///|
fn assembly_reject(nodes : Array[TestAssemblyNode]) -> Unit raise {
  try assemble_test_nodes(nodes, 0) catch {
    InvalidItem(_, _)
    | InvalidResponse(_)
    | LimitExceeded(_)
    | Unsupported(_, _) => ()
    _ => fail("unexpected assembly error")
  } noraise {
    _ => fail("invalid assembly accepted")
  }
}

///|
test "assembly uses a deterministic seeded permutation and never mutates its source" {
  let children = Array::makei(6, i => assembly_leaf(i))
  let nodes = [assembly_section("root", children, shuffle=true)]
  // Independent integer reference vectors for LCG31 + rejection + Fisher-Yates.
  assert_eq(assemble_test_nodes(nodes, 0), [0, 2, 4, 5, 1, 3])
  assert_eq(assemble_test_nodes(nodes, 1), [2, 3, 1, 4, 5, 0])
  assert_eq(assemble_test_nodes(nodes, 42), [0, 2, 5, 1, 4, 3])
  assert_eq(assemble_test_nodes(nodes, 2147483647), [3, 0, 1, 5, 4, 2])
  assert_eq(assemble_test_nodes(nodes, 0), [0, 2, 4, 5, 1, 3])
  assert_eq(assemble_test_nodes([assembly_section("plain", children)], 0), [
    0, 1, 2, 3, 4, 5,
  ])
  try assemble_test_nodes(nodes, -1) catch {
    InvalidResponse(_) => ()
    _ => fail("negative seed returned wrong error")
  } noraise {
    _ => fail("negative seed accepted")
  }
}

///|
test "assembly selection preserves source order and required entries count toward select" {
  let children = Array::makei(6, i => {
    assembly_leaf(i, required=i == 1 || i == 4)
  })
  let nodes = [assembly_section("root", children, select=4)]
  for seed in 0..<64 {
    let result = assemble_test_nodes(nodes, seed)
    assert_eq(result.length(), 4)
    assert_true(result.contains(1))
    assert_true(result.contains(4))
    for i in 1..<result.length() {
      assert_true(result[i - 1] < result[i])
    }
  }
  assembly_reject([assembly_section("few", children, select=1)])
  assembly_reject([assembly_section("many", children, select=7)])
  assembly_reject([assembly_section("negative", children, select=-1)])
  assert_eq(assemble_test_nodes([assembly_section("zero", [], select=0)], 0), [])
  assembly_reject([assembly_section("empty", [], select=1, replacement=true)])
}

///|
test "assembly with replacement exhausts distinct children before equally eligible clones" {
  let children = [
    assembly_leaf(0),
    assembly_leaf(1, required=true),
    assembly_leaf(2),
  ]
  let nodes = [assembly_section("root", children, select=5, replacement=true)]
  // Required 1, then distinct optional 0/2, then clone 2 and required 1.
  assert_eq(assemble_test_nodes(nodes, 0), [0, 1, 1, 2, 2])
  for seed in 0..<64 {
    let result = assemble_test_nodes(nodes, seed)
    assert_eq(result.length(), 5)
    for source in 0..<3 {
      assert_true(result.contains(source))
    }
    for i in 1..<result.length() {
      assert_true(result[i - 1] <= result[i])
    }
    let fewer = assemble_test_nodes(
      [assembly_section("small", children, select=2, replacement=true)],
      seed,
    )
    assert_eq(fewer.length(), 2)
    assert_true(fewer.contains(1))
    assert_true(fewer[0] != fewer[1])
  }
}

///|
test "assembly selects subsections as units and each clone assembles independently" {
  let bank = assembly_section(
    "bank",
    [assembly_leaf(0), assembly_leaf(1), assembly_leaf(2)],
    select=1,
  )
  let nodes = [assembly_section("root", [bank], select=6, replacement=true)]
  let result = assemble_test_nodes(nodes, 42)
  assert_eq(result, [2, 0, 2, 2, 2, 0])
  let unit = assembly_section(
    "unit",
    [assembly_leaf(3), assembly_leaf(4)],
    required=true,
  )
  let selected = assemble_test_nodes(
    [assembly_section("selected", [assembly_leaf(5), unit], select=1)],
    0,
  )
  assert_eq(selected, [3, 4])
}

///|
test "assembly fixed positions are assigned after selection and do not force inclusion" {
  let children = [
    assembly_leaf(0),
    assembly_leaf(1, required=true, fixed=true),
    assembly_leaf(2),
    assembly_leaf(3),
    assembly_leaf(4),
  ]
  for seed in 0..<64 {
    let selected = assemble_test_nodes(
      [assembly_section("before", children, select=3)],
      seed,
    )
    let ordered = assemble_test_nodes(
      [assembly_section("after", children, select=3, shuffle=true)],
      seed,
    )
    for i, source in selected {
      if source == 1 {
        assert_eq(ordered[i], 1)
      }
    }
  }
  let fixed_optional = [
    assembly_leaf(0, required=true),
    assembly_leaf(1, fixed=true),
  ]
  assert_eq(
    assemble_test_nodes(
      [assembly_section("optional", fixed_optional, select=1)],
      0,
    ),
    [0],
  )
}

///|
test "assembly visible or keep together sections remain blocks while transparent children interleave" {
  for visible in [false, true] {
    for keep in [false, true] {
      let group = assembly_section(
        "group",
        [assembly_leaf(1), assembly_leaf(2)],
        visible~,
        keep~,
      )
      let nodes = [
        assembly_section(
          "root",
          [assembly_leaf(0), group, assembly_leaf(3)],
          shuffle=true,
        ),
      ]
      let mut interleaved = false
      for seed in 0..<64 {
        let result = assemble_test_nodes(nodes, seed)
        let mut first = -1
        let mut second = -1
        for i, source in result {
          if source == 1 {
            first = i
          }
          if source == 2 {
            second = i
          }
        }
        if visible || keep {
          assert_eq(second, first + 1)
        } else if second != first + 1 {
          interleaved = true
        }
      }
      if !visible && !keep {
        assert_true(interleaved)
      }
    }
  }
}

///|
test "assembly child ordering precedes parent ordering and kept fixed blocks may shuffle internally" {
  let group = assembly_section(
    "group",
    [assembly_leaf(1), assembly_leaf(2), assembly_leaf(3)],
    shuffle=true,
    fixed=true,
  )
  let nodes = [
    assembly_section(
      "root",
      [assembly_leaf(0), group, assembly_leaf(4)],
      shuffle=true,
    ),
  ]
  let mut changed = false
  for seed in 0..<64 {
    let result = assemble_test_nodes(nodes, seed)
    assert_eq(result.length(), 5)
    assert_true(result[1] >= 1 && result[1] <= 3)
    assert_true(result[2] >= 1 && result[2] <= 3)
    assert_true(result[3] >= 1 && result[3] <= 3)
    if result[1] != 1 || result[2] != 2 || result[3] != 3 {
      changed = true
    }
  }
  assert_true(changed)
}

///|
test "assembly transparent sections promote child fixed flags and reject unresolved fixed section shuffles" {
  let group = assembly_section(
    "group",
    [assembly_leaf(1, fixed=true), assembly_leaf(2)],
    visible=false,
    keep=false,
  )
  let nodes = [
    assembly_section(
      "root",
      [assembly_leaf(0), group, assembly_leaf(3)],
      shuffle=true,
    ),
  ]
  for seed in 0..<32 {
    assert_eq(assemble_test_nodes(nodes, seed)[1], 1)
  }
  let fixed_group = assembly_section(
    "fixed_group",
    [assembly_leaf(1), assembly_leaf(2)],
    visible=false,
    keep=false,
    fixed=true,
  )
  assert_eq(assemble_test_nodes([fixed_group], 0), [1, 2])
  assembly_reject([assembly_section("shuffled", [fixed_group], shuffle=true)])
  let promoted = assembly_section(
    "promoted",
    [fixed_group],
    visible=false,
    keep=false,
  )
  assembly_reject([assembly_section("ancestor", [promoted], shuffle=true)])
}

///|
test "assembly validates unselected source rules and source identity" {
  let invalid = assembly_section("invalid", [], select=1)
  assembly_reject([assembly_section("root", [invalid], select=0)])
  assembly_reject([assembly_leaf(0), assembly_leaf(0)])
  assembly_reject([assembly_leaf(-1)])
}

///|
test "assembly bounds output instances and explosive empty section expansion" {
  let leaves = Array::makei(512, i => assembly_leaf(i))
  assert_eq(assemble_test_nodes(leaves, 0).length(), 512)
  assembly_reject(Array::makei(513, i => assembly_leaf(i)))
  assert_eq(
    assemble_test_nodes(
      [
        assembly_section(
          "clones",
          [assembly_leaf(0)],
          select=512,
          replacement=true,
        ),
      ],
      0,
    ).length(),
    512,
  )
  assembly_reject([
    assembly_section(
      "too_many",
      [assembly_leaf(0)],
      select=513,
      replacement=true,
    ),
  ])
  let empty = assembly_section("empty", [])
  let repeated = assembly_section(
    "repeated",
    [empty],
    select=512,
    replacement=true,
  )
  assembly_reject([
    assembly_section("explosive", [repeated], select=512, replacement=true),
  ])
  let mut nested = assembly_leaf(0)
  for i in 0..<66 {
    nested = assembly_section("nested\{i}", [nested])
  }
  assembly_reject([nested])
}
