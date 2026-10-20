///|
fn main {
  let args = @env.args()
  // Node keeps both the runtime and script prefix; other targets keep argv[0].
  let offset = if args.length() > 1 && args[1].has_suffix(".js") {
    2
  } else {
    1
  }
  if args.length() <= offset ||
    args[offset] == "--help" ||
    args[offset] == "help" {
    println(
      "QTI Score 0.2.0\n  describe ITEM.xml\n  score ITEM.xml RESPONSE.json\n  explain ITEM.xml RESPONSE.json\n  batch ITEM.xml RESPONSES.jsonl\n\nResponses: {\"RESPONSE\": \"A\"}, {\"RESPONSE\": [\"A\",\"B\"]}, {\"RESPONSE\": 100.5}, or {\"RESPONSE\": null}\nExplain is an explicit developer diagnostic and may reveal scoring rules.",
    )
    return
  }
  let command = args[offset]
  let expected = if command == "describe" { 2 } else { 3 }
  if !["describe", "score", "explain", "batch"].contains(command) ||
    args.length() != offset + expected {
    println(
      "{\"ok\":false,\"error\":{\"code\":\"usage\",\"message\":\"Use --help for command syntax\"}}",
    )
    @sys.exit(2)
    return
  }
  try {
    let item = @qti.compile_item(@fs.read_file_to_string(args[offset + 1]))
    if command == "describe" {
      let result : Json = { "ok": true, "item": item.describe() }
      println(result.stringify())
    } else {
      let input = @fs.read_file_to_string(args[offset + 2])
      if command == "explain" {
        let explanation = item.explain_json(input)
        let result : Json = {
          "ok": true,
          "item": item.describe(),
          "result": explanation.result,
          "steps": explanation.steps,
        }
        println(result.stringify())
      } else if command == "score" {
        let score = item.score_json(input)
        let result : Json = {
          "ok": true,
          "item": item.describe(),
          "result": score,
        }
        println(result.stringify())
      } else {
        let mut failed = false
        let mut line = 0
        for raw in input.split("\n") {
          line += 1
          if raw.trim() == "" {
            continue
          }
          let result : Json = {
            "ok": true,
            "line": line,
            "result": item.score_json(raw.to_owned()),
          } catch {
            e => {
              failed = true
              { "ok": false, "line": line, "error": e }
            }
          }
          println(result.stringify())
        }
        if failed {
          @sys.exit(1)
        }
      }
    }
  } catch {
    @qti.InvalidXml(_, _, _)
    | @qti.InvalidItem(_, _)
    | @qti.Unsupported(_, _)
    | @qti.InvalidResponse(_)
    | @qti.LimitExceeded(_) as e => {
      let error : Json = { "ok": false, "error": e }
      println(error.stringify())
      @sys.exit(1)
    }
    _ => {
      println(
        "{\"ok\":false,\"error\":{\"code\":\"io_error\",\"message\":\"Could not read input file\"}}",
      )
      @sys.exit(1)
    }
  }
}
