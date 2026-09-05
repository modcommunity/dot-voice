@tool
class_name DotVoiceCodecAdpcm
extends DotVoiceCodec

## IMA ADPCM: four bits a sample, so a quarter of PCM's bandwidth.
##
## [b]This is the default codec, and the reason is arithmetic.[/b] At 24 kHz, PCM is
## 48 kB/s per speaker. A twenty-slot server where four people are talking relays each of
## them to nineteen listeners, which is 3.6 MB/s of upstream on PCM and 900 kB/s on this.
## The first number is why community servers historically shipped a codec rather than raw
## samples.
##
## It costs a small amount of hiss on quiet passages, which is what a 4-bit residual
## sounds like, and nothing at all on speech at a normal level.
##
## [b]It is stateful, and that is the thing to be careful about.[/b] Each frame's decode
## depends on the predictor and step index the previous frame left behind, so:
##
## - every speaker needs their own instance ([method DotVoiceCodec.instance_for]);
## - a lost frame desynchronises the decoder from the encoder until the state converges
##   again, which is why each packet carries its own starting state in a four-byte
##   preamble rather than relying on the stream being intact.
##
## That preamble costs 4 bytes on a 240-byte frame, under 2%, and buys recovery from any
## single loss on the very next packet. Without it one dropped packet makes a speaker
## sound wrong until they stop talking.

## IMA's step size table. Fixed by the format; do not "tidy" it.
##
## A [code]static var[/code] holding a [PackedInt32Array] rather than a [code]const[/code]
## holding an [Array], and the reason is a parse error this family has documented: an
## untyped [Array] yields [Variant] when indexed, so [code]var step := TABLE[i][/code]
## does not compile under these projects' warning settings. Typing the container fixes it
## at the source instead of at every use.
static var STEP_TABLE := PackedInt32Array([
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
	253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
	1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
	3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
	11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
	32767,
])

## How the step index moves for each 4-bit code. Also fixed by the format.
static var INDEX_TABLE := PackedInt32Array([
	-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
])

const SCALE := 32767.0

## Encoder state, carried between frames so the predictor tracks the signal.
var _predictor: int = 0
var _index: int = 0


func id() -> StringName:
	return &"adpcm"


func is_stateful() -> bool:
	return true


func reset() -> void:
	_predictor = 0
	_index = 0


func duplicate_codec() -> DotVoiceCodec:
	# A real copy, every time. Two speakers sharing one instance interleave their
	# predictors, and the result is not slightly wrong, it is loud noise on both.
	return DotVoiceCodecAdpcm.new()


func bytes_for(sample_count: int) -> int:
	# Four bytes of state, then one nibble a sample rounded up to whole bytes.
	return 4 + int((sample_count + 1) / 2)


func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(bytes_for(samples.size()))

	# The starting state goes on the wire, so a decoder that missed the previous frame
	# still decodes this one correctly.
	out.encode_s16(0, clampi(_predictor, -32768, 32767))
	out.encode_u8(2, _index)
	out.encode_u8(3, 0)

	var byte_at := 4
	var nibble_high := false
	var pending := 0

	for i in range(samples.size()):
		var sample := int(round(clampf(samples[i], -1.0, 1.0) * SCALE))
		var step := STEP_TABLE[_index]
		var diff := sample - _predictor

		var code := 0
		if diff < 0:
			code = 8
			diff = -diff

		# The three magnitude bits, most significant first. Written out rather than
		# looped because the reconstruction below has to mirror it exactly and a reader
		# comparing the two should not have to unroll a loop in their head.
		var delta := step >> 3
		if diff >= step:
			code |= 4
			diff -= step
			delta += step
		if diff >= (step >> 1):
			code |= 2
			diff -= step >> 1
			delta += step >> 1
		if diff >= (step >> 2):
			code |= 1
			delta += step >> 2

		if (code & 8) != 0:
			_predictor -= delta
		else:
			_predictor += delta

		_predictor = clampi(_predictor, -32768, 32767)
		_index = clampi(_index + INDEX_TABLE[code], 0, STEP_TABLE.size() - 1)

		if nibble_high:
			out.encode_u8(byte_at, pending | (code << 4))
			byte_at += 1
			nibble_high = false
		else:
			pending = code
			nibble_high = true

	if nibble_high:
		out.encode_u8(byte_at, pending)

	return out


func decode(bytes: PackedByteArray, sample_count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(sample_count)

	if bytes.size() < 4:
		# Too short to carry even the state. Silence rather than a refusal, for the
		# reason the PCM codec gives: a truncated frame is what a lossy transport does.
		for i in range(sample_count):
			out[i] = 0.0
		return out

	# Adopted from the packet, not carried over from whatever this decoder was doing.
	# That is what makes a single lost frame cost one frame instead of the rest of the
	# sentence.
	var predictor := bytes.decode_s16(0)
	var index := clampi(bytes.decode_u8(2), 0, STEP_TABLE.size() - 1)

	var byte_at := 4
	var take_high := false
	var current := 0

	for i in range(sample_count):
		var code := 0

		if take_high:
			code = (current >> 4) & 0x0F
			take_high = false
		elif byte_at < bytes.size():
			current = bytes.decode_u8(byte_at)
			byte_at += 1
			code = current & 0x0F
			take_high = true
		else:
			# Ran out of payload. Hold the predictor rather than jumping to zero, which
			# is a step edge and audible as a click.
			out[i] = float(predictor) / SCALE
			continue

		var step := STEP_TABLE[index]
		var delta := step >> 3
		if (code & 4) != 0:
			delta += step
		if (code & 2) != 0:
			delta += step >> 1
		if (code & 1) != 0:
			delta += step >> 2

		if (code & 8) != 0:
			predictor -= delta
		else:
			predictor += delta

		predictor = clampi(predictor, -32768, 32767)
		index = clampi(index + INDEX_TABLE[code], 0, STEP_TABLE.size() - 1)

		out[i] = float(predictor) / SCALE

	_predictor = predictor
	_index = index

	return out
