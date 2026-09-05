@tool
class_name DotVoiceSourceMicrophone
extends DotVoiceSource

## The real microphone, through an [AudioEffectCapture] on its own bus.
##
## [b]Three things about this are not obvious and all three break it silently.[/b]
##
## 1. [code]audio/driver/enable_input[/code] must be true in the project settings before
##    the audio driver starts. Setting it at runtime does nothing, and the symptom is a
##    capture that returns zeros for ever with no error anywhere. [method start] checks
##    it and refuses rather than pretending.
## 2. The capture bus must not route to the speakers, or the player hears themselves with
##    the whole system's latency added. The bus this creates sends to a silent bus for
##    exactly that reason.
## 3. Capture arrives at the [b]engine's mix rate[/b], not at the rate voice wants, and
##    the difference is usually 44100 against 24000. Resampling is done here rather than
##    later so everything downstream sees one rate.
##
## On the web this additionally needs the page to have been granted microphone permission
## by the browser, which is a user gesture the game cannot perform for them. There is no
## way to ask the engine whether that happened, so a web build that gets silence should
## be treated as "not granted" rather than as a bug here.

const CHANNEL := "voice.mic"

## Bus the capture effect is installed on. Created if it does not exist.
var bus_name: StringName = &"DotVoiceCapture"

## Seconds of audio the capture effect buffers before it starts discarding.
##
## Small: this is a latency budget, not a safety margin. A large buffer hides a host that
## is not draining the capture and turns it into delay the player hears.
var buffer_seconds: float = 0.25

## Gain applied on read.
var gain: float = 1.0

var _player: AudioStreamPlayer = null
var _capture: AudioEffectCapture = null
var _bus_index: int = -1
var _mix_rate: int = 44100
var _running: bool = false
## Resampled samples not yet handed out as a whole frame.
var _spill: PackedFloat32Array = PackedFloat32Array()

## Where the player node is parented. The source does not own a tree position.
var host: Node = null


func _init(p_host: Node = null, p_sample_rate: int = 24000) -> void:
	host = p_host
	sample_rate = p_sample_rate


## Whether this build can open a microphone at all.
##
## A capability question rather than a platform one, per the family rule. Headless has no
## audio driver, and any build can have input disabled in its project settings.
static func is_supported() -> DotResult:
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"Audio input is disabled in this project's settings.",
			"set audio/driver/enable_input = true; it is read when the audio driver "
			+ "starts, so changing it at runtime does nothing"
		)

	# [b]The dummy driver is the only reliable tell, and it took a failing test to find
	# out.[/b] Everything else a headless process reports looks exactly like a working
	# sound card: `get_mix_rate()` is 44100, `get_input_device_list()` is
	# `["Default"]`, and the bus layout is whatever the project configured. So a check
	# built on any of those passes on a machine with no audio at all, and the symptom is
	# a capture that returns silence for ever with nothing anywhere reporting a problem.
	#
	# A capability question rather than a platform one, per the family rule: this is
	# true of a dedicated server, of CI, and of a desktop started with `--audio-driver
	# Dummy`, and those are the same situation as far as a microphone is concerned.
	if AudioServer.has_method("get_driver_name"):
		var driver := str(AudioServer.call("get_driver_name"))
		if driver == "Dummy":
			return DotResult.fail(
				DotError.CODE_UNSUPPORTED,
				"This process has no audio device.",
				"the audio driver is Dummy, which is what a headless run, CI and "
				+ "--audio-driver Dummy all give you"
			)

	if AudioServer.get_mix_rate() <= 0.0:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "There is no audio device on this machine."
		)

	if AudioServer.get_input_device_list().is_empty():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This machine reports no audio input devices."
		)

	return DotResult.success(true)


func start() -> DotResult:
	if _running:
		return DotResult.success(true)

	var supported := is_supported()
	if not supported.ok:
		return supported

	if host == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A microphone source needs a host node to put its player under."
		)

	_mix_rate = int(AudioServer.get_mix_rate())

	_bus_index = AudioServer.get_bus_index(bus_name)

	if _bus_index < 0:
		_bus_index = AudioServer.bus_count
		AudioServer.add_bus(_bus_index)
		AudioServer.set_bus_name(_bus_index, bus_name)

	# Muted, and sent nowhere audible. Without this the player hears their own microphone
	# through their speakers, which on a machine without headphones is a feedback loop.
	AudioServer.set_bus_mute(_bus_index, true)

	_capture = null
	for i in range(AudioServer.get_bus_effect_count(_bus_index)):
		var effect := AudioServer.get_bus_effect(_bus_index, i)
		if effect is AudioEffectCapture:
			_capture = effect
			break

	if _capture == null:
		_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(_bus_index, _capture)

	_capture.buffer_length = buffer_seconds
	_capture.clear_buffer()

	_player = AudioStreamPlayer.new()
	_player.name = "DotVoiceMicrophone"
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = bus_name
	host.add_child(_player)
	_player.play()

	_running = true

	DotLog.info(CHANNEL, "microphone open", {
		"mix_rate": _mix_rate, "wire_rate": sample_rate, "bus": String(bus_name)
	})

	return DotResult.success(true)


func stop() -> void:
	if _player != null and is_instance_valid(_player):
		_player.stop()
		_player.get_parent().remove_child(_player)
		_player.queue_free()

	_player = null
	_running = false
	_spill = PackedFloat32Array()

	if _capture != null:
		_capture.clear_buffer()

	DotLog.info(CHANNEL, "microphone closed")


func is_running() -> bool:
	return _running


func has_frame(sample_count: int) -> bool:
	if not _running or _capture == null:
		return false
	if _spill.size() >= sample_count:
		return true
	return _spill.size() + _resampled_available() >= sample_count


func read_frame(sample_count: int) -> PackedFloat32Array:
	if not _running or _capture == null:
		return PackedFloat32Array()

	_drain()

	if _spill.size() < sample_count:
		return PackedFloat32Array()

	var out := _spill.slice(0, sample_count)
	_spill = _spill.slice(sample_count)

	if not is_equal_approx(gain, 1.0):
		for i in range(out.size()):
			# Clamped here rather than at the codec, so a gain a player set too high is
			# audible distortion on their own level meter instead of a surprise at the
			# far end.
			out[i] = clampf(out[i] * gain, -1.0, 1.0)

	return out


## Pulls everything the capture has, mixes to mono and resamples to the wire rate.
func _drain() -> void:
	var available := _capture.get_frames_available()
	if available <= 0:
		return

	var frames := _capture.get_buffer(available)
	if frames.is_empty():
		return

	_spill.append_array(
		DotVoiceSource.resample(DotVoiceSource.to_mono(frames), _mix_rate, sample_rate)
	)


func _resampled_available() -> int:
	if _capture == null:
		return 0
	return int(
		float(_capture.get_frames_available()) * float(sample_rate) / float(_mix_rate)
	)


func describe() -> Dictionary:
	return {
		"source": "microphone",
		"running": _running,
		"mix_rate": _mix_rate,
		"wire_rate": sample_rate,
		"pending": _spill.size(),
		"discarded": _capture.get_discarded_frames() if _capture != null else 0,
	}
