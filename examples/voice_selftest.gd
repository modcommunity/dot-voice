extends "res://examples/voice_selftest_mid.gd"

## Proves the voice path end to end without a microphone, a speaker or a socket; exits non-zero on any failure.
##
## Run: godot --headless --path . res://examples/voice_selftest.tscn. [DotVoiceSourceBuffer] and [DotVoiceSinkBuffer] stand in for the devices, so the gate, codec, wire, router and jitter buffer run the code a player runs. The device layer is the gap (last section).

const CHECKS := 189



func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-voice self-test")

	_test_config()
	_test_codec_round_trip()
	_test_codec_independence()
	_test_packet_round_trip()
	_test_packet_refusals()
	_test_sequence_wrap()
	_test_gate_push_to_talk()
	_test_gate_activation()
	_test_jitter_ordering()
	_test_jitter_loss_and_overflow()
	await _test_end_to_end()
	await _test_router()
	await _test_server_switch()
	await _test_talk_key_opens_the_microphone()
	await _test_over_a_real_socket()
	_test_proximity_math()
	await _test_proximity_two_clients()
	_test_look_mute()
	_test_device_layer_is_not_covered()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)



func _test_talk_key_opens_the_microphone() -> void:
	_section("the first press of the talk key is where the microphone opens")

	var config := _config()
	var talker := DotVoiceManager.new()
	talker.name = "Presser"
	talker.config = config
	talker.config_file = ""
	talker.register_service = false
	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = config.sample_rate
	mic.loop = true
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, config.sample_rate, 0.4))
	talker.source = mic
	var sent: Array[int] = []
	talker.send_fn = func(b: PackedByteArray) -> void: sent.append(b.size())
	add_child(talker)
	for _i in range(5):
		await get_tree().process_frame

	_check(not talker.is_capturing() and not mic.is_running(),
		"nothing is captured before the key is pressed",
		"a browser asks for the microphone the moment a page opens it")

	var pressed := talker.update_talk(true)
	_check(pressed.ok and talker.is_capturing(), "the first press opens it")
	for _i in range(10):
		await get_tree().process_frame
	_check(sent.size() > 0, "and speech goes out while it is held (%d frames)" % sent.size())

	var _t := talker.update_talk(false)
	for _i in range(3):
		await get_tree().process_frame
	var before := sent.size()
	for _i in range(10):
		await get_tree().process_frame
	_check(sent.size() == before, "released, nothing more goes (%d new)" % (sent.size() - before))

	# Open mic: the gate opens on level, and the press already happened.
	talker.set_open_mic(true)
	for _i in range(10):
		await get_tree().process_frame
	_check(sent.size() > before and talker.open_mic, "open mic sends with no key held (%d new)" % (sent.size() - before))
	talker.set_open_mic(false)

	# A refusal is returned once a press, not every frame.
	var nothing := DotVoiceManager.new()
	nothing.name = "NoMic"
	nothing.config = _config()
	nothing.config_file = ""
	nothing.register_service = false
	add_child(nothing)
	await get_tree().process_frame
	var first := nothing.update_talk(true)
	var second := nothing.update_talk(true)
	_check(not first.ok and second.ok and not nothing.is_capturing(),
		"no microphone: the first frame of a press says why, the rest of it is quiet",
		str(first.error) if not first.ok else "first press succeeded")

	talker.queue_free()
	nothing.queue_free()
	await get_tree().process_frame
	_done()


