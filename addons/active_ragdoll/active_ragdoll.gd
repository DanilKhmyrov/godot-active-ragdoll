class_name ActiveRagdoll
extends Node
## Powered ragdoll: every physical bone has a "muscle" that turns it, relative to its physical parent, towards a
## target pose — a velocity motor: each tick the bone's angular velocity is pulled towards the parent's plus a
## correction of the pose error, the parent gets the opposite change scaled by inertia (momentum is kept). Unlike a
## torque spring this is stable at any tick rate — a strong torque on a light body (a vertebra carrying the whole
## upper body) spins it in one tick and tears the joints apart (the body stretches like rubber). Muscle tone (0..1 per bone) is what the behaviours animate:
##
##   collapse()  — death: the pose at that moment is held, then muscles give out by group (legs first, then spine
##                 and head, arms last) — the body buckles and slumps instead of dropping like a plank.
##   fall()      — alive fall: some tone that fades, arms brace towards the ground when falling forwards, chin
##                 tucks and arms come in when falling backwards.
##   hit()       — a hit without falling: only the upper body simulates (legs keep walking), muscles pull it back to
##                 the live animation; the simulation stops by itself when the pose has recovered.
##   stagger()   — a blow that may knock the body over: the torso sways as an inverted pendulum (LeanModifier tilts
##                 the spine on top of the animation, no bone physics) and stagger_velocity() tells the game where to
##                 step (under the torso) — your locomotion moves the character, the walk animation makes the steps.
##                 Torso too far — balance_lost (start() + fall() it); caught — recovered.
##
##   puppet()    — PUPPET MODE (PuppetMaster / Euphoria style): the body is physical all the time, the animation is
##                 only the target. Muscles pull joints to the animated pose, pins pull bodies to where the animation
##                 has them (feet hard, hands soft — they deflect off obstacles and other limbs). A hit weakens pins and
##                 muscles of the struck part: it really flies off with the blow, collides with the body, and is pulled
##                 back. A heavy hit weakens the hips' pin — the body really sags and sways; the game reads drift()
##                 (where the hips went from the animation) to step under them; too far — balance_lost and release():
##                 pins let go, muscles fade, the body falls carrying the motion it already had.
##
## The target pose is either live animation (the skeleton's pose outside its modifier update is the animated one —
## SkeletonModifier3D changes are temporary) or a snapshot taken when the ragdoll started.
##
## Setup:
##   var ar := ActiveRagdoll.create(skeleton, RagdollProfile.humanoid())   # builds bones, adds itself to skeleton
## A BoneLengthGuard right after the simulator keeps bone lengths on screen (no rubber stretching on hard hits).
## or, with bodies you built yourself:
##   ar.setup(skeleton, simulator, {bone name: PhysicalBone3D})
## Groups ("legs", "spine", "head", "arms") come from the profile (or meta "ragdoll_group" on the bodies).

signal settled
## stagger(): the feet could not catch the torso — knock the body over (start() + fall()).
signal balance_lost
## stagger(): the torso is back over the feet — the body is animated again.
signal recovered

## Muscle natural frequency at full tone, rad/s: higher — stiffer (a 1.75 m human holds a pose at ~10–16).
@export var frequency := 13.0
## 1 — critically damped: no wobble.
@export var damping_ratio := 1.0
## Largest change of a bone's angular velocity a muscle makes in one physics tick, rad/s.
@export var max_angular_step := 25.0
## Layer and mask the bodies get while simulating (own bodies do not collide with each other: keep the layer out
## of the mask).
@export_flags_3d_physics var collision_layer := 1 << 9
@export_flags_3d_physics var collision_mask := 1
## Body parts collide with each other (an arm cannot pass through the torso, a leg through the other leg). Bones next
## to each other on the chain (parent, grandparent, siblings) never collide, nor do pairs that already overlap when the
## ragdoll starts (they would be shot apart). Keep `collision_layer` out of `collision_mask` either way — this adds it.
@export var self_collision := true
## Hips speed below which a lying body counts as settled, m/s.
@export var settle_speed := 0.35
## Muscles during hit(): stiffer than in a fall (the body is standing and takes the blow), ×frequency.
@export var hit_stiffness := 2.4
## How long the physics pose blends back into the animation when a hit has recovered, s.
@export var hit_release := 0.25
## stagger(): torso muscle tone without support (lower — it leans further and needs steps to catch).
@export var stagger_tone := 0.4
## stagger(): how far (m, horizontal) the upper chest may get from where the animation has it before the body falls.
@export var stagger_max_lean := 0.24
## stagger(): step speed per metre of lean, 1/s (≥ √(g/h) of an inverted pendulum h ≈ 1 m tall: 3.1 — a bit more to catch up).
@export var stagger_gain := 5.5
## stagger(): longest the feet may try, s.
@export var stagger_time := 1.6
## Puppet: how fast pins pull a body back to its animated place, 1/s per metre of error.
@export var pin_rate := 14.0
## Puppet: pin weight per group (0 — free, 1 — follows the animation exactly).
@export var pin_weights := {"legs": 0.12, "spine": 0.35, "head": 0.2, "arms": 0.1}
## Puppet: pin of the feet — they carry the body (the rest of the leg is muscles: knees can give way).
@export var foot_pin := 0.85
## Puppet: pin of the root (hips) — balance; hits lower it.
@export var root_pin := 0.9
## Puppet: how fast weakened pins and muscles come back, per second (0.5 — two seconds to full).
@export var recover_rate := 0.7
## Puppet: centre of mass this far (m, horizontal) from where the animation has it — balance is lost.
@export var balance_max_drift := 0.22
## Puppet: a blow that would move the whole body faster than this (impulse / mass, m/s, horizontal) — it cannot stop
## and goes down after a short stagger.
@export var balance_max_speed := 1.3
## Puppet: hips this far below the animation — the legs gave way, balance is lost.
@export var balance_max_drop := 0.3
## Puppet: share of a blow's impulse the struck body takes; the rest goes down its chain to the hips (by mass).
@export var hit_share := 0.4
## Puppet: spine muscles and pins keep at least this much after a blow (the trunk braces instead of folding over).
@export var spine_brace := 0.75
## stagger(): how much harder than physics a blow sways the torso (a real bullet barely moves a body — games and films
## exaggerate it). 1 — physical.
@export var stagger_power := 9.0

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var bones := {}              # bone name → PhysicalBone3D
var tone := {}               # bone name → current muscle tone 0..1
## Whole-body multiplier on top of per-bone tone.
var strength := 1.0

