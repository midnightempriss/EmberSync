use crate::{
    canonical,
    config::{PairedDeviceConfig, PendingPairingConfig},
    guild::WEBSITE_URL,
    models::{DatasetKind, GuildKey, UploadEnvelope},
    queue::{QueueError, QueueStore},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, SecondsFormat, Utc};
use ed25519_dalek::{Signer, SigningKey};
use flate2::{write::GzEncoder, Compression};
use rand::{rngs::OsRng, RngCore};
use reqwest::{
    header::{CONTENT_ENCODING, CONTENT_TYPE, RETRY_AFTER},
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

impl ApiError {
    pub fn retry_after(&self) -> Option<u64> {
        match self {
            Self::Response { retry_after, .. } => *retry_after,
            _ => None,
        }
    }

    fn blocks_queue_for_authorization(&self) -> bool {
        match self {
            Self::Response {
                status,
                message,
                code,
                ..
            } => {
                matches!(
                    code.as_deref(),
                    Some(
                        "ownership_reverification_required"
                            | "account_not_eligible"
                            | "guild_membership_required"
                            | "device_revoked"
                            | "device_not_paired"
                    )
                ) || (*status == 403 && message.contains("Sign in with Battle.net again"))
            }
            _ => false,
        }
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
    missing_envelope_hashes: Vec<String>,
    max_compressed_chunk_bytes: usize,
    max_expanded_chunk_bytes: usize,
    remaining_compressed_session_bytes: usize,
}

pub struct ApiClient {
    client: reqwest::Client,
    queue: Arc<QueueStore>,
}

impl ApiClient {
    pub fn new(queue: Arc<QueueStore>) -> Result<Self, ApiError> {
        let client = reqwest::Client::builder()
            .https_only(true)
            .user_agent(format!("EmberSync/{}", env!("CARGO_PKG_VERSION")))
            .timeout(std::time::Duration::from_secs(30))
            .build()?;
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
                self.queue
                    .mark_action_required(upload.id, "device scope does not include this guild")?;
                first_deferred_error.get_or_insert_with(|| {
                    "This device is not paired for one of the queued guild scopes.".into()
                });
                continue;
            }
            match self.upload_one(&paired.device_id, &upload.envelope).await {
                Ok(()) => {
                    self.queue.mark_complete(upload.id)?;
                    complete += 1;
                }
                Err(error) => {
                    if error.blocks_queue_for_authorization() {
                        self.queue.mark_authorization_required(&error.to_string())?;
                        return Err(error);
                    }
                    first_deferred_error.get_or_insert_with(|| error.to_string());
                    self.queue.mark_retry(
                        upload.id,
                        upload.attempts,
                        &error.to_string(),
                        error.retry_after(),
                    )?;
                }
            }
        }
        if complete == 0 {
            if let Some(error) = first_deferred_error {
                return Err(ApiError::UploadDeferred(error));
            }
        }
        Ok(complete)
    }

    async fn upload_one(&self, device_id: &str, envelope: &UploadEnvelope) -> Result<(), ApiError> {
        crate::guild::validate(&envelope.guild).map_err(|_| ApiError::InvalidResponse)?;
        if envelope.kind == DatasetKind::Events
            && envelope.subject_id
                != crate::models::event_subject_id(
                    &envelope.installation_id,
                    &envelope.source_character.guid,
                    envelope.export_sequence,
                )
        {
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
        let mut segment = json!({"dataset":envelope.dataset,"kind":envelope.kind,"scope":envelope.scope,"subjectId":envelope.subject_id,"coverage":envelope.coverage,"payloadHash":envelope.payload_hash,"envelopeHash":envelope_hash,"compressedBytes":compressed.len(),"expandedBytes":expanded.len()});
        if envelope.kind == DatasetKind::Events {
            segment.as_object_mut().expect("segment is an object").insert(
                "eventRange".into(),
                json!({"firstSequence":envelope.export_sequence,"lastSequence":envelope.export_sequence}),
            );
        }
        let manifest = json!({"schemaVersion":1,"protocolVersion":"1.0","guildKey":envelope.guild_key,"guild":envelope.guild,"sourceCharacter":envelope.source_character,"installationId":envelope.installation_id,"exportSequence":envelope.export_sequence,"capturedAt":envelope.captured_at.to_rfc3339_opts(SecondsFormat::Secs,true),"segments":[segment]});
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
            || start.max_compressed_chunk_bytes != MAX_COMPRESSED_CHUNK
            || start.max_expanded_chunk_bytes != MAX_EXPANDED_CHUNK
            || start.remaining_compressed_session_bytes < compressed.len()
        {
            return Err(ApiError::InvalidResponse);
        }
        if start
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
        if !response.status().is_success() {
            return Err(response_error(response).await);
        }
        Ok(())
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
    let code = value
        .get("error")
        .and_then(Value::as_str)
        .filter(|value| {
            !value.is_empty()
                && value.len() <= 100
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
        .map(str::to_owned);
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
    #[test]
    fn token_validation_rejects_path_injection() {
        assert!(valid_token("device_1234567890"));
        assert!(!valid_token("../../other-session"));
        assert!(!valid_token("short"));
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
    fn fresh_battlenet_proof_failure_blocks_automatic_queue_retries() {
        let error = ApiError::Response {
            status: 403,
            message: "Sign in with Battle.net again before pairing or uploading with EmberSync."
                .into(),
            code: Some("ownership_reverification_required".into()),
            retry_after: None,
        };
        assert!(error.blocks_queue_for_authorization());

        let provider_error = ApiError::Response {
            status: 503,
            message: "Current membership could not be verified.".into(),
            code: Some("membership_verification_unavailable".into()),
            retry_after: Some(60),
        };
        assert!(!provider_error.blocks_queue_for_authorization());
    }
}
