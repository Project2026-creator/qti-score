#!/usr/bin/env python3
"""Build the browser demo, serve it, or verify the QTI entry points (stdlib only)."""
import argparse
import csv
import datetime
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = "0a92fbbb6d2e620a1f7fad19977be4c418246bc0"
OFFICIAL_BASE = "https://raw.githubusercontent.com/1EdTech/qti-examples/{}/qtiv3-examples/packaging/items/".format(REVISION)
OFFICIAL_HASHES = {
    "match.xml": "fcc3f989c6bcf37b8e164217f82afdb8d8ec59f057dffd7b22bfb34c2a5e8bb3",
    "choice.xml": "9d762846f7ab3232de9549a956991afa761f2fd1f1dc276e98efe85c16ffea1e",
    "choice_multiple.xml": "c0cdfc4017844b8b8b54a52eac149ea227d2c0dfd33cd0086ff9b1c2871a2cb7",
    "order.xml": "f47faff0c906c31a2e9cb3d2c7c1558278007cf47bf5593e42bcf41455185da8",
}


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # Avoid reverse DNS: older Windows Python can fail to decode localized
        # host names even when binding only to the numeric loopback address.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def moon_environment(explicit=None):
    local = ROOT / "_build" / "toolchain" / "bin" / ("moon.exe" if os.name == "nt" else "moon")
    executable = explicit or os.environ.get("QTI_MOON") or (str(local) if local.is_file() else shutil.which("moon"))
    if not executable:
        raise RuntimeError("MoonBit CLI is missing; install MoonBit 0.10.16 or newer")
    executable = str(Path(executable).resolve())
    env = os.environ.copy()
    home = Path(executable).parent.parent
    if (home / "lib" / "core").is_dir():
        env["MOON_HOME"] = str(home)
    env["PATH"] = str(Path(executable).parent) + os.pathsep + env.get("PATH", "")
    return executable, env


