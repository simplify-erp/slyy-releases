#!/bin/sh
# slyy CLI installer (SPEC-007). One command, Linux and macOS, arm64 + amd64:
#
#   curl -fsSL https://raw.githubusercontent.com/simplify-erp/slyy-releases/main/install.sh | sh
#
# Installs the newest slyy CLI release from github.com/simplify-erp/slyy-releases
# (tags slyy-cli-v*), verified against the release's SHA256SUMS, to
#   - $SLYY_INSTALL_DIR if set, else
#   - /usr/local/bin when run as root, else
#   - ~/.local/bin (added to PATH in ~/.profile, ~/.bashrc, ~/.zshrc, once).
# Later updates: `slyy update`.
#
# Environment (all optional):
#   SLYY_VERSION       install this version (e.g. 0.2.0) instead of the newest
#   SLYY_INSTALL_DIR   target directory
#   SLYY_RELEASES_API  release feed API base (mirrors, tests; https or loopback)
#   SLYY_NO_MODIFY_PATH=1  do not touch shell profiles
#
# Security: HTTPS only, checksum verified before anything is installed, the
# binary must run and report the expected version, no sudo, nothing else on
# the system is changed. Source: slyy-go scripts/install.sh.
set -eu

API="${SLYY_RELEASES_API:-https://api.github.com/repos/simplify-erp/slyy-releases}"
TAG_PREFIX="slyy-cli-v"

say() { printf 'slyy-install: %s\n' "$*"; }
die() { printf 'slyy-install: error: %s\n' "$*" >&2; exit 1; }

# Wrapped in main so a truncated download (curl | sh) never runs half a script.
main() {
	# curl protocols: https only (also on redirects); plain http only for a loopback feed (tests)
	case "$API" in
	https://*) proto='=https' ;;
	http://127.0.0.1:* | http://10.0.99.1:* | http://localhost:*) proto='=https,http' ;;
	*) die "SLYY_RELEASES_API must be https: $API" ;;
	esac
	fetch() { curl -fsSL --proto "$proto" --proto-redir "$proto" "$@"; }
	command -v curl >/dev/null 2>&1 || die "curl is required"
	command -v tar >/dev/null 2>&1 || die "tar is required"
	if command -v sha256sum >/dev/null 2>&1; then
		sha() { sha256sum "$1" | cut -d' ' -f1; }
	elif command -v shasum >/dev/null 2>&1; then
		sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
	else
		die "sha256sum or shasum is required"
	fi

	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=darwin ;;
	*) die "unsupported OS $(uname -s) (Linux and macOS only)" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) die "unsupported CPU $(uname -m) (amd64 and arm64 only)" ;;
	esac

	# Newest release: the highest slyy-cli-vX.Y.Z tag (numeric sort; no jq needed).
	if [ -n "${SLYY_VERSION:-}" ]; then
		ver="${SLYY_VERSION#v}"
	else
		ver=$(fetch "$API/releases?per_page=100" |
			grep -o "\"tag_name\": *\"${TAG_PREFIX}[0-9]*\.[0-9]*\.[0-9]*\"" |
			sed "s/.*${TAG_PREFIX}//; s/\"//g" |
			sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1) || true
		[ -n "$ver" ] || die "could not find a slyy CLI release (network, or GitHub API rate limit)"
	fi
	case "$ver" in
	*[!0-9.]* | "") die "invalid version '$ver'" ;;
	esac

	file="slyy-${ver}-${os}_${arch}.tar.gz"
	case "$API" in
	https://api.github.com/repos/*) base="https://github.com/${API#https://api.github.com/repos/}/releases/download" ;;
	*) base="${API%/repos/*}/download" ;; # mirror / test feed layout
	esac
	url="$base/${TAG_PREFIX}${ver}"

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM
	say "downloading slyy $ver for $os/$arch"
	fetch -o "$tmp/$file" "$url/$file" || die "download failed: $url/$file"
	fetch -o "$tmp/SHA256SUMS" "$url/SHA256SUMS" || die "download failed: $url/SHA256SUMS"

	want=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
	[ -n "$want" ] || die "SHA256SUMS lists no $file"
	got=$(sha "$tmp/$file")
	[ "$got" = "$want" ] || die "checksum mismatch for $file (got $got, want $want): not installed"

	members=$(tar -tzf "$tmp/$file") || die "corrupt archive"
	[ "$members" = "slyy" ] || die "unexpected archive content: $members"
	tar -xzf "$tmp/$file" -C "$tmp" slyy
	chmod 700 "$tmp/slyy"
	reported=$("$tmp/slyy" --version 2>/dev/null | awk '{print $1}') || true
	[ "$reported" = "$ver" ] || die "downloaded binary reports '$reported', expected $ver"

	if [ -n "${SLYY_INSTALL_DIR:-}" ]; then
		dir="$SLYY_INSTALL_DIR"
	elif [ "$(id -u)" = 0 ]; then
		dir=/usr/local/bin
	else
		dir="$HOME/.local/bin"
	fi
	mkdir -p "$dir" || die "cannot create $dir"
	mode=700
	[ "$dir" = /usr/local/bin ] && mode=755
	# Same-directory temp + rename: atomic, new inode (macOS code signing).
	cp "$tmp/slyy" "$dir/.slyy.new" || die "cannot write to $dir"
	chmod "$mode" "$dir/.slyy.new"
	mv -f "$dir/.slyy.new" "$dir/slyy"
	say "installed $dir/slyy ($ver)"

	on_path=no
	case ":$PATH:" in *":$dir:"*) on_path=yes ;; esac
	if [ "$on_path" = no ] && [ "$dir" = "$HOME/.local/bin" ] && [ "${SLYY_NO_MODIFY_PATH:-}" != 1 ]; then
		line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac # slyy'
		touched=""
		for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
			[ "$rc" = "$HOME/.profile" ] || [ -f "$rc" ] || continue
			if ! grep -qs '# slyy$' "$rc"; then
				printf '\n%s\n' "$line" >>"$rc"
				touched="$touched ${rc#"$HOME"/}"
			fi
		done
		[ -z "$touched" ] || say "added ~/.local/bin to PATH in:$touched"
	fi

	if [ "$on_path" = yes ]; then
		say "done. Run: slyy"
	else
		say "done. Open a new terminal, then run: slyy   (or now: $dir/slyy)"
	fi
	say "provider key: e.g. export MELIOUS_API_KEY=... ; later updates: slyy update"
}

main "$@"
