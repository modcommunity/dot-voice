@tool
class_name DotVoiceGate
extends RefCounted

## Decides whether a frame goes on the wire at all.
##
## Two modes, and the second one is where all the difficulty is:
##
## [b]Push-to-talk[/b] is a boolean the host sets. Nothing to get wrong, which is why it
## is the default.
##
## [b]Voice activation[/b] opens on loudness, and a single threshold does not work. A
## signal sitting near the threshold crosses it many times a second, so the gate chatters
## and the speaker is transmitted as a machine-gun of quarter-syllables. Two mechanisms
## fix it and both are needed:
##
## - [b]Hysteresis.[/b] It closes at [member release_ratio] of the level it opens at, so
##   there is a band the signal can sit in without changing anything.
## - [b]A hangover.[/b] Once open it stays open for [member hangover_ms] after the signal
##   drops, because speech has gaps in it and a gate that closes in them clips the end off
##   every word. "Stop" without its consonant is "sto".
##
## The gate also reports the [b]start of a talk spurt[/b], which the wire format carries
## and the jitter buffer needs: a speaker resuming after a pause has to reset the
## receiver's timeline, or their new frames look impossibly late and are all discarded.

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
## [param delta_ms] is how much time this frame represents, which is the frame duration
## rather than a wall clock: a host that stalls should not burn its hangover, exactly as
## dot-map's time limit counts simulated seconds.
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


## Root mean square of a frame, which is loudness as a listener perceives it.
##
## Not the peak: a single loud sample is a click on the desk, and a gate that opens on it
## transmits a room's worth of background between words.
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
