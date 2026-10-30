///|
priv struct GraphicImage {
  data : String
  mime_type : String
  width : Int32?
  height : Int32?
  alternative : String
} derive(Debug)

///|
priv struct GraphicRegion {
  identifier : String
  label : String
  shape : String
  coords : Array[Double]
  minimum : Int32
  maximum : Int32
} derive(Debug)

///|
// Geometry describes candidate controls. Responses remain identifiers or
// directed pairs; scoring never infers an answer from mouse coordinates.
priv struct GraphicInteraction {
  kind : String
  image : GraphicImage
  regions : Array[GraphicRegion]
  minimum : Int32
  maximum : Int32
  gap_images : Array[Json]
} derive(Debug)

///|
fn GraphicImage::describe(self : GraphicImage) -> Json {
  let width : Json = match self.width {
    Some(n) => Json(n)
    None => Json::null()
  }
  let height : Json = match self.height {
    Some(n) => Json(n)
    None => Json::null()
  }
  {
    "data": self.data,
    "type": self.mime_type,
    "width": width,
    "height": height,
    "alternative": self.alternative,
  }
}

///|
fn GraphicInteraction::describe(self : GraphicInteraction) -> Json {
  let regions : Array[Json] = self.regions.map(region => {
    "identifier": region.identifier,
    "label": region.label,
    "shape": region.shape,
    "coords": region.coords,
    "match_min": region.minimum,
    "match_max": region.maximum,
  })
  let result : Map[String, Json] = {
    "kind": Json(self.kind),
    "object": self.image.describe(),
    "regions": Json(regions),
    "gap_images": Json(self.gap_images),
  }
  if self.kind == "hotspot" {
    result["min_choices"] = Json(self.minimum)
    result["max_choices"] = Json(self.maximum)
  } else {
    result["min_associations"] = Json(self.minimum)
    result["max_associations"] = Json(self.maximum)
  }
  Json(result)
}

///|
fn graphic_dimension(node : Node, key : String) -> Int32? raise QtiError {
  if node.attr(key) is None {
    return None
  }
  let value = nonnegative_int(node, key)
  if value < 1 || value > 16384 {
    raise InvalidItem(
      node.location(),
      "graphic dimensions must be 1 to 16384 pixels",
    )
  }
  Some(value)
}

///|
fn graphic_namespaces(node : Node) -> Unit raise QtiError {
  let uri = node.element.name.namespace_uri
  let allowed = if node.name().has_prefix("qti-") {
    uri == Some(qti_namespace)
  } else {
    uri == Some(qti_namespace) || uri == Some("http://www.w3.org/1999/xhtml")
  }
  if !allowed {
    raise Unsupported(node.location(), "graphic element namespace")
  }
  for child in node.children {
    graphic_namespaces(child)
  }
}

///|
// QTI interaction children and HTML image children can use their respective
// namespaces. Check the complete subtree before matching by local name.
fn graphic_only_children(
  node : Node,
  allowed : Array[String],
) -> Unit raise QtiError {
  if node.content.to_string().trim() != "" {
    raise InvalidItem(node.location(), "unexpected graphic text content")
  }
  for child in node.children {
    if !allowed.contains(child.name()) {
      raise Unsupported(
        child.location(),
        "graphic child '" + child.name() + "'",
      )
    }
  }
}

