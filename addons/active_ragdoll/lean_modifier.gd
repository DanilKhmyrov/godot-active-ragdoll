class_name LeanModifier
extends SkeletonModifier3D
## Tilts the spine on top of the animation by the lean of ActiveRagdoll's stagger pendulum: the torso sways back from a
## blow, the legs keep animating (stepping). No physics involved — nothing can stretch. Goes before the simulator.

var ragdoll: ActiveRagdoll
var spine: Array[int] = []          # bones the tilt is spread over, root to top
var weights: Array[float] = []


func setup(ar: ActiveRagdoll, bone_names: Array) -> void:
	ragdoll = ar
	spine.clear()
	weights.clear()
	for n in bone_names:
		var i := ar.skeleton.find_bone(n)
		if i >= 0:
			spine.append(i)
	for k in spine.size():
		weights.append(1.0 / maxf(spine.size(), 1))


func _process_modification_with_delta(_delta: float) -> void:
	if ragdoll == null:
		return
	var tilt := ragdoll.stagger_tilt()            # world: axis * angle
	var angle := tilt.length()
	if angle < 0.0005:
		return
	var sk := get_skeleton()
	var axis_sk := (sk.global_basis.orthonormalized().inverse() * (tilt / angle)).normalized()
	for k in spine.size():
		var i := spine[k]
		var p := sk.get_bone_parent(i)
		var parent_rot := sk.get_bone_global_pose(p).basis.orthonormalized().get_rotation_quaternion() if p >= 0 else Quaternion.IDENTITY
		var axis_parent := (parent_rot.inverse() * axis_sk).normalized()
		sk.set_bone_pose_rotation(i, Quaternion(axis_parent, angle * weights[k]) * sk.get_bone_pose_rotation(i))
