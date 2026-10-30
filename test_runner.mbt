///|
/// Replay a timestamped action script through the same runtime used by the SDK.
pub fn AssessmentTest::run_actions_json(
  self : AssessmentTest,
  input : String,
) -> Json raise QtiError {
  if input.length() > 8388608 {
    raise LimitExceeded("test action script is too large")
  }
  let data = @json.parse(
    input[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=24,
  ) catch {
    _ => raise InvalidResponse("malformed test action script")
  }
  guard data is Object(fields) && fields.get("actions") is Some(Array(actions)) else {
    raise InvalidResponse("test action script requires an actions array")
  }
  let session = if fields.get("snapshot") is Some(String(snapshot)) {
    self.restore_session(snapshot)
  } else {
    self.new_session(
      session_string(data, "session_identifier"),
      now=session_number(data, "start_time"),
    )
  }
  for action in actions {
    ignore(session.act_json(action.stringify()))
  }
  let state = session.describe()
  if state is { "completed": True, .. } {
    let datestamp = session_string(data, "datestamp")
    let candidate = match fields.get("candidate_identifier") {
      Some(String(id)) => id
      _ => "anonymous"
    }
    {
      "state": state,
      "snapshot": session.snapshot(),
      "report": session.report(datestamp, candidate_identifier=candidate),
      "xml": session.result_xml(datestamp, candidate_identifier=candidate),
    }
  } else {
    {
      "state": state,
      "snapshot": session.snapshot(),
      "report": Json::null(),
      "xml": Json::null(),
    }
  }
}