var _parent := {}            # bone name → physical parent bone name ("" — root)
var _idx := {}               # bone name → skeleton bone index
var _inertia := {}           # bone name → effective inertia of the bone and everything it carries, kg·m²
var _own_inertia := {}       # bone name → inertia of the bone's own body, kg·m²
var _group := {}             # bone name → group
var _snapshot := {}          # bone index → Transform3D (skeleton space) — target when not live
var _live := true
var _running := false
var _partial: Array[StringName] = []
var _t := 0.0
var _fades := {}             # group → [from tone, start time, duration]
var _brace := 0.0            # 0..1 — arms reach for the ground / protect
var _brace_until := 0.0
var _hit_until := -1.0
var _release_t := -1.0
var _stagger := false
var _stagger_until := 0.0
var _lean := Vector3.ZERO
var _support := 0.0
var _lean_v := Vector3.ZERO
var _stagger_t := 0.0
var _lean_mod: LeanModifier          # stagger: how well the feet are getting under the torso, 0..1
var _root_prev := Vector3.INF
var _still := 0.0
var _settled := false
var _start_exceptions: Array = []   # [RID, RID] pairs excepted for this fall only
## Final (after all modifiers) world poses of the physical bones, this frame and the previous one — the ragdoll starts
## from exactly what was on screen, moving the way the animation moved (momentum: a walking body keeps walking into
## the fall, a swaying torso keeps swaying).
var _puppet := false
## Puppet: bones shown exactly as the target after physics (their bodies still pinned hard and colliding) — a hand
## holding a weapon in first person must not lag. {bone name: true}. BoneLengthGuard applies it.
var kinematic := {}
## Puppet: pin weight overrides {bone name: weight} (taken when larger than the group's).
var pin_override := {}
var _target_mod: TargetPoseModifier
var _pin_mul := {}           # bone name → 0..1, weakened by hits, recovers
var _last_hit := -99.0
var _hold := {}              # bone name → time until which it stays weakened (no recovery yet)
var _tone_mul := {}          # bone name → 0..1, weakened by hits, recovers
var _prev_target_w := {}     # bone name → last tick's target body transform, world (target velocity)
var _drift := Vector3.ZERO
var _drift_prev := Vector3.INF
var _com_speed := 0.0
var _fall_at := -1.0
var _drop := 0.0
var _pose_now := {}          # bone name → Transform3D
var _pose_prev := {}
var _pose_t := 0
var _pose_dt := 0.0


## Build bodies from profile on skeleton and return the node (added as a child of skeleton).
static func create(sk: Skeleton3D, profile: RagdollProfile) -> ActiveRagdoll:
	var r := RagdollBuilder.build(sk, profile)
	var ar := ActiveRagdoll.new()
	ar.name = "ActiveRagdoll"
	sk.add_child(ar)
	ar.setup(sk, r.simulator, r.bones)
	ar.add_length_guard()
	ar.add_lean_modifier()
	ar.add_target_modifier()
	return ar


## Add a CrawlModifier (procedural prone crawl) right before the TargetPoseModifier, so puppet mode follows it.
func add_crawl_modifier() -> CrawlModifier:
	var c := skeleton.get_node_or_null("Crawl") as CrawlModifier
	if c:
		return c
	c = CrawlModifier.new()
	c.name = "Crawl"
	skeleton.add_child(c)
	if _target_mod:
		skeleton.move_child(c, _target_mod.get_index())
	return c


## Add the TargetPoseModifier right before the simulator (puppet targets). create() does it.
func add_target_modifier() -> TargetPoseModifier:
	_target_mod = TargetPoseModifier.new()
	_target_mod.name = "TargetPose"
	skeleton.add_child(_target_mod)
	skeleton.move_child(_target_mod, simulator.get_index())
	_target_mod.setup(self)
	return _target_mod


## Add the LeanModifier (stagger tilt of the spine) right before the simulator. create() does it.
func add_lean_modifier(spine_bones := ["Spine", "Chest", "UpperChest"]) -> LeanModifier:
	_lean_mod = LeanModifier.new()
	_lean_mod.name = "LeanModifier"
	skeleton.add_child(_lean_mod)
	skeleton.move_child(_lean_mod, simulator.get_index())
	_lean_mod.setup(self, spine_bones)
	return _lean_mod


## Add a BoneLengthGuard right after the simulator (bones keep their length on screen whatever the solver does).
## create() does it; call it yourself after setup() with your own bodies.
func add_length_guard() -> BoneLengthGuard:
	var g := BoneLengthGuard.new()
	g.name = "BoneLengthGuard"
	skeleton.add_child(g)
	skeleton.move_child(g, simulator.get_index() + 1)
	g.setup(self)
	return g


func setup(sk: Skeleton3D, sim: PhysicalBoneSimulator3D, by_name: Dictionary) -> void:
	skeleton = sk
	simulator = sim
	bones = by_name
	for n: String in bones:
		_idx[n] = sk.find_bone(n)
		var pb := bones[n] as PhysicalBone3D
		_group[n] = String(pb.get_meta(&"ragdoll_group", _guess_group(n)))
		tone[n] = 0.0
		_pin_mul[n] = 1.0
		_tone_mul[n] = 1.0
		var p := sk.get_bone_parent(_idx[n])
		_parent[n] = ""
		while p >= 0:
			var pn := sk.get_bone_name(p)
			if bones.has(pn):
				_parent[n] = pn
				break
			p = sk.get_bone_parent(p)
	_compute_inertia()
	_chain_exceptions()
	sk.skeleton_updated.connect(_on_skeleton_updated)
	set_physics_process(false)


