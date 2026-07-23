use crate::{
    canonical,
    models::{DatasetKind, QueueSummary, UploadEnvelope},
    registry,
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
const ACTION_REQUIRED_PREFIX: &str = "action required: ";
const VAULT_MODE_META: &str = "vault_mode";
const VAULT_INITIALIZED_META: &str = "vault_initialized";
const VAULT_MODE_OS: &str = "os";
const VAULT_MODE_PASSPHRASE: &str = "passphrase";
const RECEIPT_SCHEMA_EPOCH: i64 = 2;
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
    #[error("the configured vault key is missing; existing encrypted data was preserved")]
    MissingCredential,
    #[error("the requested vault mode does not match the existing encrypted data")]
    VaultModeMismatch,
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
    pub queued_at: i64,
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
             CREATE TABLE IF NOT EXISTS upload_receipts (
               content_hash TEXT PRIMARY KEY,
               kind TEXT NOT NULL CHECK (kind IN ('state','events')),
               acknowledged_at INTEGER NOT NULL,
               dataset TEXT,
               scope TEXT,
               subject_id TEXT,
               guild_key TEXT,
               installation_id TEXT,
               first_sequence INTEGER,
               last_sequence INTEGER,
               captured_at INTEGER,
               committed_at INTEGER,
               result TEXT,
               receipt_epoch INTEGER NOT NULL DEFAULT 1
             );
             CREATE INDEX IF NOT EXISTS upload_queue_ready ON upload_queue(status, next_attempt_at, id);"
        )?;
        for (column, declaration) in [
            ("dataset", "TEXT"),
            ("scope", "TEXT"),
            ("subject_id", "TEXT"),
            ("guild_key", "TEXT"),
            ("installation_id", "TEXT"),
            ("first_sequence", "INTEGER"),
            ("last_sequence", "INTEGER"),
            ("captured_at", "INTEGER"),
            ("committed_at", "INTEGER"),
            ("result", "TEXT"),
            ("receipt_epoch", "INTEGER NOT NULL DEFAULT 1"),
        ] {
            ensure_column(&connection, "upload_receipts", column, declaration)?;
        }
        migrate_legacy_authorization_failures(&connection)?;
        reconcile_dataset_rows(&connection)?;
        Ok(Arc::new(Self {
            connection: Mutex::new(connection),
            key: Mutex::new(None),
        }))
    }

    pub fn unlock_from_os_vault(&self) -> Result<(), QueueError> {
        let mode = self.meta(VAULT_MODE_META)?;
        if mode.as_deref() == Some(VAULT_MODE_PASSPHRASE) {
            return Err(QueueError::VaultModeMismatch);
        }
        let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)
            .map_err(|error| QueueError::CredentialVault(error.to_string()))?;
        let bytes = match entry.get_secret() {
            Ok(secret) => secret,
            Err(keyring::Error::NoEntry) => {
                if self.has_vault_history()? {
                    return Err(QueueError::MissingCredential);
                }
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
        self.verify_key_for_existing_material(&key)?;
        self.set_meta(VAULT_MODE_META, VAULT_MODE_OS)?;
        self.set_meta(VAULT_INITIALIZED_META, "1")?;
        *self.key.lock() = Some(Zeroizing::new(key));
        Ok(())
    }

    pub fn unlock_with_passphrase(&self, passphrase: &str) -> Result<(), QueueError> {
        if passphrase.chars().count() < 12 {
            return Err(QueueError::Derivation);
        }
        let existing_mode = self.meta(VAULT_MODE_META)?;
        let existing_verifier = self.meta("passphrase_verifier")?;
        if existing_mode.as_deref() == Some(VAULT_MODE_OS)
            || (existing_mode.is_none()
                && existing_verifier.is_none()
                && self.has_encrypted_material()?)
        {
            return Err(QueueError::VaultModeMismatch);
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
        let verifier = existing_verifier;
        if let Some(encoded) = verifier {
            let bytes = STANDARD_NO_PAD
                .decode(encoded)
                .map_err(|_| QueueError::IncorrectPassphrase)?;
            if decrypt_bytes(&key, &bytes).map_or(true, |value| value != VERIFIER) {
                return Err(QueueError::IncorrectPassphrase);
            }
        } else {
            if self.has_encrypted_material()? {
                return Err(QueueError::VaultModeMismatch);
            }
            let encrypted = encrypt_bytes(&key, VERIFIER)?;
            self.set_meta("passphrase_verifier", &STANDARD_NO_PAD.encode(encrypted))?;
        }
        self.verify_key_for_existing_material(&key)?;
        self.set_meta(VAULT_MODE_META, VAULT_MODE_PASSPHRASE)?;
        self.set_meta(VAULT_INITIALIZED_META, "1")?;
        *self.key.lock() = Some(key);
        Ok(())
    }

    pub fn is_unlocked(&self) -> bool {
        self.key.lock().is_some()
    }

    pub fn enqueue(&self, envelope: &UploadEnvelope) -> Result<bool, QueueError> {
        let plaintext = canonical::canonical_json(&serde_json::to_value(envelope)?);
        let content_hash = hex::encode(sha2::Sha256::digest(&plaintext));
        {
            let connection = self.connection.lock();
            let acknowledged: bool = connection.query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM upload_receipts
                   WHERE content_hash=?1 AND (kind='events' OR receipt_epoch>=?2)
                 )",
                params![&content_hash, RECEIPT_SCHEMA_EPOCH],
                |row| row.get(0),
            )?;
            if acknowledged {
                return Ok(false);
            }
        }
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        let encrypted = encrypt_bytes(key, &plaintext)?;
        let (nonce, ciphertext) = encrypted.split_at(24);
        let coalesce_key = (envelope.kind == DatasetKind::State).then(|| {
            format!(
                "{}:{}:{}:{}:{}",
                envelope.guild_key.as_str(),
                envelope.installation_id,
                envelope.dataset,
                envelope.scope,
                envelope.subject_id
            )
        });
        let now = chrono::Utc::now().timestamp();
        let connection = self.connection.lock();
        // Upload completion can race the encryption work above. Recheck while
        // holding the same connection lock used for the queue insert so an
        // envelope acknowledged during that window cannot be reintroduced.
        let acknowledged: bool = connection.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM upload_receipts
               WHERE content_hash=?1 AND (kind='events' OR receipt_epoch>=?2)
             )",
            params![&content_hash, RECEIPT_SCHEMA_EPOCH],
            |row| row.get(0),
        )?;
        if acknowledged {
            return Ok(false);
        }
        let authorization_error: Option<String> = connection
            .query_row(
                "SELECT value FROM vault_meta WHERE key=?1",
                [AUTHORIZATION_REQUIRED_META],
                |row| row.get(0),
            )
            .optional()?;
        let valid_dataset_name = registry::is_bounded_upload_name(envelope.kind, &envelope.dataset);
        let (status, next_attempt_at, last_error) = if !valid_dataset_name {
            (
                "failed",
                NEVER_RETRY_AT,
                Some(format_action_required_error(&format!(
                    "invalid dataset name/kind {}",
                    envelope.dataset
                ))),
            )
        } else {
            match authorization_error {
                Some(error) => (
                    "failed",
                    NEVER_RETRY_AT,
                    Some(format_authorization_error(&error)),
                ),
                None => ("pending", 0, None),
            }
        };
        if envelope.kind == DatasetKind::State {
            if let Some(existing) = load_coalesced_envelope(
                &connection,
                key,
                coalesce_key.as_deref().expect("state coalesces"),
            )? {
                if existing.export_sequence > envelope.export_sequence
                    || (existing.export_sequence == envelope.export_sequence
                        && (existing.captured_at > envelope.captured_at
                            || (existing.captured_at == envelope.captured_at
                                && existing.coverage.observed_at >= envelope.coverage.observed_at)))
                {
                    return Ok(false);
                }
            }
        }
        let changed = if envelope.kind == DatasetKind::State {
            connection.execute(
                "INSERT INTO upload_queue(content_hash,coalesce_key,guild_key,dataset,kind,nonce,ciphertext,status,attempts,next_attempt_at,last_error,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,0,?9,?10,?11,?11)
                 ON CONFLICT(coalesce_key) DO UPDATE SET content_hash=excluded.content_hash,nonce=excluded.nonce,ciphertext=excluded.ciphertext,status=excluded.status,attempts=0,next_attempt_at=excluded.next_attempt_at,last_error=excluded.last_error,created_at=excluded.created_at,updated_at=excluded.updated_at
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
        let action_pattern = format!("{ACTION_REQUIRED_PREFIX}%");
        let mut statement = connection.prepare("SELECT id,content_hash,nonce,ciphertext,attempts,created_at FROM upload_queue WHERE (status='pending' OR (status='failed' AND (last_error IS NULL OR (last_error NOT LIKE ?3 AND last_error NOT LIKE ?4)))) AND next_attempt_at <= ?1 ORDER BY id LIMIT ?2")?;
        let rows = statement.query_map(
            params![now, limit as i64, authorization_pattern, action_pattern],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, Vec<u8>>(3)?,
                    row.get::<_, u32>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            },
        )?;
        let mut uploads = Vec::new();
        for row in rows {
            let (id, content_hash, nonce, ciphertext, attempts, queued_at) = row?;
            let mut combined = nonce;
            combined.extend_from_slice(&ciphertext);
            let plaintext = decrypt_bytes(key, &combined)?;
            let mut envelope: UploadEnvelope = serde_json::from_slice(&plaintext)?;
            if envelope.persisted_at <= 0 {
                envelope.persisted_at = envelope.captured_at.timestamp();
            }
            uploads.push(QueuedUpload {
                id,
                content_hash,
                envelope,
                attempts,
                queued_at,
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
        let action_pattern = format!("{ACTION_REQUIRED_PREFIX}%");
        self.connection
            .lock()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM upload_queue WHERE (status='pending' OR (status='failed' AND (last_error IS NULL OR (last_error NOT LIKE ?2 AND last_error NOT LIKE ?3)))) AND next_attempt_at <= ?1)",
                params![now, authorization_pattern, action_pattern],
                |row| row.get(0),
            )
            .map_err(QueueError::from)
    }

    #[cfg(test)]
    pub fn mark_complete(&self, id: i64, content_hash: &str) -> Result<(), QueueError> {
        self.mark_complete_with_receipt(id, content_hash, None, None, "committed")
    }

    pub fn mark_complete_with_receipt(
        &self,
        id: i64,
        content_hash: &str,
        committed_at: Option<i64>,
        accepted_sequence: Option<u64>,
        result: &str,
    ) -> Result<(), QueueError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let now = chrono::Utc::now().timestamp();
        let Some(plaintext) = self.queued_plaintext_json(&transaction, id, content_hash)? else {
            transaction.commit()?;
            return Ok(());
        };
        transaction.execute(
            "INSERT OR REPLACE INTO upload_receipts(
               content_hash,kind,acknowledged_at,dataset,scope,subject_id,guild_key,
               installation_id,first_sequence,last_sequence,captured_at,committed_at,result,
               receipt_epoch
             )
             SELECT content_hash,kind,?3,
                    json_extract(CAST(?4 AS TEXT),'$.dataset'),
                    json_extract(CAST(?4 AS TEXT),'$.scope'),
                    json_extract(CAST(?4 AS TEXT),'$.subjectId'),
                    json_extract(CAST(?4 AS TEXT),'$.guildKey'),
                    json_extract(CAST(?4 AS TEXT),'$.installationId'),
                    COALESCE(json_extract(CAST(?4 AS TEXT),'$.eventRange.firstSequence'),
                             json_extract(CAST(?4 AS TEXT),'$.exportSequence')),
                    COALESCE(json_extract(CAST(?4 AS TEXT),'$.eventRange.lastSequence'),?5,
                             json_extract(CAST(?4 AS TEXT),'$.exportSequence')),
                    CAST(strftime('%s',json_extract(CAST(?4 AS TEXT),'$.capturedAt')) AS INTEGER),
                    COALESCE(?6,?3),?7,?8
             FROM upload_queue
             WHERE id=?1 AND content_hash=?2 AND status='uploading'",
            params![
                id,
                content_hash,
                now,
                plaintext,
                accepted_sequence.map(|value| value as i64),
                committed_at,
                truncate_error(result),
                RECEIPT_SCHEMA_EPOCH
            ],
        )?;
        transaction.execute(
            "DELETE FROM upload_queue WHERE id=?1 AND content_hash=?2 AND status='uploading'",
            params![id, content_hash],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// A newer replaceable state is already committed by the server. This is
    /// intentionally uses the same claimed-hash guard as a successful upload,
    /// plus a database-level state-kind guard so event history cannot be
    /// discarded accidentally or reported as a newly uploaded segment.
    pub fn mark_superseded(&self, id: i64, content_hash: &str) -> Result<(), QueueError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let now = chrono::Utc::now().timestamp();
        transaction.execute(
            "UPDATE upload_receipts
             SET acknowledged_at=?3,result='superseded',receipt_epoch=?4
             WHERE content_hash=?2
               AND EXISTS(
                 SELECT 1 FROM upload_queue
                 WHERE id=?1 AND content_hash=?2 AND status='uploading' AND kind='state'
               )",
            params![id, content_hash, now, RECEIPT_SCHEMA_EPOCH],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO upload_receipts(content_hash,kind,acknowledged_at,dataset,guild_key,result,receipt_epoch)
             SELECT content_hash,kind,?3,dataset,guild_key,'superseded',?4 FROM upload_queue
             WHERE id=?1 AND content_hash=?2 AND status='uploading' AND kind='state'",
            params![id, content_hash, now, RECEIPT_SCHEMA_EPOCH],
        )?;
        transaction.execute(
            "DELETE FROM upload_queue WHERE id=?1 AND content_hash=?2 AND status='uploading' AND kind='state'",
            params![id, content_hash],
        )?;
        transaction.commit()?;
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
            params![id, content_hash, NEVER_RETRY_AT, format_action_required_error(error), now],
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
        let action_pattern = format!("{ACTION_REQUIRED_PREFIX}%");
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO vault_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![AUTHORIZATION_REQUIRED_META, safe_error],
        )?;
        transaction.execute(
            "UPDATE upload_queue SET status='failed',next_attempt_at=?1,last_error=?2,updated_at=?3
             WHERE last_error IS NULL OR last_error NOT LIKE ?4",
            params![NEVER_RETRY_AT, stored_error, now, action_pattern],
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
            "SELECT COALESCE(SUM(status='pending'),0),COALESCE(SUM(status='uploading'),0),COALESCE(SUM(status='failed' AND (last_error IS NULL OR (last_error NOT LIKE ?1 AND last_error NOT LIKE ?2))),0),COALESCE(SUM(status='failed' AND (last_error LIKE ?1 OR last_error LIKE ?2)),0),COALESCE(SUM(length(nonce)+length(ciphertext)),0),EXISTS(SELECT 1 FROM vault_meta WHERE key=?3) FROM upload_queue",
            params![authorization_pattern, format!("{ACTION_REQUIRED_PREFIX}%"), AUTHORIZATION_REQUIRED_META], |row| Ok(QueueSummary { pending: row.get(0)?, uploading: row.get(1)?, failed: row.get(2)?, action_required: row.get(3)?, bytes_encrypted: row.get(4)?, authorization_required: row.get(5)? }))
            .map_err(QueueError::from)
    }

    pub fn delete_all(&self) -> Result<(), QueueError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute("DELETE FROM upload_queue", [])?;
        transaction.execute("DELETE FROM upload_receipts", [])?;
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

    fn has_encrypted_material(&self) -> Result<bool, QueueError> {
        self.connection
            .lock()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM upload_queue UNION ALL SELECT 1 FROM secure_meta)",
                [],
                |row| row.get(0),
            )
            .map_err(QueueError::from)
    }

    fn has_vault_history(&self) -> Result<bool, QueueError> {
        if self.has_encrypted_material()? {
            return Ok(true);
        }
        self.connection
            .lock()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM upload_receipts)
                        OR EXISTS(SELECT 1 FROM vault_meta WHERE key=?1)",
                [VAULT_INITIALIZED_META],
                |row| row.get(0),
            )
            .map_err(QueueError::from)
    }

    fn verify_key_for_existing_material(&self, key: &[u8; 32]) -> Result<(), QueueError> {
        let encrypted: Option<(Vec<u8>, Vec<u8>)> = self
            .connection
            .lock()
            .query_row(
                "SELECT nonce,ciphertext FROM upload_queue
                 UNION ALL SELECT nonce,ciphertext FROM secure_meta LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((mut nonce, ciphertext)) = encrypted {
            nonce.extend_from_slice(&ciphertext);
            decrypt_bytes(key, &nonce).map_err(|_| QueueError::InvalidCredential)?;
        }
        Ok(())
    }

    fn queued_plaintext_json(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        id: i64,
        content_hash: &str,
    ) -> Result<Option<String>, QueueError> {
        let encrypted: Option<(Vec<u8>, Vec<u8>)> = transaction
            .query_row(
                "SELECT nonce,ciphertext FROM upload_queue
                 WHERE id=?1 AND content_hash=?2 AND status='uploading'",
                params![id, content_hash],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((mut nonce, ciphertext)) = encrypted else {
            return Ok(None);
        };
        nonce.extend_from_slice(&ciphertext);
        let key_guard = self.key.lock();
        let key = key_guard.as_ref().ok_or(QueueError::Locked)?;
        String::from_utf8(decrypt_bytes(key, &nonce)?)
            .map(Some)
            .map_err(|_| QueueError::Encryption)
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

fn format_action_required_error(value: &str) -> String {
    format!("{ACTION_REQUIRED_PREFIX}{}", truncate_error(value))
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    declaration: &str,
) -> Result<(), QueueError> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let present = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|candidate| candidate == column);
    if !present {
        connection.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {declaration}"),
            [],
        )?;
    }
    Ok(())
}

