use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    #[serde(default)]
    pub wow_roots: Vec<PathBuf>,
    #[serde(default)]
    pub paired_device: Option<PairedDeviceConfig>,
    #[serde(default)]
    pub pending_pairing: Option<PendingPairingConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedDeviceConfig {
    pub device_id: String,
    pub device_name: String,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingPairingConfig {
    pub device_code: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("configuration I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("configuration is invalid: {0}")]
    Invalid(#[from] serde_json::Error),
    #[error("World of Warcraft location does not exist")]
    MissingRoot,
}

pub struct ConfigStore {
    path: PathBuf,
    value: Mutex<AppConfig>,
}

impl ConfigStore {
    pub fn open(path: PathBuf) -> Result<Self, ConfigError> {
        let mut value = if path.exists() {
            serde_json::from_slice(&fs::read(&path)?)?
        } else {
            AppConfig::default()
        };
        let mut roots: BTreeSet<PathBuf> = value
            .wow_roots
            .into_iter()
            .filter(|path| path.exists())
            .map(|path| crate::discovery::normalize_configured_root(&path))
            .collect();
        roots.extend(
            crate::discovery::default_roots()
                .into_iter()
                .map(|path| crate::discovery::normalize_configured_root(&path)),
        );
        value.wow_roots = roots.into_iter().collect();
        let store = Self {
            path,
            value: Mutex::new(value),
        };
        store.save()?;
        Ok(store)
    }

    pub fn snapshot(&self) -> AppConfig {
        self.value.lock().clone()
    }

    pub fn add_root(&self, path: &Path) -> Result<(), ConfigError> {
        if !path.exists() {
            return Err(ConfigError::MissingRoot);
        }
        let canonical = crate::discovery::normalize_configured_root(path);
        let mut value = self.value.lock();
        if !value.wow_roots.contains(&canonical) {
            value.wow_roots.push(canonical);
            value.wow_roots.sort();
        }
        drop(value);
        self.save()
    }

    pub fn set_pending_pairing(
        &self,
        pending: Option<PendingPairingConfig>,
    ) -> Result<(), ConfigError> {
        self.value.lock().pending_pairing = pending;
        self.save()
    }

    pub fn set_paired_device(&self, paired: Option<PairedDeviceConfig>) -> Result<(), ConfigError> {
        self.value.lock().paired_device = paired;
        self.save()
    }

    /// Clear both halves of the pairing state in a single persisted update.
    /// The in-memory state is changed only after the file write succeeds, so a
    /// transient disk error cannot make the UI disagree with the next launch.
    pub fn clear_pairing(&self) -> Result<(), ConfigError> {
        let mut value = self.value.lock();
        let mut next = value.clone();
        next.paired_device = None;
        next.pending_pairing = None;
        self.save_value(&next)?;
        *value = next;
        Ok(())
    }

    fn save(&self) -> Result<(), ConfigError> {
        self.save_value(&self.value.lock())
    }

    fn save_value(&self, value: &AppConfig) -> Result<(), ConfigError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, serde_json::to_vec_pretty(value)?)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, Utc};

    #[test]
    fn clear_pairing_persists_paired_and_pending_state_together() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        let store = ConfigStore::open(path.clone()).unwrap();
        store
            .set_paired_device(Some(PairedDeviceConfig {
                device_id: "device_1234567890".into(),
                device_name: "Test device".into(),
                scopes: vec!["main".into()],
            }))
            .unwrap();
        store
            .set_pending_pairing(Some(PendingPairingConfig {
                device_code: "pending_device_code_1234567890".into(),
                expires_at: Utc::now() + Duration::minutes(10),
            }))
            .unwrap();

        store.clear_pairing().unwrap();
        let reopened = ConfigStore::open(path).unwrap().snapshot();
        assert!(reopened.paired_device.is_none());
        assert!(reopened.pending_pairing.is_none());
    }
}
