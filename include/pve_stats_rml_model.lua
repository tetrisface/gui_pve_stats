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

local function CollectModOptions(springApi)
	local modOptions = SafeCall(springApi, "GetModOptionsCopy")
	if modOptions then
		return CopyTable(modOptions)
	end

	return CopyTable(SafeCall(springApi, "GetModOptions") or {})
end

local function HasAiName(value, pattern)
	return string.find(string.lower(tostring(value or "")), pattern, 1, true) ~= nil
end

local function AiTypeFromFlags(isRaptors, isScavengers)
	if isRaptors == true and isScavengers ~= true then
		return "Raptors"
	end
	if isScavengers == true and isRaptors ~= true then
		return "Scavengers"
	end
	return nil
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

local function AiTypeFromText(value)
	local hasRaptors = HasAiName(value, "raptors") or HasAiName(value, "raptor")
	local hasScavengers = HasAiName(value, "scavengers") or HasAiName(value, "scavenger")
	if hasRaptors and not hasScavengers then
		return "Raptors"
	end
	if hasScavengers and not hasRaptors then
		return "Scavengers"
	end
	if hasRaptors and hasScavengers then
		return nil
	end
	if HasAiName(value, "barbarian") or HasAiName(value, "barb") then
		return "Barbarian"
	end
	return nil
end

local function AiTypeFromSeenTeams(seen)
	local hasRaptors = seen.Raptors == true
	local hasScavengers = seen.Scavengers == true
	if hasRaptors and not hasScavengers then
		return "Raptors", "team_ai_identity"
	end
	if hasScavengers and not hasRaptors then
		return "Scavengers", "team_ai_identity"
	end
	if hasRaptors or hasScavengers then
		return nil, "ambiguous_team_ai_identity"
	end
	if seen.Barbarian then
		return "Barbarian", "team_ai_identity"
	end
	return nil, nil
end

local function DetectAiTypeWithSource(springApi)
	local utilities = springApi and springApi.Utilities
	local gametype = utilities and utilities.Gametype
	if gametype then
		local aiType = AiTypeFromFlags(SafeCall(gametype, "IsRaptors"), SafeCall(gametype, "IsScavengers"))
		if aiType then
			return aiType, "spring_utilities_gametype"
		end
	end

	local teamList = SafeCall(springApi, "GetTeamList") or {}
	local hasGenericAiTeam = false
	local seen = {}
	for _, teamID in ipairs(teamList) do
		local aiId, possibleAiName, _hostingPlayerID, aiName, version = SafeCall(springApi, "GetAIInfo", teamID)
		local _, _, _, isAiTeam = SafeCall(springApi, "GetTeamInfo", teamID, false)
		local teamLuaAi = SafeCall(springApi, "GetTeamLuaAI", teamID)
		local gameRulesAiName = SafeCall(springApi, "GetGameRulesParam", "ainame_" .. tostring(teamID))
		local haystack = table.concat({
			tostring(aiId or ""),
			tostring(possibleAiName or ""),
			tostring(aiName or ""),
			tostring(version or ""),
			tostring(teamLuaAi or ""),
			tostring(gameRulesAiName or ""),
		}, " ")

		local aiType = AiTypeFromText(haystack)
		if aiType then
			seen[aiType] = true
		end
		if aiId or possibleAiName or aiName or teamLuaAi or isAiTeam == true then
			hasGenericAiTeam = true
		end
	end

	local aiType, aiTypeSource = AiTypeFromSeenTeams(seen)
	if aiType then
		return aiType, aiTypeSource
	end
	if aiTypeSource then
		return nil, aiTypeSource
	end

	if hasGenericAiTeam then
		return "Barbarian", "generic_ai_team"
	end

	return nil, "missing_ai_type"
end

