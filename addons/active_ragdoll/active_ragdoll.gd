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
## stagger(): the feet could not catch the torso — knock the body over (start() + fall()). Puppet: the body went too
## far off its feet (or stumbled too long) — release() it.
signal balance_lost
## stagger() / puppet stumbling: the feet caught the body.
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
## Most an upper arm may turn about its own axis from the rest relation, degrees (see _limit_twist).
@export var max_arm_twist := 45.0
## fall(): how much faster than usual the protecting muscles (arms reaching for the ground, the neck) move — a reflex.
@export var brace_stiffness := 2.5
## writhe(): how long a hurt body on the ground keeps moving before it calms down, s.
@export var writhe_time := 8.0
## writhe(): muscle tone of the moving body (the arm holding the wound is firmer).
@export var writhe_tone := 0.6
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
## Puppet: a blow that would move the whole body faster than this (impulse / mass, m/s, horizontal) cannot be caught
## by stepping — the body goes down after a moment. Slower ones make it stumble.
@export var balance_max_speed := 2.6
## Puppet: a blow moving the whole body at least this fast (m/s, horizontal) makes it stumble — the hips go with the
## blow and the feet have to step under them (stumble_velocity()); slower ones the pins absorb on the spot.
@export var stumble_min_speed := 0.45
## Puppet, stumbling: fastest the feet can step, m/s.
@export var stumble_step_speed := 2.8
## Puppet, stumbling: a body sent off faster than this (m/s) is caught by the steps; faster (up to balance_max_speed)
## it stumbles a few steps and trips — sooner the faster it goes.
@export var stumble_catch_speed := 1.8
## Puppet, stumbling: how hard the stepping feet brake the body, m/s² (at full support) — a lower value, longer stumbles.
@export var stumble_brake := 1.6
## Puppet, stumbling: the centre of mass this far (m, horizontal) from the feet's animated place — down it goes.
@export var stumble_max_drift := 0.5
## Puppet, stumbling: longest the feet may try, s.
@export var stumble_time := 2.5
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
var _stumble := false
var _stumble_t := 0.0
var _support_h := 1.0       # stumbling: how well the feet are under the body, 0..1 — the hips' horizontal pin
var _step_v := Vector3.ZERO # stumbling: where the feet should go, m/s (world, horizontal)
var _body_v := Vector3.ZERO # stumbling: how fast the body goes (world, horizontal) — the blow, braked by the steps
var _trip_at := -1.0        # stumbling: when a too fast body trips over its feet
var _writhe := false
var _alive := false         # fall(): an alive body keeps a little tone once down (limbs lie straight, not folded)
var _writhe_t := 0.0
var _friction := {}         # writhe(): the limbs' friction before it
var _rolling := false      # roll_over(): turning onto the back
var _roll_t := 0.0
var _roll_from := 0.0        # roll_over(): how the pelvis faced at the start (no progress → the other way)
var _roll_flipped := false
var _roll_dir := 0.0         # roll_over(): which way it turns (chosen once — face down both ways are ~180°)
var _getup_until := -1.0   # get_up(): balance is not judged meanwhile
var _writhe_k := 0.0       # writhe(): how much it moves this moment (bouts)
var _lie_face := Vector3.ZERO  # writhe(): where the pelvis faced when it started (the roll it keeps)
var _wound := ""           # last bone a blow went into (writhe(): a hand holds it)
var _flail_k := 0.0         # stumbling: how hard the arms flail, 0..1 — rises with the blow, fades slower than it
var _com_prev := Vector3.INF
var _com_v := Vector3.ZERO  # centre of mass velocity, physical (world)
var _caught := 0.0
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
	_end_writhe()
	_alive = false
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
	_anchor_joints()
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
	_alive = false
	for n: String in bones:
		tone[n] = start_tone
	for g: String in times:
		_fades[g] = [start_tone, _t, float(times[g])]
	_brace = 0.0


## Alive fall: tone fades from start_tone over duration, arms brace (forwards) or protect (backwards) until the
## body lands. Call after start().
func fall(start_tone := 0.6, duration := 1.6, brace := true) -> void:
	_alive = true
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
		_anchor_joints()
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
	_end_writhe()
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
	_stumble = false
	_support_h = 1.0
	_com_prev = Vector3.INF
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
	var g: String = _group[b]
	# a blow into the trunk or the head: the trunk braces (below) — else a limp spine folds 90° over still legs. A blow
	# into a limb leaves the trunk free to give: an arm pulled by a hit drags the shoulder and turns the chest.
	var trunk := g in ["spine", "head"]
	# the blow loosens the chain it travels down too, less at every joint (parent 0.6, then 0.36…): the shoulder of a
	# struck arm gives, the chest turns, the hips barely notice — instead of a rigid trunk under a flailing arm
	var up := {}
	var a: String = _parent[b]
	var fade := 0.6
	while a != "":
		up[a] = fade
		fade *= 0.6
		a = _parent[a]
	var struck_root := b == _root_name()
	for n: String in bones:
		var k := 0.0
		if n == b or (_descends(n, b) and not struck_root):
			k = unpin
		elif struck_root and _parent[n] == b:
			# everything hangs from the root: a blow into the hips loosens what is right on them, not the whole body
			k = unpin * 0.4
		elif up.has(n) and n != _root_name():
			k = unpin * float(up[n])
		if k > 0.0:
			_pin_mul[n] = minf(_pin_mul[n], 1.0 - k)
			if n == b or (_descends(n, b) and not struck_root):
				_hold[n] = maxf(float(_hold.get(n, 0.0)), _t + hold)
			_tone_mul[n] = minf(_tone_mul[n], maxf(1.0 - k * 0.85, spine_brace if trunk and _group[n] == "spine" else 0.0))
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
	# the trunk braces: spine pins (held to the hips) keep `spine_brace` — the spine muscles alone cannot hold the torso
	# up against gravity, a torso without them folds over the hips. A leg blow is different: the body is meant to sink.
	if trunk:
		for n: String in bones:
			if _group[n] == "spine" and n != root:
				_pin_mul[n] = maxf(_pin_mul[n], spine_brace)
	_blow(b, impulse, hit_share)
	_last_hit = _t
	# the blow would move the whole body faster than it can stop (balance_max_speed): it staggers a moment and goes
	# down. (Pins eat the momentum within a few ticks, so this is decided at the blow, not measured afterwards.)
	var total := 0.0
	for pb: PhysicalBone3D in bones.values():
		total += pb.mass
	var speed := Vector2(impulse.x, impulse.z).length() / maxf(total, 1.0)
	if bal > 0.5 and speed > balance_max_speed and _fall_at < 0.0:
		_fall_at = _t + 0.25
	elif g == "legs" and bal > 0.5 and speed > stumble_min_speed:
		# a leg knocked out from under the body cannot step — no stumbling: the body sags onto it and goes down
		_stumble = false
		_fall_at = _t + 0.2 if _fall_at < 0.0 else minf(_fall_at, _t + 0.2)
	elif bal > 0.5 and speed > stumble_min_speed:
		# the body goes with the blow and the feet have to catch it (see _stumble_tick)
		if not _stumble:
			_stumble_t = 0.0
			_caught = 0.0
			_body_v = Vector3.ZERO
			_trip_at = -1.0
			_flail_k = 0.0
		_stumble = true
		_support_h = 0.0
		_body_v += Vector3(impulse.x, 0.0, impulse.z) / maxf(total, 1.0)
		var over := inverse_lerp(stumble_catch_speed, balance_max_speed, _body_v.length())
		if over > 0.0:
			# too fast to be caught: a few steps, then the feet tangle
			var trip := _stumble_t + lerpf(1.0, 0.35, clampf(over, 0.0, 1.0))
			_trip_at = trip if _trip_at < 0.0 else minf(_trip_at, trip)


