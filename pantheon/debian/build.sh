#!/bin/sh
# Builds the pantheon-global-menu .deb. CI runs this inside
# ghcr.io/elementary/docker:circe-stable (elementary OS 8); to do the same
# locally, from the repository root:
#
#   docker run --rm -v "$PWD:/src" -w /src ghcr.io/elementary/docker:circe-stable \
#       sh pantheon/debian/build.sh out
#
# The meson project in pantheon/ installs the shortcut mappings from
# ../global-menu@unmade.space, and the repository root's debian/ is the Python
# daemon's, so the package is built from an assembled tree: pantheon/, the
# mappings, and this directory as debian/.
#
# The version is the meson project version plus the commit, e.g.
# 0.1.0+git20261105.124301.e149f74, so every commit sorts after the last.
# Set VERSION to override it. Run as root to have build dependencies installed.
set -eu

out=$(realpath -m "${1:?usage: build.sh OUTDIR}")
root=$(realpath "$(dirname "$0")/../..")

# The checkout may belong to another user (a bind mount, actions/checkout in a
# container), which git refuses to read without this.
g() { git -c safe.directory="$root" -C "$root" "$@"; }

base=$(sed -n "s/^project(.*, version: *'\([^']*\)'.*/\1/p" "$root/pantheon/meson.build")
[ -n "$base" ] || { echo "cannot read the version from pantheon/meson.build" >&2; exit 1; }
if [ -z "${VERSION:-}" ]; then
    stamp=$(TZ=UTC g log -1 --format=%cd --date=format-local:%Y%m%d.%H%M%S)
    sha=$(g rev-parse --short=7 HEAD)
    VERSION="$base+git$stamp.$sha"
fi
date=$(g log -1 --format=%cD 2>/dev/null || date -R)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree="$work/pantheon-global-menu-$VERSION"
mkdir -p "$tree/global-menu@unmade.space/shortcuts"
cp -r "$root/pantheon" "$tree/pantheon"
rm -rf "$tree/pantheon/debian"
cp -r "$root/global-menu@unmade.space/shortcuts/apps" "$tree/global-menu@unmade.space/shortcuts/apps"
cp -r "$root/pantheon/debian" "$tree/debian"
rm "$tree/debian/build.sh"

cat >"$tree/debian/changelog" <<EOF
pantheon-global-menu ($VERSION) circe; urgency=medium

  * Built from $(g rev-parse HEAD 2>/dev/null || echo "an unknown commit").

 -- Alexandre Rosenfeld <alex@rosenfeld.one>  $date
EOF

if [ "$(id -u)" = 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential debhelper dpkg-dev
    apt-get build-dep -y "$tree"
fi

(cd "$tree" && dpkg-buildpackage -b -us -uc)

mkdir -p "$out"
cp "$work"/*.deb "$out"/
ls -l "$out"
