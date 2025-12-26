#!/usr/bin/env bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Check Pi-hole core and admin pages versions and determine what
# upgrade (if any) is required. Automatically updates and reinstalls
# application if update is detected.
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# Variables
readonly ADMIN_INTERFACE_GIT_URL="https://github.com/pi-hole/web.git"
readonly PI_HOLE_GIT_URL="https://github.com/pi-hole/pi-hole.git"
readonly PI_HOLE_FILES_DIR="/etc/.pihole"

SKIP_INSTALL=true

# when --check-only is passed to this script, it will not perform the actual update
CHECK_ONLY=false

# shellcheck source="./automated install/basic-install.sh"
source "${PI_HOLE_FILES_DIR}/automated install/basic-install.sh"
# shellcheck source=./advanced/Scripts/COL_TABLE
source "/opt/pihole/COL_TABLE"
# shellcheck source="./advanced/Scripts/utils.sh"
source "${PI_HOLE_INSTALL_DIR}/utils.sh"

# is_repo() sourced from basic-install.sh
# make_repo() sourced from basic-install.sh
# update_repo() source from basic-install.sh
# getGitFiles() sourced from basic-install.sh
# FTLcheckUpdate() sourced from basic-install.sh
# getFTLConfigValue() sourced from utils.sh

# Honour configured paths for the web application.
ADMIN_INTERFACE_DIR=$(getFTLConfigValue "webserver.paths.webroot")$(getFTLConfigValue "webserver.paths.webhome")
readonly ADMIN_INTERFACE_DIR

GitCheckUpdateAvail() {
    local directory
    local curBranch
    directory="${1}"
    curdir=$PWD
    cd "${directory}" || exit 1

    # Fetch latest changes in this repo
    if ! git fetch --quiet origin ; then
        echo -e "\\n  ${COL_RED}错误：无法更新本地仓库。请联系 Pi-hole 支持。${COL_NC}"
        exit 1
    fi

    # Check current branch. If it is master, then check for the latest available tag instead of latest commit.
    curBranch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "${curBranch}" == "master" ]]; then
        # get the latest local tag
        LOCAL=$(git describe --abbrev=0 --tags master)
        # get the latest tag from remote
        REMOTE=$(git describe --abbrev=0 --tags origin/master)

    else
        # @ alone is a shortcut for HEAD. Older versions of git
        # need @{0}
        LOCAL="$(git rev-parse "@{0}")"

        # The suffix @{upstream} to a branchname
        # (short form <branchname>@{u}) refers
        # to the branch that the branch specified
        # by branchname is set to build on top of#
        # (configured with branch.<name>.remote and
        # branch.<name>.merge). A missing branchname
        # defaults to the current one.
        REMOTE="$(git rev-parse "@{upstream}")"
    fi


    if [[ "${#LOCAL}" == 0 ]]; then
        echo -e "\\n  ${COL_RED}错误：无法获取本地修订版，请联系 Pi-hole 支持"
        echo -e "  额外的调试输出：${COL_NC}"
        git status
        exit 1
    fi
    if [[ "${#REMOTE}" == 0 ]]; then
        echo -e "\\n  ${COL_RED}错误：无法获取远程修订版，请联系 Pi-hole 支持"
        echo -e "  额外的调试输出：${COL_NC}"
        git status
        exit 1
    fi

    # Change back to original directory
    cd "${curdir}" || exit 1

    if [[ "${LOCAL}" != "${REMOTE}" ]]; then
        # Local branch is behind remote branch -> Update
        return 0
    else
        # Local branch is up-to-date or in a situation
        # where this updater cannot be used (like on a
        # branch that exists only locally)
        return 1
    fi
}

