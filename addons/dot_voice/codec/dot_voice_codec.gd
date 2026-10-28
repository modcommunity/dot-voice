@tool
class_name DotVoiceCodec
extends RefCounted

## Turns a frame of mono samples into bytes and back; subclass and [method register] to plug in a real codec (e.g. Opus).
##
## Samples are mono float in -1..1; listener position is applied at playback, not carried in the audio. Nothing else names a codec except through [method for_id].

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
## The count is passed because a decoder that guesses wrong plays at the wrong speed instead of erroring.
func decode(_bytes: PackedByteArray, _sample_count: int) -> PackedFloat32Array:
	return PackedFloat32Array()


## Bytes one encoded frame of [param sample_count] samples takes.
##
## For the bandwidth estimate and buffer sizes; a variable-rate codec returns its worst case.
func bytes_for(_sample_count: int) -> int:
	return 0


## Whether a decoder must see every frame in order.
##
## True for ADPCM (predictor state), false for PCM; [DotVoiceJitter] resets the decoder after a gap when true.
func is_stateful() -> bool:
	return false


## Discards any state carried between frames. Called on a gap and on a new speaker.
func reset() -> void:
	pass


## A decoder cannot share state with an encoder or another speaker.
##
## Hence [DotVoiceJitter] holds one codec per speaker: shared stateful decoding is loud noise on both.
func duplicate_codec() -> DotVoiceCodec:
	return null



static func register(codec: DotVoiceCodec) -> void:
	if codec == null or codec.id() == &"":
		DotLog.warn(CHANNEL, "refusing to register a codec with no id")
		return
	_registry[codec.id()] = codec


## Returns a codec by id, or null.
##
## Built-ins register on first call, not in a static initialiser: GDScript gives no ordering between static initialisers.
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
