///|
priv struct MatchChoice {
  identifier : String
  text : String
  minimum : Int32
  maximum : Int32
} derive(Debug)

///|
priv struct MatchInteraction {
  sources : Array[MatchChoice]
  targets : Array[MatchChoice]
  source_index : Map[String, MatchChoice]
  target_index : Map[String, MatchChoice]
  minimum : Int32
  maximum : Int32
  allow_duplicates : Bool
} derive(Debug)

///|
// XML Schema whitespace is collapsed; pair direction is retained.
fn directed_pair(text : String) -> String raise QtiError {
  let normalized = StringBuilder()
  for c in text.iter() {
    normalized.write_char(
      if c == '\t' || c == '\r' || c == '\n' {
        ' '
      } else {
        c
      },
    )
  }
  let parts = normalized
    .to_string()
    .split(" ")
    .filter(p => !p.is_empty())
    .collect()
  if parts.length() != 2 {
    raise InvalidResponse(
      "directedPair requires exactly two space-separated identifiers",
    )
  }
  for part in parts {
    ignore(
      identifier(part.to_owned(), "directedPair") catch {
        _ => raise InvalidResponse("directedPair members must be ASCII NCNames")
      },
    )
  }
  "\{parts[0]} \{parts[1]}"
}

///|
fn authored_pair(text : String, node : Node) -> String raise QtiError {
  directed_pair(text) catch {
    error => raise InvalidItem(node.location(), error.message())
  }
}

///|
fn parse_match_interaction(
  node : Node,
  cardinality : Cardinality,
) -> MatchInteraction raise QtiError {
  if cardinality == Ordered {
    raise InvalidItem(
      node.location(),
      "match interaction requires single or multiple cardinality",
    )
  }
  node.only_attributes([
    "response-identifier", "shuffle", "min-associations", "max-associations", "class",
    "id",
  ])
  node.only_children(["qti-prompt", "qti-simple-match-set"])
  ignore(xml_bool(node, "shuffle", default=false))
  let minimum = nonnegative_int(node, "min-associations", default=0)
  let maximum = nonnegative_int(node, "max-associations", default=1)
  if (maximum != 0 && minimum > maximum) ||
    (cardinality == Single && maximum != 1) {
    raise InvalidItem(
      node.location(),
      "inconsistent association limits or single cardinality",
    )
  }
  let sets = node.children.filter(n => n.name() == "qti-simple-match-set")
  if sets.length() != 2 {
    raise InvalidItem(
      node.location(),
      "match interaction requires exactly two match sets",
    )
  }
  let groups : Array[Array[MatchChoice]] = []
  let all_ids : Map[String, Bool] = Map([])
  for set in sets {
    set.only_attributes(["id"])
    set.only_children(["qti-simple-associable-choice"])
    let choices : Array[MatchChoice] = []
    for choice in set.children {
      choice.only_attributes([
        "identifier", "match-min", "match-max", "fixed", "class", "id",
      ])
      ignore(xml_bool(choice, "fixed", default=false))
      let id = identifier(choice.required("identifier"), choice.location())
      if all_ids.contains(id) || id == "RESPONSE" || id == "SCORE" {
        raise InvalidItem(
          choice.location(),
          "duplicate or reserved match choice '\{id}'",
        )
      }
      all_ids[id] = true
      let lo = nonnegative_int(choice, "match-min", default=0)
      let hi = nonnegative_int(choice, "match-max")
      if hi != 0 && lo > hi {
        raise InvalidItem(choice.location(), "match-min exceeds match-max")
      }
      choices.push({
        identifier: id,
        text: choice.all_text.to_string().trim().to_owned(),
        minimum: lo,
        maximum: hi,
      })
    }
    groups.push(choices)
  }
  match_interaction(groups[0], groups[1], minimum, maximum)
}

///|
fn match_interaction(
  sources : Array[MatchChoice],
  targets : Array[MatchChoice],
  minimum : Int32,
  maximum : Int32,
  allow_duplicates~ : Bool = false,
) -> MatchInteraction {
  let source_index : Map[String, MatchChoice] = Map([])
  let target_index : Map[String, MatchChoice] = Map([])
  for choice in sources {
    source_index[choice.identifier] = choice
  }
  for choice in targets {
    target_index[choice.identifier] = choice
  }
  {
    sources,
    targets,
    source_index,
    target_index,
    minimum,
    maximum,
    allow_duplicates,
  }
}

///|
fn MatchInteraction::endpoints(
  self : MatchInteraction,
  pair : String,
) -> (String, String) raise QtiError {
  let parts = pair.split(" ").collect()
  let source = parts[0].to_owned()
  let target = parts[1].to_owned()
  if !self.source_index.contains(source) || !self.target_index.contains(target) {
    raise InvalidResponse("unknown or reversed match endpoints '\{pair}'")
  }
  (source, target)
}

///|
fn MatchInteraction::validate(
  self : MatchInteraction,
  pairs : Array[String],
) -> Unit raise QtiError {
  if pairs.length() < self.minimum ||
    (self.maximum != 0 && pairs.length() > self.maximum) {
    raise InvalidResponse("response violates min-associations/max-associations")
  }
  let seen : Map[String, Bool] = Map([])
  let counts : Map[String, Int32] = Map([])
  for pair in pairs {
    let (source, target) = self.endpoints(pair)
    if !self.allow_duplicates && seen.contains(pair) {
      raise InvalidResponse("duplicate association '\{pair}'")
    }
    seen[pair] = true
    counts[source] = counts.get(source).unwrap_or(0) + 1
    counts[target] = counts.get(target).unwrap_or(0) + 1
  }
  for group in [self.sources, self.targets] {
    for choice in group {
      let count = counts.get(choice.identifier).unwrap_or(0)
      if count < choice.minimum ||
        (choice.maximum != 0 && count > choice.maximum) {
        raise InvalidResponse(
          "association count violates match-min/match-max for '\{choice.identifier}'",
        )
      }
    }
  }
}

///|
fn MatchInteraction::describe(self : MatchInteraction) -> Json {
  let sets = [self.sources, self.targets].map(choices => {
    choices.map(c => {
      let description : Json = {
        "identifier": c.identifier,
        "text": c.text,
        "match_min": c.minimum,
        "match_max": c.maximum,
      }
      description
    })
  })
  {
    "min_associations": self.minimum,
    "max_associations": self.maximum,
    "sets": sets,
  }
}