## A blow into bone `b` (impulse, N·s, world) as velocity changes — not apply_central_impulse: impulses given to a
## PhysicalBone3D outside the physics step get lost. The struck body takes `share` of it (< 0 — its share of the
## chain's mass), the rest goes down the chain to the root by mass — the joints would pass it on anyway, but a whole
## blow in one light body in one tick tears through the joint limits. Nothing reaches the bodies off the chain (the
## legs under a struck chest): they only follow through the joints — the body topples from the blow instead of
## flying off as one block.
func _blow(b: String, impulse: Vector3, share := -1.0) -> void:
	_wound = b
	var chain: Array[PhysicalBone3D] = []
	var c := b
	while c != "" and bones.has(c):
		chain.append(bones[c] as PhysicalBone3D)
		c = _parent.get(c, "")
	# by mass, less at every joint further from the blow (0.6 per joint): the struck part leads, the hips under a
	# struck chest mostly get dragged by the spine — the body bends and topples instead of sliding off on its feet
	var weights: Array[float] = []
	var rest := 0.0
	for i in chain.size():
		weights.append(chain[i].mass * pow(0.6, i))
		if i > 0:
			rest += weights[i]
	if rest <= 0.0:
		share = 1.0
	elif share < 0.0:
		share = weights[0] / (weights[0] + rest)
	chain[0].linear_velocity += impulse * share / maxf(chain[0].mass, 0.1)
	for i in range(1, chain.size()):
		# each body takes its part where the blow reaches it — at the joint of the body below it in the chain: an arm
		# pulled sideways turns the chest about the spine, a push into the chest rocks the hips, not only shifts them
		var j := impulse * (1.0 - share) * weights[i] / rest
		var at := (chain[i - 1].global_transform * chain[i - 1].joint_offset).origin
		chain[i].linear_velocity += j / chain[i].mass
		var inertia := float(_own_inertia[String(chain[i].get("bone_name"))])
		chain[i].angular_velocity += ((at - chain[i].global_position).cross(j) / inertia).limit_length(12.0)


