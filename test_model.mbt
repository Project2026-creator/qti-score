///|
/// Navigation within a test part. Test parts themselves retain document order.
pub(all) enum NavigationMode {
  Linear
  Nonlinear
} derive(Debug, Eq)

///|
pub(all) enum SubmissionMode {
  Individual
  Simultaneous
} derive(Debug, Eq)

///|
/// Effective item-session constraints after part/section/item inheritance.
/// A max_attempts value of zero means unlimited attempts.
pub struct ItemSessionControl {
  max_attempts : Int32
  allow_review : Bool
  show_feedback : Bool
  allow_skipping : Bool
  validate_responses : Bool
} derive(Debug, Eq)

///|
/// QTI ASI 3.0.1 ItemSessionControl defaults for non-adaptive items.
pub fn ItemSessionControl::default() -> ItemSessionControl {
  {
    max_attempts: 1,
    allow_review: true,
    show_feedback: false,
    allow_skipping: true,
    validate_responses: false,
  }
}

///|
pub struct TestPart {
  identifier : String
  title : String
  navigation_mode : NavigationMode
  submission_mode : SubmissionMode
  max_time : Double?
  control : ItemSessionControl
  priv start : Int32
  priv count : Int32
} derive(Debug)

///|
pub struct TestEntry {
  identifier : String
  source_identifier : String
  instance_index : Int32
  part_identifier : String
  resource_id : String
  path : String
  control : ItemSessionControl
  priv item : AssessmentItem
  priv section_identifiers : Array[String]
  priv categories : Array[String]
  priv weights : Map[String, Double]
  priv instructions : Array[Json]
} derive(Debug)

///|
/// An assembled test plan with deterministic selection and order.
pub struct AssessmentTest {
  identifier : String
  title : String
  priv parts : Array[TestPart]
  priv entries : Array[TestEntry]
  priv identity : String
  priv processing : ProcessingProgram?
  priv assembly_seed : Int32
  priv candidate_count : Int32
  priv flow : Array[TestFlowScope]
  priv feedback : Array[TestFeedback]
} derive(Debug)

///|
/// Stable binding for persisted sessions; contains no authored rule text.
pub fn AssessmentTest::identity(self : AssessmentTest) -> String {
  self.identity
}

///|
pub fn AssessmentTest::parts(self : AssessmentTest) -> Array[TestPart] {
  self.parts.copy()
}

///|
pub fn AssessmentTest::entries(self : AssessmentTest) -> Array[TestEntry] {
  self.entries.copy()
}

///|
pub fn TestPart::entry_count(self : TestPart) -> Int32 {
  self.count
}

///|
pub fn AssessmentTest::describe(self : AssessmentTest) -> Json {
  let parts : Array[Json] = self.parts.map(part => {
    let max_time : Json = match part.max_time {
      Some(value) => Json(value)
      None => Json::null()
    }
    {
      "identifier": part.identifier,
      "title": part.title,
      "navigation_mode": match part.navigation_mode {
        Linear => "linear"
        Nonlinear => "nonlinear"
      },
      "submission_mode": match part.submission_mode {
        Individual => "individual"
        Simultaneous => "simultaneous"
      },
      "max_time": max_time,
      "entry_count": part.count,
      "control": part.control.describe(),
      "has_feedback": self.feedback.any(block => {
        block.scope == "part" && block.scope_identifier == part.identifier
      }),
      "conditional_navigation": self.flow.any(scope => {
        scope.part_identifier == part.identifier &&
        scope.kind != "part" &&
        (!scope.preconditions.is_empty() || !scope.branches.is_empty())
      }),
    }
  })
  let entries : Array[Json] = self.entries.map(entry => {
    "identifier": entry.identifier,
    "source_identifier": entry.source_identifier,
    "instance_index": entry.instance_index,
    "part_identifier": entry.part_identifier,
    "resource_id": entry.resource_id,
    "path": entry.path,
    "control": entry.control.describe(),
    "item": entry.item.describe(),
    "section_identifiers": entry.section_identifiers.copy(),
    "categories": entry.categories.copy(),
    "weights": Json(entry.weights),
    "instructions": session_clone(Json(entry.instructions)),
  })
  {
    "identifier": self.identifier,
    "title": self.title,
    "parts": parts,
    "entries": entries,
    "item_count": self.entries.length(),
    "outcome_types": self.outcome_types(),
    "assembly_seed": self.assembly_seed,
    "candidate_count": self.candidate_count,
    "has_feedback": !self.feedback.is_empty(),
    "conditional_navigation": self.flow.any(scope => {
      scope.kind != "part" &&
      (!scope.preconditions.is_empty() || !scope.branches.is_empty())
    }),
  }
}

///|
/// Declared test outcomes; authored defaults and processing rules stay private.
pub fn AssessmentTest::outcome_types(self : AssessmentTest) -> Json {
  let types : Map[String, Json] = Map([])
  if self.processing is Some(program) {
    for declaration in program.declarations {
      if !declaration.response {
        types[declaration.identifier] = declaration.kind.describe()
      }
    }
  }
  Json(types)
}

///|
fn ItemSessionControl::describe(self : ItemSessionControl) -> Json {
  {
    "max_attempts": self.max_attempts,
    "allow_review": self.allow_review,
    "show_feedback": self.show_feedback,
    "allow_skipping": self.allow_skipping,
    "validate_responses": self.validate_responses,
  }
}

///|
pub extend NavigationMode with Debug::{to_repr}

///|
pub extend NavigationMode with Eq::{equal, not_equal}

///|
pub extend SubmissionMode with Debug::{to_repr}

///|
pub extend SubmissionMode with Eq::{equal, not_equal}

///|
pub extend ItemSessionControl with Debug::{to_repr}

///|
pub extend ItemSessionControl with Eq::{equal, not_equal}

///|
pub extend TestPart with Debug::{to_repr}

///|
pub extend TestEntry with Debug::{to_repr}

///|
pub extend AssessmentTest with Debug::{to_repr}
