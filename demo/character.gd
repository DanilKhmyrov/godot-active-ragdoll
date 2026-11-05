extends CharacterBody3D
## A demo character: the CC0 mannequin (Quaternius) on plain animation, with an ActiveRagdoll on its skeleton.
## Locomotion is the usual CharacterBody3D; everything physical comes from the addon. The parts that are the game's
## job are here too — stepping under the body (drift() in puppet mode, stagger_velocity() while staggering) and
## what to do on balance_lost.

signal fell

const MODEL := preload("res://demo/mannequin/mannequin.glb")
## Ground speed of the clips (m/s) — the character moves this fast when the clip plays at speed 1.
const CLIP_SPEED := {"Walk": 1.15, "Jog_Fwd": 2.9}
const WALK := 1.3
const RUN := 3.2
## Capsule radii (m) that fit the mannequin's mesh — measured with demo/tools/probe_radii.gd.
const MANNEQUIN_RADII := {
	"UpperChest": 0.15, "Head": 0.12,
	"LeftUpperArm": 0.06, "RightUpperArm": 0.06, "LeftLowerArm": 0.05, "RightLowerArm": 0.05,
	"LeftFoot": 0.06, "RightFoot": 0.06,
}

## Puppet mode when standing (else plain animation with hit()/stagger() reactions).
@export var puppet := true
## Walks back and forth along its local X by this many metres (0 — stands).
@export var patrol := 0.0

var ragdoll: ActiveRagdoll
var skeleton: Skeleton3D
var anim: AnimationPlayer
var crawl: CrawlModifier
## World direction to walk in (length 0..1) and whether to run — set by the player controller.
var move_dir := Vector3.ZERO
var running := false
## On the ground: fallen, dead or crawling — locomotion is off until stand_up().
var down := false
var dead := false
var crawling := false

var _step_v := Vector3.ZERO
var _patrol_origin := Vector3.ZERO
var _patrol_sign := 1.0
var _clip := ""


func _ready() -> void:
	var model := MODEL.instantiate()
	add_child(model)
	skeleton = model.find_child("GeneralSkeleton", true, false) as Skeleton3D
	anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	# the mannequin is chunkier than the profile's default body: capsules fitted to its mesh, or the head and feet
	# sink into the floor when it lies
	var profile := RagdollProfile.humanoid()
	for bone: String in MANNEQUIN_RADII:
		profile.bones[bone]["radius"] = MANNEQUIN_RADII[bone]
	ragdoll = ActiveRagdoll.create(skeleton, profile)
	ragdoll.collision_layer = 1 << 9      # the ragdoll layer: not in its own mask, self_collision adds it back
	ragdoll.collision_mask = 1            # the world
	ragdoll.balance_lost.connect(_on_balance_lost)
	# down alive and lying still: hurt, it moves on the ground and holds the wound
	ragdoll.settled.connect(func() -> void:
		if down and not dead and not crawling:
			ragdoll.writhe())
	crawl = ragdoll.add_crawl_modifier()
	_patrol_origin = global_position
	_play("Idle")
	# the ragdoll starts from what was on screen: let the animation pose the skeleton first (the first physics
	# frames can run before any process frame)
	for i in 3:
		await get_tree().process_frame
	if puppet:
		ragdoll.puppet(true)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	if crawling:
		_crawl_tick(delta)
		return
	if down:
		velocity = Vector3(0.0, velocity.y, 0.0)
		move_and_slide()
		return
	var dir := move_dir
	if patrol > 0.0:
		var x := (global_position - _patrol_origin).dot(global_basis.x)
		if absf(x) > patrol and signf(x) == _patrol_sign:
			_patrol_sign = -_patrol_sign
		dir = global_basis.x * _patrol_sign
	var want := dir * (RUN if running else WALK)
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	flat = flat.move_toward(want, 8.0 * delta)
	if ragdoll.staggering():
		# staggering: the feet go where the torso is falling — that is what catches it
		flat = ragdoll.stagger_velocity()
	elif ragdoll.stumbling():
		# stumbling (puppet): the same — the walk animation in that direction makes the physical feet step
		flat = ragdoll.stumble_velocity()
	velocity = Vector3(flat.x, velocity.y, flat.z)
	if ragdoll.is_puppet():
		# puppet: the hips were knocked off the animation — step under them, or the feet stay pinned and the body folds
		_step_v = (_step_v + ragdoll.drift() * 18.0 * delta) * exp(-4.0 * delta)
		velocity += _step_v
	move_and_slide()
	if ragdoll.is_puppet():
		velocity -= _step_v
	if dir.length() > 0.1:
		var yaw := atan2(dir.x, dir.z)
		rotation.y = lerp_angle(rotation.y, yaw, 1.0 - exp(-10.0 * delta))
	_animate(Vector3(velocity.x, 0.0, velocity.z) + _step_v)


