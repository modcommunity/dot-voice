@tool
class_name DotVoiceJitter
extends RefCounted

## One speaker's incoming frames, put back in order and handed out at a steady rate.
##
## [b]This class is the difference between voice that works and voice that does not.[/b]
## Packets arrive reordered, late, duplicated and not at all, and playback needs a frame
## every 20 ms regardless. So frames are held briefly, sorted by sequence, and pulled at
## the rate the output device consumes them.
##
## Four things it has to get right, each of which is a way voice breaks in practice:
##
## - [b]Ordering.[/b] UDP reorders. Playing in arrival order is worse than dropping the
##   late frame, because a syllable in the wrong place is heard as a different word.
## - [b]The wrap.[/b] Sequence numbers are 16 bits.
##   [method DotVoicePacket.sequence_delta] is the only place that arithmetic is done.
## - [b]Growth.[/b] A sender whose frames arrive faster than real time, which is what a
##   reconnect or a catching-up host looks like, would otherwise add delay for ever.
##   Past [member max_frames] the oldest are dropped, because the newest are the ones
##   somebody is waiting to hear.
## - [b]Gaps.[/b] A missing frame is filled by fading the last one out rather than by
##   inserting silence. A hard cut to zero is a step edge and is heard as a click, which
##   is more noticeable than the syllable that went missing.

const CHANNEL := "voice.jitter"

## Frames buffered before playback starts, from [member DotVoiceConfig.jitter_ms].
var target_frames: int = 3

## Hard ceiling. Past this the oldest frame is dropped.
var max_frames: int = 20

## Samples in one frame. Frames of another length are refused.
var frame_samples: int = 480

## This speaker's own codec instance, never shared. See [DotVoiceCodecAdpcm].
var codec: DotVoiceCodec = null

## Diagnostics, all counted rather than logged, because at 50 frames a second a log line
## per event is the bug.
var received: int = 0
var played: int = 0
var dropped_late: int = 0
var dropped_duplicate: int = 0
var dropped_overflow: int = 0
var concealed: int = 0
var reorders: int = 0

## sequence -> PackedByteArray payload
var _frames: Dictionary = {}
## The next sequence to play. -1 until the first frame decides it.
var _next: int = -1
var _playing: bool = false
var _last_frame: PackedFloat32Array = PackedFloat32Array()
## Highest sequence seen, for reorder counting.
var _highest: int = -1


func _init(p_frame_samples: int = 480, p_codec: DotVoiceCodec = null) -> void:
	frame_samples = p_frame_samples
	codec = p_codec


## Takes one packet in. Returns whether it was kept.
func push(packet: DotVoicePacket) -> bool:
	if packet == null:
		return false

	if packet.sample_count != frame_samples:
		# A frame of a different length than this buffer was built for. Refused rather
		# than resampled: the two ends disagree about the format, and playing it would
		# produce speech at the wrong speed, which reads as a broken microphone rather
		# than as a misconfiguration.
		DotLog.debug(CHANNEL, "refusing a frame of the wrong length", {
			"got": packet.sample_count, "want": frame_samples
		})
		return false

	received += 1

	# A talk spurt starts a new timeline. Without this a speaker who paused resumes with
	# sequence numbers the buffer still considers ancient, and every frame is discarded
	# as late until the counter wraps all the way round.
	if packet.starts_talk_spurt:
		reset()
		_next = packet.sequence

	if _next < 0:
		_next = packet.sequence

	var delta := DotVoicePacket.sequence_delta(packet.sequence, _next)

	if delta < 0:
		# Older than what we are about to play. Its moment has passed.
		dropped_late += 1
		return false

	if _frames.has(packet.sequence):
		dropped_duplicate += 1
		return false

	if _highest >= 0 and DotVoicePacket.sequence_delta(packet.sequence, _highest) < 0:
		reorders += 1
	else:
		_highest = packet.sequence

	_frames[packet.sequence] = packet.payload

	while _frames.size() > max_frames:
		# Drop the oldest, which means advancing the play head past it. Dropping the
		# newest instead would keep the delay for ever, which is the thing this is here
		# to prevent.
		var oldest := _oldest_sequence()
		if oldest < 0:
			break
		_frames.erase(oldest)
		dropped_overflow += 1
		if DotVoicePacket.sequence_delta(oldest, _next) >= 0:
			_next = (oldest + 1) & 0xFFFF

	return true


## Whether enough is buffered to start, or to keep going.
##
## [b]Asymmetric on purpose.[/b] Starting takes [member target_frames]; continuing takes
## one. A buffer that re-applied the start condition on every frame would stall for the
## whole target every time a single packet was late, turning one dropped packet into
## sixty milliseconds of silence.
func is_ready() -> bool:
	if _playing:
		return not _frames.is_empty()
	return _frames.size() >= target_frames


## Hands out the next frame of samples, or an empty array when there is nothing to play.
##
## Call once per output period. A gap in the sequence is concealed rather than skipped,
## so the timeline advances at a constant rate no matter what arrived.
func pop() -> PackedFloat32Array:
	if not is_ready():
		if _playing and _frames.is_empty():
			# Ran dry mid-speech. Stop rather than conceal for ever, so the next arrival
			# rebuilds the buffer instead of playing into an empty one.
			_playing = false
		return PackedFloat32Array()

	_playing = true

	var payload: Variant = _frames.get(_next)

	if payload == null:
		# The frame is missing but later ones are here, so this is a loss rather than the
		# end of the stream. Advance the timeline and conceal.
		_next = (_next + 1) & 0xFFFF
		concealed += 1
		return _conceal()

	_frames.erase(_next)
	_next = (_next + 1) & 0xFFFF
	played += 1

	if codec == null:
		return PackedFloat32Array()

	var samples := codec.decode(payload as PackedByteArray, frame_samples)
	_last_frame = samples
	return samples


## What to play when a frame never arrived.
##
## The previous frame, faded out. Silence is a step edge and clicks; repeating the frame
## unchanged buzzes at the frame rate. A fade is neither, and at 20 ms nobody hears the
## difference between this and the syllable that was lost.
func _conceal() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frame_samples)

	if _last_frame.size() < frame_samples:
		for i in range(frame_samples):
			out[i] = 0.0
		return out

	for i in range(frame_samples):
		var fade := 1.0 - (float(i) / float(frame_samples))
		out[i] = _last_frame[i] * fade * 0.6

	# So a second consecutive loss fades from the already-faded copy and reaches silence
	# rather than holding a tone.
	_last_frame = out

	return out


func reset() -> void:
	_frames.clear()
	_next = -1
	_highest = -1
	_playing = false
	_last_frame = PackedFloat32Array()
	if codec != null:
		codec.reset()


func buffered_frames() -> int:
	return _frames.size()


func is_playing() -> bool:
	return _playing


func _oldest_sequence() -> int:
	var best := -1
	for key in _frames.keys():
		var seq: int = key
		if best < 0 or DotVoicePacket.sequence_delta(seq, best) < 0:
			best = seq
	return best


func describe() -> Dictionary:
	return {
		"buffered": _frames.size(),
		"playing": _playing,
		"received": received,
		"played": played,
		"late": dropped_late,
		"duplicate": dropped_duplicate,
		"overflow": dropped_overflow,
		"concealed": concealed,
		"reorders": reorders,
	}
