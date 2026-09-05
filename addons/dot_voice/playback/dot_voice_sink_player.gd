@tool
class_name DotVoiceSinkPlayer
extends DotVoiceSink

## Plays audio through an [AudioStreamGenerator], optionally positioned in the world.
##
## [b]One of these per speaker, not one for everybody.[/b] A generator is a stream, and a
## stream mixes one thing at a time; pushing two speakers into one produces whichever
## frame arrived last. Per-speaker also gets positional audio for free, because the node
## can sit where that player is.
##
## [b]`push_buffer` refuses more than the generator has room for[/b], and the frames it
## refuses are silently gone. So [method can_accept] is checked first and the caller is
## expected to hold the frame rather than throw it away, which is what the jitter buffer
## is for.

const CHANNEL := "voice.sink"

## Seconds the generator buffers. Bigger survives a frame hitch and costs latency.
var buffer_seconds: float = 0.2

## Set for a positioned voice; leave null for a flat one.
var positional: bool = false

## Metres the voice is inaudible beyond, when positional.
var max_distance: float = 40.0

var gain: float = 1.0

## Where the player node is parented.
var host: Node = null

var _player: Node = null
var _playback: AudioStreamGeneratorPlayback = null
var _running: bool = false


func _init(p_host: Node = null, p_sample_rate: int = 24000) -> void:
	host = p_host
	sample_rate = p_sample_rate


func start() -> DotResult:
	if _running:
		return DotResult.success(true)

	if host == null:
		return DotResult.fail(
			DotError.CODE_STATE, "A voice sink needs a host node to put its player under."
		)

	var generator := AudioStreamGenerator.new()
	# The generator's rate is the wire rate, so nothing has to resample on the way out.
	generator.mix_rate = float(sample_rate)
	generator.buffer_length = buffer_seconds

	if positional:
		var player_3d := AudioStreamPlayer3D.new()
		player_3d.stream = generator
		player_3d.max_distance = max_distance
		# Inverse falloff, which is how sound actually behaves, rather than linear, which
		# makes everyone equally loud until a cliff edge.
		player_3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_player = player_3d
	else:
		var player := AudioStreamPlayer.new()
		player.stream = generator
		_player = player

	_player.name = "DotVoicePlayback"
	host.add_child(_player)
	_player.call("play")

	_playback = _player.call("get_stream_playback")

	if _playback == null:
		stop()
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"The audio generator gave no playback to push into."
		)

	_running = true
	return DotResult.success(true)


func stop() -> void:
	if _player != null and is_instance_valid(_player):
		_player.call("stop")
		_player.get_parent().remove_child(_player)
		_player.queue_free()

	_player = null
	_playback = null
	_running = false


func is_running() -> bool:
	return _running


func can_accept(sample_count: int) -> bool:
	if not _running or _playback == null:
		return false
	return _playback.get_frames_available() >= sample_count


func write_frame(frame: PackedFloat32Array) -> void:
	if not _running or _playback == null:
		return

	# Checked rather than assumed. push_buffer drops what it cannot take and says
	# nothing, so a caller that skipped this would lose audio at exactly the moment the
	# machine is busiest, which is when it is hardest to notice.
	if _playback.get_frames_available() < frame.size():
		return

	var out := PackedVector2Array()
	out.resize(frame.size())

	for i in range(frame.size()):
		# Mono to both channels. Panning is the 3D player's business when positional,
		# and nobody's when it is not.
		var v := clampf(frame[i] * gain, -1.0, 1.0)
		out[i] = Vector2(v, v)

	_playback.push_buffer(out)


## Moves a positional voice to where the speaker is.
func set_position(position: Vector3) -> void:
	if _player is AudioStreamPlayer3D:
		(_player as AudioStreamPlayer3D).global_position = position


func describe() -> Dictionary:
	return {
		"sink": "player",
		"running": _running,
		"positional": positional,
		"available": _playback.get_frames_available() if _playback != null else 0,
		"skips": _playback.get_skips() if _playback != null else 0,
	}
