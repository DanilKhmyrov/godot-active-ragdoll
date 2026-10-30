class_name CrawlModifier
extends SkeletonModifier3D
## Procedural prone crawl for a humanoid (SkeletonProfileHumanoid bone names): the body lies face down along the
## skeleton's +Z, arms take turns reaching forward and pulling, legs drag (one can be `limp_leg`), the head is lifted.
## Bone lengths stay the rest ones (only rotations are chosen). It overrides the pose it is given, so put it after the
## animation and other modifiers — and before ActiveRagdoll's TargetPoseModifier: in puppet mode the physical body
## follows it and really touches the ground.
##
## `weight` 0..1 blends it in. `phase` advances by `speed` (cycles/s); `pull()` — how hard an arm is pulling now
## (0..1): move the character forward proportionally (~0.25 m per cycle) so the hands stay put while pulling.

@export var weight := 0.0
@export var speed := 0.55
## "Left" / "Right" — that leg drags without moving; "" — both legs push a little.
@export var limp_leg := ""
## Hips height above the ground in the crawl, m (at scale 1).
@export var hips_height := 0.14

var phase := 0.0
var _idx := {}


func _ready() -> void:
	active = true


func _bone(sk: Skeleton3D, n: String) -> int:
	if not _idx.has(n):
		_idx[n] = sk.find_bone(n)
	return _idx[n]


## How hard the arms are pulling right now (0..1) — move the body forward by it.
func pull() -> float:
	return maxf(sin(phase * TAU), 0.0) + maxf(sin(phase * TAU + PI), 0.0)


func _process_modification_with_delta(delta: float) -> void:
	if weight <= 0.001:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	phase = fposmod(phase + delta * speed, 1.0)
	var P := Basis(Vector3.RIGHT, PI * 0.5)          # standing → face down: up (+Y) to forward (+Z)
	var F := Vector3.BACK                            # +Z — forward (where the head is)
	var U := Vector3.UP
	var poses := {}
	# hips: lying, slight roll with the arms
	var roll := sin(phase * TAU) * 0.08
	var hips := sk.find_bone("Hips")
	if hips < 0:
		return
	var hrest := sk.get_bone_global_rest(hips)
	var hb := Basis(F, roll) * P * hrest.basis
	poses[hips] = Transform3D(hb, Vector3(0.0, hips_height, 0.0))
	_follow(sk, poses, ["Spine", "Chest", "UpperChest"], P, roll, {"Spine": 0.06, "Chest": 0.1, "UpperChest": 0.16})
	# head lifted, looking ahead
	_dir(sk, poses, "Neck", (F + U * 0.55).normalized(), P)
	_dir(sk, poses, "Head", (F + U * 0.35).normalized(), P)
	for side: String in ["Left", "Right"]:
		var sx := 1.0 if side == "Left" else -1.0        # body left is +X
		var S := Vector3(sx, 0.0, 0.0)
		var ph := phase * TAU + (0.0 if side == "Left" else PI)
		var reach := 0.5 + 0.5 * cos(ph)                  # 1 — arm out ahead, 0 — pulled back under the shoulder
		var lift := maxf(-sin(ph), 0.0)                   # hand off the ground while it moves forward
		var ua := ((F * 0.95 + S * 0.25 - U * 0.25) * reach + (-U * 0.85 + S * 0.45 + F * 0.15) * (1.0 - reach) + U * lift * 0.35).normalized()
		var la := ((F * 0.9 - U * 0.45) * reach + (F * 0.75 - U * 0.25 + S * -0.2) * (1.0 - reach) + U * lift * 0.2).normalized()
		_dir(sk, poses, side + "Shoulder", (S * 0.9 + F * 0.3 * reach).normalized(), P)
		_dir(sk, poses, side + "UpperArm", ua, P)
		_dir(sk, poses, side + "LowerArm", la, P)
		_dir(sk, poses, side + "Hand", (F - U * 0.5).normalized(), P)
		# legs: drag behind; a pushing leg bends its knee out to the side now and then
		var push := 0.0 if side == limp_leg else maxf(sin(ph + PI * 0.5), 0.0) * (0.7 if limp_leg == "" else 1.0)
		# knee bends out to the side along the ground (frog push), the shin stays on the ground
		var th := (-F + S * (0.15 + 0.55 * push) - U * 0.08).normalized()
		var cf := (-F * (1.0 - push * 0.2) - S * 0.35 * push - U * 0.12).normalized()
		_dir(sk, poses, side + "UpperLeg", th, P)
		_dir(sk, poses, side + "LowerLeg", cf, P)
		_dir(sk, poses, side + "Foot", (-F * 0.7 - U * 0.7).normalized(), P)
	# blend in
	for i: int in poses:
		var want: Transform3D = poses[i]
		if weight < 0.999:
			var cur := sk.get_bone_global_pose(i)
			want = cur.interpolate_with(want, weight)
		sk.set_bone_global_pose(i, want)


## Spine bones follow the hips' lying orientation (+ a little arch: chest lifted on the pulling arm).
func _follow(sk: Skeleton3D, poses: Dictionary, names: Array, P: Basis, roll: float, arch: Dictionary) -> void:
	for n: String in names:
		var i := _bone(sk, n)
		if i < 0:
			continue
		var rest := sk.get_bone_global_rest(i)
		var b := Basis(Vector3.BACK, roll) * Basis(Vector3.RIGHT, -float(arch.get(n, 0.0))) * P * rest.basis
		poses[i] = Transform3D(b, _origin(sk, poses, i))


## Bone i points along d (skeleton space): minimal rotation from its lying rest direction, roll kept.
func _dir(sk: Skeleton3D, poses: Dictionary, n: String, d: Vector3, P: Basis) -> void:
	var i := _bone(sk, n)
	if i < 0:
		return
	var rest := sk.get_bone_global_rest(i)
	var b0 := P * rest.basis
	var y0 := b0.y.normalized()
	var q := Quaternion(y0, d.normalized()) if y0.dot(d.normalized()) > -0.999 else Quaternion(b0.x.normalized(), PI)
	poses[i] = Transform3D(Basis(q) * b0, _origin(sk, poses, i))


## Where bone i starts: its parent's new pose (or current one) times the rest offset — lengths kept.
func _origin(sk: Skeleton3D, poses: Dictionary, i: int) -> Vector3:
	var p := sk.get_bone_parent(i)
	if p < 0:
		return sk.get_bone_global_pose(i).origin
	var pg: Transform3D = poses[p] if poses.has(p) else _chain(sk, poses, p)
	return pg * sk.get_bone_rest(i).origin


## Global pose of bone p built from its (new) parent and its local pose.
func _chain(sk: Skeleton3D, poses: Dictionary, p: int) -> Transform3D:
	var gp := sk.get_bone_parent(p)
	if gp < 0:
		return sk.get_bone_global_pose(p)
	var parent: Transform3D = poses[gp] if poses.has(gp) else _chain(sk, poses, gp)
	var t := parent * Transform3D(Basis(sk.get_bone_pose_rotation(p)), sk.get_bone_rest(p).origin)
	poses[p] = t
	return t
