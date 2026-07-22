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
            .collect();
        roots.extend(crate::discovery::default_roots());
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
        let canonical = path.canonicalize()?;
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

    fn save(&self) -> Result<(), ConfigError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, serde_json::to_vec_pretty(&*self.value.lock())?)?;
        Ok(())
    }
}