## Knocked over by a blow into `bone_name` (impulse, N·s, world): from puppet mode, from plain animation (the ragdoll
## starts with the character's velocity `v`) or an already falling body. The blow lands where it hit — the struck part
## goes first and the rest follows through the joints; `how` — "fall" (alive: braces), "die" or "limp".
func knock(bone_name: StringName, impulse: Vector3, how := "fall", v := Vector3.ZERO) -> void:
	var b := String(bone_name) if bones.has(String(bone_name)) else _root_name()
	if _puppet:
		release(how)
	elif not _running:
		start(v)
		match how:
			"die":
				collapse()
			"fall":
				fall()
			_:
				for n: String in bones:
					tone[n] = 0.0
	_blow(b, impulse)


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
	# a stumbling body that lost it trips over its feet: they catch, the rest goes on the way it went
	var trip_v := _body_v if _stumble else Vector3.ZERO
	_stumble = false
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
	_alive = false
	for pb: PhysicalBone3D in bones.values():
		pb.linear_velocity += dv
	if trip_v.length() > 0.05:
		for n: String in bones:
			var pb := bones[n] as PhysicalBone3D
			if "Foot" in n or "Toes" in n:
				pb.linear_velocity = Vector3(0.0, pb.linear_velocity.y, 0.0)
			elif _group[n] != "legs":
				pb.linear_velocity += trip_v * 0.8
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
	if _stumble:
		# a stumbling body throws its arms out whatever hit it (a limp arm would hang)
		for n: String in bones:
			if _group[n] == "arms":
				tone[n] = maxf(float(tone[n]), 0.8 * _flail())
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
	# the upper body (spine, head, arms) is pinned to its animated place as carried by the physical hips, not to its
	# place in the world: a pushed torso takes the hips along (and the hips the torso) instead of staying put while the
	# hips move under it — only the hips and the legs hold the body in the world (balance)
	# (only where the hips went, not how they turned: the muscles already turn the torso with the hips, and carrying the
	# hips' tilt too would swing the head by every degree of it)
	var carry := Transform3D(Basis.IDENTITY, rpb.global_position - rt.origin)
	var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) \
		* ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	for n: String in bones:
		if not _target_mod.targets.has(n):
			continue
		var pb := bones[n] as PhysicalBone3D
		var anim_w: Transform3D = g * (_target_mod.targets[n] as Transform3D) * pb.body_offset
		var tw := anim_w if n == root or _group[n] == "legs" else carry * anim_w
		var prev: Transform3D = _prev_target_w.get(n, tw)
		_prev_target_w[n] = tw
		var base: float = root_pin if n == root else (foot_pin if "Foot" in n or "Toes" in n else float(pin_weights.get(_group[n], 0.3)))
		base = maxf(base, float(pin_override.get(n, 0.0)))
		if _stumble and _group[n] == "arms":
			base *= 1.0 - 0.9 * _flail()       # the arms are busy catching the balance (_stumble_arm_targets)
		var w := clampf(base * float(_pin_mul[n]) * strength, 0.0, 1.0)
		com_phys += pb.global_position * pb.mass
		com_anim += anim_w.origin * pb.mass
		mass += pb.mass
		if n == root:
			_drop = -(pb.global_position - tw.origin).y
		# muscles carry the body's weight while its pin is whole (else the pins only hold it with a sag — the hips carry
		# the upper body); a blow weakens the pin and gives the weight back — a struck body sags. Flailing arms are
		# held up by their own muscles.
		var carried_k := clampf(float(_pin_mul[n]) * strength, 0.0, 1.0)
		if _stumble and _group[n] == "arms":
			carried_k = maxf(carried_k, _flail())
		var hold_up := gravity * pb.gravity_scale * delta * carried_k
		if w <= 0.001:
			pb.linear_velocity -= hold_up
			continue
		var v_anim := (tw.origin - prev.origin) / maxf(delta, 1e-4)
		if v_anim.length() > 15.0:
			v_anim = Vector3.ZERO           # teleport
		var fix := (tw.origin - pb.global_position) * pin_rate
		if _t < _getup_until:
			# getting up: the limbs go into the clip's pose at a human pace, not in one jump
			fix = fix.limit_length(2.5)
		var want_v := v_anim + fix
		if n == root and _stumble:
			# stumbling: the hips keep their height (the legs carry them) and go as the blow sent them, braked by the
			# steps (_stumble_tick) — the feet chase them
			var v := pb.linear_velocity
			var wv := maxf(w, root_pin * 0.8 * strength)
			var h := Vector2(v.x, v.z).lerp(Vector2(_body_v.x, _body_v.z), 0.5)
			pb.linear_velocity = Vector3(h.x, lerpf(v.y, want_v.y, wv), h.y)
		else:
			pb.linear_velocity = pb.linear_velocity.lerp(want_v, w)
		# after the pin, or the pin would eat part of it
		pb.linear_velocity -= hold_up
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
		var com := com_phys / mass
		if _com_prev != Vector3.INF:
			_com_v = _com_v.lerp((com - _com_prev) / maxf(delta, 1e-4), 1.0 - exp(-20.0 * delta))
		_com_prev = com
	var knocked := _fall_at >= 0.0 and _t >= _fall_at
	if _stumble:
		knocked = knocked or _stumble_tick(delta)
	if _t < _getup_until:
		return
	if (_drift.length() > balance_max_drift and not _stumble) or _drop > balance_max_drop or knocked:
		_fall_at = -1.0
		_stumble = false
		balance_lost.emit()


## Stumbling (puppet): the feet step to catch the body a blow sent off. The feet have to go as fast as the body
## and make up how far behind it they are: stumble_velocity() is how fast the character has to move (its walk/run
## animation makes the steps, the pinned feet follow them). Feet under the body hold the hips again (support) and every
## step brakes it (stumble_brake) — a few steps and it stands. Returns true when it cannot be caught: the body got
## too far off its feet or the feet tried too long.
func _stumble_tick(delta: float) -> bool:
	_stumble_t += delta
	# the feet go as fast as the body and make up how far behind it they are
	_step_v = (_body_v + _drift * 4.0).limit_length(stumble_step_speed)
	_support_h = clampf(1.0 - _drift.length() / 0.3, 0.0, 1.0)
	# feet under the body brake it
	_body_v = _body_v.move_toward(Vector3.ZERO, stumble_brake * _support_h * delta)
	# the arms go up with the blow and come down only once the body slows
	_flail_k = maxf(_flail_k - delta * 0.9, clampf(_body_v.length() / 0.9, 0.0, 1.0))
	if _drift.length() > stumble_max_drift or _stumble_t > stumble_time or (_trip_at >= 0.0 and _stumble_t >= _trip_at):
		return true
	_caught = _caught + delta if _body_v.length() < 0.15 and _drift.length() < 0.1 else 0.0
	if _caught > 0.2:
		_stumble = false
		_step_v = Vector3.ZERO
		_support_h = 1.0
		recovered.emit()
	return false


## Puppet: stumbling after a blow — move the character at stumble_velocity() meanwhile.
func stumbling() -> bool:
	return _stumble and _puppet


## Puppet, stumbling: where to step — horizontal velocity (world, m/s) that brings the feet under the falling body.
func stumble_velocity() -> Vector3:
	return _step_v if stumbling() else Vector3.ZERO


## Stop simulating (the caller takes the body back, e.g. a get-up animation).
func stop() -> void:
	_end_writhe()
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


