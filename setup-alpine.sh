#!/usr/bin/env bash
# vim: set ts=4 sw=4:
#
# Required environment variables:
# - INPUT_APK_TOOLS_URL
# - INPUT_ARCH
# - INPUT_BRANCH
# - INPUT_EXTRA_KEYS
# - INPUT_EXTRA_REPOSITORIES
# - INPUT_MIRROR_URL
# - INPUT_PACKAGES
# - INPUT_SHELL_NAME
# - INPUT_VOLUMES
#
set -euo pipefail

readonly SCRIPT_PATH=$(readlink -f "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

readonly ALPINE_BASE_PKGS='alpine-baselayout apk-tools busybox busybox-suid musl-utils'
readonly RUNNER_HOME="/home/$SUDO_USER"
readonly ROOTFS_BASE_DIR="$RUNNER_HOME/rootfs"


err_handler() {
	local lno=$1
	set +e

	# Print error line with 4 lines before/after.
	awk -v LINENO=$lno -v RED="\033[1;31m" -v RESET="\033[0m" '
		BEGIN { print "\n" RED "Error occurred at line " LINENO ":" RESET }
		NR > LINENO - 4 && NR < LINENO + 4 {
			pad = length(LINENO + 4); err = NR == LINENO
			printf "%s %" pad "d | %s%s\n", (err ? RED ">" : " "), NR, $0, (err ? RESET : "")
		}' "$SCRIPT_PATH"
	line=$(awk -v LINENO=$lno 'NR == LINENO { print $0 }' "$SCRIPT_PATH")

	die "${_current_group:-"Error"}" \
	    "Error occurred at line $lno: $line (see the job log for more information)"
}
trap 'err_handler $LINENO' ERR


#=======================  F u n c t i o n s  =======================#

die() {
	local title=$1
	local msg=$2

	printf '::error title=setup-alpine: %s::%s\n' "$title" "$msg"
	exit 1
}

info() {
	printf '▷ %s\n' "$@"
}

# Creates an expandable group in the log with title $1.
group() {
	[ "${_current_group:-}" ] && endgroup

	printf '::group::%s\n' "$*"
	_current_group="$*"
}

# Closes the expandable group in the log.
endgroup() {
	echo '::endgroup::'
}

# Converts Alpine architecture name to the corresponding QEMU name.
qemu_arch() {
	case "$1" in
		x86 | i[3456]86) echo 'i386';;
		armhf | armv[4-9]) echo 'arm';;
		*) echo "$1";;
	esac
}

# Returns 0 if arch $1 is not compatible with the host architecture and needs
# to be emulated.
needs_emulator() {
	local target="$(qemu_arch "$1")"
	local host="$(qemu_arch "$(uname -m)")"

	[ "$target" = "$host" ] && return 1
	[ "$host" = x86_64 ] && [ "$target" = i386 ] && return 1
	return 0
}

# Downloads a file from URL $1 to path $2 and verify its integrity.
# URL must end with '#!sha256!' followed by a SHA-256 checksum of the file.
download_file() {
	local url=${1%\#*}  # strips '#' and everything after
	local sha256=${1##*\#\!sha256\!}  # strips '#!sha256!' and everything before
	local filepath=$2

	[ -f "$filepath" ] \
		&& sha256_check "$filepath" "$sha256" >/dev/null 2>&1 \
		&& return 0

	mkdir -p "$(dirname "$filepath")" \
		&& curl --connect-timeout 10 -fsSL -o "$filepath" "$url" \
		&& sha256_check "$filepath" "$sha256"
}

# Checks SHA-256 checksum $2 of the given file $1.
sha256_check() {
	local filepath=$1
	local sha256=$2

	(cd "$(dirname "$filepath")" \
		&& echo "$sha256  ${filepath##*/}" | sha256sum -c)
}

# Unpacks content of an APK package.
unpack_apk() {
	tar -xz "$@" |& sed '/tar: Ignoring unknown extended header/d'
}

# Binds the directory $1 at the mountpoint $2 and sets propagation to private.
mount_bind() {
	local src=$1
	local dir=$2

	mkdir -p "$dir"
	mount -v --rbind "$src" "$dir"
	mount --make-rprivate "$dir"
}


#============================  M a i n  ============================#

case "$INPUT_APK_TOOLS_URL" in
	https://*\#\!sha256\!* | http://*\#\!sha256\!*) ;;  # valid
	*) die 'Invalid input parameter: apk-tools-url' \
	       "The value must start with https:// or http:// and end with '#!sha256!' followed by a SHA-256 hash of the file to be downloaded, but got: $INPUT_APK_TOOLS_URL"
esac

case "$INPUT_ARCH" in
	x86_64 | x86 | aarch64 | armhf | armv7 | ppc64le | riscv64 | s390x) ;;  # valid
	*) die 'Invalid input parameter: arch' \
	       "Expected one of: x86_64, x86, aarch64, armhf, armv7, ppc64le, riscv64, s390x, but got: $INPUT_ARCH."
