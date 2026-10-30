///|
priv struct SessionEntry {
  mut response : Json
  mut submitted : Bool
  mut dirty : Bool
  mut attempts : Int32
  mut duration : Double
  mut result : Score?
  mut outcomes : Json
  mut feedback : Json
  mut grading_error : QtiError?
  mut submitted_response : Json
  mut submission_index : Int32
}

///|
/// One candidate's mutable run. Compiled tests are shared; responses are isolated.
pub struct TestSession {
  session_identifier : String
  priv plan : AssessmentTest
  priv states : Array[SessionEntry]
  priv events : Array[Json]
  priv mut event_characters : Int32
  priv started_at : Double
  priv mut last_time : Double
  priv mut current : Int32
  priv mut part_index : Int32
  priv mut part_elapsed : Double
  priv mut paused : Bool
  priv mut completed : Bool
  priv mut timed_out : Bool
  priv mut test_outcomes : Json
  priv mut test_processing_error : QtiError?
  priv mut submission_count : Int32
}

///|
fn session_clone(value : Json) -> Json {
  @json.parse(value.stringify()[:], preserve_number_repr=true) catch {
    _ => abort("cannot clone a valid JSON value")
  }
}

///|
fn session_number(value : Json, key : String) -> Double raise QtiError {
  guard value is Object(fields) &&
    fields.get(key) is Some(Number(n, ..)) &&
    !n.is_nan() &&
    !n.is_inf() &&
    n >= 0 else {
    raise InvalidResponse("expected finite nonnegative '\{key}'")
  }
  n
}

///|
fn session_string(value : Json, key : String) -> String raise QtiError {
  guard value is Object(fields) && fields.get(key) is Some(String(text)) else {
    raise InvalidResponse("expected string '\{key}'")
  }
  text
}

///|
pub fn AssessmentTest::new_session(
  self : AssessmentTest,
  session_identifier : String,
  now~ : Double = 0.0,
) -> TestSession raise QtiError {
  ignore(identifier(session_identifier, "session"))
  if session_identifier.length() > 256 {
    raise LimitExceeded("session identifier exceeds 256 characters")
  }
  if now.is_nan() || now.is_inf() || now < 0 {
    raise InvalidResponse("invalid session clock")
  }
  if self.entries.is_empty() || self.parts.is_empty() {
    raise InvalidItem("test", "test has no items")
  }
  {
    session_identifier,
    plan: self,
    states: self.entries.map(_ => {
      response: Json::object({}),
      submitted: false,
      dirty: false,
      attempts: 0,
      duration: 0.0,
      result: None,
      outcomes: Json::object({}),
      feedback: Json::array([]),
      grading_error: None,
      submitted_response: Json::object({}),
      submission_index: 0,
    }),
    events: [],
    event_characters: 0,
    started_at: now,
    last_time: now,
    current: 0,
    part_index: 0,
    part_elapsed: 0.0,
    paused: false,
    completed: false,
    timed_out: false,
    test_outcomes: Json::object({}),
    test_processing_error: None,
    submission_count: 0,
  }
}

///|
fn TestSession::touch(self : TestSession, now : Double) -> Unit {
  let mut elapsed = if self.paused || self.completed {
    0.0
  } else {
    now - self.last_time
  }
  if self.plan.parts[self.part_index].max_time is Some(limit) {
    elapsed = elapsed.min((limit - self.part_elapsed).max(0.0))
  }
  self.states[self.current].duration += elapsed
  self.part_elapsed += elapsed
  self.last_time = now
}

///|
fn session_answered(value : Json) -> Bool {
  match value {
    Object(fields) =>
      fields
      .values()
      .any(v => {
        match v {
          Null => false
          String(s) => s != ""
          Array(xs) => !xs.is_empty()
          _ => true
        }
      })
    _ => false
  }
}

///|
fn TestSession::can_write(self : TestSession) -> Unit raise QtiError {
  let state = self.states[self.current]
  let control = self.plan.entries[self.current].control
  if state.submitted &&
    control.max_attempts != 0 &&
    state.attempts >= control.max_attempts {
    raise InvalidResponse("item does not allow another attempt")
  }
}

///|
fn TestSession::review_blocked(self : TestSession, index : Int32) -> Bool {
  let state = self.states[index]
  let control = self.plan.entries[index].control
  state.submitted &&
  !control.allow_review &&
  control.max_attempts != 0 &&
  state.attempts >= control.max_attempts
}

