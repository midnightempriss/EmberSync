use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

pub const MAX_SAFE_SEQUENCE: u64 = 9_007_199_254_740_991;

pub const STATE_DATASETS: &[(&str, &str)] = &[
    ("auction_house", "character"),
    ("calendar", "guild"),
    ("character", "character"),
    ("collections", "account"),
    ("crafting", "character"),
    ("damage_meter", "character"),
    ("guild", "guild"),
    ("guild_bank", "guild"),
    ("housing", "character"),
    ("inventory", "character"),
    ("mail_metadata", "character"),
    ("mythic_plus", "character"),
    ("professions", "character"),
    ("progression", "character"),
    ("pvp", "character"),
    ("world_quests", "character"),
];

pub const EVENT_DATASETS: &[(&str, &str)] = &[
    ("events.guild_chat", "guild"),
    ("events.officer_chat", "guild"),
    ("events.guild", "guild"),
    ("events.guild_bank", "guild"),
    ("events.guild_presence", "guild"),
    ("events.neighborhood_initiative", "guild"),
];

pub fn registered_state_scope(name: &str) -> Option<&'static str> {
    STATE_DATASETS
        .iter()
        .find_map(|(candidate, scope)| (*candidate == name).then_some(*scope))
}

pub fn registered_event_scope(name: &str) -> Option<&'static str> {
    EVENT_DATASETS
        .iter()
        .find_map(|(candidate, scope)| (*candidate == name).then_some(*scope))
}

pub fn is_bounded_state_name(value: &str) -> bool {
    is_bounded_component(value)
}

pub fn is_bounded_event_stream(value: &str) -> bool {
    is_bounded_component(value)
}

pub fn is_bounded_event_dataset_name(value: &str) -> bool {
    value
        .strip_prefix("events.")
        .is_some_and(is_bounded_event_stream)
}

pub fn is_bounded_upload_name(kind: crate::models::DatasetKind, value: &str) -> bool {
    match kind {
        crate::models::DatasetKind::State => is_bounded_state_name(value),
        crate::models::DatasetKind::Events => is_bounded_event_dataset_name(value),
    }
}

pub fn is_dataset_scope(value: &str) -> bool {
    matches!(
        value,
        "guild" | "character" | "account" | "house" | "neighborhood" | "session"
    )
}

pub fn is_player_guid(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("Player-") else {
        return false;
    };
    let Some((realm, character)) = rest.split_once('-') else {
        return false;
    };
    !realm.is_empty()
        && realm.bytes().all(|byte| byte.is_ascii_digit())
        && !character.is_empty()
        && character.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn is_bounded_component(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
}

pub fn is_installation_id(value: &str) -> bool {
    value.len() == 16
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub fn is_legacy_installation_id(value: &str) -> bool {
    (8..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub fn normalize_installation_id(value: &str) -> Option<String> {
    if is_installation_id(value) {
        return Some(value.to_owned());
    }
    if !is_legacy_installation_id(value) {
        return None;
    }
    let mut bytes = [0_u8; 12];
    for (hash_index, initial) in [5_381_u32, 52_711, 1_315_423_911].into_iter().enumerate() {
        let hash = value
            .bytes()
            .enumerate()
            .fold(initial, |hash, (index, byte)| {
                hash.wrapping_mul(33)
                    .wrapping_add(u32::from(byte))
                    .wrapping_add(index as u32 + 1)
            });
        bytes[hash_index * 4..hash_index * 4 + 4].copy_from_slice(&hash.to_be_bytes());
    }
    Some(URL_SAFE_NO_PAD.encode(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        schema_version: u32,
        state: Vec<Entry>,
        events: Vec<Entry>,
    }

    #[derive(Deserialize)]
    struct Entry {
        name: String,
        scopes: Vec<String>,
    }

    #[test]
    fn rust_catalog_matches_the_protocol_fixture() {
        let fixture: Fixture = serde_json::from_str(include_str!(
            "../../../protocol/fixtures/dataset-registry-v1.json"
        ))
        .unwrap();
        assert_eq!(fixture.schema_version, 1);
        let state: Vec<_> = fixture
            .state
            .iter()
            .map(|entry| (entry.name.as_str(), entry.scopes[0].as_str()))
            .collect();
        let events: Vec<_> = fixture
            .events
            .iter()
            .map(|entry| (entry.name.as_str(), entry.scopes[0].as_str()))
            .collect();
        assert_eq!(state, STATE_DATASETS);
        assert_eq!(events, EVENT_DATASETS);
    }

    #[test]
    fn legacy_installation_normalization_matches_lua_and_typescript() {
        assert_eq!(
            normalize_installation_id("es-123456789-987654321").as_deref(),
            Some("wbnFbgsqo9A0EqyQ")
        );
        assert_eq!(
            normalize_installation_id("es-legacy-install").as_deref(),
            Some("m4T9HLOW1j5cZmb-")
        );
        assert_eq!(
            normalize_installation_id("AbCdEf0123_-xYz9").as_deref(),
            Some("AbCdEf0123_-xYz9")
        );
        assert!(normalize_installation_id("bad space").is_none());
    }

    #[test]
    fn bounded_future_upload_names_keep_state_and_events_distinct() {
        assert!(is_bounded_upload_name(
            crate::models::DatasetKind::State,
            "future_metric"
        ));
        assert!(is_bounded_upload_name(
            crate::models::DatasetKind::Events,
            "events.future_stream"
        ));
        assert!(!is_bounded_upload_name(
            crate::models::DatasetKind::State,
            "events.future_stream"
        ));
        assert!(!is_bounded_upload_name(
            crate::models::DatasetKind::Events,
            "future_stream"
        ));
        assert!(!is_bounded_event_dataset_name("events.Bad-Stream"));
        assert!(is_player_guid("Player-3683-0ABCDEF0"));
        assert!(!is_player_guid("Player-3683-secret-value"));
    }
}
