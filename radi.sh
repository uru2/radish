#!/bin/sh
#
# Japan internet radio live streaming recoder
# Copyright (C) 2019 uru (https://twitter.com/uru_2)
# License is MIT (see LICENSE file)
set -u

#######################################
# Show usage
# Arguments:
#   None
# Returns:
#   None
#######################################
show_usage() {
  cat << _EOT_
Usage: $(basename "$0") [options]
Options:
  -t TYPE         Record type
                    nhk: NHK Radidu
                    radiko: radiko
                    lisradi: ListenRadio
                    shiburadi: Shibuya no Radio
  -s STATION ID   Station ID
  -d MINUTE       Record minute(s)
  -o FILEPATH     Output file path
  -i ADDRESS      login mail address (radiko only)
  -p PASSWORD     login password (radiko only)
  -l              Show all station ID list
_EOT_
}

#######################################
# Show all station ID and name
# Arguments:
#   None
# Returns:
#   None
#######################################
show_all_stations() {
  # Radiru
  echo "Record type: nhk"
  list=$(curl --silent "https://www.nhk.or.jp/radio/config/config_v5.8.0_radiru_and.xml")
  cnt=$(echo "${list}" | xmllint --xpath "count(/radiru_config/area)" - 2> /dev/null)
  for i in $(awk "BEGIN { for (i = 1; i <= ${cnt}; i++) { print i } }"); do
    echo "  $(echo "${list}" | xmllint --xpath "concat(string((/radiru_config/area)[${i}]/@id), '-r1: ', string((/radiru_config/area)[${i}]/@name), ' R1')" - 2> /dev/null)"
    echo "  $(echo "${list}" | xmllint --xpath "concat(string((/radiru_config/area)[${i}]/@id), '-fm: ', string((/radiru_config/area)[${i}]/@name), ' FM')" - 2> /dev/null)"
  done
  echo "  r2: R2"
  echo ""

  # radiko
  echo "Record type: radiko"
  list=$(curl --silent "https://radiko.jp/v3/station/region/full.xml")
  cnt=$(echo "${list}" | xmllint --xpath "count(/region/stations/station)" - 2> /dev/null)
  for i in $(awk "BEGIN { for (i = 1; i <= ${cnt}; i++) { print i } }"); do
    echo "  $(echo "${list}" | xmllint --xpath "concat((/region/stations/station)[${i}]/id/text(), ': ', (/region/stations/station)[${i}]/name/text())" - 2> /dev/null)"
  done
  echo ""

  # ListenRadio
  echo "Record site type: lisradi"
  curl --silent "http://listenradio.jp/service/channel.aspx" | jq -r '.Channel[] | "  " + (.ChannelId | tostring) + ": " + .ChannelName' 2> /dev/null
  echo ""

  # Shibuya no Radio
  echo "Record type: shiburadi"
  echo "  None"
  echo ""
}

#######################################
# Radiko Login
# Arguments:
#   Mail address
#   Password
# Returns:
#   0: Success
#   1: Failed
#######################################
login_radiko() {
  mail=$1
  password=$2

  # Login
  login_json=$(curl \
      --silent \
      --request POST \
      --data-urlencode "mail=${mail}" \
      --data-urlencode "pass=${password}" \
      --output - \
      "https://radiko.jp/v4/api/member/login")

  # Extract login result
  radiko_session=$(echo "${login_json}" | jq -r ".radiko_session")
  areafree=$(echo "${login_json}" | jq -r ".areafree")

  # Check login
  if [ -z "${radiko_session}" ] || [ "${areafree}" != "1" ]; then
    return 1
  fi

  echo "${radiko_session}"
  return 0
}

#######################################
# Radiko Logout
# Arguments:
#   radiko Session
# Returns:
#   None
#######################################
logout_radiko() {
  radiko_session=$1

  # Logout
  curl \
    --silent \
    --request POST \
    --data-urlencode "radiko_session=${radiko_session}" \
    --output /dev/null \
    "https://radiko.jp/v4/api/member/logout"
}

