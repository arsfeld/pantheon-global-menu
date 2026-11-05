#!/bin/sh
# Turns a directory of .debs into a signed apt repository for GitHub Pages:
#
#   pool/main/p/pantheon-global-menu/*.deb
#   dists/circe/{Release,InRelease,Release.gpg}
#   dists/circe/main/binary-amd64/Packages{,.gz}
#   pantheon-global-menu.asc, index.html
#
# The suite is circe, elementary OS 8's codename, not noble: the package is
# built against elementary's Gala and Wingpanel, not Ubuntu's.
#
# Signs with the secret key matching pantheon-global-menu.asc next to this
# script, which must already be in gpg's keyring ($GNUPGHOME). Signing fails
# if the keyring holds some other key, so a rotated secret that was not also
# published here cannot ship.
#
# Needs apt-ftparchive (apt-utils) and gpg.
set -eu

debs=$(realpath "${1:?usage: build-repo.sh DEBDIR OUTDIR}")
out=$(realpath -m "${2:?usage: build-repo.sh DEBDIR OUTDIR}")
here=$(realpath "$(dirname "$0")")
suite=circe
url=https://arsfeld.github.io/pantheon-global-menu

pubkey="$here/pantheon-global-menu.asc"
fpr=$(gpg --batch --with-colons --show-keys "$pubkey" | awk -F: '/^fpr/ { print $10; exit }')

rm -rf "$out"
mkdir -p "$out/pool/main/p/pantheon-global-menu" "$out/dists/$suite/main/binary-amd64"
cp "$debs"/*.deb "$out/pool/main/p/pantheon-global-menu/"
cp "$pubkey" "$out/"

cd "$out"
apt-ftparchive packages pool >"dists/$suite/main/binary-amd64/Packages"
gzip -9nk "dists/$suite/main/binary-amd64/Packages"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=pantheon-global-menu \
    -o APT::FTPArchive::Release::Label=pantheon-global-menu \
    -o APT::FTPArchive::Release::Suite=$suite \
    -o APT::FTPArchive::Release::Codename=$suite \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Description=Global menu for Pantheon on elementary OS 8" \
    release "dists/$suite" >Release.tmp
mv Release.tmp "dists/$suite/Release"
gpg --batch --yes --local-user "$fpr!" --clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"
gpg --batch --yes --local-user "$fpr!" --armor --detach-sign -o "dists/$suite/Release.gpg" "dists/$suite/Release"

version=$(sed -n 's/^Version: //p' "dists/$suite/main/binary-amd64/Packages" | head -n1)
cat >index.html <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pantheon Global Menu apt repository</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 16px; color: #222; background: #fff; }
  pre { background: #f2f2f2; padding: 1rem; overflow-x: auto; }
  code { font-size: 0.9em; }
  @media (prefers-color-scheme: dark) { body { color: #ddd; background: #1b1b1b; } pre { background: #2a2a2a; } }
</style>
</head>
<body>
<h1>Pantheon Global Menu</h1>
<p>An apt repository for <a href="https://github.com/arsfeld/pantheon-global-menu/tree/main/pantheon">pantheon-global-menu</a>,
built for elementary OS 8. Current version: <code>$version</code>.</p>
<pre><code>sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/pantheon-global-menu.asc $url/pantheon-global-menu.asc
echo "deb [signed-by=/etc/apt/keyrings/pantheon-global-menu.asc] $url $suite main" \\
  | sudo tee /etc/apt/sources.list.d/pantheon-global-menu.list
sudo apt update
sudo apt install pantheon-global-menu</code></pre>
<p>Then log out and back in: Gala loads plugins only at startup.</p>
<p>Signing key: <a href="pantheon-global-menu.asc">pantheon-global-menu.asc</a>, fingerprint <code>$fpr</code>.</p>
</body>
</html>
EOF