## Two clients and a router over real WebSockets on 127.0.0.1, the wire a browser uses.
##
## Covers full-width peer ids ([url=docs/history.md]history[/url]), a frame crossing process-level peers, and the server's switch both ways.
func _test_over_a_real_socket() -> void:
	_section("two clients over a real socket hear each other")

	var config := _config()
	var server := TCPServer.new()
	var port := 0
	for candidate in range(47_310, 47_330):
		if server.listen(candidate, "127.0.0.1") == OK:
			port = candidate
			break
	if not _check(port != 0, "a WebSocket port is free on 127.0.0.1"):
		_done()
		return

	var router := DotVoiceRouter.new()
	router.name = "SocketRouter"
	router.config = config
	# A looping buffer source runs faster than real time; the rate limit is another section's.
	router.max_bytes_per_second = 0
	add_child(router)

	# Server side: peer id -> WebSocketPeer. Ids full width, the way Godot hands them out.
	var ids: Array[int] = [1_900_000_001, 2_000_000_002]
	var server_peers: Dictionary = {}
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		var ws: WebSocketPeer = server_peers.get(peer)
		if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var _e := ws.send(bytes)

	var clients: Array[WebSocketPeer] = []
	for _i in range(2):
		var c := WebSocketPeer.new()
		var _e := c.connect_to_url("ws://127.0.0.1:%d" % port)
		clients.append(c)

	var pending: Array[WebSocketPeer] = []
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		while server.is_connection_available():
			var ws := WebSocketPeer.new()
			var _e := ws.accept_stream(server.take_connection())
			pending.append(ws)
		for ws in pending:
			ws.poll()
		for c in clients:
			c.poll()
		var open := 0
		for c in clients:
			if c.get_ready_state() == WebSocketPeer.STATE_OPEN:
				open += 1
		var accepted := 0
		for ws in pending:
			if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				accepted += 1
		if open == 2 and accepted == 2:
			break
		await get_tree().process_frame

	# Accept order is connect order on one loopback, but the test does not lean on it: the
	# first frame each sends says who it is.
	if not _check(pending.size() == 2, "both clients connect (%d)" % pending.size()):
		router.queue_free()
		server.stop()
		_done()
		return
	for i in range(2):
		server_peers[ids[i]] = pending[i]
		router.add_peer(ids[i])

	var talker := DotVoiceManager.new()
	talker.name = "SocketTalker"
	talker.config = config
	talker.config_file = ""
	talker.register_service = false
	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = config.sample_rate
	mic.loop = true
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, config.sample_rate, 0.4))
	talker.source = mic
	talker.send_fn = func(b: PackedByteArray) -> void: var _e := clients[0].send(b)
	add_child(talker)

	var listener := DotVoiceManager.new()
	listener.name = "SocketListener"
	listener.config = config
	listener.config_file = ""
	listener.register_service = false
	var heard := DotVoiceSinkBuffer.new()
	heard.sample_rate = config.sample_rate
	var speakers: Array[int] = []
	listener.sink_factory = func(speaker: int) -> DotVoiceSink:
		speakers.append(speaker)
		return heard
	add_child(listener)
	await get_tree().process_frame

	# One frame of the loop: poll every socket, relay what the server got, play what B got.
	var pump := func(frames: int) -> void:
		for _f in range(frames):
			for c in clients:
				c.poll()
			for id in server_peers:
				var ws: WebSocketPeer = server_peers[id]
				ws.poll()
				while ws.get_available_packet_count() > 0:
					var _r := router.relay(int(id), ws.get_packet())
			clients[1].poll()
			while clients[1].get_available_packet_count() > 0:
				var _p := listener.receive(clients[1].get_packet())
			while clients[0].get_available_packet_count() > 0:
				var _drop := clients[0].get_packet()
			await get_tree().process_frame

	var _t := talker.update_talk(true)
	await pump.call(40)

	_check(talker.frames_sent > 10, "the talker sends frames (%d)" % talker.frames_sent)
	_check(listener.frames_received > 10, "the other client receives them over the socket (%d)" % listener.frames_received)
	_check(speakers == [ids[0]], "as the full-width id of who spoke (%s)" % str(speakers))
	_check(heard.rms() > 0.1, "and plays the tone, not silence (%.3f rms)" % heard.rms())

	# The operator turns it off mid-sentence. Armed by the frames above.
	var during := listener.frames_received
	router.enabled = false
	await pump.call(15)
	var leaked := listener.frames_received - during
	_check(leaked <= 2, "sv_voice_enable 0: nothing more arrives (%d in flight)" % leaked)
	router.enabled = true
	during = listener.frames_received
	await pump.call(20)
	_check(listener.frames_received - during > 5, "and 1: speech arrives again (%d)" % (listener.frames_received - during))

	_t = talker.update_talk(false)
	for c in clients:
		c.close()
	for id in server_peers:
		(server_peers[id] as WebSocketPeer).close()
	server.stop()
	talker.queue_free()
	listener.queue_free()
	router.queue_free()
	await get_tree().process_frame
	_done()


