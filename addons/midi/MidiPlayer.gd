extends Node

"""
	pure GDScript MIDI Player [Godot MIDI Player] by Yui Kinomoto @arlez80
"""

# -----------------------------------------------------------------------------
# Import
const ADSR = preload( "ADSR.tscn" )
const SMF = preload( "SMF.gd" )
const SoundFont = preload( "SoundFont.gd" )
const Bank = preload( "Bank.gd" )

# -------------------------------------------------------
# 定数
const max_track:int = 16
const max_channel:int = 16
const max_note_number:int = 128
const max_program_number:int = 128
const drum_track_channel:int = 0x09
const drum_track_bank:int = 128

const midi_master_bus_name:String = "arlez80_GMP_MASTER_BUS"
const midi_channel_bus_name:String = "arlez80_GMP_CHANNEL_BUS%d"

# -----------------------------------------------------------------------------
# Export

# 最大発音数
export (int, 0, 128) var max_polyphony:int = 64
# ファイル
export (String, FILE, "*.mid") var file:String = "" setget set_file
# 再生中か？
export (bool) var playing:bool = false
# ミュートチャンネル
export (Array) var channel_mute:Array = [false,false,false,false,false,false,false,false,false,false,false,false,false,false,false,false]
# 再生速度
export (float) var play_speed:float = 1.0
# 音量
export (float, -1000, 0) var volume_db:float = -20.0 setget set_volume_db
# キーシフト
export (int) var key_shift:int = 0
# ループフラグ
export (bool) var loop:bool = false
# ループ開始位置
export (float) var loop_start:float = 0
# 全ての音をサウンドフォントから読むか？
export (bool) var load_all_voices_from_soundfont:bool = false
# サウンドフォントの再読み込みを行わない
export (bool) var no_reload_soundfont:bool = false
# サウンドフォント
export (String, FILE, "*.sf2") var soundfont:String = ""
# mix_target same as AudioStreamPlayer's one
export (int, "MIX_TARGET_STEREO", "MIX_TARGET_SURROUND", "MIX_TARGET_CENTER") var mix_target:int = AudioStreamPlayer.MIX_TARGET_STEREO
# bus same as AudioStreamPlayer's one
export (String) var bus:String = "Master"

# -----------------------------------------------------------------------------
# 変数

# MIDIデータ
var smf_data = null setget set_smf_data
# MIDIトラックデータ smf_dataを再生用に加工したデータが入る
var track_status = null
# 現在のテンポ
var tempo:float = 120 setget set_tempo
# 秒 -> タイムベース変換係数
var seconds_to_timebase:float = 2.3
# タイムベース -> 秒変換係数
var timebase_to_seconds:float = 1.0 / seconds_to_timebase
# 位置
var position:float = 0
# 最終位置
var last_position:int = 0
# チャンネルステータス
var channel_status:Array = []
# サウンドフォントを再生用に加工したもの
var bank = null
# AudioStreamPlayer
var audio_stream_players:Array = []
# ドラムトラック用アサイングループ
var drum_assign_groups = {
	# Hi-Hats
	42: 42,	# Closed Hi-Hat
	44: 42,	# Pedal Hi-Hat
	46: 42,	# Pedal Hi-Hat
}
# SysEx
var sys_ex = {
	"gs_reset": false,
	"gm_system_on": false,
	"xg_system_on": false,
}

# MIDIチェンネルプレフィックス
var _midi_channel_prefix:int = 0
# 曲で使用中のプログラム番号を格納
var _used_program_numbers = []
# MIDIチャンネルエフェクト
var channel_audio_effects:Array = []
# パンの強さを定義
var pan_power:float = 0.7
# リバーブの強さを定義
var reverb_power:float = 0.5
# コーラスの強さを定義
var chorus_power:float = 0.7

# -----------------------------------------------------------------------------
# シグナル

signal changed_tempo( tempo )
signal appeared_text_event( text )
signal appeared_copyright( copyright )
signal appeared_track_name( channel_number, name )
signal appeared_instrument_name( channel_number, name )
signal appeared_lyric( lyric )
signal appeared_marker( marker )
signal appeared_cue_point( cue_point )
signal midi_event( channel, event )
signal looped

