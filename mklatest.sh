#!/bin/sh

# create .latest.txt file for mirrors
# usage:
arch=$(uname -m)
case "$(uname -m)" in
	i[0-9]86) arch=x86;;
esac



current=$(cat current) || exit 1
releasedir="v${current%.*}/releases/$arch"
target=.latest.txt

do_stat() {
	stat -c "%y $releasedir/%n %s" *-$current-$arch.iso
}

do_stat || exit 1
do_stat > $target


