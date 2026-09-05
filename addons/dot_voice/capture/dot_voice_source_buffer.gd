@tool
class_name DotVoiceSourceBuffer
extends DotVoiceSource

## A source fed by hand. For tests, bots, and playing a recording back into the system.
##
## [b]This is the class the headless suite runs.[/b] Everything above it — the gate, the
## codec, the packet, the router, the jitter buffer — is exercised by writing samples in
## here and reading audio out of a [DotVoiceSinkBuffer] at the other end, with no audio
## device anywhere in the process. That is the whole reason [DotVoiceSource] exists as an
## interface rather than as a microphone.

var _pending: PackedFloat32Array = PackedFloat32Array()
var _running: bool = false

## Set to loop [member _pending] for ever, so a bot can talk indefinitely off one second
## of samples.
var loop: bool = false
var _loop_source: PackedFloat32Array = PackedFloat32Array()


func start() -> DotResult:
	_running = true
	return DotResult.success(true)


func stop() -> void:
	_running = false


func is_running() -> bool:
	return _running


## Queues samples to be read out a frame at a time.
func write(samples: PackedFloat32Array) -> void:
	_pending.append_array(samples)
	if loop and _loop_source.is_empty():
		_loop_source = samples.duplicate()


func has_frame(sample_count: int) -> bool:
	if _pending.size() >= sample_count:
		return true
	return loop and not _loop_source.is_empty()


func read_frame(sample_count: int) -> PackedFloat32Array:
	if loop and _pending.size() < sample_count and not _loop_source.is_empty():
		_pending.append_array(_loop_source)

	if _pending.size() < sample_count:
		return PackedFloat32Array()

	var out := _pending.slice(0, sample_count)
	_pending = _pending.slice(sample_count)
	return out


func available() -> int:
	return _pending.size()


func clear() -> void:
	_pending = PackedFloat32Array()


func describe() -> Dictionary:
	return {"source": "buffer", "pending": _pending.size(), "loop": loop}


# --- Test signals ----------------------------------------------------------

## A sine wave, for a signal a test can assert on.
##
## Speech is not a sine wave, but a sine is the one signal whose round trip through a
## codec can be measured rather than listened to: the error is the difference, and it has
## a number.
static func tone(
	frequency: float, seconds: float, rate: int, amplitude: float = 0.5
) -> PackedFloat32Array:
	var count := int(float(rate) * seconds)
	var out := PackedFloat32Array()
	out.resize(count)

	for i in range(count):
		out[i] = sin(TAU * frequency * float(i) / float(rate)) * amplitude

	return out


## Deterministic noise, for exercising a codec's worst case.
##
## Seeded rather than random: a codec test that fails one run in fifty and passes the
## rest is a test nobody trusts, and this family has already been bitten by a hash that
## only returned half its range.
static func noise(
	seconds: float, rate: int, amplitude: float = 0.5, seed_value: int = 12345
) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var count := int(float(rate) * seconds)
	var out := PackedFloat32Array()
	out.resize(count)

	for i in range(count):
		out[i] = rng.randf_range(-amplitude, amplitude)

	return out


## Silence, for testing that a gate stays shut.
static func silence(seconds: float, rate: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(float(rate) * seconds))
	out.fill(0.0)
	return out
