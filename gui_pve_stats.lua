if not RmlUi then
	return
end

local widget = widget

function widget:GetInfo()
	return {
		name = "PvE Stats",
		desc = "Shows PvE stats from the stats API",
		author = "tetrisface",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 1,
		enabled = true,
	}
end

local DEV = true
local LOG_SECTION = 'pve_stats_rml'
local LOG_PREFIX = 'pve_stats'
local MODEL_NAME = 'pve_stats_model'
local RML_PATH = 'luaui/rmlwidgets/gui_pve_stats/gui_pve_stats.rml'
local PANEL_ID = 'pve-stats-root'
local DEFAULT_HOST = DEV and '127.0.0.1' or 'd29i3oohxql6zz.cloudfront.net'
local DEFAULT_PORT = DEV and 8080 or 80
local DEFAULT_PATH = '/stats'
local DEFAULT_URL = ''
local DEFAULT_AUTO_FETCH = 1
local DEFAULT_EVIDENCE_LOG = 1
local DEFAULT_LUA_SOCKET_ENABLED = 1
local DEFAULT_SHOW_SPECTATORS = 0
local DEFAULT_DEBUG_LOG = 0
local DEFAULT_TIMEOUT_MS = 3000
local DEFAULT_RETRY_MAX_ATTEMPTS = 5
local DEFAULT_RETRY_INITIAL_SECONDS = 2
local DEFAULT_RETRY_MAX_SECONDS = 30
local DEFAULT_VIEW_WIDTH = 1920
local DEFAULT_VIEW_HEIGHT = 1080
local DEFAULT_PANEL_WIDTH = 344
local DEFAULT_PANEL_TOP = 138
local DEFAULT_PANEL_RIGHT = 18
local HASH_MODULO = 4294967296

local Model = VFS.Include('luaui/rmlwidgets/gui_pve_stats/include/pve_stats_rml_model.lua')
local Json = Json or VFS.Include('common/luaUtilities/json.lua')

local socketLib = socket

local state = {
	rmlContext = nil,
	document = nil,
	dmHandle = nil,
	viewModel = Model.EmptyViewModel(),
	lastRequest = nil,
	lastResponse = nil,
	lastError = nil,
	lastEvidence = nil,
	pendingFetch = false,
	fetchDelay = 0,
	retryAttempt = 0,
	retryActive = false,
	showSpectators = false,
}

local function GetConfigString(key, defaultValue)
	if Spring.GetConfigString then
		return Spring.GetConfigString(key, defaultValue)
	end
	return defaultValue
end

local function GetConfigInt(key, defaultValue)
	if Spring.GetConfigInt then
		return Spring.GetConfigInt(key, defaultValue)
	end
	return defaultValue
end

local function SetConfigInt(key, value)
	if Spring.SetConfigInt then
		Spring.SetConfigInt(key, value)
	elseif Spring.SetConfigString then
		Spring.SetConfigString(key, tostring(value))
	end
end

local function SetText(elementId, value)
	if not state.document then
		return
	end
	local element = state.document:GetElementById(elementId)
	if element then
		element.inner_rml = Model.EscapeRml(value)
	end
end

local function SetRml(elementId, value)
	if not state.document then
		return
	end
	local element = state.document:GetElementById(elementId)
	if element then
		element.inner_rml = value or ''
	end
end

local function SetClass(elementId, className, enabled)
	if not state.document then
		return
	end
	local element = state.document:GetElementById(elementId)
	if element then
		element:SetClass(className, enabled)
	end
end

local function ApplyViewModel(viewModel)
	state.viewModel = viewModel or Model.EmptyViewModel()
	local dm = state.dmHandle
	if dm then
		dm.statusText = state.viewModel.statusText
		dm.modeText = state.viewModel.modeText
		dm.difficultyText = state.viewModel.difficultyText
		dm.exactWinsText = state.viewModel.exactWinsText
		dm.extendedWinsText = state.viewModel.extendedWinsText
		dm.exactTotalPlayersText = state.viewModel.exactTotalPlayersText
		dm.matchText = state.viewModel.matchText
		dm.errorText = state.viewModel.errorText
	end

	SetText('pve-stats-status', state.viewModel.statusText)
	SetText('pve-stats-mode', state.viewModel.modeText)
	SetText('pve-stats-difficulty', state.viewModel.difficultyText)
	SetText('pve-stats-exact-wins', state.viewModel.exactWinsText)
	SetText('pve-stats-extended-wins', state.viewModel.extendedWinsText)
	SetText('pve-stats-exact-total-players', state.viewModel.exactTotalPlayersText)
	SetText('pve-stats-match', state.viewModel.matchText)
	SetText('pve-stats-spectators-toggle', state.viewModel.spectatorText)
	SetText('pve-stats-error', state.viewModel.errorText)
	SetRml('pve-stats-players', state.viewModel.playersRml)
	SetClass('pve-stats-root', 'has-error', state.viewModel.hasError)
	SetClass('pve-stats-error', 'hidden', not state.viewModel.hasError)
	SetClass('pve-stats-spectators-toggle', 'active', state.viewModel.showSpectators)
