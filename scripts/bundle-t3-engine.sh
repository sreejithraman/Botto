#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/scripts/t3-engine-pin.json"
cache="$root/.artifacts/t3-engine"

die() { printf 'T3 engine: %s\n' "$*" >&2; exit 1; }
read_key() { /usr/bin/plutil -extract "$1" raw -o - "$2"; }
download() { /usr/bin/curl --fail --silent --show-error --location --retry 2 "$1" -o "$2"; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

usage() { die "Usage: $0 [--pin vVERSION | --stage vVERSION | --embed RESOURCES_DIRECTORY]"; }
case "${1:-}" in
    "")              [[ $# == 0 ]] || usage ;;
    --pin|--stage)   [[ $# == 2 && $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || usage ;;
    --embed)         [[ $# == 2 && -n $2 ]] || usage ;;
    *)               usage ;;
esac

mkdir -p "$cache"
scratch="$(mktemp -d "$cache/.stage.XXXXXX")"
embed_scratch=""
cleanup() {
    rm -rf -- "$scratch"
    if [[ -n "$embed_scratch" ]]; then rm -rf -- "$embed_scratch"; fi
}
trap cleanup EXIT

input="$scratch/pin.json"
cp "$pin" "$input"
repository="$(read_key repository "$input")"
[[ "$repository" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "Expected a GitHub repository URL in $pin"
raw="https://raw.githubusercontent.com/${repository#https://github.com/}"

if [[ "${1:-}" == --pin || "${1:-}" == --stage ]]; then
    tag="$2"
    version="${tag#v}"
    ref="refs/tags/$tag"
    refs="$(/usr/bin/git ls-remote --exit-code "$repository" "$ref" "$ref^{}")" ||
        die "Upstream tag $tag is unavailable"
    commit="$(printf '%s\n' "$refs" | /usr/bin/awk '
        /\^\{\}$/ { peeled = $1 }
        { ref = $1 }
        END { print peeled ? peeled : ref }
    ')"
    download "$raw/$commit/package.json" "$scratch/package.json"
    runtime_version="$(read_key engines.node "$scratch/package.json")"
    asset="t3-$version-darwin-arm64.tar.gz"
    download "$repository/releases/download/$tag/SHA256SUMS" "$scratch/SHA256SUMS"
    digest="$(/usr/bin/awk -v asset="$asset" '$2 == asset {print $1}' "$scratch/SHA256SUMS")"
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || die "$tag has no checksummed $asset release asset"
    license="$(read_key licensePath "$input")"
    cat > "$input" <<EOF
{
  "repository": "$repository",
  "ref": "$ref",
  "commit": "$commit",
  "version": "$version",
  "runtime": {
    "name": "Node.js",
    "version": "$runtime_version"
  },
  "licensePath": "$license",
  "asset": {
    "name": "$asset",
    "sha256": "$digest"
  }
}
EOF
fi

is_staged() {
    [[ -x "$1/t3" && -f "$1/LICENSE" && -f "$1/NODE-LICENSE" ]] &&
        cmp -s "$input" "$1/pin.json"
}

key="$(sha256 "$input")"
stage="$cache/$key"
if ! is_staged "$stage"; then
    [[ ! -e "$stage" ]] || die "Incomplete cache entry at $stage. Remove it and retry."
    tag="$(read_key ref "$input")"
    tag="${tag#refs/tags/}"
    commit="$(read_key commit "$input")"
    asset="$(read_key asset.name "$input")"
    digest="$(read_key asset.sha256 "$input")"
    license="$(read_key licensePath "$input")"
    runtime_version="$(read_key runtime.version "$input")"
    download "$repository/releases/download/$tag/$asset" "$scratch/$asset"
    [[ "$(sha256 "$scratch/$asset")" == "$digest" ]] || die "SHA-256 mismatch for $asset"
    /usr/bin/tar -xzf "$scratch/$asset" -C "$scratch"
    payload="$scratch/${asset%.tar.gz}"
    [[ -x "$payload/t3" ]] || die "$asset does not contain the expected t3 executable"
    download "$raw/$commit/$license" "$payload/LICENSE"
    download "https://raw.githubusercontent.com/nodejs/node/v$runtime_version/LICENSE" "$payload/NODE-LICENSE"
    cp "$input" "$payload/pin.json"

    mv "$payload" "$scratch/$key"
    # Concurrent builds may have published the same complete, immutable entry.
    mv "$scratch/$key" "$cache" 2>/dev/null || is_staged "$stage" || die "Unable to publish $stage"
fi

case "${1:-}" in
    --pin)
        if ! cmp -s "$input" "$pin"; then mv "$input" "$pin"; fi
        printf 'Pinned upstream T3 %s (%s)\n' "$version" "$commit"
        ;;
    --embed)
        resources="$2"
        destination="$resources/T3Engine"
        if ! is_staged "$destination"; then
            mkdir -p "$resources"
            embed_scratch="$(mktemp -d "$resources/.t3-engine.XXXXXX")"
            /usr/bin/ditto --norsrc "$stage" "$embed_scratch/T3Engine"
            rm -rf -- "$destination"
            mv "$embed_scratch/T3Engine" "$resources"
        fi
        stage="$destination"
        ;;
esac
printf 'T3 engine staged at %s\n' "$stage"
