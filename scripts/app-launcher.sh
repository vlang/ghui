#!/bin/sh
set -eu

# Finder does not inherit a terminal's Homebrew search path.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

executable_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ "$#" -eq 0 ]; then
	set -- "$(cat "$executable_dir/../Resources/default-repository")"
fi

exec "$executable_dir/ghui" "$@"
