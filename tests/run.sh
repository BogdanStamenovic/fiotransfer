#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/fiotransfer-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/remote" "$test_dir/state"

cat >"$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

form='' output='' headers='' write_out='' url='' upload_file=''
while (( $# )); do
    case $1 in
        --form)
            form=$2
            [[ $form == *=@* ]] && upload_file=${form#*=@}
            shift 2
            ;;
        --output) output=$2; shift 2 ;;
        --dump-header) headers=$2; shift 2 ;;
        --write-out) write_out=$2; shift 2 ;;
        --connect-timeout|--max-time) shift 2 ;;
        --silent|--show-error|--progress-bar|--fail|--fail-with-body|--location) shift ;;
        --*) shift ;;
        *) url=$1; shift ;;
    esac
done

if [[ -n $write_out ]]; then
    [[ ${MOCK_UNRESPONSIVE_URL:-} == "$url" ]] && exit 22
    case $url in
        https://file.io/) printf '0.010' ;;
        https://temp.sh/) printf '0.050' ;;
        https://litterbox.catbox.moe/) printf '0.070' ;;
        https://0x0.st/) printf '0.100' ;;
        *) printf '0.120' ;;
    esac
    exit 0
fi

if [[ -n $form ]]; then
    case $url in
        https://file.io)
            [[ ${MOCK_FAIL_FILEIO:-0} == 1 ]] && exit 22
            cp -- "$upload_file" "$MOCK_REMOTE/fileio.1"
            printf '{"success":true,"key":"k1"}\n'
            ;;
        https://temp.sh/upload)
            cp -- "$upload_file" "$MOCK_REMOTE/temp.1"
            printf 'https://temp.sh/t1/part\n'
            ;;
        https://0x0.st)
            cp -- "$upload_file" "$MOCK_REMOTE/zero.1"
            printf 'https://0x0.st/z1\n'
            ;;
        https://litterbox.catbox.moe/resources/internals/api.php)
            cp -- "$upload_file" "$MOCK_REMOTE/litterbox.1"
            printf 'https://files.catbox.moe/l1.bin\n'
            ;;
        'https://uguu.se/upload?output=text')
            cp -- "$upload_file" "$MOCK_REMOTE/uguu.1"
            printf 'https://n.uguu.se/u1.bin\n'
            ;;
        *) exit 22 ;;
    esac
    exit 0
fi

case $url in
    https://api.github.com/repos/BogdanStamenovic/fiotransfer/commits/main)
        printf '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n'
        exit 0
        ;;
    https://api.github.com/repos/BogdanStamenovic/fiotransfer/compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
        printf '{"status":"ahead"}\n'
        exit 0
        ;;
    https://raw.githubusercontent.com/BogdanStamenovic/fiotransfer/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/fiotransfer)
        cp -- "$MOCK_UPDATE_SOURCE" "$output"
        exit 0
        ;;
esac

[[ -n $output ]] || exit 2
: >"$headers"
case $url in
    https://file.io/k1)
        printf 'Content-Disposition: attachment; filename="source.bin"\r\n' >"$headers"
        cp -- "$MOCK_REMOTE/fileio.1" "$output"
        ;;
    https://file.io/v1) cp -- "$MOCK_REMOTE/v1" "$output" ;;
    https://temp.sh/t1/part) cp -- "$MOCK_REMOTE/temp.1" "$output" ;;
    https://0x0.st/z1) cp -- "$MOCK_REMOTE/zero.1" "$output" ;;
    https://files.catbox.moe/l1.bin) cp -- "$MOCK_REMOTE/litterbox.1" "$output" ;;
    https://n.uguu.se/u1.bin) cp -- "$MOCK_REMOTE/uguu.1" "$output" ;;
    *) exit 22 ;;
esac
MOCK
chmod +x "$test_dir/bin/curl"

