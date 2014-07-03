#!/bin/sh

# create .latest.txt file for mirrors
# usage:
arch=$(uname -m)
case "$(uname -m)" in
	i[0-9]86) arch=x86;;
esac

current=$(cat current) || exit 1
if [ "${current%.*}" = "$current" ]; then
	branch=edge
else
	branch=v${current%.*}
fi
releasedir="$branch/releases/$arch"
target=.latest.txt

do_stat() {
	for f in *-$current-$arch.iso; do
		for hash in sha1 sha256; do
			if ! [ -f "$f.$hash" ]; then
				${hash}sum $f > $f.$hash
			fi
		done
		sha1=$(awk '{print $1}' $f.sha1)
		sha256=$(awk '{print $1}' $f.sha256)
		stat -c "%y $releasedir/%n %s $sha1 $sha256" $f
	done
}

do_yaml() {
	echo "---"
	do_stat | while read date time isopath size sha1 sha256; do
		iso=${isopath##*/}
		flavor=${iso%-${current}-${arch}.iso}
		echo "-"
		echo "  branch: $branch"
		echo "  arch: $arch"
		echo "  version: $current"
		echo "  flavor: $flavor"
		echo "  iso: $iso"
		echo "  date: $date"
		echo "  time: $time"
		echo "  size: $size"
		echo "  sha1: $sha1"
		echo "  sha256: $sha256"
	done
}

do_stat || exit 1
do_stat > $target

do_yaml > latest-releases.yaml

