extends Node

var _camera

var floor_height := -110.0
var target_pos : Vector3

var zoom = 4.0
var zoom_height = 4.0 / 2.0

func _enter() -> void:
	floor_height = -110.0

func _update(delta : float):
	Collisions.push_collision_mask(Collisions.COLLISION_CAMERA)
	
	var prev_translation : Vector3 = _camera.translation
	
	var right : Vector3 = _camera.global_transform.basis[0]
	if Input.is_action_pressed("cam_left"):
		_camera.translation -= 0.4 * right
	elif Input.is_action_pressed("cam_right"):
		_camera.translation += 0.4 * right
	
	target_pos = Global.mario.translation
	
	if floor_height == -110.0:
		floor_height = Global.mario.floor_height
	if Global.mario.floor_surf and Global.mario.floor_surf.type != Surface.SURFACE_DEATH_PLANE:
		var mario_floor_height = max(Global.mario.floor_height, Global.mario.water_level)
		
		if floor_height < mario_floor_height:
			floor_height = lerp(floor_height, mario_floor_height, 0.5)
		else:
			floor_height = Utils.approach(floor_height, mario_floor_height, 0.1)
		
		if floor_height - Global.mario.translation.y > zoom_height:
			floor_height += zoom_height - (floor_height - Global.mario.translation.y)
	
	target_pos.y = floor_height + 1.0
	
	_camera.translation.y = floor_height + zoom
	var dir_to_target := Global.mario.translation.direction_to(_camera.translation)
	var dist_to_target := Global.mario.translation.distance_to(_camera.translation)
	_camera.translation += dir_to_target * (1.5 * zoom - dist_to_target)
	
#	_camera.translation -= target_pos
#	var yaw = atan2(_camera.translation.x, _camera.translation.z)
#
#	if abs(_camera.translation.y) > zoom_height:
#		_camera.translation.y += (zoom_height - _camera.translation.y)
#
#	_camera.translation.x = zoom * cos(_camera.translation.y / zoom_height) * sin(yaw)
#	_camera.translation.z = zoom * cos(_camera.translation.y / zoom_height) * cos(yaw)
#	
#	_camera.translation += target_pos
	
	var step = prev_translation
	for i in 4:
		step += (_camera.translation - prev_translation) * 0.25
		
		var wall_data := Collisions.find_wall_collisions(step, 0.0, 1.0)
		step.x = wall_data.x
		step.z = wall_data.z
		
		var floor_data := Collisions.find_floor(step)
		if floor_data.floor and _camera.translation.y < floor_data.height + 0.2:
			step.y = floor_data.height + 0.2
		
		var ceil_data := Collisions.find_ceil(step)
		if ceil_data.ceil and _camera.translation.y > ceil_data.height - 0.2:
			step.y = floor_data.height - 0.2
		
	_camera.translation = step
	_camera.look_at(Global.mario.translation, Vector3.UP)
	
	Collisions.pop_collision_mask()