use crate::{
    canonical, discovery, guild, lua,
    models::*,
    queue::{QueueError, QueueStore},
};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IngestError {
    #[error("unable to read SavedVariables: {0}")]
    Read(#[from] std::io::Error),
    #[error("SavedVariables are not safe literal data: {0}")]
    Parse(#[from] lua::LuaParseError),
    #[error("SavedVariables schema is invalid: {0}")]
    Schema(#[from] serde_json::Error),
    #[error("unsupported SavedVariables schema version")]
    UnsupportedSchema,
    #[error("unapproved guild export: {0}")]
    Guild(#[from] guild::GuildValidationError),
    #[error("invalid capture time")]
    InvalidTime,
    #[error("dataset identity does not match its verified export")]
    DatasetMismatch,
    #[error("local encrypted queue rejected the export: {0}")]
    Queue(#[from] QueueError),
}

#[derive(Debug, Clone)]
pub struct IngestResult {
    pub used_backup: bool,
    pub guilds: Vec<GuildStatus>,
    pub coverage: Vec<CoverageRow>,
    pub queued: usize,
}

pub struct Ingestor {
    queue: Arc<QueueStore>,
}

impl Ingestor {
    pub fn new(queue: Arc<QueueStore>) -> Self {
        Self { queue }
    }

    pub fn ingest_path(&self, path: &Path) -> Result<IngestResult, IngestError> {
        let primary = discovery::read_stable(path);
        match primary {
            Ok(bytes) => match self.ingest_bytes(path, &bytes, false) {
                Ok(result) => Ok(result),
                Err(IngestError::Parse(_) | IngestError::Schema(_)) => self.ingest_backup(path),
                Err(error) => Err(error),
            },
            Err(_) => self.ingest_backup(path),
        }
    }

    fn ingest_backup(&self, path: &Path) -> Result<IngestResult, IngestError> {
        let backup = PathBuf::from(format!("{}.bak", path.display()));
        let bytes = discovery::read_stable(&backup)?;
        self.ingest_bytes(path, &bytes, true)
    }

    pub fn ingest_bytes(
        &self,
        _path: &Path,
        bytes: &[u8],
        used_backup: bool,
    ) -> Result<IngestResult, IngestError> {
        let parsed = lua::parse_ember_sync_db(bytes)?;
        let database: SavedVariablesDatabase = serde_json::from_value(parsed)?;
        if database.schema_version != 1 {
            return Err(IngestError::UnsupportedSchema);
        }
        let mut staged = Vec::new();
        let mut guilds = Vec::new();
        let mut rows = Vec::new();
        for (map_key, value) in database.exports {
            if map_key != "main" && map_key != "alt" {
                return Err(guild::GuildValidationError::UnknownKey.into());
            }
            let export: RawGuildExport = serde_json::from_value(value)?;
            validate_export(&map_key, &database.installation_id, &export)?;
            let mut state_count = 0;
            for (dataset_key, value) in &export.datasets {
                let raw: RawDatasetEnvelope = serde_json::from_value(value.clone())?;
                validate_dataset(&map_key, dataset_key, &export, &raw)?;
                let envelope = normalize_dataset(raw, DatasetKind::State)?;
                rows.push(coverage_row(&envelope));
                staged.push(envelope);
                state_count += 1;
            }
            for (stream, value) in &export.events {
                let events: Vec<RawAddonEvent> = serde_json::from_value(value.clone())?;
                let stream_coverage = export
                    .coverage
                    .get(&format!("events.{stream}"))
                    .and_then(|value| serde_json::from_value::<RawCoverage>(value.clone()).ok());
                for event in events {
                    validate_event(&export, &event)?;
                    staged.push(normalize_event(
                        stream,
                        &export,
                        event,
                        stream_coverage.clone(),
                    )?);
                }
            }
            for (dataset, value) in &export.coverage {
                if rows
                    .iter()
                    .any(|row| row.guild_key == export.guild.key && row.dataset == *dataset)
                {
                    continue;
                }
                if let Ok(coverage) = serde_json::from_value::<RawCoverage>(value.clone()) {
                    rows.push(CoverageRow {
                        guild_key: export.guild.key,
                        dataset: dataset.clone(),
                        subject_id: export.guild.key.as_str().into(),
                        status: coverage.status,
                        observed_at: optional_time(coverage.observed_at)?,
                        reason: coverage.reason,
                    });
                }
            }
            guilds.push(GuildStatus {
                key: export.guild.key,
                name: export.guild.name.clone(),
                realm: export.guild.realm.clone(),
                source_characters: usize::from(state_count > 0),
                last_captured_at: Some(required_time(export.captured_at)?),
            });
        }
        if guilds.is_empty() {
            return Ok(IngestResult {
                used_backup,
                guilds,
                coverage: rows,
                queued: 0,
            });
        }
        let mut queued = 0;
        if self.queue.is_unlocked() {
            for envelope in staged {
                if self.queue.enqueue(&envelope)? {
                    queued += 1;
                }
            }
        }
        Ok(IngestResult {
            used_backup,
            guilds,
            coverage: rows,
            queued,
        })
    }
}

fn validate_export(
    map_key: &str,
    database_installation: &str,
    export: &RawGuildExport,
) -> Result<(), IngestError> {
    if export.schema_version != 1
        || export.installation_id != database_installation
        || export.installation_id.len() < 8
    {
        return Err(IngestError::DatasetMismatch);
    }
    guild::validate_raw_map_key(map_key, &export.guild)?;
    if export.source_character.id.trim().is_empty()
        || export.source_character.name.trim().is_empty()
    {
        return Err(IngestError::DatasetMismatch);
    }
    required_time(export.captured_at)?;
    Ok(())
}

fn validate_dataset(
    map_key: &str,
    dataset_key: &str,
    export: &RawGuildExport,
    dataset: &RawDatasetEnvelope,
) -> Result<(), IngestError> {
    if dataset.schema_version != 1
        || dataset.installation_id != export.installation_id
        || dataset.guild_key != export.guild.key
        || dataset.guild != export.guild
        || dataset.source_character.id != export.source_character.id
    {
        return Err(IngestError::DatasetMismatch);
    }
    guild::validate_raw_map_key(map_key, &dataset.guild)?;
    let expected_key = if dataset.scope == "guild" || dataset.scope == "account" {
        dataset.dataset.clone()
    } else {
        format!("{}:{}", dataset.dataset, dataset.subject_id)
    };
    if dataset_key != expected_key && dataset_key != dataset.dataset {
        return Err(IngestError::DatasetMismatch);
    }
    required_time(dataset.captured_at)?;
    Ok(())
}

fn validate_event(export: &RawGuildExport, event: &RawAddonEvent) -> Result<(), IngestError> {
    if event.guild_key != export.guild.key
        || event.source_character.id != export.source_character.id
        || event.sequence == 0
    {
        return Err(IngestError::DatasetMismatch);
    }
    required_time(event.captured_at)?;
    Ok(())
}

fn normalize_dataset(
    raw: RawDatasetEnvelope,
    kind: DatasetKind,
) -> Result<UploadEnvelope, IngestError> {
    let payload_hash = canonical::sha256_hex(&raw.payload);
    let coverage = normalize_coverage(raw.coverage, raw.captured_at)?;
    let permission_evidence = normalize_permission(
        raw.permission_evidence,
        &raw.source_character,
        coverage.observed_at,
    );
    Ok(UploadEnvelope {
        schema_version: 1,
        protocol_version: "1.0".into(),
        dataset: raw.dataset,
        kind,
        scope: raw.scope,
        subject_id: raw.subject_id,
        guild_key: raw.guild_key,
        guild: raw.guild.normalized(),
        source_character: normalize_source(raw.source_character),
        installation_id: raw.installation_id,
        export_sequence: raw.sequence,
        captured_at: required_time(raw.captured_at)?,
        coverage,
        permission_evidence,
        payload_hash,
        payload: raw.payload,
    })
}

fn normalize_event(
    stream: &str,
    export: &RawGuildExport,
    event: RawAddonEvent,
    coverage: Option<RawCoverage>,
) -> Result<UploadEnvelope, IngestError> {
    let payload_hash = canonical::sha256_hex(&event.payload);
    let captured_at = required_time(event.captured_at)?;
    let source_id = event.source_character.id.clone();
    let normalized_coverage = match coverage {
        Some(value) => normalize_coverage(value, event.captured_at)?,
        None => Coverage {
            status: CoverageStatus::Partial,
            reason_code: Some("event_stream".into()),
            observed_at: captured_at,
            metadata: None,
        },
    };
    let permission_evidence = normalize_permission(
        Value::Null,
        &event.source_character,
        normalized_coverage.observed_at,
    );
    Ok(UploadEnvelope {
        schema_version: 1,
        protocol_version: "1.0".into(),
        dataset: format!("events.{stream}"),
        kind: DatasetKind::Events,
        scope: "guild".into(),
        subject_id: crate::models::event_subject_id(
            &export.installation_id,
            &source_id,
            event.sequence,
        ),
        guild_key: event.guild_key,
        guild: export.guild.normalized(),
        source_character: normalize_source(event.source_character),
        installation_id: export.installation_id.clone(),
        export_sequence: event.sequence,
        captured_at,
        coverage: normalized_coverage,
        permission_evidence,
        payload_hash,
        payload: event.payload,
    })
}

fn normalize_coverage(raw: RawCoverage, fallback: i64) -> Result<Coverage, IngestError> {
    let mut metadata = raw.metadata;
    metadata.remove("status");
    metadata.remove("observedAt");
    metadata.remove("reason");
    Ok(Coverage {
        status: raw.status,
        reason_code: raw.reason,
        observed_at: required_time(raw.observed_at.unwrap_or(fallback))?,
        metadata: (!metadata.is_empty()).then_some(metadata),
    })
}

fn coverage_row(envelope: &UploadEnvelope) -> CoverageRow {
    CoverageRow {
        guild_key: envelope.guild_key,
        dataset: envelope.dataset.clone(),
        subject_id: envelope.subject_id.clone(),
        status: envelope.coverage.status.clone(),
        observed_at: Some(envelope.coverage.observed_at),
        reason: envelope.coverage.reason_code.clone(),
    }
}

fn normalize_source(raw: RawSourceCharacter) -> SourceCharacter {
    SourceCharacter {
        guid: raw.id,
        name: raw.name,
        realm_slug: realm_slug(&raw.realm),
        realm: raw.realm,
    }
}

fn realm_slug(value: &str) -> String {
    let mut slug = String::new();
    let mut separator = false;
    for ch in value.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            if separator && !slug.is_empty() {
                slug.push('-');
            }
            separator = false;
            slug.push(ch);
        } else if !matches!(ch, '\'' | '’') {
            separator = true;
        }
    }
    slug.trim_matches('-').to_string()
}

fn normalize_permission(
    raw: Value,
    source: &RawSourceCharacter,
    observed_at: DateTime<Utc>,
) -> Value {
    let mut input = raw.as_object().cloned().unwrap_or_default();
    let rank_index = input
        .remove("rankIndex")
        .and_then(|value| value.as_u64())
        .unwrap_or(u64::from(source.rank_index));
    let mut output = serde_json::Map::new();
    output.insert(
        "observedAt".into(),
        Value::String(observed_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
    );
    output.insert("guildRankIndex".into(), Value::Number(rank_index.into()));
    if let Some(value) = input.remove("rankName").filter(Value::is_string) {
        output.insert("guildRankName".into(), value);
    }
    for key in ["canViewOfficerNote", "canUseOfficerChat", "guildBankTabs"] {
        if let Some(value) = input.remove(key) {
            output.insert(key.into(), value);
        }
    }
    if !input.is_empty() {
        output.insert("metadata".into(), Value::Object(input));
    }
    Value::Object(output)
}

fn required_time(value: i64) -> Result<DateTime<Utc>, IngestError> {
    DateTime::from_timestamp(value, 0).ok_or(IngestError::InvalidTime)
}
fn optional_time(value: Option<i64>) -> Result<Option<DateTime<Utc>>, IngestError> {
    value.map(required_time).transpose()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn fixture(realm: &str, region: u8) -> String {
        format!(
            r#"EmberSyncDB={{schemaVersion=1,installationId="es-install-1",createdAt=1750000000,updatedAt=1750000001,exports={{main={{schemaVersion=1,guild={{key="main",name="Raining Embers",realm="{realm}",region={region}}},installationId="es-install-1",sequence=2,capturedAt=1750000001,sourceCharacter={{id="Player-1",name="Aria",realm="Dalaran",rankIndex=0}},datasets={{guild={{schemaVersion=1,dataset="guild",scope="guild",subjectId="main",guildKey="main",guild={{key="main",name="Raining Embers",realm="{realm}",region={region}}},sourceCharacter={{id="Player-1",name="Aria",realm="Dalaran",rankIndex=0}},installationId="es-install-1",sequence=1,capturedAt=1750000000,coverage={{status="complete",observedAt=1750000000}},permissionEvidence={{rankIndex=0}},payload={{motd="Welcome"}}}}}},events={{guild_chat={{{{sequence=2,capturedAt=1750000001,guildKey="main",sourceCharacter={{id="Player-1",name="Aria",realm="Dalaran",rankIndex=0}},payload={{message="hello"}}}}}}}},coverage={{guild={{status="complete",observedAt=1750000000}},["events.guild_chat"]={{status="partial",observedAt=1750000001}}}}}}}}}}"#
        )
    }

    fn ingestor() -> Ingestor {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        Ingestor::new(queue)
    }

    #[test]
    fn accepts_approved_export_and_queues_state_and_events() {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let result = Ingestor::new(queue.clone())
            .ingest_bytes(
                Path::new("EmberSync.lua"),
                fixture("Dalaran", 1).as_bytes(),
                false,
            )
            .unwrap();
        assert_eq!(result.guilds.len(), 1);
        assert_eq!(result.queued, 2);
        assert!(result.coverage.iter().any(|row| row.dataset == "guild"));
        assert!(queue.next_ready(16).unwrap().iter().any(|upload| {
            upload.envelope.dataset == "events.guild_chat"
                && upload.envelope.subject_id == "es-install-1:Player-1:2"
        }));
    }

    #[test]
    fn rejects_same_name_on_wrong_realm_or_region() {
        assert!(matches!(
            ingestor().ingest_bytes(Path::new("x"), fixture("Stormrage", 1).as_bytes(), false),
            Err(IngestError::Guild(_))
        ));
        assert!(matches!(
            ingestor().ingest_bytes(Path::new("x"), fixture("Dalaran", 2).as_bytes(), false),
            Err(IngestError::Guild(_))
        ));
    }

    #[test]
    fn locked_vault_validates_membership_but_does_not_queue_plaintext() {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        let ingestor = Ingestor::new(queue.clone());
        let result = ingestor
            .ingest_bytes(Path::new("x"), fixture("Dalaran", 1).as_bytes(), false)
            .unwrap();
        assert_eq!(result.guilds.len(), 1);
        assert_eq!(result.queued, 0);
        assert_eq!(queue.summary().unwrap().pending, 0);
    }

    #[test]
    fn consumes_the_addons_exact_saved_variables_fixture() {
        let fixture = include_bytes!("../../../tests/addon/fixtures/EmberSync.lua");
        let result = ingestor()
            .ingest_bytes(Path::new("EmberSync.lua"), fixture, false)
            .unwrap();
        assert_eq!(result.guilds.len(), 1);
        assert!(result.coverage.iter().any(|row| row.dataset == "guild"));
        assert!(result.queued >= 2);
    }
}
