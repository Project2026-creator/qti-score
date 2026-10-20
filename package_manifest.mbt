///|
fn package_manifest(
  xml : String,
) -> (String, Array[PackageResource]) raise QtiError {
  let root = parse_document(xml, Limits::default())
  let ns_uri = root.element.name.namespace_uri.unwrap_or("")
  if root.name() != "manifest" ||
    ![
      "http://www.imsglobal.org/xsd/qti/qtiv3p0/imscp_v1p1", "http://www.imsglobal.org/xsd/imscp_v1p1",
    ].contains(ns_uri) {
    raise Unsupported(
      root.location(),
      "expected a QTI 3 content-package manifest namespace",
    )
  }
  root.only_attributes(["identifier", "version"], allow_base=true)
  root.only_children(["metadata", "organizations", "resources"], ns_uri~)
  let id = identifier(root.required("identifier"), root.location())
  let root_base = root.package_base("")
  ignore(root.one("metadata", required=false, ns_uri~))
  ignore(root.one("organizations", required=false, ns_uri~))
  let resources = root.one("resources", ns_uri~).unwrap()
  resources.only_attributes([], allow_base=true)
  resources.only_children(["resource"], ns_uri~)
  let resources_base = resources.package_base(root_base)
  let result : Array[PackageResource] = []
  if resources.children.length() > 512 {
    raise LimitExceeded("manifest exceeds 512 resources")
  }
  let mut reference_count = 0
  for resource in resources.children {
    reference_count += resource.children.length()
    if reference_count > 4096 {
      raise LimitExceeded("manifest exceeds 4096 resource child references")
    }
    resource.only_attributes(["identifier", "type", "href"], allow_base=true)
    resource.only_children(["metadata", "file", "dependency"], ns_uri~)
    let resource_id = identifier(
      resource.required("identifier"),
      resource.location(),
    )
    if result.any(r => r.identifier == resource_id) {
      raise InvalidPackage(
        resource.location(),
        "duplicate resource identifier '\{resource_id}'",
      )
    }
    let base = resource.package_base(resources_base)
    let href = resource.attr("href").map(s => resolve_package_uri(base, s))
    let files : Array[String] = []
    let dependencies : Array[String] = []
    ignore(resource.one("metadata", required=false, ns_uri~))
    for child in resource.children {
      if child.name() == "file" {
        child.only_attributes(["href"], allow_base=true)
        child.only_children([], ns_uri~)
        let path = resolve_package_uri(
          child.package_base(base),
          child.required("href"),
        )
        if files.contains(path) {
          raise InvalidPackage(
            child.location(),
            "duplicate file reference '\{path}'",
          )
        }
        files.push(path)
      } else if child.name() == "dependency" {
        child.only_attributes(["identifierref"])
        child.only_children([], ns_uri~)
        let dependency = identifier(
          child.required("identifierref"),
          child.location(),
        )
        if dependencies.contains(dependency) {
          raise InvalidPackage(
            child.location(),
            "duplicate dependency '\{dependency}'",
          )
        }
        dependencies.push(dependency)
      }
    }
    result.push({
      identifier: resource_id,
      kind: resource.required("type"),
      href,
      files,
      dependencies,
      source: resource.location(),
    })
  }
  (id, result)
}

///|
// Explicit enter/leave frames keep dependency depth off the call stack.
fn package_closure(
  resource : PackageResource,
  resources : Map[String, PackageResource],
  files : Map[String, Bytes],
) -> (Array[String], Array[QtiError]) {
  let colors : Map[String, Int32] = Map([])
  let paths : Map[String, Bool] = Map([])
  let issues : Array[QtiError] = []
  let stack : Array[(String, Bool)] = [(resource.identifier, false)]
  while stack.pop() is Some((id, leaving)) {
    if leaving {
      colors[id] = 2
      continue
    }
    match colors.get(id) {
      Some(2) => continue
      Some(1) => {
        add_package_issue(
          issues,
          InvalidPackage(resource.source, "dependency cycle at '\{id}'"),
        )
        continue
      }
      _ => ()
    }
    guard resources.get(id) is Some(current) else {
      add_package_issue(
        issues,
        InvalidPackage(resource.source, "unknown dependency '\{id}'"),
      )
      colors[id] = 2
      continue
    }
    colors[id] = 1
    stack.push((id, true))
    if current.href is Some(href) && !current.files.contains(href) {
      add_package_issue(
        issues,
        InvalidPackage(
          current.source,
          "entry href '\{href}' is not listed in resource files",
        ),
      )
    }
    for path in current.files {
      if !files.contains(path) {
        add_package_issue(
          issues,
          InvalidPackage(current.source, "missing package file '\{path}'"),
        )
      }
      paths[path] = true
    }
    for dependency in current.dependencies.rev_iter() {
      stack.push((dependency, false))
    }
  }
  (paths.keys().collect(), issues)
}

///|
fn add_package_issue(issues : Array[QtiError], error : QtiError) -> Unit {
  if issues.length() < 7 {
    issues.push(error)
  } else if issues.length() == 7 {
    issues.push(
      LimitExceeded(
        "further resource issues omitted; at most 8 diagnostics per resource",
      ),
    )
  }
}
