///|
/// Resolve a manifest test resource and its local section/item references.
/// Referenced documents must have the matching QTI manifest resource kind.
pub fn ContentPackage::compile_test(
  self : ContentPackage,
  resource_id : String,
) -> AssessmentTest raise QtiError {
  guard self.resources.filter(r => r.identifier == resource_id).get(0)
    is Some(resource) else {
    raise InvalidPackage("resource", "unknown test resource '\{resource_id}'")
  }
  if resource.kind != "imsqti_test_xmlv3p0" {
    raise InvalidPackage(resource.source, "resource is not a QTI 3 test")
  }
  if self.issues[resource_id].get(0) is Some(error) {
    raise error
  }
  guard resource.href is Some(path) else {
    raise InvalidPackage(
      resource.source,
      "test resource requires an entry href",
    )
  }
  let source = @utf8.decode(self.read_file(path)[:], ignore_bom=true) catch {
    _ => raise InvalidPackage(path, "test XML must be UTF-8")
  }
  let items : Map[String, AssessmentItem] = Map([])
  let item_errors : Map[String, QtiError] = Map([])
  let resource_ids : Map[String, String] = Map([])
  let section_sources : Map[String, Bytes] = Map([])
  let section_errors : Map[String, QtiError] = Map([])
  for candidate in self.resources {
    if candidate.href is Some(href) {
      if candidate.kind == "imsqti_item_xmlv3p0" {
        if resource_ids.contains(href) {
          raise InvalidPackage(
            candidate.source,
            "ambiguous item resource href '\{href}'",
          )
        }
        resource_ids[href] = candidate.identifier
        try self.assessment_item(candidate.identifier) catch {
          error => item_errors[href] = error
        } noraise {
          item => items[href] = item
        }
      } else if candidate.kind == "imsqti_section_xmlv3p0" {
        if section_sources.contains(href) {
          raise InvalidPackage(
            candidate.source,
            "ambiguous section resource href '\{href}'",
          )
        }
        if self.issues[candidate.identifier].get(0) is Some(error) {
          section_errors[href] = error
        } else {
          section_sources[href] = self.read_file(href)
        }
      }
    }
  }
  compile_test_document(
    source,
    path,
    items,
    item_errors,
    resource_ids,
    section_sources,
    section_errors,
    Limits::default(),
  )
}
