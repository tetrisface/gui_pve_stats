local Model = {}

local function CopyTable(source)
	local copy = {}
	for key, value in pairs(source or {}) do
		copy[key] = value
	end
	return copy
end

local function AppendValue(parts, value)
	local text = tostring(value or "")
	parts[#parts + 1] = tostring(#text)
	parts[#parts + 1] = ":"
	parts[#parts + 1] = text
end

local function AppendArray(parts, values)
	parts[#parts + 1] = "["
	for _, value in ipairs(values or {}) do
		AppendValue(parts, value)
		parts[#parts + 1] = ","
	end
	parts[#parts + 1] = "]"
end

local function AppendMap(parts, values)
	local keys = {}
	for key in pairs(values or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)

	parts[#parts + 1] = "{"
	for _, key in ipairs(keys) do
		AppendValue(parts, key)
		parts[#parts + 1] = "="
		AppendValue(parts, values[key])
		parts[#parts + 1] = ";"
	end
	parts[#parts + 1] = "}"
end

local function SafeCall(object, methodName, ...)
	local method = object and object[methodName]
	if not method then
		return nil
	end

	local ok, first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh = pcall(method, ...)
	if not ok then
		return nil
	end
	return first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh
end

local function HasAiName(value, pattern)
	return string.find(string.lower(tostring(value or "")), pattern, 1, true) ~= nil
end

local function AccountIdFromInfo(...)
	for index = 1, select("#", ...) do
		local info = select(index, ...)
		if type(info) == "table" then
			local accountID = tonumber(info.accountid or info.accountID or info.account_id)
			if accountID and accountID > 0 then
				return accountID
			end
		end
	end
	return nil
end

local function AddUnique(values, seen, value)
	if value and not seen[value] then
		seen[value] = true
		values[#values + 1] = value
	end
end

function Model.DetectAiType(springApi)
	local utilities = springApi and springApi.Utilities
	local gametype = utilities and utilities.Gametype
	if gametype then
		if SafeCall(gametype, "IsRaptors") then
			return "Raptors"
		end
		if SafeCall(gametype, "IsScavengers") then
			return "Scavengers"
		end
	end

	local teamList = SafeCall(springApi, "GetTeamList") or {}
	for _, teamID in ipairs(teamList) do
		local _, _, _, name, _, options = SafeCall(springApi, "GetAIInfo", teamID)
		local haystack = table.concat({
			tostring(name or ""),
			tostring(options and options.name or ""),
			tostring(options and options.shortName or ""),
			tostring(options and options.version or ""),
			tostring(options and options.profile or ""),
		}, " ")

		if HasAiName(haystack, "scav") then
			return "Scavengers"
		end
		if HasAiName(haystack, "raptor") then
			return "Raptors"
		end
		if HasAiName(haystack, "barbarian") or HasAiName(haystack, "barb") then
			return "Barbarian"
		end
	end

	return nil
end

function Model.CollectPlayers(springApi)
	local playerNames = {}
	local playerIds = {}
	local activePlayerNames = {}
	local activePlayerIds = {}
	local spectatorNames = {}
	local spectatorIds = {}
	local seenNames = {}
	local seenIds = {}
	local playerList = SafeCall(springApi, "GetPlayerList") or {}

	for _, playerID in ipairs(playerList) do
		local name, _, spectator, _, _, _, _, _, _, customKeys, extraInfo = SafeCall(springApi, "GetPlayerInfo", playerID, false)
		if name then
			local groupNames = spectator and spectatorNames or activePlayerNames
			AddUnique(playerNames, seenNames, name)
			groupNames[#groupNames + 1] = name

			local accountID = AccountIdFromInfo(customKeys, extraInfo)
			if accountID then
				local groupIds = spectator and spectatorIds or activePlayerIds
				AddUnique(playerIds, seenIds, accountID)
				groupIds[#groupIds + 1] = accountID
			end
		end
	end

	table.sort(playerNames)
	table.sort(playerIds)
	table.sort(activePlayerNames)
	table.sort(activePlayerIds)
	table.sort(spectatorNames)
	table.sort(spectatorIds)

	return playerNames, playerIds, {
		active_player_names = activePlayerNames,
		active_player_ids = activePlayerIds,
		spectator_names = spectatorNames,
		spectator_ids = spectatorIds,
	}
end

function Model.RequestKey(request)
	if not request then
		return nil
	end

	local parts = {}
	AppendValue(parts, request.ai_type)
	parts[#parts + 1] = "|"
	AppendValue(parts, request.map)
	parts[#parts + 1] = "|"
	AppendMap(parts, request.game_settings)
	parts[#parts + 1] = "|"
	AppendArray(parts, request.player_ids)
	parts[#parts + 1] = "|"
	AppendArray(parts, request.player_names)
	parts[#parts + 1] = "|"
	AppendValue(parts, request.player_filter_requested and "1" or "0")
	return table.concat(parts)
end

function Model.WireRequest(request)
	local wire = {}
	for key, value in pairs(request or {}) do
		if not string.match(tostring(key), "^_") then
			wire[key] = value
		end
	end
	return wire
end

function Model.BuildRequest(springApi, gameApi)
	local aiType = Model.DetectAiType(springApi)
	if not aiType then
		return nil, "missing_ai_type"
	end

	local mapName = gameApi and (gameApi.mapName or gameApi.map_name)
	if not mapName or tostring(mapName) == "" then
		return nil, "missing_map"
	end

	local playerNames, playerIds, playerGroups = Model.CollectPlayers(springApi)
	local request = {
		ai_type = aiType,
		map = mapName,
		game_settings = CopyTable(SafeCall(springApi, "GetModOptions") or {}),
		player_names = playerNames,
		player_ids = playerIds,
		player_filter_requested = true,
		_active_player_names = playerGroups and playerGroups.active_player_names or {},
		_active_player_ids = playerGroups and playerGroups.active_player_ids or {},
		_spectator_names = playerGroups and playerGroups.spectator_names or {},
		_spectator_ids = playerGroups and playerGroups.spectator_ids or {},
	}
	request._request_key = Model.RequestKey(request)
	return request
end

function Model.EscapeRml(value)
	local text = tostring(value or "")
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	text = string.gsub(text, "\"", "&quot;")
	text = string.gsub(text, "'", "&#39;")
	return text
end

local function FormatNumber(value, decimals)
	local number = tonumber(value)
	if not number then
		return "-"
	end
	return string.format("%." .. tostring(decimals or 0) .. "f", number)
end

local PLAYER_COLOR_FALLBACKS = {
	"#0066FF",
	"#FFCC00",
	"#FF3333",
	"#FF00CC",
	"#9966FF",
	"#33FFCC",
	"#CC6600",
	"#FFFFFF",
	"#00CC66",
	"#00CCCC",
	"#FF9966",
	"#66FF00",
}

local function StableIndex(value, count)
	local text = tostring(value or "")
	local hash = 0
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % 2147483647
	end
	return (hash % count) + 1
end

local function PlayerColor(player, colorLookup)
	local lookup = colorLookup or {}
	local name = player and player.player_name
	local id = player and (player.player_id or player.playerId or player.account_id or player.accountId)
	local color = lookup[name] or lookup[tostring(name or "")] or lookup[id] or lookup[tostring(id or "")]
	if color and string.match(tostring(color), "^#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") then
		return tostring(color)
	end
	return PLAYER_COLOR_FALLBACKS[StableIndex(name or id or "player", #PLAYER_COLOR_FALLBACKS)]
end

local function ToSet(values)
	local set = {}
	for _, value in ipairs(values or {}) do
		set[value] = true
		set[tostring(value)] = true
	end
	return set
end

local function PlayerId(player)
	return player and (player.player_id or player.playerId or player.account_id or player.accountId)
end

local function SplitPlayers(players, request)
	local activePlayers = {}
	local spectators = {}
	local spectatorNames = ToSet(request and request._spectator_names)
	local spectatorIds = ToSet(request and request._spectator_ids)

	for _, player in ipairs(players or {}) do
		local name = player.player_name
		local id = PlayerId(player)
		if spectatorNames[name] or spectatorNames[tostring(name or "")] or spectatorIds[id] or spectatorIds[tostring(id or "")] then
			spectators[#spectators + 1] = player
		else
			activePlayers[#activePlayers + 1] = player
		end
	end

	return activePlayers, spectators
end

local function MatchLabel(response)
	local status = response and response.match_status
	if status == "exact" then
		return "Exact"
	end
	if status == "closest" then
		if response.closest_match_basis == "difficulty_factor_vector" then
			return "Closest vector"
		end
		return "Closest"
	end
	if status == "not_found" then
		return "No match"
	end
	return "-"
end

function Model.PlayerRowsRml(players, colorLookup)
	if not players or #players == 0 then
		return "<div class=\"pve-stats-empty\">No player stats</div>"
	end

	local rows = {}
	for _, player in ipairs(players) do
		local name = Model.EscapeRml(player.player_name or "Unknown")
		local color = PlayerColor(player, colorLookup)
		rows[#rows + 1] = table.concat({
			"<div class=\"pve-stats-player-row\">",
			"<div class=\"pve-stats-player-accent\" style=\"background-color: ", color, ";\"></div>",
			"<span class=\"pve-stats-player-name\">", name, "</span>",
			"<span class=\"pve-stats-player-stat\">", FormatNumber(player.exact_wins, 0), "</span>",
			"<span class=\"pve-stats-player-stat\">", FormatNumber(player.harder_wins, 0), "</span>",
			"<span class=\"pve-stats-player-rating\">", FormatNumber(player.player_rating, 1), "</span>",
			"</div>",
		})
	end
	return table.concat(rows, "\n")
end

local function PlayerGroupRml(label, players, colorLookup, emptyText)
	if not players or #players == 0 then
		return table.concat({
			"<div class=\"pve-stats-group-label\">",
			Model.EscapeRml(label),
			"</div><div class=\"pve-stats-empty\">",
			Model.EscapeRml(emptyText),
			"</div>",
		})
	end

	return table.concat({
		"<div class=\"pve-stats-group-label\">",
		Model.EscapeRml(label),
		"</div>",
		Model.PlayerRowsRml(players, colorLookup),
	})
end

function Model.EmptyViewModel()
	return {
		statusText = "Ready",
		modeText = "-",
		difficultyText = "-",
		matchText = "-",
		errorText = "",
		playersRml = "<div class=\"pve-stats-empty\">No player stats</div>",
		spectatorText = "Spec",
		hasError = false,
		hasPlayers = false,
		showSpectators = false,
	}
end

function Model.ViewModelFromResponse(response, errorMessage, request, colorLookup, options)
	options = options or {}
	local view = Model.EmptyViewModel()
	view.showSpectators = options.showSpectators == true
	view.spectatorText = view.showSpectators and "Spec" or "Spec"
	if request and request.ai_type then
		view.modeText = tostring(request.ai_type)
	end

	if errorMessage then
		view.statusText = "Unavailable"
		view.errorText = tostring(errorMessage)
		view.hasError = true
		return view
	end
	if not response then
		return view
	end

	local setting = response.setting or {}
	view.statusText = response.found and "Found" or MatchLabel(response)
	view.matchText = MatchLabel(response)
	view.difficultyText = FormatNumber(setting.difficulty_rating, 1)
	local activePlayers, spectators = SplitPlayers(response.players, request)
	if view.showSpectators then
		view.playersRml = table.concat({
			PlayerGroupRml("Players", activePlayers, colorLookup, "No player stats"),
			"\n",
			PlayerGroupRml("Spectators", spectators, colorLookup, "No spectator stats"),
		})
	else
		view.playersRml = Model.PlayerRowsRml(activePlayers, colorLookup)
	end
	view.hasPlayers = response.players and #response.players > 0 or false
	return view
end

return Model
