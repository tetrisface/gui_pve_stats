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

local function assertBefore(text, left, right, message)
	local leftIndex = string.find(text, left, 1, true)
	local rightIndex = string.find(text, right, 1, true)
	assertTrue(leftIndex ~= nil, "missing left value: " .. tostring(left))
	assertTrue(rightIndex ~= nil, "missing right value: " .. tostring(right))
	assertTrue(leftIndex < rightIndex, message or (tostring(left) .. " should appear before " .. tostring(right)))
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
	assertEquals(request._ai_type_source, "spring_utilities_gametype")
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

local function testBuildRequestUsesLiveModOptionsOverStaleCopy()
	local spring = {
		Utilities = {
			Gametype = {
				IsRaptors = function() return false end,
				IsScavengers = function() return true end,
			},
		},
		GetModOptionsCopy = function()
			return {
				scav_difficulty = "normal",
				scav_boss_count = "20",
				maxunits = "850",
			}
		end,
		GetModOptions = function()
			return {
				scav_difficulty = "normal",
				scav_boss_count = "8",
				maxunits = "850",
			}
		end,
		GetPlayerList = function() return {} end,
	}

	local request = assert(Model.BuildRequest(spring, {mapName = "Full Metal Plate"}))

	assertEquals(request.ai_type, "Scavengers")
	assertEquals(request.game_settings.scav_boss_count, "8")
	assertTrue(string.find(request._request_key, "scav_boss_count", 1, true) ~= nil)
	assertTrue(string.find(request._request_key, "1:8", 1, true) ~= nil)
end

local function testModOptionStepLookupUsesNestedDefinitions()
	local lookup = Model.ModOptionStepLookup({
		{
			key = "multiplier_builddistance",
			step = 0.1,
		},
		{
			options = {
				{
					key = "raptor_graceperiodmult",
					step = "0.25",
				},
			},
		},
	})

	assertEquals(lookup.multiplier_builddistance, 0.1)
	assertEquals(lookup.raptor_graceperiodmult, 0.25)
end

local function testDetectsRaptorsFromTeamLuaAiWithoutIncidentalScavengerText()
	local spring = {
		GetTeamList = function() return {7} end,
		GetAIInfo = function()
			return nil, nil, nil, nil, nil, {
				name = "scavengers should not be considered ai identity",
			}
		end,
		GetTeamLuaAI = function()
			return "RaptorsDefense AI"
		end,
		GetGameRulesParam = function()
			return nil
		end,
		GetModOptions = function()
			return {
				lootboxes = "scav_only",
				scav_difficulty = "epic",
				raptor_difficulty = "normal",
			}
		end,
		GetPlayerList = function() return {} end,
	}

	local request = assert(Model.BuildRequest(spring, {mapName = "Supreme Isthmus"}))

	assertEquals(request.ai_type, "Raptors")
	assertEquals(request._ai_type_source, "team_ai_identity")
end

local function testAmbiguousPveAiIdentityFailsClosed()
	local spring = {
		GetTeamList = function() return {7, 8} end,
		GetAIInfo = function() return nil end,
		GetTeamLuaAI = function(teamID)
			return teamID == 7 and "RaptorsDefense AI" or "ScavengersDefense AI"
		end,
		GetModOptions = function() return {} end,
		GetPlayerList = function() return {} end,
	}

	local request, err = Model.BuildRequest(spring, {mapName = "Supreme Isthmus"})

	assertEquals(request, nil)
	assertEquals(err, "ambiguous_team_ai_identity")
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
	assertEquals(wire._ai_type_source, nil)
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
		closest_matches = {
			{
				match_basis = "raw_setting_diff",
				display_diffs = {
					{column = "raptor_difficulty", incoming = "epic", expected = "hard"},
				},
				diffs = {
					{column = "raw_only_field", incoming = "visible only without display_diffs", expected = "hidden"},
					{column = "startmetal", incoming = "2000", expected = "2000"},
					{column = "tweakdefs", incoming = "opaque", expected = "other"},
					{column = "ai_type", incoming = "Raptors", expected = "Raptors"},
				},
			},
		},
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
	assertEquals(view.isExactMatch, false)
	assertEquals(view.difficultyText, "23.8")
	assertEquals(view.exactWinsText, "80")
	assertEquals(view.extendedWinsText, "100")
	assertEquals(view.exactTotalPlayersText, "10")
	assertEquals(view.winsLabelText, "Closest Wins")
	assertEquals(view.totalPlayersLabelText, "Closest Total Players")
	assertEquals(view.playerWinsLabelText, "Closest Wins")
	assertEquals(view.hasDiffs, true)
	assertTrue(string.find(view.diffsRml, "raptor_difficulty", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "Current -> Closest", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "Field</span><span class=\"pve-stats-diff-current\">Current</span><span class=\"pve-stats-diff-closest\">Closest", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "pve-stats-diff-current", 1, true) ~= nil)
	assertBefore(view.diffsRml, "epic", "hard")
	assertTrue(string.find(view.diffsRml, "raw_only_field", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "startmetal", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "tweakdefs", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "ai_type", 1, true) == nil)
	assertTrue(string.find(view.playersRml, "&lt;Ace&gt;", 1, true) ~= nil)
	assertTrue(string.find(view.playersRml, "<span class=\"pve-stats-player-stat\">3</span><span class=\"pve-stats-player-stat\">7</span>", 1, true) ~= nil)
	assertTrue(string.find(view.playersRml, "21.2", 1, true) ~= nil)

	local exactView = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		setting = {
			difficulty_rating = 12,
		},
	}, nil, request)
	assertEquals(exactView.matchText, "Exact")
	assertEquals(exactView.isExactMatch, true)
	assertEquals(exactView.winsLabelText, "Exact Wins")
	assertEquals(exactView.hasDiffs, false)

	local notFoundView = Model.ViewModelFromResponse({
		found = false,
		match_status = "not_found",
	}, nil, request)
	assertEquals(notFoundView.matchText, "Not found")
	assertEquals(notFoundView.isExactMatch, false)
