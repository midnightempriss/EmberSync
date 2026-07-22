local _, EmberSync = ...

local Constants = {
    SCHEMA_VERSION = 1,
    INTERFACE_VERSION = 120007,
    REGION_US = 1,
    WEBSITE_URL = "https://rainingembers.org",
    NONMEMBER_MESSAGE = "EmberSync is exclusively for members of Raining Embers and Raining Embers Alts. This character is not a member of an approved Raining Embers guild, so EmberSync serves no purpose for this character.",
    VERIFYING_MESSAGE = "Checking Raining Embers guild membership...",
    UNVERIFIED_MESSAGE = "Membership could not be verified. EmberSync will not collect or save data.",
    MAX_EVENT_AGE_SECONDS = 90 * 24 * 60 * 60,
    MAX_EVENTS_PER_STREAM = 10000,
    SOFT_DATABASE_BYTES = 50 * 1024 * 1024,
    MAX_SANITIZE_DEPTH = 8,
    MAX_SANITIZE_ENTRIES = 20000,
    MAX_DATASET_ESTIMATED_BYTES = 2 * 1024 * 1024,
    COVERAGE = {
        COMPLETE = "complete",
        PARTIAL = "partial",
        FORBIDDEN = "forbidden",
        INTERACTION_REQUIRED = "interaction_required",
        UNAVAILABLE = "unavailable",
        UNSUPPORTED = "unsupported",
    },
    GUILDS = {
        main = {
            key = "main",
            name = "Raining Embers",
            normalizedName = "raining embers",
            realm = "Dalaran",
            normalizedRealm = "dalaran",
            region = 1,
            slug = "raining-embers",
        },
        alt = {
            key = "alt",
            name = "Raining Embers Alts",
            normalizedName = "raining embers alts",
            realm = "Wyrmrest Accord",
            normalizedRealm = "wyrmrestaccord",
            region = 1,
            slug = "raining-embers-alts",
        },
    },
}

EmberSync:RegisterModule("Constants", Constants)
