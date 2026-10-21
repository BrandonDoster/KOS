# Shared shell helpers. Source, don't execute.
KOS_CONF=${KOS_CONF:-/config/kos.conf}
KOS_HOME=${KOS_HOME:-/home/klipper}
KOS_STATE=${KOS_STATE:-/var/lib/kos}

# cfg KEY [DEFAULT] — last matching key wins; surrounding whitespace and one layer of quotes stripped.
cfg() {
    local v
    v=$(awk -F= -v k="$1" '
        /^[[:space:]]*#/ || !/=/ {next}
        { key=$1; sub(/^[[:space:]]+/,"",key); sub(/[[:space:]]+$/,"",key)
          if (key!=k) next
          val=substr($0, index($0,"=")+1); sub(/[[:space:]]+#.*$/,"",val)
          sub(/^[[:space:]]+/,"",val); sub(/[[:space:]]+$/,"",val)
          if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) val=substr(val,2,length(val)-2)
          out=val }
        END { print out }' "$KOS_CONF" 2>/dev/null)
    printf '%s' "${v:-${2:-}}"
}

log() { echo "kos: $*"; }
