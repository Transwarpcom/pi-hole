#!/usr/bin/env bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Switch Pi-hole subsystems to a different GitHub branch.
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

readonly PI_HOLE_FILES_DIR="/etc/.pihole"
SKIP_INSTALL="true"
# shellcheck source="./automated install/basic-install.sh"
source "${PI_HOLE_FILES_DIR}/automated install/basic-install.sh"

# webInterfaceGitUrl set in basic-install.sh
# webInterfaceDir set in basic-install.sh
# piholeGitURL set in basic-install.sh
# is_repo() sourced from basic-install.sh
# check_download_exists sourced from basic-install.sh
# fully_fetch_repo sourced from basic-install.sh
# get_available_branches sourced from basic-install.sh
# fetch_checkout_pull_branch sourced from basic-install.sh
# checkout_pull_branch sourced from basic-install.sh

warning1() {
    echo "  请注意，更改分支会严重改变您的 Pi-hole 子系统"
    echo "  在 master 分支上可用的功能，在开发分支上可能不可用"
    echo -e "  ${COL_RED}除非 Pi-hole 开发人员明确要求，否则不支持此功能！${COL_NC}"
    read -r -p "  您已阅读并理解此内容吗？ [y/N] " response
    case "${response}" in
        [yY][eE][sS]|[yY])
            echo ""
            return 0
            ;;
        *)
            echo -e "\\n  ${INFO} 分支更改已取消"
            return 1
            ;;
    esac
}

