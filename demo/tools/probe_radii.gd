extends SceneTree
# Mesh thickness per physical bone: distance of the vertices mostly weighted to that bone from its capsule axis
# (median and 90th percentile) vs the profile radius — how demo/character.gd's MANNEQUIN_RADII were chosen.
#   godot --headless --path . --script res://demo/tools/probe_radii.gd
func _initialize() -> void:
	var m := (load("res://demo/mannequin/mannequin.glb") as PackedScene).instantiate()
	root.add_child(m)
	var sk := m.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var mi := sk.find_child("Mannequin", true, false) as MeshInstance3D
	var prof := RagdollProfile.humanoid()
	var skin := mi.skin
	var bind_bone := {}
	for b in skin.get_bind_count():
		bind_bone[b] = sk.find_bone(skin.get_bind_name(b)) if skin.get_bind_name(b) != &"" else skin.get_bind_bone(b)
	var pts := {}
	for s in mi.mesh.get_surface_count():
		var a := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / v.size()
		for i in v.size():
			var best := 0
			for k in per:
				if w[i * per + k] > w[i * per + best]: best = k
			var bi: int = bind_bone[bones[i * per + best]]
			var name := sk.get_bone_name(bi)
			# bind pose → skeleton rest space (the retarget changed the rests, the mesh stayed in its bind pose)
			var bp := skin.get_bind_pose(bones[i * per + best])
			pts.get_or_add(name, []).append(sk.get_bone_global_rest(bi) * bp * v[i])
	for n: String in prof.bones:
		var spec: Dictionary = prof.bones[n]
		var i := sk.find_bone(n)
		var a := sk.get_bone_global_rest(i).origin
		var to: Variant = spec["to"]
		var b: Vector3 = sk.get_bone_global_rest(sk.find_bone(to)).origin if to is String else a + sk.get_bone_global_rest(i).basis.y.normalized() * float(to)
		var d := []
		for p: Vector3 in pts.get(n, []):
			var u := b - a
			var t := clampf((p - a).dot(u) / u.dot(u), 0.0, 1.0)
			d.append(p.distance_to(a + u * t))
		d.sort()
		if d.is_empty():
			print("RAD ", n, " no verts"); continue
		print("RAD %-14s profile %.3f  median %.3f  p90 %.3f  n %d  len %.3f" % [n, spec["radius"], d[d.size() / 2], d[int(d.size() * 0.9)], d.size(), a.distance_to(b)])
	for n in ["LeftHand", "LeftToes", "Neck", "LeftShoulder"]:
		var d := []
		var a := sk.get_bone_global_rest(sk.find_bone(n)).origin
		var ext := Vector3.ZERO
		for p: Vector3 in pts.get(n, []):
			ext = ext.max((p - a).abs())
		print("EXT ", n, " ", ext, " n ", pts.get(n, []).size())
	quit()
