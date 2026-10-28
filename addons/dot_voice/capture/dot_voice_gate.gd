@tool
class_name DotVoiceGate
extends RefCounted

## Decides whether a frame goes on the wire: push-to-talk (a host boolean, the default) or voice activation.
##
## Activation needs hysteresis (close at [member release_ratio] of the open level) and a hangover ([member hangover_ms]), or a signal near the threshold chatters and speech loses its word endings. It also reports the start of a talk spurt, which resets the receiver's jitter timeline.

## RMS the gate opens at.
var activation_rms: float = 0.02

## Fraction of [member activation_rms] the gate closes at. Below 1, always.
var release_ratio: float = 0.6

## Milliseconds the gate stays open after the level drops.
var hangover_ms: float = 250.0

## When true the gate is driven by [method set_pressed] instead of by loudness.
var push_to_talk: bool = true

## Diagnostics.
var last_rms: float = 0.0
var opened_count: int = 0

var _open: bool = false
var _pressed: bool = false
var _hangover_left_ms: float = 0.0
## Set for exactly one frame each time the gate opens.
var _spurt_start: bool = false


## Sets the push-to-talk key state. Ignored when the gate is voice activated.
func set_pressed(pressed: bool) -> void:
	_pressed = pressed


## Feeds one frame in and says whether to transmit it.
##
## [param delta_ms] is the frame duration, not wall clock: a host that stalls must not burn its hangover.
func evaluate(samples: PackedFloat32Array, delta_ms: float) -> bool:
	last_rms = rms(samples)

	var was_open := _open

	if push_to_talk:
		_open = _pressed
	else:
		if _open:
			# Hysteresis: a lower bar to stay open than to open.
			if last_rms >= activation_rms * release_ratio:
				_hangover_left_ms = hangover_ms
			else:
				_hangover_left_ms -= delta_ms
				_open = _hangover_left_ms > 0.0
		else:
			_open = last_rms >= activation_rms
			if _open:
				_hangover_left_ms = hangover_ms

	_spurt_start = _open and not was_open
	if _spurt_start:
		opened_count += 1

	return _open


func is_open() -> bool:
	return _open


## Whether the frame just evaluated is the first of a talk spurt.
func is_spurt_start() -> bool:
	return _spurt_start


func reset() -> void:
	_open = false
	_pressed = false
	_hangover_left_ms = 0.0
	_spurt_start = false


## Root mean square of a frame, which is perceived loudness.
##
## Not the peak: one click opens a peak gate and transmits the room between words.
static func rms(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0

	var total := 0.0
	for i in range(samples.size()):
		total += samples[i] * samples[i]

	return sqrt(total / float(samples.size()))


func describe() -> Dictionary:
	return {
		"open": _open,
		"mode": "ptt" if push_to_talk else "vad",
		"rms": last_rms,
		"hangover_ms": _hangover_left_ms,
		"opened": opened_count,
	}
