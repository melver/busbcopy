#!/usr/bin/env bash
#
# Copyright (c) 2014, Marco Elver
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the
#    distribution.
#
#  * Neither the name of the software nor the names of its contributors
#    may be used to endorse or promote products derived from this
#    software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

set -o errtrace
set -o errexit
set -o nounset

PROGNAME="${0##*/}"

# Any device larger than this (in MiB), we don't consider.
SAFETY_CUTOFF=10240
DD_MAX_RETRY=3

readonly PROGNAME SAFETY_CUTOFF

if [[ "$(id -u)" != "0" ]]; then
	echo "This script must be run as root!"
	exit 42
fi

die() {
	printf -- "\e[1;31mERROR:\e[0m ""$@" 1>&2
	exit 1
}

msg() {
	printf -- "\e[1;32mINFO:\e[0m ""$@"
}

warn() {
	printf -- "\e[1;33mWARN:\e[0m ""$@"
}

trap_ERR() {
	local errcode="$1"
	local lineno="$2"
	local command="$3"
	shift 3
	local traceback=""

	[[ -n "$*" ]] && printf -v traceback "\n    => in %s" "$@"
	die "line %s - '%s' failed (code=%s)%s\n" "$lineno" "$command" "$errcode" "$traceback"
}
trap 'trap_ERR "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[@]:+${FUNCNAME[@]}}"' ERR

# Check if we have all non-builtin dependencies
type -p realpath &>/dev/null || die "No realpath!\n"
type -p blockdev &>/dev/null || die "No blockdev!\n"
type -p dd &>/dev/null       || die "No dd!\n"
type -p rsync &>/dev/null    || die "No rsync!\n"
type -p openssl &>/dev/null  || die "No openssl!\n"
type -p eject &>/dev/null    || die "No eject!\n"

enumerate_usb_storage() {
	find "/dev/disk/by-id/" -name "usb-*" |
	while read line; do
		realpath "$line"
	done
}

validate_device() {
	local bdev="$1"
	[[ -b "$bdev" ]] || return 1
	local bdev_bytes="$(blockdev --getsize64 "$bdev")"
	(( bdev_bytes / (1024 * 1024) < SAFETY_CUTOFF ))
}

validated_usb_storage() {
	local bdev # not neccessary
	enumerate_usb_storage |
	while read bdev; do
		validate_device "$bdev" && echo "$bdev" || :
	done
}

# We only implement verification from image.
verify_init_checksum() {
	if [[ ! -f "$arg_source" ]]; then
		die "Need source image to verify against!\n"
	fi

	[[ -n "${img_checksum:-}" ]] && return 0 || :

	img_checksum="$(openssl dgst -md5 < "$arg_source")"
	img_checksum="${img_checksum##* }"

	msg "Image checksum (MD5): %s\n" "$img_checksum"

	local img_bytes="$(stat -c "%s" "$arg_source")"

	if (( img_bytes % 512 == 0 )); then
		img_blocks=$(( img_bytes / 512 ))
		img_bs=512
	else
		img_blocks=$img_bytes
		img_bs=1
	fi
}

verify_blockdev() {
	local bdev="$1"
	local bdev_checksum

	bdev_checksum="$(dd if="$bdev" bs=$img_bs count=$img_blocks 2>/dev/null | openssl dgst -md5)"
	bdev_checksum="${bdev_checksum##* }"

	if [[ "$bdev_checksum" == "$img_checksum" ]]; then
		return 0
	else
		return 1
	fi
}

copy_from_image() {
	local bdev="$1"

	if [[ ! -r "$arg_source" ]]; then
		die "Cannot read image %s!\n" "$arg_source"
	fi

	local try_count=0
	while (( try_count++ < DD_MAX_RETRY )); do
		dd if="$arg_source" of="$bdev" &>/dev/null

		if (( arg_verify )); then
			if verify_blockdev "$bdev"; then
				return 0
			else
				warn "Verification failed. Retrying %s ...\n" "$bdev"
			fi
		else
			return 0
		fi
	done

	die "Copying to %s failed!\n" "$bdev"
}

# If we copy from files, we assume that the target is already partitioned and
# formatted.
copy_from_files() {
	local bdev_part="${1}1"

	if [[ ! -e "$bdev_part" ]]; then
		die "Partition %s does not exist!\n" "$bdev_part"
	fi

	local tmp_mount="$(mktemp -d)"
	trap "rm -rv '${tmp_mount}'" EXIT

	if ! mount "$bdev_part" "$tmp_mount"; then
		die "Could not mount %s!" "$bdev_part"
	fi
	trap "umount '${tmp_mount}'; rm -rv '${tmp_mount}'" EXIT

	if ! rsync -qaAX --delete "${arg_source%/}/" "${tmp_mount}/"; then
		die "Rsync copy from %s to %s failed!" "$arg_source" "$bdev_part"
	fi
}

