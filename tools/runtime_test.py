#!/usr/bin/env python3
"""Exercise the authored test package through the native CLI and browser SDK.

Build assets first with ``python tools/project.py build-web``. Requires lxml for
the independent, pinned QTI 3 Results Reporting schema check.
Run ``python tools/runtime_test.py --offline`` after schemas have been cached.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if __package__:
    from .project import moon_environment
    from .reporting import portable_report
    from .result_schema_test import load_schema, validate_result_xml, NAMESPACE, SCHEMA_URL, SCHEMAS
else:
    from project import moon_environment
    from reporting import portable_report
    from result_schema_test import load_schema, validate_result_xml, NAMESPACE, SCHEMA_URL, SCHEMAS

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "web/runtime-test-package.zip"
ACTIONS = ROOT / "examples/runtime-actions.json"
RESOURCE_ID = "runtime-test"
EXPECTED_REFS = ["formative-1", "evidence", "formative-2", "measurement"]
EXPECTED_RESOURCES = ["choice", "evidence", "choice", "measurement"]
EXPECTED_SCORES = [1, 2, 0, 1]
EXPECTED_DURATIONS = [3, 3, 2, 2]
EXPECTED_ATTEMPTS = [1, 1, 1, 1]

SDK_DRIVER = r"""
import { readFileSync } from 'node:fs';
const [sdkURL, archivePath, actionsPath] = process.argv.slice(1);
const { importPackage } = await import(sdkURL);
const bundle = importPackage(readFileSync(archivePath));
const plan = bundle.getTest('runtime-test');
const script = JSON.parse(readFileSync(actionsPath, 'utf8'));
const sessions = [];
const create = id => {
  const session = plan.startSession(id, { now: script.start_time });
  sessions.push(session); return session;
};
const exportRun = session => {
  const { report, xml } = session.exportResult(script.datestamp, { candidateIdentifier: script.candidate_identifier });
  return { state: session.describe(), snapshot: session.snapshot(), report, xml, reportJSON: JSON.stringify(report) };
};
const rejected = (session, action) => {
  const before = session.snapshot(), state = JSON.stringify(session.describe());
  let code = null;
  try { session.act(action); } catch (cause) { code = cause.code; }
  return { code, unchanged: session.snapshot() === before && JSON.stringify(session.describe()) === state };
};
try {
  const full = create(script.session_identifier);
  for (const action of script.actions) full.act(action);
  const fullRun = exportRun(full);
  const partial = create(script.session_identifier);
  for (const action of script.actions.slice(0, 3)) partial.act(action);
  const partialState = partial.describe(), partialSnapshot = partial.snapshot();
  let incompleteCode = null;
  try { partial.exportResult(script.datestamp); } catch (cause) { incompleteCode = cause.code; }
  const restored = plan.restoreSession(partialSnapshot); sessions.push(restored);
  for (const action of script.actions.slice(3)) restored.act(action);
  const restoredRun = exportRun(restored);
  const originalUnchanged = partial.snapshot() === partialSnapshot && JSON.stringify(partial.describe()) === JSON.stringify(partialState);
  const invalid = create('invalid-actions');
  const badSkip = rejected(invalid, { type: 'next', time: 1 });
  const negativeClock = rejected(invalid, { type: 'tick', time: -1 });
  invalid.act({ type: 'save', time: 1, response: { RESPONSE: 'A' } });
  const backwardsClock = rejected(invalid, { type: 'tick', time: 0 });
  const badSnapshot = JSON.parse(partialSnapshot); badSnapshot.test_identity = 'different-test';
  let wrongIdentityCode = null;
  try { const rejectedSession = plan.restoreSession(JSON.stringify(badSnapshot)); rejectedSession.dispose(); }
  catch (cause) { wrongIdentityCode = cause.code; }
  console.log(JSON.stringify({ description: plan.describe(), full: fullRun, partial: { state: partialState, snapshot: partialSnapshot, incompleteCode },
    restored: restoredRun, originalUnchanged, failures: { badSkip, negativeClock, backwardsClock, wrongIdentityCode } }));
} finally {
  for (const session of sessions) session.dispose();
  plan.dispose(); bundle.dispose();
}
"""

ADDITIONAL_SDK_DRIVER = r"""
import { readFileSync } from 'node:fs';
const [sdkURL, archivePath, actionsPath, resource] = process.argv.slice(1);
const { importPackage } = await import(sdkURL);
const bundle = importPackage(readFileSync(archivePath));
const plan = bundle.getTest(resource);
const script = JSON.parse(readFileSync(actionsPath, 'utf8'));
const session = plan.startSession(script.session_identifier, { now: script.start_time });
try {
  for (const action of script.actions) session.act(action);
  const output = session.exportResult(script.datestamp, { candidateIdentifier: script.candidate_identifier });
  console.log(JSON.stringify({ ...output, state: session.describe(), reportJSON: JSON.stringify(output.report) }));
} finally { session.dispose(); plan.dispose(); bundle.dispose(); }
"""


def run_process(arguments, env, *, input_text=None):
    return subprocess.run(arguments, cwd=ROOT, env=env, input=input_text, shell=False,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          encoding="utf-8", errors="strict", timeout=90)


def json_output(result):
    # Initial native linking may print build messages before the single JSON line.
    for line in reversed(result.stdout.splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value, line
    raise AssertionError("Process did not return a JSON object: " + result.stderr[-2000:])


def raw_member(source, member):
    """Extract an object's member without rewriting its original JSON bytes."""
    decoder = json.JSONDecoder()
    position = 0
    while position < len(source) and source[position].isspace():
        position += 1
    if position >= len(source) or source[position] != "{":
        raise AssertionError("Expected object when extracting raw report JSON")
    position += 1
    while True:
        while source[position].isspace():
            position += 1
        if source[position] == "}":
            raise AssertionError("Missing JSON member " + member)
        key, position = decoder.raw_decode(source, position)
        while source[position].isspace():
            position += 1
        if source[position] != ":":
            raise AssertionError("Malformed object member")
        position += 1
        while source[position].isspace():
            position += 1
        beginning = position
        _, position = decoder.raw_decode(source, position)
        if key == member:
            return source[beginning:position]
        while source[position].isspace():
            position += 1
        if source[position] == ",":
            position += 1
        elif source[position] == "}":
            raise AssertionError("Missing JSON member " + member)
        else:
            raise AssertionError("Malformed object separator")


