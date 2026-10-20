///|
// QTI OrderInteraction 5.97: absent min-choices means order all, ignoring
// max-choices semantically. An explicit minimum must be at least one.
fn order_limits(node : Node, count : Int32) -> (Int32, Int32) raise QtiError {
  let maximum = nonnegative_int(node, "max-choices", default=count)
  if node.attr("orientation") is Some(value) &&
    !["vertical", "horizontal"].contains(value) {
    raise InvalidItem(node.location(), "invalid order orientation")
  }
  if node.attr("min-choices") is None {
    return (count, count)
  }
  let minimum = nonnegative_int(node, "min-choices")
  if minimum < 1 || minimum > count || maximum < minimum || maximum > count {
    raise InvalidItem(
      node.location(),
      "inconsistent order min-choices/max-choices",
    )
  }
  (minimum, maximum)
}