main() {
    local basicError="\\n  ${COL_RED}无法完成更新，请联系 Pi-hole 支持${COL_NC}"
    local core_update
    local web_update
    local FTL_update

    core_update=false
    web_update=false
    FTL_update=false


    # Install packages used by this installation script (necessary if users have removed e.g. git from their systems)
    package_manager_detect
    build_dependency_package
    install_dependent_packages

    # This is unlikely
    if ! is_repo "${PI_HOLE_FILES_DIR}" ; then
        echo -e "\\n  ${COL_RED}错误：系统缺少 Pi-hole 核心仓库！"
        echo -e "  请从 https://pi-hole.net 重新运行安装脚本${COL_NC}"
        exit 1;
    fi

    echo -e "  ${INFO} 正在检查更新..."

    if GitCheckUpdateAvail "${PI_HOLE_FILES_DIR}" ; then
        core_update=true
        echo -e "  ${INFO} Pi-hole 核心：\\t${COL_YELLOW}有更新可用${COL_NC}"
    else
        core_update=false
        echo -e "  ${INFO} Pi-hole 核心：\\t${COL_GREEN}已是最新${COL_NC}"
    fi

    if ! is_repo "${ADMIN_INTERFACE_DIR}" ; then
        echo -e "\\n  ${COL_RED}错误：系统缺少 Web 管理仓库！"
        echo -e "  请从 https://pi-hole.net 重新运行安装脚本${COL_NC}"
        exit 1;
    fi

    if GitCheckUpdateAvail "${ADMIN_INTERFACE_DIR}" ; then
        web_update=true
        echo -e "  ${INFO} Web 界面：\\t${COL_YELLOW}有更新可用${COL_NC}"
    else
        web_update=false
        echo -e "  ${INFO} Web 界面：\\t${COL_GREEN}已是最新${COL_NC}"
    fi

    local funcOutput
    funcOutput=$(get_binary_name) #Store output of get_binary_name here
    local binary
    binary="pihole-FTL${funcOutput##*pihole-FTL}" #binary name will be the last line of the output of get_binary_name (it always begins with pihole-FTL)

    if FTLcheckUpdate "${binary}" &>/dev/null; then
        FTL_update=true
        echo -e "  ${INFO} FTL：\\t\\t${COL_YELLOW}有更新可用${COL_NC}"
    else
        case $? in
            1)
                echo -e "  ${INFO} FTL：\\t\\t${COL_GREEN}已是最新${COL_NC}"
                ;;
            2)
                echo -e "  ${INFO} FTL：\\t\\t${COL_RED}分支不可用。${COL_NC}\\n\\t\\t\\t使用 ${COL_GREEN}pihole checkout ftl [branchname]${COL_NC} 切换到有效分支。"
                exit 1
                ;;
            3)
                echo -e "  ${INFO} FTL：\\t\\t${COL_RED}出错了，无法连接下载服务器${COL_NC}"
                exit 1
                ;;
            *)
                echo -e "  ${INFO} FTL：\\t\\t${COL_RED}出错了，请联系支持${COL_NC}"
                exit 1
        esac
        FTL_update=false
    fi

    # Determine FTL branch
    local ftlBranch
    if [[ -f "/etc/pihole/ftlbranch" ]]; then
        ftlBranch=$(</etc/pihole/ftlbranch)
    else
        ftlBranch="master"
    fi

    if [[ ! "${ftlBranch}" == "master" && ! "${ftlBranch}" == "development" ]]; then
        # Notify user that they are on a custom branch which might mean they they are lost
        # behind if a branch was merged to development and got abandoned
        printf "  %b %b警告：%b 您正在使用来自自定义分支 (%s) 的 FTL，可能会错过未来的发布。\\n" "${INFO}" "${COL_RED}" "${COL_NC}" "${ftlBranch}"
    fi

    if [[ "${core_update}" == false && "${web_update}" == false && "${FTL_update}" == false ]]; then
        echo ""
        echo -e "  ${TICK} 一切都是最新的！"
        exit 0
    fi

    if [[ "${CHECK_ONLY}" == true ]]; then
        echo ""
        exit 0
    fi

    if [[ "${core_update}" == true ]]; then
        echo ""
        echo -e "  ${INFO} Pi-hole 核心文件已过期，正在更新本地仓库。"
        getGitFiles "${PI_HOLE_FILES_DIR}" "${PI_HOLE_GIT_URL}"
        echo -e "  ${INFO} 如果您在 '/etc/.pihole/' 中做了任何更改，它们已被使用 'git stash' 暂存"
    fi

    if [[ "${web_update}" == true ]]; then
        echo ""
        echo -e "  ${INFO} Pi-hole Web 管理文件已过期，正在更新本地仓库。"
        getGitFiles "${ADMIN_INTERFACE_DIR}" "${ADMIN_INTERFACE_GIT_URL}"
        echo -e "  ${INFO} 如果您在 '${ADMIN_INTERFACE_DIR}' 中做了任何更改，它们已被使用 'git stash' 暂存"
    fi

    if [[ "${FTL_update}" == true ]]; then
        echo ""
        echo -e "  ${INFO} FTL 已过期，它将由安装程序更新。"
    fi

    if [[ "${FTL_update}" == true || "${core_update}" == true ]]; then
        ${PI_HOLE_FILES_DIR}/automated\ install/basic-install.sh --repair --unattended || \
            echo -e "${basicError}" && exit 1
    fi

    if [[ "${FTL_update}" == true || "${core_update}" == true || "${web_update}" == true ]]; then
        # Update local and remote versions via updatechecker
        /opt/pihole/updatecheck.sh
        echo -e "  ${INFO} 本地版本文件信息已更新。"
    fi

    # if there was only a web update, show the new versions
    # (on core and FTL updates, this is done as part of the installer run)
    if [[ "${web_update}" == true &&  "${FTL_update}" == false && "${core_update}" == false ]]; then
        "${PI_HOLE_BIN_DIR}"/pihole version
    fi

    echo ""
    exit 0
}

if [[ "$1" == "--check-only" ]]; then
    CHECK_ONLY=true
fi

main