## The skeleton has its final pose (animation and every modifier): remember it while animated.
func _on_skeleton_updated() -> void:
	if _running:
		return
	var now := Time.get_ticks_usec()
	_pose_dt = (now - _pose_t) / 1e6 if _pose_t > 0 else 0.0
	_pose_t = now
	_pose_prev = _pose_now
	_pose_now = {}
	var g := skeleton.global_transform
	for n: String in bones:
		_pose_now[n] = g * skeleton.get_bone_global_pose(_idx[n])


## Neighbours on the chain never collide: parent, grandparent, siblings (shoulders and the head share the chest).
func _chain_exceptions() -> void:
	var names := bones.keys()
	for a: String in names:
		for b: String in names:
			if a >= b:
				continue
			var pa: String = _parent[a]
			var pb: String = _parent[b]
			var near: bool = pa == b or pb == a or pa == pb \
				or (pa != "" and _parent.get(pa, "") == b) or (pb != "" and _parent.get(pb, "") == a)
			if near:
				PhysicsServer3D.body_add_collision_exception((bones[a] as PhysicalBone3D).get_rid(), (bones[b] as PhysicalBone3D).get_rid())
				PhysicsServer3D.body_add_collision_exception((bones[b] as PhysicalBone3D).get_rid(), (bones[a] as PhysicalBone3D).get_rid())


## Capsule of a body as a world segment and radius.
func _capsule(pb: PhysicalBone3D) -> Array:
	var l: float = pb.get_meta(&"ragdoll_length", 0.2)
	var r: float = pb.get_meta(&"ragdoll_radius", 0.05)
	var z := pb.global_basis.z.normalized() * maxf(l * 0.5 - r * 0.25, 0.0)
	return [pb.global_position - z, pb.global_position + z, r]


## Pairs overlapping right now (the start pose) — excepted until stop().
func _overlap_exceptions() -> void:
	var names := bones.keys()
	var caps := {}
	for n: String in names:
		caps[n] = _capsule(bones[n])
	for a: String in names:
		for b: String in names:
			if a >= b:
				continue
			var ca: Array = caps[a]
			var cb: Array = caps[b]
			var pts := Geometry3D.get_closest_points_between_segments(ca[0], ca[1], cb[0], cb[1])
			# only deep overlaps (a limb inside the torso in the start pose) — a light touch the solver separates gently;
			# excepting it would let the arm pass into the body later
			if (pts[0] as Vector3).distance_to(pts[1]) < float(ca[2]) + float(cb[2]) - 0.035:
				var ra := (bones[a] as PhysicalBone3D).get_rid()
				var rb := (bones[b] as PhysicalBone3D).get_rid()
				PhysicsServer3D.body_add_collision_exception(ra, rb)
				PhysicsServer3D.body_add_collision_exception(rb, ra)
				_start_exceptions.append([ra, rb])


func _clear_overlap_exceptions() -> void:
	for pair: Array in _start_exceptions:
		PhysicsServer3D.body_remove_collision_exception(pair[0], pair[1])
		PhysicsServer3D.body_remove_collision_exception(pair[1], pair[0])
	_start_exceptions.clear()


static func _guess_group(n: String) -> String:
	if "Leg" in n or "Foot" in n or "Toes" in n:
		return "legs"
	if "Arm" in n or "Hand" in n or "Shoulder" in n:
		return "arms"
	if "Head" in n or "Neck" in n:
		return "head"
	return "spine"


## Inertia a muscle has to move: the bone and every body hanging off it, about the bone's joint (rest pose).
func _compute_inertia() -> void:
	var center := {}
	for n: String in bones:
		var pb := bones[n] as PhysicalBone3D
		var rest := skeleton.get_bone_global_rest(_idx[n])
		center[n] = (rest * pb.body_offset).origin
	for n: String in bones:
		var joint := skeleton.get_bone_global_rest(_idx[n]).origin
		var total := 0.0
		for k: String in bones:
			if k != n and not _descends(k, n):
				continue
			var pb := bones[k] as PhysicalBone3D
			var l: float = pb.get_meta(&"ragdoll_length", 0.2)
			total += pb.mass * ((center[k] as Vector3).distance_squared_to(joint) + l * l / 12.0)
		_inertia[n] = maxf(total, 0.002)
		var own := bones[n] as PhysicalBone3D
		var ol: float = own.get_meta(&"ragdoll_length", 0.2)
		var orad: float = own.get_meta(&"ragdoll_radius", 0.05)
		_own_inertia[n] = maxf(own.mass * (ol * ol / 12.0 + orad * orad / 4.0), 1e-4)


func _descends(k: String, ancestor: String) -> bool:
	var p: String = _parent.get(k, "")
	while p != "":
		if p == ancestor:
			return true
		p = _parent.get(p, "")
	return false


# ------------------------------------------------------------------ behaviours

