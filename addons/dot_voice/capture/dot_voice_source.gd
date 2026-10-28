@tool
class_name DotVoiceSource
extends RefCounted

## Where a frame of microphone samples comes from.
##
## An interface so the suite and bots can use [DotVoiceSourceBuffer] and run the same path a player does; [DotVoiceSourceMicrophone] opens an [AudioEffectCapture].

## Samples per second this source produces.
var sample_rate: int = 24000


## Opens the device. Returns a failure the host can show a player.
func start() -> DotResult:
	return DotResult.success(true)


func stop() -> void:
	pass


## Whether at least [param sample_count] samples are ready.
func has_frame(_sample_count: int) -> bool:
	return false


## Takes one frame of mono samples in -1..1. Returns fewer than asked only when closing.
func read_frame(_sample_count: int) -> PackedFloat32Array:
	return PackedFloat32Array()


func is_running() -> bool:
	return false


func describe() -> Dictionary:
	return {"source": "none"}



## Mixes interleaved stereo frames down to mono.
##
## Averages rather than taking the left channel: some drivers put the signal on one channel and the side varies by machine.
static func to_mono(frames: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames.size())

	for i in range(frames.size()):
		out[i] = (frames[i].x + frames[i].y) * 0.5

	return out


## Resamples mono audio by linear interpolation.
##
## No low-pass, so downsampling aliases (a slight sibilant harshness); a polyphase filter in GDScript costs more than the codec. Subclass [DotVoiceSource] to plug in a GDExtension resampler.
static func resample(
	samples: PackedFloat32Array, from_rate: int, to_rate: int
) -> PackedFloat32Array:
	if from_rate == to_rate or samples.is_empty() or from_rate <= 0 or to_rate <= 0:
		return samples

	var ratio := float(from_rate) / float(to_rate)
	var count := int(floor(float(samples.size()) / ratio))
	var out := PackedFloat32Array()
	out.resize(maxi(count, 0))

	for i in range(out.size()):
		var position := float(i) * ratio
		var low := int(floor(position))
		var high: int = mini(low + 1, samples.size() - 1)
		var fraction := position - float(low)
		out[i] = lerpf(samples[low], samples[high], fraction)

	return out
