@tool
class_name DotVoiceCodec
extends RefCounted

## Turns a frame of mono samples into bytes and back.
##
## [b]Subclass this to plug in a real codec.[/b] Godot exposes no Opus encoder to
## GDScript, so the two shipped here are what can be written in the language: exact
## 16-bit PCM, and IMA ADPCM at a quarter of the size. A project that ships an Opus
## GDExtension registers it with [method register] and every other class in this addon
## picks it up without changing, because nothing here names a codec except through
## [method for_id].
##
## [codeblock]
## class MyOpusCodec extends DotVoiceCodec:
##     func id() -> StringName: return &"opus"
##     func encode(samples: PackedFloat32Array) -> PackedByteArray: ...
##     func decode(bytes: PackedByteArray, count: int) -> PackedFloat32Array: ...
##
## DotVoiceCodec.register(MyOpusCodec.new())
## [/codeblock]
##
## [b]Samples are mono float in -1..1.[/b] Voice is mono because a microphone is one
## microphone and stereo doubles the wire for nothing; where a listener sits relative to
## a speaker is applied at playback, from the speaker's position, not carried in the
## audio.

const CHANNEL := "voice.codec"

## id -> DotVoiceCodec, filled by [method register].
static var _registry: Dictionary = {}


## Short stable id, carried in every packet's header.
func id() -> StringName:
	return &""


## Encodes one frame. Must accept any length; callers pad or trim to the frame size.
func encode(_samples: PackedFloat32Array) -> PackedByteArray:
	return PackedByteArray()


## Decodes one frame back to [param sample_count] samples.
##
## [param sample_count] is passed rather than derived because a codec may not be able to
## tell from the bytes alone, and because a decoder that guesses wrong produces audio at
## the wrong speed instead of an error.
func decode(_bytes: PackedByteArray, _sample_count: int) -> PackedFloat32Array:
	return PackedFloat32Array()


## Bytes one encoded frame of [param sample_count] samples takes.
##
## Used for the bandwidth estimate and to size buffers. A variable-rate codec returns its
## worst case, because the point of the number is a ceiling.
func bytes_for(_sample_count: int) -> int:
	return 0


## Whether a decoder must see every frame in order.
##
## True for ADPCM and anything else carrying predictor state between frames, false for
## PCM. [DotVoiceJitter] reads this to decide whether a gap can be concealed by simply
## carrying on, or whether the decoder has to be reset first.
func is_stateful() -> bool:
	return false


## Discards any state carried between frames. Called on a gap and on a new speaker.
func reset() -> void:
	pass


## A decoder cannot share state with an encoder, or with another speaker.
##
## [b]This is the reason [DotVoiceJitter] holds one codec per speaker[/b] rather than one
## for the whole system. Two speakers decoded through one stateful codec interleave their
## predictor state, and the result is not "slightly wrong", it is loud noise on both.
func duplicate_codec() -> DotVoiceCodec:
	return null


# --- Registry --------------------------------------------------------------

static func register(codec: DotVoiceCodec) -> void:
	if codec == null or codec.id() == &"":
		DotLog.warn(CHANNEL, "refusing to register a codec with no id")
		return
	_registry[codec.id()] = codec


## Returns a codec by id, or null.
##
## The built-ins register themselves the first time this is called rather than in a
## static initialiser, because GDScript gives no ordering guarantee between one static
## initialiser and another and a registry that is sometimes empty is worse than one that
## is always filled on demand.
static func for_id(codec_id: StringName) -> DotVoiceCodec:
	_ensure_builtins()
	var found: Variant = _registry.get(codec_id)
	return found as DotVoiceCodec if found != null else null


## A private codec instance for one stream. Never share one between speakers.
static func instance_for(codec_id: StringName) -> DotVoiceCodec:
	var template := for_id(codec_id)
	if template == null:
		return null
	var copy := template.duplicate_codec()
	return copy if copy != null else template


static func known_ids() -> PackedStringArray:
	_ensure_builtins()
	var out := PackedStringArray()
	for key in _registry.keys():
		out.append(String(key))
	out.sort()
	return out


static func _ensure_builtins() -> void:
	if _registry.has(&"pcm16"):
		return
	register(DotVoiceCodecPcm16.new())
	register(DotVoiceCodecAdpcm.new())
