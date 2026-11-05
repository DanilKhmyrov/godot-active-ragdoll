extends RefCounted
## Getting up from lying face down, as an Animation built from key poses on the skeleton (no clip for it in the CC0
## packs): flat on the chest with the hands under the shoulders → pushed up onto hands and knees → on one knee, the
## other foot in front → standing (the first frame of `idle`). Puppet mode leads the lying body through it like through
## any get-up clip. The character faces +Z; lying, the head is towards +Z — getting up it stands where the knees were.
##
## A pose is {bone: direction its +Y points to (skeleton space)} plus the hips' position; every other bone keeps its
## rotation in `idle` relative to its parent (shoulders, fingers, feet as they hang).

const POSES := [
	# time, hips position, spine direction (the hips' +Y), {bone: direction}
	[0.0, Vector3(0.0, 0.13, -0.55), Vector3(0.0, 0.0, 1.0), {
		"Head": Vector3(0.0, 0.25, 1.0),
		"LeftUpperArm": Vector3(0.45, -0.55, -0.7), "RightUpperArm": Vector3(-0.45, -0.55, -0.7),
		"LeftLowerArm": Vector3(-0.1, -0.35, 1.0), "RightLowerArm": Vector3(0.1, -0.35, 1.0),
		"LeftUpperLeg": Vector3(0.05, 0.0, -1.0), "RightUpperLeg": Vector3(-0.05, 0.0, -1.0),
		"LeftLowerLeg": Vector3(0.0, 0.0, -1.0), "RightLowerLeg": Vector3(0.0, 0.0, -1.0),
		"LeftFoot": Vector3(0.0, -1.0, -0.3), "RightFoot": Vector3(0.0, -1.0, -0.3)}],
	[0.35, null, null, {}],                                                      # hold: let the body catch up
	[1.05, Vector3(0.0, 0.5, -0.3), Vector3(0.0, 0.2, 1.0), {
		"Head": Vector3(0.0, 0.35, 1.0),
		"LeftUpperArm": Vector3(0.12, -1.0, 0.05), "RightUpperArm": Vector3(-0.12, -1.0, 0.05),
		"LeftLowerArm": Vector3(0.0, -1.0, 0.05), "RightLowerArm": Vector3(0.0, -1.0, 0.05),
		"LeftUpperLeg": Vector3(0.1, -1.0, 0.0), "RightUpperLeg": Vector3(-0.1, -1.0, 0.0),
		"LeftLowerLeg": Vector3(0.0, -0.05, -1.0), "RightLowerLeg": Vector3(0.0, -0.05, -1.0),
		"LeftFoot": Vector3(0.0, -0.6, -1.0), "RightFoot": Vector3(0.0, -0.6, -1.0)}],
	[1.85, Vector3(0.0, 0.5, -0.15), Vector3(0.0, 1.0, 0.12), {
		"Head": Vector3(0.0, 1.0, 0.1),
		"LeftUpperArm": Vector3(0.25, -1.0, 0.15), "RightUpperArm": Vector3(-0.2, -1.0, 0.3),
		"LeftLowerArm": Vector3(0.0, -1.0, 0.3), "RightLowerArm": Vector3(-0.05, -0.6, 1.0),
		"LeftUpperLeg": Vector3(0.1, -1.0, 0.0), "RightUpperLeg": Vector3(-0.12, -0.15, 1.0),
		"LeftLowerLeg": Vector3(0.0, -0.05, -1.0), "RightLowerLeg": Vector3(0.0, -1.0, 0.0),
		"LeftFoot": Vector3(0.0, -0.5, -1.0), "RightFoot": Vector3(0.0, -0.2, 1.0)}],
	[2.75, Vector3.INF, null, {}],                                               # standing: idle's first frame
]


static func build(sk: Skeleton3D, idle: Animation) -> Animation:
	var a := Animation.new()
	a.length = POSES[-1][0]
	var count := sk.get_bone_count()
	# idle's first frame, local rotations (the base every pose bends from) and the hips' position
	var base: Array[Quaternion] = []
	for i in count:
		base.append(sk.get_bone_rest(i).basis.get_rotation_quaternion())
	var stand_hips := sk.get_bone_rest(sk.find_bone("Hips")).origin
	for k in idle.get_track_count():
		var bone := sk.find_bone(idle.track_get_path(k).get_concatenated_subnames())
		if bone < 0:
			continue
		match idle.track_get_type(k):
			Animation.TYPE_ROTATION_3D:
				base[bone] = idle.rotation_track_interpolate(k, 0.0)
			Animation.TYPE_POSITION_3D:
				if sk.get_bone_name(bone) == "Hips":
					stand_hips = idle.position_track_interpolate(k, 0.0)
	var rot_tracks := {}
	for i in count:
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%GeneralSkeleton:" + sk.get_bone_name(i)))
		rot_tracks[i] = t
	var pos_track := a.add_track(Animation.TYPE_POSITION_3D)
	var hips := sk.find_bone("Hips")
	a.track_set_path(pos_track, NodePath("%GeneralSkeleton:Hips"))
	var last_local: Array[Quaternion] = []
	var last_hips := Vector3.ZERO
	for p: Array in POSES:
		var time: float = p[0]
		if p[1] == null:
			# a hold: the previous pose again
			for i in count:
				a.rotation_track_insert_key(rot_tracks[i], time, last_local[i])
			a.position_track_insert_key(pos_track, time, last_hips)
			continue
		var local: Array[Quaternion] = []
		var global: Array[Quaternion] = []
		var dirs: Dictionary = p[3]
		for i in count:
			var parent := sk.get_bone_parent(i)
			var g := (global[parent] if parent >= 0 else Quaternion.IDENTITY) * base[i]
			if p[1] != Vector3.INF:
				var want: Variant = dirs.get(sk.get_bone_name(i), null)
				if i == hips:
					want = p[2]
				if want != null:
					var y := Basis(g).y.normalized()
					g = Quaternion(y, (want as Vector3).normalized()) * g
			global.append(g)
			local.append(((global[parent] if parent >= 0 else Quaternion.IDENTITY).inverse() * g).normalized())
		var hips_at: Vector3 = stand_hips if p[1] == Vector3.INF else p[1]
		for i in count:
			a.rotation_track_insert_key(rot_tracks[i], time, local[i])
		a.position_track_insert_key(pos_track, time, hips_at)
		last_local = local
		last_hips = hips_at
	return a