## Joints that cross bones without a body (upper arm ← shoulder ← upper chest, head ← neck ← upper chest) are built
## by PhysicalBone3D once, from the pose the skeleton had then (usually the rest pose — a T-pose shoulder). The
## animation moves those in-between bones (shoulders drop 30° from a T-pose), so the physical arm would hang 10–20 cm
## from the one on screen: hits land beside the arm, a lying body's arms sink into the floor. Before simulating,
## re-anchor such joints where the in-between bones put the child now; the limits stay centred on the rest pose of
## the physical bones themselves.
func _anchor_joints() -> void:
	for n: String in bones:
		var p: String = _parent[n]
		if p == "":
			continue
		var i: int = _idx[n]
		var pb := bones[n] as PhysicalBone3D
		var ppb := bones[p] as PhysicalBone3D
		var hang: float = pb.get_meta(&"ragdoll_hang", -1.0)
		var chain := Transform3D.IDENTITY          # parent bone → this bone, animated in-between bones, rest ends
		var b := skeleton.get_bone_parent(i)
		if b == _idx[p] and hang < 0.0:
			continue
		while b >= 0 and b != _idx[p]:
			chain = skeleton.get_bone_pose(b) * chain
			b = skeleton.get_bone_parent(b)
		chain = chain * skeleton.get_bone_rest(i)
		if hang >= 0.0:
			# limits centred on a hanging limb, not on the rest pose: a T-pose rest would centre the shoulder's cone on
			# an arm held out sideways — the arm could neither hang (90° off) nor reach forward, the joint pushing it up
			var r := chain.basis.y.normalized()
			var a := r.angle_to(Vector3.DOWN)       # the parent's −Y: down along the spine
			if a > deg_to_rad(hang) and Vector3.DOWN.cross(r).length() > 1e-4:
				var axis := Vector3.DOWN.cross(r).normalized()
				chain.basis = Basis(Quaternion(r, Vector3.DOWN.rotated(axis, deg_to_rad(hang)))) * chain.basis
		# PhysicalBone3D builds its joint from the two bodies' transforms when the joint type is set: place this body
		# where the chain puts it relative to the parent body, rebuild, restore the limits
		pb.global_transform = ppb.global_transform * ppb.body_offset.affine_inverse() * chain * pb.body_offset
		var keep := {}
		for prop in pb.get_property_list():
			if String(prop.name).begins_with("joint_constraints/"):
				keep[prop.name] = pb.get(prop.name)
		var jt := pb.joint_type
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		pb.joint_type = jt
		for k: StringName in keep:
			pb.set(k, keep[k])


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
	var overrides := {}
	if _brace > 0.0:
		overrides = _brace_targets()
	elif stumbling():
		overrides = _stumble_arm_targets()
	elif _rolling:
		_roll_tick(delta)
		# legs straight, head in line, arms along the sides — a body rolls over as a log (an arm left under the chest or
		# flung out props it up), then gets its limbs back
		var down_body := -_bone_basis(_root_name()).y.normalized()
		for n: String in bones:
			if (_group[n] == "legs" or n == "Head") and _parent[n] != "":
				overrides[n] = _rel_rest(n)
			elif n.ends_with("UpperArm") or n.ends_with("LowerArm"):
				overrides[n] = _aim(n, down_body)
				# held along the side: an arm the turn flings off would swing up over the body
				tone[n] = 0.8
				if _bone_basis(_root_name()).z.normalized().dot(Vector3.UP) > 0.0:
					_pin_rotation(n, overrides[n], 0.35)
	elif _writhe:
		overrides = _writhe_targets(delta)
		# the limbs and the head are lifted by their own muscles (velocity motors alone cannot hold a 9 kg thigh up
		# against gravity); the trunk lies heavy
		var lift := 0.75 * _writhe_strength()
		var g: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) \
			* ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
		_hold_wound()
		_keep_lying(delta)
		# the muscles alone cannot move a limb lying on the ground (contacts hold it) — the moving parts are led
		# where their target rotation puts them from their joint, like puppet pins
		for n: String in overrides:
			if _group[n] == "legs" or n == "Head":
				_pin_rotation(n, overrides[n], (0.3 if _group[n] == "legs" else 0.15) * minf(_writhe_k * 1.5, 1.0))
		for n: String in bones:
			var pb := bones[n] as PhysicalBone3D
			# a body that lay still has been put to sleep — the muscles' velocities would not reach it
			PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING, false)
			# the legs and the head; not the arms — a weightless arm floats up into the air
			if _group[n] == "legs" or _group[n] == "head":
				pb.linear_velocity -= g * pb.gravity_scale * delta * lift
	_limit_twist(delta)
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
		if overrides.has(n) and _brace > 0.0:
			rate *= lerpf(1.0, brace_stiffness, _brace)   # a protective reflex is faster than holding a pose
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
	if _writhe and _brace <= 0.0:
		# hurt and moving: low tone (the body lies heavy), fading as it calms down; the arm on the wound firmer
		var k := _writhe_strength()
		var hold := _holding_arm()
		for n: String in bones:
			var t := writhe_tone * k
			if hold != "" and n.begins_with(hold) and _group[n] == "arms":
				t = 0.15                     # the hand is led to the wound (_hold_wound), the arm only follows
			tone[n] = t
		return
	for g: String in _fades:
		var f: Array = _fades[g]
		var k := clampf((_t - float(f[1])) / maxf(float(f[2]), 0.01), 0.0, 1.0)
		var v := float(f[0]) * (1.0 - k * k * (3.0 - 2.0 * k))
		for n: String in bones:
			if _group[n] == g:
				tone[n] = v
	if _alive and _t > 0.6:
		# down alive: the limbs keep a little tone — they lie out towards the pose instead of staying as they folded
		# (a limp leg kneeling on the way down would lie with its foot up in the air)
		for n: String in bones:
			if _group[n] == "legs":
				tone[n] = maxf(tone[n], 0.2)
			elif _group[n] == "arms":
				tone[n] = maxf(tone[n], 0.1)
	if _brace > 0.0:
		var landed := _t > 0.35 and absf(_root_velocity().y) < 0.4 and _root_velocity().length() < 1.2
		if _t > _brace_until or landed:
			_brace = maxf(_brace - get_physics_process_delta_time() * 3.0, 0.0)
		# the protecting muscles hold until the body is down: arms and neck firm, the back keeps its curl
		for n: String in bones:
			if _group[n] == "arms" or _group[n] == "head":
				tone[n] = maxf(tone[n], 0.9 * _brace)
			elif _group[n] == "spine":
				tone[n] = maxf(tone[n], 0.55 * _brace)


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


## Stumbling: how hard the arms flail, 0..1.
func _flail() -> float:
	return _flail_k if _stumble else 0.0


