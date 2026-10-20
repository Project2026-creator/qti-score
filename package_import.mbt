///|
/// Import a ZIP package in memory, checking CRCs, paths, manifest references and
/// resource dependencies. Individual item failures are retained in describe().
pub fn read_content_package(
  bytes : Bytes,
  limits~ : PackageLimits = PackageLimits::default(),
) -> ContentPackage raise QtiError {
  if limits.max_archive_bytes <= 0 ||
    limits.max_archive_bytes > 67108864 ||
    limits.max_entries <= 0 ||
    limits.max_entries > 4096 ||
    limits.max_file_bytes <= 0 ||
    limits.max_file_bytes > 16777216 ||
    limits.max_total_bytes <= 0 ||
    limits.max_total_bytes > 134217728 {
    raise InvalidPackage(
      "limits", "positive package limits must stay within 64 MiB archive, 4096 entries, 16 MiB file and 128 MiB expanded data",
    )
  }
  let archive = @zip.read(
    bytes[:],
    limits=@zip.ReadLimits(
      max_package_bytes=limits.max_archive_bytes,
      max_entries=limits.max_entries,
      max_entry_uncompressed_bytes=limits.max_file_bytes,
      max_total_uncompressed_bytes=limits.max_total_bytes,
      max_preserved_source_bytes=limits.max_archive_bytes,
    ),
  ) catch {
    @zip.ZipError(kind, message) =>
      match kind {
        LimitExceeded(_, _, _) => raise LimitExceeded("ZIP: \{message}")
        UnsupportedCompression(_) | UnsupportedFeature =>
          raise Unsupported("ZIP", message)
        _ => raise InvalidPackage("ZIP", message)
      }
  }
  let files : Map[String, Bytes] = Map([])
  let seen : Map[String, Bool] = Map([])
  for entry in archive.entries() {
    let path = archive_path(entry.name())
    if seen.contains(path) {
      raise InvalidPackage("ZIP", "duplicate entry '\{path}'")
    }
    seen[path] = true
    if path.has_suffix("/") {
      if entry.data().length() != 0 {
        raise InvalidPackage("ZIP", "directory entry contains data")
      }
    } else {
      files[path] = entry.data().to_owned()
    }
  }
  guard files.get("imsmanifest.xml") is Some(manifest_bytes) else {
    raise InvalidPackage("ZIP", "root imsmanifest.xml is missing")
  }
  let xml = @utf8.decode(manifest_bytes[:], ignore_bom=true) catch {
    _ => raise InvalidPackage("imsmanifest.xml", "manifest must be UTF-8")
  }
  let (identifier, resources) = package_manifest(xml) catch {
    InvalidItem(location, message) => raise InvalidPackage(location, message)
    e => raise e
  }
  let by_id : Map[String, PackageResource] = Map([])
  for resource in resources {
    by_id[resource.identifier] = resource
  }
  let resolved : Map[String, Array[String]] = Map([])
  let issues : Map[String, Array[QtiError]] = Map([])
  let imported : Array[PackageItem] = []
  let compiled_paths : Map[String, Item] = Map([])
  let failed_paths : Map[String, QtiError] = Map([])
  for resource in resources {
    let (paths, diagnostics) = package_closure(resource, by_id, files)
    resolved[resource.identifier] = paths
    issues[resource.identifier] = diagnostics
    if resource.kind != "imsqti_item_xmlv3p0" {
      continue
    }
    let item : Item? = try {
      if !diagnostics.is_empty() {
        raise diagnostics[0]
      }
      guard resource.href is Some(path) else {
        raise InvalidPackage(
          resource.source,
          "item resource requires an entry href",
        )
      }
      if failed_paths.get(path) is Some(error) {
        raise error
      }
      if compiled_paths.get(path) is Some(item) {
        Some(item)
      } else {
        let outcome : Result[Item, QtiError] = try {
          let data = files.get(path).unwrap()
          let source = @utf8.decode(data[:], ignore_bom=true) catch {
            _ => raise InvalidPackage(path, "item XML must be UTF-8")
          }
          Ok(compile_item(source))
        } catch {
          error => Err(error)
        }
        let item = match outcome {
          Ok(item) => item
          Err(error) => {
            failed_paths[path] = error
            raise error
          }
        }
        compiled_paths[path] = item
        Some(item)
      }
    } catch {
      error => {
        imported.push({
          resource_id: resource.identifier,
          path: resource.href,
          item: None,
          error: Some(error),
        })
        None
      }
    }
    if item is Some(_) {
      imported.push({
        resource_id: resource.identifier,
        path: resource.href,
        item,
        error: None,
      })
    }
  }
  { identifier, files, resources, imported, resolved, issues, }
}

///|
/// Get a supported compiled item by manifest resource identifier. A returned
/// item remains usable independently of the package's host-side lifetime.
pub fn ContentPackage::item(
  self : ContentPackage,
  resource_id : String,
) -> Item raise QtiError {
  for entry in self.imported {
    if entry.resource_id == resource_id {
      if entry.item is Some(item) {
        return item
      }
      raise entry.error.unwrap()
    }
  }
  raise InvalidPackage("resource", "no QTI 3 item resource '\{resource_id}'")
}

///|
/// Read an exact, case-sensitive archive path; this does not resolve a URI.
pub fn ContentPackage::read_file(
  self : ContentPackage,
  path : String,
) -> Bytes raise QtiError {
  ignore(archive_path(path))
  guard self.files.get(path) is Some(data) else {
    raise InvalidPackage("resource", "missing package file '\{path}'")
  }
  data
}

///|
/// Files declared by a resource and its transitive dependencies. A fresh array
/// is returned, even when the resource has diagnostics in describe().
pub fn ContentPackage::resource_files(
  self : ContentPackage,
  resource_id : String,
) -> Array[String] raise QtiError {
  guard self.resolved.get(resource_id) is Some(paths) else {
    raise InvalidPackage("resource", "unknown resource '\{resource_id}'")
  }
  paths.copy()
}

///|
/// A fresh report. Metadata and organization trees are not executed. Reports
/// do not expose correct responses, maps, or file contents.
pub fn ContentPackage::describe(self : ContentPackage) -> Json {
  let resources : Array[Json] = self.resources.map(resource => {
    let href : Json = match resource.href {
      Some(path) => Json(path)
      None => Json::null()
    }
    {
      "identifier": resource.identifier,
      "type": resource.kind,
      "href": href,
      "files": resource.files,
      "dependencies": resource.dependencies,
      "resolved_file_count": self.resolved[resource.identifier].length(),
      "issues": self.issues[resource.identifier],
    }
  })
  let items : Array[Json] = self.imported.map(entry => {
    let path : Json = match entry.path {
      Some(path) => Json(path)
      None => Json::null()
    }
    let metadata : Json = match entry.item {
      Some(item) => item.describe()
      None => Json::null()
    }
    let error : Json = match entry.error {
      Some(error) => error.to_json()
      None => Json::null()
    }
    let status = match entry.error {
      None => "ready"
      Some(Unsupported(_, _)) => "unsupported"
      _ => "invalid"
    }
    {
      "resource_id": entry.resource_id,
      "path": path,
      "status": status,
      "item": metadata,
      "error": error,
    }
  })
  {
    "identifier": self.identifier,
    "file_count": self.files.length(),
    "files": self.files.keys().collect(),
    "resources": resources,
    "items": items,
    "ready_count": self.imported.filter(entry => entry.item is Some(_)).length(),
  }
}
