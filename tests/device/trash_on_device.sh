#!/bin/bash
# On-device check of the recycle bin (docs/plan.md §21.6). Run on a booted KOS box as klipper:
#   bash tests/device/trash_on_device.sh
# Works on throwaway files in ~/printer_data/trash-test. The last step forces the low-space path, which empties
# klipper's and root's whole recycle bins (KOS's trash folders): run it on a test box, not a printer you care about.
set -eu
shopt -s expand_aliases
. /etc/profile.d/kos-trash.sh
check() { if eval "$1"; then echo "ok: $2"; else echo "FAIL: $2"; exit 1; fi; }
T=~/printer_data/trash-test
mkdir -p $T/dir && echo a > $T/old.txt && echo b > $T/new.txt && echo c > $T/dir/x

rm -rf $T/dir
rm $T/old.txt
sudo rm -f $T/new.txt
check '[ -z "$(ls -A $T)" ]' "rm alias moved everything out of the folder"
check 'trash-list | grep -q trash-test/old.txt && trash-list | grep -q trash-test/dir && sudo trash-list | grep -q trash-test/new.txt' \
    "klipper and root trash hold the files"

info=$(grep -l 'trash-test/old.txt' ~/printer_data/.Trash-1000/info/*.trashinfo)
sed -i "s/^DeletionDate=.*/DeletionDate=$(date -d '40 days ago' +%FT%T)/" "$info"
sudo /usr/lib/kos/kos-trash-purge
check '! trash-list | grep -q trash-test/old.txt && trash-list | grep -q trash-test/dir && sudo trash-list | grep -q trash-test/new.txt' \
    "30-day purge took only the 40-day-old file"

low=$(mktemp)
sed 's/^MIN_FREE_PCT=10$/MIN_FREE_PCT=101/' /usr/lib/kos/kos-trash-purge > "$low"
sudo sh "$low"
rm -f "$low"
check '[ -z "$(trash-list)" ] && [ -z "$(sudo trash-list)" ]' "low-space purge emptied the trash"
rmdir $T
echo "all ok"