///|
fn graphic_image(node : Node) -> GraphicImage raise QtiError {
  let is_img = node.name() == "img"
  if !is_img && node.name() != "object" {
    raise Unsupported(node.location(), "graphic picture/source selection")
  }
  node.only_attributes(
    if is_img {
      ["src", "width", "height", "alt", "id", "class", "role", "aria-label"]
    } else {
      ["data", "type", "width", "height", "id", "class", "role", "aria-label"]
    },
  )
  if !node.children.is_empty() ||
    (is_img && node.content.to_string().trim() != "") {
    raise Unsupported(node.location(), "nested graphic fallback content")
  }
  let reference = node.required(if is_img { "src" } else { "data" })
  let decoded = decode_package_uri(reference) catch {
    _ =>
      raise InvalidItem(
        node.location(),
        "graphic resource must be a safe local package URI",
      )
  }
  if decoded == "" ||
    decoded.has_prefix("/") ||
    decoded.contains(":") ||
    decoded.contains("\\") ||
    decoded.contains("%") ||
    decoded.contains("?") ||
    decoded.contains("#") ||
    decoded.iter().any(c => c < ' ' || c == '\u007f') {
    raise InvalidItem(
      node.location(),
      "graphic resource must be a safe local package URI",
    )
  }
  // The item location supplies the base. Retain ../ references so a host can
  // resolve them against that location and enforce the package root boundary.
  // Never fetch or interpret image bytes in the scoring kernel.
  let data = reference
  let mime_type = if is_img {
    let path = decoded.to_lower()
    if path.has_suffix(".svg") {
      "image/svg+xml"
    } else if path.has_suffix(".png") {
      "image/png"
    } else if path.has_suffix(".jpg") || path.has_suffix(".jpeg") {
      "image/jpeg"
    } else if path.has_suffix(".webp") {
      "image/webp"
    } else if path.has_suffix(".gif") {
      "image/gif"
    } else {
      raise Unsupported(
        node.location(),
        "graphic img format (use SVG, PNG, JPEG, WebP or GIF)",
      )
    }
  } else {
    node.required("type").to_lower()
  }
  if !["image/svg+xml", "image/png", "image/jpeg", "image/webp", "image/gif"].contains(
      mime_type,
    ) {
    raise Unsupported(node.location(), "graphic MIME type '" + mime_type + "'")
  }
  let alternative = if is_img {
    match node.attr("alt") {
      Some(text) => text
      None =>
        raise InvalidItem(
          node.location(),
          "graphic img requires an alt attribute",
        )
    }
  } else {
    node
    .attr("aria-label")
    .unwrap_or(node.all_text.to_string().trim().to_owned())
  }
  {
    data,
    mime_type,
    alternative,
    width: graphic_dimension(node, "width"),
    height: graphic_dimension(node, "height"),
  }
}

///|
fn graphic_background(node : Node) -> GraphicImage raise QtiError {
  let backgrounds = node.children.filter(child => {
    ["img", "object", "picture"].contains(child.name())
  })
  if backgrounds.length() != 1 {
    raise InvalidItem(
      node.location(),
      "graphic interaction requires exactly one background image",
    )
  }
  if backgrounds[0].name() == "picture" {
    raise Unsupported(
      backgrounds[0].location(),
      "graphic picture/source selection",
    )
  }
  graphic_image(backgrounds[0])
}

///|
fn graphic_coordinates(
  node : Node,
  shape : String,
) -> Array[Double] raise QtiError {
  if !["circle", "rect", "ellipse", "poly"].contains(shape) {
    raise Unsupported(node.location(), "graphic shape '" + shape + "'")
  }
  let raw = node.required("coords")
  if raw.length() > 4096 {
    raise LimitExceeded("graphic coordinates exceed 4096 characters")
  }
  if raw.contains("%") {
    raise Unsupported(node.location(), "percentage graphic coordinates")
  }
  let parts = raw.split(",").to_array()
  if parts.length() > 256 {
    raise LimitExceeded("graphic region exceeds 256 coordinate components")
  }
  let values : Array[Double] = []
  for part in parts {
    if part.is_empty() || !part.iter().all(c => c >= '0' && c <= '9') {
      raise InvalidItem(
        node.location(),
        "graphic coordinates must be comma-separated nonnegative integers",
      )
    }
    let value = @string.parse_int(part) catch {
      _ =>
        raise InvalidItem(
          node.location(),
          "graphic coordinate exceeds its integer range",
        )
    }
    if value > 1000000 {
      raise LimitExceeded("graphic coordinate exceeds 1000000 pixels")
    }
    values.push(value.to_double())
  }
  let valid = match shape {
    "circle" => values.length() == 3 && values[2] > 0
    "rect" =>
      values.length() == 4 && values[2] > values[0] && values[3] > values[1]
    "ellipse" => values.length() == 4 && values[2] > 0 && values[3] > 0
    "poly" => values.length() >= 6 && values.length() % 2 == 0
    _ => false
  }
  if !valid {
    raise InvalidItem(
      node.location(),
      "graphic shape has invalid coordinate count or dimensions",
    )
  }
  values
}

