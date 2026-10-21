# Interactive rm goes to the recycle bin (trash-list / trash-restore); kos-trash-purge.timer empties it.
# Scripts and services are untouched: aliases only exist in interactive shells. '\rm' bypasses.
alias rm='trash-put'
alias sudo='sudo '   # so 'sudo rm' expands the alias too
