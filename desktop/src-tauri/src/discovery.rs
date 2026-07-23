#[cfg(target_os = "linux")]
use directories::BaseDirs;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs, io,
    path::{Path, PathBuf},
    thread,
    time::Duration,
};
use walkdir::{DirEntry, WalkDir};

pub fn default_roots() -> Vec<PathBuf> {
    let mut candidates = BTreeSet::new();
    #[cfg(target_os = "windows")]
    {
        for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
            if let Some(root) = std::env::var_os(variable) {
                candidates.insert(PathBuf::from(root).join("World of Warcraft"));
            }
        }
        for drive in ["C", "D", "E", "F", "G"] {
            candidates.insert(PathBuf::from(format!(r"{drive}:\World of Warcraft")));
        }
        candidates.extend(battle_net_install_roots());
    }
    #[cfg(target_os = "macos")]
    {
        candidates.insert(PathBuf::from("/Applications/World of Warcraft"));
    }
    #[cfg(target_os = "linux")]
    if let Some(base) = BaseDirs::new() {
        for suffix in [
            "Games/World of Warcraft",
            ".wine/drive_c/Program Files (x86)/World of Warcraft",
            ".local/share/Steam/steamapps/compatdata",
        ] {
            candidates.insert(base.home_dir().join(suffix));
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            if ancestor
                .file_name()
                .is_some_and(|name| name.eq_ignore_ascii_case("World of Warcraft"))
            {
                candidates.insert(ancestor.to_path_buf());
                break;
            }
        }
    }
    candidates
        .into_iter()
        .filter(|path| path.exists())
        .collect()
}

pub fn discover_saved_variables(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut found = BTreeSet::new();
    for root in roots {
        let start = normalize_scan_root(root);
        if !start.exists() {
            continue;
        }
        for entry in WalkDir::new(&start)
            .follow_links(false)
            .max_depth(12)
            .into_iter()
            .filter_entry(relevant_entry)
            .filter_map(Result::ok)
        {
            if entry.file_type().is_file() && is_ember_sync_candidate_file(entry.path()) {
                found.insert(primary_saved_variables_path(entry.path()));
            }
        }
    }
    found.into_iter().collect()
}

/// Convert any useful selection inside a Retail installation into the narrowest
/// stable directory that contains account SavedVariables. This lets someone
/// select World of Warcraft, _retail_, WTF, Interface/AddOns, or the EmberSync
/// addon itself without making the watcher monitor game data and cache files.
pub fn normalize_configured_root(root: &Path) -> PathBuf {
    let canonical = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());

    for ancestor in canonical.ancestors() {
        if ancestor
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("WTF"))
        {
            return ancestor.to_path_buf();
        }
        if ancestor
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("_retail_"))
        {
            let wtf = ancestor.join("WTF");
            return if wtf.exists() {
                wtf
            } else {
                ancestor.to_path_buf()
            };
        }
    }

    for ancestor in canonical.ancestors() {
        for suffix in [PathBuf::from("_retail_").join("WTF"), PathBuf::from("WTF")] {
            let candidate = ancestor.join(suffix);
            if candidate.exists() {
                return candidate;
            }
        }
    }

    canonical
}

fn normalize_scan_root(root: &Path) -> PathBuf {
    if root
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("WTF"))
    {
        return root.to_path_buf();
    }
    for suffix in [PathBuf::from("_retail_").join("WTF"), PathBuf::from("WTF")] {
        let candidate = root.join(&suffix);
        if candidate.exists() {
            return candidate;
        }
    }
    root.to_path_buf()
}

fn relevant_entry(entry: &DirEntry) -> bool {
    let name = entry.file_name().to_string_lossy();
    !entry.file_type().is_dir()
        || !matches!(
            name.as_ref(),
            "Cache" | "Logs" | "Screenshots" | "Data" | "_classic_" | "_classic_era_"
        )
}

#[cfg(test)]
pub fn is_ember_sync_file(path: &Path) -> bool {
    is_ember_sync_candidate_file(path)
        && path
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("EmberSync.lua"))
}

pub fn is_ember_sync_candidate_file(path: &Path) -> bool {
    if !path.file_name().is_some_and(|name| {
        name.eq_ignore_ascii_case("EmberSync.lua") || name.eq_ignore_ascii_case("EmberSync.lua.bak")
    }) {
        return false;
    }
    let Some(saved_variables) = path.parent() else {
        return false;
    };
    if !saved_variables
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("SavedVariables"))
    {
        return false;
    }
    let Some(account_id) = saved_variables.parent() else {
        return false;
    };
    let Some(account) = account_id.parent() else {
        return false;
    };
    let Some(wtf) = account.parent() else {
        return false;
    };
    account
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("Account"))
        && wtf
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("WTF"))
}

