#!/bin/bash

####################################
# Copyright (c) [2025] [@ravindu644]
####################################

set -e

export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export WDIR="${SCRIPT_DIR}"
export RECOVERY_LINK="$1"
export MODEL="$2"
export DOWNLOADED_FILE=""
mkdir -p "recovery" "unpacked" "output"
source "${WDIR}/binaries/colors"
source "${WDIR}/binaries/gofile.sh"

# Clean-up is required
rm -rf "${WDIR}/recovery/"*
rm -rf "${WDIR}/unpacked/"*

# Define magiskboot,avbtool and signing key paths
AVB_KEY="${WDIR}/signing-keys/testkey_rsa2048.pem"
AVBTOOL="${WDIR}/binaries/avbtool"
MAGISKBOOT="${WDIR}/binaries/magiskboot"

# Define the usage
usage() {
  echo -e "${BOLD}${RED}Usage:${RESET} ${BOLD}./patch-recovery.sh <URL/Path> <Model Number>${RESET}"
  exit 1
}

[[ -z "$RECOVERY_LINK" || -z "$MODEL" ]] && usage

# Welcome banner, Install requirements if not installed
init_patch_recovery(){
    echo -e "\n${BLUE}patch-recovery-revived - By @ravindu644${RESET}\n"

    # Install the requirements for building the kernel when running the script for the first time
    if [ ! -f ".requirements" ]; then
        echo -e "\n\t${UNBOLD_GREEN}Installing requirements...${RESET}\n"
        {
            sudo apt update
            sudo apt install -y lz4
        } && touch .requirements
    fi
}

