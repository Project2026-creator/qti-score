#!/usr/bin/env python3
"""Validate real MoonBit result XML with the pinned QTI 3 Results Reporting XSD.

Requires lxml (``python -m pip install lxml``). Schemas stay in _build and are
checked by SHA-256 on every use. No network access is allowed during XML parsing.
Run ``python tools/result_schema_test.py --offline`` for exporter smoke cases,
or pass ``--xml result.xml`` to check an existing export.
"""
import argparse
import copy
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

from lxml import etree

if __package__:
    from .project import moon_environment
else:
    from project import moon_environment

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = "http://www.imsglobal.org/xsd/imsqti_result_v3p0"
SCHEMA_URL = "https://purl.imsglobal.org/spec/qti/v3p0/schema/xsd/imsqti_resultv3p0_v1p0.xsd"
SCHEMAS = {
    "imsqti_resultv3p0_v1p0.xsd": (
        SCHEMA_URL,
        "8cf1d3c89cbb1f198691410598ac4f8755a3b3ee6c1459747c3548fa6ccdc509",
    ),
    "xml.xsd": (
        "https://purl.imsglobal.org/spec/w3/2001/schema/xsd/xml.xsd",
        "4c637d0381d988dbf24b680becde6e1c8301b4c4ceef8bfa45a1ee130e77a682",
    ),
}
NS = {"r": NAMESPACE}
NCNAME = re.compile(r"[A-Za-z_][A-Za-z_0-9.\-]*\Z")


def load_schema(offline=False):
    directory = ROOT / "_build/qti-result-schema"
    directory.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in SCHEMAS.items():
        path = directory / name
        if not path.exists():
            if offline:
                raise RuntimeError("Missing cached schema {}; run once without --offline".format(name))
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest:
                raise RuntimeError("Schema hash mismatch: " + name)
            path.write_bytes(data)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("Cached schema hash mismatch: " + name)

    class PinnedResolver(etree.Resolver):
        def resolve(self, url, public_id, context):
            if url == SCHEMAS["xml.xsd"][0]:
                return self.resolve_filename(str(directory / "xml.xsd"), context)
            raise IOError("Unpinned XML schema dependency")

    parser = etree.XMLParser(no_network=True, resolve_entities=False, load_dtd=False)
    parser.resolvers.add(PinnedResolver())
    # Parse bytes so that the resolver only sees actual imported schemas.
    document = etree.fromstring((directory / "imsqti_resultv3p0_v1p0.xsd").read_bytes(), parser)
    return etree.XMLSchema(document)


def _check_values(variable):
    cardinality, base_type = variable.get("cardinality"), variable.get("baseType")
    if cardinality not in {"single", "multiple", "ordered"}:
        raise AssertionError("Exporter profile does not support record cardinality")
    values = variable.findall("r:candidateResponse/r:value", NS) if etree.QName(variable).localname == "responseVariable" else variable.findall("r:value", NS)
    if cardinality == "single" and len(values) > 1:
        raise AssertionError("single cardinality has multiple values")
    for node in values:
        text = node.text or ""
        if base_type == "identifier" and not NCNAME.fullmatch(text):
            raise AssertionError("Invalid identifier value")
        elif base_type == "integer":
            if not re.fullmatch(r"-?[0-9]+", text) or abs(int(text)) > 9007199254740991:
                raise AssertionError("Invalid exact integer value")
        elif base_type == "float":
            if not math.isfinite(float(text)):
                raise AssertionError("Nonfinite float value")
        elif base_type == "boolean" and text not in {"true", "false"}:
            raise AssertionError("Invalid boolean value")
        elif base_type == "directedPair":
            pair = text.split(" ")
            if len(pair) != 2 or not all(NCNAME.fullmatch(x) for x in pair):
                raise AssertionError("Invalid directedPair value")
        elif base_type not in {"identifier", "string", "integer", "float", "boolean", "directedPair"}:
            raise AssertionError("Unsupported exporter base type")