func _animate(v: Vector3) -> void:
	var speed := v.length()
	if speed < 0.15:
		_play("Idle")
		anim.speed_scale = 1.0
		return
	var clip := "Jog_Fwd" if speed > 2.0 else "Walk"
	_play(clip)
	# stepping backwards (stagger, drift) plays the walk in reverse
	var fwd := v.dot(global_basis.z) >= -0.05
	anim.speed_scale = clampf(speed / float(CLIP_SPEED[clip]), 0.4, 2.0) * (1.0 if fwd else -1.0)


func _play(clip: String) -> void:
	if _clip != clip:
		_clip = clip
		anim.play(clip, 0.25)


## A shot: `impulse` (N·s, world) into `bone`.
func shoot(bone: StringName, impulse: Vector3) -> void:
	if ragdoll.is_puppet():
		ragdoll.puppet_hit(bone, impulse)
	elif not ragdoll.is_running():
		ragdoll.hit(bone, impulse)
	else:
		# lying: the blow lands where it hit (and a writhing body holds the new wound)
		ragdoll.knock(bone, impulse)


## A shove that may knock the body over: puppet — a blow to the balance (the body staggers; a hard one — over 1.3 m/s
## for the whole body — knocks it down); animated — stagger.
func shove(bone: StringName, impulse: Vector3) -> void:
	if ragdoll.is_puppet():
		ragdoll.puppet_hit(bone, impulse, 1.0, 0.6, 0.3)
	elif not ragdoll.is_running():
		ragdoll.stagger(bone, impulse)


## Killed by a shot into `bone`: the body collapses (legs first) carrying the blow.
func kill(bone: StringName, impulse: Vector3) -> void:
	if dead:
		return
	_go_down()
	dead = true
	var dv := impulse / 75.0
	if ragdoll.is_puppet():
		ragdoll.puppet_hit(bone, impulse * 0.5)
		ragdoll.release("die", dv)
	elif not ragdoll.is_running():
		ragdoll.start(velocity + dv)
		ragdoll.collapse()
	else:
		ragdoll.collapse()


## Knocked over alive by a blow into `bone` (`impulse`, N·s, world): falls bracing with the arms (forwards) or tucking
## the chin (backwards).
func knock_down(bone: StringName, impulse: Vector3) -> void:
	if down:
		return
	_go_down()
	ragdoll.knock(bone, impulse, "fall", velocity)


## Wounded: drops to the ground and crawls away on the physical body (puppet mode following CrawlModifier).
func start_crawl(limp_leg := "Left") -> void:
	if dead or crawling:
		return
	if not down:
		knock_down(&"Hips", Vector3.ZERO)
	crawling = true
	crawl.limp_leg = limp_leg
	crawl.weight = 1.0
	# the body is already lying: pins pull it into the crawl from where it is, gaining strength
	await get_tree().create_timer(0.8).timeout
	if not crawling:
		return
	_follow_body()
	ragdoll.puppet(true, true)
	ragdoll.strength = 0.15
	ragdoll.create_tween().tween_property(ragdoll, "strength", 1.0, 1.2)


func _crawl_tick(delta: float) -> void:
	if not ragdoll.is_puppet():
		return
	var fwd := global_basis.z
	if move_dir.length() > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(move_dir.x, move_dir.z), 1.0 - exp(-1.5 * delta))
	# the hands stay put while pulling: move forward as they pull
	velocity = Vector3(0.0, velocity.y, 0.0) + fwd * crawl.pull() * 0.26 * crawl.speed * 2.0
	move_and_slide()


