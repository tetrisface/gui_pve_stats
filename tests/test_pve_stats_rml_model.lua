local repoRoot = (arg and arg[1]) or "./"
local Model = dofile(repoRoot .. "include/pve_stats_rml_model.lua")

local function assertEquals(actual, expected, message)
	if actual ~= expected then
		error((message or "assertEquals failed") .. ": expected " .. tostring(expected) .. ", actual " .. tostring(actual), 2)
	end
end

local function assertTrue(value, message)
	if not value then
		error(message or "assertTrue failed", 2)
	end
end

local function testBoundedExponentialBackoffSeconds()
	assertEquals(Model.BoundedExponentialBackoffSeconds(1, 2, 30), 2)
	assertEquals(Model.BoundedExponentialBackoffSeconds(2, 2, 30), 4)
	assertEquals(Model.BoundedExponentialBackoffSeconds(3, 2, 30), 8)
	assertEquals(Model.BoundedExponentialBackoffSeconds(4, 2, 30), 16)
	assertEquals(Model.BoundedExponentialBackoffSeconds(5, 2, 30), 30)
	assertEquals(Model.BoundedExponentialBackoffSeconds(6, 2, 30), 30)
end

local function fakeSpringWithRaptors()
	return {
		Utilities = {
			Gametype = {
				IsRaptors = function() return true end,
				IsScavengers = function() return false end,
			},
		},
		GetModOptions = function()
			return {
				startmetal = "2000",
				raptor_difficulty = "normal",
			}
		end,
		GetPlayerList = function()
			return {2, 1, 3}
		end,
		GetPlayerInfo = function(playerID)
			if playerID == 1 then
				return "Alice", true, false, nil, nil, nil, nil, nil, nil, nil, {accountid = 101}
			end
			if playerID == 2 then
				return "Bob", true, false, nil, nil, nil, nil, nil, nil, nil, {accountid = 202}
			end
			return "Spectator", true, true, nil, nil, nil, nil, nil, nil, nil, {accountid = 303}
		end,
	}
end

local function testBuildRequestUsesInGameContext()
	local request = assert(Model.BuildRequest(fakeSpringWithRaptors(), {mapName = "Supreme Isthmus"}))

	assertEquals(request.ai_type, "Raptors")
	assertEquals(request.map, "Supreme Isthmus")
	assertEquals(request.game_settings.startmetal, "2000")
	assertEquals(request.game_settings.raptor_difficulty, "normal")
	assertEquals(request.player_filter_requested, true)
	assertEquals(request.player_names[1], "Alice")
	assertEquals(request.player_names[2], "Bob")
	assertEquals(request.player_names[3], "Spectator")
	assertEquals(request.player_ids[1], 101)
	assertEquals(request.player_ids[2], 202)
	assertEquals(request.player_ids[3], 303)
	assertEquals(request._active_player_names[1], "Alice")
	assertEquals(request._active_player_names[2], "Bob")
	assertEquals(request._spectator_names[1], "Spectator")
	assertEquals(request._spectator_ids[1], 303)
	assertTrue(request._request_key and request._request_key ~= "")
end

local function testBuildRequestUsesIterableModOptionsCopyWhenAvailable()
	local spring = fakeSpringWithRaptors()
	local backingModOptions = {
		startmetal = "3000",
		raptor_difficulty = "hard",
	}
	local readOnlyProxy = {}
	setmetatable(readOnlyProxy, {__index = backingModOptions})

	spring.GetModOptions = function()
		return readOnlyProxy
	end
	spring.GetModOptionsCopy = function()
		return {
			startmetal = backingModOptions.startmetal,
			raptor_difficulty = backingModOptions.raptor_difficulty,
		}
	end

	local request = assert(Model.BuildRequest(spring, {mapName = "Supreme Isthmus"}))

	assertEquals(request.game_settings.startmetal, "3000")
	assertEquals(request.game_settings.raptor_difficulty, "hard")
end

local function testDetectsBarbarianFromAiInfo()
	local spring = {
		Utilities = {
			Gametype = {
				IsRaptors = function() return false end,
				IsScavengers = function() return false end,
			},
		},
		GetTeamList = function() return {7} end,
		GetAIInfo = function()
			return nil, nil, nil, "BARbarianAI"
		end,
		GetModOptions = function() return {} end,
		GetPlayerList = function() return {} end,
	}

	local request = assert(Model.BuildRequest(spring, {mapName = "Delta Siege"}))

	assertEquals(request.ai_type, "Barbarian")
	assertEquals(request.player_filter_requested, true)
end