pub fn primary_saved_variables_path(path: &Path) -> PathBuf {
    if path
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("EmberSync.lua.bak"))
    {
        path.with_file_name("EmberSync.lua")
    } else {
        path.to_path_buf()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileFingerprint {
    len: u64,
    modified_nanos: u128,
}

pub fn saved_variables_fingerprints(roots: &[PathBuf]) -> BTreeMap<PathBuf, FileFingerprint> {
    let mut fingerprints = BTreeMap::new();
    for primary in discover_saved_variables(roots) {
        for candidate in [
            primary.clone(),
            PathBuf::from(format!("{}.bak", primary.display())),
        ] {
            if let Ok(metadata) = fs::metadata(&candidate) {
                let modified_nanos = metadata
                    .modified()
                    .ok()
                    .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0, |value| value.as_nanos());
                fingerprints.insert(
                    candidate,
                    FileFingerprint {
                        len: metadata.len(),
                        modified_nanos,
                    },
                );
            }
        }
    }
    fingerprints
}

#[cfg(target_os = "windows")]
fn battle_net_install_roots() -> Vec<PathBuf> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut roots = BTreeSet::new();
    for key in [
        r"HKCU\Software\Blizzard Entertainment\Battle.net\Launch Options\WoW",
        r"HKLM\SOFTWARE\Blizzard Entertainment\World of Warcraft",
        r"HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
    ] {
        let output = std::process::Command::new("reg.exe")
            .args(["query", key, "/v", "InstallPath"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
        if let Ok(output) = output {
            if output.status.success() {
                if let Some(path) =
                    parse_registry_install_path(&String::from_utf8_lossy(&output.stdout))
                {
                    roots.insert(PathBuf::from(path));
                }
            }
        }
    }
    if let Some(path) = battle_net_aggregate_path() {
        if let Ok(bytes) = read_bounded_json(&path, 4 * 1024 * 1024) {
            roots.extend(parse_battle_net_aggregate_install_roots(&bytes));
        }
    }
    roots.into_iter().collect()
}

#[cfg(not(target_os = "windows"))]
fn battle_net_install_roots() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "windows")]
fn battle_net_aggregate_path() -> Option<PathBuf> {
    std::env::var_os("ProgramData")
        .map(PathBuf::from)
        .or_else(|| Some(PathBuf::from(r"C:\ProgramData")))
        .map(|root| root.join("Battle.net").join("Agent").join("aggregate.json"))
}

fn read_bounded_json(path: &Path, maximum_bytes: u64) -> io::Result<Vec<u8>> {
    let metadata = fs::metadata(path)?;
    if !metadata.is_file() || metadata.len() > maximum_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Battle.net installation catalog exceeds the safe size limit",
        ));
    }
    let bytes = fs::read(path)?;
    if bytes.len() as u64 > maximum_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Battle.net installation catalog grew beyond the safe size limit",
        ));
    }
    Ok(bytes)
}

fn parse_battle_net_aggregate_install_roots(bytes: &[u8]) -> Vec<PathBuf> {
    let Ok(catalog) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return Vec::new();
    };
    let Some(installed) = catalog.get("installed").and_then(|value| value.as_array()) else {
        return Vec::new();
    };

    installed
        .iter()
        .filter(|entry| entry.get("product_id").and_then(|value| value.as_str()) == Some("wow"))
        .filter_map(|entry| {
            entry
                .get("icon_path")
                .and_then(|value| value.as_str())
                .and_then(install_root_from_battle_net_icon)
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn install_root_from_battle_net_icon(icon_path: &str) -> Option<PathBuf> {
    if icon_path.is_empty()
        || icon_path.len() > 4096
        || icon_path.contains('\0')
        || !looks_like_absolute_path(icon_path)
    {
        return None;
    }

    let path = PathBuf::from(icon_path);
    let executable_parent = path.parent()?;
    if executable_parent
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("_retail_"))
    {
        return executable_parent.parent().map(Path::to_path_buf);
    }
    Some(executable_parent.to_path_buf())
}

fn looks_like_absolute_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    Path::new(value).is_absolute()
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'/' | b'\\'))
}

fn parse_registry_install_path(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let marker = if line.contains("REG_EXPAND_SZ") {
            "REG_EXPAND_SZ"
        } else if line.contains("REG_SZ") {
            "REG_SZ"
        } else {
            return None;
        };
        let (_, value) = line.split_once(marker)?;
        let value = value.trim().trim_matches('"');
        (!value.is_empty()).then(|| value.to_owned())
    })
}

pub fn read_stable(path: &Path) -> io::Result<Vec<u8>> {
    let mut last_error = None;
    for _ in 0..5 {
        match stable_attempt(path) {
            Ok(Some(bytes)) => return Ok(bytes),
            Ok(None) => thread::sleep(Duration::from_millis(250)),
            Err(error) => {
                last_error = Some(error);
                thread::sleep(Duration::from_millis(250));
            }
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "SavedVariables file did not become stable",
        )
    }))
}

