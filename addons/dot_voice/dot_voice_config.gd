@tool
class_name DotVoiceConfig
extends DotConfig

## Voice settings, layered: exported defaults < JSON file < environment < command line.
##
## [member sample_rate], [member frame_ms] and the codec must agree on both ends of a connection; everything else is a local preference.

@export_group("Format")

## Samples per second on the wire, not the engine's mix rate.
##
## Capture arrives at 44100, about three times what speech needs; 16000 resolves a telephone's consonants and 24000 is clearly better. Both ends must agree.
@export_enum("8000:8000", "12000:12000", "16000:16000", "24000:24000", "48000:48000")
var sample_rate: int = 24000

## Milliseconds of audio in one packet.
##
## The latency/overhead trade: below 10 ms the header dominates, above 60 ms a lost packet is an audible hole.
@export_range(10.0, 60.0, 10.0) var frame_ms: float = 20.0

## Codec id, resolved by [method DotVoiceCodec.for_id].
##
## [code]pcm16[/code] is exact at 16 bits a sample; [code]adpcm[/code] (default) is a quarter of the bandwidth with slight hiss.
@export var codec_id: StringName = &"adpcm"

@export_group("Capture")

## How the microphone is opened.
##
## Off by default on every platform: opening one because a node entered the tree records people who did not ask. The host calls [method DotVoiceManager.start_capture] once a player agrees.
@export var capture_enabled: bool = false

## Hold a key to talk, rather than opening on volume.
##
## On by default. Voice activation in a room with a fan in it transmits the fan.
@export var push_to_talk: bool = true

## Loudness the gate opens at, as RMS in 0..1, when [member push_to_talk] is off.
@export_range(0.0, 0.5, 0.001) var activation_rms: float = 0.02

## How far the gate must fall below [member activation_rms] before it closes.
##
## Hysteresis: a speaker sitting at a single threshold chatters into quarter-syllables.
@export_range(0.1, 1.0, 0.05) var release_ratio: float = 0.6

## Milliseconds the gate stays open after the signal drops.
##
## Speech has gaps; without a hangover words lose their consonants.
@export_range(0.0, 2000.0, 10.0) var hangover_ms: float = 250.0

## Microphone gain, applied before the gate.
@export_range(0.1, 8.0, 0.1) var input_gain: float = 1.0

@export_group("Playback")

## Milliseconds of audio held before a speaker starts playing (the jitter buffer).
##
## Zero stutters on the first late packet; too much and people talk over each other.
@export_range(0.0, 500.0, 10.0) var jitter_ms: float = 60.0

## Milliseconds the buffer may grow to before it drops the oldest frames.
##
## A reconnecting or catching-up sender would otherwise accumulate delay for ever.
@export_range(100.0, 2000.0, 50.0) var jitter_max_ms: float = 400.0

## Output gain, applied per speaker after decode.
@export_range(0.0, 4.0, 0.05) var output_gain: float = 1.0

@export_group("Routing")

## Metres a proximity channel can be heard over. 0 disables the falloff.
@export_range(0.0, 500.0, 1.0) var proximity_range: float = 40.0

## Bytes per second one speaker may send before the server stops relaying.
##
## Stops voice being an amplifier (one speaker costs the server rate times player count). Enforced on the server; a client's own limit is not a limit.
@export_range(0, 65536, 256) var max_bytes_per_second: int = 4096


func env_prefix() -> String:
	return "DOT_VOICE_"


func cli_prefix() -> String:
	return "--voice-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray()


## Samples in one frame at the configured rate and duration.
##
## The one place this is computed: two differing copies read a frame at the wrong length and play speech at the wrong pitch.
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
## A format mismatch is silent (ADPCM read as PCM is noise, a 20 ms frame read as 40 ms is half speed); exchanging this at handshake makes it one refusal.
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
