///|
fn manifest(resources : String, extra~ : String = "") -> String {
  "<manifest xmlns=\"http://www.imsglobal.org/xsd/qti/qtiv3p0/imscp_v1p1\" identifier=\"bank\" \{extra}><resources>\{resources}</resources></manifest>"
}

///|
fn item_resource(
  id : String,
  path : String,
  dependencies~ : String = "",
) -> String {
  "<resource identifier=\"\{id}\" type=\"imsqti_item_xmlv3p0\" href=\"\{path}\"><file href=\"\{path}\"/>\{dependencies}</resource>"
}

///|
fn content_zip(
  files : Array[(String, String)],
  compression~ : @zip.Compression = Deflate,
  descriptor~ : Bool = false,
) -> Bytes raise {
  let archive = @zip.Archive()
  for (name, value) in files {
    archive.add(
      name,
      @utf8.encode(value)[:],
      compression~,
      data_descriptor=descriptor,
    )
  }
  @zip.write(archive)
}

///|
fn reject_package(bytes : Bytes, code : String) -> Unit raise {
  try @qti.read_content_package(bytes) catch {
    error => assert_eq(error.code(), code)
  } noraise {
    _ => fail("expected package rejection")
  }
}

///|
test "stored, deflated and descriptor packages use the same MoonBit scoring core" {
  let xml = manifest(item_resource("resource-id", "items/single.xml"))
  for compression in [@zip.Compression::Store, Deflate] {
    for descriptor in [false, true] {
      let bundle = @qti.read_content_package(
        content_zip(
          [("imsmanifest.xml", xml), ("items/single.xml", fixture("single"))],
          compression~,
          descriptor~,
        ),
      )
      assert_eq(bundle.identifier, "bank")
      let item = bundle.item("resource-id")
      assert_eq(item.identifier, "formative")
      assert_eq(item.score(Single("A")).score, 1.0)
      assert_true(bundle.describe() is { "ready_count": Number(1.0, ..), .. })
    }
  }
}

///|
test "one unsupported item does not prevent importing and scoring supported items" {
  let source = @fs.read_file_to_string("examples/package-manifest.xml")
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", source),
      ("items/single.xml", fixture("single")),
      ("items/numeric.xml", fixture("numeric")),
      ("items/essay.xml", fixture("essay")),
      ("assets/note.txt", "shared"),
    ]),
  )
  assert_eq(bundle.item("measurement").score(Number(100.5)).score, 1.0)
  guard bundle.describe()
    is { "ready_count": Number(2.0, ..), "items": Array(items), .. } else {
    fail("expected import report")
  }
  assert_eq(items.length(), 3)
  assert_true(
    items[2]
    is {
      "status": String("unsupported"),
      "error": { "code": String("unsupported"), .. },
      ..
    },
  )
  try bundle.item("essay") catch {
    e => assert_eq(e.code(), "unsupported")
  } noraise {
    _ => fail("expected unsupported item")
  }
}

///|
test "manifest namespace prefixes and the common CP namespace are accepted" {
  let source = manifest(item_resource("one", "a.xml"))
  let prefixed = source
    .replace_all(old="xmlns="[:], new="xmlns:c="[:])
    .replace_all(old="<manifest"[:], new="<c:manifest"[:])
    .replace_all(old="</manifest"[:], new="</c:manifest"[:])
    .replace_all(old="<resources"[:], new="<c:resources"[:])
    .replace_all(old="</resources"[:], new="</c:resources"[:])
    .replace_all(old="<resource "[:], new="<c:resource "[:])
    .replace_all(old="</resource>"[:], new="</c:resource>"[:])
    .replace_all(old="<file "[:], new="<c:file "[:])
  for
    xml in [
      source,
      prefixed,
      source.swap("qti/qtiv3p0/imscp_v1p1", "imscp_v1p1"),
    ] {
    let bundle = @qti.read_content_package(
      content_zip([("imsmanifest.xml", xml), ("a.xml", fixture("single"))]),
    )
    assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  }
}

