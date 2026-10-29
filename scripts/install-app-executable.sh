#!/bin/sh
set -eu

source_path=$1
target_path=$2

# Rename a fresh inode over the old executable instead of changing signed pages
# in place. Leave the existing executable intact if copying or chmod fails.
staged_path=$(mktemp "${target_path}.XXXXXX")
trap 'rm -f "$staged_path"' EXIT
trap 'exit 1' HUP INT TERM
cp "$source_path" "$staged_path"
chmod 755 "$staged_path"
mv -f "$staged_path" "$target_path"
