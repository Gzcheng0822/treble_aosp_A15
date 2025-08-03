#!/bin/bash
set -e

PATCH_ROOT="$(readlink -f -- "$1")"  # 即 /root/aosp/treble_aosp
TREE="$2"                            # 比如 trebledroid 或 personal

MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$MAIN_DIR/projects"
cd "$SOURCE_ROOT" || {
    echo "❌ 无法进入源码目录: $SOURCE_ROOT"
    exit 1
}

PATCH_DIR="$PATCH_ROOT/patches/$TREE"
if [ ! -d "$PATCH_DIR" ]; then
    echo "⚠️ 跳过补丁：目录不存在 $PATCH_DIR"
    exit 0
fi

total_patches=$(find "$PATCH_DIR" -type f -name "*.patch" ! -name "*.patch.disable" | wc -l)
count=0

for project in $(cd "$PATCH_DIR"; echo *); do
    p="$(tr _ / <<<"$project" | sed -e 's;platform/;;g')"
    [ "$p" == build ] && p=build/make
    [ "$p" == treble/app ] && p=treble_app
    [ "$p" == vendor/hardware/overlay ] && p=vendor/hardware_overlay

    patch_subdir="$PATCH_DIR/$project"
    [ ! -d "$patch_subdir" ] && continue

    if [ -z "$(ls -A "$patch_subdir")" ]; then
        continue
    fi

    if [ ! -d "$p" ]; then
        echo -e "\n⚠️ 跳过项目 $p：目录不存在"
        continue
    fi

    pushd "$p" > /dev/null

    for patch in "$patch_subdir"/*.patch; do
        if [ -f "$patch" ] && [[ "$patch" != *.patch.disable ]]; then
            count=$((count + 1))
            printf "\r--> 正在应用第 %d/%d 个补丁: %s" "$count" "$total_patches" "$(basename "$patch")"
            git am -q "$patch" || exit 1
        fi
    done

    popd > /dev/null
done

echo  # 换行美化输出
