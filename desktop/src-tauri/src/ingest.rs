use crate::{
    canonical, discovery, guild, lua,
    models::*,
    queue::{QueueError, QueueStore},
    registry,
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
    #[error("calendar payload contains records outside the guild-only privacy contract")]
    CalendarPrivacy,
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
            let mut calendar_quarantined = false;
            for (dataset_key, value) in &export.datasets {
                let raw: RawDatasetEnvelope = serde_json::from_value(value.clone())?;
                match validate_dataset(&map_key, dataset_key, &export, &raw) {
                    Ok(()) => {}
                    // A prerelease SavedVariables file may still contain a
                    // mixed calendar payload. Quarantine that one dataset so
                    // unrelated guild data remains uploadable.
                    Err(IngestError::CalendarPrivacy) => {
                        calendar_quarantined = true;
                        rows.push(CoverageRow {
                            guild_key: export.guild.key,
                            dataset: "calendar".into(),
                            subject_id: raw.subject_id.clone(),
                            status: CoverageStatus::Forbidden,
                            observed_at: Some(required_time(raw.captured_at)?),
                            reason: Some("calendar_privacy_quarantined".into()),
                        });
                        continue;
                    }
                    Err(error) => return Err(error),
                }
                let envelope = normalize_dataset(
                    raw,
                    DatasetKind::State,
                    export.persisted_at.unwrap_or(export.captured_at),
                )?;
                rows.push(coverage_row(&envelope));
                staged.push(envelope);
                state_count += 1;
            }
            for (stream, value) in &export.events {
                if !registry::is_bounded_event_stream(stream) {
                    return Err(IngestError::DatasetMismatch);
                }
                let events: Vec<RawAddonEvent> = serde_json::from_value(value.clone())?;
                let stream_coverage = export
                    .coverage
                    .get(&format!("events.{stream}"))
                    .and_then(|value| serde_json::from_value::<RawCoverage>(value.clone()).ok());
                let mut previous_sequence = 0;
                for event in &events {
                    validate_event(&export, event)?;
                    if event.sequence <= previous_sequence {
                        return Err(IngestError::DatasetMismatch);
                    }
                    previous_sequence = event.sequence;
                }
                for batch in contiguous_event_batches(events) {
                    let envelope =
                        normalize_event_batch(stream, &export, batch, stream_coverage.clone())?;
                    rows.push(coverage_row(&envelope));
                    staged.push(envelope);
                }
            }
            for (dataset, value) in &export.coverage {
                if calendar_quarantined && dataset == "calendar" {
                    continue;
                }
                if let Ok(coverage) = serde_json::from_value::<RawCoverage>(value.clone()) {
                    let observed_at = optional_time(coverage.observed_at)?;
                    if let Some(envelope) = staged.iter_mut().find(|envelope| {
                        envelope.guild_key == export.guild.key
                            && envelope.kind == DatasetKind::State
                            && storage_key(envelope) == *dataset
                    }) {
                        envelope.coverage =
                            normalize_coverage(coverage.clone(), export.captured_at)?;
                    }
                    if let Some(index) = coverage_row_index(&rows, export.guild.key, dataset) {
                        rows[index].status = coverage.status;
                        rows[index].observed_at = observed_at;
                        rows[index].reason = coverage.reason;
                    } else {
                        rows.push(CoverageRow {
                            guild_key: export.guild.key,
                            dataset: dataset.clone(),
                            subject_id: export.guild.key.as_str().into(),
                            status: coverage.status,
                            observed_at,
                            reason: coverage.reason,
                        });
                    }
                }
            }
            for envelope in staged.iter_mut().filter(|envelope| {
                envelope.guild_key == export.guild.key && envelope.kind == DatasetKind::State
            }) {
                if let Some(Value::Object(health)) = export.collector_health.get(&envelope.dataset)
                {
                    envelope
                        .coverage
                        .metadata
                        .get_or_insert_with(serde_json::Map::new)
                        .insert("collectorHealth".into(), Value::Object(health.clone()));
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
        || !registry::is_legacy_installation_id(&export.installation_id)
        || export.sequence == 0
        || export.sequence > registry::MAX_SAFE_SEQUENCE
    {
        return Err(IngestError::DatasetMismatch);
    }
    guild::validate_raw_map_key(map_key, &export.guild)?;
    validate_source_character(&export.source_character)?;
    required_time(export.captured_at)?;
    if let Some(persisted_at) = export.persisted_at {
        required_time(persisted_at)?;
    }
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
    {
        return Err(IngestError::DatasetMismatch);
    }
    if !registry::is_bounded_state_name(&dataset.dataset)
        || dataset.sequence == 0
        || dataset.sequence > export.sequence
    {
        return Err(IngestError::DatasetMismatch);
    }
    validate_source_character(&dataset.source_character)?;
    guild::validate_raw_map_key(map_key, &dataset.guild)?;
    let expected_key = if dataset.scope == "guild" || dataset.scope == "account" {
        dataset.dataset.clone()
    } else {
        format!("{}:{}", dataset.dataset, dataset.subject_id)
    };
    if dataset_key != expected_key {
        return Err(IngestError::DatasetMismatch);
    }
    if let Some(expected_scope) = registry::registered_state_scope(&dataset.dataset) {
        if dataset.scope != expected_scope
            || !subject_matches_scope(
                &dataset.scope,
                &dataset.subject_id,
                dataset.guild_key,
                &dataset.source_character.id,
            )
        {
            return Err(IngestError::DatasetMismatch);
        }
    } else if !valid_scope(&dataset.scope)
        || !subject_matches_scope(
            &dataset.scope,
            &dataset.subject_id,
            dataset.guild_key,
            &dataset.source_character.id,
        )
    {
        return Err(IngestError::DatasetMismatch);
    }
    required_time(dataset.captured_at)?;
    if dataset.dataset == "calendar" && !valid_guild_calendar_payload(&dataset.payload) {
        return Err(IngestError::CalendarPrivacy);
    }
    Ok(())
}

fn validate_event(export: &RawGuildExport, event: &RawAddonEvent) -> Result<(), IngestError> {
    if event.guild_key != export.guild.key
        || event.sequence == 0
        || event.sequence > export.sequence
    {
        return Err(IngestError::DatasetMismatch);
    }
    validate_source_character(&event.source_character)?;
    required_time(event.captured_at)?;
    Ok(())
}

fn validate_source_character(source: &RawSourceCharacter) -> Result<(), IngestError> {
    if !registry::is_player_guid(&source.id)
        || source.name.is_empty()
        || source.name.chars().count() > 64
        || source.realm.is_empty()
        || source.realm.chars().count() > 128
        || source.rank_index > 9
    {
        return Err(IngestError::DatasetMismatch);
    }
    Ok(())
}

fn valid_guild_calendar_event(value: &Value, opened: bool) -> bool {
    let Some(record) = value.as_object() else {
        return false;
    };
    let allowed = if opened {
        ["info", "invites", "observedAt", "privacyClass"].as_slice()
    } else {
        ["monthOffset", "day", "index", "info", "privacyClass"].as_slice()
    };
    if record.len() != allowed.len() || record.keys().any(|key| !allowed.contains(&key.as_str())) {
        return false;
    }
    if record.get("privacyClass").and_then(Value::as_str) != Some("guild") {
        return false;
    }
    let Some(info) = record.get("info").and_then(Value::as_object) else {
        return false;
    };
    if !matches!(
        info.get("calendarType").and_then(Value::as_str),
        Some("GUILD_EVENT" | "GUILD_ANNOUNCEMENT")
    ) {
        return false;
    }
    if opened {
        return record
            .get("invites")
            .and_then(Value::as_array)
            .is_some_and(|invites| invites.len() <= 100)
            && record
                .get("observedAt")
                .and_then(Value::as_f64)
                .is_some_and(|value| value.is_finite() && value >= 0.0);
    }
    record
        .get("monthOffset")
        .and_then(Value::as_i64)
        .is_some_and(|value| (-24..=24).contains(&value))
        && record
            .get("day")
            .and_then(Value::as_u64)
            .is_some_and(|value| (1..=31).contains(&value))
        && record
            .get("index")
            .and_then(Value::as_u64)
            .is_some_and(|value| (1..=100).contains(&value))
}

fn valid_calendar_month(value: &Value) -> bool {
    let Some(month) = value.as_object() else {
        return false;
    };
    if month
        .keys()
        .any(|key| !matches!(key.as_str(), "month" | "year" | "numDays" | "firstWeekday"))
    {
        return false;
    }
    month
        .get("month")
        .and_then(Value::as_u64)
        .is_some_and(|value| (1..=12).contains(&value))
        && month
            .get("year")
            .and_then(Value::as_u64)
            .is_some_and(|value| (2_000..=2_200).contains(&value))
        && match month.get("numDays") {
            None => true,
            Some(value) => value
                .as_u64()
                .is_some_and(|value| (28..=31).contains(&value)),
        }
        && match month.get("firstWeekday") {
            None => true,
            Some(value) => value.as_u64().is_some_and(|value| (1..=7).contains(&value)),
        }
}

fn valid_calendar_initialization(initialization: &serde_json::Map<String, Value>) -> bool {
    initialization
        .iter()
        .all(|(key, value)| match key.as_str() {
            "status" => value
                .as_str()
                .is_some_and(|value| value.chars().count() <= 40),
            "observedAt" | "readyAt" => value
                .as_f64()
                .is_some_and(|value| value.is_finite() && value >= 0.0),
            "openSupported" | "openRequested" | "retainedLastGood" | "interactionRequired" => {
                value.is_boolean()
            }
            "lastGoodCapturedAt" => {
                value
                    .as_f64()
                    .is_some_and(|value| value.is_finite() && value >= 0.0)
                    || value
                        .as_str()
                        .is_some_and(|value| value.chars().count() <= 64)
            }
            _ => false,
        })
}

fn valid_guild_calendar_payload(value: &Value) -> bool {
    let Some(payload) = value.as_object() else {
        return false;
    };
    if payload.keys().any(|key| {
        !matches!(
            key.as_str(),
            "months"
                | "events"
                | "guildEvents"
                | "lastOpenedEvent"
                | "openedEventDetails"
                | "initialization"
        )
    }) {
        return false;
    }
    let (Some(months), Some(events), Some(guild_events), Some(opened), Some(initialization)) = (
        payload.get("months").and_then(Value::as_array),
        payload.get("events").and_then(Value::as_array),
        payload.get("guildEvents").and_then(Value::as_array),
        payload.get("openedEventDetails").and_then(Value::as_object),
        payload.get("initialization").and_then(Value::as_object),
    ) else {
        return false;
    };
    if months.len() > 24
        || !months.iter().all(valid_calendar_month)
        || events.len() > 1_400
        || guild_events.len() > 1_400
        || events != guild_events
        || !events
            .iter()
            .all(|event| valid_guild_calendar_event(event, false))
        || opened.len() > 200
        || !opened
            .values()
            .all(|event| valid_guild_calendar_event(event, true))
        || !valid_calendar_initialization(initialization)
    {
        return false;
    }
    match payload.get("lastOpenedEvent") {
        None => true,
        Some(event) => event.is_null() || valid_guild_calendar_event(event, true),
    }
}

fn normalize_dataset(
    raw: RawDatasetEnvelope,
    kind: DatasetKind,
    persisted_at: i64,
) -> Result<UploadEnvelope, IngestError> {
    let payload_hash = canonical::sha256_hex(&raw.payload);
    let coverage = normalize_coverage(raw.coverage, raw.captured_at)?;
    let permission_evidence = normalize_permission(
        raw.permission_evidence,
        &raw.source_character,
        coverage.observed_at,
    );
    let installation_id = registry::normalize_installation_id(&raw.installation_id)
        .ok_or(IngestError::DatasetMismatch)?;
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
        installation_id,
        export_sequence: raw.sequence,
        event_range: None,
        captured_at: required_time(raw.captured_at)?,
        persisted_at: required_unix_time(persisted_at)?,
        coverage,
        permission_evidence,
        payload_hash,
        payload: raw.payload,
    })
}