func _test_proximity_math() -> void:
	_section("proximity gain curves and the packet's gain bits")

	for falloff in [0, 1, 2]:
		var name: String = ["linear", "inverse", "quadratic"][falloff]
		_check(is_equal_approx(DotVoiceProximity.gain(1.0, 40.0, 2.0, falloff), 1.0), "%s: full volume inside the minimum distance" % name)
		_check(DotVoiceProximity.gain(40.0, 40.0, 2.0, falloff) == 0.0, "%s: silent at the radius" % name)
		var last := 1.0
		var monotonic := true
		for d in range(3, 40):
			var g := DotVoiceProximity.gain(float(d), 40.0, 2.0, falloff)
			if g > last + 0.0001:
				monotonic = false
			last = g
		_check(monotonic, "%s: never gets louder with distance" % name)
	_check(is_equal_approx(DotVoiceProximity.gain(21.0, 40.0, 2.0, 0), 0.5), "linear: halfway is half")
	_check(
		DotVoiceProximity.gain(10.0, 40.0, 2.0, 2) < DotVoiceProximity.gain(10.0, 40.0, 2.0, 0),
		"quadratic is quieter than linear at the same distance"
	)

	var packet := DotVoicePacket.new()
	packet.sample_count = 480
	packet.payload = PackedByteArray([1, 2, 3])
	packet.starts_talk_spurt = true
	packet.gain = 0.5
	var back: DotVoicePacket = DotVoicePacket.from_bytes(packet.to_bytes()).value
	_check(absf(back.gain - 0.5) < 0.01 and back.starts_talk_spurt, "a gain survives the wire beside the start flag", str(back.gain))
	packet.gain = 1.0
	_check(
		(DotVoicePacket.from_bytes(packet.to_bytes()).value as DotVoicePacket).gain == 1.0,
		"no gain bits means full volume"
	)
	_done()


