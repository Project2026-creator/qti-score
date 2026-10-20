///|
/// One nonblank input line. Exactly one of result/error is present. Identity
/// fields are absent when the input could not be validated safely.
pub struct BatchRow {
  line : Int32
  attempt_id : String?
  resource_id : String?
  item_id : String?
  result : Score?
  error : QtiError?
} derive(Debug)

///|
/// score_sum includes successful submitted rows only. It is absent when there
/// are no successful rows or when sequential Double addition overflows.
/// all_rows_scored does not mean a test is complete: omitted items are unknown.
pub struct AttemptSummary {
  attempt_id : String
  row_count : Int32
  scored_count : Int32
  error_count : Int32
  answered_count : Int32
  unanswered_count : Int32
  all_rows_scored : Bool
  score_sum : Double?
  sum_error : QtiError?
} derive(Debug)

///|
/// Immutable report of one batch. Rows and summaries are returned as copies;
/// no raw response objects, author answers or explanation traces are attached.
pub struct BatchReport {
  package_identifier : String
  row_count : Int32
  attempt_count : Int32
  scored_count : Int32
  error_count : Int32
  answered_count : Int32
  unanswered_count : Int32
  unassigned_count : Int32
  has_errors : Bool
  priv entries : Array[BatchRow]
  priv summaries : Array[AttemptSummary]
}

///|
pub fn BatchReport::rows(self : BatchReport) -> Array[BatchRow] {
  self.entries.copy()
}

///|
pub fn BatchReport::attempts(self : BatchReport) -> Array[AttemptSummary] {
  self.summaries.copy()
}

///|
pub extend BatchRow with Debug::{to_repr}

///|
pub extend AttemptSummary with Debug::{to_repr}