## Stumbling: the arms go out to the sides and against the way the body goes (a counterweight), swinging — catching the
## balance. World rotations of the upper arms that override the pose target; the forearms keep the animated elbow.
func _stumble_arm_targets() -> Dictionary:
	var out := {}
	var root := _root_name()
	var k := _flail()
	if root == "" or k <= 0.01:
		return out
	var hips := _bone_basis(root)
	var fwd := Vector3(hips.z.x, 0.0, hips.z.z).normalized()
	var away := _body_v.normalized() if _body_v.length() > 0.05 else Vector3.ZERO
	for side: String in ["Left", "Right"]:
		var ua := side + "UpperArm"
		if not bones.has(ua):
			continue
		var sx := hips.x.normalized() * (1.0 if side == "Left" else -1.0)
		var swing := sin(_stumble_t * 7.0 + (0.0 if side == "Left" else PI))
		var d := (sx + Vector3.UP * 0.12 - away * 0.35 + fwd * swing * 0.45).normalized()
		out[ua] = _rel_target(ua).slerp(_aim(ua, d), k)
	return out


## Hurt, on the ground: the body moves like a hurt person — knees drawn up and let go, the back arching and curling,
## the head lifted, rolling a little — and a hand holds the wound (the bone the last blow went into; another arm when
## the wound is an arm). Call when the body has settled (signal settled); it calms down over writhe_time. The pose it
## lies in is the base — the body moves around it, it does not try to stand. stop() / puppet() end it.
func writhe(wound := &"") -> void:
	if not _running or _puppet:
		return
	if wound != &"":
		_wound = String(wound)
	# the lying pose is the target the movement goes around
	_snapshot.clear()
	var inv := skeleton.global_transform.affine_inverse()
	for n: String in bones:
		var pb := bones[n] as PhysicalBone3D
		var xf := inv * pb.global_transform * pb.body_offset.affine_inverse()
		xf.basis = xf.basis.orthonormalized()
		_snapshot[_idx[n]] = xf
	# the limbs as they lie but untwisted — a twist picked up in the fall would else be the pose to hold
	for n: String in bones:
		if (_group[n] == "arms" or _group[n] == "legs") and _parent[n] != "":
			var pi: int = _idx[_parent[n]]
			var rel: Basis = (_snapshot[pi] as Transform3D).basis.inverse() * (_snapshot[_idx[n]] as Transform3D).basis
			var rest := _rest_rel(n)
			var q := (rest.inverse() * rel).get_rotation_quaternion()
			var twist := Quaternion(0.0, q.y, 0.0, q.w).normalized()
			var xf: Transform3D = _snapshot[_idx[n]]
			xf.basis = (_snapshot[pi] as Transform3D).basis * rest * Basis(q * twist.inverse())
			_snapshot[_idx[n]] = xf
	_live = false
	_fades.clear()
	_brace = 0.0
	# heels and elbows slide over the ground (a lying limb with full friction is glued to it — the muscles cannot move
	# it); the trunk keeps its grip, the body does not skate
	if not _writhe:
		_friction.clear()
		for n: String in bones:
			if _group[n] != "spine":
				var pb := bones[n] as PhysicalBone3D
				_friction[n] = pb.friction
				pb.friction = minf(pb.friction, 0.3)
	_writhe = true
	_writhe_t = 0.0
	_lie_face = _bone_basis(_root_name()).z.normalized() if _root_name() != "" else Vector3.ZERO
	set_physics_process(true)


func _end_writhe() -> void:
	if _rolling:
		for n: String in _friction:
			(bones[n] as PhysicalBone3D).friction = _friction[n]
		_friction.clear()
	_rolling = false
	if _writhe:
		for n: String in _friction:
			(bones[n] as PhysicalBone3D).friction = _friction[n]
		_friction.clear()
	_writhe = false


func writhing() -> bool:
	return _writhe and _running and not _puppet


