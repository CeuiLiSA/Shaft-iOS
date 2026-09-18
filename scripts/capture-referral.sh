#!/bin/bash
# Capture deterministic Debug fixtures; never uses a real account or grants rewards.
set -euo pipefail
referral_root="$(cd "$(dirname "$0")/.." && pwd)"
referral_device="${1:?Usage: capture-referral.sh BOOTED_SIMULATOR_UDID [DEBUG_APP_PATH]}"
referral_app="${2:-$referral_root/build/referral/Build/Products/Debug-iphonesimulator/Shaft-iOS.app}"
referral_output="$referral_root/docs/referral/screenshots"
mkdir -p "$referral_output"
xcrun simctl install "$referral_device" "$referral_app"
capture() {
    local name="$1"
    shift
    xcrun simctl terminate "$referral_device" com.shaft.ShaftiOS >/dev/null 2>&1 || true
    xcrun simctl launch "$referral_device" com.shaft.ShaftiOS --referral-preview "$@" >/dev/null
    sleep 1
    # simctl refuses to overwrite existing exported XCTest attachments. Capture
    # to a fresh file, then replace our previous artifact atomically.
    local capture_path="$referral_output/.$name-$$.png"
    xcrun simctl io "$referral_device" screenshot "$capture_path" >/dev/null
    mv -f "$capture_path" "$referral_output/$name.png"
}
capture phone-411-light --referral-width=411.428571
capture phone-411-dark --referral-width=411.428571 --referral-dark
capture invite-sheet --referral-sheet=invite
capture rules-sheet --referral-sheet=rules
capture claim-sheet --referral-sheet=claim
capture activate-sheet --referral-sheet=activate --referral-scenario=wallet
capture submission-form --referral-sheet=form --referral-task=recommend
