# Source this file from ~/.bashrc to add fiotransfer and fioget.
# Requires curl.

fiotransfer() {
    if (( $# != 1 )); then
        printf 'Usage: fiotransfer FILE\n       fiotransfer uninstall\n' >&2
        return 2
    fi

    local file=$1 response key key_pattern error error_pattern

    if [[ $file == uninstall ]]; then
        local answer bashrc=${HOME}/.bashrc data_home install_dir install_file
        local start_marker='# >>> fiotransfer >>>'
        local end_marker='# <<< fiotransfer <<<'
        local temp_file

        data_home=${XDG_DATA_HOME:-"${HOME}/.local/share"}
        install_dir=${data_home}/fiotransfer
        install_file=${install_dir}/fileio.sh

        printf 'This will remove fiotransfer from %s and %s.\n' \
            "$install_dir" "$bashrc"
        printf 'Are you sure? [y/N] '
        if ! read -r answer </dev/tty; then
            printf '\nfiotransfer: unable to read confirmation; not uninstalled\n' >&2
            return 1
        fi

        case ${answer,,} in
            y|yes) ;;
            *)
                printf 'Uninstall cancelled.\n'
                return 0
                ;;
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
        unset -f fioget
        unset -f fiotransfer
        return 0
    fi

    if [[ ! -f $file ]]; then
        printf 'fiotransfer: not a regular file: %s\n' "$file" >&2
        return 2
    fi

    if ! command -v curl >/dev/null 2>&1; then
        printf 'fiotransfer: curl is required\n' >&2
        return 127
    fi

    # file.io's free-tier limit is smaller than this at times.  The chunk size
    # can be lowered for such plans (or for testing) without changing the
    # share-code format.
    local chunk_size=${FIOTRANSFER_CHUNK_SIZE_BYTES:-1610612736}
    local file_size offset payload_size header_size part_number part_count temp_dir wrapper
    local encoded_name base_name file_size_mib

    if [[ ! $chunk_size =~ ^[1-9][0-9]*$ ]]; then
        printf 'fiotransfer: FIOTRANSFER_CHUNK_SIZE_BYTES must be a positive integer\n' >&2
        return 2
    fi
    if ! file_size=$(wc -c < "$file"); then
        printf 'fiotransfer: could not determine file size\n' >&2
        return 1
    fi
    file_size_mib=$(( (file_size + 1048575) / 1048576 ))

    if (( file_size <= chunk_size )); then
        printf 'Uploading %s (%d MiB). Progress below is for the complete file.\n' \
            "${file##*/}" "$file_size_mib" >&2
        if ! key=$(_fiotransfer_upload "$file"); then
            return 1
        fi
        printf 'Upload complete.\n' >&2
    else
        if ! command -v base64 >/dev/null 2>&1 || ! command -v dd >/dev/null 2>&1; then
            printf 'fiotransfer: base64 and dd are required for multipart uploads\n' >&2
            return 127
        fi
        if ! temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fiotransfer.XXXXXX"); then
            printf 'fiotransfer: could not create temporary directory\n' >&2
            return 1
        fi
        trap 'rm -rf -- "$temp_dir"' RETURN
        base_name=${file##*/}
        encoded_name=$(printf '%s' "$base_name" | base64 | tr -d '\n')
        offset=0
        part_number=1
        part_count=$(( (file_size + chunk_size - 1) / chunk_size ))

        printf 'Large file detected: %s (%d MiB).\n' "$base_name" "$file_size_mib" >&2
        printf 'Preparing and uploading approximately %d parts, one at a time.\n' \
            "$part_count" >&2

        # The first object is the first raw piece.  Each following object
        # carries the code for its predecessor in a small binary-safe header.
        payload_size=$chunk_size
        if (( payload_size > file_size )); then payload_size=$file_size; fi
        wrapper=${temp_dir}/part
        if ! _fiotransfer_stage_part "$file" "$wrapper" "$offset" \
            "$payload_size" 0 "$part_number" "$part_count"; then
            printf 'fiotransfer: failed to prepare part %d\n' "$part_number" >&2
            return 1
        fi
        printf 'Uploading part %d/%d. Progress below is for this part.\n' \
            "$part_number" "$part_count" >&2
        if ! key=$(_fiotransfer_upload "$wrapper"); then
            printf 'fiotransfer: failed to upload part %d\n' "$part_number" >&2
            return 1
        fi
        printf 'Part %d/%d uploaded.\n' "$part_number" "$part_count" >&2
        offset=$((offset + payload_size))

        while (( offset < file_size )); do
            part_number=$((part_number + 1))
            printf 'FIOTRANSFER-CHAIN-V1\n%s\n%s\n\n' "$key" "$encoded_name" >"$wrapper"
            header_size=$(wc -c < "$wrapper")
            payload_size=$((chunk_size - header_size))
            if (( payload_size <= 0 )); then
                printf 'fiotransfer: chunk size is too small for multipart metadata\n' >&2
                return 2
            fi
            part_count=$((part_number - 1 + \
                (file_size - offset + payload_size - 1) / payload_size))
            if (( payload_size > file_size - offset )); then payload_size=$((file_size - offset)); fi
            if ! _fiotransfer_stage_part "$file" "$wrapper" "$offset" \
                "$payload_size" 1 "$part_number" "$part_count"; then
                printf 'fiotransfer: failed to prepare part %d\n' "$part_number" >&2
                return 1
            fi
            printf 'Uploading part %d/%d. Progress below is for this part.\n' \
                "$part_number" "$part_count" >&2
            if ! key=$(_fiotransfer_upload "$wrapper"); then
                printf 'fiotransfer: failed to upload part %d\n' "$part_number" >&2
                return 1
            fi
            printf 'Part %d/%d uploaded.\n' "$part_number" "$part_count" >&2
            offset=$((offset + payload_size))
        done
        trap - RETURN
        rm -rf -- "$temp_dir"
        printf 'Uploaded %d chained parts.\n' "$part_number" >&2
    fi

    printf 'Code: %s\n' "$key"
    printf 'Download with: fioget %q\n' "$key"
}

# Copy a range into the temporary upload object and show progress while dd is
# running. The append flag is used for chained parts that already have a small
# metadata header.
_fiotransfer_stage_part() {
    local input=$1 output=$2 offset=$3 count=$4 append=$5 part=$6 total=$7
    local initial_size=0 current_size copied percent filled bar dd_pid dd_status
    local signal_status=0 saved_int saved_term

    if (( append )); then
        initial_size=$(stat -c %s -- "$output") || return 1
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
        if [[ -f $output ]]; then
            current_size=$(stat -c %s -- "$output") || current_size=$initial_size
        else
            current_size=$initial_size
        fi
        copied=$((current_size - initial_size))
        if (( copied < 0 )); then copied=0; fi
        if (( copied > count )); then copied=$count; fi
        percent=$((copied * 100 / count))
        filled=$((percent * 40 / 100))
        printf -v bar '%*s' "$filled" ''
        bar=${bar// /#}
        printf '\rPreparing part %d/%d: [%-40s] %3d%% (%d/%d MiB)' \
            "$part" "$total" "$bar" "$percent" \
            "$((copied / 1048576))" "$(( (count + 1048575) / 1048576 ))" >&2
        sleep 0.2
    done

    if wait "$dd_pid"; then
        dd_status=0
    else
        dd_status=$?
    fi
    if (( signal_status != 0 )); then dd_status=$signal_status; fi
    if [[ -n $saved_int ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n $saved_term ]]; then eval "$saved_term"; else trap - TERM; fi

    if (( dd_status == 0 )); then
        printf -v bar '%*s' 40 ''
        bar=${bar// /#}
        printf '\rPreparing part %d/%d: [%-40s] 100%% (%d/%d MiB)\n' \
            "$part" "$total" "$bar" \
            "$(( (count + 1048575) / 1048576 ))" \
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

    local code=$1 url

    if ! command -v curl >/dev/null 2>&1; then
        printf 'fioget: curl is required\n' >&2
        return 127
    fi

    # Accept the short code printed by fiotransfer as well as pasted links.
    code=${code#http://}
    code=${code#https://}
    code=${code#www.file.io/}
    code=${code#file.io/}
    code=${code%%\?*}
    code=${code%%\#*}
    code=${code#/}

    if [[ -z $code || $code == *[[:space:]]* ]]; then
        printf 'fioget: invalid file.io code or URL\n' >&2
        return 2
    fi

    if (( $# == 2 )); then
        _fiotransfer_download_chain "$code" "$2"
    else
        _fiotransfer_download_chain "$code"
    fi
}

# Upload one file and write only its file.io key to stdout.  Keeping progress
# on stderr makes this safe to use while constructing a multipart chain.
_fiotransfer_upload() {
    local upload_file=$1 response key error
    local key_pattern='"key"[[:space:]]*:[[:space:]]*"([^\"]+)"'
    local error_pattern='"message"[[:space:]]*:[[:space:]]*"([^\"]+)"'

    if ! response=$(curl --verbose --progress-bar --show-error --fail-with-body \
        --form "file=@${upload_file}" https://file.io); then
        if [[ $response =~ $error_pattern ]]; then
            printf 'fiotransfer: %s\n' "${BASH_REMATCH[1]}" >&2
        else
            printf 'fiotransfer: upload failed\n' >&2
        fi
        return 1
    fi
    if [[ $response =~ $key_pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ $response =~ $error_pattern ]]; then error=${BASH_REMATCH[1]}; fi
    printf 'fiotransfer: %s\n' "${error:-file.io returned an unexpected response}" >&2
    return 1
}

_fiotransfer_download_chain() {
    local code=$1 requested_output=${2-} temp_dir node headers magic previous encoded_name blank
    local header_size output decoded_name remote_name idx
    local -a parts=()
    local -A seen=()

    if ! temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fioget.XXXXXX"); then
        printf 'fioget: could not create temporary directory\n' >&2
        return 1
    fi
    trap 'rm -rf -- "$temp_dir"' RETURN

    while :; do
        if [[ ${seen[$code]+yes} ]]; then
            printf 'fioget: invalid multipart chain (repeated code)\n' >&2
            return 1
        fi
        seen[$code]=1
        node=${temp_dir}/node
        headers=${temp_dir}/headers
        if ! curl --fail --location --show-error --dump-header "$headers" --output "$node" "https://file.io/${code}"; then
            return 1
        fi
        IFS= read -r magic <"$node" || magic=
        if [[ $magic != FIOTRANSFER-CHAIN-V1 ]]; then
            parts+=("$node")
            break
        fi
        {
            IFS= read -r magic
            IFS= read -r previous
            IFS= read -r encoded_name
            IFS= read -r blank
        } <"$node"
        if [[ -z $previous || -n $blank || ! $previous =~ ^[A-Za-z0-9_-]+$ || -z $encoded_name ]]; then
            printf 'fioget: invalid multipart header\n' >&2
            return 1
        fi
        header_size=$(( ${#magic} + ${#previous} + ${#encoded_name} + 4 ))
        node=${temp_dir}/part.${#parts[@]}
        if ! dd if="${temp_dir}/node" of="$node" iflag=skip_bytes skip=$header_size status=none; then
            printf 'fioget: could not unpack multipart data\n' >&2
            return 1
        fi
        parts+=("$node")
        code=$previous
    done

    if [[ -n $requested_output ]]; then
        output=$requested_output
    elif (( ${#parts[@]} == 1 )); then
        # We already fetched this one-time file.io object while checking for a
        # chain, so use its Content-Disposition filename instead of fetching it
        # again (which would consume the link a second time).
        remote_name=$(awk 'BEGIN { IGNORECASE=1 }
            /^Content-Disposition:/ {
                if (match($0, /filename="[^"]+"/)) {
                    value=substr($0, RSTART + 10, RLENGTH - 11)
                }
            }
            END { print value }' "$headers")
        output=${remote_name##*/}
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
    for (( idx=${#parts[@]} - 1; idx >= 0; idx-- )); do
        if ! cat "${parts[idx]}" >>"$output"; then
            printf 'fioget: could not assemble %s\n' "$output" >&2
            return 1
        fi
    done
    trap - RETURN
    rm -rf -- "$temp_dir"
    printf 'Downloaded and assembled %d parts into %s\n' "${#parts[@]}" "$output"
}
