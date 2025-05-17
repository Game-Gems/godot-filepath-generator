@tool
extends EditorPlugin

## This is how often the project is scanned for changes (in seconds)
const GENERATION_FREQUENCY := 5.0

## The addons directory is excluded by default
const ADDONS_PATH := "res://addons"

## The plugin name is used to create the output directory
const PLUGIN_NAME := "filepath_generator"

## The class name that will be generated
const GENERATED_CLASS_NAME := "ProjectFiles"

## Print debug messages
const DEBUG := false

## Paths that should be excluded from generation
const EXCLUDED_PATHS: Array[String] = [
	ADDONS_PATH,
	"res://export",
	"res://temp"
]

## Generated classnames to file extensions
const FILETYPES_TO_EXTENSIONS: Dictionary[String, Array] = {
	"Scripts": ["gd"],
	"Scenes": ["tscn", "scn"],
	"Resources": ["tres", "res"],
	"Images": ["png", "jpg", "jpeg", "gif", "bmp"],
	"Audio": ["wav", "ogg", "mp3"],
	"Fonts": ["ttf", "otf"],
	"Shaders": ["gdshader"],
}

var extensions_to_filetypes: Dictionary[String, String]
var illegal_symbols_regex: RegEx
var previous_filetypes_to_filepaths: Dictionary[String, PackedStringArray]
var persisted_actions: PackedStringArray
var persisted_groups: PackedStringArray

var mutex: Mutex
var config_modified_time: int = 0

func _enter_tree() -> void:
	if not Engine.is_editor_hint(): return

	mutex = Mutex.new()
	illegal_symbols_regex = RegEx.create_from_string("[^\\p{L}\\p{N}_]")

	extensions_to_filetypes = {}
	for filetype in FILETYPES_TO_EXTENSIONS:
		for extension in FILETYPES_TO_EXTENSIONS[filetype]:
			extensions_to_filetypes[extension] = filetype

	var timer := Timer.new()
	timer.name = PLUGIN_NAME.to_pascal_case() + "Timer"
	timer.wait_time = GENERATION_FREQUENCY
	timer.one_shot = false
	timer.autostart = true
	timer.timeout.connect(
		WorkerThreadPool.add_task.bind(generate_filepath_class, false, "Generating filepaths")
	)
	add_child(timer)

	on_settings_changed()
	project_settings_changed.connect(on_settings_changed)

func on_settings_changed():
	var project_settings := ConfigFile.new()
	if project_settings.load("res://project.godot"):
		push_warning("Couldn't load project.godot")
		return

	save_input_actions_class(project_settings)
	save_groups_class(project_settings)
	save_layers_enum(project_settings, "Avoidance", "avoidance")
	save_layers_enum(project_settings, "Physics2D", "2d_physics")
	save_layers_enum(project_settings, "Render2D", "2d_render")
	save_layers_enum(project_settings, "Navigation2D", "2d_navigation")
	save_layers_enum(project_settings, "Physics3D", "3d_physics")
	save_layers_enum(project_settings, "Render3D", "3d_render")
	save_layers_enum(project_settings, "Navigation3D", "3d_navigation")


func save_input_actions_class(project_settings: ConfigFile):
	var custom_actions: PackedStringArray = project_settings.get_section_keys("input") if project_settings.has_section("input") else []
	if persisted_actions == custom_actions:
		return

	var all_actions := PackedStringArray(custom_actions)
	for action in InputMap.get_actions():
		all_actions.append(action)

	generate_class("InputActions", all_actions)
	persisted_actions = custom_actions

func save_groups_class(project_settings: ConfigFile):
	var groups: PackedStringArray = project_settings.get_section_keys("global_group") if project_settings.has_section("global_group") else []
	if persisted_groups == groups:
		return

	generate_class("Groups", groups)

	persisted_groups = groups

