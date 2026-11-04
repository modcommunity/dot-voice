extends "res://examples/voice_selftest_base.gd"

## Middle layer of the voice self-test: end to end, router and server switch.


func _test_end_to_end() -> void:
	_section("a whole voice path, with no audio device in the process")

	var config := _config()

	# The speaker's half.
	var talker := DotVoiceManager.new()
	talker.name = "Talker"
	talker.config = config
	talker.config_file = ""
	talker.register_service = false
	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = config.sample_rate
	talker.source = mic

	# The listener's half, in the same process, with its own buffers.
	var listener := DotVoiceManager.new()
	listener.name = "Listener"
	listener.config = config
	listener.config_file = ""
	listener.register_service = false

	var heard := DotVoiceSinkBuffer.new()
	heard.sample_rate = config.sample_rate
	listener.sink_factory = func(_speaker: int) -> DotVoiceSink: return heard

	# The wire, as a Callable. Nothing here knows what a socket is, which is the same
	# reason dot-net takes a send_fn.
	var on_wire: Array[PackedByteArray] = []
	talker.send_fn = func(bytes: PackedByteArray) -> void: on_wire.append(bytes)

	add_child(talker)
	add_child(listener)
	await get_tree().process_frame

	var started := talker.start_capture()
	if not _check(started.ok, "capture starts against a buffer source", str(started.error)):
		talker.queue_free()
		listener.queue_free()
		_done()
		return

	# Half a second of a tone, and the key held down.
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.5, config.sample_rate, 0.4))
	talker.set_talking(true)

	for _i in range(40):
		await get_tree().process_frame

	_check(talker.frames_sent > 0, "frames go on the wire (%d)" % talker.frames_sent)
	_check(on_wire.size() == talker.frames_sent, "one packet per frame")

	var expected := int(0.5 * 1000.0 / config.frame_ms)
	_check(
		absi(talker.frames_sent - expected) <= 2,
		"and roughly one per 20 ms of audio (%d, expected about %d)"
			% [talker.frames_sent, expected]
	)

	# A talk spurt has to be flagged on its first packet and nowhere else.
	var starts := 0
	for bytes in on_wire:
		var parsed := DotVoicePacket.from_bytes(bytes)
		if parsed.ok and (parsed.value as DotVoicePacket).starts_talk_spurt:
			starts += 1
	_check(starts == 1, "exactly one packet opens the spurt (%d)" % starts)

	# Deliver them, as a server would, with the speaker stamped.
	for bytes in on_wire:
		var parsed := DotVoicePacket.from_bytes(bytes)
		var packet: DotVoicePacket = parsed.value
		packet.speaker = 7
		listener.receive(packet.to_bytes())

	for _i in range(60):
		await get_tree().process_frame

	_check(
		listener.frames_received == on_wire.size(),
		"the listener took every packet (%d of %d)"
			% [listener.frames_received, on_wire.size()]
	)
	_check(
		heard.frames_written > 0,
		"and played audio out (%d frames)" % heard.frames_written
	)
	_check(
		heard.rms() > 0.1,
		"which is actually loud rather than silence (%.4f rms)" % heard.rms(),
		"a path that produces zeros passes every check that only counts frames"
	)
	_check(heard.peak() <= 1.0, "and does not clip (%.4f peak)" % heard.peak())

	# The listener's own preference, which is a different thing from a moderator's mute.
	heard.clear()
	listener.set_local_mute(7, true)
	for bytes in on_wire:
		var parsed := DotVoicePacket.from_bytes(bytes)
		var packet: DotVoicePacket = parsed.value
		packet.speaker = 7
		listener.receive(packet.to_bytes())
	for _i in range(20):
		await get_tree().process_frame
	_check(
		heard.frames_written == 0,
		"a locally muted speaker plays nothing (%d frames)" % heard.frames_written
	)

	listener.set_local_mute(7, false)
	_check(not listener.is_locally_muted(7), "and unmuting takes")

	# Releasing the key stops the traffic. A gate that only ever opens is a hot mic.
	var before := talker.frames_sent
	talker.set_talking(false)
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, config.sample_rate, 0.4))
	for _i in range(20):
		await get_tree().process_frame
	_check(
		talker.frames_sent == before,
		"nothing is sent once the key is released (%d new)"
			% (talker.frames_sent - before)
	)

	talker.stop_capture()
	_check(not talker.is_capturing(), "capture stops")

	talker.queue_free()
	listener.queue_free()
	await get_tree().process_frame
	_done()


