///|
/// Errors distinguish malformed XML, invalid items, unsupported QTI, and invalid
/// learner responses. Line and column numbers in XML errors are one-based.
pub(all) suberror QtiError {
  InvalidXml(String, Int32, Int32)
  InvalidItem(String, String)
  InvalidPackage(String, String)
  Unsupported(String, String)
  InvalidResponse(String)
  LimitExceeded(String)
} derive(Debug, Eq)

///|
pub(all) enum Cardinality {
  Single
  Multiple
  Ordered
} derive(Debug, Eq)

///|
pub(all) enum BaseType {
  Identifier
  Text
  Integer
  Float
} derive(Debug, Eq)

///|
pub(all) enum Template {
  MatchCorrect
  MapResponse
  NumericRules
} derive(Debug, Eq)

///|
/// The caller supplies the cardinality explicitly. Empty strings and empty
/// multiple/ordered containers become QTI NULL; nonempty text is never trimmed.
pub(all) enum Response {
  Null
  Single(String)
  Multiple(Array[String])
  Ordered(Array[String])
  Number(Double)
} derive(Debug, Eq)

///|
pub(all) enum ResponseStatus {
  Unanswered
  Answered
} derive(Debug, Eq)

///|
/// `matches_correct` is exact match for identifiers/strings and exact numeric
/// equality for numbers, independent of mapping or tolerance credit. It is
/// None when the author did not provide a correct response.
pub struct Score {
  score : Double
  status : ResponseStatus
  matches_correct : Bool?
} derive(Debug, Eq)

///|
/// Limits are measured before and during XML parsing, in UTF-16 code units,
/// element nesting levels and element count respectively.
pub(all) struct Limits {
  max_characters : Int32
  max_depth : Int32
  max_elements : Int32
} derive(Debug, Eq)

///|
pub fn Limits::default() -> Limits {
  { max_characters: 1048576, max_depth: 128, max_elements: 30000, }
}

///|
pub struct Choice {
  identifier : String
  text : String
} derive(Debug, Eq)

///|
priv struct MapEntry {
  key : String
  folded_key : String
  value : Double
  case_sensitive : Bool
  source : SourceLocation
} derive(Debug)

///|
priv struct Mapping {
  entries : Array[MapEntry]
  default_value : Double
  lower_bound : Double?
  upper_bound : Double?
  source : SourceLocation
} derive(Debug)

///|
/// A compiled item is immutable to consumers. Its arrays are exposed only as
/// copies, so callers cannot accidentally change a compiled scoring rule.
pub struct Item {
  identifier : String
  title : String
  response_identifier : String
  cardinality : Cardinality
  base_type : BaseType
  template : Template
  prompt : String
  min_choices : Int32
  max_choices : Int32
  priv choices : Array[Choice]
  priv correct : Array[String]?
  priv mapping : Mapping?
  priv numeric_rule : NumericRule?
  priv processing_source : SourceLocation
} derive(Debug)

///|
pub struct SourceLocation {
  line : Int32
  column : Int32
} derive(Debug, Eq, ToJson)

///|
/// Developer diagnostics, returned only by explicit explain calls. Details may
/// reveal authored scoring rules and must not be sent to a learner by default.
pub struct ScoringStep {
  operation : String
  location : SourceLocation
  details : Json
} derive(Debug, ToJson)

///|
pub struct Explanation {
  result : Score
  steps : Array[ScoringStep]
} derive(Debug, ToJson)

///|
pub fn Item::choices(self : Item) -> Array[Choice] {
  self.choices.copy()
}

///|
pub fn Item::correct_response(self : Item) -> Array[String]? {
  self.correct.map(xs => xs.copy())
}

///|
pub extend QtiError with Eq::{equal, not_equal}

///|
pub extend QtiError with Debug::{to_repr}

///|
pub extend QtiError with ToJson::{to_json}

///|
pub extend Cardinality with Eq::{equal, not_equal}

///|
pub extend Cardinality with Debug::{to_repr}

///|
pub extend BaseType with Eq::{equal, not_equal}

///|
pub extend BaseType with Debug::{to_repr}

///|
pub extend Template with Eq::{equal, not_equal}

///|
pub extend Template with Debug::{to_repr}

///|
pub extend Response with Eq::{equal, not_equal}

///|
pub extend Response with Debug::{to_repr}

///|
pub extend ResponseStatus with Eq::{equal, not_equal}

///|
pub extend ResponseStatus with Debug::{to_repr}

///|
pub extend Score with Eq::{equal, not_equal}

///|
pub extend Score with Debug::{to_repr}

///|
pub extend Score with ToJson::{to_json}

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub extend Limits with Debug::{to_repr}

///|
pub extend Choice with Eq::{equal, not_equal}

///|
pub extend Choice with Debug::{to_repr}

///|
pub extend Item with Debug::{to_repr}

///|
pub extend SourceLocation with Eq::{equal, not_equal}

///|
pub extend SourceLocation with Debug::{to_repr}

///|
pub extend SourceLocation with ToJson::{to_json}

///|
pub extend ScoringStep with Debug::{to_repr}

///|
pub extend ScoringStep with ToJson::{to_json}

///|
pub extend Explanation with Debug::{to_repr}

///|
pub extend Explanation with ToJson::{to_json}
