///|
pub fn evaluate(xml : String, response : String) -> String {
  @qti.evaluate_json(xml, response)
}

///|
pub fn describe(xml : String) -> String {
  @qti.describe_json(xml)
}

///|
pub fn explain(xml : String, response : String) -> String {
  @qti.explain_json(xml, response)
}

///|
priv struct CompiledItems {
  items : Map[Int32, @qti.AssessmentItem]
  mut next_id : Int32
}

///|
let compiled : CompiledItems = { items: Map([]), next_id: 1, }

///|
fn handle_error(code : String, message : String) -> String {
  let result : Json = {
    "ok": false,
    "error": { "code": code, "message": message, "location": Json::null() },
  }
  result.stringify()
}

///|
/// Bounded, explicit lifetimes. Failed compilation never consumes a handle.
pub fn compile(xml : String) -> String {
  if compiled.items.length() >= 256 || compiled.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 256 live compiled items; dispose unused items",
    )
  }
  let result : Json = try {
    let item = @qti.compile_assessment_item(xml)
    let handle = compiled.next_id
    compiled.next_id += 1
    compiled.items[handle] = item
    { "ok": true, "handle": handle, "item": item.describe() }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn describe_compiled(handle : Int32) -> String {
  guard compiled.items.get(handle) is Some(item) else {
    return handle_error(
      "invalid_handle", "compiled item is unavailable or disposed",
    )
  }
  let result : Json = { "ok": true, "item": item.describe() }
  result.stringify()
}

///|
pub fn score_compiled(handle : Int32, response : String) -> String {
  guard compiled.items.get(handle) is Some(item) else {
    return handle_error(
      "invalid_handle", "compiled item is unavailable or disposed",
    )
  }
  let result : Json = { "ok": true, "result": item.score_json(response) } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn explain_compiled(handle : Int32, response : String) -> String {
  guard compiled.items.get(handle) is Some(item) else {
    return handle_error(
      "invalid_handle", "compiled item is unavailable or disposed",
    )
  }
  let result : Json = try {
    let explanation = item.explain_json(response)
    { "ok": true, "result": explanation.result, "steps": explanation.steps }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
/// Idempotent release; handles are never recycled onto another item.
pub fn release(handle : Int32) -> Bool {
  let existed = compiled.items.contains(handle)
  compiled.items.remove(handle)
  existed
}

///|
priv struct Packages {
  items : Map[Int32, @qti.ContentPackage]
  mut next_id : Int32
}

///|
let packages : Packages = { items: Map([]), next_id: 1, }

///|
pub fn import_package(bytes : Bytes) -> String {
  if packages.items.length() >= 4 || packages.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 4 live packages; dispose unused packages",
    )
  }
  let result : Json = try {
    let bundle = @qti.read_content_package(bytes)
    let handle = packages.next_id
    packages.next_id += 1
    packages.items[handle] = bundle
    { "ok": true, "handle": handle }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn describe_package(handle : Int32) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  let result : Json = { "ok": true, "package": bundle.describe() }
  result.stringify()
}

///|
pub fn package_item(handle : Int32, resource_id : String) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  if compiled.items.length() >= 256 || compiled.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 256 live compiled items; dispose unused items",
    )
  }
  let result : Json = try {
    let item = bundle.assessment_item(resource_id)
    let item_handle = compiled.next_id
    compiled.next_id += 1
    compiled.items[item_handle] = item
    { "ok": true, "handle": item_handle }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn package_files(handle : Int32, resource_id : String) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  let result : Json = {
    "ok": true,
    "files": bundle.resource_files(resource_id),
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn package_file(handle : Int32, path : String) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  let result : Json = try {
    let bytes = bundle.read_file(path)
    { "ok": true, "base64": @base64.encode(bytes[:]) }
  } catch {
    e => { "ok": false, "error": e }
  }
  result.stringify()
}

///|
pub fn release_package(handle : Int32) -> Bool {
  let existed = packages.items.contains(handle)
  packages.items.remove(handle)
  existed
}

///|
pub fn score_package_attempts(handle : Int32, jsonl : String) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  let result : Json = try {
    let report = bundle.score_attempts_jsonl(jsonl)
    {
      "ok": true,
      "report": report,
      "csv": report.to_csv(),
      "items_csv": report.items_csv(),
    }
  } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
priv struct TestPlans {
  items : Map[Int32, @qti.AssessmentTest]
  mut next_id : Int32
}

///|
priv struct TestSessions {
  items : Map[Int32, @qti.TestSession]
  mut next_id : Int32
}

///|
let tests : TestPlans = { items: Map([]), next_id: 1, }

///|
let sessions : TestSessions = { items: Map([]), next_id: 1, }

///|
pub fn package_test(handle : Int32, resource_id : String) -> String {
  package_test_seeded(handle, resource_id, 0)
}

///|
pub fn package_test_seeded(
  handle : Int32,
  resource_id : String,
  seed : Int32,
) -> String {
  guard packages.items.get(handle) is Some(bundle) else {
    return handle_error("invalid_handle", "package is unavailable or disposed")
  }
  if tests.items.length() >= 16 || tests.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 16 live compiled tests; dispose unused tests",
    )
  }
  let result : Json = try {
    let plan = bundle.compile_test(resource_id, seed~)
    let handle = tests.next_id
    tests.next_id += 1
    tests.items[handle] = plan
    { "ok": true, "handle": handle }
  } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
pub fn describe_test(handle : Int32) -> String {
  guard tests.items.get(handle) is Some(plan) else {
    return handle_error("invalid_handle", "test is unavailable or disposed")
  }
  let result : Json = { "ok": true, "test": plan.describe() }
  result.stringify()
}

///|
pub fn release_test(handle : Int32) -> Bool {
  let existed = tests.items.contains(handle)
  tests.items.remove(handle)
  existed
}

///|
pub fn start_test_session(
  handle : Int32,
  identifier : String,
  now : Double,
) -> String {
  guard tests.items.get(handle) is Some(plan) else {
    return handle_error("invalid_handle", "test is unavailable or disposed")
  }
  if sessions.items.length() >= 16 || sessions.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 16 live test sessions; dispose unused sessions",
    )
  }
  let result : Json = try {
    let session = plan.new_session(identifier, now~)
    let handle = sessions.next_id
    sessions.next_id += 1
    sessions.items[handle] = session
    { "ok": true, "handle": handle }
  } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
