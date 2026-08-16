#!/bin/sh

# Run fiotransfer directly from an Ownbox checkout. This deliberately avoids
# install.sh: Ownbox already owns the launcher and checkout lifecycle, and a
# non-login Ownbox process cannot rely on ~/.local/bin being on PATH.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
entry_point=${1:-}
case $entry_point in
    fiotransfer|fioget) shift ;;
    *)
        printf 'ownbox entry: expected fiotransfer or fioget\n' >&2
        exit 2
        ;;
esac

for candidate in "${FIOTRANSFER_BASH:-}" "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
        exec "$candidate" -c 'source "$1"; entry_point=$2; shift 2; "$entry_point" "$@"' \
            ownbox-entry "$script_dir/fiotransfer.sh" "$entry_point" "$@"
    fi
done

printf 'fiotransfer: Bash 4 or newer is required\n' >&2
exit 1
