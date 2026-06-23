local Model = {}

Model.CLIENT_VERSION = 1

local function CopyTable(source)
	local copy = {}
	for key, value in pairs(source or {}) do
		copy[key] = value
	end
	return copy
end

local function AddModOptionStep(lookup, key, step)
	local optionKey = tostring(key or "")
	local numericStep = tonumber(step)
	if optionKey == "" or not numericStep or numericStep <= 0 then
		return
	end
	lookup[optionKey] = numericStep
	lookup[string.lower(optionKey)] = numericStep
end

local function CollectModOptionSteps(definitions, lookup, seen)
	if type(definitions) ~= "table" then
		return
	end
	if seen[definitions] then
		return
	end
	seen[definitions] = true

	AddModOptionStep(lookup, definitions.key or definitions.name or definitions.id, definitions.step)
	for key, value in pairs(definitions) do
		if type(value) == "table" then
			AddModOptionStep(lookup, key, value.step)
			CollectModOptionSteps(value.options or value.items or value.children or value.entries, lookup, seen)
			CollectModOptionSteps(value, lookup, seen)
		end
	end
end

function Model.ModOptionStepLookup(...)
	local lookup = {}
	for index = 1, select("#", ...) do
		CollectModOptionSteps(select(index, ...), lookup, {})
	end
	return lookup
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

local function FormatInteger(value)
	local number = tonumber(value)
	if not number then
		return nil
	end
	return string.format("%d", math.floor(number))
end

local function ApiClientVersion(response)
	return tonumber(response and response.client_version)
end

local function ClientUpdateNotice(response)
	local apiVersion = ApiClientVersion(response)
	if apiVersion and apiVersion > Model.CLIENT_VERSION then
		return table.concat({
			"Widget update available: v",
			FormatInteger(apiVersion) or tostring(apiVersion),
		})
	end
	return ""
end

local function SourceWindowText(response)
	local sourceWindow = response and response.source_window
	if type(sourceWindow) ~= "table" then
		return "-"
	end
	if type(sourceWindow.display) == "string" and sourceWindow.display ~= "" then
		return sourceWindow.display
	end

	local earliest = tostring(sourceWindow.earliest_replay_time or "")
	if earliest == "" then
		return "-"
	end
	earliest = string.sub(earliest, 1, 10)

	local ageDays = tonumber(sourceWindow.latest_replay_age_days)
	if ageDays then
		local freshness = "today"
		if ageDays == 1 then
			freshness = "1 day ago"
		elseif ageDays > 1 then
			freshness = tostring(math.floor(ageDays)) .. " days ago"
		end
		return earliest .. " - " .. freshness
	end

	local latest = tostring(sourceWindow.latest_replay_time or "")
	if latest ~= "" then
		return earliest .. " - " .. string.sub(latest, 1, 10)
	end
	return "-"
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

local function IsExactMatch(response, setting)
	local value = FirstDisplayValue(
		response and response.match_status,
		response and response.match_result,
		response and response.match,
		response and response.result,
		setting and setting.match_result,
		setting and setting.match,
		setting and setting.result
	)
	return string.lower(tostring(value or "")) == "exact"
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

local function TrimTrailingZeros(text)
	text = string.gsub(text, "(%..-)0+$", "%1")
	return string.gsub(text, "%.$", "")
end

local function RoundNumber(value)
	if value >= 0 then
		return math.floor(value + 0.5)
	end
	return math.ceil(value - 0.5)
end

