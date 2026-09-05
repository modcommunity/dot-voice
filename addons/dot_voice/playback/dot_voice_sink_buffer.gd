@tool
class_name DotVoiceSinkBuffer
extends DotVoiceSink

## A sink that keeps what it was given, so a test can look at it.
##
## What makes the suite able to say "the listener heard the tone and the muted player
## heard nothing" rather than "no errors were logged", which is the difference between a
## test and a smoke test.

var samples: PackedFloat32Array = PackedFloat32Array()
var frames_written: int = 0

## Cap so a long-running test cannot exhaust memory. 0 keeps everything.
var max_samples: int = 0

var _running: bool = false


func start() -> DotResult:
	_running = true
	return DotResult.success(true)


func stop() -> void:
	_running = false


func is_running() -> bool:
	return _running


func can_accept(_sample_count: int) -> bool:
	return true


func write_frame(frame: PackedFloat32Array) -> void:
	samples.append_array(frame)
	frames_written += 1

	if max_samples > 0 and samples.size() > max_samples:
		samples = samples.slice(samples.size() - max_samples)


func clear() -> void:
	samples = PackedFloat32Array()
	frames_written = 0


## Loudness of everything written, which is what "did they hear anything" means.
func rms() -> float:
	return DotVoiceGate.rms(samples)


## Loudness of the last [param count] samples, for asserting that audio stopped.
func recent_rms(count: int) -> float:
	if samples.size() <= count:
		return rms()
	return DotVoiceGate.rms(samples.slice(samples.size() - count))


## Largest absolute sample, for asserting nothing clipped.
func peak() -> float:
	var best := 0.0
	for i in range(samples.size()):
		best = maxf(best, absf(samples[i]))
	return best


func describe() -> Dictionary:
	return {
		"sink": "buffer",
		"samples": samples.size(),
		"frames": frames_written,
		"rms": rms(),
	}
