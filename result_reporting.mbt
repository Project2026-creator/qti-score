///|
let result_reporting_namespace = "http://www.imsglobal.org/xsd/imsqti_result_v3p0"

///|
fn rr_error(message : String) -> QtiError {
  InvalidResponse("result report: " + message)
}

///|
fn rr_object(value : Json, label : String) -> Map[String, Json] raise QtiError {
  guard value is Object(fields) else {
    raise rr_error(label + " must be an object")
  }
  fields
}

///|
fn rr_field(fields : Map[String, Json], key : String) -> Json raise QtiError {
  match fields.get(key) {
    Some(value) => value
    None => raise rr_error("missing '" + key + "'")
  }
}

///|
fn rr_string(value : Json, label : String) -> String raise QtiError {
  guard value is String(text) else {
    raise rr_error(label + " must be a string")
  }
  if text.length() > 65536 {
    raise LimitExceeded("result report string exceeds 65536 UTF-16 code units")
  }
  text
}

///|
fn rr_id(value : Json, label : String) -> String raise QtiError {
  let text = rr_string(value, label)
  if text.length() > 256 {
    raise LimitExceeded("result report identifier exceeds 256 code units")
  }
  identifier(text, "result report " + label)
}

///|
fn rr_number(value : Json, label : String) -> Double raise QtiError {
  guard value is Number(number, ..) && !number.is_nan() && !number.is_inf() else {
    raise rr_error(label + " must be a finite number")
  }
  number
}

///|
fn rr_integer(value : Json, label : String) -> String raise QtiError {
  let number = rr_number(value, label)
  if number < -9007199254740991.0 ||
    number > 9007199254740991.0 ||
    number.to_int64().to_double() != number {
    raise rr_error(label + " must be an exact JSON integer")
  }
  number.to_int64().to_string()
}

