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
