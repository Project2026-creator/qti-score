///|
priv struct AssociateChoice {
  identifier : String
  text : String
  minimum : Int32
  maximum : Int32
  fixed : Bool
  group : Array[String]
} derive(Debug)

///|
priv struct AssociateInteraction {
  choices : Array[AssociateChoice]
  index : Map[String, AssociateChoice]
  minimum : Int32
  maximum : Int32
  shuffle : Bool
} derive(Debug)

///|
// Pair equality ignores endpoint order. Store one representation everywhere,
// including mapping keys, typed expressions and result variables.
fn undirected_pair(text : String) -> String raise QtiError {
  let pair = directed_pair(text) catch {
    _ =>
      raise InvalidResponse("pair requires two space-separated ASCII NCNames")
  }
  let parts = pair.split(" ").to_array()
  if parts[0].lexical_compare(parts[1]) < 0 {
    pair
  } else {
    "\{parts[1]} \{parts[0]}"
  }
}

///|
fn authored_undirected_pair(
  text : String,
  node : Node,
) -> String raise QtiError {
  undirected_pair(text) catch {
    error => raise InvalidItem(node.location(), error.message())
  }
}

///|
fn parse_associate_interaction(
  node : Node,
  cardinality : Cardinality,
) -> AssociateInteraction raise QtiError {
  node.only_attributes([
    "response-identifier", "shuffle", "min-associations", "max-associations", "class",
    "id", "dir",
  ])
  node.only_children(["qti-prompt", "qti-simple-associable-choice"])
  let minimum = nonnegative_int(node, "min-associations", default=0)
  let maximum = nonnegative_int(node, "max-associations", default=1)
  if cardinality == Ordered ||
    (cardinality == Single && maximum != 1) ||
    (maximum != 0 && minimum > maximum) {
    raise InvalidItem(
      node.location(),
      "inconsistent associate cardinality or limits",
    )
  }
  let shuffle = xml_bool(node, "shuffle", default=false)
  let choices : Array[AssociateChoice] = []
  let index : Map[String, AssociateChoice] = Map([])
  for
    choice in node.children.filter(n => {
      n.name() == "qti-simple-associable-choice"
    }) {
    if choices.length() >= 512 {
      raise LimitExceeded("associate interaction supports at most 512 choices")
    }
    choice.only_attributes([
      "identifier", "match-min", "match-max", "match-group", "fixed", "class", "id",
      "dir",
    ])
    let id = identifier(choice.required("identifier"), choice.location())
    if index.contains(id) || id == "RESPONSE" || id == "SCORE" {
      raise InvalidItem(
        choice.location(),
        "duplicate or reserved associate choice '\{id}'",
      )
    }
    let lo = nonnegative_int(choice, "match-min", default=0)
    let hi = nonnegative_int(choice, "match-max")
    if hi != 0 && lo > hi {
      raise InvalidItem(choice.location(), "match-min exceeds match-max")
    }
    let group_text = choice
      .attr("match-group")
      .unwrap_or("")
      .replace_all(old="\t", new=" ")
      .replace_all(old="\r", new=" ")
      .replace_all(old="\n", new=" ")
    let group : Array[String] = []
    for token in group_text.split(" ").filter(s => !s.is_empty()) {
      group.push(identifier(token.to_owned(), choice.location()))
    }
    let option = {
      identifier: id,
      text: plain_static_text(choice).trim().to_owned(),
      minimum: lo,
      maximum: hi,
      fixed: xml_bool(choice, "fixed", default=false),
      group,
    }
    choices.push(option)
    index[id] = option
  }
  if choices.length() < 2 {
    raise InvalidItem(
      node.location(),
      "associate interaction needs at least two choices",
    )
  }
  for choice in choices {
    for id in choice.group {
      if !index.contains(id) {
        raise InvalidItem(
          node.location(),
          "match-group references unknown choice '\{id}'",
        )
      }
    }
  }
  { choices, index, minimum, maximum, shuffle, }
}

///|
fn AssociateInteraction::endpoints(
  self : AssociateInteraction,
  pair : String,
) -> (String, String) raise QtiError {
  let parts = pair.split(" ").to_array()
  let first = parts[0].to_owned()
  let second = parts[1].to_owned()
  if first == second {
    raise InvalidResponse("a choice cannot be associated with itself")
  }
  guard self.index.get(first) is Some(a) && self.index.get(second) is Some(b) else {
    raise InvalidResponse("unknown associate endpoints '\{pair}'")
  }
  if (!a.group.is_empty() && !a.group.contains(second)) ||
    (!b.group.is_empty() && !b.group.contains(first)) {
    raise InvalidResponse("association violates match-group for '\{pair}'")
  }
  (first, second)
}

///|
fn AssociateInteraction::validate(
  self : AssociateInteraction,
  pairs : Array[String],
) -> Unit raise QtiError {
  if pairs.length() < self.minimum ||
    (self.maximum != 0 && pairs.length() > self.maximum) {
    raise InvalidResponse("response violates min-associations/max-associations")
  }
  let seen : Map[String, Bool] = Map([])
  let counts : Map[String, Int32] = Map([])
  for pair in pairs {
    let (a, b) = self.endpoints(pair)
    if seen.contains(pair) {
      raise InvalidResponse("duplicate undirected association '\{pair}'")
    }
    seen[pair] = true
    counts[a] = counts.get(a).unwrap_or(0) + 1
    counts[b] = counts.get(b).unwrap_or(0) + 1
  }
  for choice in self.choices {
    let count = counts.get(choice.identifier).unwrap_or(0)
    if count < choice.minimum || (choice.maximum != 0 && count > choice.maximum) {
      raise InvalidResponse(
        "association count violates match-min/match-max for '\{choice.identifier}'",
      )
    }
  }
}

///|
fn AssociateInteraction::describe(self : AssociateInteraction) -> Json {
  {
    "min_associations": self.minimum,
    "max_associations": self.maximum,
    "shuffle": self.shuffle,
    "choices": self.choices.map(c => {
      let result : Json = {
        "identifier": c.identifier,
        "text": c.text,
        "match_min": c.minimum,
        "match_max": c.maximum,
        "fixed": c.fixed,
        "match_group": c.group.copy(),
      }
      result
    }),
  }
}
