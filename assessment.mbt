///|
/// Unified host entry point. Existing Item APIs retain single-response meaning.
pub(all) enum AssessmentItem {
  Single(Item)
  Composite(CompositeItem)
  Processed(ProcessedItem)
} derive(Debug)

///|
pub extend AssessmentItem with Debug::{to_repr}

///|
pub fn compile_assessment_item(
  xml : String,
  limits~ : Limits = Limits::default(),
) -> AssessmentItem raise QtiError {
  let root = parse_document(xml, limits)
  if !processing_nodes(root, "qti-printed-variable").is_empty() ||
    !processing_nodes(root, "qti-feedback-inline").is_empty() ||
    !processing_nodes(root, "qti-feedback-block").is_empty() {
    return Processed(compile_processed_item(xml, limits~))
  }
  try {
    if root.children
      .filter(n => n.name() == "qti-response-declaration")
      .length() >
      1 {
      Composite(compile_composite_root(root))
    } else {
      Single(compile_single_root(root))
    }
  } catch {
    legacy_error => {
      let item = compile_processed_item(xml, limits~) catch {
        _ => raise legacy_error
      }
      Processed(item)
    }
  }
}

///|
pub fn AssessmentItem::identifier(self : AssessmentItem) -> String {
  match self {
    Single(item) => item.identifier
    Composite(item) => item.identifier
    Processed(item) => item.identifier()
  }
}

///|
pub fn AssessmentItem::describe(self : AssessmentItem) -> Json {
  match self {
    Single(item) => item.describe()
    Composite(item) => item.describe()
    Processed(item) => item.describe()
  }
}

///|
fn AssessmentItem::describe_outcomes(
  self : AssessmentItem,
  outcomes : Json,
  allow_feedback~ : Bool = true,
) -> Json {
  match self {
    Processed(item) => item.describe_outcomes(outcomes, allow_feedback~)
    _ => self.describe()
  }
}

///|
/// Evaluate an explicit submission and return its rendered content and feedback.
/// Session hosts use accepted stored outcomes instead of evaluating drafts.
pub fn AssessmentItem::presentation_json(
  self : AssessmentItem,
  input : String,
) -> Json raise QtiError {
  let outcomes = self.outcomes_json(input)
  {
    "item": self.describe_outcomes(outcomes),
    "outcomes": outcomes,
    "feedback": self.feedback_json(input),
  }
}

///|
pub fn AssessmentItem::score_json(
  self : AssessmentItem,
  response : String,
) -> Score raise QtiError {
  match self {
    Single(item) => item.score_json(response)
    Composite(item) => item.score_json(response)
    Processed(item) => item.score_json(response)
  }
}

///|
pub fn AssessmentItem::explain_json(
  self : AssessmentItem,
  response : String,
) -> Explanation raise QtiError {
  match self {
    Single(item) => item.explain_json(response)
    Composite(item) => item.explain_json(response)
    Processed(item) => item.explain_json(response)
  }
}
