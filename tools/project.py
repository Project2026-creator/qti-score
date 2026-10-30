#!/usr/bin/env python3
"""Build the browser demo, serve it, or verify the QTI entry points (stdlib only)."""
import argparse
import csv
import datetime
import decimal
import functools
import hashlib
import io
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

if __package__:
    from .reporting import portable_report
    from .serve import DevelopmentHandler, LoopbackHTTPServer
else:
    from reporting import portable_report
    from serve import DevelopmentHandler, LoopbackHTTPServer

ROOT = Path(__file__).resolve().parents[1]
REVISION = "0a92fbbb6d2e620a1f7fad19977be4c418246bc0"
OFFICIAL_BASE = "https://raw.githubusercontent.com/1EdTech/qti-examples/{}/qtiv3-examples/packaging/items/".format(REVISION)
OFFICIAL_URLS = {
    "QTI3-associate.xml": "https://raw.githubusercontent.com/1EdTech/qti-examples/{}/QTI3_BPIG_Examples/items/QTI3-associate.xml".format(REVISION),
}
OFFICIAL_HASHES = {
    "QTI3-associate.xml": "72028c2c25411cd1f945cc64253f1135bba47c90e832a902e739dde30b2f3c88",
    "associate.xml": "fe8738d1148f0361bb4aabe000153d9f1e45e7d40af5a41ca570cc7a6f358190",
    "slider.xml": "19979f616c9cce0667d1257adb7903456bd9e6d7ea912f0e42d0719e48a258d6",
    "inline_choice.xml": "38cc1aecf537f4ee1c463123a9a678ff7fcd8415f6d2f6747989a4e793064613",
    "hottext.xml": "7b701fa4f0b764664876eae80df74073878e28f7ef4354a3e60600ec116fb99a",
    "gap_match.xml": "440e984a6ff4af86f58c8057c47af7fe2e9af1e4fbecb058a05e39689ab4935e",
    "match.xml": "fcc3f989c6bcf37b8e164217f82afdb8d8ec59f057dffd7b22bfb34c2a5e8bb3",
    "choice.xml": "9d762846f7ab3232de9549a956991afa761f2fd1f1dc276e98efe85c16ffea1e",
    "choice_multiple.xml": "c0cdfc4017844b8b8b54a52eac149ea227d2c0dfd33cd0086ff9b1c2871a2cb7",
    "order.xml": "f47faff0c906c31a2e9cb3d2c7c1558278007cf47bf5593e42bcf41455185da8",
}


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
    examples.append(("gap-package.zip", [("imsmanifest.xml", "gap-manifest.xml"),
                                         ("items/gap.xml", "gap.xml"), ("items/gap-single.xml", "gap-single.xml")]))
    examples.append(("hottext-package.zip", [("imsmanifest.xml", "hottext-manifest.xml"),
                                             ("items/hottext.xml", "hottext.xml"),
                                             ("items/hottext-single.xml", "hottext-single.xml")]))
    examples.append(("inline-choice-package.zip", [("imsmanifest.xml", "inline-choice-manifest.xml"),
                                                  ("items/inline-choice.xml", "inline-choice.xml"),
                                                  ("items/inline-choice-required.xml", "inline-choice-required.xml")]))
    examples.append(("slider-package.zip", [("imsmanifest.xml", "slider-manifest.xml"),
                                           ("items/slider.xml", "slider.xml"), ("items/slider-float.xml", "slider-float.xml")]))
    examples.append(("composite-package.zip", [("imsmanifest.xml", "composite-manifest.xml"),
                                              ("items/composite.xml", "composite.xml"), ("items/composite-numeric.xml", "composite-numeric.xml")]))
    examples.append(("composite-tolerance-package.zip", [("imsmanifest.xml", "composite-tolerance-manifest.xml"),
                                                        ("items/composite-tolerance.xml", "composite-tolerance.xml"),
                                                        ("items/composite.xml", "composite.xml")]))
    examples.append(("composite-inline-package.zip", [("imsmanifest.xml", "composite-inline-manifest.xml"),
                                                     ("items/composite-inline.xml", "composite-inline.xml"),
                                                     ("items/composite-inline-required.xml", "composite-inline-required.xml")]))
    examples.append(("composite-fallback-package.zip", [("imsmanifest.xml", "composite-fallback-manifest.xml"),
                                                       ("items/composite-fallback.xml", "composite-fallback.xml"),
                                                       ("items/composite-inline-required.xml", "composite-inline-required.xml")]))
    examples.append(("composite-choice-package.zip", [("imsmanifest.xml", "composite-choice-manifest.xml"),
                                                     ("items/composite-choice.xml", "composite-choice.xml"),
                                                     ("items/composite-choice-required.xml", "composite-choice-required.xml")]))
    examples.append(("composite-multiple-package.zip", [("imsmanifest.xml", "composite-multiple-manifest.xml"),
                                                       ("items/composite-multiple.xml", "composite-multiple.xml"),
                                                       ("items/composite-multiple-required.xml", "composite-multiple-required.xml")]))
    examples.append(("composite-slider-package.zip", [("imsmanifest.xml", "composite-slider-manifest.xml"),
                                                     ("items/composite-slider.xml", "composite-slider.xml"),
                                                     ("items/composite-slider-continuous.xml", "composite-slider-continuous.xml")]))
    examples.append(("runtime-test-package.zip", [("imsmanifest.xml", "runtime-test-manifest.xml"),
                                                ("test.xml", "runtime-test.xml"),
                                                ("items/single.xml", "single.xml"),
                                                ("items/multiple.xml", "multiple.xml"),
                                                ("items/numeric.xml", "numeric.xml")]))
    examples.append(("feedback-test-package.zip", [("imsmanifest.xml", "feedback-test-manifest.xml"),
                                                 ("test.xml", "feedback-test.xml"),
                                                 ("items/dependent-response.xml", "dependent-response.xml"),
                                                 ("items/extended-text-scored.xml", "extended-text-scored.xml"),
                                                 ("items/extended-text.xml", "extended-text.xml")]))
    examples.append(("graphic-test-package.zip", [("imsmanifest.xml", "graphic-test-manifest.xml"),
                                                ("test.xml", "graphic-test.xml"),
                                                ("items/hotspot.xml", "hotspot.xml"),
                                                ("items/graphic-gap.xml", "graphic-gap.xml"),
                                                ("items/graphic-map.svg", "graphic-map.svg")]))
    examples.append(("interaction-test-package.zip", [("imsmanifest.xml", "interaction-test-manifest.xml"),
                                                    ("test.xml", "interaction-test.xml")] +
                    [("items/" + name + ".xml", name + ".xml") for name in
                     ("match", "gap", "hottext", "order", "inline-choice", "composite-inline", "hottext-single", "order-subset")]))
    examples.append(("assembly-test-package.zip", [("imsmanifest.xml", "assembly-test-manifest.xml"),
                                               ("test.xml", "assembly-test.xml"),
                                               ("items/single.xml", "single.xml"),
                                               ("items/multiple.xml", "multiple.xml"),
                                               ("items/numeric.xml", "numeric.xml")]))
    examples.append(("conditional-test-package.zip", [("imsmanifest.xml", "conditional-test-manifest.xml"),
                                                   ("test.xml", "conditional-test.xml"),
                                                   ("items/single.xml", "single.xml"),
                                                   ("items/numeric.xml", "numeric.xml")]))
    examples.append(("outcome-test-package.zip", [("imsmanifest.xml", "outcome-test-manifest.xml"),
                                               ("test.xml", "outcome-test.xml"),
                                               ("items/single.xml", "single.xml"),
                                               ("items/numeric.xml", "numeric.xml")]))
    examples.append(("associate-test-package.zip", [("imsmanifest.xml", "associate-test-manifest.xml"),
                                                 ("test.xml", "associate-test.xml"),
                                                 ("items/associate.xml", "associate.xml")]))
    examples.append(("dynamic-test-package.zip", [("imsmanifest.xml", "dynamic-test-manifest.xml"),
                                               ("test.xml", "dynamic-test.xml"),
                                               ("items/dynamic-feedback.xml", "dynamic-feedback.xml")]))
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


