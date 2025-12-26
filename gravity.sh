#!/usr/bin/env bash

# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Usage: "pihole -g"
# Compiles a list of ad-serving domains by downloading them from multiple sources
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

export LC_ALL=C

PI_HOLE_SCRIPT_DIR="/opt/pihole"
# Source utils.sh for GetFTLConfigValue
utilsfile="${PI_HOLE_SCRIPT_DIR}/utils.sh"
# shellcheck source=./advanced/Scripts/utils.sh
. "${utilsfile}"

coltable="${PI_HOLE_SCRIPT_DIR}/COL_TABLE"
# shellcheck source=./advanced/Scripts/COL_TABLE
. "${coltable}"
# shellcheck source=./advanced/Scripts/database_migration/gravity-db.sh
. "/etc/.pihole/advanced/Scripts/database_migration/gravity-db.sh"

basename="pihole"
PIHOLE_COMMAND="/usr/local/bin/${basename}"

piholeDir="/etc/${basename}"

# Gravity aux files directory
listsCacheDir="${piholeDir}/listsCache"

# Legacy (pre v5.0) list file locations
whitelistFile="${piholeDir}/whitelist.txt"
blacklistFile="${piholeDir}/blacklist.txt"
regexFile="${piholeDir}/regex.list"
adListFile="${piholeDir}/adlists.list"

piholeGitDir="/etc/.pihole"
GRAVITYDB=$(getFTLConfigValue files.gravity)
GRAVITY_TMPDIR=$(getFTLConfigValue files.gravity_tmp)
gravityDBschema="${piholeGitDir}/advanced/Templates/gravity.db.sql"
gravityDBcopy="${piholeGitDir}/advanced/Templates/gravity_copy.sql"

domainsExtension="domains"
curl_connect_timeout=10
etag_support=false

# Check gravity temp directory
if [ ! -d "${GRAVITY_TMPDIR}" ] || [ ! -w "${GRAVITY_TMPDIR}" ]; then
  echo -e "  ${COL_RED}Gravity 临时目录不存在或不可写，回退到 /tmp。 ${COL_NC}"
  GRAVITY_TMPDIR="/tmp"
fi

# Set this only after sourcing pihole-FTL.conf as the gravity database path may
# have changed
gravityDBfile="${GRAVITYDB}"
gravityDBfile_default="${piholeDir}/gravity.db"
gravityTEMPfile="${GRAVITYDB}_temp"
gravityDIR="$(dirname -- "${gravityDBfile}")"
gravityOLDfile="${gravityDIR}/gravity_old.db"
gravityBCKdir="${gravityDIR}/gravity_backups"
gravityBCKfile="${gravityBCKdir}/gravity.db"

fix_owner_permissions() {
  # Fix ownership and permissions for the specified file
  # User and group are set to pihole:pihole
  # Permissions are set to 664 (rw-rw-r--)
  chown pihole:pihole "${1}"
  chmod 664 "${1}"

  # Ensure the containing directory is group writable
  chmod g+w "$(dirname -- "${1}")"
}

# Generate new SQLite3 file from schema template
generate_gravity_database() {
  if ! pihole-FTL sqlite3 -ni "${gravityDBfile}" <"${gravityDBschema}"; then
    echo -e "   ${CROSS} 无法创建 ${gravityDBfile}"
    return 1
  fi
  fix_owner_permissions "${gravityDBfile}"
}

