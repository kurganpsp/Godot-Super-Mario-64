extends Spatial

var dvols = []
var dpitches = []
var dlocs = []
var timeroot
var root
var scattering : bool = false
export(NodePath) var spawn_node
export var autostart : bool = true
export var volume_range : float = 1.0
export var pitch_range : float= 1.0
export var scatter_range : float = 1.0
export var voices : int = 5
export var min_time : float = 1
export var max_time : float = 5
export var timeout : float = 7
export var randomise : bool = true

func _ready():
	for i in get_children():
		dvols.append(i.unit_db)
		dpitches.append(i.pitch_scale)
		dlocs.append(i.translation)
	if spawn_node:
		if typeof(spawn_node) == TYPE_NODE_PATH:
			root = get_node(spawn_node)
		elif typeof(spawn_node) == TYPE_OBJECT:
			root = spawn_node
	else:
		root = Node2D.new()
		add_child(root)
		root.name = "root"
	if autostart:
		play()
	
func _iplay(sound):
	var snd = sound.duplicate()
	if spawn_node:
		snd.translation = global_transform.origin
	root.add_child(snd)
	snd.play()
	snd.set_script(preload("res://addons/mixing-desk/sound/3d/spawn_sound.gd"))
	snd.setup()

func play():
	if scattering:
		return
	scattering = true
	var timeroot = Node.new()
	timeroot.name = 'timeroot' + str(get_index())
	add_child(timeroot)
	for i in voices:
		var timer = Timer.new()
		timer.name = str('scat_timer_' + str(i))
		timeroot.add_child(timer)
		timer.start(rand_range(min_time,max_time))
		timer.connect("timeout", self, "_scatter_timeout", [timer, min_time, max_time])
	if rand_range(0,1) > 0.7:
		_scatter()
	if timeout != 0:
		yield(get_tree().create_timer(timeout), "timeout")
		stop()
		
func _scatter_timeout(timer, min_time, max_time):
	_scatter()
	timer.start(rand_range(min_time, max_time))
	
func stop():
	scattering = false
	$timeroot.queue_free()
	
func _scatter():
	var ransnd = _get_ransnd()
	_iplay(ransnd)
		
func _get_ransnd(ran=true):
	var children = get_child_count()
	var chance = randi() % (children - 2)
	var ransnd = get_child(chance)
	if ran:
		_randomise(ransnd)
	return ransnd

func _randomise(sound):
	var dvol = dvols[sound.get_index()]
	var dpitch = dpitches[sound.get_index()]
	var dloc = dlocs[sound.get_index()]
	var newvol = (dvol + _range(volume_range))
	var newpitch = (dpitch + _range(pitch_range))
	var newloc = (dloc + Vector3(_range(scatter_range), _range(scatter_range),_range(scatter_range)))
	sound.unit_db = newvol
	sound.pitch_scale = newpitch
	sound.translation = newloc
	
func _range(item : float) -> float:
	return rand_range(-item,item)