local function DecimalPlacesForStep(step)
	local text = tostring(step)
	if string.find(text, "[eE]") then
		text = string.format("%.10f", tonumber(step) or 0)
	end
	text = TrimTrailingZeros(text)
	local dotIndex = string.find(text, ".", 1, true)
	if not dotIndex then
		return 0
	end
	return math.max(0, #text - dotIndex)
end

local function FormatRoundedNumber(value, decimals)
	local places = math.max(0, tonumber(decimals) or 0)
	return TrimTrailingZeros(string.format("%." .. tostring(places) .. "f", value))
end

local function RoundToStep(value, step)
	local numericStep = tonumber(step)
	if not numericStep or numericStep <= 0 then
		return value
	end
	return RoundNumber(value / numericStep) * numericStep
end

local function NumericValue(value)
	local number = tonumber(value)
	if not number then
		return nil
	end
	return number
end

local function CleanFloatNoise(value, number)
	local text = tostring(value)
	if not string.find(text, "[%.eE]") then
		return text
	end
	for decimals = 0, 6 do
		local factor = 10 ^ decimals
		local rounded = RoundNumber(number * factor) / factor
		if math.abs(number - rounded) < 0.000001 then
			return FormatRoundedNumber(rounded, decimals)
		end
	end
	return text
end

local function LookupStep(lookup, column)
	if not lookup or not column then
		return nil
	end
	return tonumber(lookup[column] or lookup[tostring(column)] or lookup[string.lower(tostring(column))])
end

local function DiffStep(diff, options, response, topMatch)
	local explicit = diff and (diff.step or diff.option_step or diff.modoption_step or diff.mod_option_step)
	local explicitStep = tonumber(explicit)
	if explicitStep and explicitStep > 0 then
		return explicitStep
	end

	local column = diff and diff.column
	return LookupStep(options and options.modOptionSteps, column)
		or LookupStep(response and (response.mod_option_steps or response.modoption_steps), column)
		or LookupStep(topMatch and (topMatch.mod_option_steps or topMatch.modoption_steps), column)
end

local function DiffDisplayValue(value, diff, options, response, topMatch)
	local text = DiffValueText(value)
	local number = NumericValue(value)
	if not number then
		return text
	end

	local step = DiffStep(diff, options, response, topMatch)
	if step then
		return FormatRoundedNumber(RoundToStep(number, step), DecimalPlacesForStep(step))
	end
	return CleanFloatNoise(value, number)
end

local function SameDiffValue(diff, options, response, topMatch)
	return DiffDisplayValue(diff.incoming, diff, options, response, topMatch) == DiffDisplayValue(diff.expected, diff, options, response, topMatch)
end

local function VectorMetric(label, value)
	local number = tonumber(value)
	if not number then
		return nil
	end
	return label .. " " .. FormatRoundedNumber(number, 3)
end

local function VectorPercentMetric(label, value)
	local number = tonumber(value)
	if not number then
		return nil
	end
	return label .. " " .. FormatRoundedNumber(number * 100, 1) .. "%"
end

local function VectorFamilySummary(families)
	if type(families) ~= "table" then
		return nil
	end

	local parts = {}
	for _, family in ipairs(families) do
		if #parts >= 3 then
			break
		end
		if type(family) == "table" and family.family then
			local label = tostring(family.family)
			local distance = tonumber(family.normalized_l1_distance)
			if distance then
				label = label .. " " .. FormatRoundedNumber(distance, 3)
			end
			local changed = tonumber(family.changed_component_count)
			if changed and changed > 0 then
				label = label .. " (" .. tostring(math.floor(changed)) .. ")"
			end
			parts[#parts + 1] = label
		end
	end

	if #parts == 0 then
		return nil
	end
	return "families " .. table.concat(parts, ", ")
end

local function VectorDiffSummaryRml(topMatch)
	local vector = topMatch and topMatch.vector_diff
	if type(vector) ~= "table" then
		return ""
	end

	local parts = {}
	local componentCount = tonumber(vector.component_count)
	if componentCount and componentCount > 0 then
		parts[#parts + 1] = tostring(math.floor(componentCount)) .. " components"
	end
	local changedMin = tonumber(vector.changed_component_count_min)
	local changedMax = tonumber(vector.changed_component_count_max)
	if changedMin and changedMax and changedMax > 0 then
		if changedMin == changedMax then
			parts[#parts + 1] = "changed " .. tostring(math.floor(changedMax))
		else
			parts[#parts + 1] = "changed " .. tostring(math.floor(changedMin)) .. "-" .. tostring(math.floor(changedMax))
		end
	end
	local l1 = VectorMetric("L1", vector.normalized_l1_distance)
	if l1 then
		parts[#parts + 1] = l1
	end
	local l2 = VectorMetric("L2", vector.normalized_l2_distance)
	if l2 then
		parts[#parts + 1] = l2
	end
	local maxDelta = VectorMetric("max", vector.normalized_max_delta)
	if maxDelta then
		parts[#parts + 1] = maxDelta
	end
	local cosine = VectorMetric("cos", vector.cosine_distance)
	if cosine then
		parts[#parts + 1] = cosine
	end
	local angular = VectorMetric("angle", vector.angular_distance)
	if angular then
		parts[#parts + 1] = angular
	end
	local relativeMedian = VectorPercentMetric("median diff", vector.relative_diff_median)
	if relativeMedian then
		parts[#parts + 1] = relativeMedian
	end
	local relativeAverage = VectorPercentMetric("avg diff", vector.relative_diff_average)
	if relativeAverage then
		parts[#parts + 1] = relativeAverage
	end
	local families = VectorFamilySummary(vector.top_changed_families)
	if families then
		parts[#parts + 1] = families
	end
	if #parts == 0 then
		return ""
	end

	return table.concat({
		"<div class=\"pve-stats-vector-diff\">Tweak/vector diff: ",
		Model.EscapeRml(table.concat(parts, ", ")),
		"</div>",
	})
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
		if not HiddenDiffColumn(column) and not SameDiffValue(diff, options, response, topMatch) then
			visibleCount = visibleCount + 1
			visibleDiffs[#visibleDiffs + 1] = diff
		end
	end

	local vectorSummary = VectorDiffSummaryRml(topMatch)
	if visibleCount == 0 and vectorSummary == "" then
		return "", false
	end
	if visibleCount > 0 then
		rows[#rows + 1] = table.concat({
			"<div class=\"pve-stats-diff-row pve-stats-diff-header\">",
			"<span class=\"pve-stats-diff-field\">Field</span>",
			"<span class=\"pve-stats-diff-current\">Current</span>",
			"<span class=\"pve-stats-diff-closest\">Closest</span>",
			"</div>",
		})
		local rowLimit = expanded and visibleCount or collapsedLimit
		for index, diff in ipairs(visibleDiffs) do
			if index <= rowLimit then
				rows[#rows + 1] = table.concat({
					"<div class=\"pve-stats-diff-row\">",
					"<span class=\"pve-stats-diff-field\">", Model.EscapeRml(diff.column), "</span>",
					"<span class=\"pve-stats-diff-current\">", Model.EscapeRml(DiffDisplayValue(diff.incoming, diff, options, response, topMatch)), "</span>",
					"<span class=\"pve-stats-diff-closest\">", Model.EscapeRml(DiffDisplayValue(diff.expected, diff, options, response, topMatch)), "</span>",
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
	end
	local sections = {}
	if vectorSummary ~= "" then
		sections[#sections + 1] = vectorSummary
	end
	if visibleCount > 0 then
		sections[#sections + 1] = table.concat({
			"<div class=\"pve-stats-diff-title\">Closest differs by ",
			tostring(visibleCount),
			" shown field",
			visibleCount == 1 and "" or "s",
			"</div>",
			table.concat(rows, "\n"),
		})
	end
	return table.concat(sections, "\n"), true
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

local function PlayerWinsIncludingHarder(player)
	local exactWins = tonumber(player and player.exact_wins)
	local harderWins = tonumber(player and player.harder_wins)
	if exactWins == nil and harderWins == nil then
		return nil
	end
	return (exactWins or 0) + (harderWins or 0)
end

local function PlayerNameForAscendingSort(player)
	local name = tostring(player and player.player_name or "")
	return string.lower(name), name
end

local function PlayerComesBefore(left, right)
	local leftInclusiveWins = NumberForDescendingSort(PlayerWinsIncludingHarder(left))
	local rightInclusiveWins = NumberForDescendingSort(PlayerWinsIncludingHarder(right))
	if leftInclusiveWins ~= rightInclusiveWins then
		return leftInclusiveWins > rightInclusiveWins
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
			"<span class=\"pve-stats-player-stat\">", FormatNumber(PlayerWinsIncludingHarder(player), 0), "</span>",
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
		sourceWindowText = "-",
		isExactMatch = false,
		errorText = "",
		noticeText = "",
		playersRml = "<div class=\"pve-stats-empty\">No player stats</div>",
		diffsRml = "",
		spectatorText = "Spec",
		hasError = false,
		hasNotice = false,
		hasPlayers = false,
		hasDiffs = false,
		hasSourceWindow = false,
		showSpectators = false,
		clientVersion = Model.CLIENT_VERSION,
		apiClientVersion = nil,
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
	view.apiClientVersion = ApiClientVersion(response)
	view.noticeText = ClientUpdateNotice(response)
	view.hasNotice = view.noticeText ~= ""
	if view.hasNotice then
		view.statusText = "Update"
	end
	view.difficultyText = FormatNumber(setting.difficulty_rating, 1)
	view.exactWinsText = FormatNumber(setting.exact_wins, 0)
	view.extendedWinsText = FormatNumber(setting.extended_wins, 0)
	view.exactTotalPlayersText = FormatNumber(setting.unique_players, 0)
	view.winsLabelText, view.totalPlayersLabelText, view.playerWinsLabelText = WinsLabels(response)
	view.matchText = MatchResultText(response, setting)
	view.sourceWindowText = SourceWindowText(response)
	view.hasSourceWindow = view.sourceWindowText ~= "-"
	view.isExactMatch = IsExactMatch(response, setting)
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
