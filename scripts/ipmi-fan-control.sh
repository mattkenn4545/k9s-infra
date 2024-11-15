#!/usr/bin/env bash
set -e
set -o pipefail

# ----------------------------------------------------------------------------------
# Automatically setting fan speed via IPMI 
#
# Requires:
# ipmitool = apt-get install ipmitool
# bc = apt-get install bc
# ----------------------------------------------------------------------------------

#### Config
## IPMI
IPMI_HOST=${IPMI_HOST:-$(hostname).mgmt.$(hostname -d)}
IPMI_USER=${IPMI_USER:-root}
IPMI_PW=${IPMI_PW:-calvin}
IPMI_EK=${IPMI_EK:-0000000000000000000000000000000000000000}
#IPMI_BASE_CMD="ipmitool -I lanplus -H ${IPMI_HOST} -U ${IPMI_USER} -P ${IPMI_PW} -y ${IPMI_EK}"
IPMI_BASE_CMD="ipmitool -y ${IPMI_EK}"

## Temp
# Ambient
AMBIENT_TEMP_CMD=${AMBIENT_TEMP_CMD:-"${IPMI_BASE_CMD} sensor reading 'Ambient Temp' | tr -s ' ' | cut -d ' ' -f 4"}
AMBIENT_TEMP_MIN=${AMBIENT_TEMP_MIN:-23}
AMBIENT_TEMP_MAX=${AMBIENT_TEMP_MAX:-43}
# Device
DEVICE_TEMP_CMD=${DEVICE_TEMP_CMD:-"smartctl --all /dev/nvme0n1 | grep 'Temperature:' | tr -s ' ' | cut -d ' ' -f 2"}
#DEVICE_TEMP_CMD="mget_temp -d $(lspci | grep MT27700 | tail -n 1 | cut -d " " -f 1 | tr -s ' ')"
DEVICE_TEMP_BIAS=${DEVICE_TEMP_BIAS:-4}
DEVICE_TEMP_MIN=${DEVICE_TEMP_MIN:-35}
DEVICE_TEMP_MIN_OVERRIDE='AMBIENT_TEMP'
DEVICE_TEMP_MAX=${DEVICE_TEMP_MAX:-$(smartctl --all /dev/nvme0n1 | grep 'Critical Comp. Temp. Threshold:' | tr -s ' ' | rev | cut -d ' ' -f2 | rev)}
## Fan
FAN_PERCENT_MIN=${FAN_PERCENT_MIN:-5}
FAN_PERCENT_MAX=${FAN_PERCENT_MAX:-65}


## Misc
CHECK_INTERVAL=10

#### Trap
fallback() {
  echo 'Stopping Active Control, fallback to automatic fan control'
  $IPMI_BASE_CMD raw 0x30 0x30 0x02 0xff "0x$(printf '%x\n' "$FAN_PERCENT_MAX")" >/dev/null
  sleep 5
  ## Enable automatic fan control
  $IPMI_BASE_CMD raw 0x30 0x30 0x01 0x01 >/dev/null
}

trap fallback ERR
trap fallback EXIT
trap fallback SIGTERM

#--------------Do not edit below this line--------------

scriptupdate=$(mktemp)

#### Script
echo "Beginning active fan control....  Ambient Temp Min(Max):${AMBIENT_TEMP_MIN}c(${AMBIENT_TEMP_MAX}c) Device Temp Min(Max):${DEVICE_TEMP_MIN_OVERRIDE:-"${DEVICE_TEMP_MIN}c"}(${DEVICE_TEMP_MAX}c) Fan Min(Max):${FAN_PERCENT_MIN}%(${FAN_PERCENT_MAX}%) Device Temp Bias: ${DEVICE_TEMP_BIAS}X"
echo "--- IPMI_HOST: ${IPMI_HOST} IPMI_USER: ${IPMI_USER}"

# Disable automatic fan control
$IPMI_BASE_CMD raw 0x30 0x30 0x01 0x00 >/dev/null

# Spin up to FAN_PERCENT_MAX
$IPMI_BASE_CMD raw 0x30 0x30 0x02 0xff "0x$(printf '%x\n' "$FAN_PERCENT_MAX")" >/dev/null
sleep 2

