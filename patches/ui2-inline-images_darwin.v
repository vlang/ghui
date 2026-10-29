module ui2

$if !ui2_custom_rendering ? {
	import macos

	#include "@VMODROOT/appkit/ghui_inline_images.h"

	fn C.ghui_inline_image_size(&char, fn (), &f64, &f64) bool
	fn C.ghui_text_view_add_image(voidptr, u64, &char, f64, f64)

	fn native_text_view_add_image(tv macos.Id, location u64, run TextRun) {
		if run.text == '\uFFFC' && run.image_path != '' {
			C.ghui_text_view_add_image(voidptr(tv), location, run.image_path.str,
				run.image_width, run.image_height)
		}
	}
}