fn normalize_event_batch(
    stream: &str,
    export: &RawGuildExport,
    events: Vec<RawAddonEvent>,
    coverage: Option<RawCoverage>,
) -> Result<UploadEnvelope, IngestError> {
    let first = events.first().ok_or(IngestError::DatasetMismatch)?;
    let last = events.last().ok_or(IngestError::DatasetMismatch)?;
    let first_sequence = first.sequence;
    let last_sequence = last.sequence;
    let captured_at = required_time(last.captured_at)?;
    let source_id = first.source_character.id.clone();
    let payload = serde_json::json!({
        "events": events.iter().map(|event| serde_json::json!({
            "sequence": event.sequence,
            "capturedAt": event.captured_at,
            "payload": event.payload,
        })).collect::<Vec<_>>()
    });
    let payload_hash = canonical::sha256_hex(&payload);
    let normalized_coverage = match coverage {
        Some(value) => normalize_coverage(value, last.captured_at)?,
        None => Coverage {
            status: CoverageStatus::Partial,
            reason_code: Some("event_stream".into()),
            observed_at: captured_at,
            metadata: None,
        },
    };
    let permission_evidence = normalize_permission(
        Value::Null,
        &first.source_character,
        normalized_coverage.observed_at,
    );
    Ok(UploadEnvelope {
        schema_version: 1,
        protocol_version: "1.0".into(),
        dataset: format!("events.{stream}"),
        kind: DatasetKind::Events,
        scope: "guild".into(),
        subject_id: crate::models::event_subject_id(
            &registry::normalize_installation_id(&export.installation_id)
                .ok_or(IngestError::DatasetMismatch)?,
            &source_id,
            first_sequence,
        ),
        guild_key: first.guild_key,
        guild: export.guild.normalized(),
        source_character: normalize_source(first.source_character.clone()),
        installation_id: registry::normalize_installation_id(&export.installation_id)
            .ok_or(IngestError::DatasetMismatch)?,
        export_sequence: last_sequence,
        event_range: Some(EventRange {
            first_sequence,
            last_sequence,
        }),
        captured_at,
        persisted_at: required_unix_time(export.persisted_at.unwrap_or(export.captured_at))?,
        coverage: normalized_coverage,
        permission_evidence,
        payload_hash,
        payload,
    })
}