def command(args, env=None, input_text=None):
    result = subprocess.run(args, cwd=str(ROOT), env=env, input=input_text,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError("Command failed ({}): {}\n{}\n{}".format(
            result.returncode, " ".join(map(str, args)), result.stdout, result.stderr))
    return result


def build_sample_package():
    examples = [
        ("sample-package.zip", [
            ("imsmanifest.xml", "package-manifest.xml"),
            ("items/single.xml", "single.xml"), ("items/numeric.xml", "numeric.xml"),
            ("items/essay.xml", "essay.xml"), ("assets/note.txt", "package-note.txt"),
        ]),
        ("order-package.zip", [("imsmanifest.xml", "order-manifest.xml"),
                               ("items/order.xml", "order.xml"), ("items/order-subset.xml", "order-subset.xml")]),
    ]
    examples.append(("match-package.zip", [("imsmanifest.xml", "match-manifest.xml"),
                                           ("items/match.xml", "match.xml"),
                                           ("items/match-single.xml", "match-single.xml")]))
    for filename, files in examples:
        with zipfile.ZipFile(str(ROOT / "web" / filename), "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path, source in files:
                info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, (ROOT / "examples" / source).read_bytes())
    return ROOT / "web/sample-package.zip"


def build_web(moon, env):
    command([moon, "build", "--target", "js", "--release"], env)
    source = ROOT / "_build/js/release/build/web/bridge/bridge.js"
    destination = ROOT / "web/qti-score.mjs"
    if not source.is_file():
        raise RuntimeError("Missing MoonBit bridge build output: {}".format(source))
    shutil.copyfile(str(source), str(destination))
    shutil.copyfile(str(source), str(ROOT / "sdk/qti-core.mjs"))
    build_sample_package()
    return destination


def package_sdk(bridge):
    destination = ROOT / "_build/sdk/qti-score"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["package.json", "index.mjs", "index.d.mts", "README.md"]:
        shutil.copyfile(str(ROOT / "sdk" / name), str(destination / name))
    for name in ["LICENSE", "NOTICE"]:
        shutil.copyfile(str(ROOT / name), str(destination / name))
    shutil.copyfile(str(bridge), str(destination / "qti-core.mjs"))
    return destination


def extract_json(stdout):
    for line in reversed(stdout.splitlines()):
        try:
            return json.loads(line)
        except ValueError:
            continue
    raise RuntimeError("No JSON result in command output: {}".format(stdout))


def verify(moon, env, output, offline=False):
    report = {
        "checked_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        "module": "Project2026-creator/qti-score", "version": "0.6.0",
        "toolchain": command([moon, "version", "--all"], env).stdout.strip(),
        "checks": [], "official_revision": REVISION, "official_cases": [], "feature_cases": [],
    }
    for arguments in [["fmt", "--check"], ["check", "--target", "all", "--deny-warn"],
                      ["test", "--target", "all", "--deny-warn"]]:
        result = command([moon] + arguments, env)
        report["checks"].append({"command": ["moon"] + arguments,
                                 "returncode": result.returncode,
                                 "output": (result.stdout + result.stderr).strip()})
    bridge = build_web(moon, env)
    node = shutil.which("node")
    if not node:
        raise RuntimeError("Node.js is required for bridge comparison")
    sdk = package_sdk(bridge)
    sdk_env = env.copy()
    sdk_env["QTI_SDK_URL"] = (sdk / "index.mjs").as_uri()
    sdk_tests = command([node, "--test", str(ROOT / "sdk/sdk_test.mjs")], sdk_env)
    report["checks"].append({"command": ["node", "--test", "sdk/sdk_test.mjs"],
                             "sdk": str(sdk), "returncode": sdk_tests.returncode,
                             "output": (sdk_tests.stdout + sdk_tests.stderr).strip()})
    tsc = ROOT / "sdk/node_modules/typescript/lib/tsc.js"
    if not tsc.is_file():
        raise RuntimeError("TypeScript development dependency missing; run npm ci --prefix sdk --ignore-scripts")
    type_args = [node, str(tsc), "--noEmit", "--strict", "--module", "nodenext", "--target", "es2022",
                 "--lib", "es2022,dom", str(ROOT / "sdk/types_test.mts")]
    types = command(type_args, env)
    report["checks"].append({"command": ["node", "sdk/node_modules/typescript/lib/tsc.js"] + type_args[2:],
                             "returncode": types.returncode, "output": (types.stdout + types.stderr).strip()})
    cache = ROOT / "_build" / "reference"
    cache.mkdir(parents=True, exist_ok=True)
    sources = [
        ("choice.xml", [
            ("ChoiceA", 1), ("ChoiceB", 0), (None, 0), ("", 0),
        ]),
        ("choice_multiple.xml", [
            (["H"], 1), (["H", "O"], 2), (["O", "H"], 2),
            (["Cl"], 0), (["H", "Cl"], 0), (["He"], 0),
            (["H", "H", "O"], 2), (["H", "O", "N"], 0),
            (None, 0), ([], 0),
        ]),
        ("order.xml", [
            (["DriverC", "DriverA", "DriverB"], 1), (["DriverC", "DriverB", "DriverA"], 0),
            (["DriverA", "DriverC", "DriverB"], 0), (["DriverA", "DriverB", "DriverC"], 0),
            (["DriverB", "DriverC", "DriverA"], 0), (["DriverB", "DriverA", "DriverC"], 0),
            (None, 0), ([], 0),
        ]),
    ]
    sources.append(("match.xml", [
        (["C R", "D M", "L M", "P T"], 3), (["P T", "L M", "D M", "C R"], 3),
        (["C R"], 1), (["D M"], 0.5), (["C T"], 0), (["C R", "D M"], 1.5), (None, 0), ([], 0),
    ]))
    bridge_inputs = []
    for filename, cases in sources:
        path = cache / filename
        uri = OFFICIAL_BASE + filename
        if not path.is_file():
            if offline:
                raise RuntimeError("Offline reference cache missing: {}".format(path))
            with urllib.request.urlopen(uri, timeout=45) as response:
                path.write_bytes(response.read())
        xml = path.read_text(encoding="utf-8")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != OFFICIAL_HASHES[filename]:
            raise RuntimeError("Official reference hash mismatch: {}".format(path))
        for response, expected in cases:
            response_object = {"RESPONSE": response}
            response_path = cache / "response.json"
            response_path.write_text(json.dumps(response_object, ensure_ascii=False), encoding="utf-8")
            result = command([moon, "run", "cmd/main", "--", "score", str(path), str(response_path)], env)
            actual = extract_json(result.stdout)
            if actual.get("ok") is not True or actual["result"]["score"] != expected:
                raise AssertionError("Official {} response {}: expected {}, got {}".format(filename, response, expected, actual))
            record = {"source": uri, "sha256": digest, "response": response_object,
                      "expected_score": expected, "cli_result": actual["result"]}
            report["official_cases"].append(record)
            bridge_inputs.append({"xml": xml, "response": response_object})
    for name, cases in [
        ("numeric", [(100, 2), (100.5, 1), (104, 0.5), (95, 0.5), (105, 0.5), (110, 0), (None, 0), ("", 0)]),
        ("integer", [(42, 1), ("0042", 1), (41, 0), (None, 0)]),
        ("match", [(["Quiz Diagnose", "Portfolio Growth", "Observation Diagnose"], 3),
                   (["Observation Diagnose", "Portfolio Growth", "Quiz Diagnose"], 3),
                   (["Quiz Diagnose"], 1), (["Quiz Diagnose", "Portfolio Diagnose"], 0.5),
                   (["Quiz Growth"], 0), (None, 0), ([], 0)]),
        ("match-single", [("Portfolio Growth", 1), ("Quiz Growth", 0), (None, 0), ("", 0)]),
        ("order", [(["Analyze", "Design", "Develop", "Implement", "Evaluate"], 1),
                   (["Develop", "Evaluate", "Analyze", "Implement", "Design"], 0), (None, 0), ([], 0)]),
        ("order-subset", [(["Locate", "Adapt"], 1), (["Adapt", "Locate"], 0),
                          (["Locate", "Adapt", "Rank"], 0), ([], 0)]),
    ]:
        item_path = ROOT / "examples" / (name + ".xml")
        xml = item_path.read_text(encoding="utf-8")
        for response, expected in cases:
            response_object = {"RESPONSE": response}
            response_path = cache / "response.json"
            response_path.write_text(json.dumps(response_object), encoding="utf-8")
            score_run = command([moon, "run", "cmd/main", "--", "score", str(item_path), str(response_path)], env)
            explanation_run = command([moon, "run", "cmd/main", "--", "explain", str(item_path), str(response_path)], env)
            actual = extract_json(score_run.stdout)
            explanation = extract_json(explanation_run.stdout)
            if actual.get("ok") is not True or actual["result"]["score"] != expected or "steps" in actual:
                raise AssertionError("Unexpected feature CLI result: {}".format(actual))
            if explanation.get("ok") is not True or explanation["result"] != actual["result"] or not explanation.get("steps"):
                raise AssertionError("CLI explanation disagrees with score: {}".format(explanation))
            report["feature_cases"].append({"fixture": name, "response": response_object,
                                            "expected_score": expected, "cli_result": actual["result"],
                                            "explanation": explanation["steps"]})
            bridge_inputs.append({"xml": xml, "response": response_object})
    # Node is only a host. It imports the compiled MoonBit bridge; no JavaScript
    # scorer or XML parser is used in this comparison.
    script = """
import {readFileSync} from 'node:fs';
const bridge = await import(process.argv[1]);
const sdk = await import(process.argv[2]);
const cases = JSON.parse(readFileSync(0, 'utf8'));
const compiled = new Map();
try {
  console.log(JSON.stringify(cases.map(c => {
    if (!compiled.has(c.xml)) compiled.set(c.xml, sdk.compileItem(c.xml));
    const item = compiled.get(c.xml);
    return {bridge: JSON.parse(bridge.evaluate(c.xml, JSON.stringify(c.response))),
      sdk_result: item.score(c.response), explanation: item.explain(c.response)};
  })));
} finally { for (const item of compiled.values()) item.dispose(); }
"""
    bridge_run = command([node, "--input-type=module", "-e", script, bridge.as_uri(), (sdk / "index.mjs").as_uri()], env,
                         json.dumps(bridge_inputs, ensure_ascii=False))
    bridge_results = json.loads(bridge_run.stdout)
    records = report["official_cases"] + report["feature_cases"]
    for record, comparison in zip(records, bridge_results):
        result = comparison["bridge"]
        if result.get("ok") is not True or result["result"] != record["cli_result"] or \
                comparison["sdk_result"] != record["cli_result"] or comparison["explanation"]["result"] != record["cli_result"]:
            raise AssertionError("CLI and browser bridge differ: {}".format(record))
        record["bridge_result"] = result["result"]
        record["sdk_result"] = comparison["sdk_result"]
        if "explanation" in record and record["explanation"] != comparison["explanation"]["steps"]:
            raise AssertionError("CLI and SDK explanation steps differ")
    if len(bridge_results) != len(records):
        raise AssertionError("Missing bridge results")
    archive = ROOT / "web/sample-package.zip"
    inspected = extract_json(command([moon, "run", "cmd/main", "--", "inspect-package", str(archive)], env).stdout)
    package_report = inspected.get("package", {})
    if inspected.get("ok") is not True or package_report.get("ready_count") != 2 or \
            [entry["status"] for entry in package_report.get("items", [])] != ["ready", "ready", "unsupported"]:
        raise AssertionError("Unexpected package inspection: {}".format(inspected))
    package_cases = []
    for resource, response_file, expected in [
        ("choice", "single-response.json", 1), ("measurement", "numeric-response.json", 1),
    ]:
        response_path = ROOT / "examples" / response_file
        score_args = [moon, "run", "cmd/main", "--", "package-score", str(archive), resource, str(response_path)]
        score = extract_json(command(score_args, env).stdout)
        explain_args = score_args.copy()
        explain_args[4] = "package-explain"
        explanation = extract_json(command(explain_args, env).stdout)
        if score.get("ok") is not True or score["result"]["score"] != expected or \
                explanation.get("result") != score["result"] or not explanation.get("steps"):
            raise AssertionError("Package scoring/explanation mismatch")
        package_cases.append({"resource_id": resource, "response": json.loads(response_path.read_text(encoding="utf-8")),
                              "expected_score": expected, "cli_result": score["result"], "steps": explanation["steps"]})
    package_script = """
import {readFileSync} from 'node:fs';
const {importPackage}=await import(process.argv[1]);
const bundle=importPackage(readFileSync(process.argv[2]));
try {
  const cases=JSON.parse(readFileSync(0,'utf8'));
  const results=cases.map(c=>{ const item=bundle.getItem(c.resource_id);
    try {return item.explain(c.response);} finally {item.dispose();} });
  console.log(JSON.stringify({report:bundle.describe(),results}));
} finally {bundle.dispose();}
"""
    package_comparison = json.loads(command([node, "--input-type=module", "-e", package_script,
                                      (sdk / "index.mjs").as_uri(), str(archive)], env,
                                     json.dumps(package_cases)).stdout)
    if package_comparison["report"] != package_report or len(package_comparison["results"]) != len(package_cases):
        raise AssertionError("Package reports differ between CLI and SDK")
    for case, result in zip(package_cases, package_comparison["results"]):
        if result != {"result": case["cli_result"], "steps": case["steps"]}:
            raise AssertionError("Package scoring differs between CLI and SDK")
        case["sdk_result"] = result["result"]
    report["package_report"] = package_report
    report["package_cases"] = package_cases
    for resource, expected_code in [("essay", "unsupported"), ("missing", "invalid_package")]:
        arguments = [moon, "run", "cmd/main", "--", "package-score", str(archive), resource, "examples/single-response.json"]
        failed = subprocess.run(arguments, cwd=str(ROOT), env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, encoding="utf-8", errors="replace")
        result = extract_json(failed.stdout)
        if failed.returncode != 1 or result.get("error", {}).get("code") != expected_code:
            raise AssertionError("Package CLI failure did not preserve error and exit status")
        report["checks"].append({"command": ["moon"] + arguments[1:], "returncode": failed.returncode,
                                 "expected_nonzero": True, "result": result})
    sample_attempts = (ROOT / "examples/package-attempts.jsonl").read_text(encoding="utf-8")
    sample_lines = sample_attempts.splitlines()
    quoted_attempts = "\n".join(json.dumps({"attempt_id": identity, "resource_id": "choice", "response": {}}, ensure_ascii=False)
                                for identity in ['学生,"A"', '=1+2'])
    batch_scenarios = [
        ("mixed", sample_attempts, 6, 4, 2, 1),
        ("valid", "\n".join(sample_lines[:2]), 2, 2, 0, 0),
        ("duplicates", "\uFEFF\r\n" + sample_lines[0] + "\r\n" + sample_lines[0] + "\r\n{broken\r\n" +
         '{"attempt_id":"unknown","resource_id":"missing","response":{}}', 4, 0, 4, 1),
        ("empty", "\uFEFF\n \r\n", 0, 0, 0, 0),
        ("quoted-identities", quoted_attempts, 2, 2, 0, 0),
        ("ordered-package", (ROOT / "examples/order-attempts.jsonl").read_text(encoding="utf-8"), 4, 3, 1, 1),
    ]
    batch_scenarios.append(("matching-package", (ROOT / "examples/match-attempts.jsonl").read_text(encoding="utf-8"), 4, 3, 1, 1))
    batch_script = """
import {readFileSync} from 'node:fs';
const {importPackage}=await import(process.argv[1]);
const bundle=importPackage(readFileSync(process.argv[2]));
try {console.log(JSON.stringify(bundle.scoreAttempts(readFileSync(0,'utf8'))));}
finally {bundle.dispose();}
"""
    report["batch_cases"] = []
    for name, source, count, scored, errors, expected_exit in batch_scenarios:
        batch_archive = ROOT / "web/order-package.zip" if name == "ordered-package" else archive
        if name == "matching-package":
            batch_archive = ROOT / "web/match-package.zip"
        path = cache / ("batch-" + name + ".jsonl")
        path.write_text(source, encoding="utf-8")
        arguments = [moon, "run", "cmd/main", "--", "package-batch", str(batch_archive), str(path)]
        cli = subprocess.run(arguments, cwd=str(ROOT), env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, encoding="utf-8", errors="replace")
        parsed = extract_json(cli.stdout)
        cli_report = parsed.get("report", {})
        if cli.returncode != expected_exit or parsed.get("ok") is not True or \
                [cli_report.get(key) for key in ["row_count", "scored_count", "error_count"]] != [count, scored, errors]:
            raise AssertionError("Unexpected package batch result: {}".format(parsed))
        sdk_evaluation = json.loads(command([node, "--input-type=module", "-e", batch_script,
                                             (sdk / "index.mjs").as_uri(), str(batch_archive)], env, source).stdout)
        if sdk_evaluation["report"] != cli_report:
            raise AssertionError("CLI and SDK batch reports differ")
        csv_run = subprocess.run(arguments + ["--csv"], cwd=str(ROOT), env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        exported = csv_run.stdout.decode("utf-8")
        if csv_run.returncode != expected_exit or exported != sdk_evaluation["csv"]:
            raise AssertionError("CLI and SDK CSV export differ")
        decoded = list(csv.DictReader(io.StringIO(exported, newline="")))
        if len(decoded) != count or len(exported.split("\r\n")[0].split(",")) != 12:
            raise AssertionError("CSV row count or fixed header mismatch")
        for row, detail in zip(decoded, cli_report["rows"]):
            if row["line"] != str(detail["line"]) or row["ok"] != str(detail["ok"]).lower():
                raise AssertionError("CSV identity/status mismatch")
            if detail["ok"]:
                if float(row["score"]) != detail["result"]["score"] or row["status"] != detail["result"]["status"]:
                    raise AssertionError("CSV score mismatch")
            elif row["score"] != "" or row["error_code"] != detail["error"]["code"]:
                raise AssertionError("CSV failure was silently converted to a score")
        if name == "mixed" and [attempt["score_sum"] for attempt in cli_report["attempts"]] != [2, 0, 0.5]:
            raise AssertionError("Successful-row sums differ from authored expectations")
        if name == "quoted-identities" and [row["attempt_id"] for row in decoded] != ['学生,"A"', "'=1+2"]:
            raise AssertionError("CSV text quoting/prefix mismatch")
        if name == "ordered-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [1, 1, 0, None]:
            raise AssertionError("Ordered package batch did not preserve sequence semantics")
        if name == "matching-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [3, 0.5, None, 0]:
            raise AssertionError("Matching package batch scores differ from authored expectations")
        report["batch_cases"].append({"name": name, "expected_exit": expected_exit,
                                      "cli_report": cli_report, "sdk_report": sdk_evaluation["report"],
                                      "csv": exported, "csv_decoded": decoded})
    # A real CLI failure must return a nonzero code as well as a JSON error.
    bad = cache / "invalid-response.json"
    bad.write_text('{"RESPONSE":"not-a-choice"}', encoding="utf-8")
    invalid = subprocess.run([moon, "run", "cmd/main", "--", "score", "examples/single.xml", str(bad)],
                             cwd=str(ROOT), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             encoding="utf-8", errors="replace")
    error = extract_json(invalid.stdout)
    if invalid.returncode == 0 or error.get("error", {}).get("code") != "invalid_response":
        raise AssertionError("CLI did not report an invalid response with a nonzero exit")
    report["checks"].append({"command": ["moon", "run", "cmd/main", "--", "score", "examples/single.xml", str(bad)],
                             "returncode": invalid.returncode, "expected_nonzero": True, "result": error})
    batch_args = [moon, "run", "cmd/main", "--", "batch", "examples/multiple.xml", "examples/attempts.jsonl"]
    batch = command(batch_args, env)
    batch_results = [json.loads(line) for line in batch.stdout.splitlines() if line.startswith("{")]
    if [row["result"]["score"] for row in batch_results] != [0, 1, 2, 0, 2]:
        raise AssertionError("Unexpected batch results: {}".format(batch_results))
    report["checks"].append({"command": ["moon"] + batch_args[1:], "returncode": batch.returncode,
                             "results": batch_results})
    mixed = cache / "mixed.jsonl"
    mixed.write_text('{"RESPONSE":["A"]}\n\n{"RESPONSE":["missing"]}\n{"RESPONSE":["A","C"]}\n', encoding="utf-8")
    mixed_args = [moon, "run", "cmd/main", "--", "batch", "examples/multiple.xml", str(mixed)]
    mixed_run = subprocess.run(mixed_args, cwd=str(ROOT), env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, encoding="utf-8", errors="replace")
    mixed_results = [json.loads(line) for line in mixed_run.stdout.splitlines() if line.startswith("{")]
    if mixed_run.returncode != 1 or [r["line"] for r in mixed_results] != [1, 3, 4] or \
            [r["ok"] for r in mixed_results] != [True, False, True] or \
            mixed_results[-1]["result"]["score"] != 2:
        raise AssertionError("Batch did not continue after an invalid response")
    report["checks"].append({"command": ["moon"] + mixed_args[1:], "returncode": mixed_run.returncode,
                             "expected_nonzero": True, "results": mixed_results})
    report["official_cases_passed"] = len(report["official_cases"])
    report["feature_cases_passed"] = len(report["feature_cases"])
    report["package_cases_passed"] = len(package_cases)
    report["batch_cases_passed"] = len(batch_scenarios)
    report["entry_point_parity"] = True
    report["passed"] = True
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("All checks passed; {} official, {} feature, {} package and {} batch cases agree across entry points.".format(
        len(report["official_cases"]), len(report["feature_cases"]), len(package_cases), len(batch_scenarios)))
    print("Results: {}".format(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build-web", "build-sdk", "serve", "check"])
    parser.add_argument("--moon", help="Path to MoonBit CLI (also accepts QTI_MOON environment variable)")
    parser.add_argument("--port", type=int, default=4173)
    parser.add_argument("--output", type=Path, default=ROOT / "_build/validation.json")
    parser.add_argument("--offline", action="store_true", help="Require already cached official reference XML")
    args = parser.parse_args()
    moon, env = moon_environment(args.moon)
    if args.action == "check":
        verify(moon, env, args.output.resolve(), args.offline)
    else:
        destination = build_web(moon, env)
        if args.action == "build-sdk":
            print("Built SDK: {}".format(package_sdk(destination)))
            return
        if args.action == "build-web":
            print("Built {}".format(destination))
            return
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT))
        server = LoopbackHTTPServer(("127.0.0.1", args.port), handler)
        print("QTI Score: http://127.0.0.1:{}/web/".format(args.port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    try:
        main()
    except (RuntimeError, AssertionError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