## Start the whole ragdoll: bodies collide, fly off with velocity v (and spin), the current pose is the target.
## exceptions — bodies not to collide with for `exception_time` s (the car the body is thrown out of).
## v — velocity of the root (hips), world, absolute (include the character's own movement); every other bone adds
## how it moved relative to the root in the animation. spin — extra angular velocity of every bone.
func start(v := Vector3.ZERO, spin := Vector3.ZERO, exceptions: Array = [], exception_time := 1.0) -> void:
	_stop_partial()
	_snapshot_pose()
	var fresh := _pose_now.size() == bones.size() and (Time.get_ticks_usec() - _pose_t) < 200000
	if fresh:
		var inv := skeleton.global_transform.affine_inverse()
		for n: String in bones:
			_snapshot[_idx[n]] = inv * (_pose_now[n] as Transform3D)
	_live = false
	for pb: PhysicalBone3D in bones.values():
		pb.collision_layer = collision_layer
		pb.collision_mask = collision_mask | (collision_layer if self_collision else 0)
		pb.gravity_scale = 1.0
	simulator.active = true
	simulator.influence = 1.0
	simulator.physical_bones_start_simulation()
	if self_collision:
		_clear_overlap_exceptions()
		_overlap_exceptions()
	var root := _root_name()
	var moving := fresh and _pose_prev.size() == bones.size() and _pose_dt > 0.002 and _pose_dt < 0.2
	var root_v := Vector3.ZERO
	if moving:
		root_v = ((_pose_now[root] as Transform3D).origin - (_pose_prev[root] as Transform3D).origin) / _pose_dt
	for n: String in bones:
		var pb := bones[n] as PhysicalBone3D
		var lin := v
		var ang := spin
		if fresh:
			var xf := (_pose_now[n] as Transform3D) * pb.body_offset
			xf.basis = xf.basis.orthonormalized()
			PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		if moving:
			var a := (_pose_prev[n] as Transform3D) * pb.body_offset
			var b := (_pose_now[n] as Transform3D) * pb.body_offset
			lin += ((b.origin - a.origin) / _pose_dt - root_v).limit_length(12.0)
			var dq := (b.basis.orthonormalized() * a.basis.orthonormalized().inverse()).get_rotation_quaternion()
			if dq.w < 0.0:
				dq = -dq
			var ang_len := 2.0 * acos(clampf(dq.w, -1.0, 1.0))
			var axis := Vector3(dq.x, dq.y, dq.z)
			if axis.length() > 1e-5:
				ang += (axis.normalized() * ang_len / _pose_dt).limit_length(25.0)
		PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lin)
		PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, ang)
	for e in exceptions:
		if e is CollisionObject3D:
			simulator.physical_bones_add_collision_exception((e as CollisionObject3D).get_rid())
			get_tree().create_timer(exception_time).timeout.connect(func() -> void:
				if is_instance_valid(e) and is_instance_valid(simulator):
					simulator.physical_bones_remove_collision_exception((e as CollisionObject3D).get_rid()))
	_running = true
	_t = 0.0
	_still = 0.0
	_settled = false
	_fades.clear()
	_brace = 0.0
	set_physics_process(true)


## Death: hold the pose a moment, then muscles give out by group over `times` (s): legs first.
func collapse(times := {"legs": 0.18, "spine": 0.5, "head": 0.55, "arms": 0.8}, start_tone := 0.85) -> void:
	for n: String in bones:
		tone[n] = start_tone
	for g: String in times:
		_fades[g] = [start_tone, _t, float(times[g])]
	_brace = 0.0


## Alive fall: tone fades from start_tone over duration, arms brace (forwards) or protect (backwards) until the
## body lands. Call after start().
func fall(start_tone := 0.6, duration := 1.6, brace := true) -> void:
	for n: String in bones:
		tone[n] = start_tone
	for g in ["legs", "spine", "head", "arms"]:
		# legs buckle at once (they would prop the body up like a plank), the torso and arms keep some tone
		_fades[g] = [start_tone * (0.5 if g == "legs" else 1.0), _t, duration * (0.15 if g == "legs" else 1.0)]
	if brace:
		_brace = 1.0
		_brace_until = _t + duration


## Hit without falling: the upper body (from the spine up; for a hit in an arm — just that arm) simulates with muscles
## on the live animation, `impulse`
## (N·s, world) goes into `bone_name`; back to animation when the pose recovers (or after `max_time` s).
## Ignored while the whole ragdoll runs. Returns whether it started.
func hit(bone_name: StringName, impulse: Vector3, recover_tone := 0.75, max_time := 1.2) -> bool:
	if _puppet:
		# the harder the blow, the longer the body cannot straighten up (a hard shove knocks it over)
		puppet_hit(bone_name, impulse, 0.95, -1.0, clampf(impulse.length() / 160.0, 0.0, 0.7))
		return true
	if _running:
		return false
	var upper: Array[StringName] = []
	var side := "Left" if String(bone_name).begins_with("Left") else ("Right" if String(bone_name).begins_with("Right") else "")
	if _group.get(String(bone_name), "") == "arms" and side != "":
		# a hit in the arm moves the arm, not the whole upper body
		for n: String in bones:
			if _group[n] == "arms" and n.begins_with(side):
				upper.append(StringName(n))
	else:
		for n: String in bones:
			if _group[n] in ["spine", "head", "arms"] and n != _root_name():
				upper.append(StringName(n))
	if not _partial.is_empty() and _partial != upper:
		_stop_partial()
	if _partial.is_empty():
		for n in upper:
			var pb := bones[String(n)] as PhysicalBone3D
			pb.collision_layer = 0
			pb.collision_mask = 0
			# a standing body holds its torso against its weight anyway; toppling is modelled separately (stagger)
			pb.gravity_scale = 0.0
			tone[String(n)] = recover_tone
		simulator.active = true
		simulator.influence = 1.0
		simulator.physical_bones_start_simulation(upper)
		_partial = upper
	_live = true
	_hit_until = _t + max_time
	_release_t = -1.0
	simulator.influence = 1.0
	var pb_hit := bones.get(String(bone_name)) as PhysicalBone3D
	if pb_hit == null or not _partial.has(bone_name):
		pb_hit = bones.get(String(_partial[0])) as PhysicalBone3D
	pb_hit.linear_velocity += impulse / maxf(pb_hit.mass, 0.1)
	set_physics_process(true)
	return true


func hitting() -> bool:
	return not _partial.is_empty()