///|
fn TestSession::evaluate_test_outcomes(
  self : TestSession,
  overrides : Map[Int32, Json],
) -> Json raise QtiError {
  guard self.plan.processing is Some(program) else { return Json::object({}) }
  let items : Array[Json] = []
  let mut submission_index = self.submission_count
  for i, entry in self.plan.entries {
    let state = self.states[i]
    let changed = overrides.contains(i)
    if changed {
      submission_index += 1
    }
    let part = self.plan.parts.filter(p => p.identifier == entry.part_identifier)[0]
    items.push({
      "identifier": entry.source_identifier,
      "instance_identifier": entry.identifier,
      "instance_index": entry.instance_index,
      "sequence_index": i + 1,
      "outcomes": overrides.get(i).unwrap_or(state.outcomes),
      "response": session_result_response(
        entry.item,
        if changed {
          state.response
        } else {
          state.submitted_response
        },
      ),
      "submitted": changed || state.submitted,
      "submission_index": if changed {
        submission_index
      } else {
        state.submission_index
      },
      "submission_mode": if part.submission_mode == Simultaneous {
        "simultaneous"
      } else {
        "individual"
      },
      "categories": entry.categories.copy(),
      "section_identifiers": entry.section_identifiers.copy(),
      "weights": Json(entry.weights),
      "response_types": entry.item.response_types_json(),
      "outcome_types": entry.item.outcome_types_json(),
    })
  }
  program.evaluate_json({ "items": items })
}

///|
fn TestSession::null_test_outcomes(self : TestSession) -> Json {
  let outcomes : Map[String, Json] = Map([])
  if self.plan.processing is Some(program) &&
    processing_types(program.describe(), "outcome") is Object(types) {
    for id, _ in types {
      outcomes[id] = Json::null()
    }
  }
  Json::object(outcomes)
}

///|
fn TestSession::commit_current(self : TestSession) -> Unit raise QtiError {
  let state = self.states[self.current]
  if state.submitted && !state.dirty {
    return
  }
  self.can_write()
  let entry = self.plan.entries[self.current]
  let input = state.response.stringify()
  entry.item.validate_json(input)
  let outcomes = entry.item.outcomes_json(input)
  let result = if session_external_scoring(entry.item) {
    None
  } else if outcomes is { "SCORE": Null, .. } {
    raise InvalidResponse(
      "SCORE is NULL; response processing did not produce a grade",
    )
  } else {
    Some(entry.item.score_json(input))
  }
  let feedback = entry.item.feedback_json(input)
  let test_outcomes = self.evaluate_test_outcomes(
    Map([(self.current, outcomes)]),
  )
  state.result = result
  state.outcomes = outcomes
  state.feedback = feedback
  state.attempts += 1
  state.submitted = true
  state.dirty = false
  state.submitted_response = session_clone(state.response)
  self.submission_count += 1
  state.submission_index = self.submission_count
  self.test_outcomes = test_outcomes
  self.test_processing_error = None
}

