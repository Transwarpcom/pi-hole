#!/usr/bin/env sh
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Show version numbers
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# Source the versions file populated by updatechecker.sh
cachedVersions="/etc/pihole/versions"

if [ -f ${cachedVersions} ]; then
    # shellcheck source=/dev/null
    . "$cachedVersions"
else
    echo "找不到 /etc/pihole/versions。正在运行更新。"
    pihole updatechecker
     # shellcheck source=/dev/null
    . "$cachedVersions"
fi

main() {
    local details
    details=false

    # Automatically show detailed information if
    # at least one of the components is not on master branch
    if [ ! "${CORE_BRANCH}" = "master" ] || [ ! "${WEB_BRANCH}" = "master" ] || [ ! "${FTL_BRANCH}" = "master" ]; then
        details=true
    fi

    if [ "${details}" = true ]; then
        echo "核心"
        echo "    版本是 ${CORE_VERSION:=N/A} (最新: ${GITHUB_CORE_VERSION:=N/A})"
        echo "    分支是 ${CORE_BRANCH:=N/A}"
        echo "    Hash 是 ${CORE_HASH:=N/A} (最新: ${GITHUB_CORE_HASH:=N/A})"
        echo "Web"
        echo "    版本是 ${WEB_VERSION:=N/A} (最新: ${GITHUB_WEB_VERSION:=N/A})"
        echo "    分支是 ${WEB_BRANCH:=N/A}"
        echo "    Hash 是 ${WEB_HASH:=N/A} (最新: ${GITHUB_WEB_HASH:=N/A})"
        echo "FTL"
        echo "    版本是 ${FTL_VERSION:=N/A} (最新: ${GITHUB_FTL_VERSION:=N/A})"
        echo "    分支是 ${FTL_BRANCH:=N/A}"
        echo "    Hash 是 ${FTL_HASH:=N/A} (最新: ${GITHUB_FTL_HASH:=N/A})"
    else
        echo "核心版本是 ${CORE_VERSION:=N/A} (最新: ${GITHUB_CORE_VERSION:=N/A})"
        echo "Web 版本是 ${WEB_VERSION:=N/A} (最新: ${GITHUB_WEB_VERSION:=N/A})"
        echo "FTL 版本是 ${FTL_VERSION:=N/A} (最新: ${GITHUB_FTL_VERSION:=N/A})"
    fi
}

main
