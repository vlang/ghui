module main

#flag -framework Cocoa
#include "@VMODROOT/packaging/macos/url-events.m"

fn C.ghui_install_url_handler(fn (&char))
fn C.ghui_open_browser(&char) bool

fn receive_macos_url(target &char) {
	handle_open_url(unsafe { cstring_to_vstring(target) }.clone())
}

fn install_macos_url_handler() {
	C.ghui_install_url_handler(receive_macos_url)
}
