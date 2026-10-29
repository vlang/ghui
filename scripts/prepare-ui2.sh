#!/bin/sh
set -eu

source_dir=$1
build_dir=$2
patch_dir=$(dirname "$0")/../patches

if [ ! -f "$source_dir/v.mod" ]; then
	printf '%s\n' "ui2 not found at $source_dir; install ui2 or set UI2_SOURCE=/path/to/ui2." >&2
	exit 1
fi

# Keep the compatibility fix local to this app, without modifying installed
# modules. Copy only the module's sources and assets, excluding its git tree.
mkdir -p "$build_dir"
for entry in ui appkit uikit windows linux assets v.mod LICENSE; do
	rm -rf "$build_dir/$entry"
done
if git -C "$source_dir" ls-files --error-unmatch v.mod >/dev/null 2>&1; then
	# Match V's module loading: scratch files in a checkout are not sources.
	git -C "$source_dir" ls-files ui appkit uikit windows linux assets v.mod LICENSE > "$build_dir/sources.list"
	tar -C "$source_dir" -cf "$build_dir/sources.tar" -T "$build_dir/sources.list"
	tar -C "$build_dir" -xf "$build_dir/sources.tar"
	rm "$build_dir/sources.tar" "$build_dir/sources.list"
else
	for entry in ui appkit uikit windows linux assets v.mod LICENSE; do
		if [ -e "$source_dir/$entry" ]; then
			cp -R "$source_dir/$entry" "$build_dir/$entry"
		fi
	done
fi

for patch_file in "$patch_dir/ui2-rich-text.patch" "$patch_dir/ui2-inline-images.patch" "$patch_dir/ui2-pointer-cast.patch"; do
	if patch --dry-run -f -s -d "$build_dir" -p1 < "$patch_file" >/dev/null 2>&1; then
		patch -f -s -d "$build_dir" -p1 < "$patch_file"
	elif patch --dry-run -R -f -s -d "$build_dir" -p1 < "$patch_file" >/dev/null 2>&1; then
		# Also accept ui2 versions that already contain these fixes.
		:
	else
		printf '%s\n' "The ui2 compatibility patch $(basename "$patch_file") needs updating for this ui2 version." >&2
		exit 1
	fi
done

cp "$patch_dir/ui2-inline-images.v" "$build_dir/ui/ghui_inline_images.v"
cp "$patch_dir/ui2-inline-images_darwin.v" "$build_dir/appkit/ghui_inline_images_darwin.v"
cp "$patch_dir/ui2-inline-images.h" "$build_dir/appkit/ghui_inline_images.h"
