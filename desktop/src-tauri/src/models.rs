use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GuildKey {
    Main,
    Alt,
}

impl GuildKey {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Alt => "alt",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GuildIdentity {
    pub key: GuildKey,
    pub name: String,
    pub slug: String,
    pub founding_realm: String,
    pub realm_slug: String,
    pub region: String,
    pub profile_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RawGuildIdentity {
    pub key: GuildKey,
    pub name: String,
    pub realm: String,
    pub region: u8,
}

impl RawGuildIdentity {
    pub fn normalized(&self) -> GuildIdentity {
        crate::guild::canonical(self.key)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawSourceCharacter {
    pub id: String,
    pub name: String,
    pub realm: String,
    #[serde(default)]
    pub rank_index: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceCharacter {
    pub guid: String,
    pub name: String,
    pub realm: String,
    pub realm_slug: String,
}

pub fn event_subject_id(
    installation_id: &str,
    source_character_guid: &str,
    first_sequence: u64,
) -> String {
    format!("{installation_id}:{source_character_guid}:{first_sequence}")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageStatus {
    Complete,
    Partial,
    Forbidden,
    InteractionRequired,
    Unavailable,
    Unsupported,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Coverage {
    pub status: CoverageStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason_code: Option<String>,
    pub observed_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Map<String, Value>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawCoverage {
    pub status: CoverageStatus,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub observed_at: Option<i64>,
    #[serde(flatten)]
    pub metadata: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawDatasetEnvelope {
    pub schema_version: u32,
    pub dataset: String,
    pub scope: String,
    pub subject_id: String,
    pub guild_key: GuildKey,
    pub guild: RawGuildIdentity,
    pub source_character: RawSourceCharacter,
    pub installation_id: String,
    pub sequence: u64,
    pub captured_at: i64,
    pub coverage: RawCoverage,
    #[serde(default)]
    pub permission_evidence: Value,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawAddonEvent {
    pub sequence: u64,
    pub captured_at: i64,
    pub guild_key: GuildKey,
    pub source_character: RawSourceCharacter,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawGuildExport {
    pub schema_version: u32,
    pub guild: RawGuildIdentity,
    pub source_character: RawSourceCharacter,
    pub installation_id: String,
    pub sequence: u64,
    pub captured_at: i64,
    #[serde(default)]
    pub persisted_at: Option<i64>,
    #[serde(default)]
    pub datasets: serde_json::Map<String, Value>,
    #[serde(default)]
    pub events: serde_json::Map<String, Value>,
    #[serde(default)]
    pub coverage: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedVariablesDatabase {
    pub schema_version: u32,
    pub installation_id: String,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub updated_at: Option<i64>,
    pub exports: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadEnvelope {
    pub schema_version: u32,
    pub protocol_version: String,
    pub dataset: String,
    pub kind: DatasetKind,
    pub scope: String,
    pub subject_id: String,
    pub guild_key: GuildKey,
    pub guild: GuildIdentity,
    pub source_character: SourceCharacter,
    pub installation_id: String,
    pub export_sequence: u64,
    pub captured_at: DateTime<Utc>,
    pub coverage: Coverage,
    pub permission_evidence: Value,
    pub payload_hash: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DatasetKind {
    State,
    Events,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MembershipState {
    Checking,
    Authorized,
    Denied,
    NoExports,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VaultState {
    Ready,
    Locked,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Unpaired,
    Paired,
    Connecting,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct QueueSummary {
    pub pending: u64,
    pub uploading: u64,
    pub failed: u64,
    pub action_required: u64,
    pub authorization_required: bool,
    pub bytes_encrypted: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GuildStatus {
    pub key: GuildKey,
    pub name: String,
    pub realm: String,
    pub source_characters: usize,
    pub last_captured_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopStatus {
    pub membership: MembershipState,
    pub vault: VaultState,
    pub connection: ConnectionState,
    pub device_name: Option<String>,
    pub device_id: Option<String>,
    pub watcher_running: bool,
    pub discovered_files: usize,
    pub last_scan_at: Option<DateTime<Utc>>,
    pub last_upload_at: Option<DateTime<Utc>>,
    pub message: Option<String>,
    pub guilds: Vec<GuildStatus>,
    pub queue: QueueSummary,
    pub roots: Vec<String>,
}

impl Default for DesktopStatus {
    fn default() -> Self {
        Self {
            membership: MembershipState::Checking,
            vault: VaultState::Locked,
            connection: ConnectionState::Unpaired,
            device_name: None,
            device_id: None,
            watcher_running: false,
            discovered_files: 0,
            last_scan_at: None,
            last_upload_at: None,
            message: None,
            guilds: vec![],
            queue: QueueSummary::default(),
            roots: vec![],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoverageRow {
    pub guild_key: GuildKey,
    pub dataset: String,
    pub subject_id: String,
    pub status: CoverageStatus,
    pub observed_at: Option<DateTime<Utc>>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DiagnosticLevel {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticEvent {
    pub id: String,
    pub at: DateTime<Utc>,
    pub level: DiagnosticLevel,
    pub message: String,
}
