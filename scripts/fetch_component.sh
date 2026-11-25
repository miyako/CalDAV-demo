#!/usr/bin/env bash
# Stage the published CalDAV component into Components/ for a headless run.
#
# `tool4d` has no Dependency manager, so `Project/Sources/dependencies.json`
# alone is not enough: the unpacked `.4dbase` has to sit in the database folder,
# next to `Project/`. This script fetches the release asset for the exact tag
# the project pins and verifies the archive before extracting it.
#
#   scripts/fetch_component.sh [TAG]
#
# TAG defaults to the version pinned in Project/Sources/dependencies.json.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository="miyako/CalDAV"
name="CalDAV"

tag=${1:-}
if [ -z "$tag" ]; then
	tag=$(python3 - "$root" <<'PY'
import json, sys
path = sys.argv[1] + "/Project/Sources/dependencies.json"
data = json.load(open(path, encoding="utf-8"))
print(data["dependencies"]["CalDAV"]["version"])
PY
)
fi

destination="$root/Components"
package="$destination/$name.4dbase"
# The CLI binary keeps the repository's lowercase name even though the package
# is `CalDAV.4dbase`; macOS volumes are usually case-insensitive, so check the
# exact names rather than a mixed-case path that only resolves on APFS.
if [ -f "$package/$name.4DZ" ] && [ -x "$package/Resources/bin/macOS/caldav" ]; then
	echo "component already staged: $package ($tag)"
	exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

api="https://api.github.com/repos/$repository/releases/tags/$tag"
echo "resolving $api"
python3 - "$api" "$tmp" "$name" <<'PY'
import json, sys, urllib.request

api, tmp, name = sys.argv[1], sys.argv[2], sys.argv[3]
request = urllib.request.Request(api, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "CalDAV-demo-fetch"})
with urllib.request.urlopen(request, timeout=60) as response:
    release = json.load(response)
assets = [a for a in release.get("assets", []) if a.get("name") == f"{name}.zip"]
if not assets:
    raise SystemExit(f"release {release.get('tag_name')} has no {name}.zip asset")
asset = assets[0]
# The tag is pinned, but a release asset is still a network download: say
# exactly which bytes are expected before touching the project folder.
print(json.dumps({"url": asset["browser_download_url"], "size": asset["size"],
                  "digest": asset.get("digest")}))
with urllib.request.urlopen(asset["browser_download_url"], timeout=300) as response, \
        open(f"{tmp}/{name}.zip", "wb") as handle:
    while chunk := response.read(65536):
        handle.write(chunk)
PY

python3 - "$tmp/$name.zip" "$root/Components" "$name" <<'PY'
import hashlib, pathlib, sys, tarfile, zipfile

archive, destination, name = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
print("sha256", hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name)
staging = destination / f".{name}.staging"
if staging.exists():
    import shutil
    shutil.rmtree(staging)
staging.mkdir(parents=True)

root = staging.resolve()
with zipfile.ZipFile(archive) as bundle:
    for member in bundle.infolist():
        target = (staging / member.filename).resolve()
        # Never let an archive member escape the staging folder.
        if root not in target.parents and target != root:
            raise SystemExit(f"unsafe archive member: {member.filename}")
        if member.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with bundle.open(member) as source, open(target, "wb") as sink:
            sink.write(source.read())
        mode = (member.external_attr >> 16) & 0o777
        if mode:
            target.chmod(mode)

unpacked = staging / f"{name}.4dbase"
if not (unpacked / f"{name}.4DZ").is_file():
    raise SystemExit(f"archive does not contain {name}.4dbase/{name}.4DZ")
final = destination / f"{name}.4dbase"
if final.exists():
    import shutil
    shutil.rmtree(final)
unpacked.rename(final)
import shutil
shutil.rmtree(staging)
print("staged", final)
PY

ls -l "$package/Resources/bin/macOS/caldav" "$package/Resources/bin/Windows/caldav.exe"
echo "done: $package"
