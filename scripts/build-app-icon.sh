#!/bin/sh
set -eu

source_path=$1
target_path=$2

mkdir -p "$(dirname "$target_path")"
staging_dir=$(mktemp -d "$(dirname "$target_path")/app-icon.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
trap 'exit 1' HUP INT TERM
iconset_dir="$staging_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"

# Include standard and Retina representations from 16 to 1024 pixels.
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$source_path" \
		--out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
	retina_size=$((size * 2))
	sips -z "$retina_size" "$retina_size" "$source_path" \
		--out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$staging_dir/AppIcon.icns"
mv -f "$staging_dir/AppIcon.icns" "$target_path"