## A blow that may knock the body over (see the class description). Returns whether it started.
## The torso is an inverted pendulum about the hips: the blow gives it a lean velocity ((r × impulse) / inertia of
## everything above the hips, times the chest height), its weight topples it further, muscles and the feet stepping
## under it bring it back. The lean is shown by LeanModifier on top of the animation — no bone physics, nothing to
## stretch; the body only goes ragdoll when balance_lost is emitted.
func stagger(bone_name: StringName, impulse: Vector3) -> bool:
	if _running or _lean_mod == null:
		return false
	var base := ""
	for n: String in bones:
		if _parent[n] == _root_name() and _group[n] == "spine":
			base = n
			break
	if base == "":
		return false
	var hit_pb := bones.get(String(bone_name), bones[base]) as PhysicalBone3D
	var joint := (skeleton.global_transform * skeleton.get_bone_global_pose(_idx[base])).origin
	var anim_hit := (skeleton.global_transform * skeleton.get_bone_global_pose(_idx.get(String(bone_name), _idx[base]))).origin
	var r := anim_hit - joint
	var w := r.cross(impulse) / float(_inertia[base]) * stagger_power     # torso angular velocity
	# chest velocity of that rotation (horizontal) — the lean velocity
	var v := w.cross(Vector3.UP * _chest_height())
	_lean_v += Vector3(v.x, 0.0, v.z)
	if not _stagger:
		_lean = Vector3.ZERO
		_support = 0.0
		_root_prev = Vector3.INF
		_stagger_t = 0.0
	_stagger = true
	_stagger_until = _t + stagger_time
	set_physics_process(true)
	return true


## Lean of the stagger pendulum as a rotation, world (axis * angle) — LeanModifier tilts the spine by it.
func stagger_tilt() -> Vector3:
	if not _stagger or _lean.length() < 0.001:
		return Vector3.ZERO
	var h := _chest_height()
	return Vector3.UP.cross(_lean.normalized()) * asin(clampf(_lean.length() / h, 0.0, 0.95))


func _chest_height() -> float:
	return 0.45


func staggering() -> bool:
	return _stagger


## Where to step while staggering: horizontal velocity (world, m/s) that brings the feet under the torso.
func stagger_velocity() -> Vector3:
	return _lean * stagger_gain if _stagger else Vector3.ZERO


## How far the upper chest is from where the animation has it (world, horizontal), m.
func lean() -> Vector3:
	return _lean


## Puppet mode on/off. On: the body becomes physical where the animation has it now, pins and muscles at full.
## keep_physics — the body is a ragdoll already (lying): it stays where it is and pins pull it into the target from
## there (no jump to the animated pose).
func puppet(on: bool, keep_physics := false) -> void:
	if on == _puppet:
		return
	if not on:
		stop()
		return
	_stop_partial()
	_stagger = false
	if not (keep_physics and _running):
		start()
	_running = true
	_live = true
	_puppet = true
	_fades.clear()
	_brace = 0.0
	_prev_target_w.clear()
	_hold.clear()
	_t = 0.0
	_last_hit = -99.0
	_drift_prev = Vector3.INF
	_com_speed = 0.0
	_fall_at = -1.0
	for n: String in bones:
		tone[n] = 1.0
		_pin_mul[n] = 1.0
		_tone_mul[n] = 1.0


func is_puppet() -> bool:
	return _puppet


## Push a physical bone by an impulse (N·s, world) at a world point: velocity change of the body and its spin.
## (PhysicalBone3D.apply_impulse outside the physics step gets lost.)
static func push(pb: PhysicalBone3D, impulse: Vector3, at: Vector3) -> void:
	var m := maxf(pb.mass, 0.1)
	pb.linear_velocity += impulse / m
	var l: float = pb.get_meta(&"ragdoll_length", 0.2)
	var inertia := m * maxf(l * l / 12.0, 0.004)
	pb.angular_velocity += ((at - pb.global_position).cross(impulse) / inertia).limit_length(30.0)


## Puppet: hit within the last `secs` seconds (still recovering from it).
func recently_hit(secs := 0.8) -> bool:
	return _puppet and _t - _last_hit < secs


## Puppet: a blow into bone_name — impulse (N·s, world) into it; the part around it (the bone, its children and, more
## softly, its parent) loses pins and muscle tone for a moment and recovers at recover_rate. A blow into the torso or a
## leg also takes the hips' pin (balance) — `balance` 0..1 how much.
## hold — seconds the struck part (and the hips, if balance > 0.5) stays weak before recovering: a wounded leg that
## keeps giving way for a moment is what makes a body sink or fall.
func puppet_hit(bone_name: StringName, impulse: Vector3, unpin := 0.95, balance := -1.0, hold := 0.0) -> void:
	var b := String(bone_name)
	if not bones.has(b):
		b = _root_name()
	for n: String in bones:
		var k := 0.0
		if n == b or _descends(n, b):
			k = unpin
		elif _parent[b] == n:
			k = unpin * 0.6
		if k > 0.0:
			_pin_mul[n] = minf(_pin_mul[n], 1.0 - k)
			if n == b or _descends(n, b):
				_hold[n] = maxf(float(_hold.get(n, 0.0)), _t + hold)
			# the trunk braces: spine muscles never go fully slack from a blow (a limp spine folds 90° over still legs)
			_tone_mul[n] = minf(_tone_mul[n], maxf(1.0 - k * 0.85, spine_brace if _group[n] == "spine" else 0.0))
	var g: String = _group[b]
	var bal := balance if balance >= 0.0 else {"legs": 0.85, "spine": 0.7, "head": 0.3, "arms": 0.1}.get(g, 0.3)
	var root := _root_name()
	_pin_mul[root] = minf(_pin_mul[root], 1.0 - bal)
	if bal > 0.5:
		_hold[root] = maxf(float(_hold.get(root, 0.0)), _t + hold)
	if bal > 0.5:
		# a heavy blow loosens the whole torso — it sways with the hips instead of being held upright
		for n: String in bones:
			if _group[n] in ["spine", "head"]:
				_pin_mul[n] = minf(_pin_mul[n], 1.0 - bal * (1.0 if g == "legs" else 0.8))
				if g == "legs":
					_hold[n] = maxf(float(_hold.get(n, 0.0)), _t + hold)
	if g == "legs" and bal > 0.5:
		# shock: the other leg goes weak too — the knees give under the body's weight instead of propping it up
		for n: String in bones:
			if _group[n] == "legs" and n != b and not _descends(n, b):
				_tone_mul[n] = minf(_tone_mul[n], 0.45)
				_hold[n] = maxf(float(_hold.get(n, 0.0)), _t + hold * 0.8)
	# the trunk braces: spine pins keep `spine_brace` — the spine muscles alone cannot hold the torso up against gravity
	# (pins carry it), a torso without them folds over the hips. A leg blow is different: the body is meant to sink.
	if g != "legs":
		for n: String in bones:
			if _group[n] == "spine" and n != root:
				_pin_mul[n] = maxf(_pin_mul[n], spine_brace)
	# a velocity change, not apply_central_impulse: impulses given to a PhysicalBone3D outside the physics step get lost
	# the struck body takes `hit_share` of the impulse, the rest goes down the chain to the root by mass — the joints
	# would pass it on anyway, but a whole blow in one light body in one tick tears through the joint limits
	var chain: Array[PhysicalBone3D] = []
	var c := b
	while c != "" and bones.has(c):
		chain.append(bones[c] as PhysicalBone3D)
		c = _parent.get(c, "")
	var rest_mass := 0.0
	for i in range(1, chain.size()):
		rest_mass += chain[i].mass
	var share := hit_share if rest_mass > 0.0 else 1.0
	chain[0].linear_velocity += impulse * share / maxf(chain[0].mass, 0.1)
	for i in range(1, chain.size()):
		chain[i].linear_velocity += impulse * (1.0 - share) / rest_mass
	_last_hit = _t
	# the blow would move the whole body faster than it can stop (balance_max_speed): it staggers a moment and goes
	# down. (Pins eat the momentum within a few ticks, so this is decided at the blow, not measured afterwards.)
	var total := 0.0
	for pb: PhysicalBone3D in bones.values():
		total += pb.mass
	if bal > 0.5 and Vector2(impulse.x, impulse.z).length() / maxf(total, 1.0) > balance_max_speed and _fall_at < 0.0:
		_fall_at = _t + 0.25


