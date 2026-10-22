///|
priv struct CompositeBinding {
  identifier : String
  base_type : BaseType
  correct : Array[String]?
  mapping : Mapping?
  placeholder : String
  source : SourceLocation
} derive(Debug)

///|
priv enum CompositePart {
  Text(String)
  Response(String)
} derive(Debug)

///|
priv enum CompositeCredit {
  Mapped
  Matched(Double)
  Compared(NumericTest, Double)
} derive(Debug)

///|
priv struct CompositeBranch {
  credit : CompositeCredit
  source : SourceLocation
} derive(Debug)

///|
priv struct CompositeRule {
  binding : Int32
  branches : Array[CompositeBranch]
} derive(Debug)

///|
pub struct CompositeItem {
  identifier : String
  title : String
  priv bindings : Array[CompositeBinding]
  priv passage : Array[CompositePart]
  priv instructions : Array[String]
  priv rules : Array[CompositeRule]
  priv source : SourceLocation
} derive(Debug)

///|
pub fn CompositeItem::describe(self : CompositeItem) -> Json {
  let description : Json = {
    "kind": "composite",
    "identifier": self.identifier,
    "title": self.title,
    "prompt": self.title,
    "template": "composite_rules",
    "responses": self.bindings.map(b => {
      "identifier": b.identifier,
      "cardinality": "single",
      "base_type": b.base_type.name(),
      "placeholder": b.placeholder,
    }),
    "passage": self.passage.map(p => {
      match p {
        Text(text) => { "text": text }
        Response(id) => { "response": id }
      }
    }),
  }
  if !self.instructions.is_empty() && description is Object(fields) {
    fields["instructions"] = Json(self.instructions.copy())
  }
  description
}

///|
pub extend CompositeItem with Debug::{to_repr}
