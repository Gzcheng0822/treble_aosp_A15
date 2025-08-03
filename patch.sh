#!/bin/bash
set -e

# 参数说明
PATCH_ROOT="$(readlink -f -- "$1")"  # 补丁根目录，例如 /root/aosp/treble_aosp
TREE="$2"                            # 补丁集目录名，例如 trebledroid、personal 等

# 定位源码根目录（projects 目录下）
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$MAIN_DIR/projects"
cd "$SOURCE_ROOT" || {
    echo "❌ 无法进入源码目录: $SOURCE_ROOT"
    exit 1
}

PATCH_DIR="$PATCH_ROOT/patches/$TREE"
PATCH_LIST_FILE="$SOURCE_ROOT/patch.list"

if [ ! -d "$PATCH_DIR" ]; then
    echo "⚠️ 补丁目录不存在: $PATCH_DIR，跳过 $TREE"
    exit 0
fi

echo "📦 当前补丁目录: $PATCH_DIR"
[ -f "$PATCH_LIST_FILE" ] && echo "📋 检测到补丁列表: $PATCH_LIST_FILE"

# ========== 构建待应用补丁项目列表 ==========
declare -a project_list

if [ -f "$PATCH_LIST_FILE" ]; then
    while IFS= read -r entry; do
        [[ "$entry" =~ ^#.*$ || -z "$entry" ]] && continue
        [[ "$entry" != "$TREE/"* ]] && continue
        project=$(echo "$entry" | cut -d/ -f2-)
        [ -d "$PATCH_DIR/$project" ] && project_list+=("$project")
    done < "$PATCH_LIST_FILE"
else
    project_list=($(cd "$PATCH_DIR"; echo *))
fi

# ========== 开始应用补丁 ==========
total_patches=$(find "$PATCH_DIR" -type f -name "*.patch" ! -name "*.patch.disable" | wc -l)
count=0

for project in "${project_list[@]}"; do
    p="$(tr _ / <<<"$project" | sed -e 's;platform/;;g')"
    [ "$p" == build ] && p=build/make
    [ "$p" == treble/app ] && p=treble_app
    [ "$p" == vendor/hardware/overlay ] && p=vendor/hardware_overlay

    patch_subdir="$PATCH_DIR/$project"
    [ ! -d "$patch_subdir" ] && continue
    [ -z "$(ls -A "$patch_subdir" 2>/dev/null)" ] && continue

    if [ ! -d "$p" ]; then
        echo -e "\n⚠️ 跳过项目 $p：源码目录不存在"
        continue
    fi

    pushd "$p" > /dev/null

    for patch in "$patch_subdir"/*.patch; do
        if [ -f "$patch" ] && [[ "$patch" != *.patch.disable ]]; then
            count=$((count + 1))
            printf "\r--> 正在应用第 %d/%d 个补丁: %s" "$count" "$total_patches" "$(basename "$patch")"
            git am -q "$patch" || {
                echo -e "\n❌ 补丁应用失败: $patch"
                exit 1
            }
        fi
    done

    popd > /dev/null
done

echo  # 美化输出
echo "✅ 补丁应用完成：已应用 $count / $total_patches"