## writhe(): how much it still moves — full most of writhe_time, calming down over its last third (eased).
func _writhe_strength() -> float:
	var k := clampf((1.0 - _writhe_t / maxf(writhe_time, 0.1)) * 3.0, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


## writhe(): "Left"/"Right" — the arm that holds the wound ("" — none).
func _holding_arm() -> String:
	if _wound == "" or not bones.has(_wound):
		return ""
	# face down the wound is under the body (or on its back, out of reach): no holding it
	var root := _root_name()
	if root != "" and _bone_basis(root).z.normalized().dot(Vector3.UP) < -0.15:
		return ""
	if _group[_wound] == "arms":
		return "Right" if _wound.begins_with("Left") else "Left"
	# the free arm — the one higher up, not the one the body lies on — the nearer one if both are free
	var at := (bones[_wound] as PhysicalBone3D).global_position
	var best := ""
	var best_score := INF
	for side: String in ["Left", "Right"]:
		var ua := side + "UpperArm"
		if bones.has(ua):
			var p := (bones[ua] as PhysicalBone3D).global_position
			var score := p.distance_to(at) - p.y * 3.0
			if score < best_score:
				best_score = score
				best = side
	return best


## writhe(): the hand is led onto the wound — its side nearer the arm, off the ground — like a pin: the palm end of the
## forearm pulled there, the joints find how the arm bends (a pose target cannot know what the elbow hinge and the
## shoulder allow).
func _hold_wound() -> void:
	var hold := _holding_arm()
	var la := hold + "LowerArm"
	if hold == "" or not bones.has(la) or not bones.has(_wound):
		return
	var wb := bones[_wound] as PhysicalBone3D
	# on the wound's side nearer this arm and up — an arm reaching over the top of a round trunk would roll it over
	var sh := (bones[hold + "UpperArm"] as PhysicalBone3D).global_position
	var toward := sh - wb.global_position
	toward = Vector3(toward.x, 0.0, toward.z).normalized()
	var target := wb.global_position + (Vector3.UP * 0.6 + toward * 0.8).normalized() * (float(wb.get_meta(&"ragdoll_radius", 0.08)) + 0.04)
	var pb := bones[la] as PhysicalBone3D
	var palm := pb.global_transform * Vector3(0, 0, -float(pb.get_meta(&"ragdoll_length", 0.25)) * 0.5 - 0.06)
	var want := ((target - palm) * 5.0).limit_length(1.4)
	pb.linear_velocity = pb.linear_velocity.lerp(want, 0.3 * minf(_writhe_strength() * 2.0, 1.0))
	# the upper arm follows the forearm (elbow kept low, by the side) — the shoulder would else hold it out sideways
	var ub := bones[hold + "UpperArm"] as PhysicalBone3D
	var elbow_at := (sh + target) * 0.5 + Vector3.DOWN * 0.08
	ub.linear_velocity = ub.linear_velocity.lerp(((elbow_at - ub.global_position) * 4.0).limit_length(1.2), 0.15 * minf(_writhe_strength() * 2.0, 1.0))


## writhe(): a flat back (or front) does not roll over — the round capsules of the trunk would at every asymmetric
## push. The trunk is turned back about its long axis towards how it lay down.
func _keep_lying(delta: float, face := Vector3.ZERO, gain := 4.0) -> void:
	var root := _root_name()
	if face == Vector3.ZERO:
		face = _lie_face
	if face == Vector3.ZERO or root == "":
		return
	# by the pelvis: the chest also turns when the back curls, which is not a roll
	var axis := _bone_basis(root).y.normalized()
	var a := _bone_basis(root).z.normalized()
	var b := face
	a = (a - axis * a.dot(axis)).normalized()
	b = (b - axis * b.dot(axis)).normalized()
	var err := atan2(axis.dot(a.cross(b)), a.dot(b))
	for n: String in bones:
		if n == root or _group[n] == "spine":
			var pb := bones[n] as PhysicalBone3D
			var spin := pb.angular_velocity.dot(axis)
			pb.angular_velocity += axis * (err * gain - spin) * clampf(10.0 * delta, 0.0, 0.5)


## Lying on the back (the pelvis faces up) — a get-up from the back can start; face down, roll_over() first.
func lying_on_back() -> bool:
	var root := _root_name()
	return root != "" and _bone_basis(root).z.normalized().dot(Vector3.UP) > 0.6


## Lying face down or on a side turned down (the pelvis faces the ground or sideways) — a get-up from the front (onto
## hands and knees) can start; lying_on_back() — a get-up from the back.
func lying_face_down() -> bool:
	var root := _root_name()
	return root != "" and _bone_basis(root).z.normalized().dot(Vector3.UP) < 0.2


## A body lying face down (or on a side) turns onto its back — the trunk rolls about the spine, the limbs follow;
## rolling() is false once it is on its back (or gave up after 2 s).
func roll_over() -> void:
	if not _running or _puppet:
		return
	_end_writhe()
	_rolling = true
	_roll_t = 0.0
	_roll_dir = 0.0
	_roll_flipped = false
	_roll_from = _bone_basis(_root_name()).z.normalized().dot(Vector3.UP)
	_friction.clear()
	for n: String in bones:
		var pb := bones[n] as PhysicalBone3D
		_friction[n] = pb.friction
		pb.friction = minf(pb.friction, 0.25)
	_fades.clear()
	_brace = 0.0
	set_physics_process(true)


func rolling() -> bool:
	return _rolling


func _roll_tick(delta: float) -> void:
	_roll_t += delta
	var root := _root_name()
	var rpb := bones[root] as PhysicalBone3D
	var axis := _bone_basis(root).y.normalized()
	var a := _bone_basis(root).z.normalized()
	a = (a - axis * a.dot(axis)).normalized()
	var b := (Vector3.UP - axis * Vector3.UP.dot(axis)).normalized()
	var err := atan2(axis.dot(a.cross(b)), a.dot(b))
	# face down the error is ~±180° and flips sign tick to tick — the body would twitch both ways and never turn
	if _roll_dir == 0.0:
		_roll_dir = signf(err) if absf(err) < 2.8 else 1.0
	if absf(err) > PI * 0.5 and signf(err) != _roll_dir:
		err = _roll_dir * absf(err)
	# stuck that way (an arm or a leg propping it up): the other way, once
	var facing := _bone_basis(root).z.normalized().dot(Vector3.UP)
	if not _roll_flipped and _roll_t > 0.7 and facing < _roll_from + 0.15:
		_roll_flipped = true
		_roll_dir = -_roll_dir
		_roll_t = 0.3
	# the whole body turns about its long axis (through the hips); the legs are straightened first (_roll targets) —
	# bent knees would swing the shins up into the air as it turns
	var w := axis * clampf(err * 5.0, -4.5, 4.5) * clampf(_roll_t / 0.3, 0.0, 1.0)
	var pivot := rpb.global_position
	var g: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) \
		* ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	for n: String in bones:
		var pb := bones[n] as PhysicalBone3D
		PhysicsServer3D.body_set_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING, false)
		tone[n] = 0.6 if _group[n] == "legs" else (0.8 if _group[n] == "arms" else 0.35)
		if _group[n] == "arms" and facing > 0.0:
			continue     # past the side the top arm comes along by its joint — turned with the body it swings up high
		var r := pb.global_position - pivot
		var want_v := w.cross(r - axis * r.dot(axis))
		pb.linear_velocity = pb.linear_velocity.lerp(Vector3(want_v.x, pb.linear_velocity.y + want_v.y, want_v.z), 0.4)
		pb.angular_velocity += (w - pb.angular_velocity.dot(axis) * axis) * 0.4
	if _bone_basis(root).z.normalized().dot(Vector3.UP) > 0.75 or _roll_t > 2.0:
		_rolling = false
		for n: String in _friction:
			(bones[n] as PhysicalBone3D).friction = _friction[n]
		_friction.clear()


## Where to put the character (a Node3D the skeleton hangs from) so that a get-up clip starts where the body lies: the
## clip's hips at its first frame (clip_hips, skeleton space — see clip_pose()) land on the physical hips, its body
## axis (hips → head) along the lying one. Only position and heading change — the character stays upright on the
## ground (its own y is kept).
func get_up_transform(character: Node3D, clip_hips: Transform3D) -> Transform3D:
	var root := _root_name()
	var rpb := bones[root] as PhysicalBone3D
	var phys := rpb.global_transform * rpb.body_offset.affine_inverse()
	var to_skel := character.global_transform.affine_inverse() * skeleton.global_transform
	var h := to_skel * clip_hips                          # clip hips in the character's space
	var a := Vector3(h.basis.y.x, 0.0, h.basis.y.z)
	var b := Vector3(phys.basis.y.x, 0.0, phys.basis.y.z)
	var yaw := 0.0
	if a.length() > 0.05 and b.length() > 0.05:
		yaw = atan2(a.normalized().cross(b.normalized()).y, a.normalized().dot(b.normalized()))
	var basis := Basis(Vector3.UP, yaw + character.global_rotation.y)
	var at := phys.origin - basis * h.origin
	return Transform3D(basis, Vector3(at.x, character.global_position.y, at.z))


