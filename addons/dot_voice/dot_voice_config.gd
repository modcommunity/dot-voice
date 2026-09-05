@tool
class_name DotVoiceConfig
extends DotConfig

## Voice settings, layered the way every other config in this family is:
## exported defaults < JSON file < environment < command line.
##
## [b]The three numbers that matter are [member sample_rate], [member frame_ms] and the
## codec[/b], and they have to agree on both ends of a connection. Everything else is a
## local preference: whether you use push-to-talk, how loud you have to be before the gate
## opens, how much jitter you are willing to buffer.

@export_group("Format")

## Samples per second on the wire.
##
## [b]Not the engine's mix rate.[/b] Godot mixes at 44100 by default and a microphone
## capture arrives at that rate, which is roughly three times what speech needs and
## three times the bandwidth. 16000 resolves every consonant a telephone does; 24000 is
## noticeably better and still a third of the mix rate. Both ends must agree.
@export_enum("8000:8000", "12000:12000", "16000:16000", "24000:24000", "48000:48000")
var sample_rate: int = 24000

## Milliseconds of audio in one packet.
##
## The whole latency/overhead trade in one number. 20 ms is what every voice system in
## this genre uses: small enough that nobody hears the delay, large enough that the
## per-packet header is not most of the traffic. Below 10 ms the header wins; above
## 60 ms a lost packet is an audible hole rather than a click.
@export_range(10.0, 60.0, 10.0) var frame_ms: float = 20.0

## Codec id, resolved by [method DotVoiceCodec.for_id].
##
## [code]pcm16[/code] is exact and costs 16 bits a sample. [code]adpcm[/code] is 4 bits a
## sample for a quarter of the bandwidth and a small amount of hiss, and is the default
## because 4x is the difference between a full server being usable and not.
@export var codec_id: StringName = &"adpcm"

@export_group("Capture")

## How the microphone is opened.
##
## [b]Off by default, on every platform.[/b] A game that opens a microphone because a
## node entered the tree is a game that records people who did not ask to be recorded.
## The host calls [method DotVoiceManager.start_capture] when a player has agreed.
@export var capture_enabled: bool = false

## Hold a key to talk, rather than opening on volume.
##
## On by default. Voice activation in a room with a fan in it transmits the fan.
@export var push_to_talk: bool = true

## Loudness the gate opens at, as RMS in 0..1, when [member push_to_talk] is off.
@export_range(0.0, 0.5, 0.001) var activation_rms: float = 0.02

## How far the gate has to fall below [member activation_rms] before it closes.
##
## Hysteresis, and it is not optional: a single threshold on a signal that crosses it
## chatters, so a speaker sitting exactly at the threshold is transmitted as a
## machine-gun of quarter-syllables.
@export_range(0.1, 1.0, 0.05) var release_ratio: float = 0.6

## Milliseconds the gate stays open after the signal drops.
##
## Speech has gaps in it. Without a hangover, "stop" loses its consonant and every
## sentence sounds clipped.
@export_range(0.0, 2000.0, 10.0) var hangover_ms: float = 250.0

## Microphone gain, applied before the gate.
@export_range(0.1, 8.0, 0.1) var input_gain: float = 1.0

@export_group("Playback")

## Milliseconds of audio held before a speaker starts playing.
##
## The jitter buffer. Zero plays the instant a packet lands and stutters on the first
## late one; too much is a conversation people talk over each other in.
@export_range(0.0, 500.0, 10.0) var jitter_ms: float = 60.0

## Milliseconds the buffer may grow to before it starts dropping the oldest frames.
##
## A speaker whose packets arrive faster than real time, which is what a reconnect or a
## catching-up server looks like, would otherwise accumulate delay for ever.
@export_range(100.0, 2000.0, 50.0) var jitter_max_ms: float = 400.0

## Output gain, applied per speaker after decode.
@export_range(0.0, 4.0, 0.05) var output_gain: float = 1.0

@export_group("Routing")

## Metres a proximity channel can be heard over. 0 disables the falloff.
@export_range(0.0, 500.0, 1.0) var proximity_range: float = 40.0

## Bytes per second one speaker may put on the wire before the server stops relaying.
##
## [b]The control that stops voice being an amplifier.[/b] A server relays one speaker to
## every listener, so a client that sends ten times the expected rate costs the server
## ten times that multiplied by the player count. Enforced on the server, because a limit
## a client applies to itself is not a limit.
@export_range(0, 65536, 256) var max_bytes_per_second: int = 4096


func env_prefix() -> String:
	return "DOT_VOICE_"


func cli_prefix() -> String:
	return "--voice-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray()


## Samples in one frame at the configured rate and duration.
##
## The single place that arithmetic is done. Two places doing it differently is a decoder
## that reads one frame's worth of samples out of a packet holding another's, which
## presents as speech at the wrong pitch rather than as an error.
func frame_samples() -> int:
	return int(round(float(sample_rate) * frame_ms / 1000.0))


func frames_per_second() -> float:
	return 1000.0 / frame_ms


## Bytes one second of encoded audio takes, for a bandwidth estimate.
func estimated_bytes_per_second() -> int:
	var codec := DotVoiceCodec.for_id(codec_id)
	if codec == null:
		return 0
	return int(codec.bytes_for(frame_samples()) * frames_per_second())


func validate() -> DotResult:
	if sample_rate <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "sample_rate must be positive.")

	if frame_ms <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "frame_ms must be positive.")

	if frame_samples() <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"sample_rate and frame_ms produce a zero-length frame.",
			"%d Hz at %.1f ms" % [sample_rate, frame_ms]
		)

	if DotVoiceCodec.for_id(codec_id) == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No codec with id '%s'." % codec_id,
			"known: %s" % ", ".join(Array(DotVoiceCodec.known_ids()))
		)

	if jitter_max_ms < jitter_ms:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"jitter_max_ms is below jitter_ms, so the buffer would drop what it just "
			+ "buffered.",
			"%.0f < %.0f" % [jitter_max_ms, jitter_ms]
		)

	if release_ratio > 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"release_ratio above 1 closes the gate above the level that opens it."
		)

	return DotResult.success(true)


## What both ends must agree on, as one number.
##
## [b]Voice fails silently when the two ends disagree about the format[/b] — a decoder
## reading ADPCM as PCM produces noise, and reading a 20 ms frame as a 40 ms one produces
## speech at half speed. Neither errors. Exchanging this once at handshake turns all of
## that into one refusal.
func format_fingerprint() -> int:
	return hash("%d|%.1f|%s" % [sample_rate, frame_ms, codec_id])


func describe() -> Dictionary:
	return {
		"sample_rate": sample_rate,
		"frame_ms": frame_ms,
		"frame_samples": frame_samples(),
		"codec": String(codec_id),
		"bytes_per_second": estimated_bytes_per_second(),
		"push_to_talk": push_to_talk,
		"jitter_ms": jitter_ms,
	}


func describe_lines(_redact: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("format    %d Hz, %.0f ms frames (%d samples), %s" % [
		sample_rate, frame_ms, frame_samples(), codec_id
	])
	out.append("bandwidth %d B/s per speaker" % estimated_bytes_per_second())
	out.append("capture   %s" % ("push-to-talk" if push_to_talk else
		"voice activated at %.3f rms" % activation_rms))
	out.append("jitter    %.0f ms, max %.0f ms" % [jitter_ms, jitter_max_ms])
	return out
