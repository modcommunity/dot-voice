@tool
class_name DotVoiceSink
extends RefCounted

## Where decoded audio goes.
##
## The other half of the split [DotVoiceSource] describes: [DotVoiceSinkPlayer] pushes
## into an [AudioStreamGenerator], [DotVoiceSinkBuffer] keeps the samples so a test can
## assert on what a listener would have heard. Nothing above this can tell them apart.

## Samples per second this sink expects.
var sample_rate: int = 24000


func start() -> DotResult:
	return DotResult.success(true)


func stop() -> void:
	pass


## Whether the sink can take another frame right now.
func can_accept(_sample_count: int) -> bool:
	return false


## Plays one frame of mono samples.
func write_frame(_samples: PackedFloat32Array) -> void:
	pass


func is_running() -> bool:
	return false


func describe() -> Dictionary:
	return {"sink": "none"}
