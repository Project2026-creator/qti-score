///|
/// Bounds apply before ZIP expansion. XML inside the package also uses Limits.
pub(all) struct PackageLimits {
  max_archive_bytes : Int32
  max_entries : Int32
  max_file_bytes : Int32
  max_total_bytes : Int32
} derive(Debug, Eq)

///|
pub fn PackageLimits::default() -> PackageLimits {
  {
    max_archive_bytes: 8388608,
    max_entries: 512,
    max_file_bytes: 4194304,
    max_total_bytes: 16777216,
  }
}

///|
priv struct PackageResource {
  identifier : String
  kind : String
  href : String?
  files : Array[String]
  dependencies : Array[String]
  source : String
}

///|
priv struct PackageItem {
  resource_id : String
  path : String?
  item : AssessmentItem?
  error : QtiError?
}

///|
/// Imported files and compiled items stay in memory. No files are extracted and
/// no referenced URLs are fetched. Resource IDs, not item identifiers, are keys.
pub struct ContentPackage {
  identifier : String
  priv files : Map[String, Bytes]
  priv resources : Array[PackageResource]
  priv imported : Array[PackageItem]
  priv resolved : Map[String, Array[String]]
  priv issues : Map[String, Array[QtiError]]
}

///|
pub extend PackageLimits with Eq::{equal, not_equal}

///|
pub extend PackageLimits with Debug::{to_repr}