## Back on the feet where the body lies (no get-up clip in the demo — the pose snaps to idle).
func stand_up() -> void:
	ragdoll.stop()
	ragdoll.strength = 1.0
	crawl.weight = 0.0
	_follow_body()
	down = false
	dead = false
	crawling = false
	velocity = Vector3.ZERO
	_step_v = Vector3.ZERO
	_clip = ""
	_play("Idle")
	if puppet:
		await get_tree().process_frame
		await get_tree().process_frame
		ragdoll.puppet(true)


## Puppet mode on/off while standing.
func set_puppet(on: bool) -> void:
	puppet = on
	if down:
		return
	if on:
		ragdoll.puppet(true)
	else:
		ragdoll.stop()


## Where the body is: the physical hips while simulating, else the character.
func body_position() -> Vector3:
	var hips := ragdoll.bones.get("Hips") as PhysicalBone3D
	if ragdoll.is_running() and hips:
		return hips.global_position
	return global_position + Vector3.UP * 0.9


## The bone a ray passes closest to (within `reach` of its capsule), or &"". Returns [bone, distance along the ray].
func pick_bone(from: Vector3, dir: Vector3, reach := 0.06) -> Array:
	var best: StringName = &""
	var best_t := INF
	for n: String in ragdoll.bones:
		var pb := ragdoll.bones[n] as PhysicalBone3D
		var xf := pb.global_transform
		if not ragdoll.is_running() or (ragdoll.hitting() and not pb.is_simulating_physics()):
			xf = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(n)) * pb.body_offset
		var half := float(pb.get_meta(&"ragdoll_length", 0.2)) * 0.5
		var r := float(pb.get_meta(&"ragdoll_radius", 0.05)) + reach
		var a := xf.origin + xf.basis.z.normalized() * half
		var b := xf.origin - xf.basis.z.normalized() * half
		var hit := _ray_segment(from, dir, a, b)
		if hit.y <= r and hit.x > 0.0 and hit.x < best_t:
			best_t = hit.x
			best = StringName(n)
	return [best, best_t]


## Closest approach of a ray (from, unit dir) and a segment a-b: (distance along the ray, distance between them).
static func _ray_segment(from: Vector3, dir: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var u := b - a
	var w := from - a
	var uu := u.dot(u)
	var ud := u.dot(dir)
	var denom := uu - ud * ud
	var s := 0.0
	if denom > 1e-6:
		s = clampf((u.dot(w) - ud * dir.dot(w)) / denom, 0.0, 1.0)
	var p := a + u * s
	var t := maxf((p - from).dot(dir), 0.0)
	return Vector2(t, (from + dir * t).distance_to(p))


func _go_down() -> void:
	down = true
	_step_v = Vector3.ZERO
	fell.emit()


func _on_balance_lost() -> void:
	if ragdoll.is_puppet():
		_go_down()
		ragdoll.release("fall")
	elif not ragdoll.is_running():
		knock_down(&"Hips", Vector3.ZERO)


## Move the character (and so the animation target) under the lying body, facing where the body points.
func _follow_body() -> void:
	var hips := ragdoll.bones.get("Hips") as PhysicalBone3D
	if hips == null or not ragdoll.is_running():
		return
	var p := hips.global_position
	# the hips capsule runs along its −Z towards the spine: where the head is, i.e. where a lying body would crawl
	var spine := -hips.global_basis.z
	spine = Vector3(spine.x, 0.0, spine.z)
	var keep := {}
	for n: String in ragdoll.bones:
		keep[n] = (ragdoll.bones[n] as PhysicalBone3D).global_transform
	global_position = Vector3(p.x, global_position.y, p.z)
	if spine.length() > 0.2:
		rotation.y = atan2(spine.x, spine.z)
	# moving the character moves the simulating bodies with it (children): put them back where they lay
	for n: String in keep:
		PhysicsServer3D.body_set_state((ragdoll.bones[n] as PhysicalBone3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, keep[n])