end

local function StableHash(value)
	local text = tostring(value or '')
	local hash = 5381
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % HASH_MODULO
	end
	return string.format('%08x', hash)
end

local function EndpointLabel(endpoint)
	if not endpoint then
		return '-'
	end
	return table.concat({
		endpoint.scheme or 'http',
		'://',
		endpoint.host or '',
		':',
		tostring(endpoint.port or DEFAULT_PORT),
		endpoint.path or DEFAULT_PATH,
	})
end

local function CountValues(values)
	local count = 0
	for _ in ipairs(values or {}) do
		count = count + 1
	end
	return count
end

local function SafeCall(method, ...)
	if not method then
		return nil
	end
	local ok, first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh = pcall(method, ...)
	if not ok then
		return nil
	end
	return first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh
end

local function ColorByte(value)
	local number = tonumber(value) or 1
	number = math.max(0, math.min(1, number))
	return math.floor(number * 255 + 0.5)
end

local function HexColor(r, g, b)
	return string.format('#%02X%02X%02X', ColorByte(r), ColorByte(g), ColorByte(b))
end

local function AccountIdFromInfo(...)
	for index = 1, select('#', ...) do
		local info = select(index, ...)
		if type(info) == 'table' then
			local accountID = tonumber(info.accountid or info.accountID or info.account_id)
			if accountID and accountID > 0 then
				return accountID
			end
		end
	end
	return nil
end

local function BuildPlayerColorLookup()
	local lookup = {}
	local playerList = SafeCall(Spring.GetPlayerList) or {}
	for _, playerID in ipairs(playerList) do
		local name, _, spectator, teamID, _, _, _, _, _, customKeys, extraInfo = SafeCall(Spring.GetPlayerInfo, playerID, false)
		if name and spectator == false and teamID and Spring.GetTeamColor then
			local r, g, b = SafeCall(Spring.GetTeamColor, teamID)
			local color = HexColor(r, g, b)
			lookup[name] = color
			local accountID = AccountIdFromInfo(customKeys, extraInfo)
			if accountID then
				lookup[accountID] = color
				lookup[tostring(accountID)] = color
			end
		end
	end
	return lookup
end

local function BuildViewModel(response, err, request)
	return Model.ViewModelFromResponse(response, err, request, BuildPlayerColorLookup(), {
		showSpectators = state.showSpectators,
	})
end

local function RefreshViewModel()
	ApplyViewModel(BuildViewModel(state.lastResponse, state.lastError, state.lastRequest))
end

local function BuildRequestEvidence(endpoint, body, request)
	return {
		version = 1,
		status = 'pending',
		endpoint = EndpointLabel(endpoint),
		ai_type = tostring(request and request.ai_type or ''),
		map_hash = StableHash(request and request.map or ''),
		player_names_count = CountValues(request and request.player_names),
		player_ids_count = CountValues(request and request.player_ids),
		request_bytes = #tostring(body or ''),
		request_hash = StableHash(body),
		request_key_hash = StableHash(request and request._request_key or ''),
	}
end

local function LogMessage(message)
	message = LOG_PREFIX .. ' ' .. tostring(message or '')
	if Spring.Echo then
		Spring.Echo('[' .. LOG_SECTION .. '] ' .. message)
	elseif Spring.Log and LOG and LOG.INFO then
		Spring.Log(LOG_SECTION, LOG.INFO, message)
	end
end

local function DebugLog(message)
	if GetConfigInt('PveStatsDebugLog', DEFAULT_DEBUG_LOG) == 1 then
		LogMessage(message)
	end
end