fn contiguous_event_batches(events: Vec<RawAddonEvent>) -> Vec<Vec<RawAddonEvent>> {
    const MAX_EVENTS_PER_BATCH: usize = 250;
    let mut batches: Vec<Vec<RawAddonEvent>> = Vec::new();
    for event in events {
        let append = batches
            .last()
            .and_then(|batch| batch.last())
            .is_some_and(|previous| {
                batch_len_under_limit(batches.last(), MAX_EVENTS_PER_BATCH)
                    && event.source_character.id == previous.source_character.id
                    && event.sequence == previous.sequence.saturating_add(1)
            });
        if append {
            batches.last_mut().expect("batch exists").push(event);
        } else {
            batches.push(vec![event]);
        }
    }
    batches
}

fn batch_len_under_limit<T>(batch: Option<&Vec<T>>, limit: usize) -> bool {
    batch.is_some_and(|value| value.len() < limit)
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

fn storage_key(envelope: &UploadEnvelope) -> String {
    if envelope.scope == "guild" || envelope.scope == "account" {
        envelope.dataset.clone()
    } else {
        format!("{}:{}", envelope.dataset, envelope.subject_id)
    }
}

fn coverage_row_index(
    rows: &[CoverageRow],
    guild_key: GuildKey,
    storage_key: &str,
) -> Option<usize> {
    rows.iter().position(|row| {
        if row.guild_key != guild_key {
            return false;
        }
        let row_storage_key =
            if row.subject_id == row.guild_key.as_str() || row.subject_id == "account" {
                row.dataset.clone()
            } else {
                format!("{}:{}", row.dataset, row.subject_id)
            };
        row_storage_key == storage_key
    })
}

fn normalize_source(raw: RawSourceCharacter) -> SourceCharacter {
    SourceCharacter {
        guid: raw.id,
        name: raw.name,
        realm_slug: realm_slug(&raw.realm),
        realm: raw.realm,
    }
}

fn valid_scope(scope: &str) -> bool {
    matches!(
        scope,
        "guild" | "character" | "account" | "house" | "neighborhood" | "session"
    )
}

fn subject_matches_scope(
    scope: &str,
    subject_id: &str,
    guild_key: GuildKey,
    source_guid: &str,
) -> bool {
    match scope {
        "guild" => subject_id == guild_key.as_str(),
        "account" => subject_id == "account",
        "character" => subject_id == source_guid,
        "house" | "neighborhood" | "session" => !subject_id.is_empty() && subject_id.len() <= 256,
        _ => false,
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
    if value <= 0 {
        return Err(IngestError::InvalidTime);
    }
    DateTime::from_timestamp(value, 0).ok_or(IngestError::InvalidTime)
}
fn required_unix_time(value: i64) -> Result<i64, IngestError> {
    required_time(value)?;
    Ok(value)
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
            r#"EmberSyncDB={{schemaVersion=1,installationId="es-install-1",createdAt=1750000000,updatedAt=1750000001,exports={{main={{schemaVersion=1,guild={{key="main",name="Raining Embers",realm="{realm}",region={region}}},installationId="es-install-1",sequence=2,capturedAt=1750000001,sourceCharacter={{id="Player-1-ABCDEF01",name="Aria",realm="Dalaran",rankIndex=0}},datasets={{guild={{schemaVersion=1,dataset="guild",scope="guild",subjectId="main",guildKey="main",guild={{key="main",name="Raining Embers",realm="{realm}",region={region}}},sourceCharacter={{id="Player-1-ABCDEF01",name="Aria",realm="Dalaran",rankIndex=0}},installationId="es-install-1",sequence=1,capturedAt=1750000000,coverage={{status="complete",observedAt=1750000000}},permissionEvidence={{rankIndex=0}},payload={{motd="Welcome"}}}}}},events={{guild_chat={{{{sequence=2,capturedAt=1750000001,guildKey="main",sourceCharacter={{id="Player-1-ABCDEF01",name="Aria",realm="Dalaran",rankIndex=0}},payload={{message="hello"}}}}}}}},coverage={{guild={{status="complete",observedAt=1750000000}},["events.guild_chat"]={{status="partial",observedAt=1750000001}}}}}}}}}}"#
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
        let event = queue
            .next_ready(16)
            .unwrap()
            .into_iter()
            .find(|upload| upload.envelope.dataset == "events.guild_chat")
            .unwrap()
            .envelope;
        assert_eq!(
            event.subject_id,
            format!(
                "{}:Player-1-ABCDEF01:2",
                registry::normalize_installation_id("es-install-1").unwrap()
            )
        );
        assert_eq!(
            event.event_range,
            Some(EventRange {
                first_sequence: 2,
                last_sequence: 2,
            })
        );
        assert_eq!(event.persisted_at, 1_750_000_001);
        assert_eq!(event.payload["events"][0]["payload"]["message"], "hello");
    }

    #[test]
    fn export_persisted_at_is_carried_to_every_upload_envelope() {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let source = fixture("Dalaran", 1).replace(
            "sequence=2,capturedAt=1750000001,sourceCharacter",
            "sequence=2,capturedAt=1750000001,persistedAt=1750000005,sourceCharacter",
        );
        Ingestor::new(queue.clone())
            .ingest_bytes(Path::new("EmberSync.lua"), source.as_bytes(), false)
            .unwrap();
        let uploads = queue.next_ready(16).unwrap();
        assert_eq!(uploads.len(), 2);
        assert!(uploads
            .iter()
            .all(|upload| upload.envelope.persisted_at == 1_750_000_005));
        assert!(uploads.iter().all(|upload| upload.queued_at > 0));
    }

    #[test]
    fn outer_coverage_change_requeues_last_good_payload_without_erasing_it() {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let source = fixture("Dalaran", 1).replace(
            r#"coverage={guild={status="complete",observedAt=1750000000}"#,
            r#"coverage={guild={status="interaction_required",observedAt=1750000001,reason="open_guild_roster"}"#,
        );
        Ingestor::new(queue.clone())
            .ingest_bytes(Path::new("EmberSync.lua"), source.as_bytes(), false)
            .unwrap();
        let guild = queue
            .next_ready(16)
            .unwrap()
            .into_iter()
            .find(|upload| upload.envelope.dataset == "guild")
            .unwrap()
            .envelope;
        assert_eq!(guild.payload["motd"], "Welcome");
        assert!(matches!(
            guild.coverage.status,
            CoverageStatus::InteractionRequired
        ));
        assert_eq!(
            guild.coverage.reason_code.as_deref(),
            Some("open_guild_roster")
        );
    }

    #[test]
    fn collector_health_is_carried_with_dataset_coverage() {
        let lua = fixture("Dalaran", 1).replace(
            r#"coverage={guild={status="complete",observedAt=1750000000}"#,
            r#"collectorHealth={guild={lastAttemptAt=1750000001,lastSuccessAt=1750000001,consecutiveFailures=0,state="succeeded"}},coverage={guild={status="complete",observedAt=1750000000}"#,
        );
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let result = Ingestor::new(queue.clone())
            .ingest_bytes(Path::new("EmberSync.lua"), lua.as_bytes(), false)
            .unwrap();

        assert!(result.queued > 0);
        let guild = queue
            .next_ready(50)
            .unwrap()
            .into_iter()
            .find(|item| item.envelope.dataset == "guild")
            .expect("guild envelope");
        let health = guild
            .envelope
            .coverage
            .metadata
            .as_ref()
            .and_then(|metadata| metadata.get("collectorHealth"))
            .and_then(Value::as_object)
            .expect("collector health metadata");
        assert_eq!(
            health.get("state").and_then(Value::as_str),
            Some("succeeded")
        );
        assert_eq!(
            health.get("consecutiveFailures").and_then(Value::as_u64),
            Some(0)
        );
    }

    #[test]
    fn contiguous_events_batch_by_source_and_sequence() {
        let source = RawSourceCharacter {
            id: "Player-1-ABCDEF01".into(),
            name: "Ember".into(),
            realm: "Dalaran".into(),
            rank_index: 1,
        };
        let make = |sequence| RawAddonEvent {
            sequence,
            captured_at: 1_750_000_000 + sequence as i64,
            guild_key: GuildKey::Main,
            source_character: source.clone(),
            payload: serde_json::json!({"sequence": sequence}),
        };
        let batches = contiguous_event_batches(vec![make(1), make(2), make(4)]);
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].len(), 2);
        assert_eq!(batches[1][0].sequence, 4);
    }

    #[test]
    fn a_periodic_rescan_does_not_requeue_acknowledged_state_or_events() {
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let ingestor = Ingestor::new(queue.clone());
        let source = fixture("Dalaran", 1);

        let first = ingestor
            .ingest_bytes(Path::new("EmberSync.lua"), source.as_bytes(), false)
            .unwrap();
        assert_eq!(first.queued, 2);
        let uploads = queue.next_ready(16).unwrap();
        assert_eq!(uploads.len(), 2);
        for upload in uploads {
            queue
                .mark_complete(upload.id, &upload.content_hash)
                .unwrap();
        }

        let second = ingestor
            .ingest_bytes(Path::new("EmberSync.lua"), source.as_bytes(), false)
            .unwrap();
        assert_eq!(second.queued, 0);
        assert_eq!(queue.summary().unwrap().pending, 0);
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
        assert_eq!(result.guilds.len(), 2);
        for dataset in [
            "guild",
            "guild_bank",
            "calendar",
            "housing",
            "events.guild_chat",
        ] {
            assert!(
                result.coverage.iter().any(|row| row.dataset == dataset),
                "missing golden-fixture coverage for {dataset}"
            );
        }
        assert!(result.queued >= 25);
    }

    #[test]
    fn quarantined_calendar_is_visible_without_blocking_safe_datasets() {
        let source = String::from_utf8_lossy(include_bytes!(
            "../../../tests/addon/fixtures/EmberSync.lua"
        ))
        .replacen(
            "[\"calendarType\"] = \"GUILD_EVENT\"",
            "[\"calendarType\"] = \"PLAYER\"",
            1,
        );
        let path = tempdir().unwrap().keep().join("queue.db");
        let queue = QueueStore::open(&path).unwrap();
        queue
            .unlock_with_passphrase("a secure test passphrase")
            .unwrap();
        let result = Ingestor::new(queue)
            .ingest_bytes(Path::new("EmberSync.lua"), source.as_bytes(), false)
            .unwrap();
        assert!(result.queued > 0);
        let calendar = result
            .coverage
            .iter()
            .find(|row| row.dataset == "calendar")
            .expect("calendar quarantine must be visible");
        assert!(matches!(calendar.status, CoverageStatus::Forbidden));
        assert_eq!(
            calendar.reason.as_deref(),
            Some("calendar_privacy_quarantined")
        );
    }

    #[test]
    fn calendar_payload_validation_quarantines_personal_and_legacy_shapes() {
        let guild_event = serde_json::json!({
            "monthOffset": 0,
            "day": 23,
            "index": 1,
            "privacyClass": "guild",
            "info": {
                "calendarType": "GUILD_EVENT",
                "title": "Guild event"
            }
        });
        let safe = serde_json::json!({
            "months": [{"month": 7, "year": 2026, "numDays": 31}],
            "events": [guild_event.clone()],
            "guildEvents": [guild_event.clone()],
            "openedEventDetails": {},
            "initialization": {"openSupported": true, "openRequested": true}
        });
        assert!(valid_guild_calendar_payload(&safe));
        let mut personal_root = safe.clone();
        personal_root["personalEvents"] = serde_json::json!([{
            "privacyClass": "personal",
            "info": {"calendarType": "PLAYER", "title": "Private invitation"}
        }]);
        assert!(!valid_guild_calendar_payload(&personal_root));
        let mut mislabeled = safe.clone();
        mislabeled["events"][0]["info"]["calendarType"] = serde_json::json!("PLAYER");
        assert!(!valid_guild_calendar_payload(&mislabeled));
        let mut extra_record_key = safe.clone();
        extra_record_key["events"][0]["private"] = serde_json::json!(true);
        extra_record_key["guildEvents"] = extra_record_key["events"].clone();
        assert!(!valid_guild_calendar_payload(&extra_record_key));
        let mut invalid_month = safe.clone();
        invalid_month["months"][0]["month"] = serde_json::json!(13);
        assert!(!valid_guild_calendar_payload(&invalid_month));
        let mut invalid_initialization = safe.clone();
        invalid_initialization["initialization"]["openSupported"] = serde_json::json!("yes");
        assert!(!valid_guild_calendar_payload(&invalid_initialization));
        let mut excessive_invites = safe.clone();
        excessive_invites["lastOpenedEvent"] = serde_json::json!({
            "info": {"calendarType": "GUILD_EVENT", "title": "Guild event"},
            "invites": (0..101).collect::<Vec<_>>(),
            "observedAt": 1,
            "privacyClass": "guild"
        });
        assert!(!valid_guild_calendar_payload(&excessive_invites));
        assert!(!valid_guild_calendar_payload(&serde_json::json!({
            "months": [],
            "events": []
        })));
    }

    #[test]
    fn character_coverage_storage_keys_do_not_create_duplicate_rows() {
        let rows = vec![
            CoverageRow {
                guild_key: GuildKey::Main,
                dataset: "auction_house".into(),
                subject_id: "Player-60-0EBBE212".into(),
                status: CoverageStatus::InteractionRequired,
                observed_at: None,
                reason: Some("open_auction_house".into()),
            },
            CoverageRow {
                guild_key: GuildKey::Main,
                dataset: "events.guild_chat".into(),
                subject_id: "es-install-1:Player-60-0EBBE212:12".into(),
                status: CoverageStatus::Partial,
                observed_at: None,
                reason: Some("event_stream".into()),
            },
        ];

        assert_eq!(
            coverage_row_index(&rows, GuildKey::Main, "auction_house:Player-60-0EBBE212"),
            Some(0)
        );
        assert_eq!(
            coverage_row_index(&rows, GuildKey::Main, "events.guild_chat"),
            None
        );
    }

    #[test]
    fn retained_datasets_and_events_keep_their_own_eligible_source_character() {
        let guild = RawGuildIdentity {
            key: GuildKey::Main,
            name: "Raining Embers".into(),
            realm: "Dalaran".into(),
            region: 1,
        };
        let latest_source = RawSourceCharacter {
            id: "Player-1-AAAABBBB".into(),
            name: "Latest".into(),
            realm: "Dalaran".into(),
            rank_index: 5,
        };
        let retained_source = RawSourceCharacter {
            id: "Player-2-CCCCDDDD".into(),
            name: "Retained".into(),
            realm: "Stormrage".into(),
            rank_index: 6,
        };
        let export = RawGuildExport {
            schema_version: 1,
            guild: guild.clone(),
            source_character: latest_source,
            installation_id: "es-install-1".into(),
            sequence: 9,
            captured_at: 1_750_000_009,
            persisted_at: None,
            datasets: serde_json::Map::new(),
            events: serde_json::Map::new(),
            coverage: serde_json::Map::new(),
            collector_health: serde_json::Map::new(),
        };
        let dataset = RawDatasetEnvelope {
            schema_version: 1,
            dataset: "character".into(),
            scope: "character".into(),
            subject_id: retained_source.id.clone(),
            guild_key: GuildKey::Main,
            guild,
            source_character: retained_source.clone(),
            installation_id: "es-install-1".into(),
            sequence: 8,
            captured_at: 1_750_000_008,
            coverage: RawCoverage {
                status: CoverageStatus::Complete,
                reason: None,
                observed_at: Some(1_750_000_008),
                metadata: serde_json::Map::new(),
            },
            permission_evidence: Value::Null,
            payload: serde_json::json!({"level": 90}),
        };
        assert!(validate_dataset("main", "character:Player-2-CCCCDDDD", &export, &dataset).is_ok());
        let mut future_sequence = dataset.clone();
        future_sequence.sequence = export.sequence + 1;
        assert!(validate_dataset(
            "main",
            "character:Player-2-CCCCDDDD",
            &export,
            &future_sequence
        )
        .is_err());
        let mut raw_future = dataset.clone();
        raw_future.dataset = "future_metric".into();
        raw_future.subject_id = "another-character".into();
        assert!(validate_dataset(
            "main",
            "future_metric:another-character",
            &export,
            &raw_future
        )
        .is_err());

        let event = RawAddonEvent {
            sequence: 7,
            captured_at: 1_750_000_007,
            guild_key: GuildKey::Main,
            source_character: retained_source,
            payload: serde_json::json!({"message": "hello"}),
        };
        assert!(validate_event(&export, &event).is_ok());
        assert!(validate_event(
            &export,
            &RawAddonEvent {
                sequence: export.sequence + 1,
                ..event
            }
        )
        .is_err());
    }
}