esac

case "$INPUT_BRANCH" in
	v[0-9].[0-9]* | edge | latest-stable) ;;  # valid
	*) die 'Invalid input parameter: branch' \
	       "Expected 'v[0-9].[0-9]+' (e.g. v3.15), edge, or latest-stable, but got: $INPUT_BRANCH."
esac

for path in $INPUT_EXTRA_KEYS; do
	if ! [ -r "$GITHUB_WORKSPACE/$path" ]; then
		die 'Invalid input parameter: extra-keys' \
		    "File does not exist in workspace or is not readable: $path."
	fi
done

if ! expr "$INPUT_SHELL_NAME" : [a-zA-Z][a-zA-Z0-9_.~+@%-]*$ >/dev/null; then
	die 'Invalid input parameter: shell-name' \
	    "Expected value matching regex ^[a-zA-Z][a-zA-Z0-9_.~+@%-]*$, but got: $INPUT_SHELL_NAME."
fi


#-----------------------------------------------------------------------
group 'Prepare rootfs directory'

rootfs_dir="$ROOTFS_BASE_DIR/alpine-${INPUT_BRANCH%-stable}-$INPUT_ARCH"
if [ -e "$rootfs_dir" ]; then
	mkdir -p "$ROOTFS_BASE_DIR"
	rootfs_dir=$(mktemp -d "$rootfs_dir-XXXXXX")
	chmod 755 "$rootfs_dir"
else
	mkdir -p "$rootfs_dir"
fi
info "Alpine will be installed into: $rootfs_dir"

cd "$RUNNER_TEMP"


#-----------------------------------------------------------------------
group 'Download static apk-tools'

APK="$RUNNER_TEMP/apk"

info "Downloading ${INPUT_APK_TOOLS_URL%\#*}"
download_file "$INPUT_APK_TOOLS_URL" "$APK"
chmod +x "$APK"


#-----------------------------------------------------------------------
if needs_emulator "$INPUT_ARCH"; then
	qemu_arch=$(qemu_arch "$INPUT_ARCH")
	qemu_cmd="qemu-$qemu_arch"

	group "Install $qemu_cmd emulator"

	if update-binfmts --display $qemu_cmd >/dev/null 2>&1; then
		info "$qemu_cmd is already installed on the host system"

	else
		# apt-get is terribly slow - installing qemu-user-static via apt-get
		# takes anywhere from ten seconds to tens of seconds. This method takes
		# less than a second.
		info "Fetching $qemu_cmd from the latest-stable Alpine repository"
		$APK fetch \
			--keys-dir "$SCRIPT_DIR"/keys \
			--repository "$INPUT_MIRROR_URL/latest-stable/community" \
			--no-progress \
			--no-cache \
			$qemu_cmd

		info "Unpacking $qemu_cmd and installing on the host system"
		unpack_apk -f ./$qemu_cmd-*.apk usr/bin/$qemu_cmd
		mv usr/bin/$qemu_cmd /usr/local/bin/
		rm ./$qemu_cmd-*.apk

		info "Registering binfmt for $qemu_arch"
		update-binfmts --import "$SCRIPT_DIR"/binfmts/$qemu_cmd
	fi