local function CurrentViewGeometry()
	if Spring.GetViewGeometry then
		local viewWidth, viewHeight = Spring.GetViewGeometry()
		if viewWidth and viewHeight and viewWidth > 0 and viewHeight > 0 then
			return viewWidth, viewHeight
		end
	end
	if gl and gl.GetViewSizes then
		local viewWidth, viewHeight = gl.GetViewSizes()
		if viewWidth and viewHeight and viewWidth > 0 and viewHeight > 0 then
			return viewWidth, viewHeight
		end
	end
	return DEFAULT_VIEW_WIDTH, DEFAULT_VIEW_HEIGHT
end

local function PositionDocument()
	if not state.document then
		return
	end

	local panel = state.document:GetElementById(PANEL_ID)
	if not panel then
		DebugLog('position_failed reason=missing_panel id=' .. PANEL_ID)
		return
	end

	local viewWidth, viewHeight = CurrentViewGeometry()
	local left = math.max(0, viewWidth - DEFAULT_PANEL_WIDTH - DEFAULT_PANEL_RIGHT)
	panel.style.left = tostring(left) .. 'px'
	panel.style.top = tostring(DEFAULT_PANEL_TOP) .. 'px'
	panel.style.width = tostring(DEFAULT_PANEL_WIDTH) .. 'dp'

	DebugLog(table.concat({
		'position_panel left=',
		tostring(left),
		' top=',
		tostring(DEFAULT_PANEL_TOP),
		' width=',
		tostring(DEFAULT_PANEL_WIDTH),
		' view=',
		tostring(viewWidth),
		'x',
		tostring(viewHeight),
	}))
end

local function FormatEvidence(evidence)
	if not evidence then
		return 'pve_stats_evidence status=missing'
	end
	return table.concat({
		'pve_stats_evidence version=',
		tostring(evidence.version or 1),
		' status=',
		tostring(evidence.status or '-'),
		' endpoint=',
		tostring(evidence.endpoint or '-'),
		' ai_type=',
		tostring(evidence.ai_type or '-'),
		' map_hash=',
		tostring(evidence.map_hash or '-'),
		' player_names=',
		tostring(evidence.player_names_count or 0),
		' player_ids=',
		tostring(evidence.player_ids_count or 0),
		' request_hash=',
		tostring(evidence.request_hash or '-'),
		' request_key_hash=',
		tostring(evidence.request_key_hash or '-'),
		' request_bytes=',
		tostring(evidence.request_bytes or 0),
		' response_hash=',
		tostring(evidence.response_hash or '-'),
		' response_bytes=',
		tostring(evidence.response_bytes or 0),
		' http_status=',
		tostring(evidence.http_status or '-'),
		' match_status=',
		tostring(evidence.match_status or '-'),
	})
end

local function MaybeLogEvidence(evidence)
	if GetConfigInt('PveStatsEvidenceLog', DEFAULT_EVIDENCE_LOG) == 1 then
		LogMessage(FormatEvidence(evidence))
	end
end

local function ParseHttpResponse(raw)
	local headerEnd = string.find(raw, '\r\n\r\n', 1, true)
	if not headerEnd then
		return nil, 'invalid_http_response'
	end

	local header = string.sub(raw, 1, headerEnd - 1)
	local body = string.sub(raw, headerEnd + 4)
	local status = tonumber(string.match(header, '^HTTP/%d%.%d%s+(%d+)'))
	if not status then
		return nil, 'invalid_http_status'
	end
	local meta = {
		http_status = status,
		response_bytes = #body,
		response_hash = StableHash(body),
	}
	if status < 200 or status >= 300 then
		return nil, 'http_' .. tostring(status) .. ':' .. body, meta
	end

	local ok, decoded = pcall(Json.decode, body)
	if not ok then
		return nil, 'invalid_json:' .. tostring(decoded), meta
	end
	return decoded, nil, meta
end

local function Trim(value)
	return string.match(tostring(value or ''), '^%s*(.-)%s*$')
end

local function NormalizePath(path)
	path = Trim(path)
	if path == '' then
		return DEFAULT_PATH
	end
	if string.sub(path, 1, 1) ~= '/' then
		return '/' .. path
	end
	return path
end