# Downloading/copying the recovery
download_recovery(){
    local DOWNLOAD_NAME

    if [[ "${RECOVERY_LINK}" =~ ^https?:// ]]; then
        if [[ "${RECOVERY_LINK}" =~ ^https?://filebin\.net/([^/?#]+)/?$ ]]; then
            local FILEBIN_PAGE
            local FILEBIN_LINK
            local FILEBIN_BIN="${BASH_REMATCH[1]}"

            if ! FILEBIN_PAGE="$(curl -fsSL "${RECOVERY_LINK}")"; then
                echo -e "${BOLD}${RED}Unable to fetch the Filebin page:${RESET} ${BOLD}${RECOVERY_LINK}${RESET}\n"
                exit 1
            fi
            FILEBIN_LINK="$(printf '%s' "${FILEBIN_PAGE}" | grep -oE 'https?://filebin\.net/[^"'\''<> ]+' | grep -m1 -F "/${FILEBIN_BIN}/" || true)"

            if [ -z "${FILEBIN_LINK}" ]; then
                FILEBIN_LINK="$(printf '%s' "${FILEBIN_PAGE}" | grep -oE '/[^"'\''<> ]+' | grep -m1 -F "/${FILEBIN_BIN}/" || true)"
                [ -n "${FILEBIN_LINK}" ] && FILEBIN_LINK="https://filebin.net${FILEBIN_LINK}"
            fi

            case "${FILEBIN_LINK}" in
                https://filebin.net/"${FILEBIN_BIN}"/*|http://filebin.net/"${FILEBIN_BIN}"/*)
                echo -e "${LIGHT_YELLOW}[INFO] Resolved Filebin page to:${RESET} ${BOLD}${FILEBIN_LINK}${RESET}\n"
                RECOVERY_LINK="${FILEBIN_LINK}"
                ;;
            "")
                ;;
            *)
                echo -e "${BOLD}${RED}Resolved Filebin URL is invalid:${RESET} ${BOLD}${FILEBIN_LINK}${RESET}\n"
                exit 1
                ;;
            esac
        fi

        echo -e "${LIGHT_YELLOW}[INFO] Downloading:${RESET} ${BOLD}${RECOVERY_LINK}${RESET}\n"

        DOWNLOAD_NAME="$(basename "${RECOVERY_LINK%%[\?#]*}")"
        [ -z "${DOWNLOAD_NAME}" ] && DOWNLOAD_NAME="downloaded-recovery"
        DOWNLOADED_FILE="${WDIR}/recovery/${DOWNLOAD_NAME}"

        curl -fL "${RECOVERY_LINK}" -o "${DOWNLOADED_FILE}"
    elif [ -f "${RECOVERY_LINK}" ]; then
        DOWNLOAD_NAME="$(basename "${RECOVERY_LINK}")"
        DOWNLOADED_FILE="${WDIR}/recovery/${DOWNLOAD_NAME}"
        cp "${RECOVERY_LINK}" "${DOWNLOADED_FILE}"
    else
        echo -e "${BOLD}${RED}Invalid input: not a URL or file.${RESET}\n"
        echo -e "${BOLD}${RED}If you entered a URL, make sure it begins with 'http://' or 'https://'${RESET}\n"
        exit 1
    fi
}

# Check if the downloaded/copied file an archive
unarchive_recovery(){

    set -x 
    cd "${WDIR}/recovery/"
    local FILE
    FILE="$(basename "${DOWNLOADED_FILE}")"

    if [ -z "${FILE}" ] || [ ! -f "${FILE}" ]; then
        echo -e "${BOLD}${RED}Unable to find a downloaded recovery file.${RESET}\n"
        exit 1
    fi

    local FILE_INFO
    FILE_INFO="$(file -b "${FILE}")"
    local FILE_MIME
    FILE_MIME="$(file -b --mime-type "${FILE}")"
    local SEARCH_DIR="."

    if [[ "${FILE_INFO}" == HTML\ document* ]] || [[ "${FILE_INFO}" == XML\ 1.0\ document* ]] || [[ "${FILE_MIME}" == "text/html" ]] || [[ "${FILE_MIME}" == "application/xhtml+xml" ]] || [[ "${FILE_MIME}" == "text/xml" ]] || [[ "${FILE_MIME}" == "application/xml" ]]; then
        echo -e "${BOLD}${RED}Downloaded file is not a direct recovery image or archive.${RESET}\n"
        echo -e "${BOLD}${RED}Please provide a direct .img, .lz4, or .zip download URL instead of a webpage link.${RESET}\n"
        exit 1
    elif [[ "${FILE_MIME}" == "application/zip" ]] || [[ "${FILE_INFO}" == Zip\ archive\ data* ]] || { command -v unzip >/dev/null 2>&1 && unzip -tqq "${FILE}" >/dev/null 2>&1; }; then
        if ! command -v unzip >/dev/null 2>&1; then
            echo -e "${BOLD}${RED}Missing required tool:${RESET} ${BOLD}unzip${RESET}\n"
            exit 1
        fi
        if ! python3 - "${FILE}" <<'PY'
import pathlib
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    seen = set()
    root_dir = None
    saw_flat_file = False
    saw_rooted_file = False
    for info in archive.infolist():
        name = info.filename
        path = pathlib.PurePosixPath(name)
        parts = tuple(part for part in path.parts if part not in ("", "."))
        is_dir = info.is_dir() or name.endswith("/")

        if name.startswith("/") or any(part == ".." for part in parts):
            sys.exit(1)
        if stat.S_ISLNK(info.external_attr >> 16):
            sys.exit(1)
        if not parts:
            continue

        if is_dir:
            if len(parts) == 1:
                if root_dir is None:
                    root_dir = parts[0]
                elif root_dir != parts[0]:
                    sys.exit(1)
                continue
            sys.exit(1)

        if len(parts) == 1:
            normalized = parts[0]
            saw_flat_file = True
            if root_dir is not None or saw_rooted_file:
                sys.exit(1)
        elif len(parts) == 2:
            if saw_flat_file:
                sys.exit(1)
            saw_rooted_file = True
            if root_dir is None:
                root_dir = parts[0]
            elif root_dir != parts[0]:
                sys.exit(1)
            normalized = parts[1]
        else:
            sys.exit(1)

        if normalized.startswith("-"):
            sys.exit(1)
        if normalized in seen:
            sys.exit(1)
        seen.add(normalized)
PY
        then
            echo -e "${BOLD}${RED}ZIP archive contains unsupported paths or symlink entries:${RESET} ${BOLD}${FILE}${RESET}\n"
            exit 1
        fi
        if ! unzip -o "${FILE}"; then
            echo -e "${BOLD}${RED}Failed to extract ZIP archive:${RESET} ${BOLD}${FILE}${RESET}\n"
            exit 1
        fi
        rm -- "${FILE}"

        local EXTRACTED_DIRS=()
        local EXTRACTED_FILES=()
        mapfile -t EXTRACTED_DIRS < <(find . -mindepth 1 -maxdepth 1 -type d -print)
        mapfile -t EXTRACTED_FILES < <(find . -mindepth 1 -maxdepth 1 -type f -print)

        if [ "${#EXTRACTED_DIRS[@]}" -eq 1 ] && [ "${#EXTRACTED_FILES[@]}" -eq 0 ]; then
            SEARCH_DIR="${EXTRACTED_DIRS[0]}"
        fi
    elif [[ "${FILE_MIME}" == "application/x-lz4" ]] || [[ "${FILE_INFO}" == LZ4\ compressed\ data* ]]; then
        if ! command -v lz4 >/dev/null 2>&1; then
            echo -e "${BOLD}${RED}Missing required tool:${RESET} ${BOLD}lz4${RESET}\n"
            exit 1
        fi
        local OUTPUT_FILE="${FILE%.lz4}"
        [[ "${OUTPUT_FILE}" == "${FILE}" ]] && OUTPUT_FILE="recovery.img"
        if ! lz4 -d "${FILE}" "${OUTPUT_FILE}"; then
            echo -e "${BOLD}${RED}Failed to decompress LZ4 recovery image:${RESET} ${BOLD}${FILE}${RESET}\n"
            exit 1
        fi
        rm -- "${FILE}"
    elif [[ "${FILE}" != *.img ]] && [[ "${FILE}" != "recovery.img" ]]; then
        echo -e "${BOLD}${RED}Unsupported recovery file type:${RESET} ${BOLD}${FILE}${RESET}\n"
        echo -e "${BOLD}${RED}Please provide a direct .img, .lz4, or .zip download URL.${RESET}\n"
        exit 1
    fi

    # Only rename if recovery.img doesn't exists
    if [ ! -f recovery.img ]; then
        local IMG_FILE
        local IMG_FILES=()
        mapfile -d '' -t IMG_FILES < <(find "${SEARCH_DIR}" -maxdepth 1 -type f -name '*.img' -print0)

        if [ "${#IMG_FILES[@]}" -eq 1 ]; then
            IMG_FILE="${IMG_FILES[0]}"
            if [ "${IMG_FILE}" != "./recovery.img" ] && [ "${IMG_FILE}" != "recovery.img" ]; then
                mv -- "${IMG_FILE}" "recovery.img"
            fi
        elif [ "${#IMG_FILES[@]}" -gt 1 ]; then
            echo -e "${BOLD}${RED}Found multiple .img files in the downloaded archive.${RESET}\n"
            echo -e "${BOLD}${RED}Please provide an archive that contains only the recovery image or a direct recovery image URL.${RESET}\n"
            exit 1
        else
            echo -e "${BOLD}${RED}Unable to locate a recovery image in the downloaded file.${RESET}\n"
            echo -e "${BOLD}${RED}Please provide a direct .img, .lz4, or .zip download URL.${RESET}\n"
            exit 1
        fi
    fi

    cd "${WDIR}/"

    export RECOVERY_FILE="${WDIR}/recovery/recovery.img"
    export RECOVERY_SIZE=$(stat -c%s "${WDIR}/recovery/recovery.img")
    set +x
}

# Extract recovery.img
extract_recovery_image(){
    cd "${WDIR}/unpacked/"

    echo -e "${LIGHT_YELLOW}[INFO] Extracting:${RESET} ${BOLD}${RECOVERY_FILE}${RESET}\n"

	${MAGISKBOOT} unpack ${RECOVERY_FILE}
	${MAGISKBOOT} cpio ramdisk.cpio extract
    cd "${WDIR}/"
}

# Hex patch the "recovery" binary to get fastbootd mode back
hexpatch_recovery_image(){
    cd "${WDIR}/unpacked/"

    echo -e "${LIGHT_YELLOW}[INFO] Hex-patching:${RESET} ${BOLD}system/bin/recovery${RESET}\n"

    set +e

	${MAGISKBOOT} hexpatch system/bin/recovery e10313aaf40300aa6ecc009420010034 e10313aaf40300aa6ecc0094 # 20 01 00 35
	${MAGISKBOOT} hexpatch system/bin/recovery eec3009420010034 eec3009420010035
	${MAGISKBOOT} hexpatch system/bin/recovery 3ad3009420010034 3ad3009420010035
	${MAGISKBOOT} hexpatch system/bin/recovery 50c0009420010034 50c0009420010035
	${MAGISKBOOT} hexpatch system/bin/recovery 080109aae80000b4 080109aae80000b5
	${MAGISKBOOT} hexpatch system/bin/recovery 20f0a6ef38b1681c 20f0a6ef38b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery 23f03aed38b1681c 23f03aed38b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery 20f09eef38b1681c 20f09eef38b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery 26f0ceec30b1681c 26f0ceec30b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery 24f0fcee30b1681c 24f0fcee30b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery 27f02eeb30b1681c 27f02eeb30b9681c
	${MAGISKBOOT} hexpatch system/bin/recovery b4f082ee28b1701c b4f082ee28b970c1
	${MAGISKBOOT} hexpatch system/bin/recovery 9ef0f4ec28b1701c 9ef0f4ec28b9701c

	${MAGISKBOOT} hexpatch system/bin/recovery 9ef00ced28b1701c 9ef00ced28b9701c
	${MAGISKBOOT} hexpatch system/bin/recovery 2001597ae0000054 2001597ae1000054

    ${MAGISKBOOT} hexpatch system/bin/recovery 50860494f3031f2a 5086049433008052

    set -e

    cd "${WDIR}/"
}

# Repack the fastbootd patched recovery image
repack_recovery_image(){
    cd "${WDIR}/unpacked/"

    ${MAGISKBOOT}  cpio ramdisk.cpio 'add 0755 system/bin/recovery system/bin/recovery'

    echo -e "${LIGHT_YELLOW}[INFO] Repacking to:${RESET} ${BOLD}${WDIR}/output/patched-recovery.img${RESET}\n"

	${MAGISKBOOT}  repack ${RECOVERY_FILE} "${WDIR}/output/patched-recovery.img"

    cd "${WDIR}/"
}

# Sign the patched-recovery.img with Google's RSA private test key
sign_recovery_image(){

    echo -e "${LIGHT_YELLOW}[INFO] Signing with Google's RSA private test key:${RESET} ${BOLD}${WDIR}/output/patched-recovery.img${RESET}\n"

    ${AVBTOOL} \
        add_hash_footer \
        --partition_name recovery \
        --partition_size ${RECOVERY_SIZE} \
        --image "${WDIR}/output/patched-recovery.img" \
        --key ${AVB_KEY} \
        --algorithm SHA256_RSA2048
}

# Create an ODIN-flashable tar
create_tar(){
    cd "${WDIR}/output/"

    mv patched-recovery.img recovery.img && \
        lz4 -B6 --content-size recovery.img recovery.img.lz4 && \
        rm recovery.img

    tar -cvf "${MODEL}-Fastbootd-patched-recovery.tar" recovery.img.lz4 && \
        rm recovery.img.lz4

    echo -e "\n${LIGHT_YELLOW}[INFO] Created ODIN-flashable tar:${RESET} ${BOLD}${PWD}/${MODEL}-Fastbootd-patched-recovery.tar${RESET}\n"

    # Optional GoFile upload
    if [[ "$GOFILE" == "1" ]]; then
        upload_to_gofile "${MODEL}-Fastbootd-patched-recovery.tar"
    fi
    
    cd "${WDIR}/"
}

cleanup_source(){
    rm -rf "${WDIR}/recovery/"*
    rm -rf "${WDIR}/unpacked/"*    
}

init_patch_recovery
download_recovery
unarchive_recovery
extract_recovery_image
hexpatch_recovery_image
repack_recovery_image
sign_recovery_image
create_tar
cleanup_source