///|
fn TestSession::finish_part(
  self : TestSession,
  now : Double,
  force~ : Bool = false,
) -> Unit raise QtiError {
  let part = self.plan.parts[self.part_index]
  // Prepare all results before changing any item state: a failure is atomic.
  let prepared : Array[(Int32, Score?, Json, Json, QtiError?)] = []
  for i in part.start..<(part.start + part.count) {
    let entry = self.plan.entries[i]
    let state = self.states[i]
    if !force &&
      !entry.control.allow_skipping &&
      !session_answered(state.response) {
      raise InvalidResponse("item '\{entry.identifier}' cannot be skipped")
    }
    if part.submission_mode == Individual && state.dirty && !force {
      raise InvalidResponse(
        "submit saved responses before finishing an individual part",
      )
    }
    if !state.submitted || state.dirty {
      let input = state.response.stringify()
      try {
        entry.item.validate_json(input)
        let outcomes = entry.item.outcomes_json(input)
        if session_external_scoring(entry.item) ||
          outcomes is { "SCORE": Null, .. } {
          prepared.push(
            (
              i,
              None,
              outcomes,
              entry.item.feedback_json(input),
              if session_external_scoring(entry.item) {
                None
              } else {
                Some(InvalidResponse("SCORE is NULL; grading incomplete"))
              },
            ),
          )
        } else {
          prepared.push(
            (
              i,
              Some(entry.item.score_json(input)),
              outcomes,
              entry.item.feedback_json(input),
              None,
            ),
          )
        }
      } catch {
        InvalidResponse(_) as error => {
          if !force &&
            (session_answered(state.response) || !entry.control.allow_skipping) {
            raise error
          }
          prepared.push(
            (i, None, Json::object({}), Json::array([]), Some(error)),
          )
        }
        error => raise error
      }
    }
  }
  let overrides : Map[Int32, Json] = Map([])
  for (i, _, outcomes, _, _) in prepared {
    overrides[i] = outcomes
  }
  let mut processing_error : QtiError? = None
  let test_outcomes = self.evaluate_test_outcomes(overrides) catch {
    error => {
      if !force {
        raise error
      }
      processing_error = Some(error)
      self.null_test_outcomes()
    }
  }
  self.touch(now)
  for (i, result, outcomes, feedback, error) in prepared {
    let state = self.states[i]
    state.result = result
    state.outcomes = outcomes
    state.feedback = feedback
    state.grading_error = error
    if session_answered(state.response) {
      state.attempts += 1
    }
    state.submitted = true
    state.dirty = false
    state.submitted_response = session_clone(state.response)
    self.submission_count += 1
    state.submission_index = self.submission_count
  }
  self.test_outcomes = test_outcomes
  self.test_processing_error = processing_error
  if self.part_index + 1 >= self.plan.parts.length() {
    self.completed = true
  } else {
    self.part_index += 1
    self.current = self.plan.parts[self.part_index].start
    self.part_elapsed = 0.0
  }
}