"""
	準備
"""
func _ready( ):
	AudioServer.add_bus( -1 )
	var midi_master_bus_idx:int = AudioServer.get_bus_count( ) - 1
	AudioServer.set_bus_name( midi_master_bus_idx, self.midi_master_bus_name )
	AudioServer.set_bus_send( midi_master_bus_idx, self.bus )

	for i in range( 0, 16 ):
		AudioServer.add_bus( -1 )
		var midi_channel_bus_idx:int = AudioServer.get_bus_count( ) - 1
		AudioServer.set_bus_name( midi_channel_bus_idx, self.midi_channel_bus_name % i )
		AudioServer.set_bus_send( midi_channel_bus_idx, self.midi_master_bus_name )
		AudioServer.set_bus_volume_db( midi_channel_bus_idx, 0.0 )
		var ae_panner = AudioEffectPanner.new( )
		var ae_reverb = AudioEffectReverb.new( )
		ae_reverb.wet = 0.03
		var ae_chorus = AudioEffectChorus.new( )
		ae_chorus.wet = 0.0
		AudioServer.add_bus_effect( midi_channel_bus_idx, ae_chorus )
		AudioServer.add_bus_effect( midi_channel_bus_idx, ae_panner )
		AudioServer.add_bus_effect( midi_channel_bus_idx, ae_reverb )
		self.channel_audio_effects.append({
			"ae_panner": ae_panner,
			"ae_reverb": ae_reverb,
			"ae_chorus": ae_chorus,
		})

	if self.playing:
		self.play( )

"""
	通知
"""
func _notification( what:int ):
	# 破棄時
	if what == NOTIFICATION_PREDELETE:
		AudioServer.remove_bus( AudioServer.get_bus_index( self.midi_master_bus_name ) )
		for i in range( 0, 16 ):
			AudioServer.remove_bus( AudioServer.get_bus_index( self.midi_channel_bus_name % i ) )

"""
	再生前の初期化
"""
func _prepare_to_play( ):
	# ファイル読み込み
	if self.smf_data == null:
		var smf_reader = SMF.new( )
		self.smf_data = smf_reader.read_file( self.file )

	self._init_track( )
	self._analyse_smf( )
	self._init_channel( )

	# 楽器
	if self.bank == null:
		self.bank = Bank.new( )
		if self.soundfont != "":
			var sf_reader = SoundFont.new( )
			var sf2 = sf_reader.read_file( self.soundfont )
			var voices = null
			if not self.load_all_voices_from_soundfont:
				voices = self._used_program_numbers
			self.bank.read_soundfont( sf2, voices )

	# 発音機
	if self.audio_stream_players.size( ) == 0:
		for i in range( self.max_polyphony ):
			var audio_stream_player = ADSR.instance( )
			audio_stream_player.mix_target = self.mix_target
			audio_stream_player.bus = self.bus
			self.add_child( audio_stream_player )
			self.audio_stream_players.append( audio_stream_player )
	else:
		for audio_stream_player in self.audio_stream_players:
			audio_stream_player.mix_target = self.mix_target
			audio_stream_player.bus = self.bus

"""
	トラック初期化
"""
func _init_track( ):
	var track_status_events:Array = []
	self.sys_ex = {
		"gs_reset": false,
		"gm_system_on": false,
		"xg_system_on": false,
	}

	if len( self.smf_data.tracks ) == 1:
		track_status_events = self.smf_data.tracks[0].events
	else:
		var tracks = []
		for track in self.smf_data.tracks:
			tracks.append({"pointer":0, "events":track.events, "length": len( track.events )})

		var time:int = 0
		var finished:bool = false
		while not finished:
			finished = true

			var next_time:int = 0x7fffffff
			for track in tracks:
				var p = track.pointer
				if track.length <= p: continue
				finished = false
				
				var e = track.events[p]
				var e_time = e.time
				if e_time == time:
					track_status_events.append( e )
					track.pointer += 1
					next_time = e_time
				elif e_time < next_time:
					next_time = e_time
			time = next_time

	self.last_position = track_status_events[len(track_status_events)-1].time
	self.track_status = {
		"events": track_status_events,
		"event_pointer": 0,
	}