# Build gravity tree
gravity_build_tree() {
  local str
  str="构建树"
  echo -ne "  ${INFO} ${str}..."

  # The index is intentionally not UNIQUE as poor quality adlists may contain domains more than once
  output=$({ pihole-FTL sqlite3 -ni "${gravityTEMPfile}" "CREATE INDEX idx_gravity ON gravity (domain, adlist_id);"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法在 ${gravityTEMPfile} 中构建 gravity 树\\n  ${output}"
    echo -e "  ${INFO} 如果您有大量域名，请确保您的 Pi-hole 有足够的可用 RAM\\n"
    return 1
  fi
  echo -e "${OVER}  ${TICK} ${str}"
}

# Rotate gravity backup files
rotate_gravity_backup() {
  for i in {9..1}; do
    if [ -f "${gravityBCKfile}.${i}" ]; then
      mv "${gravityBCKfile}.${i}" "${gravityBCKfile}.$((i + 1))"
    fi
  done
}

# Copy data from old to new database file and swap them
gravity_swap_databases() {
  str="交换数据库"
  echo -ne "  ${INFO} ${str}..."

  # Swap databases and remove or conditionally rename old database
  # Number of available blocks on disk
  # Busybox Compat: `stat` long flags unsupported
  #   -f flag is short form of --file-system.
  #   -c flag is short form of --format.
  availableBlocks=$(stat -f -c "%a" "${gravityDIR}")
  # Number of blocks, used by gravity.db
  gravityBlocks=$(stat -c "%b" "${gravityDBfile}")
  # Only keep the old database if available disk space is at least twice the size of the existing gravity.db.
  # Better be safe than sorry...
  oldAvail=false
  if [ "${availableBlocks}" -gt "$((gravityBlocks * 2))" ] && [ -f "${gravityDBfile}" ]; then
    oldAvail=true
    cp -p "${gravityDBfile}" "${gravityOLDfile}"
  fi

  # Drop the gravity and antigravity tables + subsequent VACUUM the current
  # database for compaction
  output=$({ printf ".timeout 30000\\nDROP TABLE IF EXISTS gravity;\\nDROP TABLE IF EXISTS antigravity;\\nVACUUM;\\n" | pihole-FTL sqlite3 -ni "${gravityDBfile}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法清理当前数据库以进行备份\\n  ${output}"
  else
    # Check if the backup directory exists
    if [ ! -d "${gravityBCKdir}" ]; then
      mkdir -p "${gravityBCKdir}" && chown pihole:pihole "${gravityBCKdir}"
    fi

    # If multiple gravityBCKfile's are present (appended with a number), rotate them
    # We keep at most 10 backups
    rotate_gravity_backup

    # Move the old database to the backup location
    mv "${gravityDBfile}" "${gravityBCKfile}.1"
  fi


  # Move the new database to the correct location
  mv "${gravityTEMPfile}" "${gravityDBfile}"
  echo -e "${OVER}  ${TICK} ${str}"

  if $oldAvail; then
    echo -e "  ${TICK} 旧数据库仍然可用"
  fi
}

# Update timestamp when the gravity table was last updated successfully
update_gravity_timestamp() {
  output=$({ printf ".timeout 30000\\nINSERT OR REPLACE INTO info (property,value) values ('updated',cast(strftime('%%s', 'now') as int));" | pihole-FTL sqlite3 -ni "${gravityTEMPfile}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法在数据库 ${gravityTEMPfile} 中更新 gravity 时间戳\\n  ${output}"
    return 1
  fi
  return 0
}

# Import domains from file and store them in the specified database table
database_table_from_file() {
  # Define locals
  local table src backup_path backup_file tmpFile list_type
  table="${1}"
  src="${2}"
  backup_path="${piholeDir}/migration_backup"
  backup_file="${backup_path}/$(basename "${2}")"
  # Create a temporary file. We don't use '--suffix' here because not all
  # implementations of mktemp support it, e.g. on Alpine
  tmpFile="$(mktemp -p "${GRAVITY_TMPDIR}")"
  mv "${tmpFile}" "${tmpFile%.*}.gravity"
  tmpFile="${tmpFile%.*}.gravity"

  local timestamp
  timestamp="$(date --utc +'%s')"

  local rowid
  declare -i rowid
  rowid=1

  # Special handling for domains to be imported into the common domainlist table
  if [[ "${table}" == "whitelist" ]]; then
    list_type="0"
    table="domainlist"
  elif [[ "${table}" == "blacklist" ]]; then
    list_type="1"
    table="domainlist"
  elif [[ "${table}" == "regex" ]]; then
    list_type="3"
    table="domainlist"
  fi

  # Get MAX(id) from domainlist when INSERTing into this table
  if [[ "${table}" == "domainlist" ]]; then
    rowid="$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "SELECT MAX(id) FROM domainlist;")"
    if [[ -z "$rowid" ]]; then
      rowid=0
    fi
    rowid+=1
  fi

  # Loop over all domains in ${src} file
  # Read file line by line
  grep -v '^ *#' <"${src}" | while IFS= read -r domain; do
    # Only add non-empty lines
    if [[ -n "${domain}" ]]; then
      if [[ "${table}" == "adlist" ]]; then
        # Adlist table format
        echo "${rowid},\"${domain}\",1,${timestamp},${timestamp},\"Migrated from ${src}\",,0,0,0,0,0" >>"${tmpFile}"
      else
        # White-, black-, and regexlist table format
        echo "${rowid},${list_type},\"${domain}\",1,${timestamp},${timestamp},\"Migrated from ${src}\"" >>"${tmpFile}"
      fi
      rowid+=1
    fi
  done

  # Store domains in database table specified by ${table}
  # Use printf as .mode and .import need to be on separate lines
  # see https://unix.stackexchange.com/a/445615/83260
  output=$({ printf ".timeout 30000\\n.mode csv\\n.import \"%s\" %s\\n" "${tmpFile}" "${table}" | pihole-FTL sqlite3 -ni "${gravityDBfile}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法填充数据库 ${gravityDBfile} 中的表 ${table}${list_type}\\n  ${output}"
    gravity_Cleanup "error"
  fi

  # Move source file to backup directory, create directory if not existing
  mkdir -p "${backup_path}"
  mv "${src}" "${backup_file}" 2>/dev/null ||
    echo -e "  ${CROSS} 无法将 ${src} 备份到 ${backup_path}"

  # Delete tmpFile
  rm "${tmpFile}" >/dev/null 2>&1 ||
    echo -e "  ${CROSS} 无法删除 ${tmpFile}"
}

# Check if a column with name ${2} exists in gravity table with name ${1}
gravity_column_exists() {
  output=$({ printf ".timeout 30000\\nSELECT EXISTS(SELECT * FROM pragma_table_info('%s') WHERE name='%s');\\n" "${1}" "${2}" | pihole-FTL sqlite3 -ni "${gravityTEMPfile}"; } 2>&1)
  if [[ "${output}" == "1" ]]; then
    return 0 # Bash 0 is success
  fi

  return 1 # Bash non-0 is failure
}

# Update number of domain on this list. We store this in the "old" database as all values in the new database will later be overwritten
database_adlist_number() {
  # Only try to set number of domains when this field exists in the gravity database
  if ! gravity_column_exists "adlist" "number"; then
    return
  fi

  output=$({ printf ".timeout 30000\\nUPDATE adlist SET number = %i, invalid_domains = %i WHERE id = %i;\\n" "${2}" "${3}" "${1}" | pihole-FTL sqlite3 -ni "${gravityTEMPfile}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法在数据库 ${gravityTEMPfile} 中更新 ID 为 ${1} 的广告列表的域名数量\\n  ${output}"
    gravity_Cleanup "error"
  fi
}

# Update status of this list. We store this in the "old" database as all values in the new database will later be overwritten
database_adlist_status() {
  # Only try to set the status when this field exists in the gravity database
  if ! gravity_column_exists "adlist" "status"; then
    return
  fi

  output=$({ printf ".timeout 30000\\nUPDATE adlist SET status = %i WHERE id = %i;\\n" "${2}" "${1}" | pihole-FTL sqlite3 -ni "${gravityTEMPfile}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法在数据库 ${gravityTEMPfile} 中更新 ID 为 ${1} 的广告列表的状态\\n  ${output}"
    gravity_Cleanup "error"
  fi
}

# Migrate pre-v5.0 list files to database-based Pi-hole versions
migrate_to_database() {
  # Create database file only if not present
  if [ ! -e "${gravityDBfile}" ]; then
    # Create new database file - note that this will be created in version 1
    echo -e "  ${INFO} 正在创建新的 gravity 数据库"
    if ! generate_gravity_database; then
      echo -e "   ${CROSS} 创建新 gravity 数据库时出错。请联系支持。"
      return 1
    fi

    # Check if gravity database needs to be updated
    upgrade_gravityDB "${gravityDBfile}"

    # Migrate list files to new database
    if [ -e "${adListFile}" ]; then
      # Store adlist domains in database
      echo -e "  ${INFO} 将 ${adListFile} 的内容迁移到新数据库"
      database_table_from_file "adlist" "${adListFile}"
    fi
    if [ -e "${blacklistFile}" ]; then
      # Store blacklisted domains in database
      echo -e "  ${INFO} 将 ${blacklistFile} 的内容迁移到新数据库"
      database_table_from_file "blacklist" "${blacklistFile}"
    fi
    if [ -e "${whitelistFile}" ]; then
      # Store whitelisted domains in database
      echo -e "  ${INFO} 将 ${whitelistFile} 的内容迁移到新数据库"
      database_table_from_file "whitelist" "${whitelistFile}"
    fi
    if [ -e "${regexFile}" ]; then
      # Store regex domains in database
      # Important note: We need to add the domains to the "regex" table
      # as it will only later be renamed to "regex_blacklist"!
      echo -e "  ${INFO} 将 ${regexFile} 的内容迁移到新数据库"
      database_table_from_file "regex" "${regexFile}"
    fi
  fi

  # Check if gravity database needs to be updated
  upgrade_gravityDB "${gravityDBfile}"
}

# Determine if DNS resolution is available before proceeding
gravity_CheckDNSResolutionAvailable() {
  local lookupDomain="raw.githubusercontent.com"

  # Determine if $lookupDomain is resolvable
  if timeout 4 getent hosts "${lookupDomain}" &>/dev/null; then
    echo -e "${OVER}  ${TICK} DNS 解析可用\\n"
    return 0
  else
    echo -e "  ${CROSS} DNS 解析当前不可用"
  fi

  str="等待 DNS 解析最多 120 秒..."
  echo -ne "  ${INFO} ${str}"

 # Default DNS timeout is two seconds, plus 1 second for each dot > 120 seconds
  for ((i = 0; i < 40; i++)); do
      if getent hosts github.com &> /dev/null; then
        # If we reach this point, DNS resolution is available
        echo -e "${OVER}  ${TICK} DNS 解析可用"
        return 0
      fi
      # Append one dot for each second waiting
      echo -ne "."
      sleep 1
  done

  # DNS resolution is still unavailable after 120 seconds
  return 1

}

# Function: try_restore_backup
# Description: Attempts to restore the previous Pi-hole gravity database from a
#              backup file. If a backup exists, it copies the backup to the
#              gravity database file and prepares a new gravity database. If the
#              restoration is successful, it returns 0. Otherwise, it returns 1.
# Returns:
#   0 - If the backup is successfully restored.
#   1 - If no backup is available or if the restoration fails.
try_restore_backup () {
  local num filename timestamp
  num=$1
  filename="${gravityBCKfile}.${num}"
  # Check if a backup exists
  if [ -f "${filename}" ]; then
    echo -e "  ${INFO} 尝试从备份号 ${num} 恢复先前的数据库"
    cp "${filename}" "${gravityDBfile}"

    # If the backup was successfully copied, prepare a new gravity database from
    # it
    if [ -f "${gravityDBfile}" ]; then
      output=$({ pihole-FTL sqlite3 -ni "${gravityTEMPfile}" <<<"${copyGravity}"; } 2>&1)
      status="$?"

      # Error checking
      if [[ "${status}" -ne 0 ]]; then
        echo -e "\\n  ${CROSS} 无法从 ${gravityDBfile} 复制数据到 ${gravityTEMPfile}\\n  ${output}"
        gravity_Cleanup "error"
      fi

      # Get the timestamp of the backup file in a human-readable format
      # Note that this timestamp will be in the server timezone, this may be
      # GMT, e.g., on a Raspberry Pi where the default timezone has never been
      # changed
      timestamp=$(date -r "${filename}" "+%Y-%m-%d %H:%M:%S %Z")

      # Add a record to the info table to indicate that the gravity database was restored
      pihole-FTL sqlite3 "${gravityTEMPfile}" "INSERT OR REPLACE INTO info (property,value) values ('gravity_restored','${timestamp}');"
      echo -e "  ${TICK} 已成功从备份恢复 (${gravityBCKfile}.${num} 于 ${timestamp})"
      return 0
    else
      echo -e "  ${CROSS} 无法恢复备份号 ${num}"
    fi
  fi

  echo -e "  ${CROSS} 备份号 ${num} 不可用"
  return 1
}

# Retrieve blocklist URLs and parse domains from adlist.list
gravity_DownloadBlocklists() {
  echo -e "  ${INFO} ${COL_BOLD}检测到中微子辐射${COL_NC}..."

  if [[ "${gravityDBfile}" != "${gravityDBfile_default}" ]]; then
    echo -e "  ${INFO} 将 gravity 数据库存储在 ${COL_BOLD}${gravityDBfile}${COL_NC}"
  fi

  local url domain str compression adlist_type directory success
  echo ""

  # Prepare new gravity database
  str="正在准备新的 gravity 数据库"
  echo -ne "  ${INFO} ${str}..."
  rm "${gravityTEMPfile}" >/dev/null 2>&1
  output=$({ pihole-FTL sqlite3 -ni "${gravityTEMPfile}" <"${gravityDBschema}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法创建新数据库 ${gravityTEMPfile}\\n  ${output}"
    gravity_Cleanup "error"
  else
    echo -e "${OVER}  ${TICK} ${str}"
  fi

  str="正在创建新的 gravity 数据库"
  echo -ne "  ${INFO} ${str}..."

  # Gravity copying SQL script
  copyGravity="$(cat "${gravityDBcopy}")"
  if [[ "${gravityDBfile}" != "${gravityDBfile_default}" ]]; then
    # Replace default gravity script location by custom location
    copyGravity="${copyGravity//"${gravityDBfile_default}"/"${gravityDBfile}"}"
  fi

  output=$({ pihole-FTL sqlite3 -ni "${gravityTEMPfile}" <<<"${copyGravity}"; } 2>&1)
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} 无法从 ${gravityDBfile} 复制数据到 ${gravityTEMPfile}\\n  ${output}"

    # Try to attempt a backup restore
    success=false
    if [[ -d "${gravityBCKdir}" ]]; then
      for i in {1..10}; do
        if try_restore_backup "${i}"; then
          success=true
          break
        fi
      done
    fi

    # If none of the attempts worked, return 1
    if [[ "${success}" == false ]]; then
      pihole-FTL sqlite3 "${gravityTEMPfile}" "INSERT OR REPLACE INTO info (property,value) values ('gravity_restored','failed');"
      return 1
    fi

    echo -e "  ${TICK} ${str}"
  else
    echo -e "${OVER}  ${TICK} ${str}"
  fi

  # Retrieve source URLs from gravity database
  # We source only enabled adlists, SQLite3 stores boolean values as 0 (false) or 1 (true)
  mapfile -t sources <<<"$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "SELECT address FROM vw_adlist;" 2>/dev/null)"
  mapfile -t sourceIDs <<<"$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "SELECT id FROM vw_adlist;" 2>/dev/null)"
  mapfile -t sourceTypes <<<"$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "SELECT type FROM vw_adlist;" 2>/dev/null)"

  # Parse source domains from $sources
  mapfile -t sourceDomains <<<"$(
    # Logic: Split by folder/port
    awk -F '[/:]' '{
      # Remove URL protocol & optional username:password@
      gsub(/(.*:\/\/|.*:.*@)/, "", $0)
      if(length($1)>0){print $1}
      else {print "local"}
    }' <<<"$(printf '%s\n' "${sources[@]}")" 2>/dev/null
  )"

  local str="将屏蔽列表源列表拉入范围"
  echo -e "${OVER}  ${TICK} ${str}"

  if [[ -z "${sources[*]}" ]] || [[ -z "${sourceDomains[*]}" ]]; then
    echo -e "  ${INFO} 未找到源列表，或列表为空"
    echo ""
    unset sources
  fi

  # Use compression to reduce the amount of data that is transferred
  # between the Pi-hole and the ad list provider. Use this feature
  # only if it is supported by the locally available version of curl
  if curl -V | grep -q "Features:.* libz"; then
    compression="--compressed"
    echo -e "  ${INFO} 使用 libz 压缩\n"
  else
    compression=""
    echo -e "  ${INFO} Libz 压缩不可用\n"
  fi

  # Check if etag is supported by the locally available version of curl
  # (available as of curl 7.68.0, released Jan 2020)
  # https://github.com/curl/curl/pull/4543 +
  # https://github.com/curl/curl/pull/4678
  if curl --help all | grep -q "etag-save"; then
    etag_support=true
  fi

  # Loop through $sources and download each one
  for ((i = 0; i < "${#sources[@]}"; i++)); do
    url="${sources[$i]}"
    domain="${sourceDomains[$i]}"
    id="${sourceIDs[$i]}"
    if [[ "${sourceTypes[$i]}" -eq "0" ]]; then
      # Gravity list
      str="blocklist"
      adlist_type="gravity"
    else
      # AntiGravity list
      str="allowlist"
      adlist_type="antigravity"
    fi

    # Save the file as list.#.domain
    saveLocation="${listsCacheDir}/list.${id}.${domain}.${domainsExtension}"
    activeDomains[i]="${saveLocation}"

    # Check if we can write to the save location file without actually creating
    # it (in case it doesn't exist)
    # First, check if the directory is writable
    directory="$(dirname -- "${saveLocation}")"
    if [ ! -w "${directory}" ]; then
      echo -e "  ${CROSS} 无法写入 ${directory}"
      echo "      请以 root 身份运行 pihole -g"
      echo ""
      continue
    fi
    # Then, check if the file is writable (if it exists)
    if [ -e "${saveLocation}" ] && [ ! -w "${saveLocation}" ]; then
      echo -e "  ${CROSS} 无法写入 ${saveLocation}"
      echo "      请以 root 身份运行 pihole -g"
      echo ""
      continue
    fi

    echo -e "  ${INFO} 目标: ${url}"
    local regex check_url
    # Check for characters NOT allowed in URLs
    regex="[^a-zA-Z0-9:/?&%=~._()-;]"

    # this will remove first @ that is after schema and before domain
    # \1 is optional schema, \2 is userinfo
    check_url="$(sed -re 's#([^:/]*://)?([^/]+)@#\1\2#' <<<"$url")"

    if [[ "${check_url}" =~ ${regex} ]]; then
      echo -e "  ${CROSS} 无效目标"
    else
      timeit gravity_DownloadBlocklistFromUrl "${url}" "${sourceIDs[$i]}" "${saveLocation}" "${compression}" "${adlist_type}" "${domain}"
    fi
    echo ""
  done

  DownloadBlocklists_done=true
}

compareLists() {
  local adlistID="${1}" target="${2}"

  # Verify checksum when an older checksum exists
  if [[ -s "${target}.sha1" ]]; then
    if ! sha1sum --check --status --strict "${target}.sha1"; then
      # The list changed upstream, we need to update the checksum
      sha1sum "${target}" >"${target}.sha1"
      fix_owner_permissions "${target}.sha1"
      echo "  ${INFO} 列表已更新"
      database_adlist_status "${adlistID}" "1"
    else
      echo "  ${INFO} 列表保持不变"
      database_adlist_status "${adlistID}" "2"
    fi
  else
    # No checksum available, create one for comparing on the next run
    sha1sum "${target}" >"${target}.sha1"
    fix_owner_permissions "${target}.sha1"
    # We assume here it was changed upstream
    database_adlist_status "${adlistID}" "1"
  fi
}

# Download specified URL and perform checks on HTTP status and file content
gravity_DownloadBlocklistFromUrl() {
  local url="${1}" adlistID="${2}" saveLocation="${3}" compression="${4}" gravity_type="${5}" domain="${6}"
  local listCurlBuffer str httpCode success="" ip customUpstreamResolver=""
  local file_path permissions ip_addr port blocked=false download=true
  # modifiedOptions is an array to store all the options used to check if the adlist has been changed upstream
  local modifiedOptions=()

  # Create temp file to store content on disk instead of RAM
  # We don't use '--suffix' here because not all implementations of mktemp support it, e.g. on Alpine
  listCurlBuffer="$(mktemp -p "${GRAVITY_TMPDIR}")"
  mv "${listCurlBuffer}" "${listCurlBuffer%.*}.phgpb"
  listCurlBuffer="${listCurlBuffer%.*}.phgpb"

  # For all remote files, we try to determine if the file has changed to skip
  # downloading them whenever possible.
  if [[ $url != "file"* ]]; then
    # Use the HTTP ETag header to determine if the file has changed if supported
    # by curl. Using ETags is supported by raw.githubusercontent.com URLs.
    if [[ "${etag_support}" == true ]]; then
      # Save HTTP ETag to the specified file. An ETag is a caching related header,
      # usually returned in a response. If no ETag is sent by the server, an empty
      # file is created and can later be used consistently.
      modifiedOptions=("${modifiedOptions[@]}" --etag-save "${saveLocation}".etag)

      if [[ -f "${saveLocation}.etag" ]]; then
        # This option makes a conditional HTTP request for the specific ETag read
        # from the given file by sending a custom If-None-Match header using the
        # stored ETag. This way, the server will only send the file if it has
        # changed since the last request.
        modifiedOptions=("${modifiedOptions[@]}" --etag-compare "${saveLocation}".etag)
      fi
    fi

    # Add If-Modified-Since header to the request if we did already download the
    # file once
    if [[ -f "${saveLocation}" ]]; then
      # Request a file that has been modified later than the given time and
      # date. We provide a file here which makes curl use the modification
      # timestamp (mtime) of this file.
      # Interstingly, this option is not supported by raw.githubusercontent.com
      # URLs, however, it is still supported by many older web servers which may
      # not support the HTTP ETag method so we keep it as a fallback.
      modifiedOptions=("${modifiedOptions[@]}" -z "${saveLocation}")
    fi
  fi

  str="状态:"
  echo -ne "  ${INFO} ${str} 等待中..."
  blocked=false
  # Check if this domain is blocked by Pi-hole but only if the domain is not a
  # local file or empty
  if [[ $url != "file"* ]] && [[ -n "${domain}" ]]; then
    case $(getFTLConfigValue dns.blocking.mode) in
    "IP-NODATA-AAAA" | "IP")
      # Get IP address of this domain
      ip="$(dig "${domain}" +short)"
      # Check if this IP matches any IP of the system
      if [[ -n "${ip}" && $(grep -Ec "inet(|6) ${ip}" <<<"$(ip a)") -gt 0 ]]; then
        blocked=true
      fi
      ;;
    "NXDOMAIN")
      if [[ $(dig "${domain}" | grep "NXDOMAIN" -c) -ge 1 ]]; then
        blocked=true
      fi
      ;;
    "NODATA")
      if [[ $(dig "${domain}" | grep "NOERROR" -c) -ge 1 ]] && [[ -z $(dig +short "${domain}") ]]; then
        blocked=true
      fi
      ;;
    "NULL" | *)
      if [[ $(dig "${domain}" +short | grep "0.0.0.0" -c) -ge 1 ]]; then
        blocked=true
      fi
      ;;
    esac

    if [[ "${blocked}" == true ]]; then
      # Get first defined upstream server
      local upstream
      upstream="$(getFTLConfigValue dns.upstreams)"

      # Isolate first upstream server from a string like
      # [ 1.2.3.4#1234, 5.6.7.8#5678, ... ]
      upstream="${upstream%%,*}"
      upstream="${upstream##*[}"
      upstream="${upstream%%]*}"
      # Trim leading and trailing spaces and tabs
      upstream="${upstream#"${upstream%%[![:space:]]*}"}"
      upstream="${upstream%"${upstream##*[![:space:]]}"}"

      # Get IP address and port of this upstream server
      local ip_addr port
      printf -v ip_addr "%s" "${upstream%#*}"
      if [[ ${upstream} != *"#"* ]]; then
        port=53
      else
        printf -v port "%s" "${upstream#*#}"
      fi
      ip=$(dig "@${ip_addr}" -p "${port}" +short "${domain}" | tail -1)
      if [[ $(echo "${url}" | awk -F '://' '{print $1}') = "https" ]]; then
        port=443
      else
        port=80
      fi
      echo -e "${OVER}  ${CROSS} ${str} ${domain} 被您的某个列表屏蔽。改为使用 DNS 服务器 ${upstream}"
      echo -ne "  ${INFO} ${str} 等待中..."
      customUpstreamResolver="--resolve $domain:$port:$ip"
    fi
  fi

  # If we are going to "download" a local file, we first check if the target
  # file has a+r permission. We explicitly check for all+read because we want
  # to make sure that the file is readable by everyone and not just the user
  # running the script.
  if [[ $url == "file://"* ]]; then
    # Get the file path
    file_path=$(echo "$url" | cut -d'/' -f3-)
    # Check if the file exists and is a regular file (i.e. not a socket, fifo, tty, block). Might still be a symlink.
    if [[ ! -f $file_path ]]; then
      # Output that the file does not exist
      echo -e "${OVER}  ${CROSS} ${file_path} 不存在"
      download=false
    else
      # Check if the file or a file referenced by the symlink has a+r permissions
      permissions=$(stat -L -c "%a" "$file_path")
      if [[ $permissions == *4 || $permissions == *5 || $permissions == *6 || $permissions == *7 ]]; then
        # Output that we are using the local file
        echo -e "${OVER}  ${INFO} 使用本地文件 ${file_path}"
      else
        # Output that the file does not have the correct permissions
        echo -e "${OVER}  ${CROSS} 无法读取文件（文件需要具有 a+r 权限）"
        download=false
      fi
    fi
  fi

  # Check for allowed protocols
  if [[ $url != "http"* && $url != "https"* && $url != "file"* && $url != "ftp"* && $url != "ftps"* && $url != "sftp"* ]]; then
    echo -e "${OVER}  ${CROSS} ${str} 指定了无效的协议。忽略列表。"
    echo -e "      确保您的 URL 以有效协议开头，例如 http:// 、https:// 或 file:// 。"
    download=false
  fi

  if [[ "${download}" == true ]]; then
    httpCode=$(curl --connect-timeout ${curl_connect_timeout} -s -L ${compression:+${compression}} ${customUpstreamResolver:+${customUpstreamResolver}} "${modifiedOptions[@]}" -w "%{http_code}" "${url}" -o "${listCurlBuffer}" 2>/dev/null)
  fi

  case $url in
  # Did we "download" a local file?
  "file"*)
    if [[ -s "${listCurlBuffer}" ]]; then
      echo -e "${OVER}  ${TICK} ${str} 检索成功"
      success=true
    else
      echo -e "${OVER}  ${CROSS} ${str} 检索失败 / 列表为空"
    fi
    ;;
  # Did we "download" a remote file?
  *)
    # Determine "Status:" output based on HTTP response
    case "${httpCode}" in
    "200")
      echo -e "${OVER}  ${TICK} ${str} 检索成功"
      success=true
      ;;
    "304")
      echo -e "${OVER}  ${TICK} ${str} 未检测到更改"
      success=true
      ;;
    "000") echo -e "${OVER}  ${CROSS} ${str} 连接被拒绝" ;;
    "403") echo -e "${OVER}  ${CROSS} ${str} 禁止访问" ;;
    "404") echo -e "${OVER}  ${CROSS} ${str} 未找到" ;;
    "408") echo -e "${OVER}  ${CROSS} ${str} 超时" ;;
    "451") echo -e "${OVER}  ${CROSS} ${str} 因法律原因不可用" ;;
    "500") echo -e "${OVER}  ${CROSS} ${str} 内部服务器错误" ;;
    "504") echo -e "${OVER}  ${CROSS} ${str} 连接超时（网关）" ;;
    "521") echo -e "${OVER}  ${CROSS} ${str} Web 服务器关闭 (Cloudflare)" ;;
    "522") echo -e "${OVER}  ${CROSS} ${str} 连接超时 (Cloudflare)" ;;
    *) echo -e "${OVER}  ${CROSS} ${str} ${url} (${httpCode})" ;;
    esac
    ;;
  esac

  local done="false"
  # Determine if the blocklist was downloaded and saved correctly
  if [[ "${success}" == true ]]; then
    if [[ "${httpCode}" == "304" ]]; then
      # Set list status to "unchanged/cached"
      database_adlist_status "${adlistID}" "2"
      # Add domains to database table file
      pihole-FTL "${gravity_type}" parseList "${saveLocation}" "${gravityTEMPfile}" "${adlistID}"
      done="true"
    # Check if $listCurlBuffer is a non-zero length file
    elif [[ -s "${listCurlBuffer}" ]]; then
      # Move the downloaded list to the final location
      mv "${listCurlBuffer}" "${saveLocation}"
      # Ensure the file has the correct permissions
      fix_owner_permissions "${saveLocation}"
      # Compare lists if they are identical
      compareLists "${adlistID}" "${saveLocation}"
      # Add domains to database table file
      pihole-FTL "${gravity_type}" parseList "${saveLocation}" "${gravityTEMPfile}" "${adlistID}"
      done="true"
    else
      # Fall back to previously cached list if $listCurlBuffer is empty
      echo -e "  ${INFO} 收到空文件"
    fi
  fi

  # Do we need to fall back to a cached list (if available)?
  if [[ "${done}" != "true" ]]; then
    # Determine if cached list has read permission
    if [[ -r "${saveLocation}" ]]; then
      echo -e "  ${CROSS} 列表下载失败：${COL_GREEN}使用先前缓存的列表${COL_NC}"
      # Set list status to "download-failed/cached"
      database_adlist_status "${adlistID}" "3"
      # Add domains to database table file
      pihole-FTL "${gravity_type}" parseList "${saveLocation}" "${gravityTEMPfile}" "${adlistID}"
    else
      echo -e "  ${CROSS} 列表下载失败：${COL_RED}没有可用的缓存列表${COL_NC}"
      # Manually reset these two numbers because we do not call parseList here
      database_adlist_number "${adlistID}" 0 0
      database_adlist_status "${adlistID}" "4"
    fi
  fi
}