end

local function testClientVersionNoticeIsInformational()
	local request = {
		ai_type = "Raptors",
	}
	local function viewForVersion(clientVersion)
		return Model.ViewModelFromResponse({
			found = true,
			match_status = "exact",
			client_version = clientVersion,
			setting = {
				exact_wins = 12,
				extended_wins = 14,
				unique_players = 3,
				difficulty_rating = 18.25,
			},
			players = {},
		}, nil, request)
	end

	local missing = viewForVersion(nil)
	assertEquals(missing.statusText, "Ready")
	assertEquals(missing.hasNotice, false)
	assertEquals(missing.noticeText, "")
	assertEquals(missing.exactWinsText, "12")

	local same = viewForVersion(Model.CLIENT_VERSION)
	assertEquals(same.statusText, "Ready")
	assertEquals(same.hasNotice, false)

	local older = viewForVersion(Model.CLIENT_VERSION - 1)
	assertEquals(older.statusText, "Ready")
	assertEquals(older.hasNotice, false)

	local newer = viewForVersion(Model.CLIENT_VERSION + 1)
	assertEquals(newer.statusText, "Update")
	assertEquals(newer.hasNotice, true)
	assertEquals(newer.hasError, false)
	assertTrue(string.find(newer.noticeText, "Widget update available", 1, true) ~= nil)
	assertTrue(string.find(newer.noticeText, "v" .. tostring(Model.CLIENT_VERSION + 1), 1, true) ~= nil)
	assertEquals(newer.exactWinsText, "12")
	assertEquals(newer.difficultyText, "18.2")
end

local function testSourceWindowMetadataIsDisplayedWhenPresent()
	local request = {
		ai_type = "Raptors",
	}
	local view = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		source_window = {
			earliest_replay_time = "2024-03-10T22:53:40Z",
			latest_replay_time = "2026-06-20T22:46:17Z",
			latest_replay_age_days = 4,
			display = "2024-03-10 - 4 days ago",
		},
		setting = {
			difficulty_rating = 10,
		},
	}, nil, request)

	assertEquals(view.sourceWindowText, "2024-03-10 - 4 days ago")
	assertEquals(view.hasSourceWindow, true)

	local fallback = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		source_window = {
			earliest_replay_time = "2024-03-10T22:53:40Z",
			latest_replay_age_days = 1,
		},
		setting = {
			difficulty_rating = 10,
		},
	}, nil, request)
	assertEquals(fallback.sourceWindowText, "2024-03-10 - 1 day ago")

	local missing = Model.ViewModelFromResponse({
		found = true,
		match_status = "exact",
		setting = {
			difficulty_rating = 10,
		},
	}, nil, request)
	assertEquals(missing.sourceWindowText, "-")
	assertEquals(missing.hasSourceWindow, false)
end

