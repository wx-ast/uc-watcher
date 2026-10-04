#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/release.sh [--sign-only] [--help]

Build a universal (arm64 + x86_64) release, sign with Developer ID Application,
submit to Apple, staple the ticket, check Gatekeeper and create a distribution ZIP.
--sign-only skips notarization and produces a ZIP marked as signed only.

Required environment:
  UC_SIGNING_IDENTITY  Full Developer ID Application certificate name in Keychain
  UC_NOTARY_PROFILE    notarytool Keychain profile (unless --sign-only)

Defaults may be configured in Scripts/release.local.env (ignored by Git).

Outputs: a new directory under .build/distribution/ for each invocation.
Passwords and private keys belong in Keychain, not in this script or repository.
EOF
}

sign_only=false
for argument in "$@"; do
    case "$argument" in
        --help|-h) usage; exit 0 ;;
        --sign-only) sign_only=true ;;
        *) usage >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
if [[ -f Scripts/release.local.env ]]; then
    source Scripts/release.local.env
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Release signing requires macOS.' >&2
    exit 1
fi
: "${UC_SIGNING_IDENTITY:?Set UC_SIGNING_IDENTITY to your Developer ID Application certificate name}"
if [[ "$UC_SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then
    echo 'Use the full name of a Developer ID Application certificate.' >&2
    exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$UC_SIGNING_IDENTITY\""; then
    echo 'The selected signing certificate and private key are not available in Keychain.' >&2
    exit 1
fi
if [[ "$sign_only" == false ]]; then
    : "${UC_NOTARY_PROFILE:?Set UC_NOTARY_PROFILE to your notarytool Keychain profile}"
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    # Check authentication before spending time on the build.
    xcrun notarytool history --keychain-profile "$UC_NOTARY_PROFILE" --output-format json >/dev/null
fi

swift build -c release --arch arm64 --arch x86_64
binary_directory="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
"$binary_directory/uc-watchdog" self-test
"$binary_directory/uc-watchdog" check-processes
mkdir -p .build/distribution
release_directory="$(mktemp -d "$PWD/.build/distribution/release.XXXXXX")"
app="$release_directory/UC Watchdog.app"
"$binary_directory/uc-watchdog" bundle --output "$app"

# Remove the local build's identifier-only ad-hoc requirement. codesign now
# generates the Developer ID requirement including Apple's anchor and our team.
/usr/bin/codesign --remove-signature "$app"
if ! /usr/bin/codesign --sign "$UC_SIGNING_IDENTITY" --options runtime --timestamp "$app" \
    >"$release_directory/signing.log" 2>&1; then
    cat "$release_directory/signing.log" >&2
    echo "Signing failed; diagnostic files retained in $release_directory" >&2
    echo 'For errSecInternalComponent, run from macOS Terminal with the signing Keychain unlocked and allow codesign access to the private key.' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$app"
/usr/bin/codesign --verify -R '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
/usr/bin/codesign --display --verbose=4 "$app" 2>"$release_directory/signature.txt"

if [[ "$sign_only" == true ]]; then
    archive="$release_directory/UC-Watchdog-signed.zip"
else
    submission="$release_directory/notary-submission.zip"
    /usr/bin/ditto -c -k --keepParent "$app" "$submission"
    result="$release_directory/notary-result.plist"
    submit_exit=0
    xcrun notarytool submit "$submission" --keychain-profile "$UC_NOTARY_PROFILE" \
        --wait --output-format plist >"$result" || submit_exit=$?
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    status="$(/usr/bin/plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    if [[ "$submit_exit" != 0 || "$status" != Accepted ]]; then
        if [[ -n "$submission_id" ]]; then
            xcrun notarytool log "$submission_id" --keychain-profile "$UC_NOTARY_PROFILE" \
                "$release_directory/notary-log.json" || true
        fi
        echo "Notarization did not finish with Accepted. Inspect $release_directory" >&2
        echo 'Use notarytool info/wait with the submission ID to check a pending request.' >&2
        exit 1
    fi
    xcrun notarytool log "$submission_id" --keychain-profile "$UC_NOTARY_PROFILE" \
        "$release_directory/notary-log.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    /usr/bin/codesign --verify --strict --verbose=2 "$app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
    archive="$release_directory/UC-Watchdog-notarized.zip"
fi
# Archive again after stapling, so the distributed app includes the ticket.
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
/usr/bin/shasum -a 256 "$archive" >"$archive.sha256"
printf 'Application: %s\nArchive: %s\n' "$app" "$archive"