local function testDetectsBarbarianFromGenericAiTeam()
	local spring = {
		Utilities = {
			Gametype = {
				IsRaptors = function() return false end,
				IsScavengers = function() return false end,
			},
		},
		GetTeamList = function() return {7} end,
		GetAIInfo = function()
			return nil
		end,
		GetTeamInfo = function()
			return nil, nil, nil, true
		end,
		GetModOptions = function() return {} end,
		GetPlayerList = function() return {} end,
	}

	local request = assert(Model.BuildRequest(spring, {mapName = "Delta Siege"}))

	assertEquals(request.ai_type, "Barbarian")
end

local function testDetectsBarbarianFromTeamLuaAi()
	local spring = {
		Utilities = {
			Gametype = {
				IsRaptors = function() return false end,
				IsScavengers = function() return false end,
			},
		},
		GetTeamList = function() return {7} end,
		GetAIInfo = function()
			return nil
		end,
		GetTeamLuaAI = function()
			return "BARbarianAI"
		end,
		GetModOptions = function() return {} end,
		GetPlayerList = function() return {} end,
	}

	local request = assert(Model.BuildRequest(spring, {mapName = "Delta Siege"}))

	assertEquals(request.ai_type, "Barbarian")
end

local function testWireRequestStripsLocalFields()
	local request = assert(Model.BuildRequest(fakeSpringWithRaptors(), {mapName = "Supreme Isthmus"}))
	local wire = Model.WireRequest(request)

	assertEquals(wire._request_key, nil)
	assertEquals(wire._active_player_names, nil)
	assertEquals(wire._spectator_names, nil)
	assertEquals(wire.ai_type, "Raptors")
	assertEquals(wire.map, "Supreme Isthmus")
end

local function testResponseUsesApiMatchStatus()
	local request = {
		ai_type = "Raptors",
	}
	local view = Model.ViewModelFromResponse({
		found = false,
		match_status = "closest",
		match_result = "win",
		closest_match_basis = "difficulty_factor_vector",
		setting = {
			exact_wins = 80,
			extended_wins = 100,
			unique_players = 10,
			difficulty_rating = 23.75,
		},
		players = {
			{
				player_name = "<Ace>",
				exact_wins = 3,
				harder_wins = 4,
				player_rating = 21.25,
			},
		},
	}, nil, request)

	assertEquals(view.modeText, "Raptors")
	assertEquals(view.statusText, "Ready")
	assertEquals(view.matchText, "Closest")
	assertEquals(view.difficultyText, "23.8")
	assertEquals(view.exactWinsText, "80")
	assertEquals(view.extendedWinsText, "100")
	assertEquals(view.exactTotalPlayersText, "10")
	assertTrue(string.find(view.playersRml, "&lt;Ace&gt;", 1, true) ~= nil)
	assertTrue(string.find(view.playersRml, "21.2", 1, true) ~= nil)

	local exactView = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		setting = {
			difficulty_rating = 12,
		},
	}, nil, request)
	assertEquals(exactView.matchText, "Exact")

	local notFoundView = Model.ViewModelFromResponse({
		found = false,
		match_status = "not_found",
	}, nil, request)
	assertEquals(notFoundView.matchText, "Not found")
end

local function testPlayerRowsUseColorLookup()
	local rows = Model.PlayerRowsRml({
		{
			player_name = "Alice",
			exact_wins = 1,
			harder_wins = 2,
			player_rating = 3.4,
		},
	}, {
		Alice = "#12ABEF",
	})

	assertTrue(string.find(rows, "background-color: #12ABEF", 1, true) ~= nil)
end

local function testSpectatorsRenderAsSeparateGroupWhenEnabled()
	local request = {
		ai_type = "Raptors",
		_active_player_names = {"Alice"},
		_spectator_names = {"SpecBob"},
	}
	local view = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		setting = {
			difficulty_rating = 10,
		},
		players = {
			{
				player_name = "Alice",
				exact_wins = 1,
				harder_wins = 2,
				player_rating = 3,
			},
			{
				player_name = "SpecBob",
				exact_wins = 4,
				harder_wins = 5,
				player_rating = 6,
			},
		},
	}, nil, request, nil, {showSpectators = true})

	assertTrue(string.find(view.playersRml, "Players", 1, true) ~= nil)
	assertTrue(string.find(view.playersRml, "Spectators", 1, true) ~= nil)
	assertTrue(string.find(view.playersRml, "SpecBob", 1, true) ~= nil)
end

testBoundedExponentialBackoffSeconds()
testBuildRequestUsesInGameContext()
testBuildRequestUsesIterableModOptionsCopyWhenAvailable()
testDetectsBarbarianFromAiInfo()
testDetectsBarbarianFromGenericAiTeam()
testDetectsBarbarianFromTeamLuaAi()
testWireRequestStripsLocalFields()
testResponseUsesApiMatchStatus()
testPlayerRowsUseColorLookup()
testSpectatorsRenderAsSeparateGroupWhenEnabled()

print("test_pve_stats_rml_model.lua: ok")
