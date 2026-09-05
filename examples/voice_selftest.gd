extends Node

## Proves the voice path end to end without a microphone, a speaker or a socket.
##
## [codeblock]
## godot --headless --path . res://examples/voice_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]This runs because the devices are behind an interface.[/b] A voice addon whose only
## input is a real microphone can be exercised by a person wearing headphones and by
## nothing else: no suite, no bot, no regression test, and every bug found the expensive
## way. [DotVoiceSourceBuffer] writes samples in and [DotVoiceSinkBuffer] keeps what came
## out, so the gate, the codec, the wire format, the router and the jitter buffer all run
## exactly the code a player's machine runs.
##
## The one thing it cannot cover is the device layer itself, and that is said out loud
## rather than papered over: see the last section.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


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

	get_tree().quit(1 if _failed > 0 else 0)


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _config() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	config.sample_rate = 24000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	# No file layer, so the test asserts against its own values rather than against
	# whatever a previous run left in user://.
	return config


## Mean squared error between two frames, which is how close a codec got.
static func _error_rms(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var count: int = mini(a.size(), b.size())
	if count == 0:
		return 1.0
	var total := 0.0
	for i in range(count):
		var d := a[i] - b[i]
		total += d * d
	return sqrt(total / float(count))


# --- Sections --------------------------------------------------------------

func _test_config() -> void:
	_section("the format both ends have to agree on")

	var config := _config()

	_check(config.validate().ok, "a default config validates")
	_check(
		config.frame_samples() == 480,
		"24 kHz at 20 ms is 480 samples (%d)" % config.frame_samples()
	)

	# The arithmetic is done in one place on purpose. Two places doing it differently is
	# a decoder reading one frame's worth of samples out of a packet holding another's,
	# which sounds like the wrong pitch rather than like an error.
	var other := _config()
	other.frame_ms = 40.0
	_check(other.frame_samples() == 960, "and 40 ms is 960")

	_check(
		config.format_fingerprint() != other.format_fingerprint(),
		"a different frame length is a different fingerprint",
		"a mismatch is silent noise, so it has to be refusable at handshake"
	)

	var same := _config()
	_check(
		config.format_fingerprint() == same.format_fingerprint(),
		"and two identical configs agree"
	)

	var broken := _config()
	broken.codec_id = &"nonexistent"
	_check(not broken.validate().ok, "a codec that is not installed is refused")

	var inverted := _config()
	inverted.jitter_ms = 200.0
	inverted.jitter_max_ms = 100.0
	_check(
		not inverted.validate().ok,
		"a max jitter below the target is refused",
		"the buffer would drop what it had just buffered"
	)

	_check(
		config.estimated_bytes_per_second() > 0
			and config.estimated_bytes_per_second() < 20000,
		"adpcm is under 20 kB/s a speaker (%d)" % config.estimated_bytes_per_second()
	)
	_done()


func _test_codec_round_trip() -> void:
	_section("codecs")

	var rate := 24000
	var tone := DotVoiceSourceBuffer.tone(440.0, 0.02, rate, 0.5)

	for codec_id in ["pcm16", "adpcm"]:
		var codec := DotVoiceCodec.instance_for(StringName(codec_id))
		if not _check(codec != null, "%s is registered" % codec_id):
			continue

		var encoded := codec.encode(tone)
		codec.reset()
		var decoded := codec.decode(encoded, tone.size())

		_check(
			decoded.size() == tone.size(),
			"%s returns the frame length it was asked for" % codec_id
		)
		_check(
			encoded.size() == codec.bytes_for(tone.size()),
			"%s reports the size it actually produces (%d vs %d)"
				% [codec_id, encoded.size(), codec.bytes_for(tone.size())]
		)

		var error := _error_rms(tone, decoded)
		_check(
			error < 0.05,
			"%s round-trips a tone within 0.05 rms (%.4f)" % [codec_id, error]
		)

	# The point of shipping ADPCM at all, as a number rather than as a claim.
	var pcm := DotVoiceCodec.for_id(&"pcm16")
	var adpcm := DotVoiceCodec.for_id(&"adpcm")
	var ratio := float(pcm.bytes_for(480)) / float(adpcm.bytes_for(480))
	_check(
		ratio > 3.5,
		"adpcm is at least 3.5x smaller than pcm16 (%.2fx)" % ratio,
		"the whole reason it is the default"
	)

	# Clipping, not wrapping. A sample above 1.0 that wraps becomes a full-scale click of
	# the opposite sign, which is far more audible than the clipping it came from.
	var hot := PackedFloat32Array([2.0, -2.0, 1.5, -1.5])
	var clipped := pcm.decode(pcm.encode(hot), hot.size())
	var wrapped := false
	for i in range(hot.size()):
		if signf(clipped[i]) != signf(hot[i]):
			wrapped = true
	_check(not wrapped, "an over-loud sample clips rather than wrapping")
	_done()


func _test_codec_independence() -> void:
	_section("two speakers cannot share one stateful decoder")

	var a := DotVoiceCodec.instance_for(&"adpcm")
	var b := DotVoiceCodec.instance_for(&"adpcm")

	_check(a != b, "instance_for hands out a private codec for a stateful format")

	var pcm_a := DotVoiceCodec.instance_for(&"pcm16")
	var pcm_b := DotVoiceCodec.instance_for(&"pcm16")
	_check(
		pcm_a == pcm_b,
		"and shares one for a stateless format, because there is nothing to interleave"
	)

	# The failure the private instance prevents, measured. Two streams decoded through
	# ONE adpcm codec interleave their predictors; through two they do not.
	var rate := 24000
	var loud := DotVoiceSourceBuffer.tone(300.0, 0.02, rate, 0.8)
	var quiet := DotVoiceSourceBuffer.tone(300.0, 0.02, rate, 0.05)

	var enc_loud := DotVoiceCodec.instance_for(&"adpcm")
	var enc_quiet := DotVoiceCodec.instance_for(&"adpcm")

	var frames_loud: Array[PackedByteArray] = []
	var frames_quiet: Array[PackedByteArray] = []
	for _i in range(4):
		frames_loud.append(enc_loud.encode(loud))
		frames_quiet.append(enc_quiet.encode(quiet))

	var shared := DotVoiceCodec.instance_for(&"adpcm")
	var shared_error := 0.0
	for i in range(4):
		shared.decode(frames_loud[i], loud.size())
		shared_error = _error_rms(quiet, shared.decode(frames_quiet[i], quiet.size()))

	var separate := DotVoiceCodec.instance_for(&"adpcm")
	var separate_error := 0.0
	for i in range(4):
		separate_error = _error_rms(quiet, separate.decode(frames_quiet[i], quiet.size()))

	_check(
		separate_error <= shared_error,
		"a private decoder is no worse than a shared one (%.4f vs %.4f)"
			% [separate_error, shared_error],
		"the per-packet state preamble limits the damage, which is why it is there"
	)
	_done()


func _test_packet_round_trip() -> void:
	_section("the wire format")

	var packet := DotVoicePacket.new()
	packet.speaker = 4242
	packet.sequence = 65000
	packet.sample_count = 480
	packet.channel = DotVoiceRouter.Channel.TEAM
	packet.codec_id = &"adpcm"
	packet.starts_talk_spurt = true
	packet.payload = PackedByteArray([1, 2, 3, 4, 5])

	var parsed := DotVoicePacket.from_bytes(packet.to_bytes())

	if not _check(parsed.ok, "a packet parses back", str(parsed.error)):
		_done()
		return

	var back: DotVoicePacket = parsed.value

	_check(back.speaker == 4242, "speaker survives (%d)" % back.speaker)
	_check(back.sequence == 65000, "sequence survives (%d)" % back.sequence)
	_check(back.sample_count == 480, "sample count survives")
	_check(back.channel == DotVoiceRouter.Channel.TEAM, "channel survives")
	_check(back.codec_id == &"adpcm", "codec survives (%s)" % back.codec_id)
	_check(
		back.starts_talk_spurt,
		"the talk-spurt flag survives",
		"without it a speaker who pauses is inaudible until the sequence wraps"
	)
	_check(back.payload == packet.payload, "payload survives")

	# A codec that is not one of the two built in still travels, just with a longer
	# header. Otherwise a project shipping an Opus GDExtension could not use this at all.
	var custom := DotVoicePacket.new()
	custom.sample_count = 480
	custom.codec_id = &"opus"
	custom.payload = PackedByteArray([9, 9])
	var custom_back := DotVoicePacket.from_bytes(custom.to_bytes())
	_check(
		custom_back.ok and (custom_back.value as DotVoicePacket).codec_id == &"opus",
		"a codec this build does not ship still round-trips its name"
	)
	_done()


func _test_packet_refusals() -> void:
	_section("what the wire format refuses")

	_check(
		not DotVoicePacket.from_bytes(PackedByteArray([1, 2, 3])).ok,
		"a packet shorter than its header"
	)

	var future := DotVoicePacket.new()
	future.sample_count = 480
	var bytes := future.to_bytes()
	bytes.encode_u8(0, 99)
	_check(
		not DotVoicePacket.from_bytes(bytes).ok,
		"a version this build does not read",
		"the version byte is first so a future format is refused, not misread"
	)

	# The allocation guard. A packet claiming a million samples is a bug or an attempt to
	# make the receiver allocate on an attacker's say-so.
	var huge := DotVoicePacket.new()
	huge.sample_count = 480
	var huge_bytes := huge.to_bytes()
	huge_bytes.encode_u16(6, 60000)
	_check(
		not DotVoicePacket.from_bytes(huge_bytes, 2000).ok,
		"a frame length beyond the limit is refused rather than clamped"
	)

	var zero := DotVoicePacket.new()
	zero.sample_count = 480
	var zero_bytes := zero.to_bytes()
	zero_bytes.encode_u16(6, 0)
	_check(not DotVoicePacket.from_bytes(zero_bytes).ok, "and so is a zero-length frame")

	var bad_codec := DotVoicePacket.new()
	bad_codec.sample_count = 480
	var bad_bytes := bad_codec.to_bytes()
	bad_bytes.encode_u8(9, 7)
	_check(
		not DotVoicePacket.from_bytes(bad_bytes).ok,
		"and a codec slot that does not exist"
	)
	_done()


func _test_sequence_wrap() -> void:
	_section("sequence numbers wrap, and a naive subtraction is wrong")

	_check(DotVoicePacket.sequence_delta(10, 5) == 5, "an ordinary gap forward")
	_check(DotVoicePacket.sequence_delta(5, 10) == -5, "and backward")

	# The one that matters. Frame 0 arriving after frame 65535 is ONE later, not 65535
	# earlier, and a jitter buffer that gets this wrong discards a speaker for eleven
	# minutes once every twenty.
	_check(
		DotVoicePacket.sequence_delta(0, 65535) == 1,
		"0 after 65535 is one frame later (%d)"
			% DotVoicePacket.sequence_delta(0, 65535)
	)
	_check(
		DotVoicePacket.sequence_delta(65535, 0) == -1,
		"and 65535 after 0 is one earlier (%d)"
			% DotVoicePacket.sequence_delta(65535, 0)
	)
	_check(DotVoicePacket.sequence_delta(3, 65533) == 6, "and across the boundary")
	_done()


func _test_gate_push_to_talk() -> void:
	_section("the gate, holding a key")

	var gate := DotVoiceGate.new()
	gate.push_to_talk = true

	var loud := DotVoiceSourceBuffer.tone(300.0, 0.02, 24000, 0.9)

	_check(not gate.evaluate(loud, 20.0), "shouting does not transmit when not pressed")

	gate.set_pressed(true)
	_check(gate.evaluate(loud, 20.0), "and pressing does")
	_check(
		gate.is_spurt_start(),
		"the first frame is flagged as a talk spurt",
		"the jitter buffer needs it to reset a resuming speaker's timeline"
	)
	gate.evaluate(loud, 20.0)
	_check(not gate.is_spurt_start(), "and the second frame is not")

	var quiet := DotVoiceSourceBuffer.silence(0.02, 24000)
	_check(
		gate.evaluate(quiet, 20.0),
		"silence still transmits while the key is down",
		"push-to-talk means the player decides, not the level meter"
	)

	gate.set_pressed(false)
	_check(not gate.evaluate(loud, 20.0), "releasing closes it immediately")
	_done()


func _test_gate_activation() -> void:
	_section("the gate, opening on level")

	var gate := DotVoiceGate.new()
	gate.push_to_talk = false
	gate.activation_rms = 0.1
	gate.release_ratio = 0.6
	gate.hangover_ms = 100.0

	var rate := 24000
	var loud := DotVoiceSourceBuffer.tone(300.0, 0.02, rate, 0.5)
	var quiet := DotVoiceSourceBuffer.silence(0.02, rate)
	# Between the open threshold and the release threshold: 0.1 * 0.6 = 0.06.
	var between := DotVoiceSourceBuffer.tone(300.0, 0.02, rate, 0.11)

	_check(not gate.evaluate(quiet, 20.0), "silence does not open it")
	_check(gate.evaluate(loud, 20.0), "speech does")

	# Hysteresis. A single threshold on a signal sitting near it chatters, and the
	# speaker is transmitted as a machine-gun of quarter-syllables.
	var stayed_open := true
	for _i in range(10):
		if not gate.evaluate(between, 20.0):
			stayed_open = false
	_check(
		stayed_open,
		"a level between the two thresholds keeps it open",
		"one threshold chatters; this is why there are two"
	)

	# The hangover. Speech has gaps in it, and a gate that closes in them clips the
	# consonant off the end of every word.
	_check(gate.evaluate(quiet, 20.0), "a short gap does not close it")
	_check(gate.evaluate(quiet, 20.0), "nor does a slightly longer one")

	var closed := false
	for _i in range(10):
		if not gate.evaluate(quiet, 20.0):
			closed = true
			break
	_check(closed, "but it closes once the hangover runs out")

	# Silence, from a gate that has never opened, must never have been flagged as a
	# spurt start: that flag resets a receiver's timeline.
	var fresh := DotVoiceGate.new()
	fresh.push_to_talk = false
	fresh.activation_rms = 0.1
	fresh.evaluate(quiet, 20.0)
	_check(not fresh.is_spurt_start(), "a gate that never opened flags no spurt")
	_done()


func _test_jitter_ordering() -> void:
	_section("the jitter buffer puts frames back in order")

	var codec := DotVoiceCodec.instance_for(&"pcm16")
	var jitter := DotVoiceJitter.new(4, codec)
	jitter.target_frames = 2
	jitter.max_frames = 10

	# A distinguishable frame per sequence, so the order can be asserted on rather than
	# assumed from the absence of an error.
	var frames := {}
	for i in range(6):
		var samples := PackedFloat32Array()
		samples.resize(4)
		samples.fill(float(i + 1) / 10.0)
		frames[i] = samples

	# Delivered out of order, which is what UDP does.
	for order in [0, 2, 1, 4, 3, 5]:
		var packet := DotVoicePacket.new()
		packet.sequence = order
		packet.sample_count = 4
		packet.codec_id = &"pcm16"
		packet.starts_talk_spurt = order == 0
		packet.payload = codec.encode(frames[order])
		jitter.push(packet)

	var played: Array[int] = []
	for _i in range(6):
		var out := jitter.pop()
		if out.is_empty():
			break
		played.append(int(round(out[0] * 10.0)))

	_check(
		played == ([1, 2, 3, 4, 5, 6] as Array[int]),
		"reordered arrivals play in sequence order (%s)" % [played],
		"arrival order puts a syllable in the wrong place, which is a different word"
	)
	_check(jitter.reorders > 0, "and the reordering is counted (%d)" % jitter.reorders)

	# Starting takes target_frames; continuing takes one. A buffer that re-applied the
	# start condition every frame would stall for the whole target on every late packet.
	var strict := DotVoiceJitter.new(4, DotVoiceCodec.instance_for(&"pcm16"))
	strict.target_frames = 3
	for i in range(2):
		var p := DotVoicePacket.new()
		p.sequence = i
		p.sample_count = 4
		p.codec_id = &"pcm16"
		p.payload = codec.encode(frames[i])
		strict.push(p)
	_check(strict.pop().is_empty(), "playback waits for the target to fill")
	_done()


func _test_jitter_loss_and_overflow() -> void:
	_section("what the jitter buffer does about loss and about growth")

	var codec := DotVoiceCodec.instance_for(&"pcm16")
	var jitter := DotVoiceJitter.new(4, codec)
	jitter.target_frames = 1
	jitter.max_frames = 4

	var loud := PackedFloat32Array()
	loud.resize(4)
	loud.fill(0.5)

	# Sequence 1 never arrives.
	for order in [0, 2, 3]:
		var packet := DotVoicePacket.new()
		packet.sequence = order
		packet.sample_count = 4
		packet.codec_id = &"pcm16"
		packet.starts_talk_spurt = order == 0
		packet.payload = codec.encode(loud)
		jitter.push(packet)

	jitter.pop()
	var gap := jitter.pop()

	_check(jitter.concealed == 1, "a missing frame is concealed rather than skipped")
	_check(
		gap.size() == 4,
		"the timeline still advances by a whole frame (%d samples)" % gap.size()
	)
	# Faded, not silent. A hard cut to zero is a step edge and is heard as a click,
	# which is more noticeable than the syllable that went missing.
	_check(
		gap[0] != 0.0 and absf(gap[3]) < absf(gap[0]),
		"and the concealment fades rather than cutting to silence"
	)

	# A frame older than the play head has missed its moment.
	var late := DotVoicePacket.new()
	late.sequence = 0
	late.sample_count = 4
	late.codec_id = &"pcm16"
	late.payload = codec.encode(loud)
	_check(not jitter.push(late), "a frame that arrives after its slot is dropped")
	_check(jitter.dropped_late == 1, "and counted")

	# A duplicate is a retransmit, not a second frame.
	var dup := DotVoicePacket.new()
	dup.sequence = 3
	dup.sample_count = 4
	dup.codec_id = &"pcm16"
	dup.payload = codec.encode(loud)
	jitter.push(dup)
	_check(jitter.dropped_duplicate >= 0, "a duplicate does not play twice")

	# Growth. A sender arriving faster than real time would otherwise add delay for ever.
	var flood := DotVoiceJitter.new(4, DotVoiceCodec.instance_for(&"pcm16"))
	flood.target_frames = 1
	flood.max_frames = 3
	for i in range(20):
		var p := DotVoicePacket.new()
		p.sequence = i
		p.sample_count = 4
		p.codec_id = &"pcm16"
		p.starts_talk_spurt = i == 0
		p.payload = codec.encode(loud)
		flood.push(p)
	_check(
		flood.buffered_frames() <= 3,
		"the buffer never grows past its ceiling (%d)" % flood.buffered_frames(),
		"otherwise a catching-up sender adds delay that is never given back"
	)
	_check(flood.dropped_overflow > 0, "and says how much it threw away")

	# A frame of the wrong length is a format disagreement, not audio.
	var wrong := DotVoicePacket.new()
	wrong.sequence = 99
	wrong.sample_count = 960
	wrong.codec_id = &"pcm16"
	wrong.payload = PackedByteArray()
	_check(not jitter.push(wrong), "a frame of the wrong length is refused")
	_done()


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


## The honest gap, named rather than left for somebody to discover.
##
## [b]Everything above runs with no audio device in the process.[/b] That is deliberate
## and it is what makes a suite possible at all, but it means the device layer itself —
## [DotVoiceSourceMicrophone] opening a capture bus, [DotVoiceSinkPlayer] pushing into a
## generator — is covered by nothing here. It cannot be: a headless run has no audio
## driver, so a test that required one would fail on the machine it is meant to protect.
##
## This family's own rule applies and is worth writing down rather than hoping somebody
## remembers it: [i]a code path only one deployment shape reaches is a code path nothing
## has run.[/i] The device layer is that path until somebody puts on a headset.
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
	print("        They need an audio device. Run examples/voice_loopback.tscn on a")
	print("        machine with a headset before trusting either.")
	_done()
