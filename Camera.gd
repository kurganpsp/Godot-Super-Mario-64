extends Spatial

onready var camera := $Node/Root
onready var actual_cam := $Node/Root/Camera
var prev_transform : Transform
var transition := 1.0

var direction : Vector3 setget , get_direction
var state : String setget , get_state

var shake := Vector2()
var shake_speed := 0.0
var shake_time := 0.0
var shake_amount := 0.0

var noise := OpenSimplexNoise.new()
var noise_time := 0.0
var unsteadiness := 0.0

func _init():
	Global.camera = self
	set_process_priority(6)
	
	noise.octaves = 0.0

func _ready():
	$FSM.call_deferred("_update", 1.0)
	camera.transform = transform

func _process(delta : float) -> void:
	$FSM._update(delta)
	
	var new_transform = prev_transform.interpolate_with(self.transform, transition)
	camera.transform = camera.transform.interpolate_with(new_transform, 0.4)
	
	actual_cam.rotation.x = sin(shake_time * 2*PI * shake_speed) * shake_amount * shake_time * shake.y
	actual_cam.rotation.y = sin(shake_time * 2*PI * shake_speed) * shake_amount * shake_time * shake.x
	actual_cam.rotation.x += 0.1 * noise.get_noise_2d(noise_time, 0) * unsteadiness
	actual_cam.rotation.y += 0.1 * noise.get_noise_2d(0, noise_time) * unsteadiness
	
	if shake_time > 0.0:
		shake_time -= delta
	noise_time += delta * 45.0

func set_camera(state : String, duration := 0) -> void:
	$FSM.change_state(state)
	prev_transform = camera.transform
	
	$Tween.interpolate_property(self, "transition", 0.0, 1.0, duration, Tween.TRANS_SINE, Tween.EASE_OUT)
	$Tween.start()

func set_shake(shake_dir : Vector2, shake_speed : float, shake_amount : float, shake_time : float) -> void:
	shake = shake_dir
	self.shake_speed = shake_speed
	self.shake_amount = shake_amount
	self.shake_time = shake_time

func get_direction() -> Vector3:
	return global_transform.basis.z

func get_state() -> String:
	return $FSM.active_state

func teleport(new_transform : Transform) -> void:
	transform = new_transform
	camera.transform = new_transform

#func get_internal_velocity() -> Vector3:
#	var point_a : Vector3 = camera.transform.xform(Vector3())
#	var point_b : Vector3 = transform.xform(Vector3())
#	return point_a - point_b