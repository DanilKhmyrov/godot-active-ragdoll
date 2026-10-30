@tool
class_name RagdollProfile
extends Resource
## Which bones of a skeleton get physical bodies, their capsules, masses and joints.
##
## `bones` maps a bone name to a spec dictionary:
##   to      — String: the bone the capsule runs to; or float: capsule length along the bone's +Y.
##   radius  — capsule radius, m.
##   mass    — kg.
##   joint   — "" (free, the root), "cone" or "hinge".
##   limits  — cone: [swing°, twist°]; hinge: [from°, to°] around the bone's side axis.
##   group   — "legs", "spine", "head" or "arms": muscles of a group fade together (see ActiveRagdoll.collapse).
## Bone names follow Godot's SkeletonProfileHumanoid (retarget your model with a BoneMap and they match).

@export var bones: Dictionary = {}
## Sign of the hinge for knees and elbows: which way they bend depends on the rig's bone axes.
@export var knee_sign := 1.0
@export var elbow_sign := -1.0
## Friction and damping of every physical bone.
@export var friction := 0.8
@export var linear_damp := 0.1
@export var angular_damp := 0.8


## A ready-made profile for a ~1.75 m adult on SkeletonProfileHumanoid bones (15 bodies, 75 kg total).
static func humanoid() -> RagdollProfile:
	var p := RagdollProfile.new()
	p.bones = {
		"Hips": {"to": "Spine", "radius": 0.12, "mass": 11.0, "joint": "", "limits": [], "group": "spine"},
		"Spine": {"to": "Chest", "radius": 0.11, "mass": 7.0, "joint": "cone", "limits": [15, 12], "group": "spine"},
		"Chest": {"to": "UpperChest", "radius": 0.12, "mass": 7.0, "joint": "cone", "limits": [10, 8], "group": "spine"},
		"UpperChest": {"to": "Neck", "radius": 0.13, "mass": 9.0, "joint": "cone", "limits": [10, 8], "group": "spine"},
		"Head": {"to": 0.2, "radius": 0.1, "mass": 5.0, "joint": "cone", "limits": [40, 45], "group": "head"},
		"LeftUpperArm": {"to": "LeftLowerArm", "radius": 0.05, "mass": 2.5, "joint": "cone", "limits": [80, 40], "group": "arms"},
		"LeftLowerArm": {"to": "LeftHand", "radius": 0.045, "mass": 1.6, "joint": "hinge", "limits": [0, 140], "group": "arms"},
		"RightUpperArm": {"to": "RightLowerArm", "radius": 0.05, "mass": 2.5, "joint": "cone", "limits": [80, 40], "group": "arms"},
		"RightLowerArm": {"to": "RightHand", "radius": 0.045, "mass": 1.6, "joint": "hinge", "limits": [0, 140], "group": "arms"},
		"LeftUpperLeg": {"to": "LeftLowerLeg", "radius": 0.075, "mass": 9.0, "joint": "cone", "limits": [55, 20], "group": "legs"},
		"LeftLowerLeg": {"to": "LeftFoot", "radius": 0.055, "mass": 4.0, "joint": "hinge", "limits": [0, 140], "group": "legs"},
		"LeftFoot": {"to": "LeftToes", "radius": 0.045, "mass": 1.0, "joint": "cone", "limits": [25, 10], "group": "legs"},
		"RightUpperLeg": {"to": "RightLowerLeg", "radius": 0.075, "mass": 9.0, "joint": "cone", "limits": [55, 20], "group": "legs"},
		"RightLowerLeg": {"to": "RightFoot", "radius": 0.055, "mass": 4.0, "joint": "hinge", "limits": [0, 140], "group": "legs"},
		"RightFoot": {"to": "RightToes", "radius": 0.045, "mass": 1.0, "joint": "cone", "limits": [25, 10], "group": "legs"},
	}
	return p
