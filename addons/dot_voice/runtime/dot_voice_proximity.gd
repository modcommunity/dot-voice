@tool
class_name DotVoiceProximity
extends RefCounted

## The arithmetic of proximity voice, in one place the router and the tests share.
##
## [b]Why a gain and not only a range.[/b] A hard radius is a voice that is at full volume
## at 39 m and gone at 41 m. Real hearing is a curve, so the server computes a gain per
## listener and the listener's client applies it ([member DotVoicePacket.gain]). The server
## computes it, not the listener, because the server is the one that already knows both
## positions, already has the wall test, and is the only party a modified client cannot
## talk out of the answer.

## How loudness falls from [param min_distance] to the radius. Every curve is 1.0 at the
## minimum distance and exactly 0.0 at the radius, so the range is where the server stops
## sending and nothing audible is cut off by it.
enum Falloff {
	## Straight line down.
	LINEAR = 0,
	## Like distance in air (1/d), rescaled to reach zero at the radius.
	INVERSE = 1,
	## Gentle near the speaker, steep at the edge; the quietest curve.
	QUADRATIC = 2,
}


## Gain 0..1 for a listener [param distance] metres from a speaker.
static func gain(distance: float, radius: float, min_distance: float, falloff: int) -> float:
	if radius <= 0.0:
		return 1.0
	if distance >= radius:
		return 0.0
	var near := clampf(min_distance, 0.0, radius * 0.99)
	if distance <= near:
		return 1.0
	var t := (distance - near) / (radius - near)
	match falloff:
		Falloff.INVERSE:
			# near/d is the physical curve; subtracting its value at the radius makes it
			# land on zero there instead of stopping at a nonzero step.
			var edge := near / radius
			return clampf((near / distance - edge) / (1.0 - edge), 0.0, 1.0)
		Falloff.QUADRATIC:
			return (1.0 - t) * (1.0 - t)
		_:
			return 1.0 - t


## A cheap occluder for [member DotVoiceRouter.occlusion_fn]: one ray between the two heads.
##
## [param space_fn] returns the server's [PhysicsDirectSpaceState3D] (or null: nothing is
## then occluded). One ray per listener already inside the radius, never per player, which
## is why this can be on by default in a game that wants it. Rays are lifted to head height
## so a floor does not occlude two people on it.
static func ray_occluder(space_fn: Callable, mask: int = 1, head_height: float = 1.6) -> Callable:
	return func(listener_at: Vector3, speaker_at: Vector3) -> bool:
		var space: Variant = space_fn.call()
		if not (space is PhysicsDirectSpaceState3D):
			return false
		var lift := Vector3.UP * head_height
		var query := PhysicsRayQueryParameters3D.create(listener_at + lift, speaker_at + lift, mask)
		return not (space as PhysicsDirectSpaceState3D).intersect_ray(query).is_empty()
