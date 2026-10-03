#!/bin/bash -e

# libsmb2 — small LGPL SMB2/3 client (the library VLC's smb access uses).
# Built STATIC + PIC so it links into libmpv.so without adding another
# runtime .so to the jar. ffmpeg picks it up via --enable-libsmb2
# (patches/ffmpeg/libsmb2.patch adds the smb:// URLProtocol on top).

. ../../include/depinfo.sh
. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

$0 clean # separate building not supported, always clean

mkdir -p $build
cd $build

cmake .. \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DENABLE_LIBKRB5=OFF \
	-DENABLE_GSSAPI=OFF \
	-DENABLE_EXAMPLES=OFF \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_PREFIX_PATH="$prefix_dir"

make -j$cores
make DESTDIR="$prefix_dir" install

# [PiliPlus] Upstream's installed headers are not self-contained for outside
# consumers: <stdint.h>/<time.h> sit behind the library's own HAVE_* defines
# and libsmb2.h expects smb2.h (GUID/lease types) to have been included
# first. ffmpeg's configure compiles a single-header probe, so make the
# installed headers standalone here (idempotent, marker-guarded).
for h in "$prefix_dir"/include/smb2/*.h; do
	if ! head -1 "$h" | grep -q PILI_SELF_CONTAINED; then
		sed -i '1i /* PILI_SELF_CONTAINED */\n#include <stddef.h>\n#include <stdint.h>\n#include <time.h>' "$h"
	fi
done
h="$prefix_dir/include/smb2/libsmb2.h"
if ! grep -q PILI_SMB2_UMBRELLA "$h"; then
	sed -i '2i /* PILI_SMB2_UMBRELLA */\n#include <smb2/smb2.h>' "$h"
fi

# sanity: the pkg-config file ffmpeg's configure will use must exist
test -f "$prefix_dir"/lib/pkgconfig/libsmb2.pc