fn load_coalesced_envelope(
    connection: &Connection,
    key: &[u8; 32],
    coalesce_key: &str,
) -> Result<Option<UploadEnvelope>, QueueError> {
    let encrypted: Option<(Vec<u8>, Vec<u8>)> = connection
        .query_row(
            "SELECT nonce,ciphertext FROM upload_queue WHERE coalesce_key=?1",
            [coalesce_key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((mut nonce, ciphertext)) = encrypted else {
        return Ok(None);
    };
    nonce.extend_from_slice(&ciphertext);
    let plaintext = decrypt_bytes(key, &nonce)?;
    Ok(Some(serde_json::from_slice(&plaintext)?))
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

fn reconcile_dataset_rows(connection: &Connection) -> Result<(), QueueError> {
    let authorization_error: Option<String> = connection
        .query_row(
            "SELECT value FROM vault_meta WHERE key=?1",
            [AUTHORIZATION_REQUIRED_META],
            |row| row.get(0),
        )
        .optional()?;
    let rows = {
        let mut statement =
            connection.prepare("SELECT id,dataset,kind,last_error FROM upload_queue")?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let now = chrono::Utc::now().timestamp();
    for (id, dataset, kind, last_error) in rows {
        let valid = match kind.as_str() {
            "state" => registry::is_bounded_state_name(&dataset),
            "events" => registry::is_bounded_event_dataset_name(&dataset),
            _ => false,
        };
        let legacy_unregistered_error =
            format_action_required_error(&format!("raw retained; unregistered dataset {dataset}"));
        if valid && last_error.as_deref() == Some(legacy_unregistered_error.as_str()) {
            match &authorization_error {
                Some(error) => {
                    connection.execute(
                        "UPDATE upload_queue
                         SET status='failed',attempts=0,next_attempt_at=?2,last_error=?3,updated_at=?4
                         WHERE id=?1",
                        params![id, NEVER_RETRY_AT, format_authorization_error(error), now],
                    )?;
                }
                None => {
                    connection.execute(
                        "UPDATE upload_queue
                         SET status='pending',attempts=0,next_attempt_at=0,last_error=NULL,updated_at=?2
                         WHERE id=?1",
                        params![id, now],
                    )?;
                }
            }
        } else if !valid {
            connection.execute(
                "UPDATE upload_queue
                 SET status='failed',next_attempt_at=?2,last_error=?3,updated_at=?4
                 WHERE id=?1",
                params![
                    id,
                    NEVER_RETRY_AT,
                    format_action_required_error(&format!("invalid dataset name/kind {dataset}")),
                    now
                ],
            )?;
        }
    }
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
        let is_event = kind == DatasetKind::Events;
        UploadEnvelope {
            schema_version: 1,
            dataset: if is_event {
                "events.guild_chat".into()
            } else {
                "guild".into()
            },
            kind,
            scope: "guild".into(),
            subject_id: if is_event {
                format!("AbCdEf0123_-xYz9:Player-1-ABCDEF01:{sequence}")
            } else {
                "main".into()
            },
            guild_key: GuildKey::Main,
            guild: crate::guild::canonical(GuildKey::Main),
            source_character: SourceCharacter {
                guid: "Player-1-ABCDEF01".into(),
                name: "Aria".into(),
                realm: "Dalaran".into(),
                realm_slug: "dalaran".into(),
            },
            installation_id: "AbCdEf0123_-xYz9".into(),
            protocol_version: "1.0".into(),
            export_sequence: sequence,
            event_range: is_event.then_some(EventRange {
                first_sequence: sequence,
                last_sequence: sequence,
            }),
            captured_at: Utc::now(),
            persisted_at: Utc::now().timestamp(),
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
    fn older_state_cannot_replace_a_fresher_coalesced_capture() {
        let store = store();
        let newer = envelope(5, "newer", DatasetKind::State);
        let mut older = envelope(4, "older", DatasetKind::State);
        older.captured_at = newer.captured_at + chrono::Duration::minutes(1);
        assert!(store.enqueue(&newer).unwrap());
        assert!(!store.enqueue(&older).unwrap());
        let ready = store.next_ready(1).unwrap();
        assert_eq!(ready[0].envelope.export_sequence, 5);
        assert_eq!(ready[0].envelope.payload["value"], "newer");
    }

    #[test]
    fn newer_coverage_observation_can_replace_state_at_the_same_sequence() {
        let store = store();
        let current = envelope(5, "same-payload", DatasetKind::State);
        let mut coverage_update = current.clone();
        coverage_update.coverage.status = CoverageStatus::InteractionRequired;
        coverage_update.coverage.reason_code = Some("open_guild_roster".into());
        coverage_update.coverage.observed_at += chrono::Duration::minutes(1);
        assert!(store.enqueue(&current).unwrap());
        assert!(store.enqueue(&coverage_update).unwrap());
        let ready = store.next_ready(1).unwrap();
        assert!(matches!(
            ready[0].envelope.coverage.status,
            CoverageStatus::InteractionRequired
        ));
    }

    #[test]
    fn bounded_future_state_and_events_are_encrypted_and_ready_for_raw_upload() {
        let store = store();
        let mut future = envelope(1, "future", DatasetKind::State);
        future.dataset = "future_metric".into();
        assert!(store.enqueue(&future).unwrap());
        let mut future_event = envelope(2, "future event", DatasetKind::Events);
        future_event.dataset = "events.future_stream".into();
        assert!(store.enqueue(&future_event).unwrap());
        let summary = store.summary().unwrap();
        assert_eq!(summary.pending, 2);
        assert_eq!(summary.action_required, 0);
        let ciphertexts = {
            let connection = store.connection.lock();
            let mut statement = connection
                .prepare("SELECT ciphertext FROM upload_queue ORDER BY id")
                .unwrap();
            statement
                .query_map([], |row| row.get(0))
                .unwrap()
                .collect::<Result<Vec<Vec<u8>>, _>>()
                .unwrap()
        };
        assert!(ciphertexts
            .iter()
            .all(|value| !String::from_utf8_lossy(value).contains("future")));
        let ready = store.next_ready(10).unwrap();
        assert_eq!(ready.len(), 2);
        assert_eq!(ready[0].envelope.dataset, "future_metric");
        assert_eq!(ready[1].envelope.dataset, "events.future_stream");
    }

    #[test]
    fn legacy_unregistered_quarantine_is_released_for_raw_upload_on_upgrade() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("queue.sqlite3");
        {
            let store = QueueStore::open(&path).unwrap();
            *store.key.lock() = Some(Zeroizing::new([7_u8; 32]));
            let mut future = envelope(1, "future", DatasetKind::State);
            future.dataset = "future_metric".into();
            assert!(store.enqueue(&future).unwrap());
            store
                .connection
                .lock()
                .execute(
                    "UPDATE upload_queue SET status='failed',next_attempt_at=?1,last_error=?2",
                    params![
                        NEVER_RETRY_AT,
                        format_action_required_error(
                            "raw retained; unregistered dataset future_metric"
                        )
                    ],
                )
                .unwrap();
        }
        let reopened = QueueStore::open(&path).unwrap();
        let summary = reopened.summary().unwrap();
        assert_eq!(summary.pending, 1);
        assert_eq!(summary.action_required, 0);
    }

    #[test]
    fn syntactically_invalid_dataset_names_remain_quarantined() {
        let store = store();
        let mut invalid = envelope(1, "invalid", DatasetKind::State);
        invalid.dataset = "events.wrong-kind".into();
        assert!(store.enqueue(&invalid).unwrap());
        assert_eq!(store.summary().unwrap().action_required, 1);
        assert!(store.next_ready(10).unwrap().is_empty());
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
        assert!(gap_error.starts_with(ACTION_REQUIRED_PREFIX));
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
    fn acknowledged_envelopes_are_not_requeued_after_success_or_supersession() {
        let store = store();
        let state = envelope(1, "state", DatasetKind::State);
        let mut event = envelope(2, "event", DatasetKind::Events);
        event.subject_id = "event-2".into();

        assert!(store.enqueue(&state).unwrap());
        assert!(store.enqueue(&event).unwrap());
        let claimed = store.next_ready(10).unwrap();
        for upload in &claimed {
            store
                .mark_complete(upload.id, &upload.content_hash)
                .unwrap();
        }
        assert_eq!(store.summary().unwrap().pending, 0);
        assert!(!store.enqueue(&state).unwrap());
        assert!(!store.enqueue(&event).unwrap());

        let newer = envelope(3, "superseded", DatasetKind::State);
        assert!(store.enqueue(&newer).unwrap());
        let superseded = store.next_ready(1).unwrap().remove(0);
        store
            .mark_superseded(superseded.id, &superseded.content_hash)
            .unwrap();
        assert!(!store.enqueue(&newer).unwrap());
    }

    #[test]
    fn legacy_state_receipt_requeues_once_for_the_current_projection_epoch() {
        let store = store();
        let state = envelope(7, "backfill", DatasetKind::State);
        assert!(store.enqueue(&state).unwrap());
        let claimed = store.next_ready(1).unwrap().remove(0);
        store
            .mark_complete_with_receipt(
                claimed.id,
                &claimed.content_hash,
                Some(Utc::now().timestamp()),
                Some(7),
                "committed",
            )
            .unwrap();
        store
            .connection
            .lock()
            .execute(
                "UPDATE upload_receipts SET receipt_epoch=1 WHERE content_hash=?1",
                [&claimed.content_hash],
            )
            .unwrap();

        assert!(store.enqueue(&state).unwrap());
        let replay = store.next_ready(1).unwrap().remove(0);
        store
            .mark_complete_with_receipt(
                replay.id,
                &replay.content_hash,
                Some(Utc::now().timestamp()),
                Some(7),
                "already_committed",
            )
            .unwrap();
        assert!(!store.enqueue(&state).unwrap());
    }

    #[test]
    fn legacy_state_receipt_supersession_also_advances_the_projection_epoch() {
        let store = store();
        let state = envelope(7, "backfill-superseded", DatasetKind::State);
        assert!(store.enqueue(&state).unwrap());
        let claimed = store.next_ready(1).unwrap().remove(0);
        store
            .mark_complete_with_receipt(
                claimed.id,
                &claimed.content_hash,
                Some(Utc::now().timestamp()),
                Some(7),
                "committed",
            )
            .unwrap();
        store
            .connection
            .lock()
            .execute(
                "UPDATE upload_receipts SET receipt_epoch=1 WHERE content_hash=?1",
                [&claimed.content_hash],
            )
            .unwrap();
        assert!(store.enqueue(&state).unwrap());
        let replay = store.next_ready(1).unwrap().remove(0);
        store
            .mark_superseded(replay.id, &replay.content_hash)
            .unwrap();
        assert!(!store.enqueue(&state).unwrap());
        let epoch: i64 = store
            .connection
            .lock()
            .query_row(
                "SELECT receipt_epoch FROM upload_receipts WHERE content_hash=?1",
                [&claimed.content_hash],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(epoch, RECEIPT_SCHEMA_EPOCH);
    }

    #[test]
    fn rich_receipt_records_dataset_identity_and_server_result() {
        let store = store();
        let state = envelope(9, "receipt", DatasetKind::State);
        assert!(store.enqueue(&state).unwrap());
        let claimed = store.next_ready(1).unwrap().remove(0);
        let committed_at = Utc::now().timestamp();
        store
            .mark_complete_with_receipt(
                claimed.id,
                &claimed.content_hash,
                Some(committed_at),
                Some(9),
                "committed",
            )
            .unwrap();
        let receipt: (String, String, String, String, i64, i64, String, i64) = store
            .connection
            .lock()
            .query_row(
                "SELECT dataset,scope,subject_id,installation_id,first_sequence,
                        committed_at,result,receipt_epoch
                 FROM upload_receipts WHERE content_hash=?1",
                [&claimed.content_hash],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            receipt,
            (
                "guild".into(),
                "guild".into(),
                "main".into(),
                "AbCdEf0123_-xYz9".into(),
                9,
                committed_at,
                "committed".into(),
                RECEIPT_SCHEMA_EPOCH,
            )
        );
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
    fn vault_mode_mismatch_never_rekeys_existing_ciphertext() {
        let store = store();
        assert!(store
            .enqueue(&envelope(1, "preserved", DatasetKind::State))
            .unwrap());
        *store.key.lock() = None;
        assert!(matches!(
            store.unlock_with_passphrase("a different secure passphrase"),
            Err(QueueError::VaultModeMismatch)
        ));
        assert_eq!(store.summary().unwrap().pending, 1);
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
