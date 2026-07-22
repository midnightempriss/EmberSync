#[cfg(target_os = "linux")]
use directories::BaseDirs;
use std::{
    collections::BTreeSet,
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
            if entry.file_type().is_file() && is_ember_sync_file(entry.path()) {
                found.insert(entry.into_path());
            }
        }
    }
    found.into_iter().collect()
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

pub fn is_ember_sync_file(path: &Path) -> bool {
    if !path
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("EmberSync.lua"))
    {
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
    fn stable_reader_returns_content_without_writing() {
        let root = tempdir().unwrap();
        let file = root.path().join("EmberSync.lua");
        fs::write(&file, "EmberSyncDB={}").unwrap();
        assert_eq!(read_stable(&file).unwrap(), b"EmberSyncDB={}");
    }
}
