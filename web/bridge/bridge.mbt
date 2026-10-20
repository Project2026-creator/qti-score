///|
pub fn evaluate(xml : String, response : String) -> String {
  @qti.evaluate_json(xml, response)
}

///|
pub fn describe(xml : String) -> String {
  @qti.describe_json(xml)
}
