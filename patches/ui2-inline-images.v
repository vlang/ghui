module ui2

import math

// Resolve images when their text area is displayed. The native cache loads
// remote images asynchronously and requests a refresh after decoding them.
pub fn inline_image_run(run TextRun, max_width f64, max_height f64) TextRun {
	$if macos {
		$if !ui2_custom_rendering ? {
			mut width := 0.0
			mut height := 0.0
			if C.ghui_inline_image_size(run.image_path.str, request_refresh, &width, &height) {
				scale := math.min(1, math.min(max_width / width, max_height / height))
				return TextRun{
					...run
					text:         '\uFFFC'
					style:        TextStyle{ ...run.style, underline: false }
					image_width:  width * scale
					image_height: height * scale
				}
			}
		}
	}
	return TextRun{ ...run, image_path: '' }
}
