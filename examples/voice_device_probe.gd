extends Node

## The device layer the headless suite cannot reach, on a real audio device (tools/voice_device_probe.sh, under xvfb-run).
##
## Runs [DotVoiceSourceMicrophone] and [DotVoiceSinkPlayer] with the router and two clients over WebSockets on 127.0.0.1, playing a tone into the capture bus ([member DotVoiceSourceMicrophone.input_stream]) because ALSA has no input. It measures the far-end pitch, not only loudness: a wrong mix rate is loud but chipmunk. Exit 0 heard, 1 silent or wrong, 2 no audio device.

const TONE_HZ := 440.0
const SECONDS := 3.0

var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _run() -> void:
	var driver := AudioServer.get_driver_name()
	print("dot-voice device probe  driver=%s  mix_rate=%d" % [driver, int(AudioServer.get_mix_rate())])
	if driver == "Dummy":
		print("no audio device: run this through tools/voice_device_probe.sh (xvfb-run), not --headless")
		get_tree().quit(2)
		return

	var config := DotVoiceConfig.new()
	config.push_to_talk = true

	# The wire: a WebSocket server and two clients, as a browser would connect.
	var server := TCPServer.new()
	var port := 0
	for candidate in range(47_340, 47_360):
		if server.listen(candidate, "127.0.0.1") == OK:
			port = candidate
			break
	var clients: Array[WebSocketPeer] = [WebSocketPeer.new(), WebSocketPeer.new()]
	for c in clients:
		var _e := c.connect_to_url("ws://127.0.0.1:%d" % port)
	var accepted: Array[WebSocketPeer] = []
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		while server.is_connection_available():
			var ws := WebSocketPeer.new()
			var _e := ws.accept_stream(server.take_connection())
			accepted.append(ws)
		var open := 0
		for ws in accepted:
			ws.poll()
			open += 1 if ws.get_ready_state() == WebSocketPeer.STATE_OPEN else 0
		for c in clients:
			c.poll()
			open += 1 if c.get_ready_state() == WebSocketPeer.STATE_OPEN else 0
		if open == 4:
			break
		await get_tree().process_frame
	_check(accepted.size() == 2, "two clients connect over WebSocket")
	if accepted.size() != 2:
		get_tree().quit(1)
		return

	var ids: Array[int] = [1_900_000_001, 2_000_000_002]
	var by_id := {ids[0]: accepted[0], ids[1]: accepted[1]}
	var router := DotVoiceRouter.new()
	router.config = config
	router.max_bytes_per_second = 0
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void: var _e: int = (by_id[peer] as WebSocketPeer).send(bytes)
	add_child(router)
	for id in ids:
		router.add_peer(id)

	# The talker: the real capture path, fed a tone instead of a microphone.
	var talker := DotVoiceManager.new()
	talker.name = "Talker"
	talker.config = config
	talker.config_file = ""
	talker.register_service = false
	add_child(talker)
	var mic := DotVoiceSourceMicrophone.new(talker, config.sample_rate)
	mic.input_stream = _tone_stream(TONE_HZ, int(AudioServer.get_mix_rate()))
	talker.source = mic
	talker.send_fn = func(b: PackedByteArray) -> void: var _e := clients[0].send(b)

	# The listener: the real player sink, with a recorder beside it.
	var listener := DotVoiceManager.new()
	listener.name = "Listener"
	listener.config = config
	listener.config_file = ""
	listener.register_service = false
	add_child(listener)
	var players: Array[DotVoiceSinkPlayer] = []
	var heard := DotVoiceSinkBuffer.new()
	heard.sample_rate = config.sample_rate
	listener.sink_factory = func(_speaker: int) -> DotVoiceSink:
		var player := DotVoiceSinkPlayer.new(listener, config.sample_rate)
		players.append(player)
		return Tee.new(player, heard)
	await get_tree().process_frame

	var pressed := talker.update_talk(true)
	_check(pressed.ok, "the talk key opens the capture path (%s)" % ("ok" if pressed.ok else str(pressed.error)))

	var started := Time.get_ticks_msec()
	var playing_seen := false
	while Time.get_ticks_msec() - started < int(SECONDS * 1000.0):
		for c in clients:
			c.poll()
		for id in by_id:
			var ws: WebSocketPeer = by_id[id]
			ws.poll()
			while ws.get_available_packet_count() > 0:
				var _r := router.relay(int(id), ws.get_packet())
		while clients[1].get_available_packet_count() > 0:
			var _p := listener.receive(clients[1].get_packet())
		while clients[0].get_available_packet_count() > 0:
			var _d := clients[0].get_packet()
		for p in players:
			if p._player != null and bool(p._player.get(&"playing")):
				playing_seen = true
		await get_tree().process_frame

	var _t := talker.update_talk(false)
	var seconds := SECONDS
	_check(talker.frames_captured > int(seconds * 25.0), "the capture bus delivered audio in real time (%d frames in %.0f s)" % [talker.frames_captured, seconds])
	_check(talker.frames_sent > int(seconds * 25.0), "and the gate sent it (%d frames)" % talker.frames_sent)
	_check(listener.frames_received > int(seconds * 25.0), "the other client received it over the socket (%d)" % listener.frames_received)
	_check(players.size() == 1 and playing_seen, "a generator player was playing on the device")
	var consumed := players.size() == 1 and players[0]._playback != null and players[0]._playback.get_frames_available() > 0
	_check(consumed, "and the driver was draining it")
	_check(heard.rms() > 0.1, "what played is the tone, not silence (%.3f rms)" % heard.rms())
	var hz := _pitch(heard.samples, config.sample_rate)
	_check(absf(hz - TONE_HZ) < TONE_HZ * 0.05, "at the pitch it was captured at (%.1f Hz, sent %.0f Hz)" % [hz, TONE_HZ])

	for c in clients:
		c.close()
	server.stop()
	print("%s" % ("all heard" if _failed == 0 else "%d failed" % _failed))
	get_tree().quit(1 if _failed > 0 else 0)


## A looping sine at the engine's mix rate, 16-bit, played into the capture bus.
static func _tone_stream(hz: float, rate: int) -> AudioStreamWAV:
	var samples := rate  # one second, a whole number of cycles at 440 Hz and 44.1/48 kHz
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in range(samples):
		var v := int(sin(TAU * hz * float(i) / float(rate)) * 0.4 * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = samples
	return wav


## Frequency by rising zero crossings over the loudest stretch.
static func _pitch(samples: PackedFloat32Array, rate: int) -> float:
	var crossings := 0
	var first := -1
	var last := -1
	for i in range(1, samples.size()):
		if samples[i - 1] < 0.0 and samples[i] >= 0.0 and absf(samples[i] - samples[i - 1]) > 0.01:
			crossings += 1
			if first < 0:
				first = i
			last = i
	if crossings < 2:
		return 0.0
	return float(crossings - 1) * float(rate) / float(last - first)


## Plays through one sink and records through another.
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