#######################################
# Authorize radiko
# Arguments:
#   radiko Session
# Returns:
#   0: Success
#   1: Failed
#######################################
radiko_authorize() {
  radiko_session=$1  

  # Define authorize key value (from https://radiko.jp/apps/js/playerCommon.js)
  RADIKO_AUTHKEY_VALUE="bcd151073c03b352e1ef2fd66c32209da9ca0afa"

  # Authorize 1
  auth1_res=$(curl \
      --silent \
      --header "X-Radiko-App: pc_html5" \
      --header "X-Radiko-App-Version: 0.0.1" \
      --header "X-Radiko-Device: pc" \
      --header "X-Radiko-User: dummy_user" \
      --dump-header - \
      --output /dev/null \
      "https://radiko.jp/v2/api/auth1")

  # Get partial key
  authtoken=$(echo "${auth1_res}" | awk 'tolower($0) ~/^x-radiko-authtoken: / {print substr($0,21,length($0)-21)}')
  keyoffset=$(echo "${auth1_res}" | awk 'tolower($0) ~/^x-radiko-keyoffset: / {print substr($0,21,length($0)-21)}')
  keylength=$(echo "${auth1_res}" | awk 'tolower($0) ~/^x-radiko-keylength: / {print substr($0,21,length($0)-21)}')
  if [ -z "${authtoken}" ] || [ -z "${keyoffset}" ] || [ -z "${keylength}" ]; then
    return 1
  fi
  partialkey=$(echo "${RADIKO_AUTHKEY_VALUE}" | dd bs=1 "skip=${keyoffset}" "count=${keylength}" 2> /dev/null | base64)

  # Authorize 2
  auth2_url_param=""
  if [ -n "${radiko_session}" ]; then
    auth2_url_param="?radiko_session=${radiko_session}"
  fi
  curl \
      --silent \
      --header "X-Radiko-Device: pc" \
      --header "X-Radiko-User: dummy_user" \
      --header "X-Radiko-AuthToken: ${authtoken}" \
      --header "X-Radiko-PartialKey: ${partialkey}" \
      --output /dev/null \
      "https://radiko.jp/v2/api/auth2${auth2_url_param}"
  ret=$?
  if [ ${ret} -ne 0 ]; then
    return 1
  fi

  echo "${authtoken}"
  return 0
}

#######################################
# Get NHK Radiru HLS streaming URI
# Arguments:
#   Station ID
# Returns:
#   None
#######################################
get_hls_uri_nhk() {
  station_id=$1

  if [ "${station_id}" = "r2" ]; then
    # R2
    curl --silent "https://www.nhk.or.jp/radio/config/config_v5.8.0_radiru_and.xml" | xmllint --xpath "string(/radiru_config/config[@key='url_stream_r2']/value[1]/@text)" - 2> /dev/null
  else
    # Split area and channel
    area="$(echo "${station_id}" | cut -d '-' -f 1)"
    channel="$(echo "${station_id}" | cut -d '-' -f 2)"
    curl --silent "https://www.nhk.or.jp/radio/config/config_v5.8.0_radiru_and.xml" | xmllint --xpath "string(/radiru_config/area[@id='${area}']/config[@key='url_stream_${channel}']/value[1]/@text)" - 2> /dev/null
  fi
}

#######################################
# Get radiko HLS streaming URI
# Arguments:
#   Station ID
#   radiko login status
# Returns:
#   None
#######################################
get_hls_uri_radiko() {
  station_id=$1
  radiko_login_status=$2

  areafree="0"
  if [ "${radiko_login_status}" = "1" ]; then
    areafree="1"
  fi

  curl --silent "https://radiko.jp/v2/station/stream_smh_multi/${station_id}.xml" | xmllint --xpath "/urls/url[@areafree='${areafree}'][1]/playlist_create_url/text()" - 2> /dev/null
}

#######################################
# Get ListenRadio HLS streaming URI
# Arguments:
#   Station ID
# Returns:
#   None
#######################################
get_hls_uri_lisradi() {
  station_id=$1

  curl --silent "http://listenradio.jp/service/channel.aspx" | jq -r ".Channel[] | select(.ChannelId == ${station_id}) | .ChannelHls" 2> /dev/null
}

#######################################
# Get Shibuya no Radio HLS streaming URI
# Arguments:
#   None
# Returns:
#   None
#######################################
get_hls_uri_shiburadi() {
  curl --silent "https://shibuyanoradio.info/infoapi/?ver=1.1" | jq -r ".basicinfo.hls_playback" 2> /dev/null
}

#######################################
# Format time text
# Arguments:
#   Time minute
# Returns:
#   None
#######################################
format_time() {
  minute=$1

  hour=$((minute / 60))
  minute=$((minute % 60))

  printf "%02d:%02d:%02d" "${hour}" "${minute}" "0"
}


##### Main routine start #####

# Argument none?
if [ $# -lt 1 ]; then
  show_usage
  exit 1
fi

# Parse argument
type=""
station_id=""
duration=0
output=""
login_id=""
login_password=""
while getopts t:s:d:o:i:p:l option; do
  case "${option}" in
    t)
      type="${OPTARG}"
      ;;
    s)
      station_id="${OPTARG}"
      ;;
    d)
      duration="${OPTARG}"
      ;;
    o)
      output="${OPTARG}"
      ;;
    i)
      login_id="${OPTARG}"
      ;;
    p)
      login_password="${OPTARG}"
      ;;
    l)
      show_all_stations
      exit 0
      ;;
    \?)
      show_usage
      exit 1
      ;;
  esac