func _test_router() -> void:
	_section("the server decides who hears whom")

	var config := _config()

	var router := DotVoiceRouter.new()
	router.name = "Router"
	router.config = config
	router.max_bytes_per_second = 0
	# These checks name each packet's channel; the game's own channel is the next section's.
	router.honour_packet_channel = true
	add_child(router)
	await get_tree().process_frame

	for peer in [1, 2, 3, 4]:
		router.add_peer(peer)

	var delivered: Array[Dictionary] = []
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		delivered.append({"peer": peer, "bytes": bytes})

	var codec := DotVoiceCodec.instance_for(&"adpcm")
	var frame := DotVoiceSourceBuffer.tone(300.0, 0.02, config.sample_rate, 0.4)

	var make := func(channel: int, claimed_speaker: int) -> PackedByteArray:
		var packet := DotVoicePacket.new()
		packet.speaker = claimed_speaker
		packet.sequence = 0
		packet.sample_count = config.frame_samples()
		packet.channel = channel
		packet.codec_id = &"adpcm"
		packet.payload = codec.encode(frame)
		return packet.to_bytes()

	# ALL reaches everybody except the speaker. Hearing yourself at a round trip's delay
	# is the single most disorienting thing a voice system can do.
	var relayed := router.relay(1, make.call(DotVoiceRouter.Channel.ALL, 1))
	_check(relayed.ok, "an ordinary packet relays", str(relayed.error))
	_check(delivered.size() == 3, "to everyone but the speaker (%d)" % delivered.size())

	var went_to_speaker := false
	for entry in delivered:
		if int(entry["peer"]) == 1:
			went_to_speaker = true
	_check(not went_to_speaker, "and never back to them")

	# The speaker id is stamped from the transport, never taken from the packet.
	# Otherwise any client can put words in any other player's mouth.
	delivered.clear()
	router.relay(2, make.call(DotVoiceRouter.Channel.ALL, 1))
	var claimed_ok := true
	for entry in delivered:
		var parsed := DotVoicePacket.from_bytes(entry["bytes"])
		if parsed.ok and (parsed.value as DotVoicePacket).speaker != 2:
			claimed_ok = false
	_check(
		claimed_ok,
		"a client cannot claim to be somebody else",
		"the router stamps the sender the transport reported"
	)

	# TEAM.
	delivered.clear()
	router.team_fn = func(peer: int) -> int: return 0 if peer <= 2 else 1
	router.relay(1, make.call(DotVoiceRouter.Channel.TEAM, 1))
	_check(delivered.size() == 1, "a team packet reaches the team (%d)" % delivered.size())
	_check(
		delivered.size() == 1 and int(delivered[0]["peer"]) == 2,
		"and only the team"
	)

	# A team channel with no way to tell teams apart reaches NOBODY rather than
	# everybody. A team channel that leaks to the other team is a competitive game broken
	# in a way nobody reports, because it sounds exactly like working.
	delivered.clear()
	router.team_fn = Callable()
	router.relay(1, make.call(DotVoiceRouter.Channel.TEAM, 1))
	_check(
		delivered.is_empty(),
		"with no team_fn it reaches nobody rather than everybody",
		"the safe half of an ambiguous configuration"
	)

	# PROXIMITY.
	delivered.clear()
	router.proximity_range = 10.0
	var places := {1: Vector3.ZERO, 2: Vector3(5, 0, 0), 3: Vector3(50, 0, 0),
				   4: Vector3(9, 0, 0)}
	router.position_fn = func(peer: int) -> Vector3: return places.get(peer, Vector3.ZERO)
	router.relay(1, make.call(DotVoiceRouter.Channel.PROXIMITY, 1))
	_check(delivered.size() == 2, "a proximity packet reaches the near (%d)" % delivered.size())
	var far_heard := false
	for entry in delivered:
		if int(entry["peer"]) == 3:
			far_heard = true
	_check(not far_heard, "and not the far")

	# [b]A range is not a room.[/b] The host stands a wall at x = 7: peer 2 at x = 5 is on
	# the speaker's side and peer 4 at x = 9 is not, though both are in range. Peer 3 is
	# out of range and must not even be asked about.
	delivered.clear()
	var asked: Array[int] = []
	router.can_hear_fn = func(listener: int, speaker: int, listener_at: Vector3, speaker_at: Vector3) -> bool:
		asked.append(listener)
		return speaker == 1 and (listener_at.x < 7.0) == (speaker_at.x < 7.0)
	router.relay(1, make.call(DotVoiceRouter.Channel.PROXIMITY, 1))
	_check(
		delivered.size() == 1 and int(delivered[0]["peer"]) == 2,
		"can_hear_fn takes out a listener the range let in (%d delivered)" % delivered.size()
	)
	_check(
		asked.size() == 2 and asked.has(2) and asked.has(4),
		"and is asked only about listeners in range (%s)" % str(asked)
	)
	router.can_hear_fn = Callable()

	# Muting, on the server, where it cannot be ignored by the person being muted.
	delivered.clear()
	router.set_muted(1, true)
	var muted_result := router.relay(1, make.call(DotVoiceRouter.Channel.ALL, 1))
	_check(delivered.is_empty(), "a muted speaker reaches nobody")
	_check(
		muted_result.ok,
		"and is not told about it on every frame",
		"a muted player who can measure the refusal knows exactly when a moderator acted"
	)
	_check(router.refused_muted == 1, "the refusal is counted")

	router.set_muted(1, false)
	delivered.clear()
	router.relay(1, make.call(DotVoiceRouter.Channel.ALL, 1))
	_check(delivered.size() == 3, "unmuting lets them speak again")

	# The rate limit, which is what stops voice being a bandwidth amplifier.
	var limited := DotVoiceRouter.new()
	limited.name = "Limited"
	limited.config = config
	limited.max_bytes_per_second = 512
	limited.rate_window_sec = 1.0
	add_child(limited)
	await get_tree().process_frame
	for peer in [1, 2]:
		limited.add_peer(peer)
	limited.send_fn = func(_peer: int, _bytes: PackedByteArray) -> void: pass

	var accepted := 0
	var refused := 0
	for _i in range(60):
		if limited.relay(1, make.call(DotVoiceRouter.Channel.ALL, 1)).ok:
			accepted += 1
		else:
			refused += 1

	_check(
		refused > 0,
		"a client sending faster than the budget is cut off (%d accepted, %d refused)"
			% [accepted, refused],
		"one speaker is relayed to every listener, so this is the amplifier control"
	)
	_check(limited.refused_rate == refused, "and the refusals are counted")

	# A malformed packet is refused rather than crashing the relay.
	_check(
		not router.relay(1, PackedByteArray([1, 2, 3])).ok,
		"a malformed packet is refused"
	)
	_check(router.refused_format > 0, "and counted")

	# A frame of the wrong length is a client running a different config.
	var wrong := DotVoicePacket.new()
	wrong.sample_count = 240
	wrong.codec_id = &"adpcm"
	wrong.payload = PackedByteArray([1])
	_check(
		not router.relay(1, wrong.to_bytes()).ok,
		"and so is a frame this server's format does not use"
	)

	router.queue_free()
	limited.queue_free()
	await get_tree().process_frame
	_done()


