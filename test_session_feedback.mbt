///|
// Only accepted outcome-processing boundaries update the live feedback scope.
// Saving drafts and replaying a describe call do not evaluate author rules.
fn TestSession::feedback_processed(self : TestSession) -> Unit {
  self.feedback_part_identifier = Some(
    self.plan.parts[self.part_index].identifier,
  )
}

///|
fn TestSession::feedback_healthy(self : TestSession) -> Bool {
  self.test_processing_error is None &&
  !self.states.any(state => state.grading_error is Some(_))
}

///|
fn TestSession::close_part_feedback(self : TestSession, now : Double) -> Unit {
  let part = self.plan.parts[self.part_index]
  if !self.entered_scopes.contains(part.identifier) ||
    self.part_feedback.any(group => {
      group is { "part_identifier": String(id), .. } && id == part.identifier
    }) {
    return
  }
  let feedback = if self.feedback_healthy() {
    test_visible_feedback(
      self.plan.feedback,
      "part",
      part.identifier,
      "atEnd",
      self.test_outcomes,
    )
  } else {
    []
  }
  self.part_feedback.push({
    "part_identifier": part.identifier,
    "title": part.title,
    "completed_at": now,
    "feedback": feedback,
  })
}

///|
fn TestSession::feedback_description(self : TestSession) -> Json {
  let during : Array[Json] = []
  let at_end : Array[Json] = []
  if self.feedback_healthy() {
    if self.completed {
      at_end.append(
        test_visible_feedback(
          self.plan.feedback,
          "test",
          self.plan.identifier,
          "atEnd",
          self.test_outcomes,
        ),
      )
    } else if self.feedback_part_identifier is Some(last_part) {
      during.append(
        test_visible_feedback(
          self.plan.feedback,
          "test",
          self.plan.identifier,
          "during",
          self.test_outcomes,
        ),
      )
      let part = self.plan.parts[self.part_index]
      if part.identifier == last_part &&
        self.entered_scopes.contains(part.identifier) {
        during.append(
          test_visible_feedback(
            self.plan.feedback,
            "part",
            part.identifier,
            "during",
            self.test_outcomes,
          ),
        )
      }
    }
  }
  {
    "during": during,
    "completed_parts": session_clone(Json(self.part_feedback)),
    "at_end": at_end,
  }
}
