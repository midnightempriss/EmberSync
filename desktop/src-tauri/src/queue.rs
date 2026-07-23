use crate::{
    canonical,
    models::{DatasetKind, QueueSummary, UploadEnvelope},
};
use argon2::Argon2;
use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    XChaCha20Poly1305, XNonce,
};
use parking_lot::Mutex;
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use sha2::Digest;
use std::{path::Path, sync::Arc};
use thiserror::Error;
use zeroize::Zeroizing;

const KEYRING_SERVICE: &str = "org.rainingembers.embersync";
const KEYRING_USER: &str = "local-queue-master-key-v1";
const VERIFIER: &[u8] = b"EmberSync passphrase vault v1";
const AUTHORIZATION_REQUIRED_META: &str = "upload_authorization_required";
const AUTHORIZATION_REQUIRED_PREFIX: &str = "authorization required: ";
const NEVER_RETRY_AT: i64 = i64::MAX;
const LEGACY_REAUTH_ERROR: &str =
    "%Sign in with Battle.net again before pairing or uploading with EmberSync.%";

#[derive(Debug, Error)]
pub enum QueueError {
    #[error("local encrypted vault is locked")]
    Locked,
    #[error("operating-system credential vault is unavailable: {0}")]
    CredentialVault(String),
    #[error("stored credential has an invalid length")]
    InvalidCredential,
    #[error("incorrect passphrase")]
    IncorrectPassphrase,
    #[error("local database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("local encryption failed")]
    Encryption,
    #[error("queued payload is invalid: {0}")]
    InvalidPayload(#[from] serde_json::Error),
    #[error("passphrase derivation failed")]
    Derivation,
}

#[derive(Debug, Clone)]
pub struct QueuedUpload {
    pub id: i64,
    pub content_hash: String,
    pub envelope: UploadEnvelope,
    pub attempts: u32,
}

pub struct QueueStore {
    connection: Mutex<Connection>,
    key: Mutex<Option<Zeroizing<[u8; 32]>>>,
}

impl QueueStore {
    pub fn open(path: &Path) -> Result<Arc<Self>, QueueError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| QueueError::CredentialVault(error.to_string()))?;
        }
        let connection = Connection::open(path)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS upload_queue (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               content_hash TEXT NOT NULL UNIQUE,
               coalesce_key TEXT UNIQUE,
               guild_key TEXT NOT NULL CHECK (guild_key IN ('main','alt')),
               dataset TEXT NOT NULL,
               kind TEXT NOT NULL CHECK (kind IN ('state','events')),
               nonce BLOB NOT NULL CHECK (length(nonce) = 24),
               ciphertext BLOB NOT NULL,
               status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','uploading','failed')),
               attempts INTEGER NOT NULL DEFAULT 0,
               next_attempt_at INTEGER NOT NULL DEFAULT 0,
               last_error TEXT,
               created_at INTEGER NOT NULL,
               updated_at INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS secure_meta (
               key TEXT PRIMARY KEY,
               nonce BLOB NOT NULL CHECK (length(nonce) = 24),
               ciphertext BLOB NOT NULL
             );
             CREATE INDEX IF NOT EXISTS upload_queue_ready ON upload_queue(status, next_attempt_at, id);"
        )?;
        migrate_legacy_authorization_failures(&connection)?;
        Ok(Arc::new(Self {
            connection: Mutex::new(connection),
            key: Mutex::new(None),
        }))
    }

    pub fn unlock_from_os_vault(&self) -> Result<(), QueueError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)
            .map_err(|error| QueueError::CredentialVault(error.to_string()))?;
        let bytes = match entry.get_secret() {
            Ok(secret) => secret,
            Err(keyring::Error::NoEntry) => {
                let mut generated = Zeroizing::new([0_u8; 32]);
                OsRng.fill_bytes(generated.as_mut());
                entry
                    .set_secret(generated.as_ref())
                    .map_err(|error| QueueError::CredentialVault(error.to_string()))?;
                generated.to_vec()
            }
            Err(error) => return Err(QueueError::CredentialVault(error.to_string())),
        };
        let key: [u8; 32] = bytes
            .try_into()
            .map_err(|_| QueueError::InvalidCredential)?;
        *self.key.lock() = Some(Zeroizing::new(key));
        Ok(())
    }

    pub fn unlock_with_passphrase(&self, passphrase: &str) -> Result<(), QueueError> {
        if passphrase.chars().count() < 12 {
            return Err(QueueError::Derivation);
        }
        let salt = {
            let connection = self.connection.lock();
            let existing: Option<String> = connection
                .query_row(
                    "SELECT value FROM vault_meta WHERE key='passphrase_salt'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            match existing {
                Some(value) => STANDARD_NO_PAD
                    .decode(value)
                    .map_err(|_| QueueError::Derivation)?,
                None => {
                    let mut salt = [0_u8; 16];
                    OsRng.fill_bytes(&mut salt);
                    connection.execute(
                        "INSERT INTO vault_meta(key,value) VALUES('passphrase_salt',?1)",
                        [STANDARD_NO_PAD.encode(salt)],
                    )?;
                    salt.to_vec()
                }
            }
        };
        let mut key = Zeroizing::new([0_u8; 32]);
        Argon2::default()
            .hash_password_into(passphrase.as_bytes(), &salt, key.as_mut())
            .map_err(|_| QueueError::Derivation)?;
        let verifier = self.meta("passphrase_verifier")?;
        if let Some(encoded) = verifier {
            let bytes = STANDARD_NO_PAD
                .decode(encoded)
                .map_err(|_| QueueError::IncorrectPassphrase)?;
            if decrypt_bytes(&key, &bytes).map_or(true, |value| value != VERIFIER) {
                return Err(QueueError::IncorrectPassphrase);
            }
        } else {
            let encrypted = encrypt_bytes(&key, VERIFIER)?;
            self.set_meta("passphrase_verifier", &STANDARD_NO_PAD.encode(encrypted))?;
        }
        *self.key.lock() = Some(key);
        Ok(())
    }

    pub fn is_unlocked(&self) -> bool {
        self.key.lock().is_some()
    }

    pub fn enqueue(&self, envelope: &UploadEnvelope) -> Result<bool, QueueError> {
        let plaintext = canonical::canonical_json(&serde_json::to_value(envelope)?);
        let content_hash = hex::encode(sha2::Sha256::digest(&plaintext));
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        let encrypted = encrypt_bytes(key, &plaintext)?;
        let (nonce, ciphertext) = encrypted.split_at(24);
        let coalesce_key = (envelope.kind == DatasetKind::State).then(|| {
            format!(
                "{}:{}:{}:{}",
                envelope.guild_key.as_str(),
                envelope.installation_id,
                envelope.dataset,
                envelope.subject_id
            )
        });
        let now = chrono::Utc::now().timestamp();
        let connection = self.connection.lock();
        let authorization_error: Option<String> = connection
            .query_row(
                "SELECT value FROM vault_meta WHERE key=?1",
                [AUTHORIZATION_REQUIRED_META],
                |row| row.get(0),
            )
            .optional()?;
        let (status, next_attempt_at, last_error) = match authorization_error {
            Some(error) => (
                "failed",
                NEVER_RETRY_AT,
                Some(format_authorization_error(&error)),
            ),
            None => ("pending", 0, None),
        };
        let changed = if envelope.kind == DatasetKind::State {
            connection.execute(
                "INSERT INTO upload_queue(content_hash,coalesce_key,guild_key,dataset,kind,nonce,ciphertext,status,attempts,next_attempt_at,last_error,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,0,?9,?10,?11,?11)
                 ON CONFLICT(coalesce_key) DO UPDATE SET content_hash=excluded.content_hash,nonce=excluded.nonce,ciphertext=excluded.ciphertext,status=excluded.status,attempts=0,next_attempt_at=excluded.next_attempt_at,last_error=excluded.last_error,updated_at=excluded.updated_at
                 WHERE upload_queue.content_hash != excluded.content_hash",
                params![content_hash, coalesce_key, envelope.guild_key.as_str(), envelope.dataset, kind_name(envelope.kind), nonce, ciphertext, status, next_attempt_at, last_error, now],
            )?
        } else {
            connection.execute(
                "INSERT OR IGNORE INTO upload_queue(content_hash,coalesce_key,guild_key,dataset,kind,nonce,ciphertext,status,attempts,next_attempt_at,last_error,created_at,updated_at)
                 VALUES(?1,NULL,?2,?3,?4,?5,?6,?7,0,?8,?9,?10,?10)",
                params![content_hash, envelope.guild_key.as_str(), envelope.dataset, kind_name(envelope.kind), nonce, ciphertext, status, next_attempt_at, last_error, now],
            )?
        };
        Ok(changed > 0)
    }

    pub fn next_ready(&self, limit: usize) -> Result<Vec<QueuedUpload>, QueueError> {
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        let connection = self.connection.lock();
        let now = chrono::Utc::now().timestamp();
        let authorization_pattern = format!("{AUTHORIZATION_REQUIRED_PREFIX}%");
        let mut statement = connection.prepare("SELECT id,content_hash,nonce,ciphertext,attempts FROM upload_queue WHERE (status='pending' OR (status='failed' AND (last_error IS NULL OR last_error NOT LIKE ?3))) AND next_attempt_at <= ?1 ORDER BY id LIMIT ?2")?;
        let rows =
            statement.query_map(params![now, limit as i64, authorization_pattern], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, Vec<u8>>(3)?,
                    row.get::<_, u32>(4)?,
                ))
            })?;
        let mut uploads = Vec::new();
        for row in rows {
            let (id, content_hash, nonce, ciphertext, attempts) = row?;
            let mut combined = nonce;
            combined.extend_from_slice(&ciphertext);
            let plaintext = decrypt_bytes(key, &combined)?;
            uploads.push(QueuedUpload {
                id,
                content_hash,
                envelope: serde_json::from_slice(&plaintext)?,
                attempts,
            });
        }
        for upload in &uploads {
            connection.execute(
                "UPDATE upload_queue SET status='uploading',updated_at=?3 WHERE id=?1 AND content_hash=?2 AND (status='pending' OR status='failed')",
                params![upload.id, upload.content_hash, now],
            )?;
        }
        Ok(uploads)
    }

    /// Reports whether another batch can be claimed immediately. This is kept
    /// separate from the successful-upload count so superseded state and
    /// action-required segments cannot make a queue drain stop early.
    pub fn has_ready_now(&self) -> Result<bool, QueueError> {
        let now = chrono::Utc::now().timestamp();
        let authorization_pattern = format!("{AUTHORIZATION_REQUIRED_PREFIX}%");
        self.connection
            .lock()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM upload_queue WHERE (status='pending' OR (status='failed' AND (last_error IS NULL OR last_error NOT LIKE ?2))) AND next_attempt_at <= ?1)",
                params![now, authorization_pattern],
                |row| row.get(0),
            )
            .map_err(QueueError::from)
    }

    pub fn mark_complete(&self, id: i64, content_hash: &str) -> Result<(), QueueError> {
        self.connection.lock().execute(
            "DELETE FROM upload_queue WHERE id=?1 AND content_hash=?2 AND status='uploading'",
            params![id, content_hash],
        )?;
        Ok(())
    }

    /// A newer replaceable state is already committed by the server. This is
    /// intentionally uses the same claimed-hash guard as a successful upload,
    /// plus a database-level state-kind guard so event history cannot be
    /// discarded accidentally or reported as a newly uploaded segment.
    pub fn mark_superseded(&self, id: i64, content_hash: &str) -> Result<(), QueueError> {
        self.connection.lock().execute(
            "DELETE FROM upload_queue WHERE id=?1 AND content_hash=?2 AND status='uploading' AND kind='state'",
            params![id, content_hash],
        )?;
        Ok(())
    }

    pub fn mark_retry(
        &self,
        id: i64,
        content_hash: &str,
        attempts: u32,
        error: &str,
        retry_after_seconds: Option<u64>,
    ) -> Result<(), QueueError> {
        let exponent = attempts.min(8);
        let jitter = u64::from(OsRng.next_u32() % 7);
        let delay = retry_after_seconds
            .unwrap_or_else(|| 5_u64.saturating_mul(2_u64.pow(exponent)) + jitter)
            .min(3600);
        let now = chrono::Utc::now().timestamp();
        self.connection.lock().execute("UPDATE upload_queue SET status='failed',attempts=attempts+1,next_attempt_at=?3,last_error=?4,updated_at=?5 WHERE id=?1 AND content_hash=?2 AND status='uploading'", params![id, content_hash, now + delay as i64, truncate_error(error), now])?;
        Ok(())
    }

    pub fn mark_action_required(
        &self,
        id: i64,
        content_hash: &str,
        error: &str,
    ) -> Result<(), QueueError> {
        let now = chrono::Utc::now().timestamp();
        self.connection.lock().execute(
            "UPDATE upload_queue SET status='failed',attempts=attempts+1,next_attempt_at=?3,last_error=?4,updated_at=?5 WHERE id=?1 AND content_hash=?2 AND status='uploading'",
            params![id, content_hash, NEVER_RETRY_AT, format_authorization_error(error), now],
        )?;
        Ok(())
    }

    /// Pauses the entire queue after a device-wide website authorization failure.
    /// Newly ingested data inherits this fail-closed state until a person explicitly
    /// retries after completing Battle.net verification.
    pub fn mark_authorization_required(&self, error: &str) -> Result<(), QueueError> {
        let now = chrono::Utc::now().timestamp();
        let safe_error = truncate_error(error);
        let stored_error = format_authorization_error(&safe_error);
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO vault_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![AUTHORIZATION_REQUIRED_META, safe_error],
        )?;
        transaction.execute(
            "UPDATE upload_queue SET status='failed',next_attempt_at=?1,last_error=?2,updated_at=?3",
            params![NEVER_RETRY_AT, stored_error, now],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Called only for a user-initiated retry or after a newly approved pairing.
    pub fn release_authorization_required(&self) -> Result<usize, QueueError> {
        let authorization_pattern = format!("{AUTHORIZATION_REQUIRED_PREFIX}%");
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute(
            "DELETE FROM vault_meta WHERE key=?1",
            [AUTHORIZATION_REQUIRED_META],
        )?;
        let changed = transaction.execute(
            "UPDATE upload_queue SET status='pending',attempts=0,next_attempt_at=0,last_error=NULL WHERE status='failed' AND last_error LIKE ?1",
            [authorization_pattern],
        )?;
        transaction.commit()?;
        Ok(changed)
    }

    pub fn recover_uploading(&self) -> Result<(), QueueError> {
        let connection = self.connection.lock();
        let authorization_error: Option<String> = connection
            .query_row(
                "SELECT value FROM vault_meta WHERE key=?1",
                [AUTHORIZATION_REQUIRED_META],
                |row| row.get(0),
            )
            .optional()?;
        match authorization_error {
            Some(error) => {
                connection.execute(
                    "UPDATE upload_queue SET status='failed',next_attempt_at=?1,last_error=?2 WHERE status='uploading'",
                    params![NEVER_RETRY_AT, format_authorization_error(&error)],
                )?;
            }
            None => {
                connection.execute(
                    "UPDATE upload_queue SET status='pending' WHERE status='uploading'",
                    [],
                )?;
            }
        }
        Ok(())
    }

    pub fn summary(&self) -> Result<QueueSummary, QueueError> {
        let authorization_pattern = format!("{AUTHORIZATION_REQUIRED_PREFIX}%");
        self.connection.lock().query_row(
            "SELECT COALESCE(SUM(status='pending'),0),COALESCE(SUM(status='uploading'),0),COALESCE(SUM(status='failed' AND (last_error IS NULL OR last_error NOT LIKE ?1)),0),COALESCE(SUM(status='failed' AND last_error LIKE ?1),0),COALESCE(SUM(length(nonce)+length(ciphertext)),0),EXISTS(SELECT 1 FROM vault_meta WHERE key=?2) FROM upload_queue",
            params![authorization_pattern, AUTHORIZATION_REQUIRED_META], |row| Ok(QueueSummary { pending: row.get(0)?, uploading: row.get(1)?, failed: row.get(2)?, action_required: row.get(3)?, bytes_encrypted: row.get(4)?, authorization_required: row.get(5)? }))
            .map_err(QueueError::from)
    }

    pub fn delete_all(&self) -> Result<(), QueueError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute("DELETE FROM upload_queue", [])?;
        transaction.execute(
            "DELETE FROM vault_meta WHERE key=?1",
            [AUTHORIZATION_REQUIRED_META],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn store_secure(&self, name: &str, value: &[u8]) -> Result<(), QueueError> {
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        let encrypted = encrypt_bytes(key, value)?;
        let (nonce, ciphertext) = encrypted.split_at(24);
        self.connection.lock().execute(
            "INSERT INTO secure_meta(key,nonce,ciphertext) VALUES(?1,?2,?3) ON CONFLICT(key) DO UPDATE SET nonce=excluded.nonce,ciphertext=excluded.ciphertext",
            params![name,nonce,ciphertext],
        )?;
        Ok(())
    }

    pub fn load_secure(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, QueueError> {
        let encrypted: Option<(Vec<u8>, Vec<u8>)> = self
            .connection
            .lock()
            .query_row(
                "SELECT nonce,ciphertext FROM secure_meta WHERE key=?1",
                [name],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((mut nonce, ciphertext)) = encrypted else {
            return Ok(None);
        };
        nonce.extend_from_slice(&ciphertext);
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        Ok(Some(Zeroizing::new(decrypt_bytes(key, &nonce)?)))
    }

    pub fn delete_secure(&self, name: &str) -> Result<(), QueueError> {
        self.connection
            .lock()
            .execute("DELETE FROM secure_meta WHERE key=?1", [name])?;
        Ok(())
    }

    fn meta(&self, key: &str) -> Result<Option<String>, QueueError> {
        self.connection
            .lock()
            .query_row("SELECT value FROM vault_meta WHERE key=?1", [key], |row| {
                row.get(0)
            })
            .optional()
            .map_err(QueueError::from)
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<(), QueueError> {
        self.connection.lock().execute("INSERT INTO vault_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value])?;
        Ok(())
    }
}

fn encrypt_bytes(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, QueueError> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce = [0_u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext)
        .map_err(|_| QueueError::Encryption)?;
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&ciphertext);
    Ok(combined)
}

fn decrypt_bytes(key: &[u8; 32], combined: &[u8]) -> Result<Vec<u8>, QueueError> {
    if combined.len() < 24 {
        return Err(QueueError::Encryption);
    }
    XChaCha20Poly1305::new(key.into())
        .decrypt(XNonce::from_slice(&combined[..24]), &combined[24..])
        .map_err(|_| QueueError::Encryption)
}

fn kind_name(kind: DatasetKind) -> &'static str {
    match kind {
        DatasetKind::State => "state",
        DatasetKind::Events => "events",
    }
}
fn truncate_error(value: &str) -> String {
    value.chars().take(500).collect()
}

fn format_authorization_error(value: &str) -> String {
    format!("{AUTHORIZATION_REQUIRED_PREFIX}{}", truncate_error(value))
}

fn migrate_legacy_authorization_failures(connection: &Connection) -> Result<(), QueueError> {
    let authorization_pattern = format!("{AUTHORIZATION_REQUIRED_PREFIX}%");
    let legacy_error: Option<String> = connection
        .query_row(
            "SELECT last_error FROM upload_queue WHERE status='failed' AND last_error LIKE ?1 AND last_error NOT LIKE ?2 LIMIT 1",
            params![LEGACY_REAUTH_ERROR, authorization_pattern],
            |row| row.get(0),
        )
        .optional()?;
    let Some(error) = legacy_error else {
        return Ok(());
    };
    let now = chrono::Utc::now().timestamp();
    let stored_error = format_authorization_error(&error);
    connection.execute(
        "INSERT INTO vault_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![AUTHORIZATION_REQUIRED_META, truncate_error(&error)],
    )?;
    connection.execute(
        "UPDATE upload_queue SET status='failed',next_attempt_at=?1,last_error=?2,updated_at=?3",
        params![NEVER_RETRY_AT, stored_error, now],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::*;
    use chrono::Utc;
    use tempfile::tempdir;

    fn envelope(sequence: u64, value: &str, kind: DatasetKind) -> UploadEnvelope {
        let payload = serde_json::json!({"value":value});
        UploadEnvelope {
            schema_version: 1,
            dataset: "roster".into(),
            kind,
            scope: "guild".into(),
            subject_id: "guild".into(),
            guild_key: GuildKey::Main,
            guild: crate::guild::canonical(GuildKey::Main),
            source_character: SourceCharacter {
                guid: "Player-1".into(),
                name: "Aria".into(),
                realm: "Dalaran".into(),
                realm_slug: "dalaran".into(),
            },
            installation_id: "install-1".into(),
            protocol_version: "1.0".into(),
            export_sequence: sequence,
            captured_at: Utc::now(),
            coverage: Coverage {
                status: CoverageStatus::Complete,
                reason_code: None,
                observed_at: Utc::now(),
                metadata: None,
            },
            permission_evidence: serde_json::json!({}),
            payload_hash: canonical::sha256_hex(&payload),
            payload,
        }
    }

    fn store() -> Arc<QueueStore> {
        let directory = tempdir().unwrap().keep();
        let store = QueueStore::open(&directory.join("queue.sqlite3")).unwrap();
        *store.key.lock() = Some(Zeroizing::new([7_u8; 32]));
        store
    }

    #[test]
    fn state_is_encrypted_and_coalesced() {
        let store = store();
        assert!(store
            .enqueue(&envelope(1, "old", DatasetKind::State))
            .unwrap());
        assert!(store
            .enqueue(&envelope(2, "new", DatasetKind::State))
            .unwrap());
        assert_eq!(store.summary().unwrap().pending, 1);
        let next = store.next_ready(10).unwrap();
        assert_eq!(next[0].envelope.payload["value"], "new");
        let connection = store.connection.lock();
        let ciphertext: Vec<u8> = connection
            .query_row("SELECT ciphertext FROM upload_queue", [], |row| row.get(0))
            .unwrap();
        assert!(!String::from_utf8_lossy(&ciphertext).contains("new"));
    }

    #[test]
    fn in_flight_state_result_cannot_mutate_a_newer_coalesced_payload() {
        fn assert_newer_survives(
            finish: impl FnOnce(&QueueStore, &QueuedUpload) -> Result<(), QueueError>,
        ) {
            let store = store();
            assert!(store
                .enqueue(&envelope(1, "old", DatasetKind::State))
                .unwrap());
            let claimed = store.next_ready(1).unwrap().remove(0);
            assert_eq!(claimed.envelope.payload["value"], "old");

            assert!(store
                .enqueue(&envelope(2, "new", DatasetKind::State))
                .unwrap());
            finish(&store, &claimed).unwrap();

            let next = store.next_ready(1).unwrap();
            assert_eq!(next.len(), 1);
            assert_eq!(next[0].envelope.payload["value"], "new");
            assert_ne!(next[0].content_hash, claimed.content_hash);
        }

        assert_newer_survives(|store, claimed| {
            store.mark_complete(claimed.id, &claimed.content_hash)
        });
        assert_newer_survives(|store, claimed| {
            store.mark_retry(
                claimed.id,
                &claimed.content_hash,
                claimed.attempts,
                "temporary failure",
                None,
            )
        });
        assert_newer_survives(|store, claimed| {
            store.mark_action_required(claimed.id, &claimed.content_hash, "scope approval required")
        });
    }

    #[test]
    fn retry_action_required_and_superseded_have_distinct_queue_transitions() {
        let store = store();
        let mut retry = envelope(1, "retry", DatasetKind::State);
        retry.subject_id = "retry-state".into();
        let mut coverage_gap = envelope(2, "event", DatasetKind::Events);
        coverage_gap.subject_id = "event-range-2".into();
        let mut superseded = envelope(3, "old-state", DatasetKind::State);
        superseded.subject_id = "superseded-state".into();
        assert!(store.enqueue(&retry).unwrap());
        assert!(store.enqueue(&coverage_gap).unwrap());
        assert!(store.enqueue(&superseded).unwrap());
        assert!(store.has_ready_now().unwrap());

        let claimed = store.next_ready(10).unwrap();
        assert_eq!(claimed.len(), 3);
        assert!(!store.has_ready_now().unwrap());
        let retry = claimed
            .iter()
            .find(|upload| upload.envelope.subject_id == "retry-state")
            .unwrap();
        let coverage_gap = claimed
            .iter()
            .find(|upload| upload.envelope.subject_id == "event-range-2")
            .unwrap();
        let superseded = claimed
            .iter()
            .find(|upload| upload.envelope.subject_id == "superseded-state")
            .unwrap();

        store
            .mark_retry(
                retry.id,
                &retry.content_hash,
                retry.attempts,
                "website storage is temporarily unavailable",
                Some(60),
            )
            .unwrap();
        store
            .mark_action_required(
                coverage_gap.id,
                &coverage_gap.content_hash,
                "event coverage gap requires review; append-only history was retained",
            )
            .unwrap();
        store
            .mark_superseded(superseded.id, &superseded.content_hash)
            .unwrap();

        let summary = store.summary().unwrap();
        assert_eq!(summary.pending, 0);
        assert_eq!(summary.uploading, 0);
        assert_eq!(summary.failed, 1);
        assert_eq!(summary.action_required, 1);
        assert!(!store.has_ready_now().unwrap());
        let connection = store.connection.lock();
        let (retry_status, retry_error, retry_at): (String, String, i64) = connection
            .query_row(
                "SELECT status,last_error,next_attempt_at FROM upload_queue WHERE id=?1",
                [retry.id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(retry_status, "failed");
        assert!(retry_error.contains("temporarily unavailable"));
        assert!(retry_at > chrono::Utc::now().timestamp());
        let gap_error: String = connection
            .query_row(
                "SELECT last_error FROM upload_queue WHERE id=?1",
                [coverage_gap.id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(gap_error.starts_with(AUTHORIZATION_REQUIRED_PREFIX));
        assert!(gap_error.contains("event coverage gap requires review"));
        let superseded_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM upload_queue WHERE id=?1",
                [superseded.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(superseded_count, 0);
    }

    #[test]
    fn superseded_transition_refuses_to_delete_event_history() {
        let store = store();
        let mut event = envelope(1, "event", DatasetKind::Events);
        event.subject_id = "event-range-1".into();
        assert!(store.enqueue(&event).unwrap());
        let claimed = store.next_ready(1).unwrap().remove(0);

        store
            .mark_superseded(claimed.id, &claimed.content_hash)
            .unwrap();

        assert_eq!(store.summary().unwrap().uploading, 1);
    }

    #[test]
    fn event_ranges_are_not_coalesced_but_exact_duplicates_are_idempotent() {
        let store = store();
        let event = envelope(1, "event", DatasetKind::Events);
        assert!(store.enqueue(&event).unwrap());
        assert!(!store.enqueue(&event).unwrap());
        let mut second = envelope(2, "other", DatasetKind::Events);
        second.subject_id = "event-2".into();
        assert!(store.enqueue(&second).unwrap());
        assert_eq!(store.summary().unwrap().pending, 2);
    }

    #[test]
    fn passphrase_vault_rejects_a_different_passphrase() {
        let directory = tempdir().unwrap().keep();
        let path = directory.join("queue.sqlite3");
        let first = QueueStore::open(&path).unwrap();
        first
            .unlock_with_passphrase("the correct local test passphrase")
            .unwrap();
        first.store_secure("test", b"secret").unwrap();
        drop(first);

        let reopened = QueueStore::open(&path).unwrap();
        assert!(matches!(
            reopened.unlock_with_passphrase("an incorrect test passphrase"),
            Err(QueueError::IncorrectPassphrase)
        ));
        reopened
            .unlock_with_passphrase("the correct local test passphrase")
            .unwrap();
        assert_eq!(
            reopened.load_secure("test").unwrap().unwrap().as_slice(),
            b"secret"
        );
    }

    #[test]
    fn authorization_failure_pauses_existing_and_new_uploads_until_manual_release() {
        let store = store();
        assert!(store
            .enqueue(&envelope(1, "first", DatasetKind::State))
            .unwrap());
        store
            .mark_authorization_required("fresh Battle.net verification is required")
            .unwrap();
        let summary = store.summary().unwrap();
        assert_eq!(summary.pending, 0);
        assert_eq!(summary.failed, 0);
        assert_eq!(summary.action_required, 1);
        assert!(store.next_ready(10).unwrap().is_empty());

        assert!(store
            .enqueue(&envelope(2, "newer", DatasetKind::State))
            .unwrap());
        let mut event = envelope(3, "event", DatasetKind::Events);
        event.subject_id = "event-3".into();
        assert!(store.enqueue(&event).unwrap());
        assert_eq!(store.summary().unwrap().action_required, 2);
        assert!(store.next_ready(10).unwrap().is_empty());

        assert_eq!(store.release_authorization_required().unwrap(), 2);
        let summary = store.summary().unwrap();
        assert_eq!(summary.action_required, 0);
        assert_eq!(summary.pending, 2);
        assert_eq!(store.next_ready(10).unwrap().len(), 2);
    }

    #[test]
    fn legacy_battlenet_reauth_failures_are_migrated_to_action_required() {
        let store = store();
        assert!(store
            .enqueue(&envelope(1, "first", DatasetKind::State))
            .unwrap());
        {
            let connection = store.connection.lock();
            connection
                .execute(
                    "UPDATE upload_queue SET status='failed',last_error=?1",
                    ["website returned 403: Sign in with Battle.net again before pairing or uploading with EmberSync."],
                )
                .unwrap();
            migrate_legacy_authorization_failures(&connection).unwrap();
        }
        assert_eq!(store.summary().unwrap().action_required, 1);
        assert!(store.next_ready(10).unwrap().is_empty());
    }

    #[test]
    fn deleting_local_queue_data_also_clears_the_authorization_gate() {
        let store = store();
        assert!(store
            .enqueue(&envelope(1, "first", DatasetKind::State))
            .unwrap());
        store
            .mark_authorization_required("fresh Battle.net verification is required")
            .unwrap();

        store.delete_all().unwrap();

        let summary = store.summary().unwrap();
        assert_eq!(summary.action_required, 0);
        assert!(!summary.authorization_required);
    }
}