"""
	SMF解析
"""
func _analyse_smf( ):
	var channels = []
	for i in range( max_channel ):
		channels.append({
			"number": i,
			"bank": 0,
		})
	self.loop_start = 0.0
	self._used_program_numbers = [0, self.drum_track_bank << 7]	# GrandPiano and Standard Kit

	for event_chunk in self.track_status.events:
		var channel_number:int = event_chunk.channel_number
		var channel = channels[channel_number]
		var event = event_chunk.event

		match event.type:
			SMF.MIDIEventType.program_change:
				var program_number:int = event.number | ( channel.bank << 7 )
				if not( event.number in self._used_program_numbers ):
					self._used_program_numbers.append( event.number )
				if not( program_number in self._used_program_numbers ):
					self._used_program_numbers.append( program_number )
			SMF.MIDIEventType.control_change:
				match event.number:
					SMF.control_number_bank_select_msb:
						if channel.number == drum_track_channel:
							channel.bank = self.drum_track_bank
						else:
							channel.bank = ( channel.bank & 0x7F ) | ( event.value << 7 )
					SMF.control_number_bank_select_lsb:
						if channel.number == drum_track_channel:
							channel.bank = self.drum_track_bank
						else:
							channel.bank = ( channel.bank & 0x3F80 ) | ( event.value & 0x7F )
					SMF.control_number_tkool_loop_point:
						self.loop_start = float( event_chunk.time )
			_:
				pass

"""
	チャンネル初期化
"""
func _init_channel( ):
	self.channel_status = []
	for i in range( max_channel ):
		var drum_track:bool = ( i == drum_track_channel )
		var bank:int = 0
		if drum_track:
			bank = self.drum_track_bank
		self.channel_status.append({
			"number": i,
			"track_name": "Track %d" % i,
			"instrument_name": "",
			"note_on": {},
			"bank": bank,

			"program": 0,
			"pitch_bend": 0.0,

			"volume": 100.0 / 127.0,
			"expression": 1.0,
			"reverb": 0.0,		# Effect 1
			"tremolo": 0.0,		# Effect 2
			"chorus": 0.0,		# Effect 3
			"celeste": 0.0,		# Effect 4
			"phaser": 0.0,		# Effect 5
			"modulation": 0.0,
			"hold": false,		# Sustain Pedal
			"portamento": 0.0,
			"sostenuto": 0.0,
			"freeze": false,
			"pan": 0.5,

			"drum_track": drum_track,

			"rpn": {
				"selected_msb": 0,
				"selected_lsb": 0,

				"pitch_bend_sensitivity": 2.0,
				"pitch_bend_sensitivity_msb": 2.0,
				"pitch_bend_sensitivity_lsb": 0.0,

				"modulation_sensitivity": 0.25,
				"modulation_sensitivity_msb": 0.25,
				"modulation_sensitivity_lsb": 0.0,
			},
		})

"""
	再生
	@param	from_position
"""
func play( from_position:float = 0.0 ):
	self._prepare_to_play( )
	self.playing = true
	if from_position == 0.0:
		self.position = 0.0
		self.track_status.event_pointer = 0
	else:
		self.seek( from_position )

"""
	シーク
"""
func seek( to_position:float ):
	self._stop_all_notes( )
	self.position = to_position

	var pointer:int = 0
	var new_position:int = int( floor( self.position ) )
	var length:int = len( self.track_status.events )
	for event_chunk in self.track_status.events:
		if new_position <= event_chunk.time:
			break

		var channel = self.channel_status[event_chunk.channel_number]
		var event = event_chunk.event

		match event.type:
			SMF.MIDIEventType.program_change:
				channel.program = event.number
			SMF.MIDIEventType.control_change:
				self._process_track_event_control_change( channel, event.number, event.value )
			SMF.MIDIEventType.pitch_bend:
				self._process_pitch_bend( channel, event.value )
			SMF.MIDIEventType.system_event:
				self._process_track_system_event( channel, event )
			_:
				# 無視
				pass
		pointer += 1
	self.track_status.event_pointer = pointer

"""
	停止
"""
func stop( ):
	self._stop_all_notes( )
	self.playing = false

"""
	リセット命令を強制的に発行する
"""
func send_reset( ):
	self._process_track_sys_ex_reset_all_channels( )

"""
	ファイル変更
"""
func set_file( path:String ):
	file = path
	self.smf_data = null

