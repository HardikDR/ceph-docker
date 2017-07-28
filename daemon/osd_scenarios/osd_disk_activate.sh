#!/bin/bash
set -e

function osd_activate {
  if [[ -z "${OSD_DEVICE}" ]];then
    log "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  CEPH_DISK_OPTIONS=()
  DATA_UUID=$(blkid -o value -s PARTUUID "${OSD_DEVICE}"1)
  LOCKBOX_UUID=$(blkid -o value -s PARTUUID "${OSD_DEVICE}"3 || true)

  # watch the udev event queue, and exit if all current events are handled
  udevadm settle --timeout=600

  apply_ceph_ownership_to_disks

  DATA_PART=$(dev_part "${OSD_DEVICE}" 1)
  MOUNTED_PART=${DATA_PART}

  if [[ ${OSD_DMCRYPT} -eq 1 ]]; then
    echo "Mounting LOCKBOX directory"
    # NOTE(leseb): adding || true so when this bug will be fixed the entrypoint will not fail
    # Ceph bug tracker: http://tracker.ceph.com/issues/18945
    mkdir -p /var/lib/ceph/osd-lockbox/"${DATA_UUID}"
    mount /dev/disk/by-partuuid/"${LOCKBOX_UUID}" /var/lib/ceph/osd-lockbox/"${DATA_UUID}" || true
    CEPH_DISK_OPTIONS+=('--dmcrypt')
    MOUNTED_PART="/dev/mapper/${DATA_UUID}"
  fi

  if [[ -z "${CEPH_DISK_OPTIONS[*]}" ]]; then
    ceph-disk -v --setuser ceph --setgroup disk activate --no-start-daemon "${DATA_PART}"
  else
    ceph-disk -v --setuser ceph --setgroup disk activate "${CEPH_DISK_OPTIONS[@]}" --no-start-daemon "${DATA_PART}"
  fi

  OSD_ID=$(grep "${MOUNTED_PART}" /proc/mounts | awk '{print $2}' | grep -oh '[0-9]*')
  OSD_PATH=$(get_osd_path "$OSD_ID")
  OSD_KEYRING="$OSD_PATH/keyring"
  if [[ ${OSD_BLUESTORE} -eq 1 ]] && [ -e "${OSD_PATH}block" ]; then
    OSD_WEIGHT=$(awk "BEGIN { d= $(blockdev --getsize64 "${OSD_PATH}"block)/1099511627776 ; r = sprintf(\"%.2f\", d); print r }")
  else
    OSD_WEIGHT=$(df -P -k "$OSD_PATH" | tail -1 | awk '{ d= $2/1073741824 ; r = sprintf("%.2f", d); print r }')
  fi

  # only add crush_location if the current is empty
  local crush_loc
  crush_loc=$(ceph "${CLI_OPTS[@]}" --name=osd."${OSD_ID}" --keyring="$OSD_KEYRING" osd find "${OSD_ID}"|python -c 'import sys, json; print(json.load(sys.stdin)["crush_location"])')
  if [[ "$crush_loc" == "{}" ]]; then
    ceph "${CLI_OPTS[@]}" --name=osd."${OSD_ID}" --keyring="$OSD_KEYRING" osd crush create-or-move -- "${OSD_ID}" "${OSD_WEIGHT}" "${CRUSH_LOCATION[@]}"
  fi

  log "SUCCESS"
  exec /usr/bin/ceph-osd "${CLI_OPTS[@]}" -f -i "${OSD_ID}" --setuser ceph --setgroup disk
}