func _test_proximity_two_clients() -> void:
	_section("proximity: volume falls with distance and nothing is sent beyond the radius")

	var config := _config()
	var router := DotVoiceRouter.new()
	router.name = "ProxRouter"
	router.config = config
	router.max_bytes_per_second = 0
	router.default_channel = DotVoiceRouter.Channel.PROXIMITY
	router.proximity_range = 40.0
	router.proximity_min_distance = 2.0
	router.proximity_falloff = DotVoiceProximity.Falloff.LINEAR
	add_child(router)

	var talker_id := 111_111_111
	var positions := {talker_id: Vector3.ZERO, 222: Vector3(5, 0, 0), 333: Vector3(30, 0, 0), 444: Vector3(60, 0, 0)}
	router.position_fn = func(peer: int) -> Variant: return positions.get(peer)
	for id in positions:
		router.add_peer(int(id))

	var listeners: Dictionary = {}
	var heard: Dictionary = {}
	for id in [222, 333, 444]:
		var m := DotVoiceManager.new()
		m.name = "ProxListener%d" % id
		m.config = config
		m.config_file = ""
		m.register_service = false
		var sink := DotVoiceSinkBuffer.new()
		sink.sample_rate = config.sample_rate
		heard[id] = sink
		# The factory is set before the manager is in the tree, so no speaker can exist
		# without it (the order a sink that hears silence would come from).
		m.sink_factory = func(_speaker: int) -> DotVoiceSink: return sink
		listeners[id] = m
		add_child(m)
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		var _r: bool = (listeners[peer] as DotVoiceManager).receive(bytes)

	var talker := DotVoiceManager.new()
	talker.name = "ProxTalker"
	talker.config = config
	talker.config_file = ""
	talker.register_service = false
	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = config.sample_rate
	talker.source = mic
	var first_frame: Array[PackedByteArray] = []
	talker.send_fn = func(bytes: PackedByteArray) -> void:
		if first_frame.is_empty():
			first_frame.append(bytes)
		var _r := router.relay(talker_id, bytes)
	add_child(talker)
	await get_tree().process_frame

	var _s := talker.start_capture()
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.6, config.sample_rate, 0.4))
	talker.set_talking(true)
	for _i in range(45):
		await get_tree().process_frame

	var near: float = (heard[222] as DotVoiceSinkBuffer).rms()
	var far: float = (heard[333] as DotVoiceSinkBuffer).rms()
	_check(talker.frames_sent > 10, "the talker sends frames (%d)" % talker.frames_sent)
	_check(near > 0.05 and far > 0.01, "both listeners in range hear it (%.3f, %.3f)" % [near, far])
	_check(near > far * 2.0, "the near one is louder (%.3f vs %.3f)" % [near, far])
	# Linear, min 2, radius 40: 5 m is 0.921, 30 m is 0.263; ratio 0.286.
	var ratio := far / maxf(near, 0.0001)
	_check(absf(ratio - 0.286) < 0.06, "and by the cvars' curve (ratio %.3f, expected 0.286)" % ratio)
	_check(
		(listeners[444] as DotVoiceManager).frames_received == 0,
		"beyond the radius, no frame is sent at all (%d)" % (listeners[444] as DotVoiceManager).frames_received
	)
	_check(
		(listeners[222] as DotVoiceManager).frames_received == talker.frames_sent,
		"inside it every frame is (%d of %d)" % [(listeners[222] as DotVoiceManager).frames_received, talker.frames_sent]
	)

	# The cvars move the curve, not just the constants.
	var got: Array[float] = []
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		if peer == 333:
			got.append((DotVoicePacket.from_bytes(bytes).value as DotVoicePacket).gain)
	var frame: PackedByteArray = first_frame[0]
	var _r := router.relay(talker_id, frame)
	_check(got.size() == 1 and absf(got[0] - 0.263) < 0.02, "30 m gets 0.263 (%s)" % str(got))
	_check(router.set_cvar("sv_voice_proximity_range", "100"), "sv_voice_proximity_range applies")
	_check(router.set_cvar("sv_voice_proximity_min", "10"), "sv_voice_proximity_min applies")
	_check(router.set_cvar("sv_voice_proximity_falloff", "2"), "sv_voice_proximity_falloff applies")
	got.clear()
	_r = router.relay(talker_id, frame)
	var expected := pow(1.0 - (30.0 - 10.0) / 90.0, 2.0)
	_check(got.size() == 1 and absf(got[0] - expected) < 0.02, "range 100, min 10, quadratic: 30 m is %.3f (%s)" % [expected, str(got)])

	# A client's own gain bits are the server's to set, not the talker's.
	var cheat := frame.duplicate()
	cheat.encode_u8(DotVoicePacket.OFFSET_FLAGS, cheat.decode_u8(DotVoicePacket.OFFSET_FLAGS) | DotVoicePacket.gain_bits(0.05))
	router.set_cvar("sv_voice_proximity_range", "40")
	router.set_cvar("sv_voice_proximity_min", "40")
	router.set_cvar("sv_voice_proximity_falloff", "0")
	positions[333] = Vector3(1, 0, 0)
	got.clear()
	_r = router.relay(talker_id, cheat)
	_check(got.size() == 1 and got[0] == 1.0, "a talker cannot set their own gain (%s)" % str(got))

	# Occlusion: a wall turns the voice down; off, the same wall is ignored.
	router.occlusion_fn = func(_l: Vector3, _s: Vector3) -> bool: return true
	got.clear()
	_r = router.relay(talker_id, frame)
	_check(got == [1.0], "occlusion off: the wall is ignored")
	router.set_cvar("sv_voice_proximity_occlusion", "1")
	router.set_cvar("sv_voice_proximity_occlusion_gain", "0.5")
	got.clear()
	_r = router.relay(talker_id, frame)
	_check(got.size() == 1 and absf(got[0] - 0.5) < 0.01, "occlusion on: half volume through the wall (%s)" % str(got))
	router.set_cvar("sv_voice_proximity_occlusion_gain", "0")
	got.clear()
	_r = router.relay(talker_id, frame)
	_check(got.is_empty(), "occlusion gain 0: nothing is sent through a wall")

	# Team and global channels bypass or not, per cvar, with a client that picks its channel.
	router.proximity_occlusion = false
	router.honour_packet_channel = true
	router.team_fn = func(_p: int) -> int: return 1
	var team_frame := frame.duplicate()
	team_frame.encode_u8(DotVoicePacket.OFFSET_CHANNEL, DotVoiceRouter.Channel.TEAM)
	var all_frame := frame.duplicate()
	all_frame.encode_u8(DotVoicePacket.OFFSET_CHANNEL, DotVoiceRouter.Channel.ALL)
	var counted: Array[int] = []
	router.send_fn = func(peer: int, _b: PackedByteArray) -> void: counted.append(peer)
	_r = router.relay(talker_id, team_frame)
	_check(counted.size() == 4 - 1, "team bypass on: a team packet reaches the whole team, any distance (%d)" % counted.size())
	counted.clear()
	router.set_cvar("sv_voice_proximity_team_bypass", "0")
	_r = router.relay(talker_id, team_frame)
	_check(not counted.has(444), "team bypass off: a team packet is range-limited (%s)" % str(counted))
	counted.clear()
	_r = router.relay(talker_id, all_frame)
	_check(not counted.has(444), "global bypass off (default): the everybody channel is range-limited too")
	counted.clear()
	router.set_cvar("sv_voice_proximity_global_bypass", "1")
	_r = router.relay(talker_id, all_frame)
	_check(counted.has(444), "global bypass on: a global shout reaches past the radius")

	talker.set_talking(false)
	talker.queue_free()
	for id in listeners:
		(listeners[id] as Node).queue_free()
	router.queue_free()
	await get_tree().process_frame
	_done()