local function ParseHttpUrl(url)
	url = Trim(url)
	local scheme, rest = string.match(url, '^(%a[%w+.-]*)://(.+)$')
	if not scheme then
		return nil, 'invalid_url'
	end

	scheme = string.lower(scheme)
	if scheme ~= 'http' then
		return nil, 'unsupported_scheme:' .. scheme
	end

	local authority, path = string.match(rest, '^([^/]*)(/?.*)$')
	if not authority or authority == '' then
		return nil, 'missing_host'
	end
	if string.find(authority, '@', 1, true) then
		return nil, 'unsupported_url_auth'
	end

	local host, portText = string.match(authority, '^([^:]+):?(%d*)$')
	if not host or host == '' then
		return nil, 'invalid_host'
	end

	local port = DEFAULT_PORT
	if portText and portText ~= '' then
		port = tonumber(portText)
	else
		port = 80
	end
	if not port or port < 1 or port > 65535 then
		return nil, 'invalid_port'
	end

	return {
		scheme = scheme,
		host = host,
		port = port,
		path = NormalizePath(path),
	}
end

local function ResolveEndpoint()
	local configuredUrl = Trim(GetConfigString('PveStatsUrl', DEFAULT_URL))
	if configuredUrl ~= '' then
		return ParseHttpUrl(configuredUrl)
	end

	return {
		scheme = 'http',
		host = GetConfigString('PveStatsHost', DEFAULT_HOST),
		port = GetConfigInt('PveStatsPort', DEFAULT_PORT),
		path = NormalizePath(GetConfigString('PveStatsPath', DEFAULT_PATH)),
	}
end

local function IsLuaSocketEnabled()
	return GetConfigInt('LuaSocketEnabled', DEFAULT_LUA_SOCKET_ENABLED) == 1
end

