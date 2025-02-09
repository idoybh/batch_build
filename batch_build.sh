#!/bin/bash
DEVICE_FILE="build_targets.txt"
STATUS_FILE="build_progress.txt"
BUILD_SCRIPT="makeBuild.sh"
TG_STATUS_CONF="publicGroup.conf"
TG_UPDATE_CONF="updates.conf"
OTA_REPO="https://github.com/yaap/ota-info.git"
OTA_BRANCH="full-signed"
BANNER_REPO="https://github.com/yaap/banners"
BANNER_BRANCH="master"
FILE_SERVER="https://mirror.codebucket.de/yaap"
ANDROID_VERSION=""
ANDROID_VERSION_MINOR=""
BUILD_CODENAME=""
BUILD_MATCHING="YAAP-*.zip"
BACKUP_DIR="/run/media/ido/HDD/Backups/yaap-ftp"
MAX_RETRIES=1
ENDING_TAG="@idoybh2"

# Colors
RED="\033[1;31m" # For errors / warnings
GREEN="\033[1;32m" # For info
YELLOW="\033[1;33m" # For input requests
BLUE="\033[1;36m" # For info
NC="\033[0m" # reset color

# functions

# formats the time passed relative to $start_time and stores it in $buildTime
buildTime=""
start_time=$(date +"%s")
end_time=$(date +"%s")
get_time()
{
  end_time=$(date +"%s")
  tdiff=$(( end_time - start_time )) # time diff

  # Formatting total build time
  hours=$(( tdiff / 3600 ))
  hoursOut=$hours
  if [[ ${#hours} -lt 2 ]]; then
    hoursOut="0${hours}"
  fi

  mins=$(((tdiff % 3600) / 60))
  minsOut=$mins
  if [[ ${#mins} -lt 2 ]]; then
    minsOut="0${mins}"
  fi

  secs=$((tdiff % 60))
  if [[ ${#secs} -lt 2 ]]; then
    secs="0${secs}"
  fi

  buildTime="" # will store the formatted time to output
  if [[ $hours -gt 0 ]]; then
    buildTime="${hoursOut}:${minsOut}:${secs} (hh:mm:ss)"
  elif [[ $mins -gt 0 ]]; then
    buildTime="${minsOut}:${secs} (mm:ss)"
  else
    buildTime="${secs} seconds"
  fi
}

# shellcheck disable=SC2317
function tg_clean()
{
  ./telegramSend.sh --config $TG_STATUS_CONF "Batch build was stopped / canceled externally"
  ./telegramSend.sh --unpin --tmp $tgTmp --config $TG_STATUS_CONF " "
  exit 1
}

# handle flags
isDirty=0
isClean=0
isInt=0
isUploadOnly=0
isOTAOnly=0
isResume=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            # dirty
            isDirty=1
            shift
        ;;
        -c)
            # clean build (skip the confirmation)
            isClean=1
            shift
        ;;
        -i)
            # interactive
            isInt=1
            shift
        ;;
        -u)
            # upload only
            isUploadOnly=1
            shift
        ;;
        -o)
            # ota and notify only
            isOTAOnly=1
            shift
        ;;
        -r)
            # resume
            isResume=1
            shift
        ;;
    esac
done

# making sure we have changelogs folder, otherwise init
if [ ! -d "changelogs" ]; then
    mkdir changelogs
    isInt=1
    echo -e "${RED}No changelogs folder. Forcing interactive${NC}"
fi

# making sure we have $DEVICE_FILE, otherwise init
if [ ! -f $DEVICE_FILE ]; then
    touch $DEVICE_FILE
    isInt=1
    echo -e "${RED}No ${DEVICE_FILE}. Forcing interactive${NC}"
fi

# making sure we have a conf for each target
while read -r -u9 DEVICE; do
    # ignore comments
    [[ ${DEVICE:0:1} == '#' ]] && continue
    # ignore flags
    DEVICE=$(echo "$DEVICE" | cut -d " " -f 1)
    if [ ! -f "${DEVICE}.conf" ]; then
        isInt=1
        echo -e "${RED}No ${DEVICE}.conf file. Forcing interactive${NC}"
    fi
done 9< $DEVICE_FILE

# interactive update of changelogs and infos
if [[ $isInt == 1 ]]; then
    echo -e "Current env editor is ${BLUE}${EDITOR}${NC}"
    echo -en "Enter blank to keep or an editor to change: "
    read -r ans
    if [[ $ans != "" ]]; then
        EDITOR=$ans
    fi
    echo -en "Edit ${BLUE}targets${NC}? [y]/n > "
    read -r ans
    if [[ $ans != 'n' ]]; then
        $EDITOR $DEVICE_FILE
    fi
    echo -en "Edit ${BLUE}rom changelog${NC}? [y]/n > "
    read -r ans
    if [[ $ans != 'n' ]]; then
        $EDITOR ./changelogs/ROM.txt
    fi
    echo -en "Edit ${BLUE}device infos${NC}? y/[n] > "
    read -r isEditDI
    echo -en "Edit ${BLUE}device build configs${NC}? y/[n] > "
    read -r isEditBC
    # for each line of $DEVICE_FILE
    while read -r -u9 DEVICE; do
        # ignore comments
        [[ ${DEVICE:0:1} == '#' ]] && continue
        # ignore flags
        DEVICE=$(echo "$DEVICE" | cut -d " " -f 1)

        # info files
        if [[ ! -f "./changelogs/${DEVICE}.info" ]] || [[ $isEditDI == 'y' ]]; then
            ans='y'
            if [[ -f "./changelogs/${DEVICE}.info" ]]; then
                # ask only when there is a file, force otherwise
                echo -en "Edit ${BLUE}${DEVICE}${NC} info? [y]/n > "
                read -r ans
                [[ $ans != 'n' ]] && ans='y'
            else
                touch "./changelogs/${DEVICE}.info"
            fi
            [[ $ans == 'y' ]] && $EDITOR "./changelogs/${DEVICE}.info"
        fi

        # build configs
        if [[ ! -f "./${DEVICE}.conf" ]] || [[ $isEditBC == 'y' ]]; then
            ans='y'
            if [[ -f "./${DEVICE}.conf" ]]; then
                # ask only when there is a file, force otherwise
                echo -en "Edit ${BLUE}${DEVICE}${NC} config file? [y]/n > "
                read -r ans
                [[ $ans != 'n' ]] && ans='y'
            else
                touch "./${DEVICE}.conf"
            fi
            [[ $ans == 'y' ]] && $EDITOR "./${DEVICE}.conf"
        fi
    done 9< $DEVICE_FILE

    # changelogs
    # for each line of $DEVICE_FILE
    clData=""
    haveData=0
    while read -r -u9 DEVICE; do
        # ignore comments
        [[ ${DEVICE:0:1} == '#' ]] && continue
        # ignore flags
        DEVICE=$(echo "$DEVICE" | cut -d " " -f 1)

        cFile="./changelogs/${DEVICE}.txt"
        if [[ $haveData != 0 ]]; then
            echo -en "Use the ${BLUE}saved${NC} data for ${BLUE}${DEVICE}${NC} changelog? [y]/n > "
            read -r ans
            if [[ $ans != 'n' ]]; then
                echo "${clData}" > "${cFile}"
                continue
            fi
        fi
        echo -en "Edit ${BLUE}${DEVICE}${NC} changelog? [y]/n > "
        read -r ans
        [[ $ans == 'n' ]] && continue
        if [ ! -f "${cFile}" ]; then
            touch "${cFile}"
        fi
        $EDITOR "${cFile}"
        echo -en "Save ${BLUE}${DEVICE}${NC} changelog? [y]/n > "
        read -r ans
        if [[ $ans != 'n' ]]; then
            clData=$(cat "${cFile}")
            haveData=1
        fi
    done 9< $DEVICE_FILE
fi

if [ ! -f $STATUS_FILE ]; then
    touch $STATUS_FILE
else
    if [[ $(cat $STATUS_FILE | grep -q "all done") ]] || [[ $isResume != 1 ]]; then
        rm $STATUS_FILE
        touch $STATUS_FILE
        isResume=0
    fi
fi

# init for main loop
didError=0
isTempUpload=0
isTempOTA=0
flashArg=""
i=0
n=0
targets=()
times=()
. build/envsetup.sh
if [[ $isDirty != 1 ]] && [[ $isUploadOnly != 1 ]] && [[ $isOTAOnly != 1 ]]; then
    if [[ $isClean != 1 ]]; then
        echo -e "Press enter to ${RED}clean build${NC} and start. Ctrl+C to cancel"
        echo -en "If you don't want to clean pass the -d flag"
        read -r ans
    fi
    lunch yaap_guacamole-user
    make clobber
fi

# for each line of $DEVICE_FILE
while read -r -u9 DEVICE; do
    # ignore comments
    [[ ${DEVICE:0:1} == '#' ]] && continue
    ((n++))
    targets+=("$DEVICE")
done 9< $DEVICE_FILE

./telegramSend.sh --config $TG_STATUS_CONF "Batch build started for ${n} targets"
tgTmp="$(mktemp -d)/"
firstStatus=1
startMs=$(date +"%s")

# Main loop!!!!!!!!!
for DEVICE in "${targets[@]}"; do

    # set isUploadOnly for devices with the -u flags in $DEVICE_FILES
    [[ $isTempUpload == 1 ]] && isUploadOnly=0
    isTempUpload=0
    if echo "$DEVICE" | grep -q "\-u"; then
        [[ $isUploadOnly == 0 ]] && isTempUpload=1
        isUploadOnly=1
        DEVICE=$(echo "$DEVICE" | sed 's/ //g' | sed 's/-u//g')
    fi

    # set isTempOTA for devices with the -o flags in $DEVICE_FILES
    [[ $isTempOTA == 1 ]] && isOTAOnly=0
    isTempOTA=0
    if [[ -n $(echo "$DEVICE" | grep "\-o") ]]; then
        [[ $isOTAOnly == 0 ]] && isTempUpload=1
        isOTAOnly=1
        DEVICE=$(echo "$DEVICE" | sed 's/ //g' | sed 's/-o//g')
    fi

    flashArg=""
    if [[ -n $(echo "$DEVICE" | grep "\-f") ]]; then
        flashArg=" -f"
        DEVICE=$(echo "$DEVICE" | sed 's/ //g' | sed 's/-f//g')
    fi

    # print status
    j=0
    statStr=""
    for tmp in "${targets[@]}"; do
        [[ $statStr != "" ]] && statStr="${statStr}\n"
        endE=""
        if [[ $j -eq $i ]]; then
            echo -en "${BLUE}"
            endE="🏭"
        elif [[ $j -lt $i ]]; then
            if [[ ${exitCodes[$j]} == 0 ]]; then
                echo -en "${GREEN}"
                endE="✅ [<code>${times[$j]}</code>]"
            else
                echo -en "${RED}"
                endE="❌"
            fi
        fi
        ((j++))
        echo -e "${j}. ${tmp}${NC}"
        statStr="${statStr}${j}. <code>${tmp}</code> ${endE}"
    done

    if [[ $isResume == 1 ]]; then
        if cat $STATUS_FILE | grep -q "${DEVICE} -> done"; then
            echo "Skipping built ${DEVICE}"
            exitCodes+=(0)
            continue;
        fi
    fi

    if [[ $firstStatus == 1 ]]; then
        firstStatus=0
        trap tg_clean SIGINT
        ./telegramSend.sh --pin --tmp $tgTmp --config $TG_STATUS_CONF "Current status:\n${statStr}"
    else
        ./telegramSend.sh --edit --tmp $tgTmp --config $TG_STATUS_CONF "Current status:\n${statStr}"
    fi

    # building
    start_time=$(date +"%s")
    if [[ $isOTAOnly != 1 ]]; then
        retry_count=0
        iO=$(( i + 1 ))
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            if [[ $retry_count -gt 0 ]]; then
                echo -ne "${RED}Build failed.${NC} Retrying device. "
                echo -e "[${BLUE}${retry_count}${NC}/${BLUE}${MAX_RETRIES}${NC}]"
                ./telegramSend.sh --config $TG_STATUS_CONF "Building target ${iO}/${n} (<code>${DEVICE}</code>) failed. Retrying (${retry_count}/${MAX_RETRIES} times)"
            else
                ./telegramSend.sh --config $TG_STATUS_CONF "Building target ${iO}/${n} (<code>${DEVICE}</code>)"
            fi
            echo -e "$(date)\n${DEVICE} -> started\n" >> $STATUS_FILE
            if [[ $isUploadOnly != 1 ]]; then
                ./$BUILD_SCRIPT --i-c -u -k --config "${DEVICE}.conf"$flashArg
            else
                ./$BUILD_SCRIPT -u -k -d --config "${DEVICE}.conf"$flashArg
            fi
            # !! NO COMMANDS ALLOWED HERE !!
            # shellcheck disable=SC2181
            if [[ $? != 0 ]]; then
                ((retry_count++))
                echo -e "$(date)\n${DEVICE} -> failed\n" >> $STATUS_FILE
                echo "fail count: ${retry_count}" >> $STATUS_FILE
                continue
            fi
            exitCodes+=(0)
            retry_count=0
            fileName=$(basename -- out/target/product/$DEVICE/$BUILD_MATCHING)
            ANDROID_VERSION=$(echo "$fileName" | cut -d "-" -f 2)
            ANDROID_VERSION_MINOR=$(echo $ANDROID_VERSION | cut -d "." -f 2)
            if [[ $ANDROID_VERSION_MINOR == "" ]] || [[ $ANDROID_VERSION_MINOR == "$ANDROID_VERSION" ]]; then
                ANDROID_VERSION_MINOR="0"
            fi
            BUILD_CODENAME=$(echo "$fileName" | cut -d "-" -f 3)
            if [[ $BACKUP_DIR != "" ]]; then
                echo -e "Backing up to ${BLUE}${BACKUP_DIR}${NC} in background!"
                cp out/target/product/$DEVICE/$BUILD_MATCHING $BACKUP_DIR/$DEVICE/ &
            fi

            break
        done
        if [ $retry_count == $MAX_RETRIES ]; then
            didError=1
            exitCodes+=(1)
            echo -e "${RED}Build failed ${BLUE}${MAX_RETRIES}${RED} times. Skipping device${NC}"
            echo -e "$(date)\n${DEVICE} -> skipped\n" >> $STATUS_FILE
            continue
        fi
        echo -e "$(date)\n${DEVICE} -> done" >> $STATUS_FILE
        echo >> $STATUS_FILE
    fi
    get_time
    times+=("$buildTime")

    # getting time from the built file
    if [[ $isOTAOnly != 1 ]]; then
        dateNow=$(basename -- out/target/product/$DEVICE/$BUILD_MATCHING | cut -d "-" -f 5 | sed "s/.zip//")
    else
        dateNow=$(date +%Y%m%d)
        echo -n "Enter a date in (YYYYMMDD) format (empty to use today's): "
        read -r userDate
        if [[ -n $userDate ]]; then
            dateNow=$userDate
        fi
    fi
    dateDashed="${dateNow:0:4}-${dateNow:4:2}-${dateNow:6:2}"
    # making sure ota-info is up to date
    if [ ! -d "ota-info" ]; then
        git clone $OTA_REPO
        cd ota-info || exit 1
    else
        cd ota-info || exit 1
        git remote update
        git reset --hard origin/$OTA_BRANCH
    fi # now inside ota-info
    # updating OTA json
    if [ ! -d "${DEVICE}" ]; then
        mkdir "${DEVICE}"
    fi
    cd "${DEVICE}" || exit 1 # into the device folder
    rm -f "${DEVICE}.json"
    # copying the new json
    cp "../../out/target/product/${DEVICE}/${DEVICE}.json" "./${DEVICE}.json"
    # generating a new changelog
    rm ./Changelog.txt
    {
        echo "ROM:"
        cat "../../changelogs/ROM.txt"
        echo
        echo "Device:"
        cat "../../changelogs/${DEVICE}.txt"
    } > Changelog.txt
    fullChangelog="$(cat Changelog.txt)"
    cd .. # back to main ota repo
    # git push
    git add .
    git -c commit.gpgsign=false commit -m "${DEVICE}: ${dateDashed} update"
    git push origin HEAD:$OTA_BRANCH
    cd .. # back to original dir
    # forcing github to generate raws
    wget --delete-after "https://raw.githubusercontent.com/yaap/ota-info/${OTA_BRANCH}/${DEVICE}/${DEVICE}.json"
    # channel post
    realName=$(sed '1q;d' ./changelogs/$DEVICE.info)
    deviceGroup=$(sed '2q;d' ./changelogs/$DEVICE.info)
    ./telegramSend.sh --config $TG_UPDATE_CONF \
"<a href=\"${BANNER_REPO}/raw/${BANNER_BRANCH}/${DEVICE}.jpg\">&#8205;</a>\
New YAAP Build for ${realName} (${DEVICE})

<b>Details:</b>

• Version: ${ANDROID_VERSION}.${ANDROID_VERSION_MINOR} ${dateNow}
• Type: Stable

<b>Changelog:</b>

${fullChangelog}

<b>Links:</b>

• ROM: <a href=\"${FILE_SERVER}/${DEVICE}/YAAP-${ANDROID_VERSION}-${BUILD_CODENAME}-${DEVICE}-${dateNow}.zip\">${DEVICE}</a>
• Support: <a href=\"${deviceGroup}\">Group</a>"
    echo -e "$(date)\n${DEVICE} -> posted\n" >> $STATUS_FILE
    # fastboot pkg
    if [[ -f "${DEVICE}-fb.conf" ]]; then
        if [[ $isUploadOnly != 1 ]]; then
            echo "Installclean before fastboot pkg"
            lunch "yaap_${DEVICE}-user"
            make installclean
            ./$BUILD_SCRIPT -u --config "${DEVICE}-fb.conf"$flashArg
        else
            ./$BUILD_SCRIPT -u -d --config "${DEVICE}-fb.conf"$flashArg
        fi
    fi
    ((i++))
done

# Ending Theme

# print closing status
start_time="${startMs}"
get_time
echo "!!!! Batch build done !!!!!"
echo "Results:"

j=0
ec=0
statStr=""
for tmp in "${targets[@]}"; do
    [[ $statStr != "" ]] && statStr="${statStr}\n"
    endE=""
    if [[ ${exitCodes[$j]} == 0 ]]; then
        echo -en "${GREEN}"
        endE="✅ [<code>${times[$j]}</code>]"
    else
        echo -en "${RED}"
        endE="❌"
        ((ec++))
    fi
    ((j++))
    echo -e "${j}. ${tmp}${NC}"
    statStr="${statStr}${j}. <code>${tmp}</code> ${endE}"
done
ec=$(( n - ec ))
./telegramSend.sh --edit --tmp $tgTmp --config $TG_STATUS_CONF "Current status:\n${statStr}"

echo
echo -e "Built ${BLUE}${ec}${NC} out of ${BLUE}${n}${NC} targets in ${buildTime}"
./telegramSend.sh --config $TG_STATUS_CONF "Batch build done. Built ${ec}/${n} targets in <code>${buildTime}</code>"
./telegramSend.sh --unpin --tmp $tgTmp --config $TG_STATUS_CONF " "
trap - SIGINT

if [[ $didError == 0 ]]; then
    echo -e "$(date)\nall done\n" >> $STATUS_FILE
    ./telegramSend.sh --config $TG_STATUS_CONF "Spoonfeeding..."
    ./spoonfeed.sh
fi
./telegramSend.sh --config $TG_STATUS_CONF "$ENDING_TAG"

exit $didError