# Report number of entries in a table
gravity_Table_Count() {
  local table="${1}"
  local str="${2}"
  local num
  num="$(pihole-FTL sqlite3 -ni "${gravityTEMPfile}" "SELECT COUNT(*) FROM ${table};")"
  if [[ "${table}" == "gravity" ]]; then
    local unique
    unique="$(pihole-FTL sqlite3 -ni "${gravityTEMPfile}" "SELECT COUNT(*) FROM (SELECT DISTINCT domain FROM ${table});")"
    echo -e "  ${INFO} ${str}的数量: ${num} (${COL_BOLD}${unique} 个唯一域名${COL_NC})"
    pihole-FTL sqlite3 -ni "${gravityTEMPfile}" "INSERT OR REPLACE INTO info (property,value) VALUES ('gravity_count',${unique});"
  else
    echo -e "  ${INFO} ${str}的数量: ${num}"
  fi
}

# Output count of denied and allowed domains and regex filters
gravity_ShowCount() {
  # Here we use the table "gravity" instead of the view "vw_gravity" for speed.
  # It's safe to replace it here, because right after a gravity run both will show the exactly same number of domains.
  gravity_Table_Count "gravity" "gravity 域名"
  gravity_Table_Count "domainlist WHERE type = 1 AND enabled = 1" "精确拒绝域名"
  gravity_Table_Count "domainlist WHERE type = 3 AND enabled = 1" "正则拒绝过滤器"
  gravity_Table_Count "domainlist WHERE type = 0 AND enabled = 1" "精确允许域名"
  gravity_Table_Count "domainlist WHERE type = 2 AND enabled = 1" "正则允许过滤器"
}

