@tool
class_name DotVoiceSource
extends RefCounted

## Where a frame of microphone samples comes from.
##
## [b]This split is what makes the addon testable, and it is not an afterthought.[/b] A
## voice system whose only input is a real microphone can be run by a person wearing
## headphones and by nothing else: no headless suite, no bot, no regression test, and
## every bug found the way this family's bugs get found, which is expensively and late.
##
## So the device is one implementation of an interface. [DotVoiceSourceMicrophone] opens
## an [AudioEffectCapture]; [DotVoiceSourceBuffer] hands over samples a test wrote. The
## manager cannot tell them apart, which means the suite exercises the same code path a
## player does.
##
## The same reasoning, and the same shape, as [code]DotFpsSampler[/code]: input devices,
## bots and demo playback behind one interface.

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


# --- Shared helpers --------------------------------------------------------

## Mixes interleaved stereo frames down to mono.
##
## A microphone is one microphone, but Godot hands capture back as [Vector2] frames
## because its audio bus is stereo throughout. Averaging rather than taking the left
## channel: some drivers put the signal on one channel and silence on the other, and
## which one is not consistent, so taking a channel gives silence on some machines and
## works on the developer's.
static func to_mono(frames: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames.size())

	for i in range(frames.size()):
		out[i] = (frames[i].x + frames[i].y) * 0.5

	return out


## Resamples mono audio from one rate to another by linear interpolation.
##
## [b]Honest about what this is:[/b] linear interpolation without a low-pass filter
## aliases when downsampling, which is what going from a 44100 Hz capture to a 24000 Hz
## wire is. The audible result on speech is a slight harshness on sibilants, and it is
## the trade every voice system in a scripting language makes, because a proper
## polyphase filter in GDScript costs more per frame than the codec does.
##
## A project that cares plugs in a GDExtension resampler by subclassing
## [DotVoiceSource] and doing the conversion in the source.
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
