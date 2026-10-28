@tool
class_name DotVoicePacket
extends RefCounted

## One frame of encoded speech. Header layout in docs/design.md (wire format); offsets are the [code]OFFSET_*[/code] constants.
##
## Fields: version (first, so a new format is refused), flags, 32-bit speaker (a relayed packet's transport sender is the server), sequence, sample count, channel, codec index.

## Version 2 widened the speaker from 16 to 32 bits: Godot peer ids are 31-bit, so two players differing above bit 16 became one speaker and decoded to noise.
const VERSION := 2

## Where each header field sits, named once so tests do not hand-write offsets.
const OFFSET_VERSION := 0
const OFFSET_FLAGS := 1
const OFFSET_SPEAKER := 2
const OFFSET_SEQUENCE := 6
const OFFSET_SAMPLE_COUNT := 8
const OFFSET_CHANNEL := 10
const OFFSET_CODEC := 11

const HEADER_BYTES := 12

## Codec ids that fit in one byte. Anything else goes in the extended form, so a project
## that registers its own codec still works, just with a few more bytes of header.
const CODEC_IDS := ["pcm16", "adpcm"]
const CODEC_EXTENDED := 255

## Who is talking. Set by the server on relay, never trusted from a client.
var speaker: int = 0

## Frame counter, per speaker, wrapping at 65536.
var sequence: int = 0

## Samples in the decoded frame.
var sample_count: int = 0

## Which channel this was spoken on. See [DotVoiceRouter].
var channel: int = 0

var codec_id: StringName = &"adpcm"

var payload: PackedByteArray = PackedByteArray()

## Set on the first packet after a gate opens.
##
## Without it a resumed speaker lands in a jitter buffer holding old sequence numbers and is discarded until the wrap.
var starts_talk_spurt: bool = false

const FLAG_START := 1 << 0

## Bits 1..7 of the flags byte carry the listener's gain, 0..127; 0 means unattenuated.
## Not a new field, so the version stays 2: older builds mask with FLAG_START and play at full volume.
const GAIN_SHIFT := 1
const GAIN_STEPS := 127

## Loudness the server wants this listener to hear this frame at, 0..1. 1.0 is full.
var gain: float = 1.0


## The flags byte value for a gain, to patch into a copy of an encoded packet per listener.
static func gain_bits(g: float) -> int:
	if g >= 1.0:
		return 0
	return clampi(roundi(g * GAIN_STEPS), 1, GAIN_STEPS) << GAIN_SHIFT


func to_bytes() -> PackedByteArray:
	var out := PackedByteArray()

	var index := CODEC_IDS.find(String(codec_id))
	var extended := index < 0

	var name_bytes := String(codec_id).to_utf8_buffer() if extended else PackedByteArray()
	out.resize(HEADER_BYTES + (1 + name_bytes.size() if extended else 0) + payload.size())

	out.encode_u8(OFFSET_VERSION, VERSION)
	out.encode_u8(OFFSET_FLAGS, (FLAG_START if starts_talk_spurt else 0) | gain_bits(gain))
	# 32 bits (see [constant VERSION]); masked so a larger host id (occupant, database row)
	# truncates predictably.
	out.encode_u32(OFFSET_SPEAKER, speaker & 0xFFFFFFFF)
	out.encode_u16(OFFSET_SEQUENCE, sequence & 0xFFFF)
	out.encode_u16(OFFSET_SAMPLE_COUNT, sample_count & 0xFFFF)
	out.encode_u8(OFFSET_CHANNEL, channel & 0xFF)
	out.encode_u8(OFFSET_CODEC, CODEC_EXTENDED if extended else index)

	var at := HEADER_BYTES

	if extended:
		out.encode_u8(at, name_bytes.size())
		at += 1
		for i in range(name_bytes.size()):
			out.encode_u8(at + i, name_bytes[i])
		at += name_bytes.size()

	for i in range(payload.size()):
		out.encode_u8(at + i, payload[i])

	return out


## Parses bytes off the wire.
##
## Every field is bounds-checked: this is attacker-controlled input and a declared sample count must not drive an allocation.
static func from_bytes(bytes: PackedByteArray, max_samples: int = 4096) -> DotResult:
	if bytes.size() < HEADER_BYTES:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet is shorter than its header.",
			"%d bytes" % bytes.size()
		)

	var version := bytes.decode_u8(OFFSET_VERSION)
	if version != VERSION:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This voice packet is a format this build does not read.",
			"got version %d, expected %d" % [version, VERSION]
		)

	var packet := DotVoicePacket.new()
	var flags := bytes.decode_u8(OFFSET_FLAGS)
	packet.starts_talk_spurt = (flags & FLAG_START) != 0
	var steps := flags >> GAIN_SHIFT
	packet.gain = 1.0 if steps == 0 else float(steps) / float(GAIN_STEPS)
	packet.speaker = bytes.decode_u32(OFFSET_SPEAKER)
	packet.sequence = bytes.decode_u16(OFFSET_SEQUENCE)
	packet.sample_count = bytes.decode_u16(OFFSET_SAMPLE_COUNT)
	packet.channel = bytes.decode_u8(OFFSET_CHANNEL)

	if packet.sample_count <= 0 or packet.sample_count > max_samples:
		# A packet claiming a million samples is either a bug or an attempt to make the
		# receiver allocate. Refused rather than clamped: a clamp would decode it as
		# something, and something is worse than nothing here.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet declares an unreasonable frame length.",
			"%d samples, limit %d" % [packet.sample_count, max_samples]
		)

	var codec_index := bytes.decode_u8(OFFSET_CODEC)
	var at := HEADER_BYTES

	if codec_index == CODEC_EXTENDED:
		if bytes.size() < at + 1:
			return DotResult.fail(
				DotError.CODE_INVALID, "A voice packet's codec name is truncated."
			)
		var name_length := bytes.decode_u8(at)
		at += 1
		if bytes.size() < at + name_length:
			return DotResult.fail(
				DotError.CODE_INVALID, "A voice packet's codec name is truncated."
			)
		packet.codec_id = StringName(
			bytes.slice(at, at + name_length).get_string_from_utf8()
		)
		at += name_length
	elif codec_index < CODEC_IDS.size():
		packet.codec_id = StringName(CODEC_IDS[codec_index])
	else:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet names a codec slot that does not exist.",
			"slot %d" % codec_index
		)

	packet.payload = bytes.slice(at)

	return DotResult.success(packet)


## Distance from [param earlier] to this packet's sequence, accounting for the 16-bit wrap.
##
## Frame 0 after 65535 is one later; naive subtraction discards a speaker for minutes. Signed, half the range either way.
static func sequence_delta(later: int, earlier: int) -> int:
	var d := (later - earlier) & 0xFFFF
	return d - 65536 if d > 32767 else d


func size_bytes() -> int:
	return HEADER_BYTES + payload.size()


func describe() -> Dictionary:
	return {
		"speaker": speaker,
		"sequence": sequence,
		"samples": sample_count,
		"channel": channel,
		"codec": String(codec_id),
		"bytes": size_bytes(),
		"start": starts_talk_spurt,
	}
