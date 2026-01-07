#!/bin/bash
# shellcheck enable=add-default-case,avoid-nullary-conditions,check-unassigned-uppercase,deprecate-which,quote-safe-variables,require-double-brackets

#
# Created by Pico Mitchell on 12/3/25.
# For MacLand @ Free Geek
# Version: 2025.12.4-1
#
# MIT License
#
# Copyright (c) 2025 Free Geek
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

PATH='/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec' # Add "/usr/libexec" to PATH for easy access to PlistBuddy.


if [[ ! -d '/System/Installation' || -f '/usr/bin/pico' ]]; then # The specified folder should exist in recoveryOS and the file should not.
	>&2 echo 'ERROR: "reset-remote-management-check" can ONLY be run within recoveryOS.'
	exit 1
fi

# Suppress ShellCheck suggestion to use "pgrep" since it's not available in recoveryOS.
# shellcheck disable=SC2009
if ps -ax | grep -qi '[f]g-install-os\|[s]tartosinstall\|[I]nstallAssistant'; then
	>&2 echo -e 'ERROR: "reset-remote-management-check" cannot be run because a macOS installation process is already running.'
	exit 1
fi


BOOTED_BUILD_VERSION="$(sw_vers -buildVersion)"
readonly BOOTED_BUILD_VERSION
BOOTED_DARWIN_MAJOR_VERSION="$(echo "${BOOTED_BUILD_VERSION}" | cut -c -2 | tr -dc '[:digit:]')" # 19 = 10.15 Catalina, 20 = 11 Big Sur, 21 = 12 Monterey, 22 = 13 Ventura, 23 = 14 Sonoma, 24 = 15 Sequoia, 25 = 26 Tahoe, etc. ("uname -r" is not available in recoveryOS).
readonly BOOTED_DARWIN_MAJOR_VERSION

possible_disk_ids=''

if (( BOOTED_DARWIN_MAJOR_VERSION >= 17 )); then # If is macOS 10.13 High Sierra or newer.
	# "diskutil list internal physical" was added in macOS 10.12 Sierra, but incorrectly includes "synthesized" disks for a macOS 10.13 High Sierra APFS installation even when "physical" is specified.
	# If this was used with the plist output, then the "WholeDisks" value would incorrectly include these "synthesized" disks and even checking "diskutil info" WOULD NOT properly catch that they are not actually a physical disk.
	# So, "diskutil list -plist internal physical" will only be used on macOS 10.13 High Sierra and newer where the "WholeDisks" value is reliable.
	# NOTE: Removable drives such as SD Cards will still show as "internal" so this output cannot be fully trusted and each disk ID must still be verified using "diskutil info" below.

	possible_disk_ids="$(PlistBuddy -c 'Print :WholeDisks' /dev/stdin <<< "$(diskutil list -plist internal physical)" 2> /dev/null | awk '/disk/ { print $1 }')"
elif (( BOOTED_DARWIN_MAJOR_VERSION >= 15 )); then # If is OS X 10.11 El Capitan or macOS 10.12 Sierra.
	# On macOS 10.12 Sierra, even though "diskutil list -plist internal physical" is not reliable (see comments above),
	# the the human readable text output of "diskutil list internal physical" does properly display "(internal" next to the disk IDs even though "synthesized" disks will also be in the output.
	# And OS X 10.11 El Captian DOES NOT include the options for "diskutil list internal physical" but DOES include "(internal" next to the disk IDs of the "diskutil list" human readable output.
	# So, to be compatible with both of these OS versions, just parse the human readable text output of "diskutil list" instead of using the plist output to be able to properly get only disk IDs of actual internal disks.

	possible_disk_ids="$(diskutil list | awk -F '/| ' '/^\/dev\/disk.*\(internal/ { print $3 }')"
else # If is OS X 10.10 Yosemite or older.
	# On OS X 10.10 Yosemite and older, "diskutil list internal physical" IS NOT available and also "(internal" IS NOT listed next to the disk IDs in the human readable output.
	# So for these older OS versions, just get all "WholeDisks" values from the "diskutil list -plist" output.
	# These disk IDs will be verified to be internal using using "diskutil info" below.

	possible_disk_ids="$(PlistBuddy -c 'Print :WholeDisks' /dev/stdin <<< "$(diskutil list -plist)" 2> /dev/null | awk '/disk/ { print $1 }')"
fi


while IFS='' read -r this_disk_id; do
	if [[ -n "${this_disk_id}" ]]; then
		# Make sure all internal drives are mounted before checking for Remote Management files.
		diskutil mountDisk "${this_disk_id}" &> /dev/null

		# Mounting parent disk IDs appears to not mount the child APFS Container disk IDs, so check for those and mount them too.
		while read -ra this_disk_info_line_elements; do
			if [[ "${this_disk_info_line_elements[2]#[^[:alpha:]]}" == 'Container' && "${this_disk_info_line_elements[3]}" == 'disk'* ]]; then
				diskutil mountDisk "${this_disk_info_line_elements[3]%[^[:digit:]]}" &> /dev/null
				# Trying to get APFS Containers of a disk from "diskutil" plist output would require a "diskutil list -plist" command and then multiple "diskutil info -plist" commands in a loop,
				# so just parse the human readable output of a single "diskutil list" command instead since it's right there even though it's not necessarily future-proof to parse the human readable output.
				# BUT, there are invisible characters in the "diskutil list" output before "Container" and after the disk ID as of macOS 11 Big Sur and newer, so they must be removed.
			fi
		done < <(diskutil list "${this_disk_id}")
	fi
done <<< "${possible_disk_ids}"


for this_volume in '/Volumes/'*; do
	if [[ -d "${this_volume}/private/var/db/ConfigurationProfiles/Settings/" ]]; then
		rm -rf "${this_volume}/private/var/db/ConfigurationProfiles/Settings/"{,.[^.],..?}*
		# The files in this folder, which keep track of previous Remote Management checks, are protected by System Integrity Protection (SIP),
		# so cannot be modified or deleted when macOS is running, but can only be deleted when running in Recovery.

		touch "${this_volume}/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"
		# NOTE: Above, all files within "/private/var/db/ConfigurationProfiles/Settings/" are deleted to reset any Remote Management Enrollment data that may have been saved.
		# But, if neither the ".cloudConfigRecordFound" nor the ".cloudConfigRecordNotFound" file exists, some Setup Assistant screens could be shown on next boot for some reason.
		# So, create the ".cloudConfigRecordNotFound" file to be sure macOS is starting in a state of thinking that Remote Management is NOT enabled.
		# If Remote Management is actually enabled, the ".cloudConfigRecordNotFound" file will be deleted and the ".cloudConfigRecordFound" file
		# (and others) will be re-created next time "profiles renew -type enrollment" is run.
	fi
done


shutdown -r now &> /dev/null
