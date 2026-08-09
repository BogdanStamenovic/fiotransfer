#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/fiotransfer-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/remote" "$test_dir/state"

cat >"$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

form='' output='' headers='' write_out='' url=''
while (( $# )); do
    case $1 in
        --form) form=$2; shift 2 ;;
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
    case $url in
        https://file.io/) printf '0.010' ;;
        https://temp.sh/) printf '0.050' ;;
        *) printf '0.100' ;;
    esac
    exit 0
fi

if [[ -n $form ]]; then
    upload_file=${form#file=@}
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
        *) exit 22 ;;
    esac
    exit 0
fi

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
    *) exit 22 ;;
esac
MOCK
chmod +x "$test_dir/bin/curl"

export PATH="$test_dir/bin:$PATH"
export MOCK_REMOTE="$test_dir/remote"
export FIOTRANSFER_STATE_HOME="$test_dir/state"
# shellcheck source=../fileio.sh
source "$repo_dir/fileio.sh"

printf 'abcdefghijklmnopqrstuvwxyz0123456789' >"$test_dir/source.bin"

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
if _fiotransfer_locator_to_url https://example.com/not-supported >/dev/null; then
    printf 'Unsupported URL was accepted.\n' >&2
    exit 1
fi

printf 'All tests passed.\n'
