///|
priv struct ProcessingType {
  base : String
  cardinality : Cardinality
} derive(Debug, Eq)

///|
priv struct ProcessingDeclaration {
  identifier : String
  kind : ProcessingType
  response : Bool
  default_value : Json
  correct : Json
  mapping : Mapping?
  external_scored : String?
  source : SourceLocation
} derive(Debug)

///|
priv enum ProcessingExpressionKind {
  Literal(Json)
  Reference(String, String)
  ItemReference(ProcessingItemReference)
  TestVariables(ProcessingTestVariables)
  Operator(String, Array[ProcessingExpression], NumericTolerance?)
} derive(Debug)

///|
priv struct ProcessingItemVariable {
  identifier : String
  kind : ProcessingType
  response : Bool
} derive(Debug, Eq)

///|
priv struct ProcessingItemSchema {
  identifier : String
  variables : Array[ProcessingItemVariable]
  categories : Array[String]
  section_identifiers : Array[String]
} derive(Debug)

///|
priv struct ProcessingItemReference {
  identifier : String
  instance_index : Int32?
  variable : ProcessingItemVariable
  weight_identifier : String?
} derive(Debug)

///|
priv struct ProcessingTestVariables {
  variable_identifier : String
  base_filter : String?
  section_identifier : String?
  include_categories : Array[String]
  exclude_categories : Array[String]
  weight_identifier : String?
  schemas : Array[ProcessingItemSchema]?
} derive(Debug)

///|
priv struct ProcessingExpression {
  expression : ProcessingExpressionKind
  kind : ProcessingType?
  source : SourceLocation
} derive(Debug)

///|
priv enum ProcessingRule {
  Assign(String, ProcessingExpression, SourceLocation)
  Condition(Array[ProcessingBranch])
  Exit(SourceLocation)
} derive(Debug)

///|
priv struct ProcessingBranch {
  predicate : ProcessingExpression?
  rules : Array[ProcessingRule]
  source : SourceLocation
} derive(Debug)

///|
/// A bounded typed response/outcome processing program. Evaluation resets
/// declared outcomes to their authored defaults before each invocation.
pub struct ProcessingProgram {
  priv declarations : Array[ProcessingDeclaration]
  priv rules : Array[ProcessingRule]
  priv test_mode : Bool
} derive(Debug)

///|
priv struct ProcessingFeedback {
  identifier : String
  outcome : String
  show : Bool
  title : String
  text : String
} derive(Debug)

///|
priv struct ProcessingBinding {
  identifier : String
  validator : Item
  extended : ProcessingExtended?
} derive(Debug)

///|
priv struct ProcessingExtended {
  prompt : String
  placeholder : String
  format : String
  minimum : Int32
  expected_lines : Int32?
  expected_length : Int32?
} derive(Debug)

///|
fn ProcessingExtended::describe(self : ProcessingExtended) -> Json {
  let result : Json = {
    "prompt": self.prompt,
    "placeholder": self.placeholder,
    "format": self.format,
    "min_strings": self.minimum,
  }
  if result is Object(fields) {
    if self.expected_lines is Some(lines) {
      fields["expected_lines"] = Json(lines)
    }
    if self.expected_length is Some(length) {
      fields["expected_length"] = Json(length)
    }
  }
  result
}

///|
/// An assessment item with a typed processing program and authored modal
/// feedback. Public descriptions contain response metadata, not answers.
pub struct ProcessedItem {
  priv item_identifier : String
  priv title : String
  priv program : ProcessingProgram
  priv bindings : Array[ProcessingBinding]
  priv passage : Array[CompositePart]
  priv feedback : Array[ProcessingFeedback]
  priv instructions : Array[String]
} derive(Debug)

///|
pub extend ProcessingProgram with Debug::{to_repr}

///|
pub extend ProcessedItem with Debug::{to_repr}

///|
fn processing_type(base : String, cardinality : Cardinality) -> ProcessingType {
  { base, cardinality, }
}

///|
fn ProcessingType::numeric(self : ProcessingType) -> Bool {
  self.base == "integer" || self.base == "float"
}

///|
fn ProcessingType::describe(self : ProcessingType) -> Json {
  {
    "base_type": self.base,
    "cardinality": match self.cardinality {
      Single => "single"
      Multiple => "multiple"
      Ordered => "ordered"
    },
  }
}

///|
fn ProcessingProgram::declaration(
  self : ProcessingProgram,
  id : String,
) -> ProcessingDeclaration? {
  self.declarations.filter(d => d.identifier == id).get(0)
}

///|
/// Declaration metadata intentionally omits authored correct/default values.
pub fn ProcessingProgram::describe(self : ProcessingProgram) -> Json {
  Json(
    self.declarations.map(d => {
      let metadata = d.kind.describe()
      if metadata is Object(fields) {
        fields["identifier"] = Json(d.identifier)
        fields["role"] = Json(if d.response { "response" } else { "outcome" })
        if !d.response {
          fields["external_scoring"] = Json(d.external_scored is Some(_))
          if d.external_scored is Some(mode) {
            fields["external_scored"] = Json(mode)
          }
        }
      }
      metadata
    }),
  )
}
