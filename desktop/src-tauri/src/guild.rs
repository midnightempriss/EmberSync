use crate::models::{GuildIdentity, GuildKey, RawGuildIdentity};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;

pub const WEBSITE_URL: &str = "https://rainingembers.org";

#[derive(Debug, Clone, Copy)]
pub struct ApprovedGuild {
    pub key: GuildKey,
    pub name: &'static str,
    pub realm: &'static str,
    pub region: &'static str,
    pub slug: &'static str,
    pub realm_slug: &'static str,
}

pub const APPROVED_GUILDS: [ApprovedGuild; 2] = [
    ApprovedGuild {
        key: GuildKey::Main,
        name: "Raining Embers",
        realm: "Dalaran",
        region: "US",
        slug: "raining-embers",
        realm_slug: "dalaran",
    },
    ApprovedGuild {
        key: GuildKey::Alt,
        name: "Raining Embers Alts",
        realm: "Wyrmrest Accord",
        region: "US",
        slug: "raining-embers-alts",
        realm_slug: "wyrmrest-accord",
    },
];

#[derive(Debug, Error)]
pub enum GuildValidationError {
    #[error("unknown guild key")]
    UnknownKey,
    #[error("guild name does not match the approved {0} guild")]
    NameMismatch(&'static str),
    #[error("guild founding realm does not match the approved {0} guild")]
    RealmMismatch(&'static str),
    #[error("only US Raining Embers guild exports are accepted")]
    RegionMismatch,
}

pub fn normalize_name(value: &str) -> String {
    value
        .nfkc()
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn normalize_realm(value: &str) -> String {
    value
        .nfkc()
        .flat_map(char::to_lowercase)
        .filter(|ch| !ch.is_whitespace() && !matches!(ch, '-' | '\'' | '’'))
        .collect()
}

pub fn approved(key: GuildKey) -> &'static ApprovedGuild {
    match key {
        GuildKey::Main => &APPROVED_GUILDS[0],
        GuildKey::Alt => &APPROVED_GUILDS[1],
    }
}

pub fn canonical(key: GuildKey) -> GuildIdentity {
    let value = approved(key);
    debug_assert_eq!(value.key, key);
    GuildIdentity {
        key,
        name: value.name.into(),
        slug: value.slug.into(),
        founding_realm: value.realm.into(),
        realm_slug: value.realm_slug.into(),
        region: value.region.into(),
        profile_url: format!(
            "https://worldofwarcraft.blizzard.com/en-us/guild/us/{}/{}",
            value.realm_slug, value.slug
        ),
    }
}

pub fn validate(identity: &GuildIdentity) -> Result<&'static ApprovedGuild, GuildValidationError> {
    let expected = approved(identity.key);
    if normalize_name(&identity.name) != normalize_name(expected.name) {
        return Err(GuildValidationError::NameMismatch(expected.name));
    }
    if normalize_realm(&identity.founding_realm) != normalize_realm(expected.realm) {
        return Err(GuildValidationError::RealmMismatch(expected.name));
    }
    if !identity.region.trim().eq_ignore_ascii_case(expected.region) {
        return Err(GuildValidationError::RegionMismatch);
    }
    Ok(expected)
}

pub fn validate_raw(
    identity: &RawGuildIdentity,
) -> Result<&'static ApprovedGuild, GuildValidationError> {
    if identity.region != 1 {
        return Err(GuildValidationError::RegionMismatch);
    }
    let expected = approved(identity.key);
    if normalize_name(&identity.name) != normalize_name(expected.name) {
        return Err(GuildValidationError::NameMismatch(expected.name));
    }
    if normalize_realm(&identity.realm) != normalize_realm(expected.realm) {
        return Err(GuildValidationError::RealmMismatch(expected.name));
    }
    Ok(expected)
}

pub fn validate_raw_map_key(
    map_key: &str,
    identity: &RawGuildIdentity,
) -> Result<(), GuildValidationError> {
    let expected = match map_key {
        "main" => GuildKey::Main,
        "alt" => GuildKey::Alt,
        _ => return Err(GuildValidationError::UnknownKey),
    };
    if identity.key != expected {
        return Err(GuildValidationError::UnknownKey);
    }
    validate_raw(identity)?;
    Ok(())
}

#[cfg(test)]
pub fn validate_map_key(
    map_key: &str,
    identity: &GuildIdentity,
) -> Result<(), GuildValidationError> {
    let expected = match map_key {
        "main" => GuildKey::Main,
        "alt" => GuildKey::Alt,
        _ => return Err(GuildValidationError::UnknownKey),
    };
    if identity.key != expected {
        return Err(GuildValidationError::UnknownKey);
    }
    validate(identity)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(key: GuildKey, name: &str, realm: &str, region: &str) -> GuildIdentity {
        let mut value = canonical(key);
        value.name = name.into();
        value.founding_realm = realm.into();
        value.region = region.into();
        value
    }

    #[test]
    fn accepts_only_the_two_exact_normalized_tuples() {
        assert!(validate(&identity(
            GuildKey::Main,
            "  RAINING   EMBERS ",
            "Dalaran",
            "us"
        ))
        .is_ok());
        assert!(validate(&identity(
            GuildKey::Alt,
            "Raining Embers Alts",
            "Wyrmrest-Accord",
            "US"
        ))
        .is_ok());
        assert!(validate(&identity(
            GuildKey::Main,
            "Raining Embers",
            "Stormrage",
            "US"
        ))
        .is_err());
        assert!(validate(&identity(GuildKey::Main, "Raining Embers", "Dalaran", "EU")).is_err());
        assert!(validate(&identity(
            GuildKey::Alt,
            "Raining Embers",
            "Wyrmrest Accord",
            "US"
        ))
        .is_err());
    }

    #[test]
    fn rejects_cross_key_claims() {
        let main = identity(GuildKey::Main, "Raining Embers", "Dalaran", "US");
        assert!(validate_map_key("alt", &main).is_err());
        assert!(validate_map_key("other", &main).is_err());
    }
}
