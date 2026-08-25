# shellcheck shell=bash
#
# Common helpers for the container-stack-tests autopkgtest suite.
#
# --- strict mode + tracing -------------------------------------------------
set_strict() { set -Eeuo pipefail; }
set_x()      { set -x; }

# --- deferred traps + scratch dir ------------------------------------------
exitTraps=( 'true' )
doExit() {
	for exitTrap in "${exitTraps[@]}"; do
		eval "$exitTrap" || true
	done
}
trap 'doExit' EXIT
defer() {
	exitTraps=( "$@" "${exitTraps[@]}" )
}

tempDir="$(mktemp -d)"
defer "rm -rf '$tempDir'"

# --- helpers ----------------------------------------------------------------

# unique_name [prefix] — print a collision-free name for a container/test.
unique_name() {
	printf '%s-%s-%s' "${1:-test}" "$$" "$RANDOM"
}

# write_proxy_dropin <unit> — write a systemd drop-in exporting the proxy
# environment to <unit> (e.g. containerd.service, docker.service). No-op if no
# proxy variables are set in the environment. Writes under /run so it is
# discarded on reboot and never clobbers packaged config.
write_proxy_dropin() {
	local unit="$1"
	local env_lines=()
	[ -n "${http_proxy:-}"  ] && env_lines+=("http_proxy=${http_proxy}"  "HTTP_PROXY=${http_proxy}")
	[ -n "${https_proxy:-}" ] && env_lines+=("https_proxy=${https_proxy}" "HTTPS_PROXY=${https_proxy}")
	[ -n "${no_proxy:-}"    ] && env_lines+=("no_proxy=${no_proxy}"      "NO_PROXY=${no_proxy}")
	[ "${#env_lines[@]}" -gt 0 ] || return 0

	local dir="/run/systemd/system/${unit}.d"
	mkdir -p "$dir"
	{
		echo "[Service]"
		printf 'Environment=%s\n' "${env_lines[@]}"
	} > "$dir/proxy.conf"
	systemctl daemon-reload
}

# curl_retry <url> — curl with a few retries/backoff, for smoke tests hitting a
# freshly-started local service. Avoids a single racing connection failing the
# test before the service is ready.
curl_retry() {
  local url="$1" i
  for i in 1 2 3 4 5; do
    if curl --silent --fail "$url"; then
      return 0
    fi
    sleep "$i"
  done
  return 1
}

# check_journal <exit_code> [unit ...] — assert nothing at err severity or worse
# was logged to the journal for the given units (default: docker containerd).
check_journal() {
	local code="$1"; shift
	local units=("$@")
	[ "${#units[@]}" -gt 0 ] || units=(docker containerd)

	local args=()
	local u
	for u in "${units[@]}"; do
		args+=(-u "$u")
	done

	# -p err = priority err and above (err, crit, alert, emerg)
	local errors
	errors="$(journalctl --no-pager -q -p err "${args[@]}" 2>/dev/null || true)"

	if [ -n "$errors" ]; then
		echo "check_journal: errors logged for: ${units[*]}" >&2
		echo "$errors" >&2
		exit "$code"
	fi
}