# Trap Ctrl-C
gravity_Trap() {
  trap '{ echo -e "\\n\\n  ${INFO} ${COL_RED}检测到用户中止${COL_NC}"; gravity_Cleanup "error"; }' INT
}

# Clean up after Gravity upon exit or cancellation
gravity_Cleanup() {
  local error="${1:-}"

  str="清理残留物"
  echo -ne "  ${INFO} ${str}..."

  # Delete tmp content generated by Gravity
  rm ${piholeDir}/pihole.*.txt 2>/dev/null
  rm ${piholeDir}/*.tmp 2>/dev/null
  # listCurlBuffer location
  rm "${GRAVITY_TMPDIR}"/*.phgpb 2>/dev/null
  # invalid_domains location
  rm "${GRAVITY_TMPDIR}"/*.ph-non-domains 2>/dev/null

  # Ensure this function only runs when gravity_DownloadBlocklists() has completed
  if [[ "${DownloadBlocklists_done:-}" == true ]]; then
    # Remove any unused .domains/.etag/.sha files
    for file in "${listsCacheDir}"/*."${domainsExtension}"; do
      # If list is not in active array, then remove it and all associated files
      if [[ ! "${activeDomains[*]}" == *"${file}"* ]]; then
        rm -f "${file}"* 2>/dev/null ||
          echo -e "  ${CROSS} 无法删除 ${file##*/}"
      fi
    done
  fi

  echo -e "${OVER}  ${TICK} ${str}"

  # Print Pi-hole status if an error occurred
  if [[ -n "${error}" ]]; then
    "${PIHOLE_COMMAND}" status
    exit 1
  fi
}

