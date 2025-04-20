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

var mutex: Mutex

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

func generate_filepath_class() -> void:
	if not mutex.try_lock(): return
	var walking_started := Time.get_ticks_usec()

	_generate()

	if DEBUG: print(Time.get_time_string_from_system(), " [", PLUGIN_NAME, "] ", "Finished in ", (Time.get_ticks_usec() - walking_started) / 1000, "ms")
	mutex.unlock()

func _generate():
	if DEBUG: print(Time.get_time_string_from_system(), " [", PLUGIN_NAME, "] ", "Collecting filepaths...")

	var filetypes_to_filepaths := walk("res://")

	if previous_filetypes_to_filepaths == filetypes_to_filepaths:
		if DEBUG: print(Time.get_time_string_from_system(), " [", PLUGIN_NAME, "] ", "No changes detected")
		return
	previous_filetypes_to_filepaths = filetypes_to_filepaths

	if DEBUG: print(Time.get_time_string_from_system(), " [", PLUGIN_NAME, "] ", "Generating ", GENERATED_CLASS_NAME, " class...")
	var output_path = ADDONS_PATH.path_join(PLUGIN_NAME).path_join(GENERATED_CLASS_NAME.to_snake_case()) + ".gd"

	var generated_file := FileAccess.open(output_path, FileAccess.WRITE)
	generated_file.store_line("class_name " + GENERATED_CLASS_NAME)
	for filetype in filetypes_to_filepaths:
		write_section(generated_file, filetype, filetypes_to_filepaths[filetype])
	generated_file.close()

func write_section(generated_file: FileAccess, filetype: String, filepaths: PackedStringArray) -> void:
	if filepaths.is_empty(): return

	var sorted_filepaths := Array(filepaths)
	sorted_filepaths.sort_custom(func(a: String, b: String) -> bool:
		return a.get_file().to_lower() < b.get_file().to_lower()
	)

	generated_file.store_line("\nclass %s:" % filetype)
	for filepath: String in sorted_filepaths:
		var constant_name := filepath.get_file().get_basename().to_snake_case().to_upper()
		constant_name = illegal_symbols_regex.sub(constant_name, "_", true)
		generated_file.store_line("\tconst %s = '%s'" % [constant_name, filepath])

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
