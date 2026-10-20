///|
fn[T : ToJson] batch_nullable(value : T?) -> Json {
  match value {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
pub impl ToJson for BatchRow with fn to_json(self) {
  {
    "line": self.line,
    "attempt_id": batch_nullable(self.attempt_id),
    "resource_id": batch_nullable(self.resource_id),
    "item_id": batch_nullable(self.item_id),
    "ok": self.result is Some(_),
    "result": batch_nullable(self.result),
    "error": batch_nullable(self.error),
  }
}

///|
pub impl ToJson for AttemptSummary with fn to_json(self) {
  {
    "attempt_id": self.attempt_id,
    "row_count": self.row_count,
    "scored_count": self.scored_count,
    "error_count": self.error_count,
    "answered_count": self.answered_count,
    "unanswered_count": self.unanswered_count,
    "all_rows_scored": self.all_rows_scored,
    "score_sum": batch_nullable(self.score_sum),
    "sum_error": batch_nullable(self.sum_error),
  }
}

///|
pub impl ToJson for BatchReport with fn to_json(self) {
  {
    "package_identifier": self.package_identifier,
    "row_count": self.row_count,
    "attempt_count": self.attempt_count,
    "scored_count": self.scored_count,
    "error_count": self.error_count,
    "answered_count": self.answered_count,
    "unanswered_count": self.unanswered_count,
    "unassigned_count": self.unassigned_count,
    "has_errors": self.has_errors,
    "rows": self.entries,
    "attempts": self.summaries,
  }
}

///|
// Quote text fields and double embedded quotes. Text beginning with formula
// introducers (including after whitespace) is prefixed for spreadsheet use.
fn csv_text(value : String) -> String {
  let trimmed = value.trim()
  let formula = trimmed.has_prefix("=") ||
    trimmed.has_prefix("+") ||
    trimmed.has_prefix("-") ||
    trimmed.has_prefix("@") ||
    trimmed.has_prefix("＝") ||
    trimmed.has_prefix("＋") ||
    trimmed.has_prefix("－") ||
    trimmed.has_prefix("＠") ||
    value.has_prefix("\t") ||
    value.has_prefix("\r") ||
    value.has_prefix("\n")
  let safe = if formula { "'" + value } else { value }
  "\"" + safe.replace_all(old="\""[:], new="\"\""[:]) + "\""
}

///|
/// CSV detail rows in input order, with a fixed header and CRLF endings.
/// Text cells have spreadsheet formula prefixes neutralized. JSON retains the
/// original identities. No BOM is added; UTF-8 encoding is the host's job.
pub fn BatchReport::to_csv(self : BatchReport) -> String {
  let lines = [
    "line,attempt_id,resource_id,item_id,ok,score,status,matches_correct,error_code,error_message,error_line,error_column",
  ]
  for row in self.entries {
    let fields = [
      row.line.to_string(),
      csv_text(row.attempt_id.unwrap_or("")),
      csv_text(row.resource_id.unwrap_or("")),
      csv_text(row.item_id.unwrap_or("")),
      (row.result is Some(_)).to_string(),
    ]
    match row.result {
      Some(result) => {
        fields.push(result.score.to_string())
        fields.push(
          match result.status {
            Answered => "answered"
            Unanswered => "unanswered"
          },
        )
        fields.push(
          result.matches_correct.map(value => value.to_string()).unwrap_or(""),
        )
      }
      None => {
        fields.push("")
        fields.push("")
        fields.push("")
      }
    }
    match row.error {
      Some(error) => {
        fields.push(csv_text(error.code()))
        fields.push(csv_text(error.message()))
        fields.push(error.location().map(p => p.line.to_string()).unwrap_or(""))
        fields.push(
          error.location().map(p => p.column.to_string()).unwrap_or(""),
        )
      }
      None => {
        fields.push("")
        fields.push("")
        fields.push("")
        fields.push("")
      }
    }
    lines.push(fields.join(","))
  }
  lines.join("\r\n") + "\r\n"
}

///|
pub extend BatchRow with ToJson::{to_json}

///|
pub extend AttemptSummary with ToJson::{to_json}

///|
pub extend BatchReport with ToJson::{to_json}