///|
fn graphic_id(node : Node, ids : Map[String, Bool]) -> String raise QtiError {
  let id = identifier(node.required("identifier"), node.location())
  if ids.contains(id) ||
    ["RESPONSE", "SCORE", "numAttempts", "duration", "completionStatus"].contains(
      id,
    ) {
    raise InvalidItem(
      node.location(),
      "duplicate or reserved graphic identifier '" + id + "'",
    )
  }
  ids[id] = true
  if ids.length() > 512 {
    raise LimitExceeded("graphic interaction exceeds 512 choices and regions")
  }
  id
}

///|
fn graphic_region(
  node : Node,
  ids : Map[String, Bool],
  associable~ : Bool,
) -> GraphicRegion raise QtiError {
  node.only_attributes(
    if associable {
      [
        "identifier", "shape", "coords", "hotspot-label", "match-min", "match-max",
        "show-hide", "class", "id",
      ]
    } else {
      [
        "identifier", "shape", "coords", "hotspot-label", "show-hide", "class", "id",
      ]
    },
  )
  node.only_children([])
  if node.attr("show-hide").unwrap_or("show") != "show" {
    raise Unsupported(node.location(), "dynamically hidden graphic region")
  }
  let id = graphic_id(node, ids)
  let shape = node.required("shape")
  let coords = graphic_coordinates(node, shape)
  let minimum = if associable {
    nonnegative_int(node, "match-min", default=0)
  } else {
    0
  }
  let maximum = if associable { nonnegative_int(node, "match-max") } else { 1 }
  if maximum != 0 && minimum > maximum {
    raise InvalidItem(
      node.location(),
      "graphic region match-min exceeds match-max",
    )
  }
  {
    identifier: id,
    label: node.attr("hotspot-label").unwrap_or(id),
    shape,
    coords,
    minimum,
    maximum,
  }
}

///|
fn graphic_sequence(node : Node, gap~ : Bool) -> Unit raise QtiError {
  let mut stage = 0
  let mut prompts = 0
  for child in node.children {
    let next = match child.name() {
      "qti-prompt" => {
        prompts += 1
        0
      }
      "object" | "img" | "picture" => 1
      "qti-gap-text" | "qti-gap-img" if gap => 2
      "qti-associable-hotspot" if gap => 3
      "qti-hotspot-choice" if !gap => 2
      _ => raise Unsupported(child.location(), "unsupported graphic child")
    }
    if next < stage || prompts > 1 {
      raise InvalidItem(
        child.location(),
        "graphic interaction children are out of schema order",
      )
    }
    stage = next
    if child.name() == "qti-prompt" {
      child.only_attributes(["class", "id", "dir"])
      gap_text_content(child)
    }
  }
}

///|
fn parse_hotspot_interaction(
  node : Node,
  cardinality : Cardinality,
) -> (GraphicInteraction, Array[Choice]) raise QtiError {
  graphic_namespaces(node)
  if cardinality == Ordered {
    raise InvalidItem(
      node.location(),
      "hotspot requires single or multiple identifier cardinality",
    )
  }
  node.only_attributes([
    "response-identifier", "min-choices", "max-choices", "class", "id", "data-min-selections-message",
    "data-max-selections-message",
  ])
  graphic_only_children(node, [
    "qti-prompt", "object", "img", "picture", "qti-hotspot-choice",
  ])
  graphic_sequence(node, gap=false)
  let image = graphic_background(node)
  let minimum = nonnegative_int(node, "min-choices", default=0)
  let maximum = nonnegative_int(node, "max-choices", default=1)
  if (maximum != 0 && minimum > maximum) ||
    (cardinality == Single && maximum != 1) {
    raise InvalidItem(
      node.location(),
      "hotspot choice limits conflict with cardinality",
    )
  }
  let ids : Map[String, Bool] = Map([])
  let regions = node.children
    .filter(child => child.name() == "qti-hotspot-choice")
    .map(child => graphic_region(child, ids, associable=false))
  if regions.is_empty() {
    raise InvalidItem(node.location(), "hotspot requires at least one region")
  }
  if minimum > regions.length() {
    raise InvalidItem(
      node.location(),
      "hotspot min-choices exceeds region count",
    )
  }
  let choices = regions.map(region => {
    identifier: region.identifier,
    text: region.label,
  })
  (
    { kind: "hotspot", image, regions, minimum, maximum, gap_images: [], },
    choices,
  )
}

