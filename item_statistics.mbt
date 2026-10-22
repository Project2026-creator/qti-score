///|
/// Observed submissions grouped by validated resource identifier, in first-seen
/// order. Failed rows never become zero scores. Statistics include successful
/// unanswered rows and authored negative scores. No unsubmitted items are added.
/// matches_correct counts compare standard responses, not pass/fail decisions.
pub struct ItemSummary {
  resource_id : String
  row_count : Int32
  scored_count : Int32
  error_count : Int32
  answered_count : Int32
  unanswered_count : Int32
  matched_count : Int32
  unmatched_count : Int32
  unclassified_count : Int32
  score_mean : Double?
  score_min : Double?
  score_max : Double?
} derive(Debug)

///|
fn summarize_resource(id : String, rows : Array[BatchRow]) -> ItemSummary {
  let scores : Array[Double] = []
  let mut answered = 0
  let mut matched = 0
  let mut unmatched = 0
  let mut scale = 0.0
  let mut minimum = 0.0
  let mut maximum = 0.0
  for row in rows {
    if row.result is Some(result) {
      if scores.is_empty() {
        minimum = result.score
        maximum = result.score
      }
      scores.push(result.score)
      if result.score < minimum {
        minimum = result.score
      }
      if result.score > maximum {
        maximum = result.score
      }
      if result.score.abs() > scale {
        scale = result.score.abs()
      }
      if result.status == Answered {
        answered += 1
      }
      match result.matches_correct {
        Some(true) => matched += 1
        Some(false) => unmatched += 1
        None => ()
      }
    }
  }
  // Scale before adding: the ordinary sum can overflow for finite scores.
  // Clamp rounding at both stages so the mean stays in the observed range.
  let mean = if scores.is_empty() {
    None
  } else if scale == 0.0 {
    Some(0.0)
  } else {
    let mut normalized = 0.0
    for score in scores {
      normalized += score / scale
    }
    let mut fraction = normalized / scores.length().to_double()
    if fraction > 1.0 {
      fraction = 1.0
    }
    if fraction < -1.0 {
      fraction = -1.0
    }
    let mut value = fraction * scale
    if value < minimum {
      value = minimum
    }
    if value > maximum {
      value = maximum
    }
    Some(value)
  }
  let count = scores.length()
  {
    resource_id: id,
    row_count: rows.length(),
    scored_count: count,
    error_count: rows.length() - count,
    answered_count: answered,
    unanswered_count: count - answered,
    matched_count: matched,
    unmatched_count: unmatched,
    unclassified_count: count - matched - unmatched,
    score_mean: mean,
    score_min: if count > 0 {
      Some(minimum)
    } else {
      None
    },
    score_max: if count > 0 {
      Some(maximum)
    } else {
      None
    },
  }
}

///|
/// Return fresh per-resource statistics. Rows without a validated resource ID
/// remain visible in rows() but cannot be assigned to an item summary.
pub fn BatchReport::items(self : BatchReport) -> Array[ItemSummary] {
  let groups : Map[String, Array[BatchRow]] = Map([])
  for row in self.entries {
    if row.resource_id is Some(id) {
      if groups.get(id) is Some(rows) {
        rows.push(row)
      } else {
        groups[id] = [row]
      }
    }
  }
  let summaries : Array[ItemSummary] = []
  for id, rows in groups {
    summaries.push(summarize_resource(id, rows))
  }
  summaries
}

///|
pub impl ToJson for ItemSummary with fn to_json(self) {
  {
    "resource_id": self.resource_id,
    "row_count": self.row_count,
    "scored_count": self.scored_count,
    "error_count": self.error_count,
    "answered_count": self.answered_count,
    "unanswered_count": self.unanswered_count,
    "matched_count": self.matched_count,
    "unmatched_count": self.unmatched_count,
    "unclassified_count": self.unclassified_count,
    "score_mean": batch_nullable(self.score_mean),
    "score_min": batch_nullable(self.score_min),
    "score_max": batch_nullable(self.score_max),
  }
}

///|
/// Observed item statistics with CRLF endings and the same spreadsheet text
/// protection as to_csv(). No raw responses or scoring rules are exported.
pub fn BatchReport::items_csv(self : BatchReport) -> String {
  let lines = [
    "resource_id,row_count,scored_count,error_count,answered_count,unanswered_count,matched_count,unmatched_count,unclassified_count,score_mean,score_min,score_max",
  ]
  for item in self.items() {
    lines.push(
      [
        csv_text(item.resource_id),
        item.row_count.to_string(),
        item.scored_count.to_string(),
        item.error_count.to_string(),
        item.answered_count.to_string(),
        item.unanswered_count.to_string(),
        item.matched_count.to_string(),
        item.unmatched_count.to_string(),
        item.unclassified_count.to_string(),
        item.score_mean.map(n => n.to_string()).unwrap_or(""),
        item.score_min.map(n => n.to_string()).unwrap_or(""),
        item.score_max.map(n => n.to_string()).unwrap_or(""),
      ].join(","),
    )
  }
  lines.join("\r\n") + "\r\n"
}

///|
pub extend ItemSummary with ToJson::{to_json}

///|
pub extend ItemSummary with Debug::{to_repr}