local function PostJson(endpoint, body)
	if not IsLuaSocketEnabled() then
		return nil, 'lua_socket_disabled'
	end

	socketLib = socketLib or socket
	if not socketLib or not socketLib.tcp then
		return nil, 'missing_socket'
	end

	local timeout = GetConfigInt('PveStatsTimeoutMs', DEFAULT_TIMEOUT_MS) / 1000

	local client = socketLib.tcp()
	client:settimeout(timeout)
	local ok, err = client:connect(endpoint.host, endpoint.port)
	if not ok then
		client:close()
		return nil, 'connect_failed:' .. tostring(err)
	end

	local request = table.concat({
		'POST ' .. endpoint.path .. ' HTTP/1.1\r\n',
		'Host: ' .. endpoint.host .. ':' .. tostring(endpoint.port) .. '\r\n',
		'Content-Type: application/json\r\n',
		'Content-Length: ' .. tostring(#body) .. '\r\n',
		'Connection: close\r\n',
		'\r\n',
		body,
	})

	local sent = 0
	while sent < #request do
		local lastByte, sendErr, partial = client:send(request, sent + 1)
		if lastByte then
			sent = lastByte
		elseif partial and partial > sent then
			sent = partial
		else
			client:close()
			return nil, 'send_failed:' .. tostring(sendErr)
		end
	end

	local response, receiveErr, partial = client:receive('*a')
	client:close()
	response = response or partial
	if not response or response == '' then
		return nil, 'receive_failed:' .. tostring(receiveErr)
	end
	return ParseHttpResponse(response)
end

local function CompleteEvidence(evidence, response, err, meta)
	evidence = evidence or { version = 1 }
	evidence.status = err and 'error' or 'ok'
	evidence.error = err
	if meta then
		evidence.http_status = meta.http_status
		evidence.response_bytes = meta.response_bytes
		evidence.response_hash = meta.response_hash
	end
	if response then
		evidence.match_status = response.match_status
		evidence.setting_hash = response.setting_hash
	end
	state.lastEvidence = evidence
	MaybeLogEvidence(evidence)
	return evidence
end

local function ResetRetryState()
	state.retryAttempt = 0
	state.retryActive = false
end

local function RetryMaxAttempts()
	return math.max(0, GetConfigInt('PveStatsRetryMaxAttempts', DEFAULT_RETRY_MAX_ATTEMPTS))
end

local function RetryDelaySeconds(attempt)
	return Model.BoundedExponentialBackoffSeconds(
		attempt,
		GetConfigInt('PveStatsRetryInitialSeconds', DEFAULT_RETRY_INITIAL_SECONDS),
		GetConfigInt('PveStatsRetryMaxSeconds', DEFAULT_RETRY_MAX_SECONDS)
	)
end

local function RetryErrorText(err, delay, attempt, maxAttempts)
	return table.concat({
		tostring(err or 'unknown_error'),
		' retrying in ',
		string.format('%.0f', delay or 0),
		's (',
		tostring(attempt or 0),
		'/',
		tostring(maxAttempts or 0),
		')',
	})
end

local function FetchStats()
	DebugLog('fetch_start')

	local request, err = Model.BuildRequest(Spring, Game)
	state.lastRequest = request
	if not request then
		state.lastError = err
		DebugLog('fetch_request_failed error=' .. tostring(err))
		ApplyViewModel(BuildViewModel(nil, err, nil))
		return nil, err
	end

	local ok, body = pcall(Json.encode, Model.WireRequest(request))
	if not ok then
		err = 'encode_failed:' .. tostring(body)
		state.lastError = err
		DebugLog('fetch_encode_failed error=' .. tostring(err))
		ApplyViewModel(BuildViewModel(nil, err, request))
		return nil, err
	end

	local response
	local endpoint
	endpoint, err = ResolveEndpoint()
	if not endpoint then
		state.lastError = err
		DebugLog('fetch_endpoint_failed error=' .. tostring(err))
		ApplyViewModel(BuildViewModel(nil, err, request))
		return nil, err
	end

	local evidence = BuildRequestEvidence(endpoint, body, request)
	state.lastEvidence = evidence
	DebugLog('fetch_post endpoint=' .. tostring(evidence.endpoint) .. ' request_bytes=' .. tostring(evidence.request_bytes))
	local responseMeta
	response, err, responseMeta = PostJson(endpoint, body)
	if response then
		state.lastResponse = response
		state.lastError = nil
		ResetRetryState()
	else
		state.lastError = err
	end
	CompleteEvidence(evidence, response, err, responseMeta)
	DebugLog('fetch_complete status=' .. tostring(evidence.status) .. ' error=' .. tostring(err or '-'))

	local viewModel = BuildViewModel(response, err, request)
	DebugLog(table.concat({
		'view_model status=',
		tostring(viewModel.statusText),
		' mode=',
		tostring(viewModel.modeText),
		' difficulty=',
		tostring(viewModel.difficultyText),
		' players=',
		tostring(response and response.players and #response.players or 0),
		' has_error=',
		tostring(viewModel.hasError),
	}))
	ApplyViewModel(viewModel)
	return response, err
end

local function ScheduleFetch(delay, options)
	options = options or {}
	if options.retry ~= true then
		ResetRetryState()
	end
	state.pendingFetch = true
	state.fetchDelay = delay or 0
	DebugLog(table.concat({
		'schedule_fetch delay=',
		tostring(state.fetchDelay),
		' retry=',
		tostring(options.retry == true),
		' attempt=',
		tostring(state.retryAttempt),
	}))
end

local function ScheduleRetry(err)
	local maxAttempts = RetryMaxAttempts()
	if maxAttempts <= 0 then
		DebugLog('retry_disabled error=' .. tostring(err or '-'))
		return false
	end
	if state.retryAttempt >= maxAttempts then
		state.retryActive = false
		DebugLog('retry_exhausted attempts=' .. tostring(state.retryAttempt) .. ' error=' .. tostring(err or '-'))
		return false
	end

	state.retryAttempt = state.retryAttempt + 1
	state.retryActive = true
	local delay = RetryDelaySeconds(state.retryAttempt)
	ScheduleFetch(delay, { retry = true })

	local viewModel = BuildViewModel(nil, RetryErrorText(err, delay, state.retryAttempt, maxAttempts), state.lastRequest)
	viewModel.statusText = 'Retrying'
	ApplyViewModel(viewModel)

	DebugLog(table.concat({
		'schedule_retry attempt=',
		tostring(state.retryAttempt),
		' max_attempts=',
		tostring(maxAttempts),
		' delay=',
		tostring(delay),
		' error=',
		tostring(err or '-'),
	}))
	return true
end

local function FetchStatsWithRetry()
	local response, err = FetchStats()
	if err then
		ScheduleRetry(err)
	else
		ResetRetryState()
	end
	return response, err
end

local function InstallApi()
	WG.PveStatsRml = {
		BuildRequest = function()
			return Model.BuildRequest(Spring, Game)
		end,
		FetchStats = FetchStatsWithRetry,
		FetchStatsOnce = FetchStats,
		ScheduleFetch = ScheduleFetch,
		GetLastRequest = function()
			return state.lastRequest
		end,
		GetLastResponse = function()
			return state.lastResponse
		end,
		GetLastError = function()
			return state.lastError
		end,
		GetLastEvidence = function()
			return state.lastEvidence
		end,
		GetRetryAttempt = function()
			return state.retryAttempt
		end,
		IsRetryActive = function()
			return state.retryActive
		end,
		LogLastEvidence = function()
			LogMessage(FormatEvidence(state.lastEvidence))
			return state.lastEvidence
		end,
		GetEndpoint = ResolveEndpoint,
		IsLuaSocketEnabled = IsLuaSocketEnabled,
		GetViewModel = function()
			return state.viewModel
		end,
		GetShowSpectators = function()
			return state.showSpectators
		end,
		SetShowSpectators = function(enabled)
			state.showSpectators = enabled == true
			SetConfigInt('PveStatsShowSpectators', state.showSpectators and 1 or 0)
			RefreshViewModel()
		end,
	}
end

function widget:Initialize()
	DebugLog('initialize_begin')
	state.showSpectators = GetConfigInt('PveStatsShowSpectators', DEFAULT_SHOW_SPECTATORS) == 1
	InstallApi()
	ApplyViewModel(BuildViewModel(nil, nil, nil))

	state.rmlContext = RmlUi.GetContext('shared')
	if not state.rmlContext then
		DebugLog('initialize_failed reason=missing_rml_context')
		return false
	end

	local dm = state.rmlContext:OpenDataModel(MODEL_NAME, state.viewModel, self)
	if not dm then
		DebugLog('initialize_failed reason=missing_data_model')
		return false
	end
	state.dmHandle = dm

	local document = state.rmlContext:LoadDocument(RML_PATH, self)
	if not document then
		DebugLog('initialize_failed reason=missing_document path=' .. RML_PATH)
		widget:Shutdown()
		return false
	end
	state.document = document
	document:ReloadStyleSheet()
	PositionDocument()
	document:Show()
	ApplyViewModel(state.viewModel)

	DebugLog(table.concat({
		'initialize_ready auto_fetch=',
		tostring(GetConfigInt('PveStatsAutoFetch', DEFAULT_AUTO_FETCH)),
		' evidence_log=',
		tostring(GetConfigInt('PveStatsEvidenceLog', DEFAULT_EVIDENCE_LOG)),
		' lua_socket=',
		tostring(GetConfigInt('LuaSocketEnabled', DEFAULT_LUA_SOCKET_ENABLED)),
		' show_spectators=',
		tostring(state.showSpectators and 1 or 0),
		' retry_max_attempts=',
		tostring(RetryMaxAttempts()),
		' retry_initial_seconds=',
		tostring(GetConfigInt('PveStatsRetryInitialSeconds', DEFAULT_RETRY_INITIAL_SECONDS)),
		' retry_max_seconds=',
		tostring(GetConfigInt('PveStatsRetryMaxSeconds', DEFAULT_RETRY_MAX_SECONDS)),
	}))

	if GetConfigInt('PveStatsAutoFetch', DEFAULT_AUTO_FETCH) == 1 then
		ScheduleFetch(0.5)
	end
end

function widget:ViewResize()
	PositionDocument()
end

function widget:ToggleSpectators()
	state.showSpectators = not state.showSpectators
	SetConfigInt('PveStatsShowSpectators', state.showSpectators and 1 or 0)
	DebugLog('toggle_spectators enabled=' .. tostring(state.showSpectators))
	RefreshViewModel()
end

function widget:Shutdown()
	if state.rmlContext and state.dmHandle then
		state.rmlContext:RemoveDataModel(MODEL_NAME)
		state.dmHandle = nil
	end
	if state.document then
		state.document:Close()
		state.document = nil
	end
	if WG.PveStatsRml then
		WG.PveStatsRml = nil
	end
	state.rmlContext = nil
end

function widget:Update(dt)
	if not state.pendingFetch then
		return
	end

	state.fetchDelay = state.fetchDelay - (dt or 0)
	if state.fetchDelay <= 0 then
		state.pendingFetch = false
		FetchStatsWithRetry()
	end
end

function widget:RecvLuaMsg(message)
	if not state.document then
		return
	end
	if message:sub(1, 19) == "LobbyOverlayActive0" then
		DebugLog("visibility_show reason=lobby_overlay_inactive")
		state.document:Show()
	elseif message:sub(1, 19) == "LobbyOverlayActive1" then
		DebugLog("visibility_hide reason=lobby_overlay_active")
		state.document:Hide()
	end
end