## A bone's pose in skeleton space at time t of an animation (its tracks, the rest pose where a track is missing) —
## for get_up_transform(). Tracks are matched by the bone name after ":".
static func clip_pose(sk: Skeleton3D, anim: Animation, bone: String, t := 0.0) -> Transform3D:
	var out := Transform3D.IDENTITY
	var i := sk.find_bone(bone)
	var chain: Array[int] = []
	while i >= 0:
		chain.push_front(i)
		i = sk.get_bone_parent(i)
	for b in chain:
		var rest := sk.get_bone_rest(b)
		var pos := rest.origin
		var rot := rest.basis.get_rotation_quaternion()
		for k in anim.get_track_count():
			if anim.track_get_path(k).get_concatenated_subnames() != sk.get_bone_name(b):
				continue
			match anim.track_get_type(k):
				Animation.TYPE_POSITION_3D:
					pos = anim.position_track_interpolate(k, t)
				Animation.TYPE_ROTATION_3D:
					rot = anim.rotation_track_interpolate(k, t)
		out = out * Transform3D(Basis(rot), pos)
	return out


## Get up along the animation the skeleton plays now (a get-up clip, the character placed by get_up_transform()):
## puppet mode from where the body lies — pins and muscles gain strength over `blend` s and lead the lying body
## through the clip; balance is not judged for `duration` s.
func get_up(duration: float, blend := 0.5) -> void:
	_end_writhe()
	puppet(true, true)
	_getup_until = _t + duration
	strength = 0.3
	create_tween().tween_property(self, "strength", 1.0, blend)


## Lead a body to the place a world rotation of its bone puts it, turning about its joint (where it is now): velocity
## pulled there with weight w — a pin for one bone.
func _pin_rotation(n: String, want: Basis, w: float) -> void:
	if w <= 0.001:
		return
	var pb := bones[n] as PhysicalBone3D
	var joint := (pb.global_transform * pb.body_offset.affine_inverse()).origin
	var target := joint + want.orthonormalized() * pb.body_offset.origin
	var v := ((target - pb.global_position) * 6.0).limit_length(2.0)
	pb.linear_velocity = pb.linear_velocity.lerp(v, w)


## writhe(): world rotations of the bones that override the lying pose.
func _writhe_targets(delta: float) -> Dictionary:
	_writhe_t += delta
	var out := {}
	var root := _root_name()
	var k := _writhe_strength()
	if root == "" or k <= 0.001:
		return out
	var t := _writhe_t
	var hips := _bone_basis(root)
	var side_axis := hips.x.normalized()
	var fwd := hips.z.normalized()
	# how it lies: on the back the knees come up to the chest and the chin down; face down a knee cannot come forward
	# (it would go into the ground) — the shins lift, the head comes up, the back arches; on a side it curls up
	var up := fwd.dot(Vector3.UP)
	var on_back := clampf(up * 2.0, 0.0, 1.0)
	var on_front := clampf(-up * 2.0, 0.0, 1.0)
	# in bouts — a wave of pain, then a moment still — not a metronome
	var bout := clampf(0.5 + 0.7 * sin(t * 0.83) * cos(t * 0.31 + 0.7), 0.0, 1.0)
	k *= 0.5 + 0.5 * bout
	_writhe_k = k
	# legs: knees drawn up and let go, each leg its own rhythm
	for side: String in ["Left", "Right"]:
		var ul := side + "UpperLeg"
		var ll := side + "LowerLeg"
		var ph := (t * (1.1 if side == "Left" else 1.47) + (0.0 if side == "Left" else 2.2) + 0.6 * sin(t * 0.4)) * (1.0 - 0.5 * on_front)
		var draw := (0.5 + 0.5 * sin(ph)) * k          # 0 — as it lies, 1 — knee up
		# angles from the rest pose (straight leg), not added to how it lies — limp legs land folded near the knee's
		# limit, more bend on top of that could never be reached
		if bones.has(ul):
			out[ul] = _rel_rest(ul).slerp(Basis(side_axis, -(0.15 + 1.0 * draw) * (1.0 - on_front)) * _rel_rest(ul), k)
		if bones.has(ll):
			# face down a knee only bends a little and slowly (shins swinging up and down look like a swimmer's kick)
			var bend := lerpf(0.3 + 1.3 * draw, 0.15 + 0.35 * draw, on_front)
			out[ll] = _rel_rest(ll).slerp(Basis(side_axis, bend) * _rel_rest(ll), k)
	# back curling (on the back, on a side) or arching (face down), a roll to one side and back
	var curl := (sin(t * 0.9 + 0.3 * sin(t * 0.5)) * 0.15 + 0.12 * (1.0 - on_front) - 0.15 * on_front) * k
	var roll := sin(t * 0.55) * 0.2 * k
	for n: String in bones:
		if _group[n] == "spine" and n != root:
			out[n] = Basis(fwd, roll * 0.5) * Basis(side_axis, curl) * _rel_rest(n)
	# the head comes off the ground now and then: chin to chest on the back, face up face down
	if bones.has("Head") and _parent.get("Head", "") != "":
		var lift := (0.35 + 0.25 * sin(t * 0.7 + 1.0)) * k * (1.0 - 2.0 * on_front)
		out["Head"] = Basis(side_axis, lift) * _rel_rest("Head")
	return out