///|
/// Apply a timestamped action. Saving never executes response processing.
/// Supported types: save, submit, next, select, finish_part, pause, resume, tick.
pub fn TestSession::act_json(
  self : TestSession,
  input : String,
) -> Json raise QtiError {
  if input.length() > 1048576 {
    raise LimitExceeded("session action is too large")
  }
  let action = @json.parse(
    input[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=20,
  ) catch {
    _ => raise InvalidResponse("malformed session action JSON")
  }
  guard action is Object(fields) else {
    raise InvalidResponse("expected session action object")
  }
  for key, _ in fields {
    if !["type", "time", "response", "identifier"].contains(key) {
      raise InvalidResponse("unknown session action field '\{key}'")
    }
  }
  let kind = session_string(action, "type")
  let now = session_number(action, "time")
  if now < self.last_time {
    raise InvalidResponse("session clock cannot move backwards")
  }
  if self.events.length() >= 10000 {
    raise LimitExceeded("session action limit exceeded")
  }
  let action_characters = action.stringify().length() + 1
  if self.event_characters + action_characters > 7340032 {
    raise LimitExceeded("session history exceeds the restorable snapshot limit")
  }
  if self.completed {
    raise InvalidResponse("test session is complete")
  }
  if self.paused && kind != "resume" {
    raise InvalidResponse("test session is paused")
  }
  let part = self.plan.parts[self.part_index]
  let expired = !self.paused &&
    (match part.max_time {
      Some(limit) => self.part_elapsed + (now - self.last_time) >= limit
      None => false
    })
  if expired {
    if kind != "tick" {
      raise InvalidResponse(
        "part time limit reached; use tick to finalize saved responses",
      )
    }
    self.finish_part(now, force=true)
    self.timed_out = true
    self.events.push(session_clone(action))
    self.event_characters += action_characters
    return self.describe()
  }
  match kind {
    "save" => {
      self.can_write()
      guard fields.get("response") is Some(Object(_) as response) else {
        raise InvalidResponse("save requires a response object")
      }
      self.plan.entries[self.current].item.validate_json(response.stringify())
      self.touch(now)
      let state = self.states[self.current]
      if state.response.stringify() != response.stringify() {
        state.response = session_clone(response)
        state.dirty = true
      }
    }
    "submit" => {
      if part.submission_mode != Individual {
        raise InvalidResponse(
          "simultaneous parts are submitted with finish_part",
        )
      }
      if !self.plan.entries[self.current].control.allow_skipping &&
        !session_answered(self.states[self.current].response) {
        raise InvalidResponse("current item cannot be skipped")
      }
      self.commit_current()
      self.touch(now)
    }
    "next" => {
      let entry = self.plan.entries[self.current]
      let state = self.states[self.current]
      if !entry.control.allow_skipping && !session_answered(state.response) {
        raise InvalidResponse("current item cannot be skipped")
      }
      if part.submission_mode == Individual && state.dirty {
        raise InvalidResponse("submit current response before moving")
      }
      if self.current + 1 >= part.start + part.count {
        raise InvalidResponse("last item in part; use finish_part")
      }
      if self.review_blocked(self.current + 1) {
        raise InvalidResponse("item review is disabled")
      }
      self.touch(now)
      self.current += 1
    }
    "select" => {
      if part.navigation_mode != Nonlinear {
        raise InvalidResponse(
          "linear navigation does not allow selecting another item",
        )
      }
      if !self.plan.entries[self.current].control.allow_skipping &&
        !session_answered(self.states[self.current].response) {
        raise InvalidResponse("current item cannot be skipped")
      }
      let id = session_string(action, "identifier")
      let mut found = -1
      for i in part.start..<(part.start + part.count) {
        if self.plan.entries[i].identifier == id {
          found = i
        }
      }
      if found < 0 {
        raise InvalidResponse("unknown item reference in active part")
      }
      if self.review_blocked(found) {
        raise InvalidResponse("item review is disabled")
      }
      if part.submission_mode == Individual && self.states[self.current].dirty {
        raise InvalidResponse("submit current response before moving")
      }
      self.touch(now)
      self.current = found
    }
    "finish_part" => self.finish_part(now)
    "pause" => {
      self.touch(now)
      self.paused = true
    }
    "resume" => {
      if !self.paused {
        raise InvalidResponse("session is not paused")
      }
      self.touch(now)
      self.paused = false
    }
    "tick" => self.touch(now)
    _ => raise InvalidResponse("unknown session action '\{kind}'")
  }
  self.events.push(session_clone(action))
  self.event_characters += action_characters
  self.describe()
}

///|
pub fn TestSession::describe(self : TestSession) -> Json {
  let entry = self.plan.entries[self.current]
  let state = self.states[self.current]
  let visible = state.submitted &&
    !state.dirty &&
    entry.control.show_feedback &&
    state.grading_error is None
  let result : Json = if visible {
    match state.result {
      Some(r) => r.to_json()
      None => Json::null()
    }
  } else {
    Json::null()
  }
  let summaries : Array[Json] = []
  for i, item in self.plan.entries {
    summaries.push({
      "identifier": item.identifier,
      "part_identifier": item.part_identifier,
      "submitted": self.states[i].submitted,
      "answered": session_answered(self.states[i].response),
      "dirty": self.states[i].dirty,
      "num_attempts": self.states[i].attempts,
    })
  }
  {
    "test_identifier": self.plan.identifier,
    "session_identifier": self.session_identifier,
    "completed": self.completed,
    "paused": self.paused,
    "timed_out": self.timed_out,
    "part_identifier": self.plan.parts[self.part_index].identifier,
    "part_elapsed": self.part_elapsed,
    "current": {
      "identifier": entry.identifier,
      "item": entry.item.describe(),
      "response": session_clone(state.response),
      "submitted": state.submitted,
      "dirty": state.dirty,
      "num_attempts": state.attempts,
      "result": result,
      "feedback": if visible {
        session_clone(state.feedback)
      } else {
        Json::array([])
      },
    },
    "items": summaries,
  }
}

///|
/// Versioned action history; restoring replays validated actions, never saved scores.
pub fn TestSession::snapshot(self : TestSession) -> String {
  let value : Json = {
    "format": "qti-score-test-session-v2",
    "test_identity": self.plan.identity(),
    "assembly_seed": self.plan.assembly_seed,
    "session_identifier": self.session_identifier,
    "started_at": self.started_at,
    "actions": self.events,
  }
  value.stringify()
}

///|
pub fn AssessmentTest::restore_session(
  self : AssessmentTest,
  snapshot : String,
) -> TestSession raise QtiError {
  if snapshot.length() > 8388608 {
    raise LimitExceeded("session snapshot is too large")
  }
  let data = @json.parse(
    snapshot[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=24,
  ) catch {
    _ => raise InvalidResponse("malformed session snapshot")
  }
  if session_string(data, "format") != "qti-score-test-session-v2" ||
    session_string(data, "test_identity") != self.identity() {
    raise InvalidResponse("snapshot belongs to a different test or version")
  }
  if session_number(data, "assembly_seed") != self.assembly_seed.to_double() {
    raise InvalidResponse(
      "snapshot assembly seed differs from the compiled test",
    )
  }
  let session = self.new_session(
    session_string(data, "session_identifier"),
    now=session_number(data, "started_at"),
  )
  guard data is Object(fields) && fields.get("actions") is Some(Array(actions)) else {
    raise InvalidResponse("snapshot requires actions")
  }
  if actions.length() > 10000 {
    raise LimitExceeded("snapshot action limit exceeded")
  }
  for action in actions {
    ignore(session.act_json(action.stringify()))
  }
  session
}

///|
pub fn TestSession::report(
  self : TestSession,
  datestamp : String,
  candidate_identifier~ : String = "anonymous",
) -> Json raise QtiError {
  if !self.completed {
    raise InvalidResponse("complete the test before exporting its result")
  }
  let items : Array[Json] = []
  for i, entry in self.plan.entries {
    let state = self.states[i]
    items.push({
      "identifier": entry.source_identifier,
      "instance_identifier": entry.identifier,
      "instance_index": entry.instance_index,
      "item_identifier": entry.item.identifier(),
      "sequence_index": i + 1,
      "session_status": if state.grading_error is Some(_) {
        "pendingResponseProcessing"
      } else if state.result is None {
        "pendingExternalScoring"
      } else {
        "final"
      },
      "num_attempts": state.attempts,
      "duration": state.duration,
      "processing_error": match state.grading_error {
        Some(error) => error.to_json()
        None => Json::null()
      },
      "response": session_result_response(entry.item, state.response),
      "outcomes": session_clone(state.outcomes),
      "response_types": entry.item.response_types_json(),
      "outcome_types": entry.item.outcome_types_json(),
    })
  }
  let has_errors = self.test_processing_error is Some(_) ||
    self.states.any(state => state.grading_error is Some(_))
  let all_items_scored = !self.states.any(state => state.result is None)
  let outcomes = session_clone(self.test_outcomes)
  let types = match self.plan.processing {
    None => Json::object({})
    Some(program) => processing_types(program.describe(), "outcome")
  }
  {
    "test_identifier": self.plan.identifier,
    "session_identifier": self.session_identifier,
    "candidate_identifier": candidate_identifier,
    "datestamp": datestamp,
    "completed": true,
    "has_errors": has_errors,
    "test_processing_error": match self.test_processing_error {
      Some(error) => error.to_json()
      None => Json::null()
    },
    "all_items_scored": all_items_scored,
    "items": items,
    "outcomes": outcomes,
    "test_outcome_types": types,
  }
}

///|
fn session_external_scoring(item : AssessmentItem) -> Bool {
  item.describe() is { "external_scoring": True, .. }
}

///|
fn session_result_value(value : Json, base : String) -> Json raise QtiError {
  match value {
    Null => Json::null()
    String(text) if text == "" ||
      ((base == "integer" || base == "float") && text.trim() == "") =>
      Json::null()
    String(text) if base == "integer" || base == "float" => {
      let number = @string.parse_double(text.trim()) catch {
        _ => raise InvalidResponse("invalid numeric result response")
      }
      Json(number)
    }
    String(text) if base == "directedPair" => Json(directed_pair(text))
    Array(values) if values.is_empty() => Json::null()
    Array(values) => Json::array(values.map(v => session_result_value(v, base)))
    _ => session_clone(value)
  }
}

///|
fn session_result_response(
  item : AssessmentItem,
  response : Json,
) -> Json raise QtiError {
  let result : Map[String, Json] = Map([])
  if response is Object(fields) && item.response_types_json() is Object(types) {
    for id, spec in types {
      if spec is { "base_type": String(base), .. } {
        result[id] = session_result_value(
          fields.get(id).unwrap_or(Json::null()),
          base,
        )
      }
    }
  }
  Json::object(result)
}

///|
fn processing_types(declarations : Json, role : String) -> Json {
  let result : Map[String, Json] = Map([])
  if declarations is Array(entries) {
    for declaration in entries {
      if declaration
        is {
          "identifier": String(id),
          "role": String(kind),
          "base_type": String(base),
          "cardinality": String(card),
          ..
        } &&
        kind == role {
        result[id] = { "base_type": base, "cardinality": card }
      }
    }
  }
  Json::object(result)
}

///|
pub fn TestSession::result_xml(
  self : TestSession,
  datestamp : String,
  candidate_identifier~ : String = "anonymous",
) -> String raise QtiError {
  assessment_result_xml(self.report(datestamp, candidate_identifier~))
}