local function testClosestDiffsCanExpandHiddenVisibleRows()
	local request = {
		ai_type = "Raptors",
	}
	local response = {
		found = false,
		match_status = "closest",
		closest_matches = {
			{
				display_diffs = {
					{column = "Map", incoming = "A", expected = "B"},
					{column = "raptor_difficulty", incoming = "epic", expected = "hard"},
					{column = "startmetal", incoming = "1000", expected = "2000"},
					{column = "multiplier_buildpower", incoming = "1.7", expected = "1.5"},
					{column = "ruins", incoming = "disabled", expected = "enabled"},
					{column = "lootboxes", incoming = "disabled", expected = "enabled"},
					{column = "commanderbuildersenabled", incoming = "disabled", expected = "true"},
					{column = "assistdronesenabled", incoming = "enabled", expected = "false"},
					{column = "tweakdefs", incoming = "opaque", expected = "other"},
					{column = "startenergy", incoming = "1000", expected = "1000"},
				},
			},
		},
		setting = {
			difficulty_rating = 23.75,
		},
	}

	local collapsed = Model.ViewModelFromResponse(response, nil, request)
	assertEquals(collapsed.hasDiffs, true)
	assertTrue(string.find(collapsed.diffsRml, "Closest differs by 8 shown fields", 1, true) ~= nil)
	assertTrue(string.find(collapsed.diffsRml, "+2 more", 1, true) ~= nil)
	assertTrue(string.find(collapsed.diffsRml, "widget:ToggleDiffs(event)", 1, true) ~= nil)
	assertTrue(string.find(collapsed.diffsRml, "commanderbuildersenabled", 1, true) == nil)
	assertTrue(string.find(collapsed.diffsRml, "assistdronesenabled", 1, true) == nil)
	assertTrue(string.find(collapsed.diffsRml, "tweakdefs", 1, true) == nil)
	assertTrue(string.find(collapsed.diffsRml, "startenergy", 1, true) == nil)

	local expanded = Model.ViewModelFromResponse(response, nil, request, nil, {diffExpanded = true})
	assertTrue(string.find(expanded.diffsRml, "Show fewer", 1, true) ~= nil)
	assertTrue(string.find(expanded.diffsRml, "commanderbuildersenabled", 1, true) ~= nil)
	assertTrue(string.find(expanded.diffsRml, "assistdronesenabled", 1, true) ~= nil)
	assertTrue(string.find(expanded.diffsRml, "tweakdefs", 1, true) == nil)
	assertTrue(string.find(expanded.diffsRml, "startenergy", 1, true) == nil)
end

local function testVectorDiffSummaryRendersWithoutRawDiffRows()
	local view = Model.ViewModelFromResponse({
		found = false,
		match_status = "closest",
		closest_matches = {
			{
				match_basis = "difficulty_factor_vector",
				display_diffs = {
					{column = "tweakdefs", incoming = "opaque-a", expected = "opaque-b"},
				},
				vector_diff = {
					component_count = 123,
					changed_component_count_min = 5,
					changed_component_count_max = 7,
					normalized_l1_distance = 5.4321,
					normalized_l2_distance = 3.25,
					normalized_max_delta = 0.125,
					cosine_distance = 0.292893,
					angular_distance = 0.25,
					relative_diff_median = 0.10,
					relative_diff_average = 0.15,
					top_changed_families = {
						{family = "economy_build", changed_component_count = 2, normalized_l1_distance = 1.5},
						{family = "unit_stat", changed_component_count = 1, normalized_l1_distance = 0.5},
					},
				},
			},
		},
		setting = {
			difficulty_rating = 10,
		},
	}, nil, {ai_type = "Raptors"})

	assertEquals(view.hasDiffs, true)
	assertTrue(string.find(view.diffsRml, "Tweak/vector diff", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "123 components", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "changed 5-7", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "L1 5.432", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "L2 3.25", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "max 0.125", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "cos 0.293", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "angle 0.25", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "median diff 10%", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "avg diff 15%", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "families economy_build 1.5 (2), unit_stat 0.5 (1)", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "opaque-a", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "Closest differs by", 1, true) == nil)
end

local function testClosestDiffsRoundFloatNoiseToModOptionSteps()
	local request = {
		ai_type = "Raptors",
	}
	local response = {
		found = false,
		match_status = "closest",
		closest_matches = {
			{
				display_diffs = {
					{column = "multiplier_builddistance", incoming = "1.70000005", expected = "1.5"},
					{column = "multiplier_buildpower", incoming = "1.39999998", expected = "1.29999995"},
					{column = "multiplier_same", incoming = "1.70000005", expected = "1.7"},
				},
			},
		},
	}
	local view = Model.ViewModelFromResponse(response, nil, request, nil, {
		modOptionSteps = {
			multiplier_builddistance = 0.1,
			multiplier_buildpower = 0.1,
			multiplier_same = 0.1,
		},
	})

	assertEquals(view.hasDiffs, true)
	assertTrue(string.find(view.diffsRml, "Closest differs by 2 shown fields", 1, true) ~= nil)
	assertTrue(string.find(view.diffsRml, "1.70000005", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "1.39999998", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "1.29999995", 1, true) == nil)
	assertTrue(string.find(view.diffsRml, "multiplier_same", 1, true) == nil)
	assertBefore(view.diffsRml, "1.7", "1.5")
	assertBefore(view.diffsRml, "1.4", "1.3")
