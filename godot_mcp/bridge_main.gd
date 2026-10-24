extends SceneTree
## godot-mcp bridge — run any Godot 4 project under external agent control,
## with ZERO files installed into the game project.
##
## Launch (normally done by server.py):
##   godot --path <project> -s /path/to/godot-mcp/bridge_main.gd
##
## This script boots as a custom SceneTree: it instantiates the project's
## autoloads and main scene, then adds a Bridge node that serves a TCP
## protocol on 127.0.0.1:$GODOT_MCP_PORT (default 7777).
##
## Protocol: newline-delimited JSON. Send one line containing a JSON array of
## steps; when the batch finishes the bridge replies with one line of JSON
## (samples, events, eval results, screenshot paths, scene info).
##
## Steps:
##   {"do":"input", "actions":["ui_left"], "keys":["Z"], "frames":30}
##       hold input-map actions and/or raw keys for N physics frames, release
##   {"do":"wait", "frames":30}
##   {"do":"shot", "name":"my_shot"}          PNG saved, path in result "shots"
##   {"do":"eval", "expr":"get_node('Player').velocity"}
##       evaluate an Expression against the current scene; result in "evals"
##   {"do":"watch", "name":"hp", "expr":"get_node('Player').hp"}
##       re-evaluate every frame; emits an event whenever the value changes,
##       and includes the value in every telemetry sample. Persists until reset.
##   {"do":"unwatch", "name":"hp"}
##   {"do":"call", "node":"Player", "method":"take_damage", "args":[5]}
##   {"do":"set", "node":"Player", "prop":"global_position", "value":[100, 200]}
##       [x,y] / [x,y,z] auto-convert to Vector2/3 when the property is one
##   {"do":"teleport", "x":100, "y":200}      move player node, zero velocity
##   {"do":"tree", "depth":3}                 scene tree dump in result "tree"
##   {"do":"sample_every", "frames":5}        telemetry stride (default 5)
##   {"do":"reset"}                           reload the scene fresh
##   {"do":"quit"}
##
## Environment:
##   GODOT_MCP_PORT    TCP port (default 7777)
##   GODOT_MCP_SCENE   scene to load (default: the project's main scene)
##   GODOT_MCP_PLAYER  node path of the "player" (default: first CharacterBody2D/3D)

func _initialize() -> void:
	_load_autoloads()
	var bridge := Bridge.new()
	bridge.name = "GodotMCP"
	root.add_child(bridge)
	var scene_path := OS.get_environment("GODOT_MCP_SCENE")
	if scene_path.is_empty():
		scene_path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if scene_path.is_empty():
		push_error("godot-mcp: project has no main scene; set GODOT_MCP_SCENE")
		quit(1)
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("godot-mcp: cannot load scene: " + scene_path)
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	current_scene = scene

## Script mode (-s) skips autoload singletons; recreate them so games that
## rely on them behave normally.
func _load_autoloads() -> void:
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop.name
		if not pname.begins_with("autoload/"):
			continue
		var path := str(ProjectSettings.get_setting(pname)).trim_prefix("*")
		var res := load(path)
		var inst: Node = null
		if res is PackedScene:
			inst = (res as PackedScene).instantiate()
		elif res is Script:
			var obj = (res as Script).new()
			inst = obj as Node
		if inst != null:
			inst.name = pname.trim_prefix("autoload/")
			root.add_child(inst)