///|
test "xml base inheritance resolves each URI from its containing element" {
  let source = manifest(
    "<resource identifier=\"one\" type=\"imsqti_item_xmlv3p0\" xml:base=\"items/\" href=\"single.xml\"><file href=\"single.xml\"/><file xml:base=\"../assets/\" href=\"note.txt\"/></resource>",
    extra="xml:base=\"course/\"",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", source),
      ("course/items/single.xml", fixture("single")),
      ("course/assets/note.txt", "asset"),
    ]),
  )
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  assert_eq(bundle.resource_files("one"), [
    "course/items/single.xml", "course/assets/note.txt",
  ])
  let file_base = manifest(
    item_resource("one", "single.xml"),
    extra="xml:base=\"folder/base.xml\"",
  )
  assert_eq(
    @qti.read_content_package(
      content_zip([
        ("imsmanifest.xml", file_base),
        ("folder/single.xml", fixture("single")),
      ]),
    )
    .item("one")
    .score(Single("A")).score,
    1.0,
  )
}

///|
test "URI decoding is UTF-8, exactly once, and differs from ZIP member names" {
  let source = manifest(item_resource("one", "题目%20%23%252F.xml"))
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", source),
      ("题目 #%2F.xml", fixture("single")),
    ]),
  )
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  assert_eq(bundle.resource_files("one"), ["题目 #%2F.xml"])
  assert_true(bundle.read_file("题目 #%2F.xml").length() > 0)
}

///|
test "local dot segments normalize within the package without escaping root" {
  let source = manifest(item_resource("one", "items/.././a.xml"))
  let bundle = @qti.read_content_package(
    content_zip([("imsmanifest.xml", source), ("a.xml", fixture("single"))]),
  )
  assert_eq(bundle.resource_files("one"), ["a.xml"])
}

///|
test "unsafe archive names are rejected even when unreferenced" {
  for
    path in [
      "../escape", "/absolute", "C:/drive", "a\\b", "a/../b", "a//b", "./a",
    ] {
    let bytes = content_zip([("imsmanifest.xml", manifest("")), (path, "data")])
    reject_package(bytes, "invalid_package")
  }
}

///|
test "external, ambiguous and root-escaping manifest URIs fail closed" {
  for
    path in [
      "../a.xml", "%2e%2e/a.xml", "https://example.org/a.xml", "//host/a.xml", "a%2Fb.xml",
      "a%5Cb.xml", "a?x", "a#x", "%xx", "%FF",
    ] {
    let bytes = content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", path))),
    ])
    reject_package(bytes, "invalid_package")
  }
}

///|
test "manifest must be at root and duplicate ZIP members are rejected" {
  reject_package(
    content_zip([("folder/imsmanifest.xml", manifest(""))]),
    "invalid_package",
  )
  reject_package(
    content_zip([
      ("imsmanifest.xml", manifest("")),
      ("imsmanifest.xml", manifest("")),
    ]),
    "invalid_package",
  )
  reject_package(b"not a zip", "invalid_package")
}

///|
test "duplicate resource identities and foreign manifest elements are rejected" {
  reject_package(
    content_zip([
      (
        "imsmanifest.xml",
        manifest(item_resource("one", "a.xml") + item_resource("one", "b.xml")),
      ),
    ]),
    "invalid_package",
  )
  let source = manifest(
    "<x:resource xmlns:x=\"urn:wrong\" identifier=\"fake\" type=\"webcontent\"/>",
  )
  reject_package(content_zip([("imsmanifest.xml", source)]), "unsupported")
  reject_package(
    content_zip([("imsmanifest.xml", "<manifest>")]),
    "invalid_xml",
  )
}

///|
test "missing shared files invalidate dependents while unrelated items remain ready" {
  let dependencies = "<dependency identifierref=\"shared\"/>"
  let source = manifest(
    item_resource("affected", "a.xml", dependencies~) +
    item_resource("good", "b.xml") +
    "<resource identifier=\"shared\" type=\"webcontent\"><file href=\"missing.txt\"/></resource>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", source),
      ("a.xml", fixture("single")),
      ("b.xml", fixture("single")),
    ]),
  )
  assert_eq(bundle.item("good").score(Single("A")).score, 1.0)
  try bundle.item("affected") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("expected missing dependency file")
  }
  assert_true(bundle.describe() is { "ready_count": Number(1.0, ..), .. })
}

