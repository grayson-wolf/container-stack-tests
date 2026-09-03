#!/usr/bin/env bash

# All the supported Ubuntu versions.
tier_1_images=("stonking" "resolute" "noble" "jammy")

# We try not to test explicit pinned versions because they're susceptible to
# the sands of time.
#
# All of these images exist as of 2026-08-18
# If you update this list, please bump ^ this date and reconfirm :)
tier_2_images=(
  # --- Canonical-maintained (public.ecr.aws/ubuntu/*) ---
  "public.ecr.aws/ubuntu/ubuntu:latest"           # base, as a pulled image
  "public.ecr.aws/ubuntu/redis:latest"            # key-value store
  "public.ecr.aws/ubuntu/memcached:latest"        # cache
  "public.ecr.aws/ubuntu/postgres:latest"         # relational database
  "public.ecr.aws/ubuntu/mysql:latest"            # relational database
  "public.ecr.aws/ubuntu/cassandra:latest"        # wide-column store
  "public.ecr.aws/ubuntu/zookeeper:latest"        # coordination
  "public.ecr.aws/ubuntu/kafka:latest"            # message queue
  "public.ecr.aws/ubuntu/nginx:latest"            # web server / reverse proxy
  "public.ecr.aws/ubuntu/apache2:latest"          # web server
  "public.ecr.aws/ubuntu/prometheus:latest"       # metrics
  "public.ecr.aws/ubuntu/grafana:latest"          # dashboards
  "public.ecr.aws/ubuntu/dotnet-runtime:stable"   # .NET runtime
  # --- non-Canonical (Docker Hub library) ---
  "docker.io/library/hello-world:latest"          # canonical minimal smoke image
  "docker.io/library/busybox:latest"              # ubiquitous minimal userland
  "docker.io/library/alpine:latest"               # non-Ubuntu userland (musl)
)

# Cache directory for images
# we use this since some tests (most notably coherence_in_lxd) have problems trying
# to fetch the images from within a nested VM
image_cache_dir() {
  printf '%s\n' "${CST_IMAGE_CACHE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.image-cache}"
}

fetch_tier_1_tar() {
  local release="$1"
  local arch="$2"

  local image_url="https://cdimage.ubuntu.com/ubuntu-base/$release/daily/current/$release-base-$arch.tar.gz"
  local cache_dir
  cache_dir="$(image_cache_dir)"
  local cached="$cache_dir/tier1-$release-base-$arch.tar.gz"

  # try to grab the image from cache
  if [ -s "$cached" ]; then
    echo "fetch_tier_1_tar: $release $arch served from cache ($cached)"
    cp "$cached" image.tar.gz
    return 0
  fi

  # cache miss, actually get it
  mkdir -p "$cache_dir"
  if ! wget --continue --tries=5 --timeout=60 --retry-connrefused \
        "$image_url" -O "$cached.part"; then
    echo "fetch_tier_1_tar: fetch of $image_url failed" >&2
    rm -f "$cached.part"
    return 1
  fi
  mv "$cached.part" "$cached"
  cp "$cached" image.tar.gz
}

# smoke_base_image — fetch + docker-import the second Tier 1 image (the current
# stable series) as a local base, for smoke tests that just need *an* Ubuntu
# image without pulling from a registry. Prints the imported image ref.
smoke_base_image() {
  local release="${tier_1_images[1]}"   # second entry = latest stable
  local arch="${AUTOPKGTEST_TEST_ARCH:-$(dpkg --print-architecture)}"
  local ref="ubuntu-base:$release"

  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    (cd "$tempDir" && fetch_tier_1_tar "$release" "$arch")
    docker import "$tempDir/image.tar.gz" "$ref" >/dev/null
  fi
  printf '%s' "$ref"
}

# Tier 2 images are only ever pulled as OCI via the docker daemon.
# Returns:
#   0 image pulled and present in the local daemon store
#   1 pull failed after retries (you should skip this image)
fetch_tier_2_image() {
  local image="$1"
  local attempts=3
  local delay=2
  local i

  for i in $(seq 1 "$attempts"); do
    if docker pull "$image"; then
      return 0
    fi
    echo "fetch_tier_2_image: pull of $image failed (attempt $i/$attempts); retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done

  echo "fetch_tier_2_image: skipping $image after $attempts failed pulls (registry/network)" >&2
  return 1
}
