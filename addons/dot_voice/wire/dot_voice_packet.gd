@tool
class_name DotVoicePacket
extends RefCounted

## One frame of encoded speech, as it travels.
##
## [codeblock]
## byte  0     version (1)
## byte  1     flags
## bytes 2-3   speaker id, unsigned
## bytes 4-5   sequence, unsigned, wraps
## bytes 6-7   sample count in this frame
## byte  8     channel
## byte  9     codec id index, or 255 with a length-prefixed name
## bytes ...   payload
## [/codeblock]
##
## [b]Ten bytes of header on a 124-byte ADPCM frame is 8%, and every field earns it:[/b]
##
## - [b]speaker[/b] because a listener receives a relayed packet and has to know whose
##   jitter buffer it belongs in. A transport's own sender id is the SERVER on every
##   relayed packet, which is the same for everyone.
## - [b]sequence[/b] because UDP reorders, and a jitter buffer that cannot order frames
##   plays them in arrival order, which is worse than dropping the late one.
## - [b]sample count[/b] because a stateful codec cannot always tell from the bytes, and
##   guessing wrong yields speech at the wrong speed rather than an error.
## - [b]channel[/b] because a server relaying to a team and to everybody is relaying the
##   same audio twice, and the listener has to know which it is hearing to apply the
##   right gain.
## - [b]codec[/b] because a mismatch is otherwise silent noise. See
##   [method DotVoiceConfig.format_fingerprint].
##
## The version byte is first so a future format can be refused rather than misread.

const VERSION := 1
const HEADER_BYTES := 10

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
## [b]The decoder needs to know a stream started.[/b] Without it a speaker who stops for
## a minute and starts again resumes into a jitter buffer still holding their old
## sequence numbers, and every new frame looks impossibly late and is discarded. The
## speaker is then inaudible until the sequence wraps around, which at 50 frames a second
## is twenty-two minutes.
var starts_talk_spurt: bool = false

const FLAG_START := 1 << 0


func to_bytes() -> PackedByteArray:
	var out := PackedByteArray()

	var index := CODEC_IDS.find(String(codec_id))
	var extended := index < 0

	var name_bytes := String(codec_id).to_utf8_buffer() if extended else PackedByteArray()
	out.resize(HEADER_BYTES + (1 + name_bytes.size() if extended else 0) + payload.size())

	out.encode_u8(0, VERSION)
	out.encode_u8(1, FLAG_START if starts_talk_spurt else 0)
	out.encode_u16(2, speaker & 0xFFFF)
	out.encode_u16(4, sequence & 0xFFFF)
	out.encode_u16(6, sample_count & 0xFFFF)
	out.encode_u8(8, channel & 0xFF)
	out.encode_u8(9, CODEC_EXTENDED if extended else index)

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
## [b]Every field is bounds-checked, because this is attacker-controlled input.[/b] A
## voice packet arrives from a client before that client has done anything else
## trustworthy, and a decoder that believes a declared sample count allocates whatever it
## is told to.
static func from_bytes(bytes: PackedByteArray, max_samples: int = 4096) -> DotResult:
	if bytes.size() < HEADER_BYTES:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet is shorter than its header.",
			"%d bytes" % bytes.size()
		)

	var version := bytes.decode_u8(0)
	if version != VERSION:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This voice packet is a format this build does not read.",
			"got version %d, expected %d" % [version, VERSION]
		)

	var packet := DotVoicePacket.new()
	var flags := bytes.decode_u8(1)
	packet.starts_talk_spurt = (flags & FLAG_START) != 0
	packet.speaker = bytes.decode_u16(2)
	packet.sequence = bytes.decode_u16(4)
	packet.sample_count = bytes.decode_u16(6)
	packet.channel = bytes.decode_u8(8)

	if packet.sample_count <= 0 or packet.sample_count > max_samples:
		# A packet claiming a million samples is either a bug or an attempt to make the
		# receiver allocate. Refused rather than clamped: a clamp would decode it as
		# something, and something is worse than nothing here.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet declares an unreasonable frame length.",
			"%d samples, limit %d" % [packet.sample_count, max_samples]
		)

	var codec_index := bytes.decode_u8(9)
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


## Distance from [param earlier] to this packet's sequence, accounting for the wrap.
##
## [b]Sequence numbers wrap at 65536 and a naive subtraction is wrong across it.[/b]
## Frame 0 arriving after frame 65535 is one frame later, not 65535 frames earlier, and a
## jitter buffer that gets this wrong discards a speaker's audio for eleven minutes once
## every twenty. Returns a signed distance in half the range either way.
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
