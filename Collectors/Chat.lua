local _, EmberSync = ...

local Database = EmberSync.Database
local Util = EmberSync.Util

local Chat = {
    name = "guild_chat",
    scope = "guild",
    events = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER" },
}

function Chat:HandleEvent(context, event, ...)
    local message, sender, language, channelName, target, flags, zoneChannelID,
        channelIndex, channelBaseName, _, lineID, senderGUID = ...
    local stream = event == "CHAT_MSG_OFFICER" and "officer_chat" or "guild_chat"
    Database:AppendEvent(stream, {
        type = event == "CHAT_MSG_OFFICER" and "officer" or "guild",
        message = message,
        sender = sender,
        senderGUID = senderGUID,
        language = language,
        channelName = channelName,
        target = target,
        flags = flags,
        zoneChannelID = zoneChannelID,
        channelIndex = channelIndex,
        channelBaseName = channelBaseName,
        lineID = lineID,
        sourceGuildKey = context.guild.key,
        observedAt = Util.Now(),
    })
end

EmberSync.CollectorManager:Register(Chat)
