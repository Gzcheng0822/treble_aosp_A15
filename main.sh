#!/bin/bash
set -e

# 目录设定
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="$MAIN_DIR/repo"
PROJECT_MAIN_PATH="$MAIN_DIR/projects"
BUILD_PATH="$MAIN_DIR/treble_aosp"
PATCH_SH="$MAIN_DIR/patch.sh"
PROJECTS_PATH=""

# 日志记录
log_file="$MAIN_DIR/log_$(date +%Y%m%d_%H%M%S).log"
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

# 检查目录
checkPaths() {
    echo "--> 检查必要目录和文件是否存在..."

    local missing=()

    # 必要目录
    local dirs=(
        "$MAIN_DIR"
		"$REPO_PATH"
        "$PROJECT_MAIN_PATH"
    )

    for dir in "${dirs[@]}"; do
        [ ! -d "$dir" ] && missing+=("目录: $dir")
    done

    # 必要文件
    local files=(
        "$BUILD_PATH/build/default.xml"
        "$BUILD_PATH/build/remove.xml"
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

# 检查最终 zip 是否已存在
checkFinalZIP() {
    local final_zip_dir="$MAIN_DIR/zip"

    if ls "$final_zip_dir"/*.zip >/dev/null 2>&1; then
        echo "已检测到存在已构建的 zip 文件：$final_zip_dir"
        read -p "是否重新编译？(y/N): " confirm
        case "$confirm" in
            [yY]|[yY][eE][sS])
                echo "继续执行编译流程..."
                ;;
            *)
                echo "跳过构建流程。"
                exit 0
                ;;
        esac
    fi
}


# 检查磁盘空间
checkDiskSpace() {
    echo "--> 磁盘空间检查"

    local avail_kb=$(df -k . | awk 'NR==2 {print $4}')
    if [ "$avail_kb" -lt 250000000 ]; then
        echo -e "\n磁盘空间不足（当前：$(df -h . | awk 'NR==2 {print $4}')）"
        exit 1
    fi
    echo "剩余磁盘空间为$(df -h . | awk 'NR==2 {print $4}') 检查通过"
    echo
}

# 初始化 repo
initMainRepo() {
    echo "--> 初始化主 repo 仓库（路径: $REPO_PATH）"

    # 先确保 REPO_PATH 目录存在
    if [ ! -d "$REPO_PATH" ]; then
        mkdir -p "$REPO_PATH"
    fi

    # 再进入目录
    cd "$REPO_PATH"

    # 检查 .repo 是否已存在，避免重复 init
    if [ ! -d ".repo" ]; then
        echo "执行 repo init..."
        repo init -u https://android.googlesource.com/platform/manifest \
                  -b android-15.0.0_r36 \
                  --git-lfs --config-name

        mkdir -p .repo/local_manifests
        cp -f "$BUILD_PATH/build/default.xml" .repo/local_manifests/default.xml
        cp -f "$BUILD_PATH/build/remove.xml" .repo/local_manifests/remove.xml
    else
        echo "✅ 主 repo 已存在，跳过初始化"
    fi

    echo
}

# 项目选择器
chooseProjectBuild() {
    echo "--> 选择项目子目录进行构建"
    mkdir -p "$PROJECT_MAIN_PATH"
    echo "当前可用项目目录："
    find "$PROJECT_MAIN_PATH" -maxdepth 1 -mindepth 1 -type d | sed "s|^$PROJECT_MAIN_PATH/|- |"
    echo

    read -p "请输入你要使用或创建的项目目录名（如 vanilla, patched): " subdir
    subdir=$(echo "$subdir" | tr -cd '[:alnum:]_-')
    [[ -z "$subdir" ]] && { echo "[错误] 子目录名不能为空！"; exit 1; }

    PROJECTS_PATH="$PROJECT_MAIN_PATH/$subdir"

    if [ ! -d "$PROJECTS_PATH" ]; then
        echo "创建项目目录：$PROJECTS_PATH"
        rsync -a --exclude='.repo' "$REPO_PATH/" "$PROJECTS_PATH/"
    else
        echo "使用已有项目目录：$PROJECTS_PATH"
        read -p "是否重新覆盖主 repo 源码到此目录？(y/N): " replace_confirm
        if [[ "$replace_confirm" =~ ^[yY]$ ]]; then
            echo "→ 正在重新复制主 repo 内容…"
            rsync -a --delete --exclude='.repo' "$REPO_PATH/" "$PROJECTS_PATH/"
        fi
    fi

    # —— 验证关键文件，必要时自动重复制 —— #
    if [ ! -f "$PROJECTS_PATH/build/envsetup.sh" ]; then
        echo "⚠️ 缺失 build/envsetup.sh，自动重新复制源码…"
        rsync -a --delete --exclude='.repo' "$REPO_PATH/" "$PROJECTS_PATH/"
        echo "✅ 复制完成"
    fi

    echo
}


# 检查 主repo状态
doMainRepo() {
    echo "--> 检查主 repo 状态完整性..."

    local need_init=false
    local need_sync=false

    # ===== 检查是否已初始化 .repo =====
    if [ ! -d "$REPO_PATH/.repo" ]; then
        echo "⚠️ 未发现 .repo 目录，尚未 init"
        need_init=true
    fi

    # ===== 执行初始化 =====
    if [ "$need_init" = true ]; then
        echo "→ 初始化主 repo..."
        initMainRepo
    fi

    # ===== 检查关键目录完整性 =====
    echo "→ 检查关键目录完整性..."
    local critical_paths=(
        "$REPO_PATH/build/envsetup.sh"
        "$REPO_PATH/prebuilts/go/linux-x86/bin/go"
        "$REPO_PATH/frameworks/base"
        "$REPO_PATH/system/core"
        "$REPO_PATH/device"
        "$REPO_PATH/hardware"
        "$REPO_PATH/external"
    )

    local missing_critical=0
    for path in "${critical_paths[@]}"; do
        if [ ! -e "$path" ]; then
            echo "❌ 缺失关键路径: $path"
            missing_critical=$((missing_critical + 1))
        fi
    done
    [ "$missing_critical" -gt 0 ] && need_sync=true

    # ===== 检查所有项目 Git 仓库和源码目录 =====
    echo "→ 检查所有项目 Git 仓库与源码目录..."
    local missing_git=0
    local missing_checkout=0
    local total_checked=0

    cd "$REPO_PATH" || exit 1
    while IFS= read -r proj; do
        proj_path="$REPO_PATH/$proj"
        proj_git="$REPO_PATH/.repo/projects/$proj.git"

        [ ! -d "$proj_git" ] && {
            echo "❌ Git 仓库缺失: $proj_git"
            missing_git=$((missing_git + 1))
        }

        [ ! -d "$proj_path" ] && {
            echo "⚠️ 源码目录缺失: $proj_path"
            missing_checkout=$((missing_checkout + 1))
        }

        total_checked=$((total_checked + 1))
    done < <(repo list -p)

    echo "→ 已检查 $total_checked 个项目："
    echo "   - 缺失 Git 仓库：$missing_git"
    echo "   - 缺失源码目录：$missing_checkout"

    if [ "$missing_git" -gt 0 ] || [ "$missing_checkout" -gt 0 ]; then
        need_sync=true
    fi

    # ===== 用户交互：是否同步 =====
    if [ "$need_sync" = true ]; then
        echo "⚠️ 主 repo 不完整。"

        echo "你可以选择以下操作："
        echo "  [y] 重新同步 repo"
        echo "  [s] 跳过此步（不推荐）"
        echo "  [n] 退出脚本"
        echo -n "你的选择 (y/s/n): "
        read -r decision

        case "$decision" in
            [yY])
                echo "→ 正在重新同步主 repo..."
                syncMainRepo
                ;;
            [sS])
                echo "→ 跳过同步（注意：构建可能失败）"
                ;;
            *)
                echo "→ 用户选择退出脚本"
                exit 1
                ;;
        esac
    else
        echo "✅ 主 repo 完整性检查通过"
    fi

    echo
}




syncMainRepo() {
    echo "--> 同步主 repo 源码：$REPO_PATH"
    cd "$REPO_PATH"

    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "尝试 repo sync -j16...（第 $attempt 次）"
        if repo sync -c --no-clone-bundle --no-tags -j16; then
            echo "✅ 主 repo 同步成功"
            return 0
        else
            echo "⚠️ 第 $attempt 次同步失败"
            sleep 10
        fi
        attempt=$((attempt + 1))
    done

    echo "❌ 连续 $max_attempts 次同步失败，可能是网络或远程仓库问题。"
    echo "请检查网络连接或尝试更换镜像。"
    echo "是否重试同步？(y 重试 / n 退出 / s 跳过)"
    read -r choice
    case "$choice" in
        [yY])
            syncMainRepo  # 递归调用重试
            ;;
        [sS])
            echo "⚠️ 跳过同步，后续可能构建失败。"
            ;;
        *)
            echo "退出脚本。"
            exit 1
            ;;
    esac
}



# 应用补丁
applyPatches() {
    echo "--> 准备应用补丁"

    local patch_flag="$PROJECTS_PATH/.patch_applied"

    if [ -f "$patch_flag" ]; then
        echo "检测到补丁已应用，跳过此步骤。"
        return
    fi

    read -p "是否应用补丁？(Y/n): " confirm
    case "$confirm" in
        [nN]|[nN][oO])
            echo "用户选择跳过补丁。"
            return
            ;;
    esac

    echo "--> 应用补丁"
    bash "$PATCH_SH" "$BUILD_PATH" trebledroid
    bash "$PATCH_SH" "$BUILD_PATH" personal

    cd "$PROJECTS_PATH/device/phh/treble" || exit 1
    cp "$BUILD_PATH/build/aosp.mk" .
    bash generate.sh aosp
    cd "$MAIN_DIR"

    # 标记补丁已完成
    touch "$patch_flag"
    echo "补丁已应用完成。"
    echo
}

# 配置ccache
configureCcache() {
    echo "启用 ccache"
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)

    export CCACHE_DIR=$PROJECTS_PATH/.ccache
    export CCACHE_TEMPDIR=$CCACHE_DIR/tmp
    mkdir -p "$CCACHE_TEMPDIR"

    export CC="ccache $PROJECTS_PATH/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang"
    export CXX="ccache $PROJECTS_PATH/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang++"

    ccache -M 200G > /dev/null 2>&1 || true

    echo "当前 ccache 路径为：$CCACHE_DIR，已成功启用。"
}


# 设置环境
setupEnv() {
    echo "--> 设置构建环境"
    cd "$PROJECTS_PATH"
    source build/envsetup.sh
	
	configureCcache

    echo
}

# 编译配置
buildSystemImg() {
    echo "--> 编译 $1"
    cd "$PROJECTS_PATH"

    lunch "$1"-bp1a-userdebug
    make -j$(nproc) installclean
    make -j$(nproc) systemimage
    make -j$(nproc) target-files-package otatools
	
    cd "$MAIN_DIR"
    echo
}

# 编译系统变种
buildVariants() {
    if [[ "$VARIANT_VANILLA" == true ]]; then
        echo "编译 Vanilla + GApps 两个版本"
        buildSystemImg treble_arm64_bvN
        buildSystemImg treble_arm64_bgN
    else
        echo "仅编译 GApps 版本"
        buildSystemImg treble_arm64_bgN
    fi
}

# 移动并重命名已构建的 .zip 镜像
collectFinalZIP() {
	local search_root="$PROJECTS_PATH/out/target/product/tdgsi_arm64_ab/obj/PACKAGING/target_files_intermediates"
    if [ ! -d "$search_root" ]; then
		echo "⚠️ 构建输出目录未找到：$search_root"
		return 1
	fi
    local dest_dir="$MAIN_DIR/zip"
    local timestamp
    local zip_list

    echo "正在扫描 $search_root 目录以查找 .zip 文件..."

    zip_list=$(find "$search_root" -type f -name "*.zip" 2>/dev/null)

    if [ -z "$zip_list" ]; then
        echo "未找到任何 .zip 文件。"
        return 1
    fi

    mkdir -p "$dest_dir"
    timestamp=$(date "+%Y%m%d_%H%M%S")

    while IFS= read -r zip_file; do
        [ -z "$zip_file" ] && continue

        local base_name new_name dest_zip
        base_name=$(basename "$zip_file")
        new_name="${base_name%.*}_$timestamp.zip"
        dest_zip="$dest_dir/$new_name"

        echo "移动 $zip_file 到 $dest_zip"
        mv "$zip_file" "$dest_zip"
    done <<< "$zip_list"

    echo "所有 zip 文件已成功移动到: $dest_dir"
}

# 开始计时
export BUILD_NUMBER="$(date +%y%m%d)"
START=$(date +%s)
# ========== 主流程 ==========
export BUILD_NUMBER="$(date +%y%m%d)"
START=$(date +%s)
echo "--------------------------------------"
echo "       AOSP 15.0 自动编译脚本（v10）     "
echo "          Modified By Gzcheng         "
echo "--------------------------------------"

# 检查
checkPaths
checkSystemPackage
check_java11
checkFinalZIP
checkDiskSpace

# 检查主repo, 如果不存在或者不完整则初始化
doMainRepo

# 选择子项目
chooseProjectBuild    
#应用补丁
applyPatches
# 设置构建环境
setupEnv
# 开始编译系统
buildVariants
# 移动镜像
collectFinalZIP

END=$(date +%s)
ELAPSED=$((END - START))
echo "构建完成，用时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