///|
test "dependency diamonds deduplicate files and cycles are reported without recursion" {
  let source = manifest(
    item_resource(
      "one",
      "a.xml",
      dependencies="<dependency identifierref=\"left\"/><dependency identifierref=\"right\"/>",
    ) +
    "<resource identifier=\"left\" type=\"webcontent\"><dependency identifierref=\"shared\"/></resource>" +
    "<resource identifier=\"right\" type=\"webcontent\"><dependency identifierref=\"shared\"/></resource>" +
    "<resource identifier=\"shared\" type=\"webcontent\"><file href=\"asset.txt\"/></resource>",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", source),
      ("a.xml", fixture("single")),
      ("asset.txt", "shared"),
    ]),
  )
  assert_eq(bundle.resource_files("one"), ["a.xml", "asset.txt"])
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  let cycle = source.swap(
    "<file href=\"asset.txt\"/>", "<file href=\"asset.txt\"/><dependency identifierref=\"one\"/>",
  )
  let cyclic = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", cycle),
      ("a.xml", fixture("single")),
      ("asset.txt", "shared"),
    ]),
  )
  assert_true(cyclic.describe() is { "ready_count": Number(0.0, ..), .. })
}

///|
test "unknown dependencies, missing entry points and unlisted entries produce item diagnostics" {
  let good = fixture("single")
  for
    resource in [
      item_resource(
        "one",
        "a.xml",
        dependencies="<dependency identifierref=\"unknown\"/>",
      ),
      "<resource identifier=\"one\" type=\"imsqti_item_xmlv3p0\"><file href=\"a.xml\"/></resource>",
      "<resource identifier=\"one\" type=\"imsqti_item_xmlv3p0\" href=\"a.xml\"/>",
    ] {
    let bundle = @qti.read_content_package(
      content_zip([("imsmanifest.xml", manifest(resource)), ("a.xml", good)]),
    )
    try bundle.item("one") catch {
      e => assert_eq(e.code(), "invalid_package")
    } noraise {
      _ => fail("expected resource diagnostic")
    }
  }
}

///|
test "package limits guard archive size, entries, per-file size and expanded total" {
  let bytes = content_zip([
    ("imsmanifest.xml", manifest(item_resource("one", "a.xml"))),
    ("a.xml", fixture("single")),
  ])
  let defaults = @qti.PackageLimits::default()
  for
    limits in [
      { ..defaults, max_archive_bytes: 10, },
      { ..defaults, max_entries: 1, },
      { ..defaults, max_file_bytes: 20, },
      { ..defaults, max_total_bytes: 20, },
    ] {
    try @qti.read_content_package(bytes, limits~) catch {
      e => assert_eq(e.code(), "limit_exceeded")
    } noraise {
      _ => fail("expected ZIP budget rejection")
    }
  }
  let invalid = { ..defaults, max_entries: 0, }
  try @qti.read_content_package(bytes, limits=invalid) catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("expected invalid limits")
  }
}

///|
test "CRC corruption is detected before returning package contents" {
  let bytes = content_zip(
    [("imsmanifest.xml", manifest("")), ("marker.txt", "unique payload marker")],
    compression=Store,
  )
  let offset = bytes.find(b"unique payload marker").unwrap()
  let changed = bytes.to_array()
  changed[offset] = b'X'
  reject_package(Bytes::from_array(changed), "invalid_package")
  reject_package(bytes[:bytes.length() - 10].to_owned(), "invalid_package")
}

///|
test "reports and resolved file arrays cannot mutate compiled package state" {
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", manifest(item_resource("one", "a.xml"))),
      ("a.xml", fixture("single")),
    ]),
  )
  bundle.resource_files("one").clear()
  let report = bundle.describe()
  guard report is { "files": Array(files), .. } else { fail("expected files") }
  files.clear()
  assert_eq(bundle.resource_files("one"), ["a.xml"])
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  for id in ["unknown", "formative"] {
    try bundle.item(id) catch {
      e => assert_eq(e.code(), "invalid_package")
    } noraise {
      _ => fail("resource IDs are package keys")
    }
  }
}