"""
	SMFデータ更新
"""
func set_smf_data( sd ):
	smf_data = sd
	if not self.no_reload_soundfont: self.bank = null

"""
	テンポ設定
"""
func set_tempo( bpm:float ):
	tempo = bpm
	self.seconds_to_timebase = tempo / 60.0
	self.timebase_to_seconds = 60.0 / tempo
	self.emit_signal( "changed_tempo", bpm )

"""
	音量設定
"""
func set_volume_db( vdb:float ):
	volume_db = vdb
	for channel in self.channel_status:
		AudioServer.set_bus_volume_db( AudioServer.get_bus_index( self.midi_channel_bus_name % channel.number ), linear2db( channel.volume * channel.expression ) + self.volume_db )

"""
	全音を止める
"""
func _stop_all_notes( ):
	for audio_stream_player in self.audio_stream_players:
		audio_stream_player.hold = false
		audio_stream_player.stop( )

	for channel in self.channel_status:
		channel.note_on = {}

"""
	毎フレーム処理
"""
func _process( delta:float ):
	for channel in self.channel_status:
		for key_number in channel.note_on.keys( ):
			var note_on = channel.note_on[key_number]
			if not note_on.playing:
				channel.note_on.erase( key_number )

	if self.smf_data != null:
		if self.playing:
			self.position += float( self.smf_data.timebase ) * delta * self.seconds_to_timebase * self.play_speed
			self._process_track( )

	for asp in self.audio_stream_players:
		asp._update_adsr( delta )

"""
	トラック処理
"""
func _process_track( ):
	var track = self.track_status
	if track.events == null:
		return

	var length:int = len( track.events )

	if length <= track.event_pointer:
		if self.loop:
			var diff:float = self.position - track.events[len( track.events ) - 1].time
			self.seek( self.loop_start )
			self.emit_signal( "looped" )
			self.position += diff
		else:
			self.playing = false
			return

	var execute_event_count:int = 0
	var current_position:int = int( ceil( self.position ) )

	while track.event_pointer < length:
		var event_chunk = track.events[track.event_pointer]
		if current_position <= event_chunk.time:
			break
		track.event_pointer += 1
		execute_event_count += 1

		var channel = self.channel_status[event_chunk.channel_number]
		var event = event_chunk.event

		self.emit_signal( "midi_event", channel, event )

		match event.type:
			SMF.MIDIEventType.note_off:
				self._process_track_event_note_off( channel, event.note )
			SMF.MIDIEventType.note_on:
				self._process_track_event_note_on( channel, event.note, event.velocity )
			SMF.MIDIEventType.program_change:
				channel.program = event.number
			SMF.MIDIEventType.control_change:
				self._process_track_event_control_change( channel, event.number, event.value )
			SMF.MIDIEventType.pitch_bend:
				self._process_pitch_bend( channel, event.value )
			SMF.MIDIEventType.system_event:
				self._process_track_system_event( channel, event )
			_:
				# 無視
				pass

	return execute_event_count

func receive_raw_midi_message( input_event:InputEventMIDI ):
	var channel = self.channel_status[input_event.channel]

	match input_event.message:
		0x08:
			self._process_track_event_note_off( channel, input_event.pitch )
		0x09:
			# note-on vel0をnote-offにはしてくれている https://github.com/godotengine/godot/blob/master/core/os/midi_driver.cpp#L79
			self._process_track_event_note_on( channel, input_event.pitch, input_event.velocity )
		0x0A:
			# polyphonic key pressure プレイヤー自体が未実装
			pass
		0x0B:
			self._process_track_event_control_change( channel, input_event.controller_number, input_event.controller_value )
		0x0C:
			channel.program = input_event.instrument
		0x0D:
			# channel pressure プレイヤー自体が未実装
			pass
		0x0E:
			# 3.1でおかしい値を返す対応。3.2ではvelocityが0のままのハズなので影響はない
			var fixed_pitch = ( input_event.velocity << 7 ) | input_event.pitch
			self._process_pitch_bend( channel, fixed_pitch )
		0x0F:
			# InputEventMIDIはMIDI System Eventを飛ばしてこない！
			pass
		_:
			print( "unknown message %x" % input_event.message )
			breakpoint