def verify_item_statistics(report):
    groups = {}
    for row in report["rows"]:
        if row["resource_id"] is not None:
            groups.setdefault(row["resource_id"], []).append(row)
    if report["unassigned_resource_count"] != sum(row["resource_id"] is None for row in report["rows"]):
        raise AssertionError("Unassigned resource count differs")
    if [item["resource_id"] for item in report["items"]] != list(groups):
        raise AssertionError("Item statistics order/grouping differs")
    for item in report["items"]:
        rows = groups[item["resource_id"]]
        scored = [row["result"] for row in rows if row["ok"]]
        expected = {"row_count": len(rows), "scored_count": len(scored),
                    "error_count": len(rows) - len(scored),
                    "answered_count": sum(s["status"] == "answered" for s in scored),
                    "unanswered_count": sum(s["status"] == "unanswered" for s in scored),
                    "matched_count": sum(s["matches_correct"] is True for s in scored),
                    "unmatched_count": sum(s["matches_correct"] is False for s in scored),
                    "unclassified_count": sum(s["matches_correct"] is None for s in scored)}
        if any(item[key] != value for key, value in expected.items()):
            raise AssertionError("Item count differs from independent row aggregation")
        scores = [row["score"] for row in scored]
        if not scores:
            if any(item[key] is not None for key in ["score_mean", "score_min", "score_max"]):
                raise AssertionError("An unscored item must have null statistics")
        else:
            # Decimal addition provides an independent mean without binary sum overflow.
            mean = float(sum(decimal.Decimal(str(score)) for score in scores) / len(scores))
            if not math.isfinite(item["score_mean"]) or not math.isclose(item["score_mean"], mean, rel_tol=1e-12, abs_tol=1e-300) or \
                    [item["score_min"], item["score_max"]] != [min(scores), max(scores)]:
                raise AssertionError("Item score statistics differ from independent aggregation")


