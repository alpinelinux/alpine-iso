#!/bin/sh

# craete .latest.txt file for mirrors
# usage:

current=$(cat current) || exit 1
releasedir="v${current%.*}/releases"
target=.latest.txt

do_stat() {
	stat -c "$release_dir %y %n %s" *-$current-x86.iso
}

do_stat || exit 1
do_stat > $target


