///|
priv enum NumericOperand {
  Variable
  Correct
  Literal(Double)
} derive(Debug)

///|
priv struct NumericTolerance {
  mode : String
  lower : Double
  upper : Double
  include_lower : Bool
  include_upper : Bool
} derive(Debug)

///|
priv enum NumericTest {
  IsNull(NumericOperand)
  Equal(NumericOperand, NumericOperand, NumericTolerance)
} derive(Debug)

///|
priv struct NumericBranch {
  condition : NumericTest?
  score : Double
  source : SourceLocation
} derive(Debug)

///|
priv struct NumericRule {
  branches : Array[NumericBranch]
} derive(Debug)

///|
fn Node::source(self : Node) -> SourceLocation {
  { line: self.line, column: self.column, }
}

///|
// This is a checked grammar, not a general expression evaluator. Each branch
// has one supported predicate and one literal SCORE assignment, with a final
// else so that NULL and unsuccessful comparisons always have defined outcomes.
fn parse_numeric_rule(
  node : Node,
  correct : Array[String]?,
  base_type : BaseType,
) -> NumericRule raise QtiError {
  node.only_attributes([])
  node.only_children(["qti-response-condition"])
  let condition = node.one("qti-response-condition").unwrap()
  condition.only_attributes([])
  condition.only_children([
    "qti-response-if", "qti-response-else-if", "qti-response-else",
  ])
  let children = condition.children
  if children.length() < 2 ||
    children[0].name() != "qti-response-if" ||
    children.last().unwrap().name() != "qti-response-else" {
    raise InvalidItem(
      condition.location(),
      "numeric rule requires response-if and a final response-else",
    )
  }
  if children.length() > 128 {
    raise LimitExceeded("numeric rule exceeds 128 branches")
  }
  let branches : Array[NumericBranch] = []
  for i, branch in children {
    let is_else = i == children.length() - 1
    let expected = if is_else {
      "qti-response-else"
    } else if i == 0 {
      "qti-response-if"
    } else {
      "qti-response-else-if"
    }
    if branch.name() != expected {
      raise InvalidItem(branch.location(), "invalid numeric branch order")
    }
    branch.only_attributes([])
    branch.only_children(["qti-is-null", "qti-equal", "qti-set-outcome-value"])
    let expected_length = if is_else { 1 } else { 2 }
    if branch.children.length() != expected_length {
      raise InvalidItem(
        branch.location(),
        "branch needs one condition and one SCORE assignment, or only an assignment for else",
      )
    }
    let predicate = if is_else {
      None
    } else {
      Some(parse_numeric_test(branch.children[0], correct, base_type))
    }
    let assignment = branch.children[expected_length - 1]
    if assignment.name() != "qti-set-outcome-value" {
      raise InvalidItem(assignment.location(), "expected SCORE assignment")
    }
    assignment.only_attributes(["identifier"])
    assignment.only_children(["qti-base-value"])
    if assignment.required("identifier") != "SCORE" {
      raise Unsupported(
        assignment.location(),
        "only SCORE assignments are supported",
      )
    }
    let value = assignment.one("qti-base-value").unwrap()
    value.only_attributes(["base-type"])
    if value.required("base-type") != "float" || !value.children.is_empty() {
      raise Unsupported(
        value.location(),
        "SCORE assignment requires a literal float",
      )
    }
    branches.push({
      condition: predicate,
      score: authored_number(value.content.to_string(), Float, value),
      source: branch.source(),
    })
  }
  { branches, }
}

///|
fn parse_numeric_operand(
  node : Node,
  correct : Array[String]?,
) -> NumericOperand raise QtiError {
  match node.name() {
    "qti-variable" | "qti-correct" => {
      node.only_attributes(["identifier"])
      node.only_children([])
      if node.required("identifier") != "RESPONSE" {
        raise Unsupported(
          node.location(),
          "only the RESPONSE variable is supported",
        )
      }
      if node.name() == "qti-correct" {
        if correct is None {
          raise InvalidItem(
            node.location(),
            "qti-correct requires a correct response",
          )
        }
        Correct
      } else {
        Variable
      }
    }
    "qti-base-value" => {
      node.only_attributes(["base-type"])
      if !node.children.is_empty() {
        raise InvalidItem(
          node.location(),
          "numeric literal must contain text only",
        )
      }
      let kind = match node.required("base-type") {
        "integer" => BaseType::Integer
        "float" => BaseType::Float
        _ => raise Unsupported(node.location(), "expected a numeric literal")
      }
      Literal(authored_number(node.content.to_string(), kind, node))
    }
    _ => raise Unsupported(node.location(), "numeric operand '\{node.name()}'")
  }
}

