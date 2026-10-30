#!/usr/bin/env python3
"""Validate assessment XML and manifests against pinned official QTI schemas.

Requires lxml (``python -m pip install lxml``). Run once with network access to
cache the official schemas in _build, then use ``--offline``. Assessment files
are checked against both ASI 3.0.1 and the appropriate item/test schema. Content
packaging has a separate version: its schemaversion metadata is 3.0.0.
XML parsing never fetches network resources or resolves document entities.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

try:
    from lxml import etree
except ImportError as error:
    raise SystemExit("Install the XML validator with: python -m pip install lxml") from error

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "_build/qti-asi-schema"
ASI_NAMESPACE = "http://www.imsglobal.org/xsd/imsqtiasi_v3p0"
CP_NAMESPACE = "http://www.imsglobal.org/xsd/qti/qtiv3p0/imscp_v1p1"
SOURCE_INDEX = "https://www.1edtech.org/standards/qti/index"
BASE = "https://purl.imsglobal.org/spec/qti/v3p0/schema/xsd/"
ASI_SCHEMA = "imsqti_asiv3p0p1_v1p0.xsd"
ITEM_SCHEMA = "imsqti_itemv3p0p1_v1p0.xsd"
TEST_SCHEMA = "imsqti_testv3p0p1_v1p0.xsd"
CP_SCHEMA = "imsqtiv3p0_imscpv1p2_v1p0.xsd"
MAX_SCHEMA_BYTES = 32 * 1024 * 1024
MAX_XML_BYTES = 4 * 1024 * 1024
SCHEMAS = {
    ASI_SCHEMA: (BASE + ASI_SCHEMA, "bd82f6df3c7acec951fffc78548325a01e9e9bc91d5768d7415bdcbdc018341d"),
    ITEM_SCHEMA: (BASE + ITEM_SCHEMA, "eddc7e78d16cd077deb60b182cf40a326523070b126610bad854868d0e6a8c8c"),
    TEST_SCHEMA: (BASE + TEST_SCHEMA, "4bf00ed6e72c2ac81b249722fa7d71f1ff44bee0bd211308a188c46e745b2401"),
    CP_SCHEMA: (BASE + CP_SCHEMA, "30be3dad4fe0ee103295268317ee0ff2b1826b8b55023db974a993edf3ce9101"),
    "xml.xsd": ("https://purl.imsglobal.org/spec/w3/2001/schema/xsd/xml.xsd", "4c637d0381d988dbf24b680becde6e1c8301b4c4ceef8bfa45a1ee130e77a682"),
    "XInclude.xsd": ("https://purl.imsglobal.org/spec/w3/2001/schema/xsd/XInclude.xsd", "b72e1d2a0ab90aca502b827ce12572bfb4ef787fee89b4dcc1ce474dd3c00df0"),
    "mathml3.xsd": ("https://purl.imsglobal.org/spec/mathml/v3p0/schema/xsd/mathml3.xsd", "af49edc2c29c4976d6a9d8860388c026b94ca75edfbd67bbaf67448da9990656"),
    "mathml3-content.xsd": ("https://purl.imsglobal.org/spec/mathml/v3p0/schema/xsd/mathml3-content.xsd", "922b4082d00559df86b0389842b1d1ba9537db0050ab229d64ad313ddfb44098"),
    "mathml3-presentation.xsd": ("https://purl.imsglobal.org/spec/mathml/v3p0/schema/xsd/mathml3-presentation.xsd", "74d605b09528b7c55a4ae803debc429c27a2afa6cd34607d28df79bcc7f3575b"),
    "mathml3-common.xsd": ("https://purl.imsglobal.org/spec/mathml/v3p0/schema/xsd/mathml3-common.xsd", "94007301de9c8ed29ffed4a5eba6ca6b1e2e7511eda8d2b39e01b97d7d7e5d06"),
    "mathml3-strict-content.xsd": ("https://purl.imsglobal.org/spec/mathml/v3p0/schema/xsd/mathml3-strict-content.xsd", "cd0da554afbe2d1570c4e548a29ee5eb0b25aea1d6455bacf664080cb5982640"),
    "ssmlv1p1-core.xsd": ("https://purl.imsglobal.org/spec/ssml/v1p1/schema/xsd/ssmlv1p1-core.xsd", "f5e6d5ca575722c5ee1de50aefbe483bb8c88d2c46e65f4d7eecb713b8c1f485"),
    "synthesis-nonamespace.xsd": ("https://purl.imsglobal.org/spec/ssml/v1p1/schema/xsd/synthesis-nonamespace.xsd", "10608b0b9ad809f78be41e84c655d210fcf27ccc84996ef97cd6dc80b00ace5c"),
    "imsmd_loose_v1p3p2.xsd": ("https://purl.imsglobal.org/spec/md/v1p3/schema/xsd/imsmd_loose_v1p3p2.xsd", "1ae9e77aba63b6789574631213c97fd00a3d43aeffb58050ac7befb665fba9f6"),
    "imsqtiv3p0_csmv1p1_v1p0.xsd": (BASE + "imsqtiv3p0_csmv1p1_v1p0.xsd", "caa7ddf900afa66fd5efb212a8834b42480f675de092ae927ce0c95b74443d2e"),
    "imsqti_metadatav3p0_v1p0.xsd": (BASE + "imsqti_metadatav3p0_v1p0.xsd", "448c18d65607695d2a60ce96c42003df98f28630fb044ca14ccc609bad384c8b"),
    "imsqtiv3p0_cpextv1p2_v1p0.xsd": (BASE + "imsqtiv3p0_cpextv1p2_v1p0.xsd", "3f8deb01dd5ac3ad4b81522e159650c01b3dfe199cae6a6be7e87487e790ad85"),
    "imsqtiv3p0_afa3p0drd_v1p0.xsd": (BASE + "imsqtiv3p0_afa3p0drd_v1p0.xsd", "dd3822a3fe0f42af9a25b33be56d11d1a1f3c54ea791bcc355965ceb8f41b064"),
    "xlink.xsd": ("https://purl.imsglobal.org/spec/w3/1999/schema/xsd/xlink.xsd", "e49074eafa608cbf3bc01c2de3406781d466f6ae6adbb90f26cc450d5bf02a1c"),
}
DEFAULT_FILES = (
    "match.xml", "gap.xml", "hottext.xml", "order.xml", "inline-choice.xml", "composite-inline.xml", "hottext-single.xml", "order-subset.xml",
    "assembly-test.xml", "assembly-test-manifest.xml", "interaction-test.xml", "interaction-test-manifest.xml",
    "runtime-test.xml", "feedback-test.xml", "graphic-test.xml",
    "single.xml", "multiple.xml", "numeric.xml", "dependent-response.xml",
    "extended-text-scored.xml", "extended-text.xml", "extended-text-preformatted.xml",
    "hotspot.xml", "graphic-gap.xml", "runtime-test-manifest.xml",
    "feedback-test-manifest.xml", "graphic-test-manifest.xml",
)


def checked_schema_bytes(name):
    path = CACHE / name
    try:
        data = path.read_bytes()
    except OSError as error:
        raise RuntimeError("Cannot read cached schema " + name) from error
    if len(data) > MAX_SCHEMA_BYTES or hashlib.sha256(data).hexdigest() != SCHEMAS[name][1]:
        raise RuntimeError("Cached schema hash mismatch: " + name)
    return data


def cache_schemas(offline=False):
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in SCHEMAS.items():
        path = CACHE / name
        if not path.exists():
            # Share the unchanged XML namespace schema already used by RR tests.
            existing = ROOT / "_build/qti-result-schema" / name
            if name == "xml.xsd" and existing.is_file():
                data = existing.read_bytes()
            elif offline:
                raise RuntimeError("Missing cached schema {}; run once without --offline".format(name))
            else:
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read(MAX_SCHEMA_BYTES + 1)
            if len(data) > MAX_SCHEMA_BYTES or hashlib.sha256(data).hexdigest() != digest:
                raise RuntimeError("Downloaded schema hash mismatch: " + name)
            temporary = path.with_suffix(".download")
            temporary.write_bytes(data)
            temporary.replace(path)
        checked_schema_bytes(name)


class PinnedResolver(etree.Resolver):
    """Resolve official URLs and nested cached includes, with no other access."""

    def __init__(self):
        super().__init__()
        self.urls = {url: name for name, (url, _) in SCHEMAS.items()}
        self.paths = {(CACHE / name).resolve(): name for name in SCHEMAS}

    def resolve(self, url, public_id, context):
        if url in self.urls:
            name = self.urls[url]
        else:
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme not in {"", "file"}:
                raise IOError("Unpinned schema URL")
            decoded = urllib.parse.unquote(parsed.path) if parsed.scheme == "file" else url
            # libxml normalizes local includes to file:/C:/... on Windows.
            if re.match(r"^/[A-Za-z]:/", decoded):
                decoded = decoded[1:]
            name = self.paths.get(Path(decoded).resolve())
            if name is None:
                raise IOError("Unpinned schema dependency")
        checked_schema_bytes(name)
        return self.resolve_filename(str(CACHE / name), context)


def load_schemas(offline=False):
    cache_schemas(offline)
    parser = etree.XMLParser(no_network=True, resolve_entities=False, load_dtd=False)
    parser.resolvers.add(PinnedResolver())
    compiled = {}
    for name in (ASI_SCHEMA, ITEM_SCHEMA, TEST_SCHEMA, CP_SCHEMA):
        schema = etree.XMLSchema(etree.fromstring(checked_schema_bytes(name), parser))
        # Some processors tolerate failed optional imports with a warning. Do
        # not report a successful official-schema check from an incomplete set.
        if schema.error_log:
            raise RuntimeError("Schema compilation diagnostics for " + name)
        compiled[name] = schema
    return compiled


def parse_document(data):
    if len(data) > MAX_XML_BYTES:
        raise ValueError("Assessment XML exceeds 4 MiB validation bound")
    parser = etree.XMLParser(no_network=True, resolve_entities=False, load_dtd=False)
    document = etree.fromstring(data, parser)
    if document.getroottree().docinfo.doctype:
        raise ValueError("Assessment XML must not contain a DTD")
    return document


def applicable_schemas(document):
    if document.tag == "{" + ASI_NAMESPACE + "}qti-assessment-item":
        return (ASI_SCHEMA, ITEM_SCHEMA)
    if document.tag == "{" + ASI_NAMESPACE + "}qti-assessment-test":
        return (ASI_SCHEMA, TEST_SCHEMA)
    if document.tag == "{" + CP_NAMESPACE + "}manifest":
        return (CP_SCHEMA,)
    raise ValueError("Expected a QTI 3 item, test, or manifest root namespace")


def validate_assessment_xml(data, schemas):
    """Check official XSD structure without executing QTI processing rules."""
    document = parse_document(data.encode("utf-8") if isinstance(data, str) else data)
    names = applicable_schemas(document)
    for name in names:
        schemas[name].assertValid(document)
    return document, names


def portable_label(path, index):
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return "input-{}.xml".format(index)


def portable_message(message):
    text = urllib.parse.unquote(str(message))
    for source in (str(ROOT), ROOT.as_posix()):
        text = text.replace(source, ".")
    return text


def negative_checks(documents, schemas):
    checks = []
    item = next((data for data, names in documents if ITEM_SCHEMA in names), None)
    test = next((data for data, names in documents if TEST_SCHEMA in names), None)
    manifest = next((data for data, names in documents if CP_SCHEMA in names), None)
    cases = []
    if item:
        original = parse_document(item)
        declaration = original.find("{" + ASI_NAMESPACE + "}qti-response-declaration")
        if declaration is not None:
            declaration.set("cardinality", "not-a-cardinality")
            cases.append(("Official item XSD rejects invalid cardinality", etree.tostring(original)))
        original = parse_document(item)
        original.attrib.pop("identifier", None)
        cases.append(("Official item XSD requires the item identifier", etree.tostring(original)))
        cases.append(("Document parser rejects DTD declarations", b'<!DOCTYPE qti-assessment-item [<!ENTITY sample "value">]>' + etree.tostring(parse_document(item))))
    if test:
        original = parse_document(test)
        part = original.find("{" + ASI_NAMESPACE + "}qti-test-part")
        if part is not None:
            part.set("navigation-mode", "free-navigation")
            cases.append(("Official test XSD rejects invalid navigation mode", etree.tostring(original)))
    if manifest:
        original = parse_document(manifest)
        version = original.find("{" + CP_NAMESPACE + "}metadata/{" + CP_NAMESPACE + "}schemaversion")
        if version is not None:
            version.text = "3.0.1"
            cases.append(("Official packaging XSD distinguishes package metadata version 3.0.0", etree.tostring(original)))
    for label, data in cases:
        try:
            validate_assessment_xml(data, schemas)
        except (etree.DocumentInvalid, etree.XMLSyntaxError, ValueError):
            checks.append(label)
        else:
            raise AssertionError("Negative validation unexpectedly passed: " + label)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--xml", action="append", type=Path, default=[])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    schemas = load_schemas(args.offline)
    paths = args.xml or [ROOT / "examples" / name for name in DEFAULT_FILES]
    results, documents = [], []
    for index, path in enumerate(paths, 1):
        label = portable_label(path, index)
        try:
            data = path.read_bytes()
        except OSError as error:
            raise RuntimeError("Cannot read assessment input " + label) from error
        try:
            document, names = validate_assessment_xml(data, schemas)
            documents.append((data, names))
            results.append({"file": label, "ok": True, "schemas": list(names)})
        except (etree.DocumentInvalid, etree.XMLSyntaxError, ValueError) as error:
            errors = [{"line": entry.line, "message": portable_message(entry.message)}
                      for entry in getattr(error, "error_log", [])]
            results.append({"file": label, "ok": False,
                            "errors": errors or [{"line": None, "message": portable_message(error)}]})
    negatives = negative_checks(documents, schemas)
    ok = all(result["ok"] for result in results)
    result = {
        "ok": ok,
        "profile": "QTI ASI 3.0.1 assessment XML and QTI 3 content packaging XSD validation",
        "scope": "Official XSD structure of the listed files; processing semantics are verified by separate runtime tests",
        "source_index": SOURCE_INDEX,
        "command": "python tools/asi_schema_test.py" + (" --offline" if args.offline else ""),
        "lxml_version": ".".join(map(str, etree.LXML_VERSION)),
        "schema_hashes": {name: digest for name, (_, digest) in SCHEMAS.items()},
        "documents_checked": len(results),
        "documents_passed": sum(entry["ok"] for entry in results),
        "xsd_checks_passed": sum(len(entry.get("schemas", [])) for entry in results if entry["ok"]),
        "negative_checks_passed": len(negatives),
        "negative_checks": negatives,
        "documents": results,
    }
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, AssertionError, ValueError, OSError, etree.XMLSchemaParseError) as error:
        print("Assessment schema verification failed: " + portable_message(error), file=sys.stderr)
        sys.exit(1)