func _test_look_mute() -> void:
	_section("look at a player: tap gags, double-tap mutes, both rebindable")

	var config := _config()
	var manager := DotVoiceManager.new()
	manager.config = config
	manager.config_file = ""
	manager.register_service = false
	add_child(manager)

	var look := DotVoiceLookMute.new()
	look.manager = manager
	var target := [7]
	look.target_fn = func() -> int: return target[0]
	var chat_calls: Array = []
	look.chat_mute_fn = func(peer: int, on: bool) -> void: chat_calls.append([peer, on])
	add_child(look)

	look.tap(1000)
	_check(look.is_gagged(7) and not look.is_muted(7), "a tap gags")
	look.tap(2000)
	_check(not look.is_gagged(7), "a later tap un-gags")
	look.tap(5000)
	look.tap(5200)
	_check(look.is_muted(7) and not look.is_gagged(7), "a double-tap mutes and leaves no gag behind")
	_check(chat_calls == [[7, true]], "and mutes chat through chat_mute_fn")
	_check(manager.local_mutes.has(7), "voice is muted on the manager")
	look.tap(9000)
	look.tap(9100)
	_check(not look.is_muted(7) and chat_calls.back() == [7, false], "double-tap again un-mutes")

	target[0] = 8
	look.tap(12000)
	target[0] = 9
	look.tap(12100)
	_check(look.is_gagged(8) and look.is_gagged(9) and not look.is_muted(9), "taps on two different players are not a double-tap")
	target[0] = 0
	look.tap(13000)
	_check(look.is_gagged(8), "looking at nobody does nothing")
	target[0] = 8

	# A gagged speaker's frames are dropped; the others' are not.
	var packet := DotVoicePacket.new()
	packet.speaker = 8
	packet.sample_count = config.frame_samples()
	packet.payload = PackedByteArray([0, 0, 0, 0])
	var _r := manager.receive(packet.to_bytes())
	_check(manager.active_speakers().is_empty() and manager.describe()["speakers"] == 0, "a gagged speaker's voice is not played")
	look.set_gag(8, false)
	_check(not manager.is_gagged(8), "un-gag restores them")

	# Separate keys: the gag key never mutes, the mute key never gags.
	look.separate_keys = true
	target[0] = 20
	look.tap(20000)
	look.tap(20100)
	_check(not look.is_gagged(20) and not look.is_muted(20), "separate keys: two quick gag taps just toggle twice")
	look.tap(21000, true)
	_check(look.is_muted(20) and not look.is_gagged(20), "separate keys: the mute key mutes")

	# Both are InputMap actions, so a key table can rebind them.
	DotVoiceLookMute.ensure_actions()
	_check(InputMap.has_action(DotVoiceLookMute.GAG_ACTION) and InputMap.has_action(DotVoiceLookMute.MUTE_ACTION), "both keys are InputMap actions")
	InputMap.action_erase_events(DotVoiceLookMute.GAG_ACTION)
	var rebound := InputEventKey.new()
	rebound.physical_keycode = KEY_B
	InputMap.action_add_event(DotVoiceLookMute.GAG_ACTION, rebound)
	var press := InputEventKey.new()
	press.physical_keycode = KEY_B
	press.pressed = true
	look.separate_keys = false
	target[0] = 30
	look._unhandled_input(press)
	_check(look.is_gagged(30), "a rebound gag key gags")
	InputMap.action_erase_events(DotVoiceLookMute.GAG_ACTION)
	var home := InputEventKey.new()
	home.physical_keycode = DotVoiceLookMute.DEFAULT_GAG_KEY
	InputMap.action_add_event(DotVoiceLookMute.GAG_ACTION, home)

	# Server side: allowed and default are cvars.
	_check(look.set_cvar(DotVoiceLookMute.CVAR_GAG_ALLOWED, "0"), "sv_voice_gag_allowed applies")
	target[0] = 40
	look.tap(30000)
	_check(not look.is_gagged(40), "gag not allowed: a tap does nothing")
	look.tap(40000)
	look.tap(40100)
	_check(look.is_muted(40), "but a double-tap still mutes when mute is allowed")
	look.set_cvar(DotVoiceLookMute.CVAR_MUTE_ALLOWED, "0")
	target[0] = 41
	look.tap(50000)
	look.tap(50100)
	_check(not look.is_muted(41), "mute not allowed: no mute")
	look.set_cvar(DotVoiceLookMute.CVAR_GAG_DEFAULT, "1")
	_check(manager.is_gagged(500) and not manager.is_gagged(8), "gag default: strangers start gagged, anyone un-gagged stays heard")

	look.queue_free()
	manager.queue_free()
	_done()


## The honest gap: everything above runs with no audio device in the process.
##
## [DotVoiceSourceMicrophone] and [DotVoiceSinkPlayer] are covered by nothing here (a headless run has no driver); see tools/voice_device_probe.sh.
func _test_device_layer_is_not_covered() -> void:
	_section("what this suite does not cover")

	var supported := DotVoiceSourceMicrophone.is_supported()

	_check(
		not supported.ok,
		"a headless run has no microphone, and says so rather than pretending",
		str(supported.error) if supported.ok else ""
	)
	_check(
		supported.error != null and supported.error.code == DotError.CODE_UNSUPPORTED,
		"as CODE_UNSUPPORTED, which a host can branch on"
	)

	print("  note  DotVoiceSourceMicrophone and DotVoiceSinkPlayer are NOT covered here.")
	print("        They need an audio device: tools/voice_device_probe.sh runs both under")
	print("        Xvfb on a real ALSA device, with a tone played into the capture bus.")
	_done()