func _process_pitch_bend( channel, value:int ):
	var pb:float = float( value ) / 8192.0 - 1.0
	var pbs:float = channel.rpn.pitch_bend_sensitivity
	channel.pitch_bend = pb

	for note in channel.note_on.values( ):
		note.pitch_bend_sensitivity = pbs
		note.pitch_bend = pb

func _process_track_event_note_off( channel, note:int ):
	if channel.drum_track: return

	var key_number:int = note + self.key_shift
	if channel.note_on.has( key_number ):
		var note_player = channel.note_on[key_number]
		if note_player != null:
			note_player.start_release( )
			if not channel.hold:
				channel.note_on.erase( key_number )

func _process_track_event_note_on( channel, note:int, velocity:int ):
	if not self.channel_mute[channel.number]:
		var key_number:int = note + self.key_shift
		var preset = self.bank.get_preset( channel.program, channel.bank )
		var instrument = preset.instruments[key_number]
		var assign_group:int = key_number
		if channel.drum_track:
			if key_number in self.drum_assign_groups:
				assign_group = self.drum_assign_groups[key_number]

		if instrument != null:
			if channel.note_on.has( assign_group ):
				channel.note_on[ assign_group ].start_release( )

			if channel.hold and channel.note_on.has( key_number ):
				var note_player = channel.note_on[key_number]
				note_player.hold = false
				note_player.start_release( )
				channel.note_on.erase( key_number )

			var note_player = self._get_idle_player( )
			if note_player != null:
				note_player.bus = self.midi_channel_bus_name % channel.number
				note_player.velocity = velocity
				note_player.pitch_bend = channel.pitch_bend
				note_player.pitch_bend_sensitivity = channel.rpn.pitch_bend_sensitivity
				note_player.hold = channel.hold
				note_player.modulation = channel.modulation
				note_player.modulation_sensitivity = channel.rpn.modulation_sensitivity
				note_player.auto_release_mode = channel.drum_track
				note_player.set_instrument( instrument )
				note_player.play( 0.0 )
				channel.note_on[ assign_group ] = note_player

func _process_track_event_control_change( channel, number:int, value:int ):
	match number:
		SMF.control_number_volume:
			channel.volume = float( value ) / 127.0
			AudioServer.set_bus_volume_db( AudioServer.get_bus_index( self.midi_channel_bus_name % channel.number ), linear2db( channel.volume * channel.expression ) + self.volume_db )
		SMF.control_number_modulation:
			channel.modulation = float( value ) / 127.0
			self._apply_channel_modulation( channel )
		SMF.control_number_expression:
			channel.expression = float( value ) / 127.0
			AudioServer.set_bus_volume_db( AudioServer.get_bus_index( self.midi_channel_bus_name % channel.number ), linear2db( channel.volume * channel.expression ) + self.volume_db )
		SMF.control_number_reverb_send_level:
			channel.reverb = float( value ) / 127.0
			self.channel_audio_effects[channel.number].ae_reverb.wet = channel.reverb * self.reverb_power
		SMF.control_number_tremolo_depth:
			channel.tremolo = float( value ) / 127.0
		SMF.control_number_chorus_send_level:
			channel.chorus = float( value ) / 127.0
			self.channel_audio_effects[channel.number].ae_chorus.wet = channel.chorus * self.chorus_power
		SMF.control_number_celeste_depth:
			channel.celeste = float( value ) / 127.0
		SMF.control_number_phaser_depth:
			channel.phaser = float( value ) / 127.0
		SMF.control_number_pan:
			channel.pan = float( value ) / 127.0
			self.channel_audio_effects[channel.number].ae_panner.pan = ( ( channel.pan * 2 ) - 1.0 ) * self.pan_power
		SMF.control_number_hold:
			channel.hold = 64 <= value
			self._apply_channel_hold( channel )
		SMF.control_number_portament:
			channel.portament = float( value ) / 127.0
		SMF.control_number_sostenuto:
			channel.sostenuto = float( value ) / 127.0
		SMF.control_number_freeze:
			channel.freeze = float( value ) / 127.0
		SMF.control_number_bank_select_msb:
			if channel.drum_track:
				channel.bank = self.drum_track_bank
			else:
				channel.bank = ( channel.bank & 0x7F ) | ( value << 7 )
		SMF.control_number_bank_select_lsb:
			if channel.drum_track:
				channel.bank = self.drum_track_bank
			else:
				channel.bank = ( channel.bank & 0x3F80 ) | ( value & 0x7F )
		SMF.control_number_rpn_lsb:
			channel.rpn.selected_lsb = value
		SMF.control_number_rpn_msb:
			channel.rpn.selected_msb = value
		SMF.control_number_data_entry_msb:
			self._process_track_event_control_change_rpn_data_entry_msb( channel, value )
		SMF.control_number_data_entry_lsb:
			self._process_track_event_control_change_rpn_data_entry_lsb( channel, value )
		SMF.control_number_all_sound_off:
			self._stop_all_notes( )
		SMF.control_number_all_note_off:
			for key_number in channel.note_on.keys( ):
				var note_on = channel.note_on[key_number]
				note_on.hold = false
				note_on.start_release( )
				channel.note_on.erase( key_number )
		_:
			# 無視
			pass

