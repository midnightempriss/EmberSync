use crate::{
    canonical,
    config::{PairedDeviceConfig, PendingPairingConfig},
    guild::WEBSITE_URL,
    models::{DatasetKind, GuildKey, UploadEnvelope},
    queue::{QueueError, QueueStore},
    registry,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, SecondsFormat, Utc};
use ed25519_dalek::{Signer, SigningKey};
use flate2::{write::GzEncoder, Compression};
use rand::{rngs::OsRng, RngCore};
use reqwest::{
    header::{CONTENT_ENCODING, CONTENT_TYPE, RETRY_AFTER},
    redirect::Policy,
    Method,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{io::Write, sync::Arc};
use thiserror::Error;

const SIGNING_KEY_NAME: &str = "device-ed25519-v1";
const MAX_COMPRESSED_CHUNK: usize = 1_048_576;
const MAX_EXPANDED_CHUNK: usize = 8_388_608;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("secure device key is unavailable: {0}")]
    Queue(#[from] QueueError),
    #[error("website request failed: {0}")]
    Transport(#[from] reqwest::Error),
    #[error("website returned {status}: {message}")]
    Response {
        status: u16,
        message: String,
        code: Option<String>,
        retry_after: Option<u64>,
    },
    #[error("website returned an invalid response")]
    InvalidResponse,
    #[error("queued segment exceeds protocol limits")]
    SegmentTooLarge,
    #[error("pairing request has expired")]
    PairingExpired,
    #[error("pairing was denied")]
    PairingDenied,
    #[error("upload deferred safely: {0}")]
    UploadDeferred(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum UploadErrorDisposition {
    /// The website or network is temporarily unavailable. Keep the segment and
    /// retry it with bounded backoff.
    Retry,
    /// This particular segment needs a person or a newer client/export before
    /// it can be accepted. Other independent segments may still upload.
    ActionRequired,
    /// The device/account authorization itself is unusable, so every queued
    /// segment must stop until the connection is repaired or reverified.
    DeviceActionRequired,
    /// A newer state projection is already committed on the website. Only
    /// replaceable state may be discarded this way; event history never may.
    Superseded,
}

impl ApiError {
    pub fn retry_after(&self) -> Option<u64> {
        match self {
            Self::Response { retry_after, .. } => *retry_after,
            _ => None,
        }
    }

    fn upload_disposition(&self, kind: DatasetKind) -> UploadErrorDisposition {
        match self {
            Self::Response {
                status,
                message,
                code,
                ..
            } => {
                if *status == 408
                    || *status == 429
                    || *status >= 500
                    || matches!(
                        code.as_deref(),
                        Some(
                            "service_unavailable"
                                | "storage_unavailable"
                                | "membership_verification_unavailable"
                                | "sync_session_expired"
                                | "sync_session_not_found"
                                | "sync_session_not_restartable"
                                | "sync_session_restart_conflict"
                                | "replayed_request"
                        )
                    )
                {
                    return UploadErrorDisposition::Retry;
                }
                if code.as_deref() == Some("sequence_replay") {
                    return if kind == DatasetKind::State {
                        UploadErrorDisposition::Superseded
                    } else {
                        // Append-only events can contain records the server has
                        // not seen even when their export sequence is older.
                        // Retain them as an explicit coverage gap for review.
                        UploadErrorDisposition::ActionRequired
                    };
                }
                if matches!(
                    code.as_deref(),
                    Some(
                        "ownership_reverification_required"
                            | "account_not_eligible"
                            | "guild_membership_required"
                            | "device_revoked"
                            | "device_not_found"
                            | "device_not_paired"
                            | "invalid_signature"
                    )
                ) || (*status == 403 && message.contains("Sign in with Battle.net again"))
                {
                    return UploadErrorDisposition::DeviceActionRequired;
                }
                // All other protocol rejections are non-transient. This covers
                // invalid_*, unsupported schemas/protocols, guild/source/dataset
                // mismatches, sequence conflicts, and size/integrity failures.
                // Retrying the identical encrypted segment cannot fix them.
                UploadErrorDisposition::ActionRequired
            }
            Self::Transport(_) | Self::Queue(_) | Self::UploadDeferred(_) => {
                UploadErrorDisposition::Retry
            }
            Self::InvalidResponse
            | Self::SegmentTooLarge
            | Self::PairingExpired
            | Self::PairingDenied => UploadErrorDisposition::ActionRequired,
        }
    }

    fn action_required_reason(&self, kind: DatasetKind) -> String {
        if kind == DatasetKind::Events
            && matches!(
                self,
                Self::Response {
                    code: Some(code),
                    ..
                } if code == "sequence_replay"
            )
        {
            return format!(
                "event coverage gap requires review; an append-only event range was not discarded: {self}"
            );
        }
        self.to_string()
    }

    /// A self-revocation is idempotent. If the server no longer recognizes
    /// this device as active, the desktop client can safely forget its local
    /// pairing instead of trapping the user in an unrecoverable paired state.
    pub(crate) fn confirms_device_is_inactive(&self) -> bool {
        matches!(
            self,
            Self::Response {
                status: 401 | 404,
                code: Some(code),
                ..
            } if matches!(code.as_str(), "device_revoked" | "device_not_found" | "device_not_paired")
        )
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingStartRequest {
    protocol_version: &'static str,
    public_key_algorithm: &'static str,
    device_public_key: String,
    device_name: String,
    platform: &'static str,
    client_version: &'static str,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingStartResponse {
    pub device_code: String,
    pub verification_code: String,
    pub verification_uri: String,
    pub expires_at: DateTime<Utc>,
    pub poll_interval_seconds: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum PairingPollResponse {
    Pending {
        #[serde(rename = "expiresAt")]
        expires_at: DateTime<Utc>,
    },
    Denied,
    Expired,
    Approved {
        #[serde(rename = "deviceId")]
        device_id: String,
        #[serde(rename = "uploadScopes")]
        upload_scopes: Vec<GuildKey>,
        #[serde(rename = "serverTime")]
        server_time: DateTime<Utc>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncStartResponse {
    session_id: String,
    expires_at: DateTime<Utc>,
    missing_envelope_hashes: Vec<String>,
    max_compressed_chunk_bytes: usize,
    max_expanded_chunk_bytes: usize,
    remaining_compressed_session_bytes: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncCommitResponse {
    status: String,
    committed_at: DateTime<Utc>,
    accepted_sequence: u64,
}

pub struct ApiClient {
    client: reqwest::Client,
    queue: Arc<QueueStore>,
}

fn valid_upload_envelope(envelope: &UploadEnvelope) -> bool {
    if envelope.schema_version != 1
        || envelope.protocol_version != "1.0"
        || !registry::is_installation_id(&envelope.installation_id)
        || !registry::is_player_guid(&envelope.source_character.guid)
        || envelope.export_sequence == 0
        || envelope.export_sequence > registry::MAX_SAFE_SEQUENCE
        || envelope.persisted_at <= 0
        || canonical::sha256_hex(&envelope.payload) != envelope.payload_hash
    {
        return false;
    }

    match (envelope.kind, envelope.event_range) {
        (DatasetKind::State, None) => {
            if !registry::is_bounded_state_name(&envelope.dataset) {
                return false;
            }
            if let Some(expected) = registry::registered_state_scope(&envelope.dataset) {
                if envelope.scope != expected {
                    return false;
                }
            } else if !registry::is_dataset_scope(&envelope.scope) {
                return false;
            }
            valid_state_subject(envelope)
        }
        (DatasetKind::Events, Some(range)) => {
            if !registry::is_bounded_event_dataset_name(&envelope.dataset)
                || registry::registered_event_scope(&envelope.dataset)
                    .map_or(envelope.scope != "guild", |expected| {
                        envelope.scope != expected
                    })
                || range.first_sequence == 0
                || range.first_sequence > range.last_sequence
                || range.last_sequence != envelope.export_sequence
                || envelope.subject_id
                    != crate::models::event_subject_id(
                        &envelope.installation_id,
                        &envelope.source_character.guid,
                        range.first_sequence,
                    )
            {
                return false;
            }
            valid_event_batch_payload(envelope, range)
        }
        _ => false,
    }
}

fn valid_state_subject(envelope: &UploadEnvelope) -> bool {
    match envelope.scope.as_str() {
        "guild" => envelope.subject_id == envelope.guild_key.as_str(),
        "account" => envelope.subject_id == "account",
        "character" => envelope.subject_id == envelope.source_character.guid,
        "house" | "neighborhood" | "session" => {
            !envelope.subject_id.is_empty() && envelope.subject_id.len() <= 256
        }
        _ => false,
    }
}

fn valid_event_batch_payload(envelope: &UploadEnvelope, range: crate::models::EventRange) -> bool {
    const MAX_EVENTS_PER_BATCH: usize = 250;
    let Some(root) = envelope.payload.as_object() else {
        return false;
    };
    let Some(events) = root.get("events").and_then(Value::as_array) else {
        return false;
    };
    if root.len() != 1 || events.is_empty() || events.len() > MAX_EVENTS_PER_BATCH {
        return false;
    }
    let expected_len = range
        .last_sequence
        .checked_sub(range.first_sequence)
        .and_then(|distance| distance.checked_add(1))
        .and_then(|length| usize::try_from(length).ok());
    if expected_len != Some(events.len()) {
        return false;
    }

    for (index, event) in events.iter().enumerate() {
        let Some(event) = event.as_object() else {
            return false;
        };
        if event.len() != 3
            || !event.contains_key("payload")
            || event.get("sequence").and_then(Value::as_u64)
                != range.first_sequence.checked_add(index as u64)
            || event
                .get("capturedAt")
                .and_then(Value::as_i64)
                .map_or(true, |value| value <= 0)
        {
            return false;
        }
    }
    events
        .last()
        .and_then(Value::as_object)
        .and_then(|event| event.get("capturedAt"))
        .and_then(Value::as_i64)
        == Some(envelope.captured_at.timestamp())
}

fn build_sync_manifest(
    envelope: &UploadEnvelope,
    queued_at: i64,
    envelope_hash: &str,
    compressed_bytes: usize,
    expanded_bytes: usize,
) -> Result<Value, ApiError> {
    if queued_at <= 0 {
        return Err(ApiError::InvalidResponse);
    }
    let mut segment = json!({
        "dataset": envelope.dataset,
        "kind": envelope.kind,
        "scope": envelope.scope,
        "subjectId": envelope.subject_id,
        "coverage": envelope.coverage,
        "payloadHash": envelope.payload_hash,
        "envelopeHash": envelope_hash,
        "compressedBytes": compressed_bytes,
        "expandedBytes": expanded_bytes
    });
    if envelope.kind == DatasetKind::Events {
        let range = envelope.event_range.ok_or(ApiError::InvalidResponse)?;
        segment
            .as_object_mut()
            .expect("segment is an object")
            .insert(
                "eventRange".into(),
                json!({"firstSequence":range.first_sequence,"lastSequence":range.last_sequence}),
            );
    }
    Ok(json!({
        "schemaVersion": 1,
        "protocolVersion": "1.0",
        "guildKey": envelope.guild_key,
        "guild": envelope.guild,
        "sourceCharacter": envelope.source_character,
        "installationId": envelope.installation_id,
        "exportSequence": envelope.export_sequence,
        "capturedAt": envelope.captured_at.to_rfc3339_opts(SecondsFormat::Secs, true),
        "persistedAt": envelope.persisted_at,
        "queuedAt": queued_at,
        "segments": [segment]
    }))
}

impl ApiClient {
    pub fn new(queue: Arc<QueueStore>) -> Result<Self, ApiError> {
        let client = build_http_client(true)?;
        Ok(Self { client, queue })
    }

    pub async fn start_pairing(
        &self,
    ) -> Result<(PairingStartResponse, PendingPairingConfig), ApiError> {
        let signing = self.signing_key()?;
        let request = PairingStartRequest {
            protocol_version: "1.0",
            public_key_algorithm: "Ed25519",
            device_public_key: URL_SAFE_NO_PAD.encode(signing.verifying_key().as_bytes()),
            device_name: device_name(),
            platform: platform(),
            client_version: env!("CARGO_PKG_VERSION"),
        };
        let body = canonical::canonical_json(
            &serde_json::to_value(request).map_err(|_| ApiError::InvalidResponse)?,
        );
        let response = self
            .client
            .post(format!("{WEBSITE_URL}/api/ember-sync/v1/pairing/start"))
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await?;
        let response: PairingStartResponse = parse_response(response).await?;
        if !response
            .verification_uri
            .starts_with(&format!("{WEBSITE_URL}/"))
            || response.device_code.len() < 32
            || response.verification_code.len() < 6
            || !(1..=60).contains(&response.poll_interval_seconds)
        {
            return Err(ApiError::InvalidResponse);
        }
        let pending = PendingPairingConfig {
            device_code: response.device_code.clone(),
            expires_at: response.expires_at,
        };
        Ok((response, pending))
    }

    pub async fn poll_pairing(
        &self,
        pending: &PendingPairingConfig,
    ) -> Result<Option<PairedDeviceConfig>, ApiError> {
        if pending.expires_at <= Utc::now() {
            return Err(ApiError::PairingExpired);
        }
        let body = canonical::canonical_json(
            &json!({"deviceCode":pending.device_code,"protocolVersion":"1.0"}),
        );
        let response = self
            .client
            .post(format!("{WEBSITE_URL}/api/ember-sync/v1/pairing/poll"))
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await?;
        match parse_response::<PairingPollResponse>(response).await? {
            PairingPollResponse::Pending { expires_at } if expires_at > Utc::now() => Ok(None),
            PairingPollResponse::Pending { .. } | PairingPollResponse::Expired => {
                Err(ApiError::PairingExpired)
            }
            PairingPollResponse::Denied => Err(ApiError::PairingDenied),
            PairingPollResponse::Approved {
                device_id,
                upload_scopes,
                server_time,
            } => {
                if !valid_token(&device_id)
                    || upload_scopes.is_empty()
                    || (Utc::now() - server_time).num_minutes().unsigned_abs() > 10
                {
                    return Err(ApiError::InvalidResponse);
                }
                Ok(Some(PairedDeviceConfig {
                    device_id,
                    device_name: device_name(),
                    scopes: upload_scopes
                        .into_iter()
                        .map(|key| key.as_str().into())
                        .collect(),
                }))
            }
        }
    }

    pub async fn revoke(&self, paired: &PairedDeviceConfig) -> Result<(), ApiError> {
        if !valid_token(&paired.device_id) {
            return Err(ApiError::InvalidResponse);
        }
        let path = format!("/api/ember-sync/v1/devices/{}/revoke", paired.device_id);
        let body = canonical::canonical_json(&json!({"protocolVersion":"1.0"}));
        let request = self.signed_request(Method::POST, &path, &paired.device_id, body)?;
        let response = request.send().await?;
        if !response.status().is_success() {
            return Err(response_error(response).await);
        }
        Ok(())
    }

    pub fn forget_signing_key(&self) -> Result<(), ApiError> {
        self.queue.delete_secure(SIGNING_KEY_NAME)?;
        Ok(())
    }

    pub async fn process_queue(&self, paired: &PairedDeviceConfig) -> Result<usize, ApiError> {
        let uploads = self.queue.next_ready(16)?;
        let mut complete = 0;
        let mut first_deferred_error: Option<String> = None;
        for upload in uploads {
            if !paired
                .scopes
                .iter()
                .any(|scope| scope == upload.envelope.guild_key.as_str())
            {
                self.queue.mark_action_required(
                    upload.id,
                    &upload.content_hash,
                    "device scope does not include this guild",
                )?;
                first_deferred_error.get_or_insert_with(|| {
                    "This device is not paired for one of the queued guild scopes.".into()
                });
                continue;
            }
            match self
                .upload_one(&paired.device_id, &upload.envelope, upload.queued_at)
                .await
            {
                Ok(receipt) => {
                    self.queue.mark_complete_with_receipt(
                        upload.id,
                        &upload.content_hash,
                        Some(receipt.committed_at.timestamp()),
                        Some(receipt.accepted_sequence),
                        &receipt.status,
                    )?;
                    complete += 1;
                }
                Err(error) => match error.upload_disposition(upload.envelope.kind) {
                    UploadErrorDisposition::Retry => {
                        first_deferred_error.get_or_insert_with(|| error.to_string());
                        self.queue.mark_retry(
                            upload.id,
                            &upload.content_hash,
                            upload.attempts,
                            &error.to_string(),
                            error.retry_after(),
                        )?;
                    }
                    UploadErrorDisposition::ActionRequired => {
                        let reason = error.action_required_reason(upload.envelope.kind);
                        first_deferred_error.get_or_insert_with(|| reason.clone());
                        self.queue.mark_action_required(
                            upload.id,
                            &upload.content_hash,
                            &reason,
                        )?;
                    }
                    UploadErrorDisposition::DeviceActionRequired => {
                        self.queue.mark_authorization_required(&error.to_string())?;
                        return Err(error);
                    }
                    UploadErrorDisposition::Superseded => {
                        self.queue
                            .mark_superseded(upload.id, &upload.content_hash)?;
                    }
                },
            }
        }
        if let Some(error) = first_deferred_error {
            return Err(ApiError::UploadDeferred(error));
        }
        Ok(complete)
    }

    async fn upload_one(
        &self,
        device_id: &str,
        envelope: &UploadEnvelope,
        queued_at: i64,
    ) -> Result<SyncCommitResponse, ApiError> {
        crate::guild::validate(&envelope.guild).map_err(|_| ApiError::InvalidResponse)?;
        if !valid_upload_envelope(envelope) {
            return Err(ApiError::InvalidResponse);
        }
        let expanded = canonical::canonical_json(
            &serde_json::to_value(envelope).map_err(|_| ApiError::InvalidResponse)?,
        );
        if expanded.len() > MAX_EXPANDED_CHUNK {
            return Err(ApiError::SegmentTooLarge);
        }
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder
            .write_all(&expanded)
            .map_err(|_| ApiError::InvalidResponse)?;
        let compressed = encoder.finish().map_err(|_| ApiError::InvalidResponse)?;
        if compressed.len() > MAX_COMPRESSED_CHUNK {
            return Err(ApiError::SegmentTooLarge);
        }
        let envelope_hash = hex::encode(Sha256::digest(&expanded));
        let manifest = build_sync_manifest(
            envelope,
            queued_at,
            &envelope_hash,
            compressed.len(),
            expanded.len(),
        )?;
        let manifest_hash = canonical::sha256_hex(&manifest);
        let start_body =
            canonical::canonical_json(&json!({"manifest":manifest,"manifestHash":manifest_hash}));
        let start_path = "/api/ember-sync/v1/sync/start";
        let response = self
            .signed_request(Method::POST, start_path, device_id, start_body)?
            .send()
            .await?;
        let start: SyncStartResponse = parse_response(response).await?;
        if !valid_token(&start.session_id)
            || start.expires_at <= Utc::now()
            || start.expires_at > Utc::now() + chrono::Duration::hours(1)
            || !server_chunk_limits_support_client(
                start.max_compressed_chunk_bytes,
                start.max_expanded_chunk_bytes,
            )
            || start.remaining_compressed_session_bytes < compressed.len()
        {
            return Err(ApiError::InvalidResponse);
        }
        if start.missing_envelope_hashes.len() > 1
            || start
                .missing_envelope_hashes
                .iter()
                .any(|hash| hash != &envelope_hash)
        {
            return Err(ApiError::InvalidResponse);
        }
        if start
            .missing_envelope_hashes
            .iter()
            .any(|hash| hash == &envelope_hash)
        {
            let path = format!(
                "/api/ember-sync/v1/sync/{}/chunks/{}",
                start.session_id, envelope_hash
            );
            let response = self
                .signed_request(Method::PUT, &path, device_id, compressed)?
                .header(CONTENT_TYPE, "application/json")
                .header(CONTENT_ENCODING, "gzip")
                .send()
                .await?;
            if !response.status().is_success() {
                return Err(response_error(response).await);
            }
        }
        let path = format!("/api/ember-sync/v1/sync/{}/commit", start.session_id);
        let body = canonical::canonical_json(&json!({"manifestHash":manifest_hash}));
        let response = self
            .signed_request(Method::POST, &path, device_id, body)?
            .send()
            .await?;
        let commit: SyncCommitResponse = parse_response(response).await?;
        if !valid_commit_response(&commit, envelope, Utc::now()) {
            return Err(ApiError::InvalidResponse);
        }
        Ok(commit)
    }

    fn signed_request(
        &self,
        method: Method,
        path: &str,
        device_id: &str,
        body: Vec<u8>,
    ) -> Result<reqwest::RequestBuilder, ApiError> {
        if !path.starts_with('/') || path.starts_with("//") || !valid_token(device_id) {
            return Err(ApiError::InvalidResponse);
        }
        let signing = self.signing_key()?;
        let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let mut nonce = [0_u8; 24];
        OsRng.fill_bytes(&mut nonce);
        let nonce = URL_SAFE_NO_PAD.encode(nonce);
        let body_hash = hex::encode(Sha256::digest(&body));
        let message = format!(
            "EMBERSYNC-SIGN-V1\n{}\n{}\n{}\n{}\n{}",
            method.as_str().to_ascii_uppercase(),
            path,
            timestamp,
            nonce,
            body_hash
        );
        let signature = URL_SAFE_NO_PAD.encode(signing.sign(message.as_bytes()).to_bytes());
        Ok(self
            .client
            .request(method, format!("{WEBSITE_URL}{path}"))
            .header(CONTENT_TYPE, "application/json")
            .header("x-embersync-device-id", device_id)
            .header("x-embersync-timestamp", timestamp)
            .header("x-embersync-nonce", nonce)
            .header("x-embersync-content-sha256", body_hash)
            .header("x-embersync-signature", signature)
            .body(body))
    }

    fn signing_key(&self) -> Result<SigningKey, ApiError> {
        if let Some(bytes) = self.queue.load_secure(SIGNING_KEY_NAME)? {
            let key: [u8; 32] = bytes
                .as_slice()
                .try_into()
                .map_err(|_| ApiError::InvalidResponse)?;
            return Ok(SigningKey::from_bytes(&key));
        }
        let signing = SigningKey::generate(&mut OsRng);
        self.queue
            .store_secure(SIGNING_KEY_NAME, &signing.to_bytes())?;
        Ok(signing)
    }
}

fn build_http_client(https_only: bool) -> Result<reqwest::Client, reqwest::Error> {
    reqwest::Client::builder()
        .https_only(https_only)
        .redirect(Policy::none())
        .user_agent(format!("EmberSync/{}", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(30))
        .build()
}

fn valid_commit_response(
    commit: &SyncCommitResponse,
    envelope: &UploadEnvelope,
    now: DateTime<Utc>,
) -> bool {
    matches!(commit.status.as_str(), "committed" | "already_committed")
        && commit.accepted_sequence == envelope.export_sequence
        && commit.committed_at <= now + chrono::Duration::minutes(5)
        && commit.committed_at >= envelope.captured_at - chrono::Duration::days(365)
}

async fn parse_response<T: for<'de> Deserialize<'de>>(
    response: reqwest::Response,
) -> Result<T, ApiError> {
    if !response.status().is_success() {
        return Err(response_error(response).await);
    }
    response.json().await.map_err(ApiError::Transport)
}
async fn response_error(response: reqwest::Response) -> ApiError {
    let status = response.status();
    let retry_after = response
        .headers()
        .get(RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok());
    let value = response.json::<Value>().await.unwrap_or(Value::Null);
    let code = response_code(&value);
    let message = value
        .get("message")
        .or_else(|| value.get("error"))
        .and_then(Value::as_str)
        .unwrap_or(status.canonical_reason().unwrap_or("request rejected"))
        .chars()
        .take(200)
        .collect();
    ApiError::Response {
        status: status.as_u16(),
        message,
        code,
        retry_after,
    }
}
fn response_code(value: &Value) -> Option<String> {
    value
        .get("code")
        // Protocol 1.0 responses use `code`. Keep the older machine-valued
        // `error` shape as a compatibility fallback.
        .or_else(|| value.get("error"))
        .and_then(Value::as_str)
        .filter(|value| {
            !value.is_empty()
                && value.len() <= 100
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
        .map(str::to_owned)
}
fn server_chunk_limits_support_client(max_compressed: usize, max_expanded: usize) -> bool {
    max_compressed >= MAX_COMPRESSED_CHUNK && max_expanded >= MAX_EXPANDED_CHUNK
}
fn valid_token(value: &str) -> bool {
    (16..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}
fn platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}
fn device_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(|value| {
            format!(
                "EmberSync on {}",
                value.trim().chars().take(80).collect::<String>()
            )
        })
        .unwrap_or_else(|| "EmberSync Desktop".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    use wiremock::{
        matchers::{method, path},
        Mock, MockServer, ResponseTemplate,
    };
    #[test]
    fn token_validation_rejects_path_injection() {
        assert!(valid_token("device_1234567890"));
        assert!(!valid_token("../../other-session"));
        assert!(!valid_token("short"));
    }

    #[tokio::test]
    async fn upload_client_refuses_cross_origin_and_same_origin_redirects() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/redirect"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("Location", format!("{}/target", server.uri())),
            )
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/target"))
            .respond_with(ResponseTemplate::new(200))
            .expect(0)
            .mount(&server)
            .await;
        let response = build_http_client(false)
            .unwrap()
            .get(format!("{}/redirect", server.uri()))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::FOUND);
    }

    #[test]
    fn commit_response_must_acknowledge_the_exact_uploaded_sequence() {
        let captured_at = Utc::now() - chrono::Duration::minutes(1);
        let envelope: UploadEnvelope = serde_json::from_value(json!({
            "schemaVersion": 1,
            "protocolVersion": "1.0",
            "dataset": "guild",
            "kind": "state",
            "scope": "guild",
            "subjectId": "main",
            "guildKey": "main",
            "guild": crate::guild::canonical(GuildKey::Main),
            "sourceCharacter": {
                "guid": "Player-1-ABCDEF01",
                "name": "Ember",
                "realm": "Dalaran",
                "realmSlug": "dalaran"
            },
            "installationId": "AbCdEf0123_-xYz9",
            "exportSequence": 7,
            "capturedAt": captured_at,
            "coverage": {
                "status": "complete",
                "observedAt": captured_at
            },
            "permissionEvidence": {},
            "payloadHash": "0".repeat(64),
            "payload": {}
        }))
        .unwrap();
        let now = Utc::now();
        let valid = SyncCommitResponse {
            status: "committed".into(),
            committed_at: now,
            accepted_sequence: 7,
        };
        assert!(valid_commit_response(&valid, &envelope, now));
        assert!(!valid_commit_response(
            &SyncCommitResponse {
                accepted_sequence: 8,
                ..valid
            },
            &envelope,
            now
        ));
    }

    fn raw_upload_envelope(dataset: &str, kind: DatasetKind, sequence: u64) -> UploadEnvelope {
        let captured_at = Utc::now() - chrono::Duration::minutes(1);
        let (scope, subject_id, event_range, payload) = match kind {
            DatasetKind::State => (
                "character",
                "Player-1-ABCDEF01".to_owned(),
                None,
                json!({"futureValue": 42}),
            ),
            DatasetKind::Events => (
                "guild",
                format!("AbCdEf0123_-xYz9:Player-1-ABCDEF01:{sequence}"),
                Some(crate::models::EventRange {
                    first_sequence: sequence,
                    last_sequence: sequence,
                }),
                json!({"events":[{
                    "sequence": sequence,
                    "capturedAt": captured_at.timestamp(),
                    "payload": {"futureValue": 42}
                }]}),
            ),
        };
        UploadEnvelope {
            schema_version: 1,
            protocol_version: "1.0".into(),
            dataset: dataset.into(),
            kind,
            scope: scope.into(),
            subject_id,
            guild_key: GuildKey::Main,
            guild: crate::guild::canonical(GuildKey::Main),
            source_character: crate::models::SourceCharacter {
                guid: "Player-1-ABCDEF01".into(),
                name: "Ember".into(),
                realm: "Dalaran".into(),
                realm_slug: "dalaran".into(),
            },
            installation_id: "AbCdEf0123_-xYz9".into(),
            export_sequence: sequence,
            event_range,
            captured_at,
            persisted_at: captured_at.timestamp() + 5,
            coverage: crate::models::Coverage {
                status: crate::models::CoverageStatus::Complete,
                reason_code: None,
                observed_at: captured_at,
                metadata: None,
            },
            permission_evidence: json!({}),
            payload_hash: canonical::sha256_hex(&payload),
            payload,
        }
    }

    #[test]
    fn bounded_future_state_and_event_batches_pass_signed_upload_validation() {
        let state = raw_upload_envelope("future_metric", DatasetKind::State, 7);
        assert!(valid_upload_envelope(&state));

        let event = raw_upload_envelope("events.future_stream", DatasetKind::Events, 8);
        assert!(valid_upload_envelope(&event));
        let queued_at = event.persisted_at + 3;
        let manifest = build_sync_manifest(&event, queued_at, &"a".repeat(64), 100, 200).unwrap();
        assert_eq!(manifest["persistedAt"], event.persisted_at);
        assert_eq!(manifest["queuedAt"], queued_at);
        assert_eq!(manifest["segments"][0]["dataset"], "events.future_stream");
        assert_eq!(manifest["segments"][0]["eventRange"]["lastSequence"], 8);

        let mut wrong_kind = state.clone();
        wrong_kind.dataset = "events.future_stream".into();
        assert!(!valid_upload_envelope(&wrong_kind));

        let mut mismatched_range = event.clone();
        mismatched_range.event_range.as_mut().unwrap().last_sequence = 9;
        assert!(!valid_upload_envelope(&mismatched_range));

        let mut mismatched_payload = event;
        mismatched_payload.payload["events"][0]["sequence"] = json!(9);
        mismatched_payload.payload_hash = canonical::sha256_hex(&mismatched_payload.payload);
        assert!(!valid_upload_envelope(&mismatched_payload));

        let mut missing_persistence = state;
        missing_persistence.persisted_at = 0;
        assert!(!valid_upload_envelope(&missing_persistence));
    }

    #[test]
    fn signing_context_matches_protocol() {
        let method = Method::POST;
        let path = "/api/ember-sync/v1/sync/start";
        let timestamp = "2026-07-22T12:00:00Z";
        let nonce = "YWJjZGVmZ2hpamtsbW5vcA";
        let hash = "0".repeat(64);
        assert_eq!(
            format!(
                "EMBERSYNC-SIGN-V1\n{}\n{}\n{}\n{}\n{}",
                method.as_str(),
                path,
                timestamp,
                nonce,
                hash
            ),
            format!("EMBERSYNC-SIGN-V1\nPOST\n{path}\n{timestamp}\n{nonce}\n{hash}")
        );
    }

    #[test]
    fn self_revoke_uses_the_exact_signed_device_route_and_body() {
        let directory = tempfile::tempdir().unwrap();
        let queue = QueueStore::open(&directory.path().join("queue.sqlite3")).unwrap();
        queue
            .unlock_with_passphrase("test-only-passphrase")
            .unwrap();
        let client = ApiClient::new(queue.clone()).unwrap();
        let device_id = "device_1234567890";
        let path = format!("/api/ember-sync/v1/devices/{device_id}/revoke");
        let body = canonical::canonical_json(&json!({"protocolVersion":"1.0"}));
        let request = client
            .signed_request(Method::POST, &path, device_id, body.clone())
            .unwrap()
            .build()
            .unwrap();

        assert_eq!(request.method(), Method::POST);
        assert_eq!(request.url().as_str(), format!("{WEBSITE_URL}{path}"));
        assert_eq!(
            request.body().and_then(reqwest::Body::as_bytes),
            Some(body.as_slice())
        );
        assert_eq!(request.headers()["x-embersync-device-id"], device_id);

        let timestamp = request.headers()["x-embersync-timestamp"].to_str().unwrap();
        let nonce = request.headers()["x-embersync-nonce"].to_str().unwrap();
        let body_hash = request.headers()["x-embersync-content-sha256"]
            .to_str()
            .unwrap();
        assert_eq!(body_hash, hex::encode(Sha256::digest(&body)));
        let signature = Signature::from_slice(
            &URL_SAFE_NO_PAD
                .decode(request.headers()["x-embersync-signature"].to_str().unwrap())
                .unwrap(),
        )
        .unwrap();
        let key_bytes: [u8; 32] = queue
            .load_secure(SIGNING_KEY_NAME)
            .unwrap()
            .unwrap()
            .as_slice()
            .try_into()
            .unwrap();
        let verifying_key = VerifyingKey::from(&SigningKey::from_bytes(&key_bytes));
        let message = format!("EMBERSYNC-SIGN-V1\nPOST\n{path}\n{timestamp}\n{nonce}\n{body_hash}");
        verifying_key
            .verify(message.as_bytes(), &signature)
            .unwrap();
    }

    #[test]
    fn fresh_battlenet_proof_failure_blocks_automatic_queue_retries() {
        let error = ApiError::Response {
            status: 403,
            message: "Sign in with Battle.net again before pairing or uploading with EmberSync."
                .into(),
            code: Some("ownership_reverification_required".into()),
            retry_after: None,
        };
        assert_eq!(
            error.upload_disposition(DatasetKind::State),
            UploadErrorDisposition::DeviceActionRequired
        );

        let provider_error = ApiError::Response {
            status: 503,
            message: "Current membership could not be verified.".into(),
            code: Some("membership_verification_unavailable".into()),
            retry_after: Some(60),
        };
        assert_eq!(
            provider_error.upload_disposition(DatasetKind::State),
            UploadErrorDisposition::Retry
        );
    }

    #[test]
    fn upload_error_dispositions_follow_the_server_contract() {
        struct Case {
            status: u16,
            code: Option<&'static str>,
            kind: DatasetKind,
            expected: UploadErrorDisposition,
        }

        let cases = [
            Case {
                status: 408,
                code: None,
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 429,
                code: Some("rate_limited"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 503,
                code: Some("service_unavailable"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 503,
                code: Some("storage_unavailable"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 503,
                code: Some("membership_verification_unavailable"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 409,
                code: Some("sync_session_expired"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Retry,
            },
            Case {
                status: 401,
                code: Some("device_not_paired"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::DeviceActionRequired,
            },
            Case {
                status: 401,
                code: Some("device_revoked"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::DeviceActionRequired,
            },
            Case {
                status: 401,
                code: Some("invalid_signature"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::DeviceActionRequired,
            },
            Case {
                status: 403,
                code: Some("account_not_eligible"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::DeviceActionRequired,
            },
            Case {
                status: 403,
                code: Some("guild_membership_required"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::DeviceActionRequired,
            },
            Case {
                status: 401,
                code: Some("stale_request"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 400,
                code: Some("unsupported_schema"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 403,
                code: Some("guild_identity_denied"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 403,
                code: Some("source_character_not_authorized"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 400,
                code: Some("dataset_scope_mismatch"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 400,
                code: Some("invalid_chunk_envelope"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 409,
                code: Some("sequence_conflict"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 413,
                code: Some("sync_too_large"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::ActionRequired,
            },
            Case {
                status: 409,
                code: Some("sequence_replay"),
                kind: DatasetKind::State,
                expected: UploadErrorDisposition::Superseded,
            },
            Case {
                status: 409,
                code: Some("sequence_replay"),
                kind: DatasetKind::Events,
                expected: UploadErrorDisposition::ActionRequired,
            },
        ];

        for case in cases {
            let error = ApiError::Response {
                status: case.status,
                message: "server response".into(),
                code: case.code.map(str::to_owned),
                retry_after: None,
            };
            assert_eq!(
                error.upload_disposition(case.kind),
                case.expected,
                "unexpected disposition for status {} code {:?} kind {:?}",
                case.status,
                case.code,
                case.kind,
            );
        }

        assert_eq!(
            ApiError::SegmentTooLarge.upload_disposition(DatasetKind::State),
            UploadErrorDisposition::ActionRequired
        );
    }

    #[test]
    fn replayed_events_are_identified_as_a_coverage_gap() {
        let error = ApiError::Response {
            status: 409,
            message: "The export sequence was already superseded.".into(),
            code: Some("sequence_replay".into()),
            retry_after: None,
        };
        let reason = error.action_required_reason(DatasetKind::Events);
        assert!(reason.contains("event coverage gap requires review"));
        assert!(reason.contains("was not discarded"));
        assert!(!error
            .action_required_reason(DatasetKind::State)
            .contains("coverage gap"));
    }

    #[test]
    fn server_chunk_limits_may_grow_but_may_not_shrink_below_client_requirements() {
        assert!(server_chunk_limits_support_client(
            MAX_COMPRESSED_CHUNK,
            MAX_EXPANDED_CHUNK
        ));
        assert!(server_chunk_limits_support_client(
            MAX_COMPRESSED_CHUNK * 2,
            MAX_EXPANDED_CHUNK * 2
        ));
        assert!(!server_chunk_limits_support_client(
            MAX_COMPRESSED_CHUNK - 1,
            MAX_EXPANDED_CHUNK
        ));
        assert!(!server_chunk_limits_support_client(
            MAX_COMPRESSED_CHUNK,
            MAX_EXPANDED_CHUNK - 1
        ));
    }

    #[test]
    fn already_revoked_device_allows_idempotent_local_disconnect() {
        for code in ["device_revoked", "device_not_found", "device_not_paired"] {
            let error = ApiError::Response {
                status: if code == "device_not_found" { 404 } else { 401 },
                message: "This EmberSync device is not authorized.".into(),
                code: Some(code.into()),
                retry_after: None,
            };
            assert!(error.confirms_device_is_inactive());
        }

        let invalid_signature = ApiError::Response {
            status: 401,
            message: "The EmberSync signature is invalid.".into(),
            code: Some("invalid_signature".into()),
            retry_after: None,
        };
        assert!(!invalid_signature.confirms_device_is_inactive());
    }

    #[test]
    fn response_machine_code_comes_from_the_code_field() {
        let value = json!({
            "error": "This EmberSync device is not authorized.",
            "code": "device_revoked"
        });
        assert_eq!(response_code(&value).as_deref(), Some("device_revoked"));
    }
}
