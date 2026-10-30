///|
priv struct TestFlowPredicate {
  program : ProcessingProgram
  expression : ProcessingExpression
} derive(Debug)

///|
priv struct TestFlowCompiler {
  program : ProcessingProgram
  item_schemas : Array[ProcessingItemSchema]?
}

///|
// Declarations are parsed once for the whole test. Predicates share this
// immutable compilation context rather than duplicating every item schema.
fn test_flow_context(
  root : Node,
  item_declarations : Json,
) -> TestFlowCompiler raise QtiError {
  if root.name() != "qti-assessment-test" ||
    root.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(
      root.location(),
      "flow predicates require a QTI assessment test",
    )
  }
  let declarations = processing_declarations(root)
  if declarations.any(d => d.response) {
    raise InvalidItem(
      root.location(),
      "test flow cannot declare local response variables",
    )
  }
  {
    program: { declarations, rules: [], test_mode: true, },
    item_schemas: processing_item_schemas(item_declarations),
  }
}

///|
fn test_flow_expression_scope(
  expression : ProcessingExpression,
) -> Unit raise QtiError {
  let location = "flow expression at \{expression.source.line}:\{expression.source.column}"
  match expression.expression {
    TestVariables(_) =>
      raise Unsupported(
        location, "test-variables is restricted to outcome processing",
      )
    ItemReference(reference) =>
      if reference.weight_identifier is Some(_) {
        raise Unsupported(
          location, "item weighting is restricted to outcome processing",
        )
      }
    Operator(_, operands, _) =>
      for operand in operands {
        test_flow_expression_scope(operand)
      }
    _ => ()
  }
}

///|
// Flow conditions share the processing expression types and item declarations.
// Scope/target ordering is checked by the test compiler, not by this predicate.
fn test_flow_predicate(
  node : Node,
  root : Node,
  item_declarations~ : Json = Json::null(),
  compiled~ : TestFlowCompiler? = None,
) -> TestFlowPredicate raise QtiError {
  let compiler = match compiled {
    Some(compiler) => compiler
    None => test_flow_context(root, item_declarations)
  }
  compiler.compile(node)
}

///|
fn TestFlowCompiler::compile(
  self : TestFlowCompiler,
  node : Node,
) -> TestFlowPredicate raise QtiError {
  if !["qti-pre-condition", "qti-branch-rule"].contains(node.name()) ||
    node.element.name.namespace_uri != Some(qti_namespace) {
    raise Unsupported(
      node.location(),
      "expected a QTI pre-condition or branch-rule",
    )
  }
  let branch = node.name() == "qti-branch-rule"
  node.only_attributes(if branch { ["target"] } else { [] })
  if branch {
    ignore(identifier(node.required("target"), node.location()))
  }
  processing_arity(node, 1, 1)
  let expression = processing_expression(
    node.children[0],
    self.program.declarations,
    test_mode=true,
    item_schemas=self.item_schemas,
  )
  processing_expect(node, expression, processing_type("boolean", Single))
  test_flow_expression_scope(expression)
  { program: self.program, expression, }
}

///|
// Current test outcomes are explicit inputs: evaluation never resets them or
// runs outcome-processing. Missing values stay NULL, including before entry.
fn TestFlowPredicate::evaluate(
  self : TestFlowPredicate,
  input : Json,
  test_outcomes : Json,
) -> Bool raise QtiError {
  let context = self.program.context(
    input,
    None,
    current_outcomes=Some(test_outcomes),
  )
  let result = self.expression.evaluate(context)
  match result {
    True => true
    False | Null => false
    _ => raise InvalidResponse("flow predicate did not return a single boolean")
  }
}