func _apply_channel_modulation( channel ):
	var ms:float = channel.rpn.modulation_sensitivity
	var m:float = channel.modulation
	for note in channel.note_on.values( ):
		note.modulation_sensitivity = ms
		note.modulation = m

func _apply_channel_hold( channel ):
	var hold:bool = channel.hold
	for key_number in channel.note_on.keys( ):
		var note = channel.note_on[key_number]
		note.hold = hold
		if note.request_release:
			channel.note_on.erase( key_number )

func _process_track_event_control_change_rpn_data_entry_msb( channel, value:int ):
	match channel.rpn.selected_msb:
		0:
			match channel.rpn.selected_lsb:
				SMF.rpn_control_number_pitch_bend_sensitivity:
					channel.rpn.pitch_bend_sensitivity_msb = float( value )
					if 12 < channel.rpn.pitch_bend_sensitivity_msb: channel.rpn.pitch_bend_sensitivity_msb = 12
					channel.rpn.pitch_bend_sensitivity = channel.rpn.pitch_bend_sensitivity_msb + channel.rpn.pitch_bend_sensitivity_lsb / 100.0
				_:
					pass
		_:
			pass

func _process_track_event_control_change_rpn_data_entry_lsb( channel, value:int ):
	match channel.rpn.selected_msb:
		0:
			match channel.rpn.selected_lsb:
				SMF.rpn_control_number_pitch_bend_sensitivity:
					channel.rpn.pitch_bend_sensitivity_lsb = float( value )
					channel.rpn.pitch_bend_sensitivity = channel.rpn.pitch_bend_sensitivity_msb + channel.rpn.pitch_bend_sensitivity_lsb / 100.0
				_:
					pass
		_:
			pass

func _process_track_system_event( channel, event ):
	match event.args.type:
		SMF.MIDISystemEventType.set_tempo:
			self.tempo = 60000000.0 / float( event.args.bpm )
		SMF.MIDISystemEventType.text_event:
			self.emit_signal( "appeared_text_event", event.args.text )
		SMF.MIDISystemEventType.copyright:
			self.emit_signal( "appeared_copyright", event.args.text )
		SMF.MIDISystemEventType.track_name:
			self.emit_signal( "appeared_track_name", self._midi_channel_prefix, event.args.text )
			self.channel_status[self._midi_channel_prefix].track_name = event.args.text
		SMF.MIDISystemEventType.instrument_name:
			self.emit_signal( "appeared_instrument_name", self._midi_channel_prefix, event.args.text )
			self.channel_status[self._midi_channel_prefix].instrument_name = event.args.text
		SMF.MIDISystemEventType.lyric:
			self.emit_signal( "appeared_lyric", event.args.text )
		SMF.MIDISystemEventType.marker:
			self.emit_signal( "appeared_marker", event.args.text )
		SMF.MIDISystemEventType.cue_point:
			self.emit_signal( "appeared_cue_point", event.args.text )
		SMF.MIDISystemEventType.midi_channel_prefix:
			self._midi_channel_prefix = event.args.channel
		SMF.MIDISystemEventType.sys_ex:
			self._process_track_sys_ex( channel, event.args )
		SMF.MIDISystemEventType.divided_sys_ex:
			self._process_track_sys_ex( channel, event.args )
		_:
			# 無視
			pass