export PATH="$test_dir/bin:$PATH"
export MOCK_REMOTE="$test_dir/remote"
export FIOTRANSFER_STATE_HOME="$test_dir/state"
export XDG_STATE_HOME="$test_dir/xdg-state"
# shellcheck source=../fiotransfer
source "$repo_dir/fiotransfer"

printf 'abcdefghijklmnopqrstuvwxyz0123456789' >"$test_dir/source.bin"

# Read-only provider subcommands expose configuration, local quota usage, and
# the result of the same health probes used by upload routing.
providers_output=$(FIOTRANSFER_PROVIDERS=temp,fileio fiotransfer providers)
grep -q 'Loaded providers (2)' <<<"$providers_output"
grep -q '^  temp$' <<<"$providers_output"
grep -q '^  fileio$' <<<"$providers_output"
[[ $(FIOTRANSFER_PROVIDERS=temp,fileio fiotransfer loaded-providers) == "$providers_output" ]]

limits_output=$(fiotransfer usage-limits)
grep -Eq '^fileio +2 GB +4 GB$' <<<"$limits_output"
grep -Eq '^uguu +128 MiB +not published$' <<<"$limits_output"

printf '%s fileio 1000000000\n' "$(date +%s)" >"$test_dir/state/usage"
usage_output=$(fiotransfer usage)
grep -Eq '^fileio +1 GB +3 GB$' <<<"$usage_output"
grep -Eq '^temp +not tracked +unknown$' <<<"$usage_output"

export MOCK_UNRESPONSIVE_URL=https://0x0.st/
unresponsive_output=$(fiotransfer unresponsive-providers)
[[ $unresponsive_output == 0x0 ]]
status_output=$(fiotransfer status)
grep -Eq '^fileio +responsive +10 ms +2 GB +1 GB / 4 GB$' <<<"$status_output"
grep -Eq '^0x0 +unresponsive +- +512 MiB +not tracked$' <<<"$status_output"
unset MOCK_UNRESPONSIVE_URL
grep -q 'All loaded providers are responsive' <<<"$(fiotransfer unresponsive)"

grep -q 'fiotransfer status' <<<"$(fiotransfer --help)"

# Leave file.io only twelve bytes of its rolling-hour allowance. Its lower
# measured latency wins the first part; temp.sh must carry the remainder.
printf '%s fileio 3999999988\n' "$(date +%s)" >"$test_dir/state/usage"
upload_output=$(FIOTRANSFER_CHUNK_SIZE_BYTES=128 \
    fiotransfer "$test_dir/source.bin" 2>"$test_dir/upload.log")
code=$(printf '%s\n' "$upload_output" | awk '/^Code: / { print $2 }')
[[ $code == t:t1/part ]]
grep -q 'Part 1 uploaded through fileio' "$test_dir/upload.log"
grep -q 'Part 2 uploaded through temp' "$test_dir/upload.log"

fioget "$code" "$test_dir/result.bin" >"$test_dir/download.log"
cmp "$test_dir/source.bin" "$test_dir/result.bin"

# Chains created by releases before provider-aware V2 remain downloadable.
printf 'legacy-' >"$test_dir/remote/fileio.1"
encoded_name=$(printf 'legacy.bin' | base64 | tr -d '\n')
printf 'FIOTRANSFER-CHAIN-V1\nk1\n%s\n\ncurrent' "$encoded_name" \
    >"$test_dir/remote/v1"
fioget v1 "$test_dir/legacy.bin" >/dev/null
[[ $(<"$test_dir/legacy.bin") == legacy-current ]]

# A hard failure of the fastest provider transparently retries the same file
# through the next-lowest-latency provider.
rm -f "$test_dir/remote/"*
: >"$test_dir/state/usage"
export MOCK_FAIL_FILEIO=1
fallback_output=$(fiotransfer "$test_dir/source.bin" 2>"$test_dir/fallback.log")
fallback_code=$(printf '%s\n' "$fallback_output" | awk '/^Code: / { print $2 }')
[[ $fallback_code == t:t1/part ]]
grep -q 'fileio failed; trying another provider' "$test_dir/fallback.log"
fioget "$fallback_code" "$test_dir/fallback.bin" >/dev/null
cmp "$test_dir/source.bin" "$test_dir/fallback.bin"

