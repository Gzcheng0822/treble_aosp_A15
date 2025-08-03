#!/bin/bash
set -e

# 目录设定
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="/root/aosp"
SOURCE_ROOT="$WORK_DIR/projects"
BUILD_ROOT="$WORK_DIR/treble_aosp"
OUTPUT_DIR="$WORK_DIR/output"
PATCH_SH="$BUILD_ROOT/patch_quite.sh"

# 日志记录
log_file="$BUILD_ROOT/build_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$log_file") 2>&1

# 处理命令行参数
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -v|--vanilla)
            VARIANT_VANILLA=true
            ;;
        -t|--trebleapp)
            INCLUDE_TREBLEAPP=true
            ;;
        *)
            echo "未知参数: $1"
            echo "用法: $0 [-v] [-t]"
            exit 1
            ;;
    esac
    shift
done

export BUILD_NUMBER="$(date +%y%m%d)"
START=$(date +%s)

# 检查目录
checkPaths() {
    echo "--> 检查必要目录和文件是否存在..."

    local missing=()

    # 必要目录
    local dirs=(
        "$WORK_DIR"
        "$SOURCE_ROOT"
        "$BUILD_ROOT"
        "$OUTPUT_DIR"
        "$BUILD_ROOT/build"
    )

    for dir in "${dirs[@]}"; do
        [ ! -d "$dir" ] && missing+=("目录: $dir")
    done

    # 必要文件
    local files=(
        "$BUILD_ROOT/build/default.xml"
        "$BUILD_ROOT/build/remove.xml"
        "$PATCH_SH"
    )

    for file in "${files[@]}"; do
        [ ! -f "$file" ] && missing+=("文件: $file")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[ERROR] 以下文件或目录不存在："
        for item in "${missing[@]}"; do
            echo "  - $item"
        done
        exit 1
    fi

    echo "所有目录和文件检查通过。"
    echo
}

# 检查软件包
checkSystemPackage() {
    echo "--> 检查软件包..."
    local packages=(git git-lfs zipalign unzip zip ccache jq xz-utils flex bison gcc-multilib g++-multilib libc6-dev-i386 libncurses5-dev lib32ncurses-dev x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc)
    local missing=()
    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺失软件包：${missing[*]}"
        sudo apt-get update || true
        sudo apt-get install -y "${missing[@]}"
    else
        echo "所有软件包已安装"
    fi
    echo
}

# 检查 Java_11
check_java11() {
    echo "--> 检查 Java 版本..."

    local CURRENT_JAVA_VER
    CURRENT_JAVA_VER=$(java -version 2>&1 | grep "version" | awk -F '"' '{print $2}' | cut -d. -f1)

    if [[ "$CURRENT_JAVA_VER" != "11" ]] || [[ ! -x "/usr/lib/jvm/java-11-openjdk-amd64/bin/jlink" ]]; then
        echo "当前 Java 版本为 $CURRENT_JAVA_VER 或 jlink 缺失，安装完整 OpenJDK 11"

        sudo apt-get update -qq
        sudo apt-get install -y openjdk-11-jdk

        echo "设置为默认 Java 版本..."
        sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-11-openjdk-amd64/bin/java 1111
        sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-11-openjdk-amd64/bin/javac 1111
        sudo update-alternatives --install /usr/bin/jlink jlink /usr/lib/jvm/java-11-openjdk-amd64/bin/jlink 1111

        sudo update-alternatives --set java /usr/lib/jvm/java-11-openjdk-amd64/bin/java
        sudo update-alternatives --set javac /usr/lib/jvm/java-11-openjdk-amd64/bin/javac
        sudo update-alternatives --set jlink /usr/lib/jvm/java-11-openjdk-amd64/bin/jlink
    else
        echo "当前已是 Java 11 且 jlink 可用"
    fi
    echo
}

fixGappsLfs() {
    echo "--> 确保 GApps APK LFS 内容完整"
    pushd "$SOURCE_ROOT/vendor/gapps/common" >/dev/null
    git lfs install
    git lfs pull
    git lfs checkout
    popd >/dev/null
}

# 磁盘空间检查
checkDiskSpace() {
    echo "--> 磁盘空间检查"

    local avail_kb=$(df -k . | awk 'NR==2 {print $4}')
    if [ "$avail_kb" -lt 250000000 ]; then
        echo -e "\n磁盘空间不足（当前：$(df -h . | awk 'NR==2 {print $4}')）"
        exit 1
    fi
    echo "检查通过"
    echo
}

cleanVendorPoncesPriv() {
    local xml="$BUILD_ROOT/build/default.xml"
    if grep -q "ponces/vendor_ponces-priv" "$xml"; then
        echo "清理 default.xml 中的 vendor_ponces-priv 项"
        sed -i '/ponces\/vendor_ponces-priv/d' "$xml"
    fi
}