end

local function testClosestDiffsCleanFloatNoiseWithoutStepMetadata()
	local request = {
		ai_type = "Raptors",
	}
	local view = Model.ViewModelFromResponse({
		found = false,
		match_status = "closest",
		closest_matches = {
			{
				display_diffs = {
					{column = "multiplier_resourceincome", incoming = "1.89999998", expected = "1.5"},
				},
			},
		},
	}, nil, request)

	assertEquals(view.hasDiffs, true)
	assertTrue(string.find(view.diffsRml, "1.89999998", 1, true) == nil)
	assertBefore(view.diffsRml, "1.9", "1.5")
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
	assertTrue(string.find(rows, "<span class=\"pve-stats-player-stat\">1</span><span class=\"pve-stats-player-stat\">3</span>", 1, true) ~= nil)
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

local function testPlayersAndSpectatorsSortByWinsRatingAndName()
	local request = {
		ai_type = "Raptors",
		_active_player_names = {"Aaron", "Alice", "Bob", "Clara", "Delta"},
		_spectator_names = {"SpecA", "SpecHigh", "SpecZ"},
	}
	local view = Model.ViewModelFromResponse({
		found = true,
		match_status = "closest",
		setting = {
			difficulty_rating = 10,
		},
		players = {
			{
				player_name = "Delta",
				exact_wins = 99,
				harder_wins = 4,
				player_rating = 99,
			},
			{
				player_name = "Bob",
				exact_wins = 10,
				harder_wins = 5,
				player_rating = 1,
			},
			{
				player_name = "SpecZ",
				exact_wins = 1,
				harder_wins = 1,
				player_rating = 1,
			},
			{
				player_name = "Alice",
				exact_wins = 10,
				harder_wins = 5,
				player_rating = 7,
			},
			{
				player_name = "SpecHigh",
				exact_wins = 0,
				harder_wins = 2,
				player_rating = 0,
			},
			{
				player_name = "Clara",
				exact_wins = 8,
				harder_wins = 5,
				player_rating = 5,
			},
			{
				player_name = "Aaron",
				exact_wins = 10,
				harder_wins = 5,
				player_rating = 7,
			},
			{
				player_name = "SpecA",
				exact_wins = 1,
				harder_wins = 1,
				player_rating = 1,
			},
		},
	}, nil, request, nil, {showSpectators = true})

	assertBefore(view.playersRml, "Delta", "Aaron")
	assertBefore(view.playersRml, "Aaron", "Alice")
	assertBefore(view.playersRml, "Alice", "Bob")
	assertBefore(view.playersRml, "Bob", "Clara")
	assertBefore(view.playersRml, "SpecA", "SpecZ")
	assertBefore(view.playersRml, "SpecZ", "SpecHigh")
end

testBoundedExponentialBackoffSeconds()
testBuildRequestUsesInGameContext()
testBuildRequestUsesIterableModOptionsCopyWhenAvailable()
testBuildRequestUsesLiveModOptionsOverStaleCopy()
testModOptionStepLookupUsesNestedDefinitions()
testDetectsRaptorsFromTeamLuaAiWithoutIncidentalScavengerText()
testAmbiguousPveAiIdentityFailsClosed()
testDetectsBarbarianFromAiInfo()
testDetectsBarbarianFromGenericAiTeam()
testDetectsBarbarianFromTeamLuaAi()
testWireRequestStripsLocalFields()
testResponseUsesApiMatchStatus()
testClientVersionNoticeIsInformational()
testSourceWindowMetadataIsDisplayedWhenPresent()
testClosestDiffsCanExpandHiddenVisibleRows()
testVectorDiffSummaryRendersWithoutRawDiffRows()
testClosestDiffsRoundFloatNoiseToModOptionSteps()
testClosestDiffsCleanFloatNoiseWithoutStepMetadata()
testPlayerRowsUseColorLookup()
testSpectatorsRenderAsSeparateGroupWhenEnabled()
testPlayersAndSpectatorsSortByWinsRatingAndName()

print("test_pve_stats_rml_model.lua: ok")