## A cvar as dot-server's DotConVar looks to [method DotVoiceRouter.bind_cvars]: a value,
## a changed signal, a range. Duck-typed there, so a stand-in is the whole contract.
class FakeCvar:
	extends RefCounted
	signal changed(old_value: String, new_value: String)
	var value: String = ""
	var low: float = 0.0
	var high: float = 0.0
	func get_string() -> String:
		return value
	func with_range(a: float, b: float) -> FakeCvar:
		low = a
		high = b
		return self
	func set_string(v: String) -> void:
		var old := value
		value = v
		changed.emit(old, v)


## A client link as dot-server's DotClientLink looks to [method DotVoiceManager.follow_cvars].
class FakeLink:
	extends RefCounted
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var values: Dictionary = {}
	func replicated_cvar(cvar_name: String, fallback: String = "") -> String:
		return String(values.get(cvar_name, fallback))
	func tell(cvar_name: String, value: String) -> void:
		values[cvar_name] = value
		replicated_cvar_changed.emit(cvar_name, value)


func _test_server_switch() -> void:
	_section("the server's switch, and the game's channel")

	var config := _config()
	var router := DotVoiceRouter.new()
	router.name = "SwitchRouter"
	router.config = config
	router.max_bytes_per_second = 0
	add_child(router)
	await get_tree().process_frame

	for peer in [1, 2, 3, 4]:
		router.add_peer(peer)

	var delivered: Array[int] = []
	router.send_fn = func(peer: int, _bytes: PackedByteArray) -> void: delivered.append(peer)

	var codec := DotVoiceCodec.instance_for(&"adpcm")
	var packet := DotVoicePacket.new()
	packet.sample_count = config.frame_samples()
	packet.channel = DotVoiceRouter.Channel.ALL
	packet.codec_id = &"adpcm"
	packet.payload = codec.encode(DotVoiceSourceBuffer.tone(300.0, 0.02, config.sample_rate, 0.4))
	var bytes := packet.to_bytes()

	# The game chose team voice; the client's packet says ALL. Armed: before default_channel
	# was read, this reached all three and every team game was everybody's.
	router.default_channel = DotVoiceRouter.Channel.TEAM
	router.team_fn = func(peer: int) -> int: return 0 if peer <= 2 else 1
	var _r := router.relay(1, bytes)
	_check(delivered == [2], "the game's channel wins over the one the packet names (%s)" % str(delivered),
		"a rule the client writes the field for is not a rule")

	# The operator's mode wins over the game's.
	delivered.clear()
	router.forced_channel = DotVoiceRouter.Channel.ALL
	_r = router.relay(1, bytes)
	_check(delivered.size() == 3, "a forced channel wins over the game's (%d)" % delivered.size())
	router.forced_channel = -1

	# Off relays nothing, quietly, and counts it. Armed by the same packet relaying with it on.
	router.default_channel = DotVoiceRouter.Channel.ALL
	delivered.clear()
	router.enabled = false
	var off := router.relay(1, bytes)
	_check(delivered.is_empty(), "with voice off nothing is relayed (%d)" % delivered.size())
	_check(off.ok and int(off.value) == 0 and router.refused_disabled == 1,
		"and the speaker is not told, but it is counted (%d)" % router.refused_disabled)
	router.enabled = true
	_r = router.relay(1, bytes)
	_check(delivered.size() == 3, "on again, the same packet reaches everybody (%d)" % delivered.size())

	# The cvars, through a module's add_cvar.
	var made := {}
	var add := func(n: String, v: String, _d: String, _f: int) -> Object:
		var c := FakeCvar.new()
		c.value = v
		made[n] = c
		return c
	var cvars := router.bind_cvars(add, 0)
	_check(cvars.size() == router.cvar_specs().size() and made.has(DotVoiceRouter.CVAR_ENABLE) and made.has(DotVoiceRouter.CVAR_MODE),
		"bind_cvars registers sv_voice_enable, sv_voice_mode and the proximity cvars (%s)" % str(made.keys()))
	var enable: FakeCvar = made.get(DotVoiceRouter.CVAR_ENABLE)
	var mode: FakeCvar = made.get(DotVoiceRouter.CVAR_MODE)
	_check(enable != null and enable.value == "1" and enable.high == 1.0, "sv_voice_enable defaults to 1, range 0..1")
	enable.set_string("0")
	delivered.clear()
	_r = router.relay(1, bytes)
	_check(not router.enabled and delivered.is_empty(), "sv_voice_enable 0 turns relaying off")
	enable.set_string("1")
	_r = router.relay(1, bytes)
	_check(router.enabled and delivered.size() == 3, "and 1 turns it back on (%d)" % delivered.size())
	mode.set_string("2")
	_check(router.forced_channel == DotVoiceRouter.Channel.TEAM, "sv_voice_mode 2 forces team voice")
	mode.set_string("0")
	_check(router.forced_channel == -1, "and 0 hands it back to the game")
	_check(not router.set_cvar(DotVoiceRouter.CVAR_ENABLE, "yes") and router.enabled,
		"a value that is not a number is refused and changes nothing")

	# A value set before the router bound (argv, content.yml) is the one it starts on.
	var early := DotVoiceRouter.new()
	early.config = config
	var preset := func(n: String, _v: String, _d: String, _f: int) -> Object:
		var c := FakeCvar.new()
		c.value = "0" if n == DotVoiceRouter.CVAR_ENABLE else "0"
		return c
	var _made_early := early.bind_cvars(preset, 0)
	_check(not early.enabled, "a value the operator set before binding is read back")
	early.free()

	# The client's half: the link says off, the manager stops.
	var listener := DotVoiceManager.new()
	listener.name = "SwitchListener"
	listener.config = config
	listener.config_file = ""
	listener.register_service = false
	var heard := DotVoiceSinkBuffer.new()
	heard.sample_rate = config.sample_rate
	listener.sink_factory = func(_speaker: int) -> DotVoiceSink: return heard
	add_child(listener)
	await get_tree().process_frame

	var told: Array[bool] = []
	listener.server_enabled_changed.connect(func(on: bool) -> void: told.append(on))
	var link := FakeLink.new()
	link.values[DotVoiceRouter.CVAR_ENABLE] = "0"
	_check(listener.follow_cvars(link), "a manager follows a link that replicates cvars")
	_check(not listener.server_enabled and told == [false], "and takes the value the link already holds (%s)" % str(told))

	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = config.sample_rate
	listener.source = mic
	var _t := listener.update_talk(true)
	_check(not listener.is_capturing(), "with voice off the talk key opens no microphone")
	_t = listener.update_talk(false)

	packet.speaker = 9
	var _played := listener.receive(packet.to_bytes())
	for _i in range(10):
		await get_tree().process_frame
	_check(heard.frames_written == 0, "and what arrives anyway is not played (%d)" % heard.frames_written)

	link.tell(DotVoiceRouter.CVAR_ENABLE, "1")
	_check(listener.server_enabled and told == [false, true], "the server turning it on reaches the manager (%s)" % str(told))
	_check(not listener.follow_cvars(RefCounted.new()),
		"a source that cannot replicate is refused, and voice stays as it was")

	# Asked before the shell published its link: it waits for one.
	var late := DotVoiceManager.new()
	late.name = "LateListener"
	late.config = config
	late.config_file = ""
	late.register_service = false
	add_child(late)
	await get_tree().process_frame
	var late_link := FakeLink.new()
	late_link.values[DotVoiceRouter.CVAR_ENABLE] = "0"
	_check(not late.follow_cvars(null) and late.server_enabled, "with no link yet it follows nothing")
	DotRegistry.register(DotVoiceManager.LINK_SERVICE, late_link)
	_check(not late.server_enabled, "and follows the link the moment the shell publishes it")
	DotRegistry.unregister_instance(DotVoiceManager.LINK_SERVICE, late_link)
	late.queue_free()

	listener.queue_free()
	router.queue_free()
	await get_tree().process_frame
	_done()


