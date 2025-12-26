#!/usr/bin/env bash

# Pi-hole: A black hole for Internet advertisements
# (c) 2019 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Network table flush
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

coltable="/opt/pihole/COL_TABLE"
if [[ -f ${coltable} ]]; then
# shellcheck source="./advanced/Scripts/COL_TABLE"
    source ${coltable}
fi

readonly PI_HOLE_SCRIPT_DIR="/opt/pihole"
utilsfile="${PI_HOLE_SCRIPT_DIR}/utils.sh"
# shellcheck source=./advanced/Scripts/utils.sh
source "${utilsfile}"

# Source api functions
# shellcheck source="./advanced/Scripts/api.sh"
. "${PI_HOLE_SCRIPT_DIR}/api.sh"

flushNetwork(){
    local output

    echo -ne "  ${INFO} 正在刷新网络表 ..."

    local data status error
    # Authenticate with FTL
    LoginAPI

    # send query again
    data=$(PostFTLData "action/flush/network" "" "status")

    # Separate the status from the data
    status=$(printf %s "${data#"${data%???}"}")
    data=$(printf %s "${data%???}")

    # If there is an .error object in the returned data, display it
    local error
    error=$(jq --compact-output <<< "${data}" '.error')
    if [[ $error != "null" && $error != "" ]]; then
        echo -e "${OVER}  ${CROSS} 刷新网络表失败："
        echo -e "      $(jq <<< "${data}" '.error')"
        LogoutAPI
        exit 1
    elif [[ "${status}" == "200" ]]; then
        echo -e "${OVER}  ${TICK} 已刷新网络表"
    fi

    # Delete session
    LogoutAPI
}

flushArp(){
    # Flush ARP cache of the host
    if ! output=$(ip -s -s neigh flush all 2>&1); then
        echo -e "${OVER}  ${CROSS} 刷新 ARP 缓存失败"
        echo "  输出: ${output}"
        return 1
    fi
}

# Process all options (if present)
while [ "$#" -gt 0 ]; do
    case "$1" in
    "--arp" ) doARP=true ;;
    esac
    shift
done

flushNetwork

if [[ "${doARP}" == true ]]; then
    echo -ne "  ${INFO} 正在刷新 ARP 缓存"
    if flushArp; then
        echo -e "${OVER}  ${TICK} 已刷新 ARP 缓存"
    fi
fi

