#!/bin/bash -e

set -euo pipefail

PATCHES=(patches/*)
ROOT=$(pwd)

for dep_path in "${PATCHES[@]}"; do
    if [ -d "$dep_path" ]; then
        patches=($dep_path/*)
        dep=$(echo $dep_path |cut -d/ -f 2)
        # [PiliPlus] Content-hash stamp: deps/ is reused via actions/cache, and
        # since ffmpeg now also carries a patch, unconditionally resetting it
        # would force a full ffmpeg rebuild even when only mpv patches changed.
        # Skip re-patching (and keep the previous build tree for incremental
        # ninja/make) when the patch content is unchanged since last apply.
        stamp=$(cat "$ROOT/$dep_path"/* | md5sum | cut -d' ' -f1)
        cd deps/$dep
        marker=.pili_patch_stamp
        if [ -f "$marker" ] && [ "$(cat "$marker")" == "$stamp" ]; then
            echo "Patches for $dep unchanged ($stamp), keeping tree as-is"
            cd $ROOT
            continue
        fi
        echo Patching $dep
        git reset --hard
        # [PiliPlus] deps 目录被 actions/cache 复用时, 上一次应用补丁产生的
        # 新增文件(vr.c/vr.h/vr_tracker.* 与 ffmpeg 的 libsmb2.c 是补丁新增
        # 的, 不在 git 索引里)不会被 reset --hard 清掉, 再次 git apply 会报
        # already exists, 所以先 clean(代价是该依赖本次全量重编)。
        git clean -fdx
        for patch in "${patches[@]}"; do
            echo Applying $patch
            git apply "$ROOT/$patch"
        done
        echo "$stamp" > "$marker"
        cd $ROOT
    fi
done

exit 0
