#!/bin/sh

# create latest-releases.yaml file for mirrors

arch=$(abuild -A)

current=$(cat current) || exit 1
if [ "${current%.*}" = "$current" ]; then
	branch=edge
else
	branch=v${current%.*}
fi
releasedir="$branch/releases/$arch"

do_stat() {
	for f in *-$current-$arch.iso *-$current-$arch.*tar.gz; do
		if ! [ -e "$f" ]; then
			continue
		fi
		for hash in sha1 sha256 sha512; do
			if ! [ -f "$f.$hash" ]; then
				${hash}sum $f > $f.$hash
			fi
		done
		sha1=$(awk '{print $1}' $f.sha1)
		sha256=$(awk '{print $1}' $f.sha256)
		sha512=$(awk '{print $1}' $f.sha512)
		stat -c "%y $releasedir/%n %s $sha1 $sha256 $sha512" $f
	done
}

do_yaml() {
	echo "---"
	do_stat | while read date time filepath size sha1 sha256 sha512; do
		file=${filepath##*/}
		flavor=${file%-${current}-${arch}.*}
		echo "-"
		echo "  branch: $branch"
		echo "  arch: $arch"
		echo "  version: $current"
		echo "  flavor: $flavor"
		echo "  file: $file"
		echo "  iso: $file"	# for compat
		echo "  date: $date"
		echo "  time: $time"
		echo "  size: $size"
		echo "  sha1: $sha1"
		echo "  sha256: $sha256"
		echo "  sha512: $sha512"
	done
}

do_stat || exit 1
do_stat > .latest.txt

do_yaml > latest-releases.yaml