checkout() {
    local corebranches
    local webbranches

    # Check if FTL is installed - do this early on as FTL is a hard dependency for Pi-hole
    local funcOutput
    funcOutput=$(get_binary_name) #Store output of get_binary_name here
    local binary
    binary="pihole-FTL${funcOutput##*pihole-FTL}" #binary name will be the last line of the output of get_binary_name (it always begins with pihole-FTL)

    # Avoid globbing
    set -f

    # This is unlikely
    if ! is_repo "${PI_HOLE_FILES_DIR}" ; then
        echo -e "  ${COL_RED}错误：系统缺少 Pi-hole 核心仓库！"
        echo -e "  请从 https://github.com/pi-hole/pi-hole 重新运行安装脚本${COL_NC}"
        exit 1;
    fi

    if ! is_repo "${webInterfaceDir}" ; then
        echo -e "  ${COL_RED}错误：系统缺少 Web 管理仓库！"
        echo -e "  请从 https://github.com/pi-hole/pi-hole 重新运行安装脚本${COL_NC}"
        exit 1;
    fi

    if [[ -z "${1}" ]]; then
        echo -e "  ${COL_RED}无效选项${COL_NC}"
        echo -e "  尝试 'pihole checkout --help' 获取更多信息。"
        exit 1
    fi

    if ! warning1 ; then
        exit 1
    fi

    if [[ "${1}" == "dev" ]] ; then
        # Shortcut to check out development branches
        echo -e "  ${INFO} 检测到快捷方式 \"${COL_YELLOW}dev${COL_NC}\" - 正在检出开发分支..."
        echo ""
        echo -e "  ${INFO} Pi-hole 核心"
        fetch_checkout_pull_branch "${PI_HOLE_FILES_DIR}" "development" || { echo "  ${CROSS} 无法拉取核心开发分支"; exit 1; }
        echo ""
        echo -e "  ${INFO} Web 界面"
        fetch_checkout_pull_branch "${webInterfaceDir}" "development" || { echo "  ${CROSS} 无法拉取 Web 开发分支"; exit 1; }
        #echo -e "  ${TICK} Pi-hole Core"

        local path
        path="development/${binary}"
        echo "development" > /etc/pihole/ftlbranch
        chmod 644 /etc/pihole/ftlbranch
    elif [[ "${1}" == "master" ]] ; then
        # Shortcut to check out master branches
        echo -e "  ${INFO} 检测到快捷方式 \"${COL_YELLOW}master${COL_NC}\" - 正在检出 master 分支..."
        echo -e "  ${INFO} Pi-hole 核心"
        fetch_checkout_pull_branch "${PI_HOLE_FILES_DIR}" "master" || { echo "  ${CROSS} 无法拉取核心 master 分支"; exit 1; }
        echo -e "  ${INFO} Web 界面"
        fetch_checkout_pull_branch "${webInterfaceDir}" "master" || { echo "  ${CROSS} 无法拉取 Web master 分支"; exit 1; }
        #echo -e "  ${TICK} Web Interface"
        local path
        path="master/${binary}"
        echo "master" > /etc/pihole/ftlbranch
        chmod 644 /etc/pihole/ftlbranch
    elif [[ "${1}" == "core" ]] ; then
        str="正在从 ${piholeGitUrl} 获取分支"
        echo -ne "  ${INFO} $str"
        if ! fully_fetch_repo "${PI_HOLE_FILES_DIR}" ; then
            echo -e "${OVER}  ${CROSS} $str"
            exit 1
        fi
        mapfile -t corebranches < <(get_available_branches "${PI_HOLE_FILES_DIR}")

        if [[ "${corebranches[*]}" == *"master"* ]]; then
            echo -e "${OVER}  ${TICK} $str"
            echo -e "  ${INFO} Pi-hole 核心有 ${#corebranches[@]} 个可用分支"
        else
            # Print STDERR output from get_available_branches
            echo -e "${OVER}  ${CROSS} $str\\n\\n${corebranches[*]}"
            exit 1
        fi

        echo ""
        # Have the user choose the branch they want
        if ! (for e in "${corebranches[@]}"; do [[ "$e" == "${2}" ]] && exit 0; done); then
            echo -e "  ${INFO} 请求的分支 \"${COL_CYAN}${2}${COL_NC}\" 不可用"
            echo -e "  ${INFO} 核心的可用分支有："
            for e in "${corebranches[@]}"; do echo "      - $e"; done
            exit 1
        fi
        checkout_pull_branch "${PI_HOLE_FILES_DIR}" "${2}"
    elif [[ "${1}" == "web" ]] ; then
        str="正在从 ${webInterfaceGitUrl} 获取分支"
        echo -ne "  ${INFO} $str"
        if ! fully_fetch_repo "${webInterfaceDir}" ; then
            echo -e "${OVER}  ${CROSS} $str"
            exit 1
        fi
        mapfile -t webbranches < <(get_available_branches "${webInterfaceDir}")

        if [[ "${webbranches[*]}" == *"master"* ]]; then
            echo -e "${OVER}  ${TICK} $str"
            echo -e "  ${INFO} Web 管理界面有 ${#webbranches[@]} 个可用分支"
        else
            # Print STDERR output from get_available_branches
            echo -e "${OVER}  ${CROSS} $str\\n\\n${webbranches[*]}"
            exit 1
        fi

        echo ""
        # Have the user choose the branch they want
        if ! (for e in "${webbranches[@]}"; do [[ "$e" == "${2}" ]] && exit 0; done); then
            echo -e "  ${INFO} 请求的分支 \"${COL_CYAN}${2}${COL_NC}\" 不可用"
            echo -e "  ${INFO} Web 管理界面的可用分支有："
            for e in "${webbranches[@]}"; do echo "      - $e"; done
            exit 1
        fi
        checkout_pull_branch "${webInterfaceDir}" "${2}"
        # Update local and remote versions via updatechecker
        /opt/pihole/updatecheck.sh
    elif [[ "${1}" == "ftl" ]] ; then
        local path
        local oldbranch
        local existing=false
        path="${2}/${binary}"
        oldbranch="$(pihole-FTL -b)"

        # Check if requested branch is available
        echo -e "  ${INFO} 正在检查 GitHub 上分支 ${COL_CYAN}${2}${COL_NC} 的可用性"
        mapfile -t ftlbranches < <(git ls-remote https://github.com/Transwarpcom/ftl | grep "refs/heads" | cut -d'/' -f3- -)
        # If returned array is empty -> connectivity issue
        if [[ ${#ftlbranches[@]} -eq 0 ]]; then
            echo -e "  ${CROSS} 无法从 GitHub 获取分支。请检查您的互联网连接并稍后重试。"
            exit 1
        fi

        for e in "${ftlbranches[@]}"; do [[ "$e" == "${2}" ]] && existing=true; done
        if [[ "${existing}" == false ]]; then
            echo -e "  ${CROSS} 请求的分支不可用\n"
            echo -e "  ${INFO} 可用分支有："
            for e in "${ftlbranches[@]}"; do echo "      - $e"; done
            exit 1
        fi
        echo -e "  ${TICK} 分支 ${2} 存在于 GitHub 上"

        echo -e "  ${INFO} 正在检查 https://ftl.pi-hole.net 上是否有 ${COL_YELLOW}${binary}${COL_NC} 二进制文件"

        if check_download_exists "$path"; then
            echo "  ${TICK} 二进制文件存在"
            echo "${2}" > /etc/pihole/ftlbranch
            chmod 644 /etc/pihole/ftlbranch
            echo -e "  ${INFO} 切换分支到：${COL_CYAN}${2}${COL_NC} 从 ${COL_CYAN}${oldbranch}${COL_NC}"
            FTLinstall "${binary}"
            restart_service pihole-FTL
            enable_service pihole-FTL
            str="正在重启 FTL..."
            echo -ne "  ${INFO} ${str}"
            # Wait until name resolution is working again after restarting FTL,
            # so that the updatechecker can run successfully and does not fail
            # trying to resolve github.com
            until getent hosts github.com &> /dev/null; do
                # Append one dot for each second waiting
                str="${str}."
                echo -ne "  ${OVER}  ${INFO} ${str}"
                sleep 1
            done
            echo -e "  ${OVER}  ${TICK} 已重启 FTL 服务"

            # Update local and remote versions via updatechecker
            /opt/pihole/updatecheck.sh
        else
            local status
            status=$?
            if [ $status -eq 1 ]; then
                # Binary for requested branch is not available, may still be
                # int he process of being built or CI build job failed
                printf "  %b 请求分支的二进制文件不可用，请稍后重试。\\n" "${CROSS}"
                printf "      如果问题仍然存在，请联系 Pi-hole 支持并要求他们重新生成二进制文件。\\n"
                exit 1
            elif [ $status -eq 2 ]; then
                printf "  %b 无法从 ftl.pi-hole.net 下载。请检查您的互联网连接并稍后重试。\\n" "${CROSS}"
                exit 1
            else
                printf "  %b 未知的检出错误。请联系 Pi-hole 支持\\n" "${CROSS}"
                exit 1
            fi
        fi

    else
        echo -e "  ${CROSS} 请求的选项 \"${1}\" 不可用"
        exit 1
    fi

    # Force updating everything
    if [[  ! "${1}" == "web" && ! "${1}" == "ftl" ]]; then
        echo -e "  ${INFO} 运行安装程序以升级您的安装"
        if "${PI_HOLE_FILES_DIR}/automated install/basic-install.sh" --unattended; then
            exit 0
        else
            echo -e "  ${COL_RED} 错误：无法完成更新，请联系支持${COL_NC}"
            exit 1
        fi
    fi
}