database_recovery() {
  local result
  local str="检查现有 gravity 数据库的完整性（这可能需要一段时间）"
  local option="${1}"
  echo -ne "  ${INFO} ${str}..."
  result="$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "PRAGMA integrity_check" 2>&1)"

  if [[ ${result} = "ok" ]]; then
    echo -e "${OVER}  ${TICK} ${str} - 未发现错误"

    str="检查现有 gravity 数据库的外键（这可能需要一段时间）"
    echo -ne "  ${INFO} ${str}..."
    unset result
    result="$(pihole-FTL sqlite3 -ni "${gravityDBfile}" "PRAGMA foreign_key_check" 2>&1)"
    if [[ -z ${result} ]]; then
      echo -e "${OVER}  ${TICK} ${str} - 未发现错误"
      if [[ "${option}" != "force" ]]; then
        return
      fi
    else
      echo -e "${OVER}  ${CROSS} ${str} - 发现错误："
      while IFS= read -r line; do echo "  - $line"; done <<<"$result"
    fi
  else
    echo -e "${OVER}  ${CROSS} ${str} - 发现错误："
    while IFS= read -r line; do echo "  - $line"; done <<<"$result"
  fi

  str="尝试恢复现有的 gravity 数据库"
  echo -ne "  ${INFO} ${str}..."
  # We have to remove any possibly existing recovery database or this will fail
  rm -f "${gravityDBfile}.recovered" >/dev/null 2>&1
  if result="$(pihole-FTL sqlite3 -ni "${gravityDBfile}" ".recover" | pihole-FTL sqlite3 -ni "${gravityDBfile}.recovered" 2>&1)"; then
    echo -e "${OVER}  ${TICK} ${str} - 成功"
    mv "${gravityDBfile}" "${gravityDBfile}.old"
    mv "${gravityDBfile}.recovered" "${gravityDBfile}"
    echo -ne " ${INFO} ${gravityDBfile} 已恢复"
    echo -ne " ${INFO} 旧的 ${gravityDBfile} 已移动到 ${gravityDBfile}.old"
  else
    echo -e "${OVER}  ${CROSS} ${str} - 发生了以下错误："
    while IFS= read -r line; do echo "  - $line"; done <<<"$result"
    echo -e "  ${CROSS} 恢复失败。请改试 \"pihole -r recreate\"。"
    exit 1
  fi
  echo ""
}