# Locator parsing retains old bare file.io codes and supports all new forms.
[[ $(_fiotransfer_locator_to_url old_key) == https://file.io/old_key ]]
[[ $(_fiotransfer_locator_to_url f:new_key) == https://file.io/new_key ]]
[[ $(_fiotransfer_locator_to_url t:a/file) == https://temp.sh/a/file ]]
[[ $(_fiotransfer_locator_to_url z:abc.txt) == https://0x0.st/abc.txt ]]
[[ $(_fiotransfer_locator_to_url l:abc.bin) == https://files.catbox.moe/abc.bin ]]
[[ $(_fiotransfer_locator_to_url u:n.uguu.se/abc.bin) == https://n.uguu.se/abc.bin ]]
if _fiotransfer_locator_to_url https://example.com/not-supported >/dev/null; then
    printf 'Unsupported URL was accepted.\n' >&2
    exit 1
fi

# Exercise both new upload adapters and their download locators.
unset MOCK_FAIL_FILEIO
[[ $(_fiotransfer_upload_provider litterbox "$test_dir/source.bin") == l:l1.bin ]]
fioget l:l1.bin "$test_dir/litterbox.bin" >/dev/null
cmp "$test_dir/source.bin" "$test_dir/litterbox.bin"
[[ $(_fiotransfer_upload_provider uguu "$test_dir/source.bin") == u:n.uguu.se/u1.bin ]]
fioget u:n.uguu.se/u1.bin "$test_dir/uguu.bin" >/dev/null
cmp "$test_dir/source.bin" "$test_dir/uguu.bin"

# The updater stages, validates, backs up, atomically replaces, and reloads an
# installer-managed script.
install_home="$test_dir/install-home"
mkdir -p "$install_home"
HOME="$install_home" XDG_DATA_HOME="$install_home/data" \
    XDG_STATE_HOME="$install_home/state" "$repo_dir/install.sh" >/dev/null
test -f "$install_home/data/fiotransfer/fiotransfer"
if git -C "$repo_dir" diff --quiet HEAD -- fiotransfer install.sh; then
    [[ $(<"$install_home/state/fiotransfer/installed-revision") == \
        "$(git -C "$repo_dir" rev-parse HEAD)" ]]
else
    test ! -e "$install_home/state/fiotransfer/installed-revision"
fi

export XDG_DATA_HOME="$test_dir/data"
mkdir -p "$XDG_DATA_HOME/fiotransfer"
cp -- "$repo_dir/fiotransfer" "$XDG_DATA_HOME/fiotransfer/fiotransfer"
mkdir -p "$XDG_STATE_HOME/fiotransfer"
printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$XDG_STATE_HOME/fiotransfer/installed-revision"
sed '1s/$/ (updated)/' "$repo_dir/fiotransfer" >"$test_dir/update-source.sh"
export MOCK_UPDATE_SOURCE="$test_dir/update-source.sh"
source "$XDG_DATA_HOME/fiotransfer/fiotransfer"
fiotransfer update >"$test_dir/update.log"
cmp "$test_dir/update-source.sh" "$XDG_DATA_HOME/fiotransfer/fiotransfer"
grep -q 'fiotransfer updated successfully' "$test_dir/update.log"
test "$(find "$XDG_STATE_HOME/fiotransfer/backups" -type f | wc -l)" -eq 1
[[ $(<"$XDG_STATE_HOME/fiotransfer/installed-revision") == \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
fiotransfer update >"$test_dir/update-current.log"
grep -q 'already up to date' "$test_dir/update-current.log"

printf 'All tests passed.\n'
