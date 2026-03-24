#!/usr/bin/env bash
set -Eeuo pipefail

source /mnt/data/k8s-node-upgrade.sh

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" name="$3"
  [[ "$expected" == "$actual" ]] || fail "$name: expected '$expected', got '$actual'"
  pass "$name"
}
assert_true() {
  local name="$1"
  shift
  "$@" || fail "$name"
  pass "$name"
}
assert_false() {
  local name="$1"
  shift
  if "$@"; then fail "$name"; fi
  pass "$name"
}

# Pure version helpers
assert_eq "1.35.3" "$(normalize_version v1.35.3)" "normalize_version strips v"
assert_eq "1.35" "$(version_major_minor 1.35.3)" "version_major_minor"
assert_eq "3" "$(version_patch 1.35.3)" "version_patch"
assert_eq "1.35" "$(bump_minor 1.34.6)" "bump_minor"
assert_true  "version_lt smaller<greater" version_lt 1.34.6 1.35.3
assert_false "version_lt equal versions" version_lt 1.35.3 1.35.3
assert_true  "version_eq equal versions" version_eq v1.35.3 1.35.3

# Drain args safety: no emptyDir deletion by default
NODE_NAME="node-1"
ALLOW_EMPTYDIR_LOSS="false"
assert_eq "node-1 --ignore-daemonsets --timeout=20m " "$(build_drain_args)" "drain args default"
ALLOW_EMPTYDIR_LOSS="true"
assert_eq "node-1 --ignore-daemonsets --timeout=20m --delete-emptydir-data " "$(build_drain_args)" "drain args with emptydir deletion"

# Auto role detection
ROLE="auto"
CONTROL_PLANE="false"
FIRST_CONTROL_PLANE="true"
detect_role
assert_eq "worker" "$ROLE" "auto role defaults to worker without api-server manifest"

# Repo switch rewrite test with mocked apt-get
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cat > "$TMPDIR_TEST/kubernetes.list" <<'REPO'
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /
REPO
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/apt-get"
OLD_PATH="$PATH"
export PATH="$TMPDIR_TEST/bin:$PATH"
PKG_FAMILY="apt"
PKG_REPO_FILE="$TMPDIR_TEST/kubernetes.list"
DRY_RUN="false"
FORCE_REPO_SWITCH="false"
ensure_pkgs_repo_minor "1.35"
assert_true "repo file switched to v1.35" grep -q 'v1.35/deb/' "$TMPDIR_TEST/kubernetes.list"
export PATH="$OLD_PATH"

printf 'All tests passed.\n'
