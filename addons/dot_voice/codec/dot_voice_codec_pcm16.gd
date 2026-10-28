@tool
class_name DotVoiceCodecPcm16
extends DotVoiceCodec

## Linear 16-bit PCM: exact, stateless, twice the bandwidth.
##
## The reference every codec is checked against (round trip within one quantisation step); fine on a LAN.

## Full scale. 32767 rather than 32768 so +1.0 and -1.0 are symmetric and neither wraps.
const SCALE := 32767.0


func id() -> StringName:
	return &"pcm16"


func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size() * 2)

	for i in range(samples.size()):
		# Clamped, not wrapped. A sample above 1.0 is a microphone that was too loud, and
		# wrapping turns it into a full-scale click of the opposite sign, which is far
		# more audible than the clipping it came from.
		var v := int(round(clampf(samples[i], -1.0, 1.0) * SCALE))
		out.encode_s16(i * 2, v)

	return out


func decode(bytes: PackedByteArray, sample_count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var available: int = mini(sample_count, bytes.size() / 2)
	out.resize(sample_count)

	for i in range(available):
		out[i] = float(bytes.decode_s16(i * 2)) / SCALE

	# A short packet is filled with silence rather than refused: a truncated frame is
	# what a lossy transport does, and a click is better than a gap in the timeline.
	for i in range(available, sample_count):
		out[i] = 0.0

	return out


func bytes_for(sample_count: int) -> int:
	return sample_count * 2


func duplicate_codec() -> DotVoiceCodec:
	# Stateless, so one instance can serve every stream. Returned as itself rather than as
	# a copy to keep the allocation out of the per-speaker path.
	return self