func _process_track_sys_ex( channel, event_args ):
	match event_args.manifacture_id:
		SMF.manufacture_id_universal_nopn_realtime_sys_ex:
			if self._is_same_data( event_args.data, [0x7f,0x09,0x01,0xf7] ):
				self.sys_ex.gm_system_on = true
				self._process_track_sys_ex_reset_all_channels( )
		SMF.manufacture_id_roland_corporation:
			if self._is_same_data( event_args.data, [-1,0x42,0x12,0x40,0x00,0x7f,0x00,0x41,0xf7] ):
				self.sys_ex.gs_reset = true
				self._process_track_sys_ex_reset_all_channels( )
		SMF.manufacture_id_yamaha_corporation:
			if self._is_same_data( event_args.data, [-1,0x4c,0x00,0x00,0x7E,0x00,0xf7] ):
				self.sys_ex.xg_system_on = true
				self._process_track_sys_ex_reset_all_channels( )

func _process_track_sys_ex_reset_all_channels( ):
	var init_params = {
		"program": 0,
		"pitch_bend": 0.0,
	
		"volume": 100.0 / 127.0,
		"expression": 1.0,
		"reverb": 0.0,		# Effect 1
		"tremolo": 0.0,		# Effect 2
		"chorus": 0.0,		# Effect 3
		"celeste": 0.0,		# Effect 4
		"phaser": 0.0,		# Effect 5
		"modulation": 0.0,
		"hold": false,		# Sustain Pedal
		"portamento": 0.0,
		"sostenuto": 0.0,
		"freeze": false,
		"pan": 0.5,
	}
	var rpn_init_params = {
		"selected_msb": 0,
		"selected_lsb": 0,

		"pitch_bend_sensitivity": 2.0,
		"pitch_bend_sensitivity_msb": 2.0,
		"pitch_bend_sensitivity_lsb": 0.0,

		"modulation_sensitivity": 0.25,
		"modulation_sensitivity_msb": 0.25,
		"modulation_sensitivity_lsb": 0.0,
	};

	for audio_stream_player in self.audio_stream_players:
		audio_stream_player.hold = false
		audio_stream_player.start_release( )

	for channel in self.channel_status:
		for name in init_params.keys( ):
			channel[name] = init_params[name]
		for name in rpn_init_params.keys( ):
			channel.rpn[name] = rpn_init_params[name]

		AudioServer.set_bus_volume_db( AudioServer.get_bus_index( self.midi_channel_bus_name % channel.number ), linear2db( float( channel.volume * channel.expression ) ) )
		self.channel_audio_effects[channel.number].ae_reverb.wet = channel.reverb * self.reverb_power
		self.channel_audio_effects[channel.number].ae_chorus.wet = channel.chorus * self.chorus_power
		self.channel_audio_effects[channel.number].ae_panner.pan = ( ( channel.pan * 2 ) - 1.0 ) * self.pan_power

func _is_same_data( data_a, data_b ):
	if len( data_a ) != len( data_b ): return false

	var id:int = 0
	var incorrect:bool = false
	for t in data_a:
		if t != -1 and t != data_b[id]:
			incorrect = true
			break
		id += 1
	return not incorrect

func _get_idle_player( ):
	var stopped_audio_stream_player = null
	var minimum_volume_db:float = -100.0
	var oldest_audio_stream_player = null
	var oldest:float = 0.0

	for audio_stream_player in self.audio_stream_players:
		if not audio_stream_player.playing:
			return audio_stream_player
		if audio_stream_player.releasing and audio_stream_player.current_volume_db < minimum_volume_db:
			stopped_audio_stream_player = audio_stream_player
			minimum_volume_db = audio_stream_player.current_volume_db
		if oldest < audio_stream_player.using_timer:
			oldest_audio_stream_player = audio_stream_player
			oldest = audio_stream_player.using_timer

	if stopped_audio_stream_player != null:
		return stopped_audio_stream_player

	return oldest_audio_stream_player

"""
	現在発音中の音色数を返す
"""
func get_now_playing_polyphony( ):
	var polyphony:int = 0
	for audio_stream_player in self.audio_stream_players:
		if audio_stream_player.playing:
			polyphony += 1
	return polyphony