func save_layers_enum(project_settings: ConfigFile, classname: String, layer_prefix: String):
	var layer_names: PackedStringArray = project_settings.get_section_keys("layer_names") if project_settings.has_section("layer_names") else []

	var found := false
	for layer in layer_names: if layer.begins_with(layer_prefix):
		found = true
	if not found: return

	var output_path = ADDONS_PATH.path_join(PLUGIN_NAME).path_join(classname.to_snake_case()) + ".gd"

	var generated_file := FileAccess.open(output_path, FileAccess.WRITE)
	generated_file.store_line("class_name " + classname)

	generated_file.store_line("")
	generated_file.store_line("enum Layer {")

	var number_offset := (layer_prefix + "/layer_").length()
	for layer in layer_names: if layer.begins_with(layer_prefix):
		var name: String = project_settings.get_value("layer_names", layer).to_upper()
		var number: int = int(layer.substr(number_offset))
		generated_file.store_line("\t%s = %d," % [name, number])

	generated_file.store_line("}")
	generated_file.close()


func debug(message: String):
	if DEBUG: print_debug(Time.get_time_string_from_system(), " [", PLUGIN_NAME, "] ", message)

func generate_class(name: String, values: Array[StringName], derive_const_name: Callable = func(value): return value):
	var file_name := name.to_snake_case().to_lower() + ".gd"
	debug("Generating %s" % file_name)

	var path := ADDONS_PATH.path_join(PLUGIN_NAME).path_join(file_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_warning("Couldn't open file %s: %s" % [path, FileAccess.get_open_error()])
		return

	file.store_line("class_name " + name)
	file.store_line("")
	for value in values:
		var const_name = derive_const_name.call(value.to_upper().strip_edges())
		const_name = illegal_symbols_regex.sub(const_name, "_", true)
		file.store_line("const %s = &\"%s\"" % [const_name, value])
	file.close()

func generate_filepath_class() -> void:
	if not mutex.try_lock(): return
	var walking_started := Time.get_ticks_usec()

	var filetypes_to_filepaths := walk("res://")
	if previous_filetypes_to_filepaths == filetypes_to_filepaths:
		return

	debug("Generating " + GENERATED_CLASS_NAME + " class...")
	var output_path = ADDONS_PATH.path_join(PLUGIN_NAME).path_join(GENERATED_CLASS_NAME.to_snake_case()) + ".gd"

	var generated_file := FileAccess.open(output_path, FileAccess.WRITE)
	generated_file.store_line("class_name " + GENERATED_CLASS_NAME)
	for filetype in filetypes_to_filepaths:
		write_section(generated_file, filetype, filetypes_to_filepaths[filetype])
	generated_file.close()

	debug("Finished in %dms" % ((Time.get_ticks_usec() - walking_started) / 1000))
	previous_filetypes_to_filepaths = filetypes_to_filepaths
	mutex.unlock()

func write_section(generated_file: FileAccess, classname: String, filepaths: PackedStringArray) -> void:
	if filepaths.is_empty(): return

	var sorted_filepaths := Array(filepaths)
	sorted_filepaths.sort_custom(func(a: String, b: String) -> bool:
		return a.get_file().to_lower() < b.get_file().to_lower()
	)

	generated_file.store_line("\nclass %s:" % classname)
	for filepath: String in sorted_filepaths:
		var constant_name := filepath.get_file().get_basename().to_snake_case().to_upper()
		constant_name = illegal_symbols_regex.sub(constant_name, "_", true)
		generated_file.store_line("\tconst %s = \"%s\"" % [constant_name, filepath])

func walk(path: String) -> Dictionary[String, PackedStringArray]:
	var filetypes_to_filepaths: Dictionary[String, PackedStringArray] = {}
	for filetype in FILETYPES_TO_EXTENSIONS:
		filetypes_to_filepaths[filetype] = PackedStringArray()

	var walker := DirAccess.open(path)
	_walk(walker, filetypes_to_filepaths)
	return filetypes_to_filepaths

func _walk(walker: DirAccess, collected_paths: Dictionary[String, PackedStringArray]) -> void:
	walker.list_dir_begin()

	var current_dir := walker.get_current_dir()
	for file in walker.get_files():
		var file_path := current_dir.path_join(file)
		if file_path in EXCLUDED_PATHS: continue

		var extension := file.get_extension()
		if extension in extensions_to_filetypes:
			collected_paths[extensions_to_filetypes[extension]].append(file_path)

	for dir in walker.get_directories():
		var dir_path := current_dir.path_join(dir)
		if dir_path in EXCLUDED_PATHS: continue

		walker.change_dir(dir_path)
		_walk(walker, collected_paths)

	walker.list_dir_end()
