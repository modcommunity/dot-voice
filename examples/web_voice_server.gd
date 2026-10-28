extends SceneTree

## The server half of tools/web_voice_check.mjs: a [DotVoiceRouter] behind a WebSocket listener, and a native bot talking a 300 Hz tone, recording what the browser says. Prints `SERVER {json}` once a second.
##
## Run: godot --headless --path . --script examples/web_voice_server.gd -- --port 47380 --seconds 30

var _server := TCPServer.new()
var _router: DotVoiceRouter = null
var _peers: Dictionary = {}   # id -> WebSocketPeer
var _next_id := 1_900_000_001
var _bot_ws := WebSocketPeer.new()
var _bot_talker: DotVoiceManager = null
var _bot_listener: DotVoiceManager = null
var _bot_mic := DotVoiceSourceBuffer.new()
var _bot_heard := DotVoiceSinkBuffer.new()
var _bot_speakers: Array[int] = []
var _ends_at := 0
var _last := 0
var _started := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	var args := OS.get_cmdline_user_args()
	var port := 47380
	var seconds := 30
	for i in range(args.size() - 1):
		if args[i] == "--port":
			port = int(args[i + 1])
		elif args[i] == "--seconds":
			seconds = int(args[i + 1])
	if _server.listen(port, "0.0.0.0") != OK:
		print("SERVER {\"error\": \"port %d busy\"}" % port)
		quit(6)
		return
	_ends_at = Time.get_ticks_msec() + seconds * 1000
	var _e := _bot_ws.connect_to_url("ws://127.0.0.1:%d" % port)


func _start_nodes() -> void:
	var config := DotVoiceConfig.new()
	_router = DotVoiceRouter.new()
	_router.config = config
	_router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		var ws: WebSocketPeer = _peers.get(peer)
		if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var _s := ws.send(bytes)
	root.add_child(_router)

	_bot_talker = DotVoiceManager.new()
	_bot_talker.config = config
	_bot_talker.config_file = ""
	_bot_talker.register_service = false
	_bot_mic.sample_rate = config.sample_rate
	_bot_talker.source = _bot_mic
	_bot_talker.send_fn = func(b: PackedByteArray) -> void:
		if _bot_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var _s := _bot_ws.send(b)
	root.add_child(_bot_talker)

	_bot_listener = DotVoiceManager.new()
	_bot_listener.config = config
	_bot_listener.config_file = ""
	_bot_listener.register_service = false
	_bot_heard.sample_rate = config.sample_rate
	_bot_listener.sink_factory = func(speaker: int) -> DotVoiceSink:
		_bot_speakers.append(speaker)
		return _bot_heard
	root.add_child(_bot_listener)
	_started = true


func _process(delta: float) -> bool:
	if not _started:
		_start_nodes()

	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		var _e := ws.accept_stream(_server.take_connection())
		_peers[_next_id] = ws
		_router.add_peer(_next_id)
		_next_id += 1

	for id in _peers:
		var ws: WebSocketPeer = _peers[id]
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var _r := _router.relay(int(id), ws.get_packet())

	_bot_ws.poll()
	while _bot_ws.get_available_packet_count() > 0:
		var _p := _bot_listener.receive(_bot_ws.get_packet())

	# The bot talks continuously, at real time: delta's worth of tone a frame.
	if _bot_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _bot_talker.is_capturing():
			var _t := _bot_talker.update_talk(true)
		var n := int(delta * float(_bot_mic.sample_rate))
		if n > 0:
			_bot_mic.write(DotVoiceSourceBuffer.tone(300.0, float(n) / float(_bot_mic.sample_rate), _bot_mic.sample_rate, 0.4))
		var _h := _bot_talker.update_talk(true)

	var now := Time.get_ticks_msec()
	if now - _last >= 1000:
		_last = now
		print("SERVER " + JSON.stringify({
			"peers": _peers.size(),
			"relayed": _router.relayed_packets,
			"bot_sent": _bot_talker.frames_sent,
			"bot_received": _bot_listener.frames_received,
			"bot_speakers": _bot_speakers,
			"bot_heard_rms": _bot_heard.rms(),
		}))
	return now >= _ends_at
