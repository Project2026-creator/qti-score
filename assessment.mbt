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
