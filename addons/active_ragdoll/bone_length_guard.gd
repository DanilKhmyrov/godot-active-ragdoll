class_name BoneLengthGuard
extends SkeletonModifier3D
## Keeps bone lengths while a ragdoll simulates. PhysicalBoneSimulator3D copies each body's full transform into the
## skeleton, so when the solver lets joints separate for a moment (a hard hit, a wall, a kinematic parent moving fast
## during a partial ragdoll) the mesh stretches like rubber. Placed right after the simulator, this modifier keeps
## the physics rotations but puts every simulated bone (except the ragdoll's root) back at its rest offset from its
## parent:
## the body can never stretch on screen, whatever the physics did that frame. In puppet mode it also shows the
## ActiveRagdoll.kinematic bones exactly at their target.

var ragdoll: ActiveRagdoll
var _bones: PackedInt32Array = []


func setup(ar: ActiveRagdoll) -> void:
	ragdoll = ar
	_bones.clear()
	var sk := ar.skeleton
	for n: String in ar.bones:
		var i := sk.find_bone(n)
		# the ragdoll's root (hips: no physical parent) moves freely — its offset from the skeleton root is the fall
		if i >= 0 and ar.physical_parent(n) != "":
			_bones.append(i)
		# bones between physical ones (neck, shoulders) take their offset from animation — already right


func _process_modification_with_delta(_delta: float) -> void:
	if ragdoll == null or not (ragdoll.is_running() or ragdoll.hitting()):
		return
	var sk := get_skeleton()
	if sk == null:
		return
	for i in _bones:
		sk.set_bone_pose_position(i, sk.get_bone_rest(i).origin)
	# puppet: bones shown exactly as the target (a hand holding something)
	if ragdoll.is_puppet() and not ragdoll.kinematic.is_empty() and ragdoll._target_mod:
		var tg: Dictionary = ragdoll._target_mod.targets
		for n: String in ragdoll.kinematic:
			if tg.has(n):
				sk.set_bone_global_pose(ragdoll._idx[n], tg[n])