///|
test "invalid UTF-8 item data is isolated and binary assets stay byte-exact" {
  let archive = @zip.Archive()
  let xml = manifest(
    item_resource("one", "bad.xml") + item_resource("two", "good.xml"),
  )
  archive.add("imsmanifest.xml", @utf8.encode(xml)[:])
  archive.add("bad.xml", b"\xff\xfe"[:])
  archive.add("good.xml", @utf8.encode(fixture("single"))[:])
  archive.add("binary.bin", b"\x00\xff\x80"[:])
  let bundle = @qti.read_content_package(@zip.write(archive))
  assert_eq(bundle.read_file("binary.bin"), b"\x00\xff\x80")
  assert_eq(bundle.item("two").score(Single("A")).score, 1.0)
  try bundle.item("one") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("invalid UTF-8 must not be replaced silently")
  }
}

///|
test "directory entries, case-sensitive paths and resources xml base are handled" {
  let xml = manifest(item_resource("one", "A.xml")).swap(
    "<resources>", "<resources xml:base=\"items/\">",
  )
  let bundle = @qti.read_content_package(
    content_zip([
      ("imsmanifest.xml", xml),
      ("items/", ""),
      ("items/A.xml", fixture("single")),
    ]),
  )
  assert_eq(bundle.resource_files("one"), ["items/A.xml"])
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  try bundle.read_file("items/a.xml") catch {
    e => assert_eq(e.code(), "invalid_package")
  } noraise {
    _ => fail("archive paths must preserve case")
  }
  reject_package(
    content_zip([("imsmanifest.xml", manifest("")), ("items/", "payload")]),
    "invalid_package",
  )
}

///|
test "long dependency chains and many missing files have bounded diagnostics" {
  let resources : Array[String] = []
  resources.push(
    item_resource(
      "one",
      "a.xml",
      dependencies="<dependency identifierref=\"r0\"/>",
    ),
  )
  for i in 0..<250 {
    let dependency = if i < 249 {
      "<dependency identifierref=\"r\{i + 1}\"/>"
    } else {
      ""
    }
    resources.push(
      "<resource identifier=\"r\{i}\" type=\"webcontent\">\{dependency}</resource>",
    )
  }
  let source = manifest(resources.join(""))
  let bundle = @qti.read_content_package(
    content_zip([("imsmanifest.xml", source), ("a.xml", fixture("single"))]),
  )
  assert_eq(bundle.item("one").score(Single("A")).score, 1.0)
  let missing = Array::makei(20, i => "<file href=\"missing\{i}.txt\"/>").join(
    "",
  )
  let broken = @qti.read_content_package(
    content_zip([
      (
        "imsmanifest.xml",
        manifest(
          "<resource identifier=\"asset\" type=\"webcontent\">\{missing}</resource>",
        ),
      ),
    ]),
  )
  guard broken.describe() is { "resources": Array(rows), .. } else {
    fail("expected resources")
  }
  guard rows[0] is { "issues": Array(issues), .. } else {
    fail("expected issues")
  }
  assert_eq(issues.length(), 8)
  assert_true(issues[7] is { "code": String("limit_exceeded"), .. })
}

///|
test "metadata stays inert and shared item files can have different resource keys" {
  let xml = manifest(
    item_resource("one", "a.xml") + item_resource("two", "a.xml"),
  ).swap(
    "<resources>", "<metadata><x:entry xmlns:x=\"urn:metadata\">text</x:entry></metadata><organizations/><resources>",
  )
  let bundle = @qti.read_content_package(
    content_zip([("imsmanifest.xml", xml), ("a.xml", fixture("single"))]),
  )
  assert_eq(
    bundle.item("one").score(Single("A")).score,
    bundle.item("two").score(Single("A")).score,
  )
  assert_true(bundle.describe() is { "ready_count": Number(2.0, ..), .. })
}