initRepos() {
    echo "--> 初始化 repo"
    cd "$SOURCE_ROOT"
    if [ ! -d .repo ]; then
        repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r36 --depth=1 --config-name
    fi
    mkdir -p .repo/local_manifests
    cp -f "$BUILD_ROOT/build/default.xml" .repo/local_manifests/default.xml
    cp -f "$BUILD_ROOT/build/remove.xml" .repo/local_manifests/remove.xml
    cd "$WORK_DIR"
    echo
}

syncRepos() {
    echo "--> 同步源码"
    cd "$SOURCE_ROOT"
    for jobs in 32 16 8; do
        echo "尝试 repo sync -j$jobs..."
        if repo sync -c --no-clone-bundle --no-tags -j$jobs; then
            echo "同步成功"
            break
        fi
        sleep 10
    done
    cd "$WORK_DIR"
    echo
}

applyPatches() {
    echo "--> 应用补丁"
    bash "$PATCH_SH" "$BUILD_ROOT" trebledroid
    bash "$PATCH_SH" "$BUILD_ROOT" personal
    cd "$SOURCE_ROOT/device/phh/treble"
    cp "$BUILD_ROOT/build/aosp.mk" .
    bash generate.sh aosp
    cd "$WORK_DIR"
    echo
}

setupEnv() {
    echo "--> 设置构建环境"
    cd "$SOURCE_ROOT"
    source build/envsetup.sh

    echo "启用 ccache"
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)

    export CCACHE_DIR=$SOURCE_ROOT/out/.ccache
    export CCACHE_TEMPDIR=$CCACHE_DIR/tmp
    mkdir -p "$CCACHE_TEMPDIR"

    export CC="ccache /root/aosp/projects/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang"
    export CXX="ccache /root/aosp/projects/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang++"

    echo "设置 ccache 缓存上限为 200G..."
    ccache -M 200G || true

    echo "CC=$CC"
    echo "CXX=$CXX"
    echo "CCACHE_DIR=$CCACHE_DIR"
    ccache -p | grep dir

    mkdir -p "$OUTPUT_DIR"
    cd "$WORK_DIR"
    echo
}

zipalignGapps() {
    echo "--> zipalign 所有 GApps APK"
    local count=0
    local apk_list
    apk_list=$(find projects/vendor/gapps/common/proprietary -name "*.apk")
    echo "找到以下 APK："
    echo "$apk_list"

    while IFS= read -r apk; do
        if file "$apk" | grep -qv 'Zip archive\|Java archive'; then
            echo "跳过无效 APK：$apk"
            continue
        fi
        if ! zipalign -c -p 4 "$apk" &>/dev/null; then
            if zipalign -p -f 4 "$apk" "$apk.aligned" 2>/dev/null; then
                mv "$apk.aligned" "$apk"
                echo "zipaligned: $apk"
                ((count++))
            else
                echo "zipalign 失败: $apk"
            fi
        fi
    done <<< "$apk_list"

    echo "共处理 $count 个 APK"
    echo
}

buildTrebleApp() {
    echo "--> 编译 TrebleApp"
    cd "$SOURCE_ROOT/treble_app"
    bash build.sh release
    cp TrebleApp.apk "$SOURCE_ROOT/vendor/hardware_overlay/TrebleApp/app.apk"
    cd "$WORK_DIR"
    echo
}

buildVariant() {
    echo "--> 编译 $1"
    cd "$SOURCE_ROOT"

    output_img="$OUTPUT_DIR/system-$1.img"
    if [[ -f "$output_img" ]]; then
        echo "检测到已构建镜像 $output_img，跳过构建"
        return
    fi

    lunch "$1"-bp1a-userdebug
    make -j$(nproc) installclean
    make -j$(nproc) systemimage
    make -j$(nproc) target-files-package otatools

    img_source="$OUT/target/product/tdgsi_arm64_ab/obj/PACKAGING/system_intermediates/system.img"
    if [[ ! -f "$img_source" ]]; then
        echo "未找到系统镜像 $img_source"
        exit 1
    fi

    cp "$img_source" "$output_img"
    echo "导出系统镜像为 $output_img"

    cd "$WORK_DIR"
    echo
}

buildVariants() {
    if [[ "$VARIANT_VANILLA" == true ]]; then
        echo "编译 Vanilla + GApps 两个版本"
        buildVariant treble_arm64_bvN
        buildVariant treble_arm64_bgN
    else
        echo "仅编译 GApps 版本"
        buildVariant treble_arm64_bgN
    fi
}

# ========== 主流程 ==========
echo "--------------------------------------"
echo "       AOSP 15.0 自动编译脚本（v10）     "
echo "          Modified By Gzcheng         "
echo "--------------------------------------"

# 

# 检查目录
checkPaths
# 检查软件包
checkSystemPackage
# 检查 Java_11
check_java11
# 磁盘空间检查
checkDiskSpace


END=$(date +%s)
ELAPSED=$((END - START))
echo "构建完成，用时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
