EmberSyncDB = {
    ["schemaVersion"] = 1,
    ["installationId"] = "es-123456789-987654321",
    ["createdAt"] = 1784721600,
    ["updatedAt"] = 1784721660,
    ["meta"] = {
        ["addon"] = "EmberSync",
        ["addonVersion"] = "0.1.0",
        ["interfaceVersion"] = 120007,
    },
    ["settings"] = {
        ["categories"] = {},
        ["minimap"] = { ["angle"] = 225, ["hidden"] = false },
        ["privacy"] = { ["collectAllPermitted"] = true },
    },
    ["exports"] = {
        ["main"] = {
            ["schemaVersion"] = 1,
            ["guild"] = {
                ["key"] = "main",
                ["name"] = "Raining Embers",
                ["realm"] = "Dalaran",
                ["region"] = 1,
            },
            ["installationId"] = "es-123456789-987654321",
            ["sequence"] = 2,
            ["capturedAt"] = 1784721660,
            ["sourceCharacter"] = {
                ["id"] = "Player-3676-00000001",
                ["name"] = "Embertest",
                ["realm"] = "Dalaran",
                ["rankIndex"] = 4,
            },
            ["datasets"] = {
                ["guild"] = {
                    ["schemaVersion"] = 1,
                    ["dataset"] = "guild",
                    ["scope"] = "guild",
                    ["subjectId"] = "main",
                    ["guildKey"] = "main",
                    ["guild"] = {
                        ["key"] = "main",
                        ["name"] = "Raining Embers",
                        ["realm"] = "Dalaran",
                        ["region"] = 1,
                    },
                    ["sourceCharacter"] = {
                        ["id"] = "Player-3676-00000001",
                        ["name"] = "Embertest",
                        ["realm"] = "Dalaran",
                        ["rankIndex"] = 4,
                    },
                    ["installationId"] = "es-123456789-987654321",
                    ["sequence"] = 1,
                    ["capturedAt"] = 1784721600,
                    ["coverage"] = {
                        ["status"] = "complete",
                        ["observedAt"] = 1784721600,
                        ["memberCount"] = 1,
                    },
                    ["permissionEvidence"] = {
                        ["rankIndex"] = 4,
                        ["rankName"] = "Officer",
                        ["canViewOfficerNote"] = true,
                    },
                    ["payload"] = {
                        ["identity"] = {
                            ["key"] = "main",
                            ["name"] = "Raining Embers",
                            ["realm"] = "Dalaran",
                            ["region"] = 1,
                        },
                        ["roster"] = {},
                    },
                },
            },
            ["events"] = {
                ["guild_chat"] = {
                    {
                        ["sequence"] = 2,
                        ["capturedAt"] = 1784721660,
                        ["guildKey"] = "main",
                        ["sourceCharacter"] = {
                            ["id"] = "Player-3676-00000001",
                            ["name"] = "Embertest",
                            ["realm"] = "Dalaran",
                            ["rankIndex"] = 4,
                        },
                        ["payload"] = {
                            ["type"] = "guild",
                            ["message"] = "Welcome to the guild!",
                            ["sender"] = "Embertest-Dalaran",
                        },
                    },
                },
            },
            ["coverage"] = {
                ["guild"] = {
                    ["status"] = "complete",
                    ["observedAt"] = 1784721600,
                    ["memberCount"] = 1,
                },
            },
        },
    },
}