gravity_optimize() {
    # The ANALYZE command gathers statistics about tables and indices and stores
    # the collected information in internal tables of the database where the
    # query optimizer can access the information and use it to help make better
    # query planning choices
    local str="优化数据库"
    echo -ne "  ${INFO} ${str}..."
    output=$( { pihole-FTL sqlite3 -ni "${gravityTEMPfile}" "PRAGMA analysis_limit=0; ANALYZE" 2>&1; } 2>&1 )
    status="$?"

    if [[ "${status}" -ne 0 ]]; then
        echo -e "\\n  ${CROSS} 无法优化数据库 ${gravityTEMPfile}\\n  ${output}"
        gravity_Cleanup "error"
    else
        echo -e "${OVER}  ${TICK} ${str}"
    fi
}

# Function: timeit
# Description: Measures the execution time of a given command.
#
# Usage:
#   timeit <command>
#
# Parameters:
#   <command> - The command to be executed and timed.
#
# Returns:
#   The exit status of the executed command.
#
# Output:
#   If the 'timed' variable is set to true, prints the elapsed time in seconds
#   with millisecond precision.
#
# Example:
#   timeit ls -l
#
timeit(){
  local start_time end_time elapsed_time ret

  # Capture the start time
  start_time=$(date +%s%3N)

  # Execute the command passed as arguments
  "$@"
  ret=$?

  if [[ "${timed:-}" != true ]]; then
    return $ret
  fi

  # Capture the end time
  end_time=$(date +%s%3N)

  # Calculate the elapsed time
  elapsed_time=$((end_time - start_time))

  # Display the elapsed time
  printf "  %b--> 耗时 %d.%03d 秒%b\n" "${COL_BLUE}" $((elapsed_time / 1000)) $((elapsed_time % 1000)) "${COL_NC}"

  return $ret
}

