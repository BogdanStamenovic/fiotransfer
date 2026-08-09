# Source this file from ~/.bashrc to add fiotransfer and fioget.
# Requires Bash 4+, curl, coreutils, and base64.

fiotransfer() {
    if (( $# != 1 )); then
        printf 'Usage: fiotransfer FILE\n       fiotransfer uninstall\n' >&2
        return 2
    fi

    local file=$1

    if [[ $file == uninstall ]]; then
        _fiotransfer_uninstall
        return
    fi
    if [[ ! -f $file ]]; then
        printf 'fiotransfer: not a regular file: %s\n' "$file" >&2
        return 2
    fi
    if (( BASH_VERSINFO[0] < 4 )); then
        printf 'fiotransfer: Bash 4 or newer is required\n' >&2
        return 2
    fi

    local command
    for command in curl base64 dd stat wc date; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf 'fiotransfer: %s is required\n' "$command" >&2
            return 127
        fi
    done

    local file_size file_size_mib temp_dir wrapper base_name encoded_name
    local offset=0 part_number=1 payload_size header_size object_size
    local locator='' provider='' selected_locator='' failed_count
    local upload_path is_complete=0

    if ! file_size=$(wc -c <"$file"); then
        printf 'fiotransfer: could not determine file size\n' >&2
        return 1
    fi
    file_size_mib=$(( (file_size + 1048575) / 1048576 ))

    if ! temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fiotransfer.XXXXXX"); then
        printf 'fiotransfer: could not create a temporary directory\n' >&2
        return 1
    fi
    trap 'rm -rf -- "$temp_dir"' RETURN
    wrapper=${temp_dir}/part
    base_name=${file##*/}
    encoded_name=$(printf '%s' "$base_name" | base64 | tr -d '\n')

    if ! _fiotransfer_init_providers "$temp_dir"; then
        return 2
    fi
    _fiotransfer_measure_latency "$temp_dir"

    printf 'Uploading %s (%d MiB) with automatic provider fallback.\n' \
        "$base_name" "$file_size_mib" >&2

    # Every successful object becomes the predecessor named by the next
    # object's header. A failed provider is skipped for the rest of this run;
    # the same byte range is then restaged to fit the next provider's limit.
    while (( ! is_complete )); do
        failed_count=0
        while :; do
            if (( offset == 0 )); then
                : >"$wrapper"
                header_size=0
            else
                printf 'FIOTRANSFER-CHAIN-V2\n%s\n%s\n\n' \
                    "$locator" "$encoded_name" >"$wrapper"
                header_size=$(stat -c %s -- "$wrapper") || return 1
            fi

            if ! _fiotransfer_select_provider "$header_size" \
                "$((file_size - offset))"; then
                printf 'fiotransfer: no provider can accept the remaining data\n' >&2
                return 1
            fi
            provider=$_FIOTRANSFER_SELECTED_PROVIDER
            payload_size=$((_FIOTRANSFER_SELECTED_LIMIT - header_size))
            if (( payload_size > file_size - offset )); then
                payload_size=$((file_size - offset))
            fi

            # Preserve the original name and avoid a temporary copy whenever
            # the complete file fits in the selected service.
            if (( offset == 0 && payload_size == file_size )); then
                upload_path=$file
                object_size=$file_size
            else
                if ! _fiotransfer_stage_part "$file" "$wrapper" "$offset" \
                    "$payload_size" "$header_size" "$part_number"; then
                    printf 'fiotransfer: failed to prepare part %d\n' "$part_number" >&2
                    return 1
                fi
                upload_path=$wrapper
                object_size=$((header_size + payload_size))
            fi

            printf 'Uploading part %d through %s (%d MiB).\n' \
                "$part_number" "$provider" \
                "$(( (object_size + 1048575) / 1048576 ))" >&2
            if selected_locator=$(_fiotransfer_upload_provider \
                "$provider" "$upload_path"); then
                locator=$selected_locator
                _fiotransfer_record_usage "$provider" "$object_size"
                printf 'Part %d uploaded through %s.\n' "$part_number" "$provider" >&2
                break
            fi

            _FIOTRANSFER_FAILED[$provider]=1
            failed_count=$((failed_count + 1))
            printf 'fiotransfer: %s failed; trying another provider\n' "$provider" >&2
            if (( failed_count >= ${#_FIOTRANSFER_PROVIDERS[@]} )); then
                printf 'fiotransfer: all eligible providers failed\n' >&2
                return 1
            fi
        done

        offset=$((offset + payload_size))
        if (( offset >= file_size )); then
            is_complete=1
        else
            part_number=$((part_number + 1))
        fi
    done

    trap - RETURN
    rm -rf -- "$temp_dir"
    printf 'Upload complete (%d part(s)).\n' "$part_number" >&2

    # A final file.io locator can still use the original short-code syntax.
    if [[ $locator == f:* ]]; then locator=${locator#f:}; fi
    printf 'Code: %s\n' "$locator"
    printf 'Download with: fioget %q\n' "$locator"
}

_fiotransfer_uninstall() {
    local answer bashrc=${HOME}/.bashrc data_home install_dir install_file
    local start_marker='# >>> fiotransfer >>>'
    local end_marker='# <<< fiotransfer <<<'
    local temp_file

    data_home=${XDG_DATA_HOME:-"${HOME}/.local/share"}
    install_dir=${data_home}/fiotransfer
    install_file=${install_dir}/fileio.sh

    printf 'This will remove fiotransfer from %s and %s.\n' "$install_dir" "$bashrc"
    printf 'Are you sure? [y/N] '
    if ! read -r answer </dev/tty; then
        printf '\nfiotransfer: unable to read confirmation; not uninstalled\n' >&2
        return 1
    fi
    case ${answer,,} in
        y|yes) ;;
        *) printf 'Uninstall cancelled.\n'; return 0 ;;
    esac

    if [[ -f $bashrc ]] && grep -Fqx "$start_marker" "$bashrc" && \
        grep -Fqx "$end_marker" "$bashrc"; then
        if ! temp_file=$(mktemp "${bashrc}.fiotransfer.XXXXXX"); then
            printf 'fiotransfer: could not create a temporary file\n' >&2
            return 1
        fi
        if ! awk -v start="$start_marker" -v end="$end_marker" '
            $0 == start { managed = 1; next }
            $0 == end   { managed = 0; next }
            !managed    { print }
        ' "$bashrc" >"$temp_file"; then
            rm -f -- "$temp_file"
            printf 'fiotransfer: could not update %s\n' "$bashrc" >&2
            return 1
        fi
        chmod --reference="$bashrc" "$temp_file" 2>/dev/null || true
        if ! mv -- "$temp_file" "$bashrc"; then
            rm -f -- "$temp_file"
            printf 'fiotransfer: could not update %s\n' "$bashrc" >&2
            return 1
        fi
    fi

    rm -f -- "$install_file"
    rmdir -- "$install_dir" 2>/dev/null || true
    printf 'fiotransfer has been uninstalled. Restart the shell to finish.\n'
    unset -f fioget fiotransfer
}

# Build the enabled provider table. Limits are bytes per uploaded object and
# bytes per rolling hour. A zero hourly limit means the service publishes no
# hourly quota; upload failures remain the authoritative fallback signal.
_fiotransfer_init_providers() {
    local temp_dir=$1 provider provider_list=${FIOTRANSFER_PROVIDERS:-fileio,temp,0x0}
    local chunk_cap=${FIOTRANSFER_CHUNK_SIZE_BYTES:-0}

    if [[ ! $chunk_cap =~ ^[0-9]+$ ]]; then
        printf 'fiotransfer: FIOTRANSFER_CHUNK_SIZE_BYTES must be a non-negative integer\n' >&2
        return 1
    fi

    declare -ga _FIOTRANSFER_PROVIDERS=()
    declare -gA _FIOTRANSFER_MAX_OBJECT=()
    declare -gA _FIOTRANSFER_HOURLY_LIMIT=()
    declare -gA _FIOTRANSFER_LATENCY=()
    declare -gA _FIOTRANSFER_FAILED=()
    declare -gA _FIOTRANSFER_ENDPOINT=()

    _FIOTRANSFER_MAX_OBJECT[fileio]=2000000000
    _FIOTRANSFER_HOURLY_LIMIT[fileio]=4000000000
    _FIOTRANSFER_ENDPOINT[fileio]=https://file.io/
    _FIOTRANSFER_MAX_OBJECT[temp]=4000000000
    _FIOTRANSFER_HOURLY_LIMIT[temp]=0
    _FIOTRANSFER_ENDPOINT[temp]=https://temp.sh/
    _FIOTRANSFER_MAX_OBJECT[0x0]=536870912
    _FIOTRANSFER_HOURLY_LIMIT[0x0]=0
    _FIOTRANSFER_ENDPOINT[0x0]=https://0x0.st/

    provider_list=${provider_list//,/ }
    for provider in $provider_list; do
        if [[ ! ${_FIOTRANSFER_MAX_OBJECT[$provider]+set} ]]; then
            printf 'fiotransfer: unknown provider: %s\n' "$provider" >&2
            return 1
        fi
        _FIOTRANSFER_PROVIDERS+=("$provider")
        if (( chunk_cap > 0 && chunk_cap < _FIOTRANSFER_MAX_OBJECT[$provider] )); then
            _FIOTRANSFER_MAX_OBJECT[$provider]=$chunk_cap
        fi
    done
    if (( ${#_FIOTRANSFER_PROVIDERS[@]} == 0 )); then
        printf 'fiotransfer: no providers are enabled\n' >&2
        return 1
    fi

    if [[ -n ${FIOTRANSFER_STATE_HOME:-} ]]; then
        _FIOTRANSFER_STATE_HOME=$FIOTRANSFER_STATE_HOME
    elif [[ -n ${XDG_STATE_HOME:-} ]]; then
        _FIOTRANSFER_STATE_HOME=${XDG_STATE_HOME}/fiotransfer
    else
        _FIOTRANSFER_STATE_HOME=${HOME}/.local/state/fiotransfer
    fi
    _FIOTRANSFER_USAGE_FILE=${_FIOTRANSFER_STATE_HOME}/usage
    _FIOTRANSFER_PROBE_DIR=$temp_dir
}

# Probe read-only endpoints concurrently. Providers that cannot be measured are
# left usable with a conservative score so an outage is confirmed by upload.
_fiotransfer_measure_latency() {
    local temp_dir=$1 provider pid value seconds fraction
    local -a pids=()

    for provider in "${_FIOTRANSFER_PROVIDERS[@]}"; do
        (
            curl --silent --show-error --output /dev/null \
                --connect-timeout 2 --max-time 4 --write-out '%{time_total}' \
                "${_FIOTRANSFER_ENDPOINT[$provider]}" 2>/dev/null
        ) >"${temp_dir}/latency.${provider}" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    for provider in "${_FIOTRANSFER_PROVIDERS[@]}"; do
        value=$(<"${temp_dir}/latency.${provider}")
        if [[ $value =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            seconds=${BASH_REMATCH[1]}
            fraction=${BASH_REMATCH[2]}000
            _FIOTRANSFER_LATENCY[$provider]=$((seconds * 1000 + 10#${fraction:0:3}))
        else
            _FIOTRANSFER_LATENCY[$provider]=10000
        fi
    done
}

_fiotransfer_recent_usage() {
    local provider=$1 now cutoff
    now=$(date +%s)
    cutoff=$((now - 3600))
    if [[ ! -r $_FIOTRANSFER_USAGE_FILE ]]; then
        printf '0\n'
        return
    fi
    awk -v cutoff="$cutoff" -v provider="$provider" \
        '$1 >= cutoff && $2 == provider { total += $3 } END { print total + 0 }' \
        "$_FIOTRANSFER_USAGE_FILE"
}

_fiotransfer_record_usage() {
    local provider=$1 bytes=$2 now
    now=$(date +%s)
    if mkdir -p -- "$_FIOTRANSFER_STATE_HOME" 2>/dev/null; then
        printf '%s %s %s\n' "$now" "$provider" "$bytes" >>"$_FIOTRANSFER_USAGE_FILE" 2>/dev/null || true
    fi
}

_fiotransfer_select_provider() {
    local header_size=$1 remaining=$2 provider max_object hourly used available
    local payload_capacity estimated_parts score latency
    local best_score=2147483647 best_limit=0 best_provider=''

    for provider in "${_FIOTRANSFER_PROVIDERS[@]}"; do
        [[ ${_FIOTRANSFER_FAILED[$provider]:-0} == 1 ]] && continue
        max_object=${_FIOTRANSFER_MAX_OBJECT[$provider]}
        hourly=${_FIOTRANSFER_HOURLY_LIMIT[$provider]}
        available=$max_object
        if (( hourly > 0 )); then
            used=$(_fiotransfer_recent_usage "$provider")
            if (( hourly - used < available )); then available=$((hourly - used)); fi
        fi
        (( available > header_size )) || continue
        payload_capacity=$((available - header_size))
        estimated_parts=$(( (remaining + payload_capacity - 1) / payload_capacity ))
        # Endpoint RTT approximates the fixed cost of each request. Multiplying
        # it by the number of objects balances quick hosts against hosts that
        # can finish a large remainder in fewer requests.
        (( estimated_parts > 1000000 )) && estimated_parts=1000000
        latency=${_FIOTRANSFER_LATENCY[$provider]:-10000}
        score=$((latency * estimated_parts))
        if (( score < best_score )); then
            best_score=$score
            best_limit=$available
            best_provider=$provider
        fi
    done
    [[ -n $best_provider ]] || return 1
    _FIOTRANSFER_SELECTED_PROVIDER=$best_provider
    _FIOTRANSFER_SELECTED_LIMIT=$best_limit
}

_fiotransfer_upload_provider() {
    local provider=$1 upload_file=$2 response key error url
    local key_pattern='"key"[[:space:]]*:[[:space:]]*"([^\"]+)"'
    local error_pattern='"message"[[:space:]]*:[[:space:]]*"([^\"]+)"'

    case $provider in
        fileio)
            if ! response=$(curl --progress-bar --show-error --fail-with-body \
                --form "file=@${upload_file}" https://file.io); then
                if [[ $response =~ $error_pattern ]]; then error=${BASH_REMATCH[1]}; fi
                printf 'fiotransfer: file.io: %s\n' "${error:-upload failed}" >&2
                return 1
            fi
            if [[ $response =~ $key_pattern ]]; then
                key=${BASH_REMATCH[1]}
                [[ $key =~ ^[A-Za-z0-9_-]+$ ]] || return 1
                printf 'f:%s\n' "$key"
                return 0
            fi
            if [[ $response =~ $error_pattern ]]; then error=${BASH_REMATCH[1]}; fi
            printf 'fiotransfer: file.io: %s\n' "${error:-unexpected response}" >&2
            return 1
            ;;
        temp)
            if ! response=$(curl --progress-bar --show-error --fail-with-body \
                --form "file=@${upload_file}" https://temp.sh/upload); then
                printf 'fiotransfer: temp.sh upload failed\n' >&2
                return 1
            fi
            url=${response//$'\r'/}
            url=${url//$'\n'/}
            if [[ $url == https://temp.sh/* && $url != *[[:space:]]* ]]; then
                printf 't:%s\n' "${url#https://temp.sh/}"
                return 0
            fi
            printf 'fiotransfer: temp.sh returned an unexpected response\n' >&2
            return 1
            ;;
        0x0)
            if ! response=$(curl --progress-bar --show-error --fail-with-body \
                --form "file=@${upload_file}" https://0x0.st); then
                printf 'fiotransfer: 0x0.st upload failed\n' >&2
                return 1
            fi
            url=${response//$'\r'/}
            url=${url//$'\n'/}
            if [[ $url == https://0x0.st/* && $url != *[[:space:]]* ]]; then
                printf 'z:%s\n' "${url#https://0x0.st/}"
                return 0
            fi
            printf 'fiotransfer: 0x0.st returned an unexpected response\n' >&2
            return 1
            ;;
    esac
    return 1
}

# Copy a range into a temporary upload object and show local preparation
# progress. header_size is zero for a raw first part and nonzero for a chain.
_fiotransfer_stage_part() {
    local input=$1 output=$2 offset=$3 count=$4 header_size=$5 part=$6
    local current_size copied percent filled bar dd_pid dd_status
    local signal_status=0 saved_int saved_term

    if (( header_size > 0 )); then
        dd if="$input" of="$output" oflag=append conv=notrunc \
            iflag=skip_bytes,count_bytes skip="$offset" count="$count" status=none &
    else
        dd if="$input" of="$output" iflag=skip_bytes,count_bytes \
            skip="$offset" count="$count" status=none &
    fi
    dd_pid=$!
    saved_int=$(trap -p INT)
    saved_term=$(trap -p TERM)
    trap 'signal_status=130; kill -TERM "$dd_pid" 2>/dev/null' INT
    trap 'signal_status=143; kill -TERM "$dd_pid" 2>/dev/null' TERM

    while kill -0 "$dd_pid" 2>/dev/null; do
        current_size=$(stat -c %s -- "$output" 2>/dev/null || printf '%s' "$header_size")
        copied=$((current_size - header_size))
        (( copied < 0 )) && copied=0
        (( copied > count )) && copied=$count
        if (( count == 0 )); then percent=100; else percent=$((copied * 100 / count)); fi
        filled=$((percent * 40 / 100))
        printf -v bar '%*s' "$filled" ''
        bar=${bar// /#}
        printf '\rPreparing part %d: [%-40s] %3d%% (%d/%d MiB)' \
            "$part" "$bar" "$percent" "$((copied / 1048576))" \
            "$(( (count + 1048575) / 1048576 ))" >&2
        sleep 0.2
    done

    if wait "$dd_pid"; then dd_status=0; else dd_status=$?; fi
    (( signal_status != 0 )) && dd_status=$signal_status
    if [[ -n $saved_int ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n $saved_term ]]; then eval "$saved_term"; else trap - TERM; fi

    if (( dd_status == 0 )); then
        printf -v bar '%*s' 40 ''
        bar=${bar// /#}
        printf '\rPreparing part %d: [%-40s] 100%% (%d/%d MiB)\n' \
            "$part" "$bar" "$(( (count + 1048575) / 1048576 ))" \
            "$(( (count + 1048575) / 1048576 ))" >&2
    else
        printf '\n' >&2
    fi
    return "$dd_status"
}

fioget() {
    if (( $# < 1 || $# > 2 )); then
        printf 'Usage: fioget CODE_OR_URL [OUTPUT_FILE]\n' >&2
        return 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        printf 'fioget: curl is required\n' >&2
        return 127
    fi
    if (( $# == 2 )); then
        _fiotransfer_download_chain "$1" "$2"
    else
        _fiotransfer_download_chain "$1"
    fi
}

_fiotransfer_locator_to_url() {
    local locator=$1
    locator=${locator%%\?*}
    locator=${locator%%\#*}
    case $locator in
        f:*) [[ ${locator#f:} =~ ^[A-Za-z0-9_-]+$ ]] && printf 'https://file.io/%s\n' "${locator#f:}" ;;
        t:?*) [[ ${locator#t:} != *[[:space:]]* ]] && printf 'https://temp.sh/%s\n' "${locator#t:}" ;;
        z:?*) [[ ${locator#z:} != *[[:space:]]* ]] && printf 'https://0x0.st/%s\n' "${locator#z:}" ;;
        https://file.io/*|https://www.file.io/*|https://temp.sh/*|https://www.temp.sh/*|https://0x0.st/*)
            [[ $locator != *[[:space:]]* ]] && printf '%s\n' "$locator"
            ;;
        *)
            locator=${locator#www.file.io/}
            locator=${locator#file.io/}
            locator=${locator#/}
            [[ $locator =~ ^[A-Za-z0-9_-]+$ ]] && printf 'https://file.io/%s\n' "$locator"
            ;;
    esac
}

_fiotransfer_download_chain() {
    local locator=$1 requested_output=${2-} temp_dir node headers magic previous
    local encoded_name='' blank header_size output decoded_name remote_name idx url
    local header_previous
    local -a parts=()
    local -A seen=()

    if ! temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fioget.XXXXXX"); then
        printf 'fioget: could not create a temporary directory\n' >&2
        return 1
    fi
    trap 'rm -rf -- "$temp_dir"' RETURN

    while :; do
        if [[ ${seen[$locator]+yes} ]]; then
            printf 'fioget: invalid multipart chain (repeated locator)\n' >&2
            return 1
        fi
        seen[$locator]=1
        if ! url=$(_fiotransfer_locator_to_url "$locator") || [[ -z $url ]]; then
            printf 'fioget: invalid code or URL: %s\n' "$locator" >&2
            return 2
        fi
        node=${temp_dir}/node
        headers=${temp_dir}/headers
        if ! curl --fail --location --show-error --dump-header "$headers" \
            --output "$node" "$url"; then
            return 1
        fi
        IFS= read -r magic <"$node" || magic=
        if [[ $magic != FIOTRANSFER-CHAIN-V1 && $magic != FIOTRANSFER-CHAIN-V2 ]]; then
            parts+=("$node")
            break
        fi
        {
            IFS= read -r magic
            IFS= read -r previous
            IFS= read -r encoded_name
            IFS= read -r blank
        } <"$node"
        header_previous=$previous
        if [[ $magic == FIOTRANSFER-CHAIN-V1 ]]; then
            previous=f:${previous}
        fi
        if [[ -z $previous || -n $blank || -z $encoded_name ]] || \
            ! _fiotransfer_locator_to_url "$previous" >/dev/null; then
            printf 'fioget: invalid multipart header\n' >&2
            return 1
        fi
        header_size=$(( ${#magic} + ${#header_previous} + ${#encoded_name} + 4 ))
        node=${temp_dir}/part.${#parts[@]}
        if ! dd if="${temp_dir}/node" of="$node" iflag=skip_bytes \
            skip="$header_size" status=none; then
            printf 'fioget: could not unpack multipart data\n' >&2
            return 1
        fi
        parts+=("$node")
        locator=$previous
    done

    if [[ -n $requested_output ]]; then
        output=$requested_output
    elif (( ${#parts[@]} == 1 )); then
        remote_name=$(awk 'BEGIN { IGNORECASE=1 }
            /^Content-Disposition:/ {
                if (match($0, /filename="[^"]+"/)) {
                    value=substr($0, RSTART + 10, RLENGTH - 11)
                }
            }
            END { print value }' "$headers")
        output=${remote_name##*/}
        if [[ -z $output ]]; then
            output=${url%%\?*}
            output=${output##*/}
        fi
        if [[ -z $output || $output == . || $output == .. ]]; then output=download; fi
    else
        if ! decoded_name=$(printf '%s' "$encoded_name" | base64 -d 2>/dev/null); then
            printf 'fioget: invalid original filename in multipart header\n' >&2
            return 1
        fi
        output=${decoded_name##*/}
        if [[ -z $output || $output == . || $output == .. ]]; then output=download; fi
    fi

    if ! : >"$output"; then
        printf 'fioget: could not write %s\n' "$output" >&2
        return 1
    fi
    for ((idx=${#parts[@]} - 1; idx >= 0; idx--)); do
        if ! command cat "${parts[idx]}" >>"$output"; then
            printf 'fioget: could not assemble %s\n' "$output" >&2
            return 1
        fi
    done
    trap - RETURN
    rm -rf -- "$temp_dir"
    printf 'Downloaded and assembled %d part(s) into %s\n' "${#parts[@]}" "$output"
}
