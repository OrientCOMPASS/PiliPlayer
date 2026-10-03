#!/bin/bash -e

# Dependency sources for the VR libmpv build (arm64-v8a only, default flavor).
# Trimmed from upstream My-Responsitories/libmpv-android-video-build
# download-deps.sh @ 8e50ecc (the state that produced the 20260906 release
# the app pins): no encoders-gpl deps (libvpx/libx264/fftools_ffi), no
# media_kit / media-kit-android-helper clones (the final jar keeps those
# .so files from the upstream jar and only swaps libmpv.so, see
# bundle_vr_arm64.sh), no shaderc stub (not a dep of the default flavor).

. ./include/depinfo.sh

[ -z "$WGET" ] && WGET=wget

set -euo pipefail

mkdir -p deps && cd deps

git config --global advice.detachedHead false

# mbedtls
[ ! -d mbedtls ] && git clone --depth 1 --branch v$v_mbedtls --recurse-submodules --shallow-submodules https://github.com/Mbed-TLS/mbedtls.git mbedtls

# dav1d
[ ! -d dav1d ] && git clone --depth 1 --branch $v_dav1d https://code.videolan.org/videolan/dav1d.git dav1d

# ffmpeg
[ ! -d ffmpeg ] && git clone --depth 1 --branch n$v_ffmpeg https://github.com/FFmpeg/FFmpeg.git ffmpeg

# libsmb2 (SMB2/3 client for ffmpeg's smb:// protocol - the same library
# VLC's smb access module uses; see patches/ffmpeg/libsmb2.patch)
[ ! -d libsmb2 ] && git clone --depth 1 --branch libsmb2-$v_libsmb2 https://github.com/sahlberg/libsmb2.git libsmb2

# freetype2
[ ! -d freetype ] && git clone --depth 1 --branch VER-$v_freetype https://gitlab.freedesktop.org/freetype/freetype.git freetype

# fribidi
[ ! -d fribidi ] && git clone --depth 1 --branch v$v_fribidi https://github.com/fribidi/fribidi.git fribidi

# harfbuzz
[ ! -d harfbuzz ] && git clone --depth 1 --branch $v_harfbuzz https://github.com/harfbuzz/harfbuzz.git harfbuzz

# libass
[ ! -d libass ] && git clone --depth 1 --branch $v_libass https://github.com/libass/libass.git libass

# libwebp
[ ! -d libwebp ] && git clone --depth 1 --branch v$v_libwebp https://github.com/webmproject/libwebp libwebp

# libplacebo
[ ! -d libplacebo ] && git clone --depth 1 --branch v$v_libplacebo --recurse-submodules --shallow-submodules https://code.videolan.org/videolan/libplacebo.git libplacebo

# mpv
[ ! -d mpv ]  && git clone --depth 1 --branch v$v_mpv https://github.com/mpv-player/mpv.git mpv

cd ..
