///|
fn main {
  let args = @env.args()
  let version = "0.18.0"
  // Node keeps both the runtime and script prefix; other targets keep argv[0].
  let offset = if args.length() > 1 && args[1].has_suffix(".js") {
    2
  } else {
    1
  }
  if args.length() > offset && args[offset] == "--version" {
    println("QTI Score \{version}")
    return
  }
  if args.length() <= offset ||
    args[offset] == "--help" ||
    args[offset] == "help" {
    println(
      "QTI Score \{version}\n  --version\n  describe ITEM.xml\n  score ITEM.xml RESPONSE.json\n  explain ITEM.xml RESPONSE.json\n  batch ITEM.xml RESPONSES.jsonl\n  inspect-package ARCHIVE.zip\n  package-score ARCHIVE.zip RESOURCE_ID RESPONSE.json\n  package-explain ARCHIVE.zip RESOURCE_ID RESPONSE.json\n  package-batch ARCHIVE.zip ATTEMPTS.jsonl [--csv | --items-csv]\n\nResponses: {\"RESPONSE\":\"A\"}, {\"RESPONSE\":[\"A\",\"B\"]}, {\"RESPONSE\":100.5}, {\"RESPONSE\":null}, or composite {\"ACTION\":\"Adapt\",\"RATIO\":75}\nBatch rows: {\"attempt_id\":\"a\",\"resource_id\":\"choice\",\"response\":{\"RESPONSE\":\"A\"}}\nExplain is an explicit developer diagnostic and may reveal scoring rules.",
    )
    return
  }
  let command = args[offset]
  let from_package = command == "package-score" || command == "package-explain"
  let batch_csv = command == "package-batch" &&
    args.length() == offset + 4 &&
    ["--csv", "--items-csv"].contains(args[offset + 3])
  let expected = if command == "describe" || command == "inspect-package" {
    2
  } else if from_package {
    4
  } else {
    3
  }
  if ![
      "describe", "score", "explain", "batch", "inspect-package", "package-score",
      "package-explain", "package-batch",
    ].contains(command) ||
    (args.length() != offset + expected && !batch_csv) {
    println(
      "{\"ok\":false,\"error\":{\"code\":\"usage\",\"message\":\"Use --help for command syntax\"}}",
    )
    @sys.exit(2)
    return
  }
  try {
    if command == "package-batch" {
      let report = @qti.read_content_package(
        @fs.read_file_to_bytes(args[offset + 1]),
      ).score_attempts_jsonl(@fs.read_file_to_string(args[offset + 2]))
      if batch_csv {
        // println supplies the final LF; keep the preceding CR and all rows.
        let csv = if args[offset + 3] == "--items-csv" {
          report.items_csv()
        } else {
          report.to_csv()
        }
        println(csv.strip_suffix("\n").unwrap())
      } else {
        let result : Json = { "ok": true, "report": report }
        println(result.stringify())
      }
      if report.has_errors {
        @sys.exit(1)
      }
      return
    }
    if command == "inspect-package" {
      let bundle = @qti.read_content_package(
        @fs.read_file_to_bytes(args[offset + 1]),
      )
      let result : Json = { "ok": true, "package": bundle.describe() }
      println(result.stringify())
      return
    }
    let item = if from_package {
      @qti.read_content_package(@fs.read_file_to_bytes(args[offset + 1])).assessment_item(
        args[offset + 2],
      )
    } else {
      @qti.compile_assessment_item(@fs.read_file_to_string(args[offset + 1]))
    }
    if command == "describe" {
      let result : Json = { "ok": true, "item": item.describe() }
      println(result.stringify())
    } else {
      let response_offset = if from_package { 3 } else { 2 }
      let input = @fs.read_file_to_string(args[offset + response_offset])
      if command == "explain" || command == "package-explain" {
        let explanation = item.explain_json(input)
        let result : Json = {
          "ok": true,
          "item": item.describe(),
          "result": explanation.result,
          "steps": explanation.steps,
        }
        println(result.stringify())
      } else if command == "score" || command == "package-score" {
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
    | @qti.InvalidPackage(_, _)
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