## Puppet: where the body is compared with the animation — horizontal drift of the centre of mass (world, m) and drop
## of the hips (m, down positive).
func drift() -> Vector3:
	return _drift


func drop() -> float:
	return _drop


## Puppet → falling body: pins let go, muscles fade ("die" — collapse, "fall" — brace, "limp"), the motion it had
## goes on; dv is added to every body (a push).
func release(how := "fall", dv := Vector3.ZERO) -> void:
	if not _puppet:
		return
	_puppet = false
	_snapshot.clear()
	if _target_mod:
		for n: String in bones:
			if _target_mod.targets.has(n):
				_snapshot[_idx[n]] = _target_mod.targets[n]
	_live = false
	_t = 0.0
	_still = 0.0
	_settled = false
	_fades.clear()
	for pb: PhysicalBone3D in bones.values():
		pb.linear_velocity += dv
	match how:
		"die":
			collapse()
		"fall":
			fall()
		_:
			for n: String in bones:
				tone[n] = 0.0


## Pins: every body's linear velocity is pulled towards "the animation's velocity + correction of the position error"
## (velocity motor, stable at any tick rate); the root also gets its rotation pulled. Weak pins (arms) leave limbs
## free to deflect; a weakened part flies off and comes back as its pins recover.
func _puppet_tick(delta: float) -> void:
	var g := skeleton.global_transform
	var root := _root_name()
	for n: String in bones:
		if _t < float(_hold.get(n, 0.0)):
			tone[n] = float(_tone_mul[n])
			continue
		_pin_mul[n] = minf(float(_pin_mul[n]) + recover_rate * delta, 1.0)
		_tone_mul[n] = minf(float(_tone_mul[n]) + recover_rate * delta, 1.0)
		tone[n] = float(_tone_mul[n])
	if _target_mod == null or _target_mod.targets.is_empty():
		return
	# the character jumped (teleport, respawn, seat): move the whole body there at once instead of dragging it
	var rpb := bones[root] as PhysicalBone3D
	var rt: Transform3D = g * (_target_mod.targets[root] as Transform3D) * rpb.body_offset
	if rpb.global_position.distance_to(rt.origin) > 1.0:
		for n: String in bones:
			if _target_mod.targets.has(n):
				var pbt := bones[n] as PhysicalBone3D
				var xf: Transform3D = g * (_target_mod.targets[n] as Transform3D) * pbt.body_offset
				xf.basis = xf.basis.orthonormalized()
				PhysicsServer3D.body_set_state(pbt.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
				PhysicsServer3D.body_set_state(pbt.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
				PhysicsServer3D.body_set_state(pbt.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		_prev_target_w.clear()
		_drift_prev = Vector3.INF
		return
	var com_phys := Vector3.ZERO
	var com_anim := Vector3.ZERO
	var mass := 0.0
	for n: String in bones:
		if not _target_mod.targets.has(n):
			continue
		var pb := bones[n] as PhysicalBone3D
		var tw: Transform3D = g * (_target_mod.targets[n] as Transform3D) * pb.body_offset
		var prev: Transform3D = _prev_target_w.get(n, tw)
		_prev_target_w[n] = tw
		var base: float = root_pin if n == root else (foot_pin if "Foot" in n or "Toes" in n else float(pin_weights.get(_group[n], 0.3)))
		base = maxf(base, float(pin_override.get(n, 0.0)))
		var w := clampf(base * float(_pin_mul[n]) * strength, 0.0, 1.0)
		com_phys += pb.global_position * pb.mass
		com_anim += tw.origin * pb.mass
		mass += pb.mass
		if n == root:
			_drop = -(pb.global_position - tw.origin).y
		if w <= 0.001:
			continue
		var v_anim := (tw.origin - prev.origin) / maxf(delta, 1e-4)
		if v_anim.length() > 15.0:
			v_anim = Vector3.ZERO           # teleport
		var want_v := v_anim + (tw.origin - pb.global_position) * pin_rate
		pb.linear_velocity = pb.linear_velocity.lerp(want_v, w)
		if n == root:
			var q := (tw.basis.orthonormalized() * pb.global_basis.orthonormalized().inverse()).get_rotation_quaternion()
			if q.w < 0.0:
				q = -q
			var ang := 2.0 * acos(clampf(q.w, -1.0, 1.0))
			var axis := Vector3(q.x, q.y, q.z)
			var want_w := axis.normalized() * ang * pin_rate if axis.length() > 1e-6 else Vector3.ZERO
			pb.angular_velocity = pb.angular_velocity.lerp(want_w, w)
	# balance: the centre of mass vs where the animation has it (a torso bent over the hips moves it, not just the hips)
	if mass > 0.0:
		var d := (com_phys - com_anim) / mass
		_drift = Vector3(d.x, 0.0, d.z)
	var knocked := _fall_at >= 0.0 and _t >= _fall_at
	if _drift.length() > balance_max_drift or _drop > balance_max_drop or knocked:
		_fall_at = -1.0
		balance_lost.emit()


## Stop simulating (the caller takes the body back, e.g. a get-up animation).
func stop() -> void:
	_puppet = false
	_stop_partial()
	if _running:
		simulator.physical_bones_stop_simulation()
		simulator.active = false
		for pb: PhysicalBone3D in bones.values():
			pb.collision_layer = 0
			pb.collision_mask = 0
		_clear_overlap_exceptions()
	_running = false
	set_physics_process(false)


## The physical bone a bone hangs from ("" — the ragdoll's root).
func physical_parent(bone_name: String) -> String:
	return _parent.get(bone_name, "")


func is_running() -> bool:
	return _running


func root_velocity() -> Vector3:
	return _root_velocity()


func hips_speed() -> float:
	var r := bones.get(_root_name()) as PhysicalBone3D
	return r.linear_velocity.length() if r else 0.0


func _root_name() -> String:
	for n: String in bones:
		if _parent[n] == "":
			return n
	return ""


func _stop_partial() -> void:
	if _partial.is_empty():
		return
	simulator.physical_bones_stop_simulation()
	simulator.active = false
	simulator.influence = 1.0
	for n in _partial:
		(bones[String(n)] as PhysicalBone3D).gravity_scale = 1.0
	_partial.clear()
	_hit_until = -1.0
	_release_t = -1.0


## Partial ragdoll: bodies that do not simulate (hips, legs) are what the simulated ones hang from — put them where
## the animation has the bones every tick. Left where they were when the hit started, they would hold the upper body
## back while the character walks on (the body stretches, the torso "leans" more the faster it steps).
func _follow_animation() -> void:
	for n: String in bones:
		if _partial.has(StringName(n)):
			continue
		var pb := bones[n] as PhysicalBone3D
		var xf := skeleton.global_transform * skeleton.get_bone_global_pose(_idx[n]) * pb.body_offset
		xf.basis = xf.basis.orthonormalized()
		PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)


## Stepping under the torso is what saves the balance: the root (hips, animated — the game moves the character)
## moving towards the lean at the speed stagger_velocity() asks for gives support; support restores the torso
## muscles and takes the toppling away. Standing still or stepping the wrong way — the torso keeps falling.
func _stagger_tick(delta: float) -> void:
	_stagger_t += delta
	var root := _root_name()
	var at := (skeleton.global_transform * skeleton.get_bone_global_pose(_idx[root])).origin if root != "" else Vector3.ZERO
	var vel := Vector3.ZERO
	if _root_prev != Vector3.INF and delta > 0.0:
		vel = (at - _root_prev) / delta
	_root_prev = at
	var need := _lean.length() * stagger_gain
	# small lean counts as balanced only once the blow has played out (else the muscles kill it at once)
	var s := 1.0 if _lean.length() < 0.03 and _stagger_t > 0.3 else 0.0
	if need > 0.05:
		s = clampf(Vector3(vel.x, 0.0, vel.z).dot(_lean.normalized()) / need, 0.0, 1.0)
	_support = lerpf(_support, s, 1.0 - exp(-6.0 * delta))
	var h := _chest_height()
	var muscle := frequency * 0.5 * lerpf(stagger_tone, 1.0, _support)       # rad/s
	var acc := _lean * (9.8 / h) * (1.0 - _support) - _lean * muscle * muscle - _lean_v * 2.0 * muscle
	_lean_v += acc * delta
	_lean += _lean_v * delta
	if _lean.length() > stagger_max_lean or (_t > _stagger_until and _lean.length() > stagger_max_lean * 0.5):
		_stagger = false
		balance_lost.emit()
		_lean = Vector3.ZERO
		_lean_v = Vector3.ZERO
	elif (_stagger_t > 0.35 and _lean.length() < 0.025 and _lean_v.length() < 0.12) or _t > _stagger_until:
		_stagger = false
		_lean = Vector3.ZERO
		_lean_v = Vector3.ZERO
		recovered.emit()


func _snapshot_pose() -> void:
	_snapshot.clear()
	for i in skeleton.get_bone_count():
		_snapshot[i] = skeleton.get_bone_global_pose(i)


# ------------------------------------------------------------------ muscles

func _physics_process(delta: float) -> void:
	_t += delta
	if not _partial.is_empty():
		_follow_animation()
	if _stagger:
		_stagger_tick(delta)
	if not _running and _partial.is_empty():
		if not _stagger:
			set_physics_process(false)
		return
	if _puppet:
		_puppet_tick(delta)
	else:
		_update_tone()
	var overrides := _brace_targets() if _brace > 0.0 else {}
	var err_sum := 0.0
	var count := 0
	var sk_basis := skeleton.global_basis.orthonormalized()
	for n: String in bones:
		var p: String = _parent[n]
		if p == "":
			continue
		if not _partial.is_empty() and not _partial.has(StringName(n)):
			continue
		var s: float = tone[n] * strength
		if s <= 0.002:
			continue
		var pb := bones[n] as PhysicalBone3D
		var cur := _bone_basis(n)
		var par := _bone_basis(p)
		var want: Basis
		if overrides.has(n):
			want = overrides[n]
		else:
			var tp := sk_basis * _target(p).basis.orthonormalized()
			var tc := sk_basis * _target(n).basis.orthonormalized()
			want = par * (tp.inverse() * tc)
		var q := (want * cur.inverse()).orthonormalized().get_rotation_quaternion()
		if q.w < 0.0:
			q = -q
		var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
		var axis := Vector3(q.x, q.y, q.z)
		axis = axis / axis.length() if axis.length() > 1e-6 else Vector3.ZERO
		err_sum += angle
		count += 1
		# Velocity motor (stable at any tick rate, unlike a torque spring on a light body): pull the bone's angular
		# velocity towards "parent's + correction of the pose error"; the parent gets the opposite change scaled by
		# inertia (no swimming: a ragdoll cannot push itself through the air).
		var rate := frequency * s * (hit_stiffness if not _partial.is_empty() and not _stagger else 1.0)   # rad/s per rad
		var ppb := bones[p] as PhysicalBone3D
		var parent_sim := _partial.is_empty() or _partial.has(StringName(p))
		var parent_w := ppb.angular_velocity if parent_sim else Vector3.ZERO
		var want_w := parent_w + axis * angle * rate
		var k := clampf(damping_ratio * rate * delta * 2.0, 0.0, 0.9)
		var dw := ((want_w - pb.angular_velocity) * k).limit_length(max_angular_step)
		pb.angular_velocity += dw
		if parent_sim:
			ppb.angular_velocity -= dw * (float(_own_inertia[n]) / maxf(float(_own_inertia[p]), 1e-4))
	# hit: recovered (or out of time) — blend the physics pose back into the animation, then stop
	if not _partial.is_empty():
		var avg := err_sum / maxf(count, 1)
		if _release_t < 0.0 and ((_t > _hit_until - 0.85 and avg < 0.15) or _t > _hit_until):
			_release_t = 0.0
		if _release_t >= 0.0:
			_release_t += delta
			simulator.influence = 1.0 - smoothstep(0.0, hit_release, _release_t)
			if _release_t >= hit_release:
				_stop_partial()
				simulator.influence = 1.0
				if not _running:
					set_physics_process(false)
		return
	# settled
	if _running and not _settled and not _puppet:
		_still = _still + delta if hips_speed() < settle_speed else 0.0
		if _still > 0.5 and _t > 0.8:
			_settled = true
			settled.emit()


func _update_tone() -> void:
	for g: String in _fades:
		var f: Array = _fades[g]
		var k := clampf((_t - float(f[1])) / maxf(float(f[2]), 0.01), 0.0, 1.0)
		var v := float(f[0]) * (1.0 - k * k * (3.0 - 2.0 * k))
		for n: String in bones:
			if _group[n] == g:
				tone[n] = v
	if _brace > 0.0:
		var landed := _t > 0.35 and absf(_root_velocity().y) < 0.4
		if _t > _brace_until or landed:
			_brace = maxf(_brace - get_physics_process_delta_time() * 3.0, 0.0)
		for n: String in bones:
			if _group[n] == "arms":
				tone[n] = maxf(tone[n], 0.9 * _brace)


func _root_velocity() -> Vector3:
	var r := bones.get(_root_name()) as PhysicalBone3D
	return r.linear_velocity if r else Vector3.ZERO


## World rotation of a bone now (physical body if simulating, animation otherwise).
func _bone_basis(n: String) -> Basis:
	var pb := bones[n] as PhysicalBone3D
	if _running or _partial.has(StringName(n)):
		return (pb.global_transform * pb.body_offset.affine_inverse()).basis.orthonormalized()
	return (skeleton.global_transform * skeleton.get_bone_global_pose(_idx[n])).basis.orthonormalized()


## Target pose of a bone in skeleton space.
func _target(n: String) -> Transform3D:
	var i: int = _idx[n]
	if _puppet and _target_mod and _target_mod.targets.has(n):
		return _target_mod.targets[n]
	if _live or not _snapshot.has(i):
		return skeleton.get_bone_global_pose(i)
	return _snapshot[i]


## Bracing: falling forwards — upper arms point at the ground ahead (forearms nearly straight); backwards — chin
## tucked, arms come in front of the chest. World rotations of the bones that override the pose target.
func _brace_targets() -> Dictionary:
	var out := {}
	var root := _root_name()
	if root == "":
		return out
	var v := _root_velocity()
	var hips := _bone_basis(root)
	var fwd := hips.z.normalized()
	var flat := Vector3(v.x, 0.0, v.z)
	var dir := flat.normalized() if flat.length() > 0.3 else Vector3(fwd.x, 0.0, fwd.z).normalized()
	var forwards := dir.dot(fwd) > -0.2
	for side: String in ["Left", "Right"]:
		var ua := side + "UpperArm"
		var la := side + "LowerArm"
		if not bones.has(ua):
			continue
		var sx := hips.x.normalized() * (1.0 if side == "Left" else -1.0)
		var d: Vector3
		if forwards:
			d = (dir * 0.75 + Vector3.DOWN * 0.7 + sx * 0.25).normalized()
		else:
			d = (fwd * 0.8 + Vector3.DOWN * 0.2 - sx * 0.35).normalized()   # across the chest
		var cur := _bone_basis(ua)
		var swing := Quaternion(cur.y.normalized(), d)
		var want := Basis(swing) * cur
		out[ua] = cur.slerp(want, _brace)
		if bones.has(la) and forwards:
			# forearm in line with the upper arm: the hand reaches the ground first (the elbow hinge limits the rest)
			out[la] = out[ua]
	if not forwards and bones.has("Head") and _parent.get("Head", "") != "":
		# chin to chest
		var par := _bone_basis(_parent["Head"])
		out["Head"] = par * Basis(Vector3.RIGHT, 0.6)
	return out