class Bridge:
	extends Node

	var port := 7777
	var shots_dir := ""

	var _server := TCPServer.new()
	var _client: StreamPeerTCP = null
	var _rx := ""

	var t := 0
	var _queue: Array = []
	var _frames_left := 0
	var _held_actions: Array = []
	var _held_keys: Array = []
	var _samples: Array = []
	var _events: Array = []
	var _shots: Array = []
	var _evals: Array = []
	var _tree_dump := ""
	var _sample_every := 5
	var _executing := false
	var _quit_at := -1

	# name -> {"expr": Expression, "src": String, "last": Variant, "errored": bool}
	var _watches: Dictionary = {}

	var _player: Node = null
	var _player_env_path := ""
	var _cam: Camera2D = null

	func _ready() -> void:
		var port_env := OS.get_environment("GODOT_MCP_PORT")
		if not port_env.is_empty():
			port = int(port_env)
		_player_env_path = OS.get_environment("GODOT_MCP_PLAYER")
		var proj := str(ProjectSettings.get_setting("application/config/name", "game"))
		var tmp := OS.get_temp_dir() if OS.has_method("get_temp_dir") else "/tmp"
		shots_dir = tmp.path_join("godot_mcp").path_join(proj.to_snake_case()).path_join("shots")
		DirAccess.make_dir_recursive_absolute(shots_dir)
		var err := _server.listen(port, "127.0.0.1")
		if err != OK:
			push_error("godot-mcp: cannot listen on port %d (%s) — already running?" % [port, error_string(err)])
			get_tree().quit(1)
			return
		print("godot-mcp bridge listening on 127.0.0.1:%d" % port)

	func _physics_process(_delta: float) -> void:
		t += 1
		if _quit_at > 0 and t >= _quit_at:
			get_tree().quit()
			return
		_ensure_player()
		_poll_net()
		if _executing:
			_tick_watches()
			if t % _sample_every == 0:
				_samples.append(_sample())
			_frames_left -= 1
			if _frames_left <= 0:
				_release_all()
				_samples.append(_sample())
				_advance()
		else:
			_maybe_start_batch()

	# ---- player discovery / camera ----

	func _ensure_player() -> void:
		if is_instance_valid(_player) and _player.is_inside_tree():
			return
		_player = null
		var scene := get_tree().current_scene
		if scene == null:
			return
		if not _player_env_path.is_empty():
			_player = scene.get_node_or_null(_player_env_path)
		if _player == null:
			_player = _find_first(scene, ["CharacterBody2D", "CharacterBody3D"])
		if _player != null:
			_attach_camera()

	func _find_first(node: Node, classes: Array) -> Node:
		for cls in classes:
			if node.is_class(cls):
				return node
		for child in node.get_children():
			var found := _find_first(child, classes)
			if found != null:
				return found
		return null

	## Follow the player with a camera so screenshots stay centered on the
	## action — but only in 2D and only if the game has no camera of its own.
	func _attach_camera() -> void:
		if not (_player is Node2D):
			return
		if is_instance_valid(_cam) and _cam.get_parent() == _player:
			return
		if _player.get_viewport().get_camera_2d() != null:
			return
		_cam = Camera2D.new()
		_cam.name = "GodotMCPCam"
		_player.add_child(_cam)
		_cam.make_current()

	# ---- networking ----

	func _poll_net() -> void:
		if _client == null and _server.is_connection_available():
			_client = _server.take_connection()
			_rx = ""
		if _client == null:
			return
		_client.poll()
		var status := _client.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			if status != StreamPeerTCP.STATUS_CONNECTING:
				_client = null
			return
		var n := _client.get_available_bytes()
		if n > 0:
			var res := _client.get_data(n)
			if res[0] == OK:
				_rx += (res[1] as PackedByteArray).get_string_from_utf8()

	func _maybe_start_batch() -> void:
		var idx := _rx.find("\n")
		if idx < 0:
			return
		var line := _rx.substr(0, idx).strip_edges()
		_rx = _rx.substr(idx + 1)
		if line.is_empty():
			return
		_samples = []
		_events = []
		_shots = []
		_evals = []
		_tree_dump = ""
		var parsed = JSON.parse_string(line)
		var steps = null
		if parsed is Array:
			steps = parsed
		elif parsed is Dictionary and parsed.get("steps") is Array:
			steps = parsed["steps"]
		if steps == null:
			_events.append({"t": t, "event": "error", "detail": "request must be a JSON array of steps"})
			_finish()
			return
		_queue = steps
		_executing = true
		_samples.append(_sample())
		_advance()

	func _finish() -> void:
		_executing = false
		var scene := get_tree().current_scene
		var res := {
			"status": "done",
			"t": t,
			"project": str(ProjectSettings.get_setting("application/config/name", "")),
			"project_dir": ProjectSettings.globalize_path("res://"),
			"scene": scene.scene_file_path if scene != null else "",
			"player_node": str(get_tree().current_scene.get_path_to(_player)) if is_instance_valid(_player) else "",
			"player": _sample(),
			"events": _events,
			"samples": _samples,
			"shots": _shots,
			"evals": _evals,
		}
		if not _tree_dump.is_empty():
			res["tree"] = _tree_dump
		if _client != null and _client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_client.put_data((JSON.stringify(res) + "\n").to_utf8_buffer())
		_samples = []
		_events = []
		_shots = []
		_evals = []
		_tree_dump = ""

	# ---- step execution ----

	## Pop steps until we hit a timed one (input/wait) or the queue empties.
	## Instant steps execute immediately within the same frame.
	func _advance() -> void:
		while true:
			if _queue.is_empty():
				_finish()
				return
			var step = _queue.pop_front()
			if not (step is Dictionary):
				_events.append({"t": t, "event": "error", "detail": "step is not an object: " + str(step)})
				continue
			_events.append({"t": t, "event": "step", "detail": JSON.stringify(step)})
			match str(step.get("do", "")):
				"input":
					_held_actions = _as_array(step.get("actions", []))
					_held_keys = _as_array(step.get("keys", []))
					for a in _held_actions:
						Input.action_press(a)
					for k in _held_keys:
						_send_key(k, true)
					_frames_left = int(step.get("frames", 1))
					return
				"wait":
					_frames_left = int(step.get("frames", 1))
					return
				"shot":
					_shot(str(step.get("name", "shot_%d" % t)))
				"eval":
					_do_eval(str(step.get("expr", "")))
				"watch":
					_add_watch(str(step.get("name", "")), str(step.get("expr", "")))
				"unwatch":
					_watches.erase(str(step.get("name", "")))
				"call":
					_do_call(step)
				"set":
					_do_set(step)
				"teleport":
					_do_teleport(step)
				"tree":
					_tree_dump = _dump_tree(int(step.get("depth", 3)))
				"sample_every":
					_sample_every = maxi(1, int(step.get("frames", 5)))
				"reset":
					_do_reset()
					# Behave as a short timed step so the fresh scene has run
					# before any same-batch shot/eval/input observes it.
					_frames_left = 2
					return
				"quit":
					_queue.clear()
					_finish()
					_quit_at = t + 3  # a few frames so the reply flushes before exit
					return
				_:
					_events.append({"t": t, "event": "error", "detail": "unknown step: " + str(step)})

	func _do_eval(src: String) -> void:
		var expr := Expression.new()
		if expr.parse(src) != OK:
			_evals.append({"expr": src, "error": expr.get_error_text()})
			return
		var v = expr.execute([], get_tree().current_scene)
		if expr.has_execute_failed():
			_evals.append({"expr": src, "error": expr.get_error_text()})
		else:
			_evals.append({"expr": src, "value": _jsonable(v)})

	func _add_watch(watch_name: String, src: String) -> void:
		if watch_name.is_empty() or src.is_empty():
			_events.append({"t": t, "event": "error", "detail": "watch needs name and expr"})
			return
		var expr := Expression.new()
		if expr.parse(src) != OK:
			_events.append({"t": t, "event": "error", "detail": "watch '%s' parse failed: %s" % [watch_name, expr.get_error_text()]})
			return
		_watches[watch_name] = {"expr": expr, "src": src, "last": "__unset__", "errored": false}

	func _tick_watches() -> void:
		for watch_name in _watches:
			var w: Dictionary = _watches[watch_name]
			var v = (w["expr"] as Expression).execute([], get_tree().current_scene)
			if (w["expr"] as Expression).has_execute_failed():
				if not w["errored"]:
					w["errored"] = true
					_events.append({"t": t, "event": "error", "detail": "watch '%s' failed: %s" % [watch_name, (w["expr"] as Expression).get_error_text()]})
				continue
			w["errored"] = false
			var jv = _jsonable(v)
			if not _deep_eq(jv, w["last"]):
				_events.append({"t": t, "event": watch_name, "value": jv})
				w["last"] = jv

	func _do_call(step: Dictionary) -> void:
		var node := _resolve_node(step)
		if node == null:
			return
		var method := str(step.get("method", ""))
		if not node.has_method(method):
			_events.append({"t": t, "event": "error", "detail": "no method '%s' on %s" % [method, node.name]})
			return
		var out = node.callv(method, Array(step.get("args", [])))
		_evals.append({"call": method, "value": _jsonable(out)})

	func _do_set(step: Dictionary) -> void:
		var node := _resolve_node(step)
		if node == null:
			return
		var prop := str(step.get("prop", ""))
		var value = step.get("value")
		var cur = node.get(prop)
		if value is Array:
			if typeof(cur) == TYPE_VECTOR2 and value.size() == 2:
				value = Vector2(value[0], value[1])
			elif typeof(cur) == TYPE_VECTOR3 and value.size() == 3:
				value = Vector3(value[0], value[1], value[2])
		node.set(prop, value)

	func _do_teleport(step: Dictionary) -> void:
		var node := _resolve_node(step) if step.has("node") else _player
		if node == null or not (node is Node2D or node is Node3D):
			_events.append({"t": t, "event": "error", "detail": "teleport: no player/node to move"})
			return
		if node is Node2D:
			node.global_position = Vector2(
				step.get("x", node.global_position.x),
				step.get("y", node.global_position.y))
		else:
			node.global_position = Vector3(
				step.get("x", node.global_position.x),
				step.get("y", node.global_position.y),
				step.get("z", node.global_position.z))
		if "velocity" in node:
			node.velocity = node.velocity * 0.0

	func _resolve_node(step: Dictionary) -> Node:
		var scene := get_tree().current_scene
		var path := str(step.get("node", ""))
		var node := scene.get_node_or_null(path) if not path.is_empty() else _player
		if node == null:
			_events.append({"t": t, "event": "error", "detail": "node not found: " + path})
		return node

	func _do_reset() -> void:
		var scene := get_tree().current_scene
		if scene == null:
			return
		var path := scene.scene_file_path
		# Take the old scene out of the tree before adding the fresh one, so
		# the new root keeps its real name (no @-rename) and the two instances
		# never coexist for a frame.
		get_tree().root.remove_child(scene)
		scene.queue_free()
		var fresh := (load(path) as PackedScene).instantiate()
		get_tree().root.add_child(fresh)
		get_tree().current_scene = fresh
		_player = null
		_cam = null
		for watch_name in _watches:
			_watches[watch_name]["last"] = "__unset__"
		_ensure_player()

	# ---- inputs ----

	func _release_all() -> void:
		for a in _held_actions:
			Input.action_release(a)
		for k in _held_keys:
			_send_key(k, false)
		_held_actions = []
		_held_keys = []

	func _send_key(key_name: String, pressed: bool) -> void:
		var ev := InputEventKey.new()
		ev.keycode = OS.find_keycode_from_string(key_name)
		ev.physical_keycode = ev.keycode
		ev.pressed = pressed
		Input.parse_input_event(ev)

	# ---- telemetry ----

	func _sample() -> Dictionary:
		var s := {"t": t}
		if is_instance_valid(_player):
			if _player is Node2D:
				s["x"] = snappedf(_player.global_position.x, 0.1)
				s["y"] = snappedf(_player.global_position.y, 0.1)
			elif _player is Node3D:
				s["x"] = snappedf(_player.global_position.x, 0.01)
				s["y"] = snappedf(_player.global_position.y, 0.01)
				s["z"] = snappedf(_player.global_position.z, 0.01)
			if _player is CharacterBody2D:
				s["vx"] = snappedf(_player.velocity.x, 0.1)
				s["vy"] = snappedf(_player.velocity.y, 0.1)
				s["floor"] = _player.is_on_floor()
			elif _player is CharacterBody3D:
				s["vel"] = _jsonable(_player.velocity)
				s["floor"] = _player.is_on_floor()
		for watch_name in _watches:
			var w: Dictionary = _watches[watch_name]
			if w["errored"]:
				continue
			if typeof(w["last"]) == TYPE_STRING and str(w["last"]) == "__unset__":
				continue
			s[watch_name] = w["last"]
		return s

	func _dump_tree(max_depth: int) -> String:
		var lines: Array = []
		var scene := get_tree().current_scene
		if scene != null:
			_dump_node(scene, 0, max_depth, lines)
		return "\n".join(lines)

	func _dump_node(node: Node, depth: int, max_depth: int, lines: Array) -> void:
		if lines.size() >= 300:
			return
		var line := "  ".repeat(depth) + str(node.name) + " (" + node.get_class() + ")"
		if node is Node2D:
			line += " @(%.0f, %.0f)" % [node.global_position.x, node.global_position.y]
		elif node is Node3D:
			line += " @(%.1f, %.1f, %.1f)" % [node.global_position.x, node.global_position.y, node.global_position.z]
		lines.append(line)
		if depth < max_depth:
			for child in node.get_children():
				_dump_node(child, depth + 1, max_depth, lines)

	func _shot(shot_name: String) -> void:
		if DisplayServer.get_name() == "headless":
			_events.append({"t": t, "event": "error", "detail": "screenshots need a window (running headless)"})
			return
		# macOS pauses rendering for occluded windows, which would freeze every
		# capture at the last drawn frame; force a fresh draw before grabbing.
		RenderingServer.force_draw(false)
		var path := shots_dir.path_join(shot_name.validate_filename() + ".png")
		get_viewport().get_texture().get_image().save_png(path)
		_shots.append(path)

	# ---- helpers ----

	func _jsonable(v):
		match typeof(v):
			TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
				return v
			TYPE_VECTOR2, TYPE_VECTOR2I:
				return [v.x, v.y]
			TYPE_VECTOR3, TYPE_VECTOR3I:
				return [v.x, v.y, v.z]
			TYPE_ARRAY:
				var out := []
				for item in v:
					out.append(_jsonable(item))
				return out
			TYPE_DICTIONARY:
				var outd := {}
				for k in v:
					outd[str(k)] = _jsonable(v[k])
				return outd
			TYPE_OBJECT:
				if v is Node:
					return str(v.name)
				return str(v)
			_:
				return str(v)

	func _deep_eq(a, b) -> bool:
		return typeof(a) == typeof(b) and a == b

	func _as_array(v) -> Array:
		return [v] if v is String else Array(v)
