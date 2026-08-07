#!/usr/bin/env bash

set -euo pipefail

if [[ -z ${HOME:-} ]]; then
    printf 'install: HOME is not set\n' >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    printf 'install: curl is required but was not found\n' >&2
    exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_file=${script_dir}/fileio.sh
data_home=${XDG_DATA_HOME:-"${HOME}/.local/share"}
install_dir=${data_home}/fiotransfer
install_file=${install_dir}/fileio.sh
bashrc=${HOME}/.bashrc
start_marker='# >>> fiotransfer >>>'
end_marker='# <<< fiotransfer <<<'

if [[ ! -f $source_file ]]; then
    printf 'install: fileio.sh was not found next to install.sh\n' >&2
    exit 1
fi

mkdir -p -- "$install_dir"
temporary_script=$(mktemp "${install_dir}/.fileio.sh.XXXXXX")
temporary_bashrc=''
trap 'rm -f -- "$temporary_script" "$temporary_bashrc"' EXIT

cp -- "$source_file" "$temporary_script"
chmod 0644 "$temporary_script"
mv -- "$temporary_script" "$install_file"
temporary_script=''

touch -- "$bashrc"
if grep -Fqx "$start_marker" "$bashrc" || grep -Fqx "$end_marker" "$bashrc"; then
    if ! grep -Fqx "$start_marker" "$bashrc" || ! grep -Fqx "$end_marker" "$bashrc"; then
        printf 'install: incomplete fiotransfer block in %s; fix it manually\n' \
            "$bashrc" >&2
        exit 1
    fi

    temporary_bashrc=$(mktemp "${bashrc}.fiotransfer.XXXXXX")
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { managed = 1; next }
        $0 == end   { managed = 0; next }
        !managed    { print }
    ' "$bashrc" >"$temporary_bashrc"
    chmod --reference="$bashrc" "$temporary_bashrc" 2>/dev/null || true
    mv -- "$temporary_bashrc" "$bashrc"
    temporary_bashrc=''
fi

{
    printf '\n%s\n' "$start_marker"
    printf 'source %q\n' "$install_file"
    printf '%s\n' "$end_marker"
} >>"$bashrc"

printf 'fiotransfer installed successfully.\n'
printf 'Run this now, or open a new terminal: source %q\n' "$bashrc"
