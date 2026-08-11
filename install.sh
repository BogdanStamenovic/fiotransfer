#!/bin/sh

# Permit `sh install.sh` as well as direct execution from Bash, Zsh, and other
# shells. The rest of the installer deliberately runs under Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    for bootstrap_bash in "${FIOTRANSFER_BASH:-}" "$(command -v bash 2>/dev/null)" \
        /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -n "$bootstrap_bash" ] && [ -x "$bootstrap_bash" ]; then
            exec "$bootstrap_bash" "$0" "$@"
        fi
    done
    printf 'install: Bash is required to run this installer\n' >&2
    exit 1
fi

set -euo pipefail

if [[ -z ${HOME:-} ]]; then
    printf 'install: HOME is not set\n' >&2
    exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_file=${script_dir}/fiotransfer.sh
data_home=${XDG_DATA_HOME:-"${HOME}/.local/share"}
install_dir=${data_home}/fiotransfer
install_file=${install_dir}/fiotransfer.sh
bin_dir=${XDG_BIN_HOME:-"${HOME}/.local/bin"}
state_home=${XDG_STATE_HOME:-"${HOME}/.local/state"}
state_dir=${state_home}/fiotransfer
revision_file=${state_dir}/installed-revision
message_file=${state_dir}/installed-commit-message
profile_file=${state_dir}/shell-profile
bin_dir_file=${state_dir}/bin-directory
start_marker='# >>> fiotransfer >>>'
end_marker='# <<< fiotransfer <<<'

if [[ ! -f $source_file ]]; then
    printf 'install: fiotransfer.sh was not found next to install.sh\n' >&2
    exit 1
fi

# The user's login shell need not be Bash, but the implementation is Bash.
# Prefer an explicit interpreter, then PATH, then the usual Homebrew locations.
bash_path=''
for candidate in "${FIOTRANSFER_BASH:-}" "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -n $candidate && -x $candidate ]] || continue
    if "$candidate" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
        bash_path=$candidate
        break
    fi
done
if [[ -z $bash_path ]]; then
    printf 'install: Bash 4 or newer is required.\n' >&2
    if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
        printf 'Install it with "brew install bash", then rerun this installer.\n' >&2
    else
        printf 'Install Bash with your operating system package manager, then rerun this installer.\n' >&2
    fi
    exit 1
fi

for required_command in curl base64 awk grep head tail uname wc; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'install: %s is required but was not found\n' "$required_command" >&2
        exit 1
    fi
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    printf 'install: either sha256sum or shasum is required but was not found\n' >&2
    exit 1
fi

case ${FIOTRANSFER_SHELL:-${SHELL:-}} in
    zsh|*/zsh)   profile=${ZDOTDIR:-$HOME}/.zshrc; profile_kind=posix ;;
    fish|*/fish) profile=${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish; profile_kind=fish ;;
    bash|*/bash)
        if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
            profile=${HOME}/.bash_profile
        else
            profile=${HOME}/.bashrc
        fi
        profile_kind=posix
        ;;
    *)      profile=${HOME}/.profile; profile_kind=posix ;;
esac

mkdir -p -- "$install_dir" "$bin_dir" "$state_dir" "$(dirname -- "$profile")"
temporary_script=$(mktemp "${install_dir}/.fiotransfer.sh.XXXXXX")
temporary_profile=''
temporary_launcher=''
trap 'rm -f -- "$temporary_script" "$temporary_profile" "$temporary_launcher"' EXIT

cp -- "$source_file" "$temporary_script"
chmod 0644 "$temporary_script"
mv -- "$temporary_script" "$install_file"
temporary_script=''

quote_for_sh() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

make_launcher() {
    local command_name=$1 destination=$2 quoted_bash quoted_source
    quoted_bash=$(quote_for_sh "$bash_path")
    quoted_source=$(quote_for_sh "$install_file")
    temporary_launcher=$(mktemp "${bin_dir}/.${command_name}.XXXXXX")
    {
        printf '#!/bin/sh\n'
        printf 'exec %s -c '\''source "$1"; shift; %s "$@"'\'' %s %s "$@"\n' \
            "$quoted_bash" "$command_name" "$command_name" "$quoted_source"
    } >"$temporary_launcher"
    chmod 0755 "$temporary_launcher"
    mv -- "$temporary_launcher" "$destination"
    temporary_launcher=''
}

make_launcher fiotransfer "$bin_dir/fiotransfer"
make_launcher fioget "$bin_dir/fioget"

# Record the trusted source revision for forward-only self-updates. Installs
# from an exported archive still work; the updater establishes it later.
if command -v git >/dev/null 2>&1 && \
    git -C "$script_dir" diff --quiet HEAD -- fiotransfer.sh fiotransfer.ps1 install.sh install.ps1 && \
    revision=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null) && \
    [[ $revision =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$revision" >"$revision_file"
    git -C "$script_dir" log -1 --format=%s HEAD >"$message_file"
else
    rm -f -- "$revision_file" "$message_file"
fi
printf '%s\n' "$profile" >"$profile_file"
printf '%s\n' "$bin_dir" >"$bin_dir_file"

touch -- "$profile"
if grep -Fqx "$start_marker" "$profile" || grep -Fqx "$end_marker" "$profile"; then
    if ! grep -Fqx "$start_marker" "$profile" || ! grep -Fqx "$end_marker" "$profile"; then
        printf 'install: incomplete fiotransfer block in %s; fix it manually\n' \
            "$profile" >&2
        exit 1
    fi
    temporary_profile=$(mktemp "${profile}.fiotransfer.XXXXXX")
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { managed = 1; next }
        $0 == end   { managed = 0; next }
        !managed    { print }
    ' "$profile" >"$temporary_profile"
    chmod --reference="$profile" "$temporary_profile" 2>/dev/null || chmod 0644 "$temporary_profile"
    mv -- "$temporary_profile" "$profile"
    temporary_profile=''
fi

{
    printf '\n%s\n' "$start_marker"
    if [[ $profile_kind == fish ]]; then
        printf 'fish_add_path %s\n' "$(quote_for_sh "$bin_dir")"
    else
        printf 'export PATH=%s:"$PATH"\n' "$(quote_for_sh "$bin_dir")"
    fi
    printf '%s\n' "$end_marker"
} >>"$profile"

printf 'fiotransfer installed successfully for %s.\n' "${SHELL##*/}"
printf 'Commands: %s and %s\n' "$bin_dir/fiotransfer" "$bin_dir/fioget"
printf 'Open a new terminal, or reload %s.\n' "$profile"
