// vfmt off
module main

// ui2 sets window titles only through its native macOS and Windows backends.
// Linux and custom-rendered builds draw through gg, which owns the window.
$if (macos || windows) && !ui2_custom_rendering ? {
	import ui2

	fn set_app_window_title(title string) {
		ui2.set_window_title(title)
	}
} $else {
	import gg

	fn set_app_window_title(title string) {
		gg.set_window_title(title)
	}
}