///|
fn rr_escape(text : String) -> String raise QtiError {
  let out = StringBuilder()
  for c in text.iter() {
    let n = c.to_int()
    if !(n == 9 ||
      n == 10 ||
      n == 13 ||
      (n >= 32 && n <= 0xD7FF) ||
      (n >= 0xE000 && n <= 0xFFFD) ||
      (n >= 0x10000 && n <= 0x10FFFF)) {
      raise rr_error("text contains a character forbidden by XML 1.0")
    }
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      '\t' => out.write_string("&#x9;")
      '\n' => out.write_string("&#xA;")
      '\r' => out.write_string("&#xD;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn rr_decimal(text : String) -> Int32 raise QtiError {
  if text.is_empty() || !text.iter().all(c => c >= '0' && c <= '9') {
    raise rr_error("datestamp must use UTC YYYY-MM-DDThh:mm:ss[.fraction]Z")
  }
  @string.parse_int(text[:]) catch {
    _ => raise rr_error("invalid datestamp decimal component")
  }
}

///|
fn rr_datestamp(value : Json) -> String raise QtiError {
  let text = rr_string(value, "datestamp")
  if text.length() < 20 ||
    text.length() > 30 ||
    text[4:5] != "-" ||
    text[7:8] != "-" ||
    text[10:11] != "T" ||
    text[13:14] != ":" ||
    text[16:17] != ":" ||
    !text.has_suffix("Z") {
    raise rr_error("datestamp must use UTC YYYY-MM-DDThh:mm:ss[.fraction]Z")
  }
  let year = rr_decimal(text[0:4].to_owned())
  let month = rr_decimal(text[5:7].to_owned())
  let day = rr_decimal(text[8:10].to_owned())
  let hour = rr_decimal(text[11:13].to_owned())
  let minute = rr_decimal(text[14:16].to_owned())
  let second = rr_decimal(text[17:19].to_owned())
  if year < 1 ||
    month < 1 ||
    month > 12 ||
    hour > 23 ||
    minute > 59 ||
    second > 59 {
    raise rr_error("datestamp has an invalid calendar or time component")
  }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days = [
    31,
    if leap {
      29
    } else {
      28
    },
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ]
  if day < 1 || day > days[month - 1] {
    raise rr_error("datestamp has an invalid calendar day")
  }
  if text.length() > 20 {
    if text[19:20] != "." || text.length() == 21 {
      raise rr_error("invalid fractional seconds in datestamp")
    }
    ignore(rr_decimal(text[20:text.length() - 1].to_owned()))
  }
  text
}

///|
fn rr_scalar(value : Json, base_type : String) -> String raise QtiError {
  match base_type {
    "string" => rr_escape(rr_string(value, "string value"))
    "identifier" => rr_escape(rr_id(value, "identifier value"))
    "directedPair" => {
      let pair = rr_string(value, "directedPair value").split(" ").to_array()
      if pair.length() != 2 {
        raise rr_error(
          "directedPair must contain two identifiers separated by one space",
        )
      }
      rr_id(Json(pair[0]), "directedPair source") +
      " " +
      rr_id(Json(pair[1]), "directedPair target")
    }
    "integer" => rr_integer(value, "integer value")
    "float" => rr_number(value, "float value").to_string()
    "boolean" =>
      match value {
        True => "true"
        False => "false"
        _ => raise rr_error("boolean value must be true or false")
      }
    _ => raise Unsupported("result report", "base type '" + base_type + "'")
  }
}

///|
fn rr_values(
  value : Json,
  base_type : String,
  cardinality : String,
) -> String raise QtiError {
  if value is Null ||
    (
      cardinality == "single" &&
      (base_type == "string" || base_type == "identifier") &&
      value is String("")
    ) {
    return ""
  }
  let values = if cardinality == "single" {
    [value]
  } else {
    guard value is Array(values) else {
      raise rr_error("multiple and ordered variables require arrays or null")
    }
    if values.length() > 4096 {
      raise LimitExceeded("result variable exceeds 4096 values")
    }
    values
  }
  let parts : Array[String] = []
  let mut length = 0
  for value in values {
    let part = "<value>" + rr_scalar(value, base_type) + "</value>"
    length += part.length()
    if length > 1048576 {
      raise LimitExceeded("result variable exceeds 1048576 XML code units")
    }
    parts.push(part)
  }
  parts.join("")
}

///|
fn rr_variable(
  name : String,
  value : Json,
  declaration : Json,
  response~ : Bool,
) -> String raise QtiError {
  ignore(rr_id(Json(name), "variable identifier"))
  let definition = rr_object(declaration, "variable declaration")
  let base_type = rr_string(rr_field(definition, "base_type"), "base_type")
  if !["identifier", "string", "integer", "float", "boolean", "directedPair"].contains(
      base_type,
    ) {
    raise Unsupported("result report", "base type '" + base_type + "'")
  }
  let cardinality = rr_string(
    rr_field(definition, "cardinality"),
    "cardinality",
  )
  if !["single", "multiple", "ordered"].contains(cardinality) {
    raise Unsupported("result report", "cardinality '" + cardinality + "'")
  }
  let values = rr_values(value, base_type, cardinality)
  let tag = if response { "responseVariable" } else { "outcomeVariable" }
  let body = if response {
    "<candidateResponse>" + values + "</candidateResponse>"
  } else {
    values
  }
  "<" +
  tag +
  " identifier=\"" +
  name +
  "\" cardinality=\"" +
  cardinality +
  "\" baseType=\"" +
  base_type +
  "\">" +
  body +
  "</" +
  tag +
  ">"
}

///|
fn rr_variables(
  values : Json,
  declarations : Json,
  response~ : Bool,
) -> String raise QtiError {
  let values = rr_object(values, "variable values")
  let types = rr_object(declarations, "variable declarations")
  if types.length() > 128 || values.length() > 128 {
    raise LimitExceeded(
      "result report supports at most 128 variables per scope",
    )
  }
  for name, _ in values {
    if !types.contains(name) {
      raise rr_error("undeclared result variable '" + name + "'")
    }
  }
  let names = types.keys().to_array()
  names.sort()
  let parts : Array[String] = []
  let mut length = 0
  for name in names {
    let part = rr_variable(
      name,
      values.get(name).unwrap_or(Json::null()),
      types[name],
      response~,
    )
    length += part.length()
    if length > 2097152 {
      raise LimitExceeded(
        "result variable scope exceeds 2097152 XML code units",
      )
    }
    parts.push(part)
  }
  parts.join("")
}

///|
fn rr_builtin(
  name : String,
  value : Json,
  base_type : String,
) -> String raise QtiError {
  let declaration : Json = { "base_type": base_type, "cardinality": "single" }
  rr_variable(name, value, declaration, response=true)
}

///|
/// Export a session report as QTI 3 Results Reporting XML (Candidate Final,
/// 2022-11-01). The host supplies UTC `datestamp`; no wall clock is read.
///
/// Required root fields: test_identifier, session_identifier, datestamp, items,
/// outcomes, test_outcome_types. Each item requires identifier (ItemRef ID),
/// sequence_index (one-based), session_status, num_attempts, duration (seconds),
/// response, response_types, outcomes and outcome_types. Optional
/// candidate_identifier is an anonymous ASCII NCName, not a display name.
///
/// Supports single/multiple/ordered identifier, string, integer, float, boolean
/// and directedPair variables. QTI NULL is the absence of value elements.
/// Declaration keys determine exported variables; answers, mappings, and traces
/// are never copied. Record/file/point/pair/URI variables are rejected.
pub fn assessment_result_xml(report : Json) -> String raise QtiError {
  let fields = rr_object(report, "report")
  let test_id = rr_id(rr_field(fields, "test_identifier"), "test_identifier")
  let session_id = rr_id(
    rr_field(fields, "session_identifier"),
    "session_identifier",
  )
  let datestamp = rr_datestamp(rr_field(fields, "datestamp"))
  let candidate = match fields.get("candidate_identifier") {
    None | Some(Null) => ""
    Some(value) => " sourcedId=\"" + rr_id(value, "candidate_identifier") + "\""
  }
  let test_variables = rr_variables(
    rr_field(fields, "outcomes"),
    rr_field(fields, "test_outcome_types"),
    response=false,
  )
  guard rr_field(fields, "items") is Array(items) else {
    raise rr_error("items must be an array")
  }
  if items.length() > 512 {
    raise LimitExceeded("result report supports at most 512 item results")
  }
  let parts = [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<assessmentResult xmlns=\"" +
    result_reporting_namespace +
    "\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"" +
    result_reporting_namespace +
    " https://purl.imsglobal.org/spec/qti/v3p0/schema/xsd/imsqti_resultv3p0_v1p0.xsd\">",
    "<context" +
    candidate +
    "><sessionIdentifier sourceID=\"https://github.com/Project2026-creator/qti-score\" identifier=\"" +
    session_id +
    "\"/></context>",
    "<testResult identifier=\"" +
    test_id +
    "\" datestamp=\"" +
    datestamp +
    "\">" +
    test_variables +
    "</testResult>",
  ]
  let positions : Map[String, Bool] = Map([])
  let mut length = test_variables.length() + 1024
  for item in items {
    let item = rr_object(item, "item result")
    let item_id = rr_id(rr_field(item, "identifier"), "item identifier")
    let sequence = rr_integer(
      rr_field(item, "sequence_index"),
      "sequence_index",
    )
    if rr_number(rr_field(item, "sequence_index"), "sequence_index") < 1 {
      raise rr_error("sequence_index must be one-based")
    }
    if positions.contains(sequence) {
      raise rr_error("duplicate sequence_index")
    }
    positions[sequence] = true
    // Selection with replacement creates multiple instances of one ItemRef.
    // Keep the authored identifier; sequenceIndex disambiguates its instances.
    let status = rr_string(rr_field(item, "session_status"), "session_status")
    if ![
        "initial", "pendingSubmission", "pendingResponseProcessing", "pendingExternalScoring",
        "final",
      ].contains(status) {
      raise rr_error("unknown item session_status")
    }
    let attempts = rr_field(item, "num_attempts")
    ignore(rr_integer(attempts, "num_attempts"))
    let attempt_count = rr_number(attempts, "num_attempts")
    if attempt_count < 0 || (status == "initial" && attempt_count != 0) {
      raise rr_error(
        "num_attempts must be nonnegative and initial sessions require zero attempts",
      )
    }
    let duration = rr_field(item, "duration")
    if rr_number(duration, "duration") < 0 {
      raise rr_error("duration seconds must be nonnegative")
    }
    let response_types = rr_object(
      rr_field(item, "response_types"),
      "response_types",
    )
    let outcome_types = rr_object(
      rr_field(item, "outcome_types"),
      "outcome_types",
    )
    if response_types.contains("numAttempts") ||
      response_types.contains("duration") ||
      outcome_types.contains("numAttempts") ||
      outcome_types.contains("duration") {
      raise rr_error(
        "numAttempts and duration are reserved built-in response variables",
      )
    }
    for name, _ in response_types {
      if outcome_types.contains(name) {
        raise rr_error(
          "response and outcome variables must have distinct identifiers",
        )
      }
    }
    let responses = rr_variables(
      rr_field(item, "response"),
      rr_field(item, "response_types"),
      response=true,
    )
    let outcomes = rr_variables(
      rr_field(item, "outcomes"),
      rr_field(item, "outcome_types"),
      response=false,
    )
    let part = "<itemResult identifier=\"" +
      item_id +
      "\" sequenceIndex=\"" +
      sequence +
      "\" datestamp=\"" +
      datestamp +
      "\" sessionStatus=\"" +
      status +
      "\">" +
      rr_builtin("numAttempts", attempts, "integer") +
      rr_builtin("duration", duration, "float") +
      responses +
      outcomes +
      "</itemResult>"
    length += part.length()
    if length > 8388608 {
      raise LimitExceeded("result report exceeds 8388608 XML code units")
    }
    parts.push(part)
  }
  parts.push("</assessmentResult>\n")
  parts.join("")
}
