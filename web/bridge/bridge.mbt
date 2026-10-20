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
  items : Map[Int32, @qti.Item]
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
    let item = @qti.compile_item(xml)
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