///|
fn parse_graphic_gap_interaction(
  node : Node,
  cardinality : Cardinality,
) -> (GraphicInteraction, MatchInteraction) raise QtiError {
  graphic_namespaces(node)
  if cardinality != Multiple {
    raise InvalidItem(
      node.location(),
      "graphic gap match requires multiple directedPair cardinality",
    )
  }
  node.only_attributes([
    "response-identifier", "min-associations", "max-associations", "class", "id",
    "data-min-selections-message", "data-max-selections-message", "data-choices-container-width",
  ])
  graphic_only_children(node, [
    "qti-prompt", "object", "img", "picture", "qti-gap-text", "qti-gap-img", "qti-associable-hotspot",
  ])
  graphic_sequence(node, gap=true)
  let image = graphic_background(node)
  let minimum = nonnegative_int(node, "min-associations", default=0)
  let maximum = nonnegative_int(node, "max-associations", default=1)
  if maximum != 0 && minimum > maximum {
    raise InvalidItem(node.location(), "graphic association limits conflict")
  }
  let ids : Map[String, Bool] = Map([])
  let sources : Array[MatchChoice] = []
  let gap_images : Array[Json] = []
  for choice in node.children {
    if choice.name() != "qti-gap-text" && choice.name() != "qti-gap-img" {
      continue
    }
    choice.only_attributes(
      if choice.name() == "qti-gap-img" {
        [
          "identifier", "match-min", "match-max", "show-hide", "object-label", "class",
          "id",
        ]
      } else {
        ["identifier", "match-min", "match-max", "show-hide", "class", "id"]
      },
    )
    if choice.attr("show-hide").unwrap_or("show") != "show" {
      raise Unsupported(
        choice.location(),
        "dynamically hidden graphic gap choice",
      )
    }
    let id = graphic_id(choice, ids)
    let lo = nonnegative_int(choice, "match-min", default=0)
    let hi = nonnegative_int(choice, "match-max")
    if hi != 0 && lo > hi {
      raise InvalidItem(
        choice.location(),
        "graphic gap choice match-min exceeds match-max",
      )
    }
    let text = if choice.name() == "qti-gap-text" {
      gap_text_content(choice)
      choice.all_text.to_string().trim().to_owned()
    } else {
      graphic_only_children(choice, ["img", "object", "picture"])
      let picture = graphic_background(choice)
      gap_images.push({ "identifier": id, "image": picture.describe() })
      choice
      .attr("object-label")
      .unwrap_or(
        if picture.alternative == "" {
          id
        } else {
          picture.alternative
        },
      )
    }
    sources.push({ identifier: id, text, minimum: lo, maximum: hi, })
  }
  let regions = node.children
    .filter(child => child.name() == "qti-associable-hotspot")
    .map(child => graphic_region(child, ids, associable=true))
  if sources.is_empty() || regions.is_empty() {
    raise InvalidItem(
      node.location(),
      "graphic gap match needs choices and hotspot targets",
    )
  }
  let targets = regions.map(region => {
    identifier: region.identifier,
    text: region.label,
    minimum: region.minimum,
    maximum: region.maximum,
  })
  let matching = match_interaction(
    sources,
    targets,
    minimum,
    maximum,
    allow_duplicates=true,
  )
  (
    { kind: "graphic_gap_match", image, regions, minimum, maximum, gap_images, },
    matching,
  )
}
