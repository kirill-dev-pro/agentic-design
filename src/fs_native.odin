#+build !js
package agentic_design

import "core:os"
import "core:path/filepath"

// The app's file system on the desktop. Every name is core:os's (or core:path/filepath's)
// own procedure or type, so the desktop build makes exactly the calls it always made;
// fs_js.odin gives a browser host the same names over the files the page hands over.

Fs_Error :: os.Error
Fs_File_Info :: os.File_Info

fs_read :: os.read_entire_file
fs_write :: os.write_entire_file
fs_mkdir_all :: os.make_directory_all
fs_exists :: os.exists
fs_is_dir :: os.is_dir
fs_copy :: os.copy_file
fs_rename :: os.rename
fs_remove :: os.remove
fs_stat :: os.stat
fs_list :: os.read_all_directory_by_path
fs_env :: os.get_env
fs_home :: os.user_home_dir
fs_temp_dir :: os.temp_directory
fs_executable :: os.get_executable_path

fs_dir :: os.dir
fs_base :: os.base
fs_path_is_abs :: filepath.is_abs
fs_path_join :: filepath.join
fs_path_rel :: filepath.rel

// The command line (none in a browser).
fs_args :: proc() -> []string {
	return os.args
}
