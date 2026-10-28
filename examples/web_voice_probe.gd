extends Node

## Voice in a browser: the page's half of tools/web_voice_check.mjs.
##
## Connects to `?ws=ws://host:port`, asks for the microphone on the first press of V via [method DotVoiceManager.update_talk] (the check counts `getUserMedia` calls), and prints one `VOICEPROBE {json}` line a second.

var _ws := WebSocketPeer.new()
var _talker: DotVoiceManager = null
var _listener: DotVoiceManager = null
var _heard := DotVoiceSinkBuffer.new()
var _speakers: Array[int] = []
var _last_report := 0
var _press_error := ""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	var url := "ws://127.0.0.1:47380"
	var from_page: Variant = JavaScriptBridge.eval("new URLSearchParams(location.search).get('ws') || ''", true)
	if from_page is String and from_page != "":
		url = from_page
	var _e := _ws.connect_to_url(url)

	var config := DotVoiceConfig.new()
	config.push_to_talk = true

	_talker = DotVoiceManager.new()
	_talker.name = "Talker"
	_talker.config = config
	_talker.config_file = ""
	_talker.register_service = false
	_talker.send_fn = func(b: PackedByteArray) -> void:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var _s := _ws.send(b)
	add_child(_talker)

	_listener = DotVoiceManager.new()
	_listener.name = "Listener"
	_listener.config = config
	_listener.config_file = ""
	_listener.register_service = false
	_heard.sample_rate = config.sample_rate
	_listener.sink_factory = func(speaker: int) -> DotVoiceSink:
		_speakers.append(speaker)
		var player := DotVoiceSinkPlayer.new(_listener, config.sample_rate)
		return Tee.new(player, _heard)
	add_child(_listener)
	DotVoiceManager.ensure_talk_action()
	print("VOICEPROBE {\"ready\": true, \"url\": \"%s\"}" % url)


func _process(_delta: float) -> void:
	_ws.poll()
	while _ws.get_available_packet_count() > 0:
		var _p := _listener.receive(_ws.get_packet())

	var pressed := _talker.update_talk(DotVoiceManager.is_talk_held())
	if not pressed.ok:
		_press_error = pressed.error.message

	var now := Time.get_ticks_msec()
	if now - _last_report >= 1000:
		_last_report = now
		print("VOICEPROBE " + JSON.stringify({
			"socket": _ws.get_ready_state(),
			"driver": AudioServer.get_driver_name(),
			"mix_rate": AudioServer.get_mix_rate(),
			"capturing": _talker.is_capturing(),
			"captured": _talker.frames_captured,
			"sent": _talker.frames_sent,
			"received": _listener.frames_received,
			"speakers": _speakers,
			"heard_rms": _heard.rms(),
			"heard_frames": _heard.frames_written,
			"press_error": _press_error,
		}))


class Tee:
	extends DotVoiceSink
	var a: DotVoiceSink
	var b: DotVoiceSink
	func _init(p_a: DotVoiceSink, p_b: DotVoiceSink) -> void:
		a = p_a
		b = p_b
	func start() -> DotResult:
		var s := a.start()
		var _t := b.start()
		return s
	func stop() -> void:
		a.stop()
		b.stop()
	func is_running() -> bool:
		return a.is_running()
	func can_accept(n: int) -> bool:
		return a.can_accept(n)
	func write_frame(frame: PackedFloat32Array) -> void:
		a.write_frame(frame)
		b.write_frame(frame)