def verify(offline=False):
    for path in (PACKAGE, ACTIONS, ROOT / "sdk/qti-core.mjs"):
        if not path.is_file():
            raise RuntimeError("Missing runtime fixture or built SDK: " + path.name)
    schema = load_schema(offline)
    moon, env = moon_environment()
    node = shutil.which("node")
    if not node:
        raise RuntimeError("Node.js is required for SDK verification")
    sequence = json.loads(ACTIONS.read_text(encoding="utf-8"))
    checks = []

    def check(name, condition, expected, actual):
        if not condition:
            raise AssertionError("{}: expected {!r}, got {!r}".format(name, expected, actual))
        checks.append({"name": name, "expected": expected, "actual": actual})

    def cli(command, *arguments):
        result = run_process([moon, "run", "--target", "native", "cmd/main", "--", command, str(PACKAGE), RESOURCE_ID, *map(str, arguments)], env)
        value, source = json_output(result)
        return result.returncode, value, source

    with tempfile.TemporaryDirectory(prefix="qti-runtime-") as temporary:
        directory = Path(temporary)

        def cli_script(document):
            path = directory / "actions.json"
            path.write_text(json.dumps(document, ensure_ascii=False, allow_nan=False), encoding="utf-8")
            return cli("test-run", path)

        code, description, _ = cli("test-describe")
        check("CLI loads the authored four-reference test", code == 0 and description.get("ok") is True and description["test"]["item_count"] == 4,
              {"exit_code": 0, "item_count": 4}, {"exit_code": code, "item_count": description.get("test", {}).get("item_count")})
        code, full_cli, raw_full = cli("test-run", ACTIONS)
        if code != 0 or full_cli.get("ok") is not True:
            raise AssertionError("Valid authored action script failed: " + str(full_cli))
        full = full_cli["run"]
        sdk_process = run_process([node, "--input-type=module", "-e", SDK_DRIVER,
                                   (ROOT / "sdk/index.mjs").as_uri(), str(PACKAGE), str(ACTIONS)], env)
        if sdk_process.returncode:
            raise AssertionError("SDK runtime driver failed: " + sdk_process.stderr[-3000:])
        sdk, _ = json_output(sdk_process)
        check("CLI and SDK expose the same test plan", sdk["description"] == description["test"], "identical test descriptions", "identical test descriptions" if sdk["description"] == description["test"] else "different descriptions")
        entries = description["test"]["entries"]
        refs = [entry["identifier"] for entry in entries]
        resources = [entry["resource_id"] for entry in entries]
        check("Repeated resources retain independent ItemRef identities", refs == EXPECTED_REFS and resources == EXPECTED_RESOURCES and entries[0]["item"]["identifier"] == entries[2]["item"]["identifier"],
              {"references": EXPECTED_REFS, "resources": EXPECTED_RESOURCES}, {"references": refs, "resources": resources})
        report = full["report"]
        scores = [item["outcomes"]["SCORE"] for item in report["items"]]
        check("Authored item and test outcomes match hand-calculated values", full["state"]["completed"] is True and report["outcomes"]["SCORE"] == 4 and scores == EXPECTED_SCORES,
              {"completed": True, "test_score": 4, "item_scores": EXPECTED_SCORES}, {"completed": full["state"]["completed"], "test_score": report["outcomes"]["SCORE"], "item_scores": scores})
        attempts = [item["num_attempts"] for item in report["items"]]
        durations = [item["duration"] for item in report["items"]]
        check("Attempts and item durations follow the scripted clock", attempts == EXPECTED_ATTEMPTS and durations == EXPECTED_DURATIONS,
              {"attempts": EXPECTED_ATTEMPTS, "duration_seconds": EXPECTED_DURATIONS}, {"attempts": attempts, "duration_seconds": durations})
        raw_cli_report = raw_member(raw_member(raw_full, "run"), "report")
        bytes_match = raw_cli_report.encode("utf-8") == sdk["full"]["reportJSON"].encode("utf-8") and full["xml"].encode("utf-8") == sdk["full"]["xml"].encode("utf-8") and sdk["full"]["state"] == full["state"]
        check("CLI and SDK result JSON and XML match byte for byte", bytes_match, True, bytes_match)
        document = validate_result_xml(full["xml"], schema)
        ns = {"r": NAMESPACE}
        xml_refs = [element.get("identifier") for element in document.findall("r:itemResult", ns)]
        total = document.find("r:testResult/r:outcomeVariable[@identifier='SCORE']/r:value", ns)
        check("Independent pinned XSD validates standard results and total", xml_refs == EXPECTED_REFS and total is not None and float(total.text) == 4,
              {"references": EXPECTED_REFS, "test_score": 4}, {"references": xml_refs, "test_score": float(total.text) if total is not None else None})

        partial_script = copy.deepcopy(sequence)
        partial_script["actions"] = sequence["actions"][:3]
        code, partial, _ = cli_script(partial_script)
        partial_run = partial.get("run", {})
        incomplete = code == 0 and partial.get("ok") is True and partial_run.get("report") is None and partial_run.get("xml") is None and partial_run.get("state", {}).get("completed") is False and sdk["partial"]["incompleteCode"] == "invalid_response" and sdk["partial"]["state"] == partial_run["state"]
        check("Incomplete runs withhold result exports", incomplete, {"CLI_report": None, "CLI_xml": None, "SDK_error": "invalid_response"},
              {"CLI_report": partial_run.get("report"), "CLI_xml": partial_run.get("xml"), "SDK_error": sdk["partial"]["incompleteCode"]})
        resume_script = {"snapshot": partial_run["snapshot"], "actions": sequence["actions"][3:], "datestamp": sequence["datestamp"], "candidate_identifier": sequence["candidate_identifier"]}
        code, resumed, _ = cli_script(resume_script)
        restored = code == 0 and resumed.get("ok") is True and resumed["run"] == full and sdk["restored"]["report"] == report and sdk["restored"]["xml"] == full["xml"] and sdk["restored"]["snapshot"] == full["snapshot"] and sdk["full"]["snapshot"] == full["snapshot"] and sdk["originalUnchanged"] is True
        check("CLI and SDK restore then continue to the identical result", restored, True, restored)

        bad_skip = copy.deepcopy(sequence)
        bad_skip["actions"] = [{"type": "next", "time": 1}]
        code, failure, _ = cli_script(bad_skip)
        sdk_skip = sdk["failures"]["badSkip"]
        check("Rejected skip returns a failing CLI status and leaves SDK state unchanged", code == 1 and failure.get("ok") is False and failure.get("error", {}).get("code") == "invalid_response" and sdk_skip == {"code": "invalid_response", "unchanged": True},
              {"CLI_exit": 1, "SDK_unchanged": True}, {"CLI_exit": code, "SDK_unchanged": sdk_skip["unchanged"]})
        clock_results = []
        for bad_actions in ([{"type": "tick", "time": -1}], [sequence["actions"][0], {"type": "tick", "time": 0}]):
            bad_clock = copy.deepcopy(sequence)
            bad_clock["actions"] = bad_actions
            code, failure, _ = cli_script(bad_clock)
            clock_results.append(code == 1 and failure.get("ok") is False and failure.get("error", {}).get("code") == "invalid_response")
        clock_results.extend(sdk["failures"][key] == {"code": "invalid_response", "unchanged": True} for key in ("negativeClock", "backwardsClock"))
        check("Negative and backwards clocks fail atomically across entry points", all(clock_results), [True] * 4, clock_results)
        changed = json.loads(partial_run["snapshot"])
        changed["test_identity"] = "different-test"
        invalid_resume = {"snapshot": json.dumps(changed), "actions": []}
        code, failure, _ = cli_script(invalid_resume)
        identity_rejected = code == 1 and failure.get("ok") is False and failure.get("error", {}).get("code") == "invalid_response" and sdk["failures"]["wrongIdentityCode"] == "invalid_response" and sdk["originalUnchanged"]
        check("Changed snapshot test identity is rejected without altering its source session", identity_rejected, True, identity_rejected)

    for name, resource, expected_scores, expected_outcomes, all_scored in (
            ("feedback", "feedback-workflow", [5, 2, None], {"SCORE": None, "MAXSCORE": 7}, False),
            ("graphic", "graphic-test", [1, 3], {"SCORE": 4}, True),
            ("interaction", "interaction-test", [3, 3, 2, 1, 1, 4, 1, 1], {"SCORE": 16}, True),
            ("assembly", "assembly-test", [1, 2, 1, 0, 1], {"SCORE": 6.5, "CORE": 3, "ANCHOR": 2, "SECOND": 1}, True)):
        archive_path = ROOT / ("web/" + name + "-test-package.zip")
        actions_path = ROOT / ("examples/" + name + "-actions.json")
        cli_process = run_process([moon, "run", "--target", "native", "cmd/main", "--", "test-run",
                                   str(archive_path), resource, str(actions_path)], env)
        cli_value, raw_output = json_output(cli_process)
        if cli_process.returncode or cli_value.get("ok") is not True:
            raise AssertionError(name + " example failed through CLI")
        actual = cli_value["run"]
        sdk_process = run_process([node, "--input-type=module", "-e", ADDITIONAL_SDK_DRIVER,
                                   (ROOT / "sdk/index.mjs").as_uri(), str(archive_path), str(actions_path), resource], env)
        if sdk_process.returncode:
            raise AssertionError(name + " example failed through SDK: " + sdk_process.stderr[-1000:])
        sdk_value, _ = json_output(sdk_process)
        demo_report = actual["report"]
        demo_scores = [item["outcomes"]["SCORE"] for item in demo_report["items"]]
        expected = {"scores": expected_scores, "outcomes": expected_outcomes, "all_items_scored": all_scored, "has_errors": False}
        observed = {"scores": demo_scores, "outcomes": demo_report["outcomes"],
                    "all_items_scored": demo_report["all_items_scored"], "has_errors": demo_report["has_errors"]}
        same_bytes = raw_member(raw_member(raw_output, "run"), "report").encode("utf-8") == sdk_value["reportJSON"].encode("utf-8")
        same_bytes = same_bytes and actual["xml"] == sdk_value["xml"]
        check(name + " workflow preserves authored grades and identical CLI/SDK results", observed == expected and same_bytes,
              expected, observed)
        document = validate_result_xml(actual["xml"], schema)
        xml_scores = []
        statuses = []
        for item in document.findall("r:itemResult", ns):
            value = item.find("r:outcomeVariable[@identifier='SCORE']/r:value", ns)
            xml_scores.append(float(value.text) if value is not None else None)
            statuses.append(item.get("sessionStatus"))
        expected_status = ["final"] * len(expected_scores)
        if not all_scored:
            expected_status[-1] = "pendingExternalScoring"
        check(name + " result XML passes the pinned schema and independent typed reader",
              xml_scores == expected_scores and statuses == expected_status,
              {"scores": expected_scores, "statuses": expected_status}, {"scores": xml_scores, "statuses": statuses})

    conditional_package = ROOT / "web/conditional-test-package.zip"
    for name, actions_name, expected_scores, expected_skipped, total in (
            ("pass", "conditional-actions.json", [1, None, 2, 1], [False, True, False, False], 4),
            ("catchup", "conditional-catchup-actions.json", [0, 1, None, 1], [False, False, True, False], 2),
            ("exit", "conditional-exit-actions.json", [0, None, None, None], [False, True, True, True], 0)):
        actions_path = ROOT / "examples" / actions_name
        cli_process = run_process([moon, "run", "--target", "native", "cmd/main", "--", "test-run",
                                   str(conditional_package), "conditional-test", str(actions_path)], env)
        cli_value, raw_output = json_output(cli_process)
        if cli_process.returncode or cli_value.get("ok") is not True:
            raise AssertionError("Conditional " + name + " path failed through CLI")
        actual = cli_value["run"]
        sdk_process = run_process([node, "--input-type=module", "-e", ADDITIONAL_SDK_DRIVER,
                                   (ROOT / "sdk/index.mjs").as_uri(), str(conditional_package),
                                   str(actions_path), "conditional-test"], env)
        if sdk_process.returncode:
            raise AssertionError("Conditional " + name + " path failed through SDK: " + sdk_process.stderr[-1000:])
        sdk_value, _ = json_output(sdk_process)
        demo = actual["report"]
        # Initial outcomes on skipped items are authored defaults, not grades.
        grades = [None if item["skipped"] else item["outcomes"]["SCORE"] for item in demo["items"]]
        expected_statuses = ["initial" if skipped else "final" for skipped in expected_skipped]
        expected = {"scores": expected_scores, "skipped": expected_skipped,
                    "presented": [not value for value in expected_skipped],
                    "attempts": [0 if value else 1 for value in expected_skipped],
                    "outcomes": {"SCORE": total}, "statuses": expected_statuses,
                    "all_items_scored": True, "has_errors": False}
        observed = {"scores": grades, "skipped": [item["skipped"] for item in demo["items"]],
                    "presented": [item["presented"] for item in demo["items"]],
                    "attempts": [item["num_attempts"] for item in demo["items"]],
                    "outcomes": demo["outcomes"], "statuses": [item["session_status"] for item in demo["items"]],
                    "all_items_scored": demo["all_items_scored"], "has_errors": demo["has_errors"]}
        same_bytes = raw_member(raw_member(raw_output, "run"), "report").encode("utf-8") == sdk_value["reportJSON"].encode("utf-8")
        same_bytes = same_bytes and actual["xml"] == sdk_value["xml"] and actual["state"] == sdk_value["state"]
        check("Conditional " + name + " path matches CLI and SDK with skipped sessions ungraded",
              observed == expected and same_bytes and actual["state"]["completed"], expected, observed)
        document = validate_result_xml(actual["xml"], schema)
        statuses = [item.get("sessionStatus") for item in document.findall("r:itemResult", ns)]
        check("Conditional " + name + " XML validates final and initial session statuses",
              statuses == expected_statuses, expected_statuses, statuses)

    assembly_package = ROOT / "web/assembly-test-package.zip"
    expected_seeds = {1: ["anchor", "review", "evidence", "repeat", "repeat"],
                      42: ["anchor", "measurement", "review", "repeat", "repeat"]}
    for seed, expected_refs in expected_seeds.items():
        result = run_process([moon, "run", "--target", "native", "cmd/main", "--", "test-describe",
                              str(assembly_package), "assembly-test", "--seed", str(seed)], env)
        value, _ = json_output(result)
        refs = [entry["source_identifier"] for entry in value.get("test", {}).get("entries", [])]
        check("CLI seed " + str(seed) + " selects the documented reference sequence", result.returncode == 0 and refs == expected_refs,
              expected_refs, refs)
    invalid_seeds = []
    for seed in ("-1", "0.5", "2147483648", "bad"):
        result = run_process([moon, "run", "--target", "native", "cmd/main", "--", "test-describe",
                              str(assembly_package), "assembly-test", "--seed", seed], env)
        value, _ = json_output(result)
        invalid_seeds.append(result.returncode == 2 and value.get("error", {}).get("code") == "usage")
    check("CLI rejects malformed or out-of-range assembly seeds with usage status", all(invalid_seeds), [True] * 4, invalid_seeds)

    return {
        "ok": True,
        "checks_passed": len(checks),
        "checks": checks,
        "command": "python tools/runtime_test.py --offline --output _build/runtime-validation.json",
        "inputs": {
            "package": "web/runtime-test-package.zip",
            "actions": "examples/runtime-actions.json",
            "package_sha256": hashlib.sha256(PACKAGE.read_bytes()).hexdigest(),
            "actions_sha256": hashlib.sha256(ACTIONS.read_bytes()).hexdigest(),
        },
        "result": {"item_count": 4, "test_score": report["outcomes"]["SCORE"], "item_scores": scores,
                   "attempts": attempts, "duration_seconds": durations,
                   "xml_sha256": hashlib.sha256(full["xml"].encode("utf-8")).hexdigest()},
        "schema": {"url": SCHEMA_URL, "sha256": {name: digest for name, (_, digest) in SCHEMAS.items()}},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Use only hash-checked cached schemas")
    parser.add_argument("--output", type=Path, default=ROOT / "_build/runtime-validation.json")
    args = parser.parse_args()
    exit_code = 0
    try:
        report = verify(args.offline)
    except Exception as error:
        report = {"ok": False, "error": str(error)}
        exit_code = 1
    report = portable_report(report, ROOT)
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(output, encoding="utf-8")
    print(output, end="")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
