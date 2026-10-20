///|
priv struct PendingAttempt {
  line : Int32
  attempt_id : String?
  resource_id : String?
  response : Json?
  error : QtiError?
}

///|
fn batch_identity(value : Json?, limit : Int32) -> String? {
  guard value is Some(String(id)) else { return None }
  if id == "" ||
    id.length() > limit ||
    id.trim() != id ||
    id.iter().any(c => c < ' ' || (c >= '\u007f' && c <= '\u009f')) {
    None
  } else {
    Some(id)
  }
}

///|
fn parse_attempt(raw : String, line : Int32) -> PendingAttempt {
  let mut attempt_id = None
  let mut resource_id = None
  let outcome : Result[Json, QtiError] = try {
    if raw.length() > 1048576 {
      raise LimitExceeded("batch line exceeds 1048576 UTF-16 code units")
    }
    let parsed = @json.parse(
      raw[:],
      max_nesting_depth=16,
      reject_duplicate_keys=true,
      preserve_number_repr=true,
    ) catch {
      _ => raise InvalidResponse("malformed attempt JSON")
    }
    guard parsed is Object(fields) else {
      raise InvalidResponse("attempt must be a JSON object")
    }
    attempt_id = batch_identity(fields.get("attempt_id"), 256)
    resource_id = batch_identity(fields.get("resource_id"), 4096)
    for key, _ in fields {
      if !["attempt_id", "resource_id", "response"].contains(key) {
        raise InvalidResponse("unknown attempt member '\{key}'")
      }
    }
    if attempt_id is None {
      raise InvalidResponse(
        "attempt_id must be 1..256 code units, without edge whitespace or control characters",
      )
    }
    if resource_id is None {
      raise InvalidResponse(
        "resource_id must be 1..4096 code units, without edge whitespace or control characters",
      )
    }
    guard fields.get("response") is Some(Object(_) as response) else {
      raise InvalidResponse(
        "response must be a JSON object; use {} for no response",
      )
    }
    Ok(response)
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(response) =>
      { line, attempt_id, resource_id, response: Some(response), error: None, }
    Err(error) =>
      { line, attempt_id, resource_id, response: None, error: Some(error), }
  }
}

///|
fn summarize_attempt(id : String, rows : Array[BatchRow]) -> AttemptSummary {
  let mut scored = 0
  let mut answered = 0
  let mut sum = 0.0
  let mut sum_error : QtiError? = None
  for row in rows {
    if row.result is Some(result) {
      scored += 1
      if result.status == Answered {
        answered += 1
      }
      if sum_error is None {
        sum += result.score
        if sum.is_nan() || sum.is_inf() {
          sum_error = Some(
            LimitExceeded("successful row score sum is not finite"),
          )
        }
      }
    }
  }
  {
    attempt_id: id,
    row_count: rows.length(),
    scored_count: scored,
    error_count: rows.length() - scored,
    answered_count: answered,
    unanswered_count: scored - answered,
    all_rows_scored: scored == rows.length(),
    score_sum: if scored > 0 && sum_error is None {
      Some(sum)
    } else {
      None
    },
    sum_error,
  }
}

///|
/// Score JSONL records {attempt_id, resource_id, response} against this package.
/// Blank lines are skipped; original one-based line numbers are retained.
/// All rows sharing a validated (attempt_id, resource_id) pair are rejected.
/// Fatal limits: 4,194,304 UTF-16 code units and 4096 nonblank rows. Other input
/// and scoring errors stay on their row and do not stop unrelated attempts.
pub fn ContentPackage::score_attempts_jsonl(
  self : ContentPackage,
  jsonl : String,
) -> BatchReport raise QtiError {
  if jsonl.length() > 4194304 {
    raise LimitExceeded("batch JSONL exceeds 4194304 UTF-16 code units")
  }
  let pending : Array[PendingAttempt] = []
  let occurrences : Map[(String, String), Int32] = Map([])
  let mut line = 0
  for raw in jsonl.split("\n") {
    line += 1
    let text = if line == 1 {
      raw.strip_prefix("\uFEFF").unwrap_or(raw)
    } else {
      raw
    }
    if text.trim() == "" {
      continue
    }
    if pending.length() >= 4096 {
      raise LimitExceeded("batch exceeds 4096 nonblank rows")
    }
    let parsed = parse_attempt(text.to_owned(), line)
    pending.push(parsed)
    if parsed.attempt_id is Some(attempt) &&
      parsed.resource_id is Some(resource) {
      let key = (attempt, resource)
      occurrences[key] = occurrences.get(key).unwrap_or(0) + 1
    }
  }
  let entries : Array[BatchRow] = []
  let groups : Map[String, Array[BatchRow]] = Map([])
  let mut scored = 0
  let mut answered = 0
  let mut unassigned = 0
  for parsed in pending {
    let mut item_id = None
    let outcome : Result[Score, QtiError] = try {
      if parsed.attempt_id is Some(attempt) &&
        parsed.resource_id is Some(resource) &&
        occurrences[(attempt, resource)] > 1 {
        raise InvalidResponse(
          "duplicate attempt_id/resource_id pair; every occurrence is rejected",
        )
      }
      if parsed.error is Some(error) {
        raise error
      }
      let item = self.item(parsed.resource_id.unwrap())
      item_id = Some(item.identifier)
      Ok(item.score_json(parsed.response.unwrap().stringify()))
    } catch {
      error => Err(error)
    }
    let (result, error) = match outcome {
      Ok(score) => {
        scored += 1
        if score.status == Answered {
          answered += 1
        }
        (Some(score), None)
      }
      Err(error) => (None, Some(error))
    }
    let row : BatchRow = {
      line: parsed.line,
      attempt_id: parsed.attempt_id,
      resource_id: parsed.resource_id,
      item_id,
      result,
      error,
    }
    entries.push(row)
    if row.attempt_id is Some(id) {
      if groups.get(id) is Some(rows) {
        rows.push(row)
      } else {
        groups[id] = [row]
      }
    } else {
      unassigned += 1
    }
  }
  let summaries : Array[AttemptSummary] = []
  for id, rows in groups {
    summaries.push(summarize_attempt(id, rows))
  }
  {
    package_identifier: self.identifier,
    row_count: entries.length(),
    attempt_count: summaries.length(),
    scored_count: scored,
    error_count: entries.length() - scored,
    answered_count: answered,
    unanswered_count: scored - answered,
    unassigned_count: unassigned,
    has_errors: scored != entries.length() ||
    summaries.any(summary => summary.sum_error is Some(_)),
    entries,
    summaries,
  }
}