def verify(moon, env, output, offline=False):
    report = {
        "checked_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        "module": "Project2026-creator/qti-score", "version": "0.25.0",
        "toolchain": command([moon, "version", "--all"], env).stdout.strip(),
        "checks": [], "official_revision": REVISION, "official_cases": [], "derived_cases": [], "official_rejections": [], "feature_cases": [],
    }
    for arguments in [["fmt", "--check"], ["check", "--target", "all", "--deny-warn"],
                      ["test", "--target", "all", "--deny-warn"]]:
        result = command([moon] + arguments, env)
        report["checks"].append({"command": ["moon"] + arguments,
                                 "returncode": result.returncode,
                                 "output": (result.stdout + result.stderr).strip()})
    service_tests = command([sys.executable, "-m", "unittest", "tools.project_test", "-v"], env)
    report["checks"].append({"command": ["python", "-m", "unittest", "tools.project_test", "-v"],
                             "returncode": service_tests.returncode,
                             "output": (service_tests.stdout + service_tests.stderr).strip()})
    version = json.loads((ROOT / "sdk/package.json").read_text(encoding="utf-8"))["version"]
    for flag in ["--version", "--help"]:
        arguments = [moon, "run", "cmd/main", "--", flag]
        result = command(arguments, env)
        if result.stdout.splitlines()[0] != "QTI Score " + version:
            raise AssertionError("CLI and SDK version metadata differ")
        report["checks"].append({"command": ["moon"] + arguments[1:],
                                 "returncode": result.returncode, "output": result.stdout.strip()})
    for arguments in [
            ["describe", str(ROOT / "_build/not-present.xml")],
            ["score", "examples/single.xml", str(ROOT / "_build/not-present.json")],
            ["inspect-package", str(ROOT / "_build/not-present.zip")]]:
        result = subprocess.run([moon, "run", "cmd/main", "--"] + arguments, cwd=str(ROOT), env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", errors="replace")
        error = extract_json(result.stdout)
        if result.returncode != 1 or error.get("error", {}).get("code") != "io_error" or \
                error["error"]["message"] != "Could not read input file":
            raise AssertionError("File errors must not expose the local input path")
        report["checks"].append({"command": ["moon", "run", "cmd/main", "--"] + arguments,
                                 "returncode": result.returncode, "expected_nonzero": True, "result": error})
    bridge = build_web(moon, env)
    node = shutil.which("node")
    if not node:
        raise RuntimeError("Node.js is required for bridge comparison")
    sdk = package_sdk(bridge)
    sdk_env = env.copy()
    sdk_env["QTI_SDK_URL"] = (sdk / "index.mjs").as_uri()
    sdk_test_files = sorted((ROOT / "sdk").glob("*_test.mjs"))
    sdk_tests = command([node, "--test"] + [str(path) for path in sdk_test_files], sdk_env)
    report["checks"].append({"command": ["node", "--test"] + [path.relative_to(ROOT).as_posix() for path in sdk_test_files],
                             "sdk": str(sdk), "returncode": sdk_tests.returncode,
                             "output": (sdk_tests.stdout + sdk_tests.stderr).strip()})
    view_tests = command([node, "--test", "web/results_test.mjs"], env)
    report["checks"].append({"command": ["node", "--test", "web/results_test.mjs"],
                             "returncode": view_tests.returncode, "output": (view_tests.stdout + view_tests.stderr).strip()})
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
    sources.append(("associate.xml", [
        (["A P", "C M", "D L"], 4), (["P A", "M C", "L D"], 4),
        (["L D", "P A", "M C"], 4), (["P A"], 2), (["M C"], 1),
        (["A C"], 0), ([" A\tP "], 2), (None, 0), ([], 0),
    ]))
    sources.append(("QTI3-associate.xml", [
        (["A P", "C M", "D L"], 4), (["P A", "M C", "L D"], 4),
        (["P A"], 2), (["M C"], 1), (["A C"], 0), (None, 0), ([], 0),
    ]))
    sources.append(("gap_match.xml", [(["W G1", "Su G2"], 3), (["Su G2", "W G1"], 3),
                                      (["W G1"], 1), (["Su G2"], 2), (["Sp G1"], 0),
                                      (["W G1", "A G2"], 0), (None, 0), ([], 0)]))
    sources.append(("hottext.xml", [("B", 1), ("A", 0), ("C", 0), ("D", 0), ("E", 0), (None, 0), ("", 0)]))
    sources.append(("inline_choice.xml", [("Y", 1), ("G", 0), ("L", 0), (None, 0), ("", 0)]))
    sources.append(("slider.xml", [(0, 0), (12, 0.5), (13, 0.5), (14, 1), (15, 1), (16, 1),
                                   (17, 1), (18, 1), (19, 0.5), (20, 0.5), (100, 0), (None, 0), ("", 0)]))
    bridge_inputs = []
    bridge_records = []
    for filename, cases in sources:
        path = cache / filename
        uri = OFFICIAL_URLS.get(filename, OFFICIAL_BASE + filename)
        if not path.is_file():
            if offline:
                raise RuntimeError("Offline reference cache missing: {}".format(path))
            with urllib.request.urlopen(uri, timeout=45) as response:
                path.write_bytes(response.read())
        xml = path.read_text(encoding="utf-8")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != OFFICIAL_HASHES[filename]:
            raise RuntimeError("Official reference hash mismatch: {}".format(path))
        if filename == "gap_match.xml":
            # The pinned original omits max-associations (default 1) despite two
            # authored correct pairs. Reject it, then score a labelled correction.
            rejected = subprocess.run([moon, "run", "cmd/main", "--", "describe", str(path)],
                                      cwd=str(ROOT), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      encoding="utf-8", errors="replace")
            rejection = extract_json(rejected.stdout)
            if rejected.returncode != 1 or rejection.get("error", {}).get("code") != "invalid_item":
                raise AssertionError("Pinned gap sample must reject its inconsistent default maximum")
            report["official_rejections"].append({"source": uri, "sha256": digest, "result": rejection,
                                                   "reason": "max-associations defaults to 1, but correct-response contains 2 pairs"})
            old = '<qti-gap-match-interaction response-identifier="RESPONSE" shuffle="false">'
            if xml.count(old) != 1:
                raise AssertionError("Unexpected pinned gap source structure")
            xml = xml.replace(old, old[:-1] + ' max-associations="0">')
            path = cache / "gap_match_max0.xml"
            path.write_text(xml, encoding="utf-8")
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
            if filename == "gap_match.xml":
                record["adjustment"] = 'Add max-associations="0" to the gap-match interaction; original source hash is preserved above'
                report["derived_cases"].append(record)
            else:
                report["official_cases"].append(record)
            bridge_inputs.append({"xml": xml, "response": response_object})
            bridge_records.append(record)
    for name, cases in [
        ("numeric", [(100, 2), (100.5, 1), (104, 0.5), (95, 0.5), (105, 0.5), (110, 0), (None, 0), ("", 0)]),
        ("integer", [(42, 1), ("0042", 1), (41, 0), (None, 0)]),
        ("composite", [({"PLATFORM":"LMS","COUNT":4},4), ({"PLATFORM":"lms","COUNT":4},3),
                       ({"PLATFORM":"LMS"},2), ({"COUNT":4},2), ({"PLATFORM":"Unknown","COUNT":3},0),
                       ({},0), ({"PLATFORM":None,"COUNT":None},0), ({"COUNT":"04"},2)]),
        ("composite-numeric", [({"RATIO":0.75,"TOTAL":20},3), ({"RATIO":0.7,"TOTAL":20},2),
                               ({"RATIO":0.7},1), ({"TOTAL":20},1), ({},0), ({"RATIO":0,"TOTAL":0},0)]),
        ("composite-inline", [({"ACTION":"Adapt","RATIO":75},4), ({"ACTION":"Review","RATIO":75},2.5),
                              ({"ACTION":"Adapt","RATIO":74.5},3), ({"ACTION":"Ignore","RATIO":74.5},1),
                              ({"RATIO":75},2), ({"ACTION":"Adapt"},2), ({"ACTION":"Review"},0.5),
                              ({"ACTION":"Ignore"},0), ({},0), ({"ACTION":None,"RATIO":None},0),
                              ({"ACTION":"Adapt","RATIO":77},2), ({"ACTION":"Adapt","RATIO":76},3)]),
        ("composite-inline-required", [({"METHOD":"Formative","ACTION":"Adapt"},2),
                                       ({"METHOD":"Summative","ACTION":"Adapt"},1),
                                       ({"METHOD":"Formative","ACTION":"Ignore"},1),
                                       ({"METHOD":"Summative","ACTION":"Ignore"},0)]),
        ("composite-choice", [({"METHOD":"Formative","ACTION":"Adapt","RATIO":75,"UNIT":"%"},6),
                              ({"METHOD":"Formative","ACTION":"Review","RATIO":74.5,"UNIT":"%"},4.5),
                              ({"METHOD":"Summative","ACTION":"Ignore","RATIO":80,"UNIT":"%"},1),
                              ({"METHOD":"Formative"},2), ({"ACTION":"Adapt"},1), ({"ACTION":"Review"},0.5),
                              ({"RATIO":75},2), ({"UNIT":"%"},1), ({"METHOD":"Summative"},0),
                              ({"RATIO":74},1), ({"RATIO":76},1), ({"RATIO":76.001},0),
                              ({},0), ({"METHOD":None},0), ({"METHOD":""},0)]),
        ("composite-slider", [({"TIME":40,"RATIO":0.75,"ACTION":"Adapt"},5),
                              ({"TIME":40,"RATIO":0.7,"ACTION":"Adapt"},4),
                              ({"TIME":40,"RATIO":0.8,"ACTION":"Adapt"},4),
                              ({"TIME":40},2), ({"RATIO":0.75},2), ({"ACTION":"Adapt"},1),
                              ({"TIME":0},0), ({"RATIO":0},0), ({},0),
                              ({"TIME":None,"RATIO":None},0), ({"TIME":"","RATIO":" "},0)]),
        ("composite-slider-continuous", [({"ZERO":0,"RATE":0.5},3), ({"ZERO":0},1),
                                         ({"RATE":0.5},2), ({"RATE":0.55},1), ({"RATE":0.625},0),
                                         ({"RATE":0.333},0), ({"RATE":0},0), ({"ZERO":10},0),
                                         ({"ZERO":2},0), ({},0), ({"ZERO":None,"RATE":None},0),
                                         ({"ZERO":""},0)]),
        ("composite-multiple", [({"EVIDENCE":["Quiz","Feedback"],"ACTION":"Adapt","COUNT":4},4),
                                ({"EVIDENCE":["Feedback","Quiz"]},2), ({"EVIDENCE":["Quiz"]},1),
                                ({"EVIDENCE":["Quiz","Quiz"]},1), ({"EVIDENCE":["Quiz","Rank"]},0),
                                ({"EVIDENCE":["Rank"]},0), ({"ACTION":"Adapt"},1), ({"COUNT":4},1),
                                ({},0), ({"EVIDENCE":[]},0), ({"EVIDENCE":None},0)]),
        ("composite-multiple-required", [({"EVIDENCE":["Feedback","Quiz"],"TOOLS":["Quiz","Portfolio"]},4),
                                         ({"EVIDENCE":["Quiz","Quiz"],"TOOLS":["Quiz","Quiz"]},1),
                                         ({"EVIDENCE":["Quiz","Feedback","Rank"],"TOOLS":["Quiz"]},1),
                                         ({"EVIDENCE":["Quiz","Feedback"],"TOOLS":["Quiz","Portfolio","Poster"]},4),
                                         ({"EVIDENCE":["Quiz","Rank"],"TOOLS":["Poster"]},0)]),
        ("composite-choice-required", [({"METHOD":"Formative","ACTION":"Adapt"},2),
                                       ({"METHOD":"Formative","ACTION":"Ignore"},1),
                                       ({"METHOD":"Summative","ACTION":"Adapt"},1),
                                       ({"METHOD":"Summative","ACTION":"Ignore"},0)]),
        ("composite-fallback", [({"ACTION":"Adapt","RATIO":75},4), ({"ACTION":"Adapt","RATIO":74.5},3),
                                ({"ACTION":"Adapt","RATIO":80},1.5), ({"ACTION":"Ignore","RATIO":75},1),
                                ({"ACTION":"Ignore","RATIO":80},-1.5), ({"RATIO":75},2),
                                ({"ACTION":"Adapt"},2), ({"ACTION":"Ignore"},-1), ({"RATIO":80},-0.5),
                                ({},0), ({"ACTION":None,"RATIO":None},0), ({"ACTION":"","RATIO":""},0)]),
        ("composite-tolerance", [({"UNIT":"cm","LENGTH":100,"GROUPS":4},5),
                                 ({"UNIT":"cm","LENGTH":100.5,"GROUPS":4},4),
                                 ({"LENGTH":99},2), ({"LENGTH":101},2), ({"LENGTH":98.999},1),
                                 ({"LENGTH":104},1), ({"LENGTH":95},1), ({"LENGTH":105},1),
                                 ({"LENGTH":94.999},0), ({"LENGTH":105.001},0),
                                 ({"LENGTH":"1e2"},3), ({"UNIT":"cm"},1), ({"GROUPS":4},1),
                                 ({},0), ({"LENGTH":None},0), ({"LENGTH":0},0)]),
        ("slider", [(40, 2), (30, 1), (50, 1), (0, 0), (100, 0), (None, 0), ("", 0)]),
        ("slider-float", [(0.75, 2), (0.7, 1), (0.8, 1), (0.5, 0), (1, 0), (None, 0), ("", 0)]),
        ("inline-choice", [("Improve", 1), ("Rank", 0), ("Archive", 0), (None, 0), ("", 0)]),
        ("inline-choice-required", [("Adapt", 2), ("Review", 0.5), ("Ignore", 0)]),
        ("hottext", [(["Evidence", "Support"], 2), (["Support", "Evidence"], 2),
                     (["Evidence"], 1), (["Support"], 1), (["Ranking"], 0),
                     (["Evidence", "Ranking"], 0), (None, 0), ([], 0)]),
        ("hottext-single", [("Feedback", 1), ("Final", 0), (None, 0), ("", 0)]),
        ("gap", [(["Feedback G1", "Adjust G2", "Feedback G3"], 3),
                 (["Feedback G3", "Feedback G1", "Adjust G2"], 3), (["Feedback G1"], 1),
                 (["Feedback G1", "Rank G2"], 0.5), (["Rank G1"], 0), (None, 0), ([], 0)]),
        ("gap-single", [("Improve Goal", 1), ("Rank Goal", 0), (None, 0), ("", 0)]),
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
            response_object = response if name.startswith("composite") else {"RESPONSE": response}
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
            feature_record = {"fixture": name, "response": response_object,
                              "expected_score": expected, "cli_result": actual["result"],
                              "explanation": explanation["steps"]}
            report["feature_cases"].append(feature_record)
            bridge_records.append(feature_record)
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
    records = bridge_records
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
    batch_scenarios.append(("gap-package", (ROOT / "examples/gap-attempts.jsonl").read_text(encoding="utf-8"), 5, 4, 1, 1))
    batch_scenarios.append(("hottext-package", (ROOT / "examples/hottext-attempts.jsonl").read_text(encoding="utf-8"), 5, 4, 1, 1))
    batch_scenarios.append(("inline-choice-package", (ROOT / "examples/inline-choice-attempts.jsonl").read_text(encoding="utf-8"), 6, 4, 2, 1))
    batch_scenarios.append(("slider-package", (ROOT / "examples/slider-attempts.jsonl").read_text(encoding="utf-8"), 7, 5, 2, 1))
    batch_scenarios.append(("composite-package", (ROOT / "examples/composite-attempts.jsonl").read_text(encoding="utf-8"), 6, 5, 1, 1))
    batch_scenarios.append(("composite-tolerance-package", (ROOT / "examples/composite-tolerance-attempts.jsonl").read_text(encoding="utf-8"), 7, 6, 1, 1))
    batch_scenarios.append(("composite-inline-package", (ROOT / "examples/composite-inline-attempts.jsonl").read_text(encoding="utf-8"), 8, 6, 2, 1))
    batch_scenarios.append(("composite-fallback-package", (ROOT / "examples/composite-fallback-attempts.jsonl").read_text(encoding="utf-8"), 8, 6, 2, 1))
    batch_scenarios.append(("composite-choice-package", (ROOT / "examples/composite-choice-attempts.jsonl").read_text(encoding="utf-8"), 8, 6, 2, 1))
    batch_scenarios.append(("composite-multiple-package", (ROOT / "examples/composite-multiple-attempts.jsonl").read_text(encoding="utf-8"), 10, 7, 3, 1))
    batch_scenarios.append(("composite-slider-package", (ROOT / "examples/composite-slider-attempts.jsonl").read_text(encoding="utf-8"), 10, 7, 3, 1))
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
        if name == "gap-package":
            batch_archive = ROOT / "web/gap-package.zip"
        if name == "hottext-package":
            batch_archive = ROOT / "web/hottext-package.zip"
        if name == "inline-choice-package":
            batch_archive = ROOT / "web/inline-choice-package.zip"
        if name == "slider-package":
            batch_archive = ROOT / "web/slider-package.zip"
        if name == "composite-package":
            batch_archive = ROOT / "web/composite-package.zip"
        if name == "composite-tolerance-package":
            batch_archive = ROOT / "web/composite-tolerance-package.zip"
        if name == "composite-inline-package":
            batch_archive = ROOT / "web/composite-inline-package.zip"
        if name == "composite-fallback-package":
            batch_archive = ROOT / "web/composite-fallback-package.zip"
        if name == "composite-choice-package":
            batch_archive = ROOT / "web/composite-choice-package.zip"
        if name == "composite-multiple-package":
            batch_archive = ROOT / "web/composite-multiple-package.zip"
        if name == "composite-slider-package":
            batch_archive = ROOT / "web/composite-slider-package.zip"
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
        verify_item_statistics(cli_report)
        item_csv_run = subprocess.run(arguments + ["--items-csv"], cwd=str(ROOT), env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        item_csv = item_csv_run.stdout.decode("utf-8")
        if item_csv_run.returncode != expected_exit or item_csv != sdk_evaluation["itemsCsv"]:
            raise AssertionError("CLI and SDK item CSV exports differ")
        item_rows = list(csv.DictReader(io.StringIO(item_csv, newline="")))
        if len(item_rows) != len(cli_report["items"]):
            raise AssertionError("Item CSV row count differs")
        for exported_item, item in zip(item_rows, cli_report["items"]):
            for key in ["score_mean", "score_min", "score_max"]:
                if (exported_item[key] == "") != (item[key] is None) or \
                        (item[key] is not None and float(exported_item[key]) != item[key]):
                    raise AssertionError("Item CSV numeric value differs")
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
        if name == "gap-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [3, 1, 0.5, None, 0]:
            raise AssertionError("Gap package batch scores differ from authored expectations")
        if name == "hottext-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [2, 1, 1, None, 0]:
            raise AssertionError("Hottext package batch scores differ from authored expectations")
        if name == "inline-choice-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [1, 2, 0.5, None, 0, None]:
            raise AssertionError("Inline choice package batch scores differ from authored expectations")
        if name == "slider-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [2, 2, 1, 1, None, None, 0]:
            raise AssertionError("Slider package batch scores differ from authored expectations")
        if name == "composite-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [4, 3, 3, 1, None, 0]:
            raise AssertionError("Composite package batch scores differ from authored expectations")
        if name == "composite-tolerance-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [5, 2, 4, 1, None, 0, 3]:
            raise AssertionError("Composite tolerance batch scores differ from authored expectations")
        if name == "composite-inline-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [4, 2, 1.5, 2, None, None, 0, 0]:
            raise AssertionError("Composite inline batch scores differ from authored expectations")
        if name == "composite-fallback-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [4, 2, 1.5, 1, 0, None, None, -1.5]:
            raise AssertionError("Composite fallback batch scores differ from authored expectations")
        if name == "composite-choice-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [6, 2, 4.5, 1, 0, None, None, 0]:
            raise AssertionError("Composite choice batch scores differ from authored expectations")
        if name == "composite-multiple-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [4, 4, 2, 1, 0, None, None, None, 1, 2]:
            raise AssertionError("Composite multiple batch scores differ from authored expectations")
        if name == "composite-slider-package" and [row["result"]["score"] if row["ok"] else None for row in cli_report["rows"]] != [5, 3, 4, 0, 1, None, None, None, 1, 0]:
            raise AssertionError("Composite slider batch scores differ from authored expectations")
        report["batch_cases"].append({"name": name, "expected_exit": expected_exit,
                                      "cli_report": cli_report, "sdk_report": sdk_evaluation["report"],
                                      "csv": exported, "csv_decoded": decoded, "items_csv": item_csv,
                                      "item_statistics_verified": True})
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
    report["path_labels"] = {"<project>": "project root", "<home>": "user home",
                             "<moon>": "MoonBit executable", "<node>": "Node.js executable",
                             "<python>": "Python executable"}
    report = portable_report(report, ROOT, [("moon", moon), ("node", node), ("python", sys.executable)])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("All checks passed; {} official, {} derived, {} feature, {} package and {} batch cases agree across entry points.".format(
        len(report["official_cases"]), len(report["derived_cases"]), len(report["feature_cases"]), len(package_cases), len(batch_scenarios)))
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
        handler = functools.partial(DevelopmentHandler, directory=str(ROOT))
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