fi


#-----------------------------------------------------------------------
group "Initialize Alpine Linux $INPUT_BRANCH ($INPUT_ARCH)"

cd "$rootfs_dir"

info 'Creating /etc/apk/repositories:'
mkdir -p etc/apk
printf '%s\n' \
	"$INPUT_MIRROR_URL/$INPUT_BRANCH/main" \
	"$INPUT_MIRROR_URL/$INPUT_BRANCH/community" \
	$INPUT_EXTRA_REPOSITORIES \
	| tee etc/apk/repositories

cp -r "$SCRIPT_DIR"/keys etc/apk/

for path in $INPUT_EXTRA_KEYS; do
	cp "$GITHUB_WORKSPACE/$path" etc/apk/keys/
done

cat /etc/resolv.conf > etc/resolv.conf

release_pkg='alpine-release'
if [ "${INPUT_BRANCH#v}" != "$INPUT_BRANCH" ] && [ "$($APK version -t "$INPUT_BRANCH" 'v3.17')" = '<' ]; then
	release_pkg=''
fi

info "Installing base packages into $(pwd)"
$APK add \
	--root . \
	--initdb \
	--no-progress \
	--update-cache \
	--arch "$INPUT_ARCH" \
	$ALPINE_BASE_PKGS $release_pkg

if ! [ "$release_pkg" ]; then
	# This package contains /etc/os-release, /etc/alpine-release and /etc/issue,
	# but we don't wanna install all its dependencies (e.g. openrc).
	info 'Fetching and unpacking /etc from alpine-base'
	$APK fetch \
		--root . \
		--no-progress \
		--stdout \
		alpine-base \
		| unpack_apk etc
fi


#-----------------------------------------------------------------------
group 'Bind filesystems into chroot'

mkdir -p proc
mount -v -t proc none proc
mount_bind /dev dev
mount_bind /sys sys
mount_bind "$RUNNER_HOME/work" "${RUNNER_HOME#/}/work"

# Some systems (Ubuntu?) symlinks /dev/shm to /run/shm.
if [ -L /dev/shm ] && [ -d /run/shm ]; then
	mount_bind /run/shm run/shm
fi

for vol in $INPUT_VOLUMES; do
	[ "$vol" ] || continue
	src=${vol%%:*}
	dst=${vol#*:}

	mount_bind "$src" "${dst#/}"
done


#-----------------------------------------------------------------------
group 'Copy action scripts'

install -Dv -m755 "$SCRIPT_DIR"/alpine.sh abin/"$INPUT_SHELL_NAME"
install -Dv -m755 "$SCRIPT_DIR"/destroy.sh .


#-----------------------------------------------------------------------
if [ "$INPUT_PACKAGES" ]; then
	group 'Install packages'

	pkgs=$(printf '%s ' $INPUT_PACKAGES)
	cat > .setup.sh <<-SHELL
		echo '▷ Installing $pkgs'
		apk add --update-cache $pkgs
	SHELL
	abin/"$INPUT_SHELL_NAME" --root /.setup.sh
fi


#-----------------------------------------------------------------------
group "Set up user $SUDO_USER"

cat > .setup.sh <<-SHELL
	echo '▷ Creating user $SUDO_USER with uid ${SUDO_UID:-1000}'
	adduser -u '${SUDO_UID:-1000}' -G users -s /bin/sh -D '$SUDO_USER'

	if [ -d /etc/sudoers.d ]; then
		echo '▷ Adding sudo rule:'
		echo '$SUDO_USER ALL=(ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/root
	fi
	if [ -d /etc/doas.d ]; then
		echo '▷ Adding doas rule:'
		echo 'permit nopass keepenv $SUDO_USER' | tee /etc/doas.d/root.conf
	fi
SHELL
abin/"$INPUT_SHELL_NAME" --root /.setup.sh

rm .setup.sh
endgroup
#-----------------------------------------------------------------------

echo "root-path=$rootfs_dir" >> $GITHUB_OUTPUT
echo "$rootfs_dir/abin" >> $GITHUB_PATH
