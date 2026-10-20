///|
fn package_path_error(value : String) -> QtiError {
  InvalidPackage("package path", "expected a local package path: '\{value}'")
}

///|
// ZIP member names are file names, not URIs: do not percent-decode them.
fn archive_path(name : String) -> String raise QtiError {
  if name == "" ||
    name.length() > 4096 ||
    name.has_prefix("/") ||
    name.contains("\\") ||
    name.contains(":") ||
    name.iter().any(c => c < ' ' || c == '\u007f') {
    raise package_path_error(name)
  }
  let parts = name.split("/").collect()
  for i, part in parts {
    if part == "." || part == ".." || (part == "" && i != parts.length() - 1) {
      raise package_path_error(name)
    }
  }
  name
}

///|
fn hex_digit(value : Byte) -> Int32? {
  if value >= b'0' && value <= b'9' {
    Some(value.to_int() - 48)
  } else if value >= b'A' && value <= b'F' {
    Some(value.to_int() - 55)
  } else if value >= b'a' && value <= b'f' {
    Some(value.to_int() - 87)
  } else {
    None
  }
}

///|
fn decode_package_uri(value : String) -> String raise QtiError {
  if value.length() > 4096 || value.iter().any(c => c <= ' ' || c == '\u007f') {
    raise package_path_error(value)
  }
  let bytes = @utf8.encode(value)
  let output : Array[Byte] = []
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == b'%' {
      if i + 2 >= bytes.length() {
        raise package_path_error(value)
      }
      guard hex_digit(bytes[i + 1]) is Some(hi) &&
        hex_digit(bytes[i + 2]) is Some(lo) else {
        raise package_path_error(value)
      }
      let decoded = (hi * 16 + lo).to_byte()
      // Encoded separators have different interpretations across URI hosts.
      if decoded == b'/' || decoded == b'\\' {
        raise package_path_error(value)
      }
      output.push(decoded)
      i += 3
    } else {
      output.push(bytes[i])
      i += 1
    }
  }
  @utf8.decode(Bytes::from_array(output)[:]) catch {
    _ => raise package_path_error(value)
  }
}

///|
// Resolve an RFC-style relative path against a file or directory base. Only
// local URI references are supported; dot segments may never leave the root.
fn resolve_package_uri(
  base : String,
  reference : String,
  directory~ : Bool = false,
) -> String raise QtiError {
  if reference == "" && directory {
    return base
  }
  if reference.contains("?") || reference.contains("#") {
    raise package_path_error(reference)
  }
  let path = decode_package_uri(reference)
  if path == "" ||
    path.has_prefix("/") ||
    path.contains(":") ||
    path.contains("\\") ||
    path.iter().any(c => c < ' ' || c == '\u007f') {
    raise package_path_error(reference)
  }
  let parts : Array[String] = []
  if base != "" {
    let base_parts = base.split("/").collect()
    for i in 0..<(base_parts.length() - 1) {
      parts.push(base_parts[i].to_owned())
    }
  }
  for part in path.split("/") {
    if part == "." || part == "" {
      continue
    }
    if part == ".." {
      if parts.is_empty() {
        raise package_path_error(reference)
      }
      ignore(parts.pop())
    } else {
      parts.push(part.to_owned())
    }
  }
  let trailing = path.has_suffix("/") ||
    path == "." ||
    path == ".." ||
    path.has_suffix("/.") ||
    path.has_suffix("/..")
  let result = parts.join("/")
  if !directory && (result == "" || trailing) {
    raise package_path_error(reference)
  }
  if result != "" && trailing {
    result + "/"
  } else {
    result
  }
}

///|
fn Node::package_base(self : Node, inherited : String) -> String raise QtiError {
  for attr in self.element.attributes {
    if attr.name.namespace_uri == Some("http://www.w3.org/XML/1998/namespace") &&
      attr.name.local_name == "base" {
      return resolve_package_uri(inherited, attr.value, directory=true)
    }
  }
  inherited
}
