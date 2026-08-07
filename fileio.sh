# Source this file from ~/.bashrc to add fiotransfer and fioget.
# Requires curl.

fiotransfer() {
    if (( $# != 1 )); then
        printf 'Usage: fiotransfer FILE\n' >&2
        return 2
    fi

    local file=$1 response key key_pattern error error_pattern

    if [[ ! -f $file ]]; then
        printf 'fiotransfer: not a regular file: %s\n' "$file" >&2
        return 2
    fi

    if ! command -v curl >/dev/null 2>&1; then
        printf 'fiotransfer: curl is required\n' >&2
        return 127
    fi

    if ! response=$(curl --silent --show-error --fail-with-body \
        --form "file=@${file}" https://file.io); then
        printf 'fiotransfer: upload failed\n' >&2
        return 1
    fi

    # The API returns JSON. A file.io key cannot contain a double quote, so a
    # small Bash match avoids requiring jq or Python just to read the key.
    key_pattern='"key"[[:space:]]*:[[:space:]]*"([^\"]+)"'
    if [[ $response =~ $key_pattern ]]; then
        key=${BASH_REMATCH[1]}
    else
        error_pattern='"message"[[:space:]]*:[[:space:]]*"([^\"]+)"'
        if [[ $response =~ $error_pattern ]]; then
            error=${BASH_REMATCH[1]}
            printf 'fiotransfer: %s\n' "$error" >&2
        else
            printf 'fiotransfer: file.io returned an unexpected response\n' >&2
        fi
        return 1
    fi

    printf 'Code: %s\n' "$key"
    printf 'Download with: fioget %q\n' "$key"
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

    url="https://file.io/${code}"
    if (( $# == 2 )); then
        curl --fail --location --show-error --output "$2" "$url"
    else
        # Use the filename supplied by file.io when no output name is given.
        curl --fail --location --show-error \
            --remote-header-name --remote-name "$url"
    fi
}
