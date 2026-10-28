@tool
class_name DotVoiceSourceMicrophone
extends DotVoiceSource

## The real microphone, through an [AudioEffectCapture] on its own bus.
##
## Needs [code]audio/driver/enable_input[/code] true before the driver starts (else silent zeros; [method start] refuses), a capture bus that does not route to the speakers, and resampling here from the mix rate. On the web, silence means permission was not granted.

const CHANNEL := "voice.mic"

## Bus the capture effect is installed on. Created if it does not exist.
var bus_name: StringName = &"DotVoiceCapture"

## Seconds the capture effect buffers before discarding.
##
## A latency budget, not a safety margin: a large buffer turns an undrained capture into audible delay.
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

## A stream played into the capture bus instead of the microphone; null is the microphone.
##
## For a device probe on a driver with no input: the capture effect, resampling and encoder run as for a person. A bot speaks through [DotVoiceSourceBuffer].
var input_stream: AudioStream = null


func _init(p_host: Node = null, p_sample_rate: int = 24000) -> void:
	host = p_host
	sample_rate = p_sample_rate


## Whether this build can open a microphone at all.
##
## Headless has no audio driver, and any build can have input disabled in project settings.
static func is_supported() -> DotResult:
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"Audio input is disabled in this project's settings.",
			"set audio/driver/enable_input = true; it is read when the audio driver "
			+ "starts, so changing it at runtime does nothing"
		)

	# Only the dummy driver reliably tells: a headless process still reports a 44100 mix rate,
	# a "Default" input device and a configured bus layout, so those checks pass with no audio.
	# True of servers, CI and `--audio-driver Dummy`.
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
		# bus_count, not add_bus(): on web add_bus() puts the new bus ahead of Master and unplugs it
		# from the speakers, silencing the game on the first push-to-talk (see
		# DotAudioMixer._create_bus).
		AudioServer.bus_count = _bus_index + 1
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
	_player.stream = input_stream if input_stream != null else AudioStreamMicrophone.new()
	_player.bus = bus_name
	# A stream, never a sample: a browser build plays samples by default, and a microphone
	# cannot be one (it falls back with a warning).
	_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
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