migrate_to_listsCache_dir() {
  # If the ${listsCacheDir} directory already exists, this has been done before
  if [[ -d "${listsCacheDir}" ]]; then
    return
  fi

  # If not, we need to migrate the old files to the new directory
  local str="迁移列表缓存目录到新位置"
  echo -ne "  ${INFO} ${str}..."
  mkdir -p "${listsCacheDir}" && chown pihole:pihole "${listsCacheDir}"

  # Move the old files to the new directory
  if mv "${piholeDir}"/list.* "${listsCacheDir}/" 2>/dev/null; then
    echo -e "${OVER}  ${TICK} ${str}"
  else
    echo -e "${OVER}  ${CROSS} ${str}"
  fi

  # Update the list's paths in the corresponding .sha1 files to the new location
  sed -i "s|${piholeDir}/|${listsCacheDir}/|g" "${listsCacheDir}"/*.sha1 2>/dev/null
}

helpFunc() {
  echo "用法：pihole -g
从 adlists.list 中指定的屏蔽列表更新域名

选项：
  -f, --force          强制下载所有指定的屏蔽列表
  -t, --timeit         计时 gravity 更新过程
  -h, --help           显示此帮助对话框"
  exit 0
}

repairSelector() {
  case "$1" in
  "recover") recover_database=true ;;
  "recreate") recreate_database=true ;;
  *)
    echo "用法：pihole -g -r {recover,recreate}
尝试修复 gravity 数据库

可用选项：
  pihole -g -r recover        尝试恢复损坏的 gravity 数据库文件。
                              Pi-hole 尝试从损坏的 gravity 数据库恢复尽可能多的数据。

  pihole -g -r recover force  即使未检测到损坏，Pi-hole 也会运行恢复过程。
                              此选项旨在作为最后手段。恢复是一项脆弱的任务，
                              消耗大量资源，不应不必要地执行。

  pihole -g -r recreate       从头开始创建新的 gravity 数据库文件。
                              这将删除现有的 gravity 数据库并从头开始创建新文件。
                              如果您仍然拥有迁移到 Pi-hole v5.0 时创建的迁移备份，
                              Pi-hole 将导入这些文件。"
    exit 0
    ;;
  esac
}

for var in "$@"; do
  case "${var}" in
  "-f" | "--force") forceDelete=true ;;
  "-t" | "--timeit") timed=true ;;
  "-r" | "--repair") repairSelector "$3" ;;
  "-u" | "--upgrade")
    upgrade_gravityDB "${gravityDBfile}"
    exit 0
    ;;
  "-h" | "--help") helpFunc ;;
  esac
done

# Check if DNS is available, no need to do any database manipulation if we're not able to download adlists
if ! timeit gravity_CheckDNSResolutionAvailable; then
  echo -e "   ${CROSS} 没有可用的 DNS 解析。请联系支持。"
  exit 1
fi

# Remove OLD (backup) gravity file, if it exists
if [[ -f "${gravityOLDfile}" ]]; then
  rm "${gravityOLDfile}"
fi

# Trap Ctrl-C
gravity_Trap

if [[ "${recreate_database:-}" == true ]]; then
  str="从迁移备份重新创建 gravity 数据库"
  echo -ne "${INFO} ${str}..."
  rm "${gravityDBfile}"
  pushd "${piholeDir}" >/dev/null || exit
  cp migration_backup/* .
  popd >/dev/null || exit
  echo -e "${OVER}  ${TICK} ${str}"
fi

if [[ "${recover_database:-}" == true ]]; then
  timeit database_recovery "$4"
fi

# Migrate scattered list files to the new cache directory
migrate_to_listsCache_dir

# Move possibly existing legacy files to the gravity database
if ! timeit migrate_to_database; then
  echo -e "   ${CROSS} 无法迁移到数据库。请联系支持。"
  exit 1
fi

if [[ "${forceDelete:-}" == true ]]; then
  str="删除现有的列表缓存"
  echo -ne "  ${INFO} ${str}..."

  rm "${listsCacheDir}/list.*" 2>/dev/null || true
  echo -e "${OVER}  ${TICK} ${str}"
fi

# Gravity downloads blocklists next
if ! gravity_DownloadBlocklists; then
  echo -e "   ${CROSS} 无法创建 gravity 数据库。请稍后重试。如果问题仍然存在，请联系支持。"
  exit 1
fi

# Update gravity timestamp
update_gravity_timestamp

# Ensure proper permissions are set for the database
fix_owner_permissions "${gravityTEMPfile}"

# Build the tree
timeit gravity_build_tree

# Compute numbers to be displayed (do this after building the tree to get the
# numbers quickly from the tree instead of having to scan the whole database)
timeit gravity_ShowCount

# Optimize the database
timeit gravity_optimize

# Migrate rest of the data from old to new database
# IMPORTANT: Swapping the databases must be the last step before the cleanup
if ! timeit gravity_swap_databases; then
  echo -e "   ${CROSS} 无法创建数据库。请联系支持。"
  exit 1
fi

timeit gravity_Cleanup
echo ""

echo "  ${TICK} 完成。"

# "${PIHOLE_COMMAND}" status