pub fn restore_test_session(handle : Int32, snapshot : String) -> String {
  guard tests.items.get(handle) is Some(plan) else {
    return handle_error("invalid_handle", "test is unavailable or disposed")
  }
  if sessions.items.length() >= 16 || sessions.next_id == 2147483647 {
    return handle_error(
      "limit_exceeded", "at most 16 live test sessions; dispose unused sessions",
    )
  }
  let result : Json = try {
    let session = plan.restore_session(snapshot)
    let handle = sessions.next_id
    sessions.next_id += 1
    sessions.items[handle] = session
    { "ok": true, "handle": handle }
  } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
pub fn describe_test_session(handle : Int32) -> String {
  guard sessions.items.get(handle) is Some(session) else {
    return handle_error(
      "invalid_handle", "test session is unavailable or disposed",
    )
  }
  let result : Json = { "ok": true, "session": session.describe() }
  result.stringify()
}

///|
pub fn act_test_session(handle : Int32, action : String) -> String {
  guard sessions.items.get(handle) is Some(session) else {
    return handle_error(
      "invalid_handle", "test session is unavailable or disposed",
    )
  }
  let result : Json = { "ok": true, "session": session.act_json(action) } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
pub fn snapshot_test_session(handle : Int32) -> String {
  guard sessions.items.get(handle) is Some(session) else {
    return handle_error(
      "invalid_handle", "test session is unavailable or disposed",
    )
  }
  let result : Json = { "ok": true, "snapshot": session.snapshot() }
  result.stringify()
}

///|
pub fn export_test_session(
  handle : Int32,
  datestamp : String,
  candidate : String,
) -> String {
  guard sessions.items.get(handle) is Some(session) else {
    return handle_error(
      "invalid_handle", "test session is unavailable or disposed",
    )
  }
  let result : Json = try {
    let report = session.report(datestamp, candidate_identifier=candidate)
    { "ok": true, "report": report, "xml": @qti.assessment_result_xml(report) }
  } catch {
    error => { "ok": false, "error": error }
  }
  result.stringify()
}

///|
pub fn release_test_session(handle : Int32) -> Bool {
  let existed = sessions.items.contains(handle)
  sessions.items.remove(handle)
  existed
}