done

# Set value from ENV
if [ "${type}" = "radiko" ]; then
  if [ -z "${login_id}" ]; then
    env | grep -q -E "^RADIKO_MAIL="
    ret=$?
    if [ ${ret} -eq 0 ]; then
      login_id="${RADIKO_MAIL}"
    fi
  fi
  if [ -z "${login_password}" ]; then
    env | grep -q -E "^RADIKO_PASSWORD="
    ret=$?
    if [ ${ret} -eq 0 ]; then
      login_password="${RADIKO_PASSWORD}"
    fi
  fi
fi

# Check argument parameter
if [ -z "${type}" ]; then
  # -t value is empty
  echo "Require \"Type\"" >&2
  exit 1
fi
echo "${duration}" | grep -q -E "^[0-9]+$"
ret=$?
if [ ${ret} -ne 0 ]; then
  # -d value is invalid
  echo "Invalid \"Record minute\"" >&2
  exit 1
fi
if [ "${type}" = "shiburadi" ]; then
  station_id="shiburadi"
else
  if [ -z "${station_id}" ]; then
    # -s value is empty
    echo "Require \"Station ID\"" >&2
    exit 1
  fi
fi

# Generate default file path
file_ext="m4a"
if [ "${type}" = "shiburadi" ]; then
  file_ext="mp3"
fi
if [ -z "${output}" ]; then
  output="${station_id}_$(date +%Y%m%d%H%M%S).${file_ext}"
else
  # Fix file path extension
  echo "${output}" | grep -q -E "\\.${file_ext}$"
  ret=$?
  if [ ${ret} -ne 0 ]; then
    output="${output}.${file_ext}"
  fi
fi

playlist_uri=""
radiko_authtoken=""

# Record type processes
if [ "${type}" = "nhk" ]; then
  # NHK
  playlist_uri=$(get_hls_uri_nhk "${station_id}")
elif [ "${type}" = "lisradi" ]; then
  # ListenRadio
  playlist_uri=$(get_hls_uri_lisradi "${station_id}")
elif [ "${type}" = "shiburadi" ]; then
  # Shibuya no Radio
  playlist_uri=$(get_hls_uri_shiburadi)
elif [ "${type}" = "radiko" ]; then
  # radiko
  radiko_session=""
  radiko_login_status="0"

  # Login radiko premium
  if [ -n "${login_id}" ]; then
    radiko_session=$(login_radiko "${login_id}" "${login_password}")
    ret=$?
    if [ ${ret} -ne 0 ]; then
      echo "Cannot login radiko premium" >&2
      exit 1
    fi

    # Register radiko logout handler
    trap "logout_radiko ""${radiko_session}""" EXIT HUP INT QUIT TERM

    radiko_login_status="1"
  fi

  # Authorize
  radiko_authtoken=$(radiko_authorize "${radiko_session}")
  ret=$?
  if [ ${ret} -ne 0 ]; then
    echo "radiko authorize failed" >&2
    exit 1
  fi

  playlist_uri=$(get_hls_uri_radiko "${station_id}" "${radiko_login_status}")
fi
if [ -z "${playlist_uri}" ]; then
  echo "Cannot get playlist URI" >&2
  exit 1
fi

# Record
if [ "${type}" = "radiko" ]; then
  ffmpeg \
      -loglevel error \
      -fflags +discardcorrupt \
      -headers "X-Radiko-Authtoken: ${radiko_authtoken}" \
      -i "${playlist_uri}" \
      -acodec copy \
      -vn \
      -bsf:a aac_adtstoasc \
      -y \
      -t "$(format_time "${duration}")" \
      "${output}"
elif [ "${type}" = "shiburadi" ]; then
  ffmpeg \
      -loglevel error \
      -fflags +discardcorrupt \
      -i "${playlist_uri}" \
      -acodec copy \
      -vn \
      -y \
      -t "$(format_time "${duration}")" \
      "${output}"
else
  ffmpeg \
      -loglevel error \
      -fflags +discardcorrupt \
      -i "${playlist_uri}" \
      -acodec copy \
      -vn \
      -bsf:a aac_adtstoasc \
      -y \
      -t "$(format_time "${duration}")" \
      "${output}"
fi
ret=$?
if [ ${ret} -ne 0 ]; then
  echo "Record failed" >&2
  exit 1
fi

# Finish
exit 0
##### Main routine end #####
