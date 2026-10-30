///|
fn TestSession::item_flow(self : TestSession) -> Bool {
  let part_id = self.plan.parts[self.part_index].identifier
  self.plan.flow.any(scope => {
    scope.part_identifier == part_id &&
    scope.kind != "part" &&
    (!scope.preconditions.is_empty() || !scope.branches.is_empty())
  })
}

///|
fn TestSession::flow_scope(self : TestSession, id : String) -> TestFlowScope {
  self.plan.flow.filter(scope => scope.identifier == id)[0]
}

///|
fn TestSession::flow_allowed(
  self : TestSession,
  scope : TestFlowScope,
) -> Bool raise QtiError {
  for predicate in scope.preconditions {
    if !predicate.evaluate(
        self.processing_input(Map([]), initial_outcomes=true),
        self.test_outcomes,
      ) {
      return false
    }
  }
  true
}

///|
fn TestSession::flow_branch(
  self : TestSession,
  scope : TestFlowScope,
) -> String? raise QtiError {
  for branch in scope.branches {
    if branch.predicate.evaluate(
        self.processing_input(Map([]), initial_outcomes=true),
        self.test_outcomes,
      ) {
      return Some(branch.target)
    }
  }
  None
}

///|
fn TestSession::exclude(self : TestSession, start : Int32, end : Int32) -> Unit {
  for i in start..<end {
    if !self.states[i].presented && !self.states[i].submitted {
      self.states[i].skipped = true
    }
  }
}

///|
fn TestSession::flow_target(
  self : TestSession,
  scope : TestFlowScope,
  target : String,
) -> Int32 {
  match target {
    "EXIT_TEST" => self.plan.entries.length()
    "EXIT_TESTPART" => self.flow_scope(scope.part_identifier).end
    "EXIT_SECTION" => self.flow_scope(scope.parent_section.unwrap()).end
    _ => self.flow_scope(target).start
  }
}

///|
fn TestSession::close_sections(self : TestSession, boundary : Int32) -> Unit {
  for scope in self.plan.flow {
    if scope.kind == "section" &&
      scope.end <= boundary &&
      self.entered_scopes.get(scope.identifier) == Some(true) {
      self.entered_scopes[scope.identifier] = false
    }
  }
}

///|
fn TestSession::leave_sections(
  self : TestSession,
  boundary : Int32,
) -> (TestFlowScope, String)? raise QtiError {
  for ;; {
    let mut next : TestFlowScope? = None
    for scope in self.plan.flow {
      if scope.kind == "section" &&
        scope.end <= boundary &&
        self.entered_scopes.get(scope.identifier) == Some(true) {
        match next {
          None => next = Some(scope)
          Some(previous) =>
            if scope.end < previous.end ||
              (scope.end == previous.end && scope.start >= previous.start) {
              next = Some(scope)
            }
        }
      }
    }
    guard next is Some(scope) else { return None }
    self.entered_scopes[scope.identifier] = false
    if self.flow_branch(scope) is Some(target) {
      return Some((scope, target))
    }
  }
}

///|
// Entry gates run from the containing part through the outer/inner sections.
// Once entered, a scope's preconditions are not re-evaluated on every item.
fn TestSession::enter_from(
  self : TestSession,
  target : Int32,
  now : Double,
) -> Unit raise QtiError {
  let mut index = target
  while index < self.plan.entries.length() {
    let mut part_index = 0
    for i, part in self.plan.parts {
      if part.start <= index && index < part.start + part.count {
        part_index = i
      }
    }
    let part = self.plan.parts[part_index]
    if self.part_index != part_index {
      self.part_index = part_index
      self.part_elapsed = 0.0
    }
    let part_scope = self.flow_scope(part.identifier)
    if !self.entered_scopes.contains(part.identifier) {
      if !self.flow_allowed(part_scope) {
        self.exclude(part.start, part.start + part.count)
        index = part.start + part.count
        continue
      }
      self.entered_scopes[part.identifier] = true
    }
    let entry = self.plan.entries[index]
    let scope_ids = entry.section_identifiers + [entry.source_identifier]
    let mut blocked = false
    for id in scope_ids {
      if !self.entered_scopes.contains(id) {
        let scope = self.flow_scope(id)
        if !self.flow_allowed(scope) {
          self.exclude(index, scope.end)
          index = scope.end
          blocked = true
          break
        }
        self.entered_scopes[id] = true
      }
    }
    if blocked {
      if self.leave_sections(index) is Some((scope, branch)) {
        let target = self.flow_target(scope, branch)
        self.exclude(index, target)
        self.close_sections(target)
        if branch == "EXIT_TEST" {
          self.close_part_feedback(now)
          self.completed = true
          return
        }
        index = target
      }
      if index >= part.start + part.count {
        self.finish_part(now)
        return
      }
      continue
    }
    self.current = index
    self.states[index].presented = true
    return
  }
  self.completed = true
}

