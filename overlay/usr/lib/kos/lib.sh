# Shared shell helpers. Source, don't execute.
KOS_CONF=${KOS_CONF:-/config/kos.conf}
KOS_HOME=${KOS_HOME:-/home/klipper}
KOS_STATE=${KOS_STATE:-/var/lib/kos}
KOS_KEYS=${KOS_KEYS:-/etc/kos/authorized_keys/klipper}   # sshd's only AuthorizedKeysFile (sshd_config.d/kos.conf)

# kos.conf format. read_conf() in kos-archive and kos-mcu-discover is the Python twin; tests/test_lib_sh.sh keeps them equal.
#   key=value, one per line; the last one wins. '#' starts a comment only at the start of a line.
#   A line ending in '\' continues on the next line: the '\' goes, and the two parts are joined with one space.
#   A comment line, or a line that starts a new key=, ends a continuation (cfg_problems reports the second case).
#   Whitespace around the key and the value is stripped, then one pair of matching quotes.
#   A UTF-8 byte order mark on line 1 and NUL bytes are dropped; a CR counts only at the end of a line.
# cfg_lines KEY: "<first line> <last line> <value>" for every KEY entry, in file order.
# cfg_lines = problems: one message per line about continuations that look like mistakes.
cfg_lines() {
    LC_ALL=C tr -d '\000' 2>/dev/null < "$KOS_CONF" | LC_ALL=C awk -v k="$1" '
        function emit(   key, val) {
            if (index(buf, "=") == 0) return
            key = substr(buf, 1, index(buf, "=") - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != k) return
            val = substr(buf, index(buf, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (length(val) >= 2 && (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/)) val = substr(val, 2, length(val) - 2)
            print start " " end " " val
        }
        NR == 1 { sub(/^\357\273\277/, "") }
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { if (cont) { cont = 0; emit() } next }
        cont && /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/ {
            cont = 0; emit()
            if (k == "=") print "line " end " ends in \\ but line " NR " starts a new setting: read as two settings (remove the \\ if that is right)"
        }
        { if (cont) { sub(/^[[:space:]]+/, ""); buf = buf " " $0 } else { buf = $0; start = NR } end = NR }
        /\\$/ { sub(/[[:space:]]*\\$/, "", buf); cont = 1; next }
        { cont = 0; emit() }
        END { if (cont) { emit(); if (k == "=") print "the last line ends in \\ (a continuation with nothing after it): the \\ was dropped" } }'
}
cfg_problems() { cfg_lines '='; }

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
valid_dnsname() { [ ${#1} -le 253 ] && printf '%s\n' "$1" | grep -Eqx -- '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*'; }
valid_tz() {   # a zone file under /usr/share/zoneinfo, nothing outside it. Its "localtime" links back to /etc/localtime.
    local z=/usr/share/zoneinfo r
    case $1 in ''|*..*|/*|localtime|*/localtime) return 1 ;; esac
    r=$(readlink -f "$z/$1") && case $r in "$(readlink -f "$z")"/*) ;; *) return 1 ;; esac
    [ "$(head -c 4 "$r" 2>/dev/null)" = TZif ]
}

# moonraker_host FILE: print [server]'s host (its last unindented "host:" or "host =" line) and succeed only if it is
# 127.0.0.1. moonraker_host FILE ADDR: print FILE with "host: ADDR" right under [server] and its other host lines
# dropped, or with "[server] host: ADDR" appended when there is no [server]. Every other line stays as it was.
moonraker_host() {
    awk -v set="${2:-}" '
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^\[/ { srv = (line ~ /^\[server\]/) }
        srv && tolower(line) ~ /^host[[:space:]]*[:=]/ {
            host = line; sub(/^[^:=]*[:=][[:space:]]*/, "", host); sub(/[[:space:]]+[#;].*$/, "", host); sub(/[[:space:]]+$/, "", host)
            if (set != "") next
        }
        set != "" { print; if (srv && line ~ /^\[/ && !done) { print "host: " set; done = 1 } }
        END {
            if (set == "") { print host; exit (host != "127.0.0.1") }
            if (!done) printf "\n[server]\nhost: %s\n", set
        }' "$1"
}

# hosts_map NAME...: /etc/kos/nginx-hosts.map (conf.d/kos-hosts.conf) for these names and localhost. The leading '\'
# stops nginx from reading a name as a map keyword (default, include, hostnames, volatile).
hosts_map() { printf '%s\n' localhost "$@" | tr 'A-Z' 'a-z' | LC_ALL=C sort -u | sed 's/^/\\/; s/$/ 1;/'; }

# split_keys: SSH public keys on stdin, any number per line -> one per line. A key starts at each key-type word,
# so "ssh_key=<key1> \" + "<key2>" yields both. Options (from=, command=, restrict, ...) and certificates are not
# supported, and once lines are joined an option cannot be told apart from a comment: a line that does not start with
# a key type, or that holds an option-like word or a certificate anywhere, comes out whole with a leading '!' and is
# never installed (fail closed: a restricted key must not end up unrestricted).
split_keys() {
    awk '
        function opt(t,   n, i, p) {
            if (t ~ /="/) return 1
            n = split(tolower(t), p, ",")
            for (i = 1; i <= n; i++)
                if (p[i] !~ /^(restrict|cert-authority|verify-required|(no-)?(agent-forwarding|port-forwarding|pty|user-rc|x11-forwarding|touch-required))$/ &&
                    p[i] !~ /^(command|environment|expiry-time|from|permitlisten|permitopen|principals|tunnel)=/) return 0
            return 1
        }
        NF == 0 { next }
        {
            bad = $1 !~ T
            for (i = 1; i <= NF; i++) if ($i ~ /-cert-v01@openssh\.com$/ || opt($i)) bad = 1
            if (bad) { print "!" $0; next }
            for (i = 1; i <= NF; i++) {
                if ($i ~ T && k != "") { print k; k = "" }
                k = (k == "" ? $i : k " " $i)
            }
            print k; k = ""
        }' T='^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh[.]com)$'
}
ssh_keys() { cfg_lines ssh_key | cut -d' ' -f3- | split_keys; }
valid_key() { printf '%s\n' "$1" | ssh-keygen -lf - >/dev/null 2>&1; }

# apply_ssh_keys: rewrite $KOS_KEYS from kos.conf, so a removed ssh_key= is revoked. Invalid keys are skipped with a warning.
apply_ssh_keys() {
    local k tmp
    mkdir -p "$(dirname "$KOS_KEYS")"
    tmp=$(mktemp "$KOS_KEYS.XXXXXX") || return 1
    while IFS= read -r k; do
        case $k in
        '') ;;
        '!'*) warn "ssh_key: not a plain public key (options such as from= or command=, and certificates, are not supported), skipped: $(printf '%.60s' "${k#!}")" ;;
        *) if valid_key "$k"; then printf '%s\n' "$k"
           else warn "ssh_key: not a valid SSH public key, skipped: $(printf '%.60s' "$k")"; fi ;;
        esac
    done > "$tmp" <<EOF
$(ssh_keys)
EOF
    chmod 0644 "$tmp" && mv -f "$tmp" "$KOS_KEYS"
}