///|
fn parse_numeric_test(
  node : Node,
  correct : Array[String]?,
  base_type : BaseType,
) -> NumericTest raise QtiError {
  node.only_children(["qti-variable", "qti-correct", "qti-base-value"])
  if node.name() == "qti-is-null" {
    node.only_attributes([])
    if node.children.length() != 1 {
      raise InvalidItem(node.location(), "is-null requires one operand")
    }
    return IsNull(parse_numeric_operand(node.children[0], correct))
  }
  if node.name() != "qti-equal" {
    raise Unsupported(node.location(), "numeric predicate '\{node.name()}'")
  }
  node.only_attributes([
    "tolerance-mode", "tolerance", "include-lower-bound", "include-upper-bound",
  ])
  if node.children.length() != 2 {
    raise InvalidItem(node.location(), "equal requires two operands")
  }
  let left = parse_numeric_operand(node.children[0], correct)
  let right = parse_numeric_operand(node.children[1], correct)
  let mode = node.attr("tolerance-mode").unwrap_or("exact")
  if !["exact", "absolute", "relative"].contains(mode) {
    raise InvalidItem(node.location(), "invalid tolerance-mode")
  }
  let mut lower = 0.0
  let mut upper = 0.0
  if mode == "exact" {
    if node.attr("tolerance") is Some(_) {
      raise Unsupported(node.location(), "tolerance on an exact comparison")
    }
  } else {
    let parts = node
      .required("tolerance")
      .split(" ")
      .filter(s => s != "")
      .map(s => s.to_owned())
      .collect()
    if parts.length() != 1 && parts.length() != 2 {
      raise InvalidItem(
        node.location(),
        "tolerance needs one or two positive numbers",
      )
    }
    lower = authored_number(parts[0], Float, node)
    upper = if parts.length() == 1 {
      lower
    } else {
      authored_number(parts[1], Float, node)
    }
    if lower <= 0.0 || upper <= 0.0 {
      raise InvalidItem(node.location(), "tolerances must be positive")
    }
    // Keep the relative profile unambiguous: its reference x is a fixed,
    // nonnegative correct value or literal, never the learner's variable.
    if mode == "relative" {
      let reference = match left {
        Variable =>
          raise Unsupported(
            node.location(),
            "relative comparison requires a fixed first operand",
          )
        Correct => authored_number(correct.unwrap()[0], base_type, node)
        Literal(n) => n
      }
      if reference < 0.0 {
        raise Unsupported(
          node.location(),
          "negative relative reference; use absolute tolerance",
        )
      }
    }
  }
  let tolerance : NumericTolerance = {
    mode,
    lower,
    upper,
    include_lower: xml_bool(node, "include-lower-bound", default=true),
    include_upper: xml_bool(node, "include-upper-bound", default=true),
  }
  if mode != "exact" {
    let reference = match left {
      Variable => None
      Correct => Some(authored_number(correct.unwrap()[0], base_type, node))
      Literal(n) => Some(n)
    }
    if reference is Some(x) {
      let (lo, hi) = tolerance.bounds(x)
      if lo.is_inf() || hi.is_inf() || lo.is_nan() || hi.is_nan() {
        raise InvalidItem(
          node.location(),
          "authored tolerance bounds exceed finite range",
        )
      }
    }
  }
  Equal(left, right, tolerance)
}

///|
fn NumericTolerance::bounds(
  self : NumericTolerance,
  x : Double,
) -> (Double, Double) {
  if self.mode == "absolute" {
    (x - self.lower, x + self.upper)
  } else {
    (x * (1.0 - self.lower / 100.0), x * (1.0 + self.upper / 100.0))
  }
}

///|
fn NumericOperand::value(
  self : NumericOperand,
  response : Double?,
  correct : Double?,
) -> Double? {
  match self {
    Variable => response
    Correct => correct
    Literal(n) => Some(n)
  }
}

///|
fn NumericTest::evaluate(
  self : NumericTest,
  response : Double?,
  correct : Double?,
) -> (Bool?, Json) raise QtiError {
  match self {
    IsNull(operand) => {
      let matched = operand.value(response, correct) is None
      (Some(matched), { "operator": "is_null", "matched": matched })
    }
    Equal(left, right, tolerance) => {
      let x = left.value(response, correct)
      let y = right.value(response, correct)
      guard x is Some(x) && y is Some(y) else {
        return (
          None,
          {
            "operator": "equal",
            "matched": Json::null(),
            "reason": "null_operand",
          },
        )
      }
      if tolerance.mode == "exact" {
        return (
          Some(x == y),
          {
            "operator": "equal",
            "mode": "exact",
            "reference": x,
            "value": y,
            "matched": x == y,
          },
        )
      }
      let (lo, hi) = tolerance.bounds(x)
      if lo.is_inf() || hi.is_inf() || lo.is_nan() || hi.is_nan() {
        raise InvalidResponse("numeric tolerance bounds exceed finite range")
      }
      let matched = (if tolerance.include_lower { y >= lo } else { y > lo }) &&
        (if tolerance.include_upper { y <= hi } else { y < hi })
      (
        Some(matched),
        {
          "operator": "equal",
          "mode": tolerance.mode,
          "reference": x,
          "value": y,
          "lower": lo,
          "upper": hi,
          "include_lower": tolerance.include_lower,
          "include_upper": tolerance.include_upper,
          "matched": matched,
        },
      )
    }
  }
}

///|
fn NumericRule::score(
  self : NumericRule,
  response : Double?,
  correct : Double?,
  steps : Array[ScoringStep]?,
) -> Double raise QtiError {
  for i, branch in self.branches {
    let (matched, detail) : (Bool, Json) = match branch.condition {
      None => (true, { "operator": "else", "matched": true })
      Some(predicate) => {
        let (result, detail) = predicate.evaluate(response, correct)
        (result == Some(true), detail)
      }
    }
    record_step(steps, "numeric_condition", branch.source, {
      "branch": i,
      "condition": detail,
      "selected": matched,
    })
    if matched {
      record_step(steps, "set_score", branch.source, { "score": branch.score })
      return branch.score
    }
  }
  // Compilation requires an unconditional final else.
  abort("compiled numeric rule has no final branch")
}