///|
fn TestSession::finish_part(
  self : TestSession,
  now : Double,
  force~ : Bool = false,
) -> Unit raise QtiError {
  let part = self.plan.parts[self.part_index]
  self.submit_entries(part.start, part.start + part.count, force~)
  self.touch(now)
  self.close_part_feedback(now)
  if self.item_flow() {
    self.exclude(part.start, part.start + part.count)
  }
  let scope = self.flow_scope(part.identifier)
  try {
    let target = match self.flow_branch(scope) {
      Some(branch) => self.flow_target(scope, branch)
      None => part.start + part.count
    }
    self.exclude(part.start + part.count, target)
    self.close_sections(target)
    self.enter_from(target, now)
  } catch {
    error => {
      if !force {
        raise error
      }
      // A forced time-limit close must remain exportable even if a route
      // expression fails. Preserve the diagnostic instead of trapping tick.
      self.test_processing_error = Some(error)
      self.test_outcomes = self.null_test_outcomes()
      self.exclude(part.start, self.plan.entries.length())
      self.completed = true
    }
  }
}

///|
fn TestSession::advance_flow(
  self : TestSession,
  now : Double,
) -> Unit raise QtiError {
  let current = self.current
  let part = self.plan.parts[self.part_index]
  self.submit_entries(current, current + 1)
  let item = self.flow_scope(self.plan.entries[current].source_identifier)
  let mut chosen = self.flow_branch(item)
  let mut owner = item
  if chosen is None {
    if self.leave_sections(current + 1) is Some((section, branch)) {
      chosen = Some(branch)
      owner = section
    }
  }
  let target = match chosen {
    Some(branch) => self.flow_target(owner, branch)
    None => current + 1
  }
  if chosen == Some("EXIT_TEST") {
    self.submit_entries(part.start, part.start + part.count)
    self.touch(now)
    self.close_part_feedback(now)
    self.exclude(current + 1, self.plan.entries.length())
    self.completed = true
  } else if target >= part.start + part.count {
    self.finish_part(now)
  } else {
    self.touch(now)
    self.exclude(current + 1, target)
    self.close_sections(target)
    self.enter_from(target, now)
  }
}

///|
fn session_initial_outcomes(item : AssessmentItem) -> Json {
  match item {
    Processed(processed) => processed.program.initial_outcomes()
    Single(single) => { "SCORE": single.score_default }
    Composite(_) => { "SCORE": 0.0 }
  }
}

///|
// A rejected action must also roll back navigation predicates, clocks, and
// prepared grades. Existing JSON values are immutable throughout actions.
pub fn TestSession::act_json(
  self : TestSession,
  input : String,
) -> Json raise QtiError {
  let states = self.states.map(state => { ..state, response: state.response, })
  let entered : Map[String, Bool] = Map([])
  for id, value in self.entered_scopes {
    entered[id] = value
  }
  let last_time = self.last_time
  let current = self.current
  let part_index = self.part_index
  let part_elapsed = self.part_elapsed
  let paused = self.paused
  let completed = self.completed
  let timed_out = self.timed_out
  let test_outcomes = self.test_outcomes
  let test_processing_error = self.test_processing_error
  let submission_count = self.submission_count
  let feedback_part_identifier = self.feedback_part_identifier
  let part_feedback = self.part_feedback.copy()
  errdefer {
    for i, state in states {
      self.states[i] = state
    }
    self.entered_scopes.clear()
    for id, value in entered {
      self.entered_scopes[id] = value
    }
    self.last_time = last_time
    self.current = current
    self.part_index = part_index
    self.part_elapsed = part_elapsed
    self.paused = paused
    self.completed = completed
    self.timed_out = timed_out
    self.test_outcomes = test_outcomes
    self.test_processing_error = test_processing_error
    self.submission_count = submission_count
    self.feedback_part_identifier = feedback_part_identifier
    self.part_feedback.clear()
    self.part_feedback.append(part_feedback)
  }
  self.apply_json(input)
}