fn stable_attempt(path: &Path) -> io::Result<Option<Vec<u8>>> {
    let before = fs::metadata(path)?;
    if before.len() > crate::lua::MAX_INPUT_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "SavedVariables file exceeds size limit",
        ));
    }
    let bytes = fs::read(path)?;
    thread::sleep(Duration::from_millis(150));
    let after = fs::metadata(path)?;
    let stable = before.len() == after.len()
        && before.modified().ok() == after.modified().ok()
        && bytes.len() as u64 == after.len();
    Ok(stable.then_some(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn finds_only_account_saved_variables_files() {
        let root = tempdir().unwrap();
        let target = root
            .path()
            .join("_retail_/WTF/Account/ACCOUNT/SavedVariables/EmberSync.lua");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, "EmberSyncDB={}").unwrap();
        let fake = root.path().join("EmberSync.lua");
        fs::write(&fake, "bad").unwrap();
        assert_eq!(
            discover_saved_variables(&[root.path().to_path_buf()]),
            vec![target]
        );
        assert!(!is_ember_sync_file(&fake));
    }

    #[test]
    fn backup_only_exports_are_discovered_as_their_primary_path() {
        let root = tempdir().unwrap();
        let primary = root
            .path()
            .join("_retail_/WTF/Account/ACCOUNT/SavedVariables/EmberSync.lua");
        fs::create_dir_all(primary.parent().unwrap()).unwrap();
        fs::write(
            PathBuf::from(format!("{}.bak", primary.display())),
            "EmberSyncDB={}",
        )
        .unwrap();
        assert_eq!(
            discover_saved_variables(&[root.path().to_path_buf()]),
            vec![primary]
        );
    }

    #[test]
    fn registry_output_parser_preserves_paths_with_spaces() {
        let output = r#"
HKEY_CURRENT_USER\Software\Blizzard Entertainment\Battle.net\Launch Options\WoW
    InstallPath    REG_SZ    G:\Battlenet\World of Warcraft
"#;
        assert_eq!(
            parse_registry_install_path(output).as_deref(),
            Some(r"G:\Battlenet\World of Warcraft")
        );
    }

    #[test]
    fn battle_net_aggregate_fixture_discovers_only_the_retail_install() {
        let fixture = include_bytes!("../fixtures/battle-net-aggregate.json");
        assert_eq!(
            parse_battle_net_aggregate_install_roots(fixture),
            vec![PathBuf::from(r"G:/Battlenet/World of Warcraft")]
        );
    }

    #[test]
    fn battle_net_aggregate_rejects_malformed_or_unsafe_paths() {
        assert!(parse_battle_net_aggregate_install_roots(br#"{"installed":"invalid"}"#).is_empty());
        assert!(parse_battle_net_aggregate_install_roots(
            br#"{"installed":[{"product_id":"wow","icon_path":"relative/Wow.exe"}]}"#
        )
        .is_empty());
    }

    #[test]
    fn file_fingerprints_change_only_with_saved_variables_content() {
        let root = tempdir().unwrap();
        let primary = root
            .path()
            .join("_retail_/WTF/Account/ACCOUNT/SavedVariables/EmberSync.lua");
        fs::create_dir_all(primary.parent().unwrap()).unwrap();
        fs::write(&primary, "EmberSyncDB={}").unwrap();
        let roots = vec![root.path().to_path_buf()];
        let first = saved_variables_fingerprints(&roots);
        let second = saved_variables_fingerprints(&roots);
        assert_eq!(first, second);
        fs::write(&primary, "EmberSyncDB={schemaVersion=1}").unwrap();
        assert_ne!(first, saved_variables_fingerprints(&roots));
    }

    #[test]
    fn stable_reader_returns_content_without_writing() {
        let root = tempdir().unwrap();
        let file = root.path().join("EmberSync.lua");
        fs::write(&file, "EmberSyncDB={}").unwrap();
        assert_eq!(read_stable(&file).unwrap(), b"EmberSyncDB={}");
    }

    #[test]
    fn addon_folder_selection_normalizes_to_retail_wtf() {
        let root = tempdir().unwrap();
        let retail = root.path().join("World of Warcraft/_retail_");
        let addon = retail.join("Interface/AddOns/EmberSync");
        let wtf = retail.join("WTF");
        fs::create_dir_all(&addon).unwrap();
        fs::create_dir_all(&wtf).unwrap();

        assert_eq!(
            normalize_configured_root(&addon),
            wtf.canonicalize().unwrap()
        );
    }

    #[test]
    fn install_folder_selection_normalizes_to_retail_wtf() {
        let root = tempdir().unwrap();
        let install = root.path().join("World of Warcraft");
        let wtf = install.join("_retail_/WTF");
        fs::create_dir_all(&wtf).unwrap();

        assert_eq!(
            normalize_configured_root(&install),
            wtf.canonicalize().unwrap()
        );
    }
}