# Main loop
while true
do
  if [[ $0 -nt $scriptupdate ]]; then
    echo '--- New version detected, terminating main loop!'
    break
  fi
  check_count=$((check_count+1))

  DEVICE_TEMP=$(bash -c "${DEVICE_TEMP_CMD} | cut -d ' ' -f 1")
  AMBIENT_TEMP=$(bash -c "${AMBIENT_TEMP_CMD} | cut -d ' ' -f 1")

  if [[ -n $DEVICE_TEMP_MIN_OVERRIDE ]]; then
    DEVICE_TEMP_MIN=${!DEVICE_TEMP_MIN_OVERRIDE}
  fi

  if [ -z "${DEVICE_TEMP}" ] || [ -z "${AMBIENT_TEMP}" ]; then
    # If the condition that caused this to trigger is not resolved fans will spin up and down repeatedly as the service starts and then ends in error
    echo "Unable to determine DEVICE_TEMP (${DEVICE_TEMP}) or AMBIENT_TEMP (${AMBIENT_TEMP}). Exiting!"
    exit 1
  fi

  ## Clamp RATIOs to ensure curve remains between MIN/MAX
  # Device
  if [ "$DEVICE_TEMP" -ge "$DEVICE_TEMP_MAX" ]; then
    FAN_RATIO_DEVICE=1
  elif [ "$DEVICE_TEMP" -lt "$DEVICE_TEMP_MIN" ]; then
    FAN_RATIO_DEVICE=0
  else
    FAN_RATIO_DEVICE=$(echo "scale=4;($DEVICE_TEMP - $DEVICE_TEMP_MIN) / ($DEVICE_TEMP_MAX - $DEVICE_TEMP_MIN)" | bc)
  fi
  # Ambient
  if [ "$AMBIENT_TEMP" -ge "$AMBIENT_TEMP_MAX" ]; then
    FAN_RATIO_AMBIENT=1
  elif [ "$AMBIENT_TEMP" -lt "$AMBIENT_TEMP_MIN" ]; then
    FAN_RATIO_AMBIENT=0
  else
    FAN_RATIO_AMBIENT=$(echo "scale=4;($AMBIENT_TEMP - $AMBIENT_TEMP_MIN) / ($AMBIENT_TEMP_MAX - $AMBIENT_TEMP_MIN)" | bc)
  fi

  # AMBIENT ratio is NOT accounted for in the denominator here ie it is not a 'true' average.  This means FAN_RATIO
  # can go above 1 if both AMBIENT and DEVICE temps are at or near MAX.  This allows fans to 'boost' if temps start
  # to get crazy.
  FAN_RATIO=$(echo "scale=4; (($FAN_RATIO_DEVICE * $DEVICE_TEMP_BIAS) + $FAN_RATIO_AMBIENT) / $DEVICE_TEMP_BIAS" | bc)

  FAN_PERCENT_LAST=${FAN_PERCENT:-100}
  FAN_PERCENT=$(echo "scale=2;(($FAN_PERCENT_MAX - $FAN_PERCENT_MIN) * $FAN_RATIO + $FAN_PERCENT_MIN)" | bc | cut -d '.' -f 1)

  # If $FAN_PERCENT > 100% clamp.  This can occur when DEVICE and AMBIENT temps are at/near threshold.
  if [ "$FAN_PERCENT" -gt "100" ]; then
    FAN_PERCENT=100
  fi

  # Set fan speed
  FAN_PERCENT_HEX="0x$(printf '%x\n' "$FAN_PERCENT")"
  $IPMI_BASE_CMD raw 0x30 0x30 0x02 0xff "${FAN_PERCENT_HEX}" >/dev/null

  sleep $CHECK_INTERVAL

  # Only log if $FAN_PERCENT is changed
  if [ "$FAN_PERCENT_LAST" -ne "$FAN_PERCENT" ]; then
    log="\
Device: ${DEVICE_TEMP}c | \
Ambient Temp(+device): ${AMBIENT_TEMP}c(+$((DEVICE_TEMP - AMBIENT_TEMP))c) | \
Fan Ratio(Device/Ambient): ${FAN_RATIO}(${FAN_RATIO_DEVICE}/${FAN_RATIO_AMBIENT}) | \
Final Fan%(hex): ${FAN_PERCENT}(${FAN_PERCENT_HEX})"
    FAN_RPM=$(${IPMI_BASE_CMD} sensor reading "FAN 1 RPM" | tr -s "  " " " | cut -d " " -f 5)
    echo "${log} RPM: ${FAN_RPM} Checks Since Last Change: ${check_count}"
    check_count=0
  fi
done

echo '--- Graceful exit all is well!'