## A falling body protects itself (while _brace lasts): the arms reach for the ground the way it falls (in front,
## behind, to the side — the arm on the far side comes across), the head keeps off the ground (chin to chest falling
## backwards, face up falling forwards, tilted away falling sideways), the back rounds falling backwards so the back
## lands before the head. World rotations of the bones that override the pose target.
func _brace_targets() -> Dictionary:
	var out := {}
	var root := _root_name()
	if root == "":
		return out
	var k := _brace
	var hips := _bone_basis(root)
	var side_axis := hips.x.normalized()      # towards the body's left
	var fwd := hips.z.normalized()
	var v := _root_velocity()
	var flat := Vector3(v.x, 0.0, v.z)
	var dir: Vector3
	if flat.length() > 0.3:
		dir = flat.normalized()
	else:
		# hardly moving: the way the torso tips
		var up := hips.y
		var lean := Vector3(up.x, 0.0, up.z)
		dir = lean.normalized() if lean.length() > 0.1 else Vector3(fwd.x, 0.0, fwd.z).normalized()
	var f := dir.dot(fwd)                      # + falling forwards
	var s := dir.dot(side_axis)                # + falling to the left
	for side: String in ["Left", "Right"]:
		var ua := side + "UpperArm"
		var la := side + "LowerArm"
		if not bones.has(ua):
			continue
		var sx := side_axis * (1.0 if side == "Left" else -1.0)
		var toward := dir.dot(sx)              # this arm is on the side the body falls to
		var d: Vector3
		if toward < -0.5:
			# falling to the other side: this arm comes across in front
			d = (fwd * 0.6 + dir * 0.4 + Vector3.DOWN * 0.3).normalized()
		elif f > -0.3 or toward > 0.3:
			# reach for the ground where the body goes
			d = (dir * 0.75 + Vector3.DOWN * 0.7 + sx * 0.25).normalized()
		else:
			# backwards: reach back and down — the hands behind take the fall
			d = (dir * 0.55 + Vector3.DOWN * 0.75 + sx * 0.45).normalized()
		out[ua] = _rel_target(ua).slerp(_aim(ua, d), k)
		if bones.has(la):
			# forearm in line with the upper arm: the hand reaches the ground first (the elbow hinge limits the rest)
			out[la] = out[ua]
	if bones.has("Head") and _parent.get("Head", "") != "":
		var tuck := clampf(-f, 0.0, 1.0) * 0.7    # chin to chest
		var lift := clampf(f, 0.0, 1.0) * 0.45    # face up, off the ground
		var tilt := s * 0.45                      # away from the ground
		out["Head"] = Basis(side_axis, (tuck - lift) * k) * Basis(fwd, tilt * k) * _rel_target("Head")
	if f < -0.2:
		# backwards: round the back
		for n: String in bones:
			if _group[n] == "spine" and n != root:
				out[n] = Basis(side_axis, 0.18 * -f * k) * _rel_target(n)
	return out


## A bone pointed along world direction d, keeping the twist (about its own axis) of its pose target — a swing from
## where it is now would keep whatever twist it picked up (an upper arm turned 110° about itself: the elbow and the
## hand point the wrong way, and nothing would ever turn it back).
func _aim(n: String, d: Vector3) -> Basis:
	var base := _rel_target(n).orthonormalized()
	return Basis(Quaternion(base.y.normalized(), d.normalized())) * base


## A bone's rest rotation relative to its physical parent (skeleton space) — for a limb with "hang" (upper arms) the
## hanging neutral its joint limits are centred on (see _anchor_joints), not a T-pose held out sideways.
func _rest_rel(n: String) -> Basis:
	var p: String = _parent[n]
	var rel := skeleton.get_bone_global_rest(_idx[p]).basis.orthonormalized().inverse() \
		* skeleton.get_bone_global_rest(_idx[n]).basis.orthonormalized()
	var hang: float = (bones[n] as PhysicalBone3D).get_meta(&"ragdoll_hang", -1.0)
	if hang >= 0.0:
		var r := rel.y.normalized()
		var a := r.angle_to(Vector3.DOWN)
		if a > deg_to_rad(hang) and Vector3.DOWN.cross(r).length() > 1e-4:
			rel = Basis(Quaternion(r, Vector3.DOWN.rotated(Vector3.DOWN.cross(r).normalized(), deg_to_rad(hang)))) * rel
	return rel


## The upper arms do not turn about their own axis more than max_arm_twist from their neutral — whatever the
## muscles' tone (a limp arm too): the cone joint's twist limit lets a hard fall wind an arm 110°+ about itself
## (the elbow and the hand pointing the wrong way, and lying like that). Like a joint limit: only the excess is pushed
## back.
func _limit_twist(delta: float) -> void:
	if not _running:
		return
	for n: String in ["LeftUpperArm", "RightUpperArm"]:
		if not bones.has(n) or _parent[n] == "":
			continue
		if not _partial.is_empty() and not _partial.has(StringName(n)):
			continue
		var cur := _bone_basis(n)
		var rel := _bone_basis(_parent[n]).inverse() * cur
		var q := (_rest_rel(n).inverse() * rel).get_rotation_quaternion()
		var twist := wrapf(2.0 * atan2(q.y, q.w), -PI, PI)
		var limit := deg_to_rad(max_arm_twist)
		if absf(twist) <= limit:
			continue
		var excess := twist - signf(twist) * limit
		var pb := bones[n] as PhysicalBone3D
		var axis := cur.y.normalized()
		var spin := pb.angular_velocity.dot(axis)
		pb.angular_velocity += axis * (-excess * 12.0 - spin) * clampf(30.0 * delta, 0.0, 0.6)


## The rest pose of a bone relative to its physical parent, as a world rotation given where the parent is now.
func _rel_rest(n: String) -> Basis:
	var p: String = _parent[n]
	var sk_basis := skeleton.global_basis.orthonormalized()
	var tp := sk_basis * skeleton.get_bone_global_rest(_idx[p]).basis.orthonormalized()
	var tc := sk_basis * skeleton.get_bone_global_rest(_idx[n]).basis.orthonormalized()
	return _bone_basis(p) * (tp.inverse() * tc)


## The pose target of a bone as a world rotation, given where its physical parent is now.
func _rel_target(n: String) -> Basis:
	var p: String = _parent[n]
	var sk_basis := skeleton.global_basis.orthonormalized()
	var tp := sk_basis * _target(p).basis.orthonormalized()
	var tc := sk_basis * _target(n).basis.orthonormalized()
	return _bone_basis(p) * (tp.inverse() * tc)