function Model.DetectAiType(springApi)
	local aiType = DetectAiTypeWithSource(springApi)
	return aiType
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
	local aiType, aiTypeSource = DetectAiTypeWithSource(springApi)
	if not aiType then
		return nil, aiTypeSource or "missing_ai_type"
	end

	local mapName = gameApi and (gameApi.mapName or gameApi.map_name)
	if not mapName or tostring(mapName) == "" then
		return nil, "missing_map"
	end

	local playerNames, playerIds, playerGroups = Model.CollectPlayers(springApi)
	local request = {
		ai_type = aiType,
		map = mapName,
		game_settings = CollectModOptions(springApi),
		player_names = playerNames,
		player_ids = playerIds,
		player_filter_requested = true,
		_ai_type_source = aiTypeSource,
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

function Model.BoundedExponentialBackoffSeconds(attempt, initialSeconds, maxSeconds)
	local safeAttempt = math.max(1, tonumber(attempt) or 1)
	local safeInitial = math.max(0, tonumber(initialSeconds) or 0)
	local safeMax = math.max(safeInitial, tonumber(maxSeconds) or safeInitial)
	local delay = safeInitial * (2 ^ (safeAttempt - 1))
	return math.min(delay, safeMax)
end

local function FirstDisplayValue(...)
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		local valueType = type(value)
		if (valueType == "string" or valueType == "number" or valueType == "boolean") and tostring(value) ~= "" then
			return value
		end
	end
	return nil
end

local function MatchResultText(response, setting)
	local value = FirstDisplayValue(
		response and response.match_status,
		response and response.match_result,
		response and response.match,
		response and response.result,
		setting and setting.match_result,
		setting and setting.match,
		setting and setting.result
	)
	if value == nil then
		return "-"
	end

	local text = tostring(value)
	local normalized = string.lower(text)
	if normalized == "exact" then
		return "Exact"
	end
	if normalized == "closest" then
		return "Closest"
	end
	if normalized == "not_found" or normalized == "not found" then
		return "Not found"
	end
	if normalized == "win" or normalized == "won" or normalized == "victory" then
		return "Win"
	end
	if normalized == "loss" or normalized == "lost" or normalized == "defeat" then
		return "Loss"
	end
	if normalized == "draw" or normalized == "tie" then
		return "Draw"
	end
	return text
end

local function IsClosestResponse(response)
	return string.lower(tostring(response and response.match_status or "")) == "closest"
end

local function WinsLabels(response)
	if IsClosestResponse(response) then
		return "Closest Wins", "Closest Total Players", "Closest Wins"
	end
	return "Exact Wins", "Exact Total Players", "Exact Wins"
end

local function StartsWith(value, prefix)
	return string.sub(value, 1, #prefix) == prefix
end

local function HiddenDiffColumn(column)
	local lower = string.lower(tostring(column or ""))
	return lower == "" or lower == "ai_type" or StartsWith(lower, "tweakdefs") or StartsWith(lower, "tweakunits")
end

local function DiffValueText(value)
	local valueType = type(value)
	if value == nil then
		return "-"
	end
	if valueType == "boolean" then
		return value and "true" or "false"
	end
	if valueType == "number" or valueType == "string" then
		local text = tostring(value)
		if text == "" then
			return "-"
		end
		return text
	end
	return "<complex>"
end

local function SameDiffValue(left, right)
	return DiffValueText(left) == DiffValueText(right)
end

local function ClosestDiffsRml(response, options)
	options = options or {}
	local matches = response and response.closest_matches
	local topMatch = matches and matches[1]
	local diffs = topMatch and (topMatch.display_diffs or topMatch.diffs) or {}
	local rows = {}
	local visibleCount = 0
	local visibleDiffs = {}
	local expanded = options.diffExpanded == true
	local collapsedLimit = options.diffCollapsedLimit or 6

	for _, diff in ipairs(diffs) do
		local column = diff and diff.column
		if not HiddenDiffColumn(column) and not SameDiffValue(diff.incoming, diff.expected) then
			visibleCount = visibleCount + 1
			visibleDiffs[#visibleDiffs + 1] = diff
		end
	end

	if visibleCount == 0 then
		return "", false
	end
	local rowLimit = expanded and visibleCount or collapsedLimit
	for index, diff in ipairs(visibleDiffs) do
		if index <= rowLimit then
			rows[#rows + 1] = table.concat({
				"<div class=\"pve-stats-diff-row\">",
				"<span class=\"pve-stats-diff-key\">", Model.EscapeRml(diff.column), "</span>",
				"<span class=\"pve-stats-diff-values\">",
				Model.EscapeRml(DiffValueText(diff.incoming)),
				" -> ",
				Model.EscapeRml(DiffValueText(diff.expected)),
				"</span>",
				"</div>",
			})
		end
	end

	if visibleCount > collapsedLimit then
		local toggleText = expanded and "Show fewer" or table.concat({"+", tostring(visibleCount - collapsedLimit), " more"})
		rows[#rows + 1] = table.concat({
			"<div class=\"pve-stats-diff-more\" onclick=\"widget:ToggleDiffs(event)\">",
			Model.EscapeRml(toggleText),
			"</div>",
		})
	end
	return table.concat({
		"<div class=\"pve-stats-diff-title\">Closest differs by ",
		tostring(visibleCount),
		" shown field",
		visibleCount == 1 and "" or "s",
		"</div>",
		table.concat(rows, "\n"),
	}), true
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

local function NumberForDescendingSort(value)
	return tonumber(value) or -math.huge
end

local function PlayerNameForAscendingSort(player)
	local name = tostring(player and player.player_name or "")
	return string.lower(name), name
end

local function PlayerComesBefore(left, right)
	local leftHarderWins = NumberForDescendingSort(left and left.harder_wins)
	local rightHarderWins = NumberForDescendingSort(right and right.harder_wins)
	if leftHarderWins ~= rightHarderWins then
		return leftHarderWins > rightHarderWins
	end

	local leftClosestWins = NumberForDescendingSort(left and left.exact_wins)
	local rightClosestWins = NumberForDescendingSort(right and right.exact_wins)
	if leftClosestWins ~= rightClosestWins then
		return leftClosestWins > rightClosestWins
	end

	local leftRating = NumberForDescendingSort(left and left.player_rating)
	local rightRating = NumberForDescendingSort(right and right.player_rating)
	if leftRating ~= rightRating then
		return leftRating > rightRating
	end

	local leftLowerName, leftName = PlayerNameForAscendingSort(left)
	local rightLowerName, rightName = PlayerNameForAscendingSort(right)
	if leftLowerName ~= rightLowerName then
		return leftLowerName < rightLowerName
	end
	return leftName < rightName
end

local function SortPlayers(players)
	table.sort(players, PlayerComesBefore)
	return players
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

	SortPlayers(activePlayers)
	SortPlayers(spectators)

	return activePlayers, spectators
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
		exactWinsText = "-",
		extendedWinsText = "-",
		exactTotalPlayersText = "-",
		winsLabelText = "Exact Wins",
		totalPlayersLabelText = "Exact Total Players",
		playerWinsLabelText = "Exact Wins",
		matchText = "-",
		errorText = "",
		playersRml = "<div class=\"pve-stats-empty\">No player stats</div>",
		diffsRml = "",
		spectatorText = "Spec",
		hasError = false,
		hasPlayers = false,
		hasDiffs = false,
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
	view.statusText = "Ready"
	view.difficultyText = FormatNumber(setting.difficulty_rating, 1)
	view.exactWinsText = FormatNumber(setting.exact_wins, 0)
	view.extendedWinsText = FormatNumber(setting.extended_wins, 0)
	view.exactTotalPlayersText = FormatNumber(setting.unique_players, 0)
	view.winsLabelText, view.totalPlayersLabelText, view.playerWinsLabelText = WinsLabels(response)
	view.matchText = MatchResultText(response, setting)
	view.diffsRml, view.hasDiffs = ClosestDiffsRml(response, options)
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
