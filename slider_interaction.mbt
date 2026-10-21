///|
priv struct SliderInteraction {
  lower : Double
  upper : Double
  step : Double?
  integer : Bool
  step_label : Bool
  orientation : String
  reverse : Bool
} derive(Debug)

///|
fn SliderInteraction::describe(self : SliderInteraction) -> Json {
  let step : Json = match self.step {
    Some(value) => Json(value)
    None => Json::null()
  }
  {
    "lower_bound": self.lower,
    "upper_bound": self.upper,
    "step": step,
    "step_label": self.step_label,
    "orientation": self.orientation,
    "reverse": self.reverse,
  }
}

///|
fn SliderInteraction::validate(
  self : SliderInteraction,
  value : Double,
) -> Unit raise QtiError {
  if value < self.lower || value > self.upper {
    raise InvalidResponse("slider response is outside its bounds")
  }
  if self.step is Some(step) {
    let index = ((value - self.lower) / step).round()
    let grid = self.lower + index * step
    if grid.is_inf() {
      raise InvalidResponse(
        "slider response does not lie on a finite step grid",
      )
    }
    // This accounts only for arithmetic roundoff in grid validation. It does
    // not change the response or add tolerance to any scoring comparison.
    let tolerance = if self.integer {
      0.0
    } else {
      let factor = 8.0 * 2.220446049250313e-16
      let margin = factor * value.abs() +
        factor * self.lower.abs() +
        factor * (index * step).abs()
      let cap = step * 1.0e-8
      if margin < cap {
        margin
      } else {
        cap
      }
    }
    if (value - grid).abs() > tolerance {
      raise InvalidResponse("slider response does not lie on its step grid")
    }
  }
}

///|
fn parse_slider_interaction(
  node : Node,
  base_type : BaseType,
) -> SliderInteraction raise QtiError {
  node.only_attributes([
    "response-identifier", "lower-bound", "upper-bound", "step", "step-label", "orientation",
    "reverse", "class", "id", "dir",
  ])
  node.only_children(["qti-prompt"])
  let integer = base_type == Integer
  let lo = number(node, "lower-bound")
  let hi = number(node, "upper-bound")
  if lo < 0 || hi < lo {
    raise InvalidItem(
      node.location(),
      "slider bounds must be nonnegative and ordered",
    )
  }
  let lower = if integer { lo.floor() } else { lo }
  let upper = if integer { hi.ceil() } else { hi }
  if integer && upper > 9007199254740991.0 {
    raise InvalidItem(
      node.location(),
      "integer slider exceeds the exact JSON/JS range",
    )
  }
  let step = match optional_number(node, "step") {
    None if integer => Some(1.0)
    value => value
  }
  if step is Some(value) {
    if value <= 0 {
      raise InvalidItem(
        node.location(),
        "slider step must be positive in this profile",
      )
    }
    if integer && (value.trunc() != value || value > 9007199254740991.0) {
      raise Unsupported(
        node.location(),
        "integer sliders require a safe integral step",
      )
    }
    let intervals = (upper - lower) / value
    if intervals.is_inf() || intervals > 1048576.0 {
      raise LimitExceeded("slider grid exceeds 1048576 intervals")
    }
    if lower != upper && (lower + value == lower || upper - value == upper) {
      raise Unsupported(
        node.location(),
        "slider step is smaller than floating-point resolution",
      )
    }
  }
  let orientation = node.attr("orientation").unwrap_or("horizontal")
  if orientation != "horizontal" && orientation != "vertical" {
    raise InvalidItem(node.location(), "unknown slider orientation")
  }
  {
    lower,
    upper,
    step,
    integer,
    step_label: xml_bool(node, "step-label", default=false),
    orientation,
    reverse: xml_bool(node, "reverse", default=false),
  }
}

///|
// A block slider follows its prompt and static context; instructions remain
// separate. Do not silently flatten images, links or dynamic content.
fn slider_body_text(node : Node) -> String raise QtiError {
  if node.name() == "qti-rubric-block" {
    return ""
  }
  if node.name() == "qti-slider-interaction" {
    return match node.one("qti-prompt", required=false) {
      None => ""
      Some(prompt) => {
        prompt.only_attributes(["class", "id", "dir"])
        plain_static_text(prompt)
      }
    }
  }
  if ![
      "qti-item-body", "p", "div", "blockquote", "ul", "ol", "li", "span", "strong",
      "em", "b", "i", "u", "sub", "sup", "br",
    ].contains(node.name()) {
    raise Unsupported(node.location(), "slider context '\{node.name()}'")
  }
  node.only_attributes(["class", "id", "dir"])
  if node.name() == "br" {
    node.only_children([])
  }
  let text = StringBuilder()
  for part in node.parts {
    match part {
      Text(value) =>
        if node.name() != "qti-item-body" || value.trim() != "" {
          text.write_string(value)
        }
      Element(child) => text.write_string(slider_body_text(child))
    }
  }
  if ["p", "div", "blockquote", "li", "br"].contains(node.name()) {
    text.write_string("\n")
  }
  text.to_string()
}
