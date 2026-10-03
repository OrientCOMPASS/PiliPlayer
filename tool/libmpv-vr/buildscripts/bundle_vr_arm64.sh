#!/bin/bash -e
# Build the VR-patched libmpv.so (arm64-v8a) and assemble the media_kit
# Android jar around it.
#
# Strategy: build ONLY libmpv.so from patched sources (patches/mpv/*), then
# take the official media_kit jar pinned by the app
# (My-Responsitories/libmpv-android-video-build release 20260906, built from
# upstream commit 8e50ecc which this buildscripts/ tree is copied from) and
# replace its lib/arm64-v8a/libmpv.so with ours. The other native libraries
# in the jar (libmedia_kit_native_event_loop.so, libmediakitandroidhelper.so)
# stay byte-identical to what the app already ships, so the only runtime
# difference is mpv itself.
#
# Output: ../output/default-arm64-v8a.jar (+ .sha256)

set -euo pipefail
cd "$( dirname "${BASH_SOURCE[0]}" )"

UPSTREAM_TAG=20260906
UPSTREAM_JAR_URL="https://github.com/My-Responsitories/libmpv-android-video-build/releases/download/${UPSTREAM_TAG}/default-arm64-v8a.jar"
UPSTREAM_JAR_SHA256="98df6410375cc7a4be7e6eff56f9ccd88fa52678973cc23bcf7e934ab8c8682d"

# --------------------------------------------------
# 1. deps + patches + build (arm64 only)

./download.sh
./patch.sh

# sanity: the VR patches must have applied (patch.sh does git apply; a failed
# hunk would already abort, but check the files/needles exist too)
test -f deps/mpv/video/out/gpu/vr.c
test -f deps/mpv/video/out/gpu/vr_tracker.c
grep -q "vr-head-tracking" deps/mpv/video/out/gpu/video.c
grep -q "vr_manual_angles" deps/mpv/video/out/gpu/vr.c
# VR_DUMB_FIX: VR must opt out of voluntary dumb mode, otherwise media_kit's
# default options (bilinear/no-dither) put every Android playback in dumb mode
# and the VR branch in pass_draw_to_screen never runs (flat 2D forever).
grep -q "VR_DUMB_FIX" deps/mpv/video/out/gpu/video.c
# VR_GYRO_CONT: gyro on/off must not jump the view (reference sampling with
# exact continuation + head-pose fold into manual bias on disable).
grep -q "VR_GYRO_CONT" deps/mpv/video/out/gpu/vr.c
# metadata patch (vr-metadata-* properties + demux_lavf spherical/stereo3d)
grep -q "mp_vr_projection_from_spherical" deps/mpv/demux/demux_lavf.c
grep -q "vr-metadata-projection" deps/mpv/player/command.c
# ffmpeg smb:// protocol via libsmb2 (VLC-parity LAN playback, no loopback
# HTTP proxy: seeks are positioned reads, quit closes the socket outright)
grep -q "ff_libsmb2_protocol" deps/ffmpeg/libavformat/libsmb2.c
# SMB2_BLANK_PW: blank-password accounts must authenticate with NTLM over the
# empty password; libsmb2 treats a NULL password as anonymous login, which
# Windows/NAS reject with STATUS_INVALID_PARAMETER (round-15 device log).
grep -q "SMB2_BLANK_PW" deps/ffmpeg/libavformat/libsmb2.c
grep -q "enable-libsmb2" flavors/default.sh
# round 15: packed vr-view property (single round trip per drag batch) and
# effective-angle HUD properties
grep -q "vr_parse_view_string" deps/mpv/video/out/gpu/video.c
grep -q "VOCTRL_VR_VIEW_ANGLES" deps/mpv/player/command.c

cp flavors/default.sh scripts/ffmpeg.sh
./build.sh mpv --arch arm64

NEW_SO="../libmpv/src/main/jniLibs/arm64-v8a/libmpv.so"
test -f "$NEW_SO"
ls -la "$NEW_SO"

# sanity: VR options must be compiled into the library
if ! strings -a "$NEW_SO" | grep -q "vr-head-tracking"; then
    echo "FATAL: libmpv.so does not contain the VR options" >&2
    exit 1
fi
# the metadata properties (from vr_metadata.patch) must be present too
if ! strings -a "$NEW_SO" | grep -q "vr-metadata-projection"; then
    echo "FATAL: libmpv.so does not contain the vr-metadata-* properties" >&2
    exit 1
fi
# the ffmpeg smb:// protocol (patches/ffmpeg/libsmb2.patch) must be compiled in
if ! strings -a "$NEW_SO" | grep -q "Malformed smb:// url"; then
    echo "FATAL: libmpv.so does not contain the libsmb2 smb:// protocol" >&2
    exit 1
fi
if ! strings -a "$NEW_SO" | grep -q "vr-view-yaw"; then
    echo "FATAL: libmpv.so does not contain the vr-view-* HUD properties" >&2
    exit 1
fi
# libsmb2 must be linked STATICALLY (the jar ships no extra .so files)
if readelf -d "$NEW_SO" | grep NEEDED | grep -qi "smb2"; then
    echo "FATAL: libmpv.so has a dynamic dependency on libsmb2" >&2
    exit 1
fi
echo "libmpv.so contains VR options + metadata properties + smb:// protocol ✓"

# --------------------------------------------------
# 2. jar assembly: upstream jar with our libmpv.so swapped in

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

wget -q "$UPSTREAM_JAR_URL" -O "$work/upstream.jar"
echo "$UPSTREAM_JAR_SHA256  $work/upstream.jar" | sha256sum -c -
(cd "$work" && unzip -q upstream.jar)

cp -L "$NEW_SO" "$work/lib/arm64-v8a/libmpv.so"

mkdir -p ../output
rm -f ../output/default-arm64-v8a.jar
# NOTE: entries must keep the lib/<abi>/ prefix (AGP native-libs-in-jar
# convention, same as the upstream jar) — zipping from $work, not $work/lib.
(cd "$work" && zip -q -r default-arm64-v8a.jar lib/arm64-v8a)
mv "$work/default-arm64-v8a.jar" ../output/default-arm64-v8a.jar

# verify the layout before publishing: AGP silently ignores jars whose native
# entries lack the lib/ prefix, which would ship an APK without libmpv.so
unzip -l ../output/default-arm64-v8a.jar | grep -q "lib/arm64-v8a/libmpv.so"
unzip -l ../output/default-arm64-v8a.jar | grep -q "lib/arm64-v8a/libmedia_kit_native_event_loop.so"
unzip -l ../output/default-arm64-v8a.jar | grep -q "lib/arm64-v8a/libmediakitandroidhelper.so"
test "$(unzip -l ../output/default-arm64-v8a.jar | tail -1 | awk '{print $2}')" = "4"

(cd ../output && sha256sum default-arm64-v8a.jar | tee default-arm64-v8a.jar.sha256)
unzip -l ../output/default-arm64-v8a.jar

echo "OK: ../output/default-arm64-v8a.jar"
