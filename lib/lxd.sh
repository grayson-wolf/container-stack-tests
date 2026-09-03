# shellcheck shell=bash
#
# LXD helpers for the container-stack-tests autopkgtest suite.
#
# lxd_install — install LXD via snap, or skip the test. snap store access and
# image availability are external to the package under test, so a failure here
# is exit 77 (skip), not a failure.
lxd_install() {
	if ! snap install lxd; then
		echo "lxd_install: snap install lxd failed (snap store / network); skipping" >&2
		exit 77
	fi
	# Wait for LXD to be ready; a timeout here is also infra, not our code.
	if ! lxd waitready --timeout 600; then
		echo "lxd_install: lxd waitready timed out; skipping" >&2
		exit 77
	fi
}

# lxd_set_proxy — forward any proxy environment to the LXD daemon so image
# downloads inside guests honour the testbed's proxy. No-op if none set.
lxd_set_proxy() {
	[ -n "${http_proxy:-}"  ] && lxc config set core.proxy_http "$http_proxy"
	[ -n "${https_proxy:-}" ] && lxc config set core.proxy_https "$https_proxy"
	[ -n "${no_proxy:-}"    ] && lxc config set core.proxy_ignore_hosts "$no_proxy"
	return 0
}

# make sure a guest OS image is present in the local lxd image store
# instead of relying on the lxd daemon, which is prone to randomly dying
# mid-download. we also use minimal where we can since it's ~50% smaller
lxd_fetch_guest_image() {
	local suite="$1" arch="$2"
	local alias="cst-guest-$suite-$arch"
	local cache_dir
	cache_dir="$(image_cache_dir)"
	local meta="$cache_dir/lxd-$suite-$arch-lxd.tar.xz"
	local rootfs="$cache_dir/lxd-$suite-$arch-root.tar.xz"
	local remote="ubuntu-daily:$suite/$arch"

	# Already in the LXD store (e.g. a previous run on a persistent testbed)?
	if lxc image info "$alias" >/dev/null 2>&1; then
		echo "lxd_fetch_guest_image: $alias already in image store" >&2
		printf '%s\n' "$alias"
		return 0
	fi

	# Try minimal if possible
	local base="https://cloud-images.ubuntu.com/minimal/daily/$suite/current"
	local name_prefix="$suite-minimal-cloudimg-$arch"
	if ! curl --silent --head --max-time 30 --fail \
		"$base/$name_prefix-root.tar.xz" >/dev/null 2>&1; then
		base="https://cloud-images.ubuntu.com/daily/server/$suite/current"
		name_prefix="$suite-server-cloudimg-$arch"
		echo "lxd_fetch_guest_image: no minimal image for $arch; using full server image" >&2
	fi

	# Cached pair? Import without touching the network.
	if [ -s "$meta" ] && [ -s "$rootfs" ]; then
		echo "lxd_fetch_guest_image: importing $alias from cache ($cache_dir)" >&2
		if lxc image import "$meta" "$rootfs" --alias "$alias" >/dev/null 2>&1; then
			printf '%s\n' "$alias"
			return 0
		fi
		echo "lxd_fetch_guest_image: cached pair failed to import; refetching" >&2
		lxc image delete "$alias" >/dev/null 2>&1 || true
	fi

	# Download the pair ourselves (resumable, bounded).
	mkdir -p "$cache_dir"
	local ok=true
	local kind part name dest
	for kind in lxd root; do
		name="$name_prefix-$kind.tar.xz"
		dest="$rootfs"
		[ "$kind" = lxd ] && dest="$meta"
		part="$dest.part"
		if ! wget --continue --tries=5 --timeout=60 --retry-connrefused \
			"$base/$name" -O "$part"; then
			echo "lxd_fetch_guest_image: fetch of $base/$name failed" >&2
			ok=false
			break
		fi
		mv "$part" "$dest"
	done
	if [ "$ok" = true ]; then
		if lxc image import "$meta" "$rootfs" --alias "$alias" >/dev/null 2>&1; then
			printf '%s\n' "$alias"
			return 0
		fi
		echo "lxd_fetch_guest_image: image import failed despite good download" >&2
		lxc image delete "$alias" >/dev/null 2>&1 || true
	fi

	# Last resort: let the daemon fetch from the remote.
	echo "lxd_fetch_guest_image: direct fetch failed; trying $remote" >&2
	rm -f "$meta" "$rootfs" "$meta.part" "$rootfs.part"
	printf '%s\n' "$remote"
}

# lxd_launch_nested <name> <image> — launch a nesting-capable LXD container
# suitable for running docker/containerd inside. Caller is responsible for
# defer'ing `lxc delete --force <name>`.
lxd_launch_nested() {
	local name="$1" image="$2"
	lxc launch "$image" "$name" \
		-c security.nesting=true \
		-c security.syscalls.intercept.mknod=true \
		-c security.syscalls.intercept.setxattr=true
}

# lxd_wait_network <name> — block until the guest is up and has a resolver, or fail.
lxd_wait_network() {
	local name="$1"
	# cloud-init finishing implies networkd/resolved have been configured.
	lxc exec "$name" -- cloud-init status --wait
}
