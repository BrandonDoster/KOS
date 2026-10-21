# Shared shell helpers. Source, don't execute.
KOS_CONF=${KOS_CONF:-/config/kos.conf}
KOS_HOME=${KOS_HOME:-/home/klipper}
KOS_STATE=${KOS_STATE:-/var/lib/kos}
KOS_KEYS=${KOS_KEYS:-/etc/kos/authorized_keys/klipper}   # sshd's only AuthorizedKeysFile (sshd_config.d/kos.conf)

# kos.conf format. read_conf() in kos-archive and kos-mcu-discover is the Python twin; tests/test_lib_sh.sh keeps them equal.
#   key=value, one per line; the last one wins. '#' starts a comment only at the start of a line.
#   A line ending in '\' continues on the next line: the '\' goes, and the two parts are joined with one space.
#   Whitespace around the key and the value is stripped, then one pair of matching quotes.
# cfg_lines KEY: "<first line> <last line> <value>" for every KEY entry, in file order.
cfg_lines() {
    awk -v k="$1" '
        function emit(   key, val) {
            if (index(buf, "=") == 0) return
            key = substr(buf, 1, index(buf, "=") - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != k) return
            val = substr(buf, index(buf, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (length(val) >= 2 && (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/)) val = substr(val, 2, length(val) - 2)
            print start " " NR " " val
        }
        { sub(/\r$/, "") }
        !cont && /^[[:space:]]*#/ { next }
        { if (cont) { sub(/^[[:space:]]+/, ""); buf = buf " " $0 } else { buf = $0; start = NR } }
        /\\$/ { sub(/[[:space:]]*\\$/, "", buf); cont = 1; next }
        { cont = 0; emit() }
        END { if (cont) emit() }' "$KOS_CONF" 2>/dev/null
}

# cfg KEY [DEFAULT]: the value of the last KEY entry, or DEFAULT when absent or empty.
cfg() {
    local v
    v=$(cfg_lines "$1" | tail -n 1 | cut -d' ' -f3-)
    printf '%s' "${v:-${2:-}}"
}

log() { echo "kos: $*"; }
# warn: to the journal now; kos-config also writes the collected list to /config/KOS-WARNINGS.txt and the login banner.
warn() {
    echo "kos: WARNING: $*" >&2
    KOS_WARNINGS="${KOS_WARNINGS:-}$*
"
}

valid_label() { printf '%s\n' "$1" | grep -Eqx -- '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'; }   # RFC 1123
valid_dnsname() { printf '%s\n' "$1" | grep -Eqx -- '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*'; }
valid_tz() {   # a zone file under /usr/share/zoneinfo, nothing outside it
    case $1 in ''|*..*|/*) return 1 ;; esac
    [ "$(head -c 4 "/usr/share/zoneinfo/$1" 2>/dev/null)" = TZif ]
}

# split_keys: SSH public keys on stdin, any number per line -> one per line. A key starts at each key-type word,
# so "ssh_key=<key1> \" + "<key2>" yields both. Text before the first type word comes out as its own (invalid) line.
split_keys() {
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)$/ && k != "") { print k; k = "" }
            k = (k == "" ? $i : k " " $i)
        }
        if (k != "") print k; k = ""
    }'
}
ssh_keys() { cfg_lines ssh_key | cut -d' ' -f3- | split_keys; }
valid_key() { printf '%s\n' "$1" | ssh-keygen -lf - >/dev/null 2>&1; }

# apply_ssh_keys: rewrite $KOS_KEYS from kos.conf, so a removed ssh_key= is revoked. Invalid keys are skipped with a warning.
apply_ssh_keys() {
    local k tmp
    mkdir -p "$(dirname "$KOS_KEYS")"
    tmp=$(mktemp "$KOS_KEYS.XXXXXX") || return 1
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        if valid_key "$k"; then printf '%s\n' "$k"
        else warn "ssh_key: not a valid SSH public key, skipped: $(printf '%.60s' "$k")"; fi
    done > "$tmp" <<EOF
$(ssh_keys)
EOF
    chmod 0644 "$tmp" && mv -f "$tmp" "$KOS_KEYS"
}
