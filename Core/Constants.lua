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
    COLLECTOR_HEARTBEAT_SECONDS = 15 * 60,
    DATABASE_SIZE_CHECK_SEQUENCE_INTERVAL = 50,
    COOPERATIVE_WORK_INTERVAL = 200,
    INSTALLATION_ID_LENGTH = 16,
    INSTALLATION_ID_FORMAT_VERSION = 2,
    HOUSING_DISCOVERY_COOLDOWN_SECONDS = 60,
    HOUSING_NEIGHBORHOOD_CATALOG_VERSION = 1,
    WORLD_QUEST_MAP_LIMIT = 64,
    WORLD_QUESTS_PER_MAP_LIMIT = 200,
    WORLD_QUEST_MAP_CATALOG_VERSION = 1,
    -- Retail 12.0.7 Midnight map catalog. Keeping this versioned and explicit
    -- lets a character collect the current expansion's visible world quests
    -- even while they are idling in an older continent.
    WORLD_QUEST_CURRENT_EXPANSION = {
        key = "midnight",
        rootMapID = 2537, -- Quel'Thalas
        mapIDs = {
            2393, -- Silvermoon City
            2395, -- Eversong Woods
            2405, -- Voidstorm
            2413, -- Harandar
            2424, -- Isle of Quel'Danas
            2437, -- Zul'Aman
        },
    },
    COVERAGE = {
        COMPLETE = "complete",
        PARTIAL = "partial",
        FORBIDDEN = "forbidden",
        INTERACTION_REQUIRED = "interaction_required",
        UNAVAILABLE = "unavailable",
        UNSUPPORTED = "unsupported",
    },
    -- This is the addon-side source of truth for names put into the
    -- SavedVariables wire format. Protocol, desktop, and site tests mirror this
    -- registry so contract drift fails a build instead of silently dropping a
    -- collector.
    STATE_DATASETS = {
        auction_house = true,
        calendar = true,
        character = true,
        collections = true,
        crafting = true,
        damage_meter = true,
        guild = true,
        guild_bank = true,
        housing = true,
        inventory = true,
        mail_metadata = true,
        mythic_plus = true,
        professions = true,
        progression = true,
        pvp = true,
        world_quests = true,
    },
    EVENT_STREAMS = {
        ["events.guild_chat"] = true,
        ["events.officer_chat"] = true,
        ["events.guild"] = true,
        ["events.guild_bank"] = true,
        ["events.guild_presence"] = true,
        ["events.neighborhood_initiative"] = true,
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