cmd_copy() {
	local bdev="$1"
	if ! validate_device "$bdev"; then
		die "Not a valid block device: %s\n" "$bdev"
	fi

	# Cleanup potential parent shell's EXIT trap.
	trap - EXIT

	if [[ -z "$arg_source" ]]; then
		die "Please specify source!\n"
	fi

	(( arg_verify )) && verify_init_checksum || :

	msg "Copying to %s ...\n" "$bdev"

	if [[ -d "$arg_source" ]]; then
		copy_from_files "$bdev"
	else
		copy_from_image "$bdev"
	fi

	if (( arg_verify )); then
		msg "Verified copy to %s successful.\n" "$bdev"
	else
		msg "Copying to %s successful.\n" "$bdev"
	fi

	if (( arg_eject )); then
		eject "$bdev"
	fi
}

cmd_verify() {
	verify_init_checksum

	while read bdev; do
		msg "Verifying %s ... " "$bdev"
		if verify_blockdev "$bdev"; then
			printf "\e[0;32mpassed.\e[0m\n"
		else
			printf "\e[0;31mfailed!\e[0m\n"
		fi
	done < <(validated_usb_storage)
}

batchcopy_cleanup() {
	for pid in "${pids[@]:+${pids[@]}}"; do
		kill "$pid" &>/dev/null || :
	done
}

cmd_batchcopy() {
	local min_count="${1:-1}"
	local batch_count
	local answer
	local all_done
	local bdev

	msg "Batch copy mode starting ...\n"
	trap 'batchcopy_cleanup' EXIT
	trap 'msg "User aborted!\n"; exit 42' INT

	# Because cmd_copy is called in a subshell, if we copy from image,
	# initialize checksum, so we only do it once.
	(( arg_verify )) && verify_init_checksum || :

	while :; do
		pids=()
		batch_count="$(validated_usb_storage | wc -l)"

		if (( batch_count < min_count )); then
			die "Detected %s USB storage devices. Need at least %s!\n" "$batch_count" "$min_count"
		fi

		msg "Detected %s USB storage device(s):\n" "${batch_count}"
		printf "\e[1;33m"
		validated_usb_storage |
		while read line; do
			printf "${sep:-}%s" "$line"
			sep=", "
		done
		printf "\e[0m\n"
		read -rp "Press ENTER to confirm..." answer

		msg "Start time: %s\n" "$(date)"

		# Can't pipe, as subshell would not propagate pids.
		while read bdev; do
			# BASHBUG?: Bash starts any command suffixed by & in a subshell,
			# however, it does not honor the EXIT trap if we do not explicitly
			# either EXIT or place it in an explicit subshell via (..).
			( cmd_copy "$bdev" ) &
			pids+=($!)
		done < <(validated_usb_storage)

		all_done=0
		while (( ! all_done )); do
			all_done=1
			for pid in "${pids[@]}"; do
				if kill -0 "$pid" &>/dev/null; then
					all_done=0
					break
				fi
			done
			sleep 1
		done

		sync
		msg "Finish time: %s\n" "$(date)"

		if (( ! arg_eject )); then
			msg "Please remove all USB storage devices ... "
			while (( $(validated_usb_storage | wc -l) )); do
				sleep 1
			done
			printf -- "done.\n"
		fi

		msg "Please insert next batch of USB storage devices.\n"
		read -rp "Press ENTER to confirm..." answer
	done
}

##
# PARSE OPTIONS
#
prog_usage() {
	printf -- "\
Usage: %s [<options>] <command> [<args>]

Commands available:
    enum       Enumerate all valid USB storage devices.
    copy       Copy to a single target.
    verify     Verify all attached USB storage devices against source image.
    batchcopy  Batch copy to all USB storage devices attached to this system.

Options:
    --source
        Source image or directory with files to copy to targets.
    --verify
        When copying an image, automatically verify.
    --eject
        Use 'eject' when done with copying.
" "$PROGNAME"
	exit 42
}

arg_source=
arg_verify=0
arg_eject=0

while :; do
	case "${1:-}" in
		--source)
			[[ -n "${2:-}" ]] || prog_usage
			arg_source="$2"
			shift
			;;
		--verify)
			arg_verify=1
			;;
		--eject)
			arg_eject=1
			;;
		-*) prog_usage ;;
		*) break;;
	esac
	shift
done

cmd="${1:-}"
shift || :

case "${cmd}" in
	enum) validated_usb_storage "$@"     ;;
	copy) cmd_copy "$@"                  ;;
	verify) cmd_verify "$@"              ;;
	batchcopy) cmd_batchcopy "$@"        ;;
	*) prog_usage                        ;;
esac

exit 0
