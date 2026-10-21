#!/bin/bash
# Self-check for overlay/usr/lib/kos/kos-trash-purge with stub df and trash-empty: only the listed trash folders,
# never a symlinked one, and a df that fails never counts as "disk low".
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/real/files" "$T/real/info" "$T/linked" "$T/evil/info"
ln -s "$T/real" "$T/link" && ln -s /etc "$T/evil/files"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$T" > "$T/bin/trash-empty"
run() {   # $1 = df output (empty: df fails)
    printf '#!/bin/sh\n[ -n "%s" ] || exit 1\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 100 99 %s 99%% /\\n"\n' "$1" "$1" > "$T/bin/df"
    chmod +x "$T/bin/"*; : > "$T/calls"
    PATH=$T/bin:$PATH KOS_TRASH_DIRS="$T/real $T/link $T/evil $T/missing" sh overlay/usr/lib/kos/kos-trash-purge
}
run ''                                    # df fails: the 30-day purge only
[ "$(cat "$T/calls")" = "-f --trash-dir $T/real 30" ]
run 50                                    # 50% free: same
[ "$(wc -l < "$T/calls")" -eq 1 ]
run 1                                     # 1% free: day by day down to 0, still only the real folder
[ "$(wc -l < "$T/calls")" -eq 31 ] && [ "$(tail -n 1 "$T/calls")" = "-f --trash-dir $T/real 0" ] || exit 1
! grep -q -e link -e evil "$T/calls" || exit 1
echo ok
