#!/usr/bin/env python3
"""Build the browser demo, serve it, or verify the QTI entry points (stdlib only)."""
import argparse
import datetime
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "0a92fbbb6d2e620a1f7fad19977be4c418246bc0"
OFFICIAL_BASE = "https://raw.githubusercontent.com/1EdTech/qti-examples/{}/qtiv3-examples/packaging/items/".format(REVISION)
OFFICIAL_HASHES = {
    "choice.xml": "9d762846f7ab3232de9549a956991afa761f2fd1f1dc276e98efe85c16ffea1e",
    "choice_multiple.xml": "c0cdfc4017844b8b8b54a52eac149ea227d2c0dfd33cd0086ff9b1c2871a2cb7",
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


def build_web(moon, env):
    command([moon, "build", "--target", "js", "--release"], env)
    source = ROOT / "_build/js/release/build/web/bridge/bridge.js"
    destination = ROOT / "web/qti-score.mjs"
    if not source.is_file():
        raise RuntimeError("Missing MoonBit bridge build output: {}".format(source))
    shutil.copyfile(str(source), str(destination))
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
        "module": "Project2026-creator/qti-score", "version": "0.1.0",
        "toolchain": command([moon, "version", "--all"], env).stdout.strip(),
        "checks": [], "official_revision": REVISION, "official_cases": [],
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
    ]
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
    # Node is only a host. It imports the compiled MoonBit bridge; no JavaScript
    # scorer or XML parser is used in this comparison.
    script = """
import {readFileSync} from 'node:fs';
const bridge = await import(process.argv[1]);
const cases = JSON.parse(readFileSync(0, 'utf8'));
console.log(JSON.stringify(cases.map(c => JSON.parse(bridge.evaluate(c.xml, JSON.stringify(c.response))))));
"""
    bridge_run = command([node, "--input-type=module", "-e", script, bridge.as_uri()], env,
                         json.dumps(bridge_inputs, ensure_ascii=False))
    bridge_results = json.loads(bridge_run.stdout)
    for record, result in zip(report["official_cases"], bridge_results):
        if result.get("ok") is not True or result["result"] != record["cli_result"]:
            raise AssertionError("CLI and browser bridge differ: {}".format(record))
        record["bridge_result"] = result["result"]
    if len(bridge_results) != len(report["official_cases"]):
        raise AssertionError("Missing bridge results")
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
    report["entry_point_parity"] = True
    report["passed"] = True
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("All checks passed; {} official cases agree across CLI and browser bridge.".format(len(report["official_cases"])))
    print("Results: {}".format(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build-web", "serve", "check"])
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