def validate_result_xml(data, schema):
    """Validate XSD, then the exporter's explicit scalar/container profile."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    if len(data) > 32 * 1024 * 1024:
        raise AssertionError("Result XML exceeds validation byte bound")
    parser = etree.XMLParser(no_network=True, resolve_entities=False, load_dtd=False)
    document = etree.fromstring(data, parser)
    if document.getroottree().docinfo.doctype:
        raise AssertionError("Result XML must not contain a DTD")
    schema.assertValid(document)
    if document.find("r:testResult", NS) is None:
        raise AssertionError("This export profile requires testResult")
    if document.findall(".//r:correctResponse", NS):
        raise AssertionError("Learner export must omit authored correct responses")
    positions = set()
    for item in document.findall("r:itemResult", NS):
        identifier, position = item.get("identifier"), int(item.get("sequenceIndex", "0"))
        if position in positions or position < 1:
            raise AssertionError("Repeated or invalid sequence index")
        positions.add(position)
        variable_ids = [node.get("identifier") for node in item if etree.QName(node).localname in {"responseVariable", "outcomeVariable"}]
        if len(variable_ids) != len(set(variable_ids)):
            raise AssertionError("Duplicate item variable identifier")
        for name in ("numAttempts", "duration"):
            variable = item.find("r:responseVariable[@identifier='{}']".format(name), NS)
            if variable is None:
                raise AssertionError("Missing built-in " + name)
            value = variable.find("r:candidateResponse/r:value", NS)
            if value is None or float(value.text) < 0:
                raise AssertionError("Invalid built-in " + name)
        attempts = int(item.find("r:responseVariable[@identifier='numAttempts']/r:candidateResponse/r:value", NS).text)
        if item.get("sessionStatus") == "initial" and attempts:
            raise AssertionError("Initial item result must have zero attempts")
    for scope in [document.find("r:testResult", NS)] + document.findall("r:itemResult", NS):
        stamp = scope.get("datestamp")
        if not stamp.endswith("Z"):
            raise AssertionError("Export profile requires UTC timestamps")
        datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        for variable in scope:
            if etree.QName(variable).localname in {"responseVariable", "outcomeVariable"}:
                _check_values(variable)
    return document


def smoke_report():
    def declaration(base, cardinality="single"):
        return {"base_type": base, "cardinality": cardinality}
    return {
        "test_identifier": "TEST", "session_identifier": "SESSION_1",
        "candidate_identifier": "anonymous_1", "datestamp": "2026-10-30T12:34:56.123Z",
        "outcomes": {"SCORE": 2.5}, "test_outcome_types": {"SCORE": declaration("float")},
        "items": [{
            "identifier": "REF_1", "item_identifier": "ITEM_NOT_REF", "sequence_index": 1,
            "session_status": "final", "num_attempts": 1, "duration": 12.5,
            "response": {"CHOICE": ["B", "A", "B"], "TEXT": "中文 < & > \" '\n第二行\t😀", "EMPTY": None, "ZERO": 0},
            "response_types": {"CHOICE": declaration("identifier", "ordered"), "TEXT": declaration("string"), "EMPTY": declaration("string"), "ZERO": declaration("integer")},
            "outcomes": {"SCORE": 2.5, "PASS": True, "completionStatus": "completed"},
            "outcome_types": {"SCORE": declaration("float"), "PASS": declaration("boolean"), "completionStatus": declaration("identifier")},
            "correct_response": "ANSWER_SENTINEL", "mapping": "MAPPING_SENTINEL", "trace": "TRACE_SENTINEL",
        }],
    }


def export_report(report, moon, env, directory, target="native"):
    source = directory / "report.json"
    source.write_text(json.dumps(report, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    result = subprocess.run([moon, "run", "--target", target, "cmd/main", "--", "result-xml", str(source)], cwd=ROOT, env=env, capture_output=True, encoding="utf-8", timeout=120)
    if result.returncode:
        raise RuntimeError("MoonBit result-xml failed:\n" + result.stderr[-4000:] + result.stdout[-4000:])
    return result.stdout


def run_smoke(schema, moon_path=None, target="native"):
    moon, env = moon_environment(moon_path)
    checks = []
    with tempfile.TemporaryDirectory(prefix="qti-result-schema-") as temporary:
        directory = Path(temporary)
        report = smoke_report()
        xml = export_report(report, moon, env, directory, target)
        document = validate_result_xml(xml, schema)
        checks.append("MoonBit output validates against pinned QTI 3 RR XSD")
        item = document.find("r:itemResult", NS)
        assert item.get("identifier") == "REF_1" and "ITEM_NOT_REF" not in xml
        checks.append("ItemRef identifier and one-based sequence index")
        assert [v.text for v in item.findall("r:responseVariable[@identifier='CHOICE']/r:candidateResponse/r:value", NS)] == ["B", "A", "B"]
        checks.append("Ordered response preserves sequence and duplicates")
        assert item.find("r:responseVariable[@identifier='TEXT']/r:candidateResponse/r:value", NS).text == report["items"][0]["response"]["TEXT"]
        checks.append("Independent XML reader preserves Unicode XML metacharacters and whitespace")
        assert not item.findall("r:responseVariable[@identifier='EMPTY']/r:candidateResponse/r:value", NS)
        assert item.find("r:responseVariable[@identifier='ZERO']/r:candidateResponse/r:value", NS).text == "0"
        checks.append("NULL remains distinct from numeric zero")
        assert all(sentinel not in xml for sentinel in ("ANSWER_SENTINEL", "MAPPING_SENTINEL", "TRACE_SENTINEL"))
        checks.append("Learner export omits authored answers mappings and trace")
        assert export_report(report, moon, env, directory, target) == xml
        checks.append("Repeated export is deterministic")
        partial = copy.deepcopy(report)
        partial["candidate_identifier"] = None
        partial["items"][0].update(session_status="initial", num_attempts=0, duration=0)
        partial["items"][0]["response"] = {key: None for key in partial["items"][0]["response"]}
        partial_xml = export_report(partial, moon, env, directory, target)
        partial_doc = validate_result_xml(partial_xml, schema)
        assert partial_doc.find("r:context", NS).get("sourcedId") is None
        checks.append("Anonymous initial report with NULL responses validates")
        repeated = copy.deepcopy(report)
        second = copy.deepcopy(repeated["items"][0])
        second.update(sequence_index=2, instance_identifier="runtime_instance_two")
        second["response"]["CHOICE"] = ["A"]
        second["outcomes"]["SCORE"] = 0
        repeated["items"].append(second)
        repeated_xml = export_report(repeated, moon, env, directory, target)
        repeated_doc = validate_result_xml(repeated_xml, schema)
        repeated_items = repeated_doc.findall("r:itemResult", NS)
        assert [node.get("identifier") for node in repeated_items] == ["REF_1", "REF_1"]
        assert [node.get("sequenceIndex") for node in repeated_items] == ["1", "2"]
        assert "runtime_instance_two" not in repeated_xml
        assert repeated_items[0].find("r:outcomeVariable[@identifier='SCORE']/r:value", NS).text == "2.5"
        assert repeated_items[1].find("r:outcomeVariable[@identifier='SCORE']/r:value", NS).text == "0"
        checks.append("Repeated source ItemRef instances validate with distinct sequence indices and independent scores")
        try:
            validate_result_xml(repeated_xml.replace('sequenceIndex="2"', 'sequenceIndex="1"'), schema)
        except AssertionError:
            pass
        else:
            raise AssertionError("Duplicate instance sequence index accepted")
        # Prove the independent schema check rejects malformed external documents.
        for broken in (
            xml.replace(NAMESPACE, "urn:wrong-result-namespace"),
            xml.replace('sessionStatus="final"', 'sessionStatus="closed"'),
            xml.replace('datestamp="2026-10-30T12:34:56.123Z"', 'datestamp="not-a-date"'),
            xml.replace('<context sourcedId="anonymous_1">', '<context unsupported="x" sourcedId="anonymous_1">'),
        ):
            try:
                validate_result_xml(broken, schema)
            except (etree.DocumentInvalid, AssertionError, ValueError):
                pass
            else:
                raise AssertionError("Invalid XML unexpectedly passed independent schema validation")
        checks.append("Independent XSD rejects four malformed namespace/status/date/attribute mutations")
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--moon")
    parser.add_argument("--target", choices=("native", "js"), default="native")
    parser.add_argument("--xml", action="append", type=Path, default=[])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    schema = load_schema(args.offline)
    if args.xml:
        checks = []
        for index, path in enumerate(args.xml, 1):
            validate_result_xml(path.read_bytes(), schema)
            checks.append("Input result XML {} validates".format(index))
    else:
        checks = run_smoke(schema, args.moon, args.target)
    result = {"ok": True, "profile": "QTI 3 Results Reporting Candidate Final 2022-11-01 scalar/container export subset", "schema": SCHEMA_URL,
              "schema_hashes": {name: digest for name, (_, digest) in SCHEMAS.items()},
              "checks_passed": len(checks), "checks": checks}
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError, ValueError, OSError, etree.XMLSyntaxError, etree.DocumentInvalid) as error:
        print("Result XML verification failed: {}".format(error), file=sys.stderr)
        sys.exit(1)
