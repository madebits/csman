#!/bin/bash -

# cskey.sh

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
\export PATH
\unalias -a
hash -r
ulimit -H -c 0 --
IFS=$' \t\n'

set -eu -o pipefail

if [ $(id -u) != "0" ]; then
    case "${1:-}" in
        rnd)
        ;;
        *)
            (>&2 echo "! using sudo recommended")
        ;;
    esac

fi

# none of values in this file is secret
# change default argon2 params in cskHashToolOptions as it fits you here
# https://crypto.stackexchange.com/questions/37137/what-is-the-recommended-number-of-iterations-for-argon2

#state
cskFile=""
cskDebug="0"
cskInputMode="0"
cskBackup="0"
cskBackupNewSecret="0"
cskHashToolOptions=( "-p" "8" "-m" "14" "-t" "1000" )
cskPassFile=""
cskKeyFiles=()
cskNoKeyFiles="0"
cskSecret=""
cskSessionKey=""
cskSessionAutoKey="0"
cskSessionAutoKeyFile=""
cskSessionSaltFile=""

cskSessionPassFile=""
cskSessionSecretFile=""
cskSessionSaveDecodePassFile=""
cskRndLen=""
cskRndBatch="0"
cskUseURandom="0"
cskDecodeOffset=""
cskTruncate="0"

user="${SUDO_USER:-$(whoami)}"
userHome="$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f6)"
currentScriptPid=$$
toolsDir="$(dirname $0)"
useAes="1"
cskSessionLocation="${userHome}/mnt/tmpcsm"

export HOME="${userHome}"

#if [ -f "${toolsDir}/aes" ]; then
#    useAes="1"
#fi

########################################################################

function logError()
{
    (>&2 echo "$@")
}

function debugData()
{
    if [ "$cskDebug" = "1" ]; then
        logError
        while [ -n "${1:-}" ]; do
            logError "DEBUG [${1}]"
            shift
        done
    fi
}

function onFailed()
{
    logError "!" "$@"
    kill -9 "${currentScriptPid}"
}

function checkNumber()
{
    local re='^[0-9]+$'
    if ! [[ "$1" =~ $re ]] ; then
        logError "$1 not a number"
        exit 1
    fi
}

# file
function createDir()
{
    local file="$1"
    if [ -S "${file}" ]; then
        return
    fi
    if [ -f "$file" ]; then
        local dir
        dir=$(dirname -- "${file}")
        if [ dir != "." ]; then
            mkdir -p -- "${dir}"
        fi
    fi
}

# file
function touchFile()
{
    local file="$1"
    if [ -f "$file" ]; then
        local md
        md=$(stat -c %z -- "$file")
        set +e
        touch -d "$md" -- "$file" 2> /dev/null
        set -e
    fi
}

# file
function ownFile()
{
    if [ -f "$1" ]; then
        chown $(id -un "$user"):$(id -gn "$user") -- "$1"
    fi
}

# file
function restrictFile()
{
    # umask
    touch "$1"
    chmod o-r "$1"
}

########################################################################

function encryptedSecretLength()
{
    if [ "$useAes" = "1" ]; then
        echo 624
    elif [ "$useAes" = "2" ]; then
        echo 544
    elif [ "$useAes" = "3" ]; then
        echo 587
    #elif [ "$useAes" = "4" ]; then
    #    echo 560
    else
        onFailed "invalid -c $useAes"
    fi
}

function encryptAes()
{
    local pass="$1"
    if [ "$useAes" = "1" ]; then
        "${toolsDir}/aes" -c 1000000 -r /dev/urandom -e -f <(echo -n "$pass")
    elif [ "$useAes" = "2" ]; then
        ccrypt -e -f -k <(echo -n "$pass")
    elif [ "$useAes" = "3" ]; then
        gpg -o - --batch --quiet --yes --passphrase-file <(echo -n "$pass") --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 --s2k-cipher-algo AES256 --symmetric -
    #elif [ "$useAes" = "4" ]; then
    #    "${toolsDir}/aes" -a -m -c 5000000 -r /dev/urandom -e -f <(echo -n "$pass")
    else
        onFailed "invalid -c $useAes"
    fi
}

function decryptAes()
{
    local pass="$1"
    if [ "$useAes" = "1" ]; then
        "${toolsDir}/aes" -c 1000000 -d -f <(echo -n "$pass")
    elif [ "$useAes" = "2" ]; then
        ccrypt -d -k <(echo -n "$pass")
    elif [ "$useAes" = "3" ]; then
        gpg -o - --batch --quiet --yes --passphrase-file <(echo -n "$pass") -d -
    #elif [ "$useAes" = "4" ]; then
    #    "${toolsDir}/aes" -a -m -c 5000000 -d -f <(echo -n "$pass")
    else
        onFailed "invalid -c $useAes"
    fi
}

function encryptAesSession()
{
    local pass="$1"
    "${toolsDir}/aes" -c 1000000 -r /dev/urandom -e -f <(echo -n "$pass")
}

function decryptAesSession()
{
    local pass="$1"
    "${toolsDir}/aes" -c 1000000 -d -f <(echo -n "$pass")
}

########################################################################

# pass salt
function pass2hash()
{
    local pass="$1"
    local salt="$2"
    local acmd="argon2"
    if [ -f "${toolsDir}/${acmd}" ]; then
        acmd="${toolsDir}/${acmd}"
    fi

    # argon2 tool has a build-in limit of 126 chars on pass length
    #local state=$(set +o)
    #set +x
    pass=$(echo -n "$pass" | sha512sum | cut -d ' ' -f 1 | tr -d '\n' | while read -n 2 code; do printf "\x$code"; done | base64 -w 0)
    #eval "$state"
    echo -n "$pass" | "$acmd" "$salt" -id "${cskHashToolOptions[@]}" -l 128 -r | tr -d '\n'
}

# file pass secret
function encodeSecret()
{
    local file="$1"
    local pass="$2"
    local secret="$3"

    if [ -z "${secret}" ]; then
        onFailed "no secret"
    fi

    debugData "Pass:" "$pass" "Secret:" "$secret"
    local secretLength=$(encryptedSecretLength)
    # random file size
    local maxRndLength=$((1024 - $secretLength - 32))
    local r=$((RANDOM % $maxRndLength))

    local salt
    salt=$(head -c 32 /dev/urandom | base64 -w 0)
    hash=$(pass2hash "$pass" "$salt")

    if [ "$file" = "-" ]; then
        file="/dev/stdout"
        echo -n "$salt" | base64 -d >> "$file"
        echo -n "$secret" | base64 -d | encryptAes "$hash" >> "$file"
        head -c "$r" /dev/urandom >> "$file"
        return
    fi

    if [ -f "$file" ]; then
        createDir "$file"
    fi
    if [ -z "$cskDecodeOffset" ] && [ "$cskTruncate" = "1" ] && [ -f "$file"] ; then
        debugData "truncating $file if exists"
        > "$file"
    fi

    #echo -n "$salt" | base64 -d >> "$file"
    local seek="${cskDecodeOffset:-0}"
    debugData "seek at byte ${seek}"
    echo -n "$salt" | base64 -d | dd status=none conv=notrunc bs=1 count=32 seek="$seek" of="$file"

    #echo -n "$secret" | base64 -d | encryptAes "$hash" >> "$file"
    local length="$secretLength"
    seek=$(($seek + 32))
    echo -n "$secret" | base64 -d | encryptAes "$hash" | dd status=none conv=notrunc bs=1 count="$length" seek="$seek" of="$file"
    seek=$(($seek + $length))

    #head -c "$r" /dev/urandom >> "$file"
    if [ -n "$cskDecodeOffset" ]; then
        r="$maxRndLength"
    fi
    debugData "random suffix length ${r} of max ${maxRndLength} ($(($secretLength + 32)))"
    dd status=none conv=notrunc bs=1 count="$r" seek="$seek" if=/dev/urandom of="$file"

    if [ -f "$file" ]; then
        ownFile "$file"
        touchFile "$file"
    fi
}

# file pass
function decodeSecret()
{
    local file="$1"
    local pass="$2"
    local secretLength=$(encryptedSecretLength)
    local length=$(("$secretLength" + 32))

    # weak shortcut, ok to use for something quick, once a while
    if [ "$1" = "--" ]; then
        # we put only part of pass hash in command line here!
        local sps
        sps="$(echo -n "$pass" | sha256sum | cut -d ' ' -f 1 | tr -d '\n' | head -c 32)"
        pass2hash "$pass" "$sps"
        return
    fi

    if [ -e "$file" ] || [ "$file" = "-" ]; then
        debugData "Read at offset ${cskDecodeOffset:-0}"
        local offset=$((${cskDecodeOffset:-0} + 1))
        local fileData=$(tail -c +${offset} -- "$file" | head -c "$length" | base64 -w 0)
        if [ "$file" != "-" ]; then
            touchFile "$file"
        fi
        if [ -z "$fileData" ]; then
            onFailed "cannot read: $file"
        fi
        local salt
        salt=$(echo -n "$fileData" | base64 -d | head -c 32 | base64 -w 0)
        local data
        data=$(echo -n "$fileData" | base64 -d | tail -c +33 | head -c "${secretLength}" | base64 -w 0)
        #debugData "data $data"
        local hash
        hash=$(pass2hash "$pass" "$salt")
        touchFile "$file"

        if [ -n "${cskSessionSecretFile}" ]; then
            readSessionPass
            restrictFile "${cskSessionSecretFile}"
            echo -n "$data" | base64 -d | decryptAes "$hash" | encryptAes "$cskSessionKey" > "${cskSessionSecretFile}"
            debugData "Secret:" "$(echo -n "$data" | base64 -d | decryptAes "$hash" | base64 -w 0)"
            logError "# session: stored secret in: ${cskSessionSecretFile}"
            debugData "SessionSecret:" "$(cat -- ${cskSessionSecretFile} | base64 -w 0)"
            logError
        fi
        echo -n "$data" | base64 -d | decryptAes "$hash"
    else
        onFailed "no such file: $file"
    fi
}

########################################################################

function keyFileHash()
{
    local keyFile="$1"
    head -c 1024 -- "$keyFile" | sha512sum | cut -d ' ' -f 1
    if [ "$?" != "0" ]; then
        onFailed "cannot read keyFile: ${keyFile}"
    fi
    touchFile "$keyFile"
}

function readKeyFiles()
{
    local count=0
    local keyFile=""

    if [ "$cskNoKeyFiles" = "1" ]; then
        return
    fi

    local lastDir=""
    if [ -f "$1" ]; then
        lastDir="$(dirname -- "$1")/"
        lastDir="${lastDir/#${userHome}/\~}"
    fi

    while :
    do
        count=$((count+1))

        read -i "$lastDir" -e -p "Key file $count (Ctrl+U clear, Enter if none) [ $(dirs +0) ]: " keyFile
        #logError

        if [ -z "$keyFile" ] || [ -d "$keyFile" ]; then
            break
        fi

        keyFile="${keyFile/#\~/${userHome}}"
        keyFile="$(realpath -- "$keyFile")"

        if [ -z "$keyFile" ] || [ -d "$keyFile" ]; then
            break
        fi

        if [ ! -f "$keyFile" ]; then
            logError "# no such file: ${keyFile}"
            count=$((count-1))
        else
            cskKeyFiles+=( "$(keyFileHash "$keyFile")" )
        fi
        lastDir="$(dirname -- "$keyFile")/"
        lastDir="${lastDir/#${userHome}/\~}"
    done
    logError
}

function computeKeyFilesHash()
{
    local hash=""
    if (( ${#cskKeyFiles[@]} )); then
        # read order does not matter
        hash=$(printf '%s\n' "${cskKeyFiles[@]}" | sort | sha512sum | cut -d ' ' -f 1)
    fi
    echo "$hash"
}

########################################################################

# file
function readPassFromFile()
{
    if [ -e "$1" ] || [ "$1" = "-" ]; then
        logError "# reading: $1"
        head -n 1 -- "$1" | tr -d '\n'
        if [ "$?" != "0" ]; then
            onFailed "cannot read file: ${1}"
        fi
    else
        onFailed "cannot read file: ${1}"
    fi
}

function readPassword()
{
    if [ -n "$cskSessionPassFile" ]; then
        echo "$cskSessionPassFile"
        return
    fi

    if [ -n "$cskPassFile" ]; then
        pass="$cskPassFile"
    elif [ "$cskInputMode" = "1" ] || [ "$cskInputMode" = "e" ] || [ "$cskInputMode" = "echo" ]; then
        read -p "Password: " pass
        reset
        logError "..."
    elif [ "$cskInputMode" = "2" ] || [ "$cskInputMode" = "c" ] || [ "$cskInputMode" = "copy" ]; then
        pass=$(xclip -o -selection clipboard)
    else
        read -p "Password: " -s pass
        logError
        if [ "${1:-}" = "1" ]; then
            # new password from console, ask to re-enter
            if [ -t 0 ] ; then
                read -p "Renter password: " -s pass2
                logError
                if [ "$pass" != "$pass2" ]; then
                    onFailed "passwords do not match"
                fi
            fi
        fi
    fi
    if [ -z "$pass" ]; then
        onFailed "no password"
    fi
    echo "$pass"
}

function readPass()
{
    local hash=$(computeKeyFilesHash)
    local pass=$(readPassword "${1:-}")
    pass="${pass}${hash}"
    echo "$pass"
}

function readNewPass()
{
    readPass "1"
}

function getSecret()
{
    local secret=""
    if [ -n "${cskSecret}" ]; then
        logError "# secret: user specified (-s or -as)"
        secret="${cskSecret}"
        local secretLength=$(echo -n $secret | base64 -d | wc -c)
        if [ $secretLength -lt 512 ]; then
            local pad=$((512 - $secretLength))
            secret=$(cat <(echo -n $secret | base64 -d) <(head -c $pad /dev/urandom) | base64 -w 0 )
        fi
    else
        # skip some bytes
        head -c $RANDOM /dev/urandom > /dev/null
        if [ "${cskUseURandom}" = "1" ]; then
            logError "# secret: generating new (-su)"
            # https://security.stackexchange.com/questions/3936/is-a-rand-from-dev-urandom-secure-for-a-login-key
            # https://www.2uo.de/myths-about-urandom/
            # dmesg | grep random:
            secret=$(head -c 512 /dev/urandom | base64 -w 0)
        else
            logError "# secret: generating new, move mouse around if stuck (or use -su)"
            # 32 bytes from /dev/random are enough
            # but length matters, so we use 512 byte passwords
            secret=$(cat <(head -c 16 /dev/random) <(head -c 480 /dev/urandom) <(head -c 16 /dev/random) | base64 -w 0)
        fi
    fi
    echo "${secret}"
}

# file pass secret
function encodeMany()
{
    local f="$1"
    logError "# hashtool:" "${cskHashToolOptions[@]}"
    local secret="$3"

    logError "${f}"

    encodeSecret "${f}" "$2" "${secret}"

    local count=$(($cskBackup + 0))
    if [ "$count" -gt "64" ]; then
        count=64
    fi
    for ((i=1 ; i <= $count; i++))
    {
        local pad
        pad=$(printf "%02d" ${i}) # printf -v padd "..."
        local file="${f}.${pad}"
        logError "$file"
        if [ "$cskBackupNewSecret" = "1" ]; then
            secret=$(getSecret)
        fi
        encodeSecret "$file" "$2" "${secret}"
    }
}

# file
function encryptFile()
{
    if [ "$1" = "--" ]; then
        return
    fi

    local file="$1"
    if [ "${file}" = "?" ]; then
        read -e -p "Secret file (or Enter if none): " file
        file="${file/#\~/${userHome}}"
        logError
    #elif [ "${file}" = "!" ]; then
    #    file="$(zenity --file-selection --title='Select Secret File' 2> /dev/null)"
    fi

    logError "# Encoding secret in: $file (at byte offset ${cskDecodeOffset:-0}, slot=$((${cskDecodeOffset:-0} / 1024 + 1))) (-c $useAes)"
    readKeyFiles "$file"
    local pass
    pass=$(readNewPass)
    local secret
    secret=$(getSecret)
    encodeMany "$file" "$pass" "$secret"
    logError "# Done"
}

# file
function decryptFile()
{
    local file="$1"
    if [ "$file" = "?" ]; then
        read -e -p "Secret file (or Enter if none): " file
        file="${file/#\~/${userHome}}"
        logError
    #elif [ "$file" = "!" ]; then
    #    file="$(zenity --file-selection --title='Select Secret File' 2> /dev/null)"
    fi
    if [ -e "$file" ] || [ "$file" = "-" ]; then
        :
    else
        onFailed "no such file: $file"
    fi

    readKeyFiles "$file"
    local pass
    pass=$(readPass)
    debugData "PASS" "$pass"
    if [ -n "${cskSessionSaveDecodePassFile}" ]; then
        createSessionPass "${cskSessionSaveDecodePassFile}" "$pass"
    fi

    decodeSecret "$file" "$pass"
}

########################################################################

function fixSessionFilePath()
{
    local file="$1"
    if [[ "$file" == @* ]]; then
        file="${cskSessionLocation}/${file:1}"
    else
        file="$(basename -- "${file}")"
        file="${cskSessionLocation}/${file}"
    fi
    echo "${file}"
}

function createSessionStore()
{
    local fs="${cskSessionLocation}"
    mkdir -p "$fs"
    local tfs=$(mount | grep "$fs" | cut -d ' ' -f 1)
    if [ "${tfs}" != "tmpfs" ]; then
        logError "# session: creating tmpfs store in ${fs} (use -ar to choose another)"
        logError
        mount -t tmpfs -o size=4m tmpfs "$fs"
    fi

}

function readSessionPass()
{
    if [ -z "$cskSessionKey" ]; then
        # session specific
        local sData0=""
        if [ -z "$cskSessionSaltFile" ]; then
            cskSessionSaltFile="${cskSessionLocation}/session"
        fi
        if [ -n "$cskSessionSaltFile" ]; then
            if [ ! -e "$cskSessionSaltFile" ]; then
                logError "# session: creating new seed: ${cskSessionSaltFile}"
                restrictFile "$cskSessionSaltFile"
                createRndFile "$cskSessionSaltFile"
            fi
            sData0=$(head -c 64 -- "${cskSessionSaltFile}" | base64 -w 0)
            if [ -z "${sData0}" ]; then
                    onFailed "cannot read session seed from: ${cskSessionSaltFile}"
                else
                    logError "# session: reading seed from: ${cskSessionSaltFile}"
            fi
        fi
        #local sData1="$(uptime -s | tr -d ' :-')"
        #local sData2="$(ps ax | grep -E '/systemd --user|/cron|/udisks' | grep -v grep | tr -s ' ' | cut -d ' ' -f 2 | tr -d '\n')"
        local sessionData="${user}"
        local sSecret="${sessionData}"
        local rsp="${cskSessionAutoKeyFile}"
        if [ -z "${rsp}" ] && [ "${cskSessionAutoKey}" = "0" ]; then
            logError
            if [ "$cskInputMode" = "1" ] || [ "$cskInputMode" = "e" ] || [ "$cskInputMode" = "echo" ]; then
                read -p "Session key (or Enter for default): " rsp
            else
                read -p "Session key (or Enter for default): " -s rsp
            fi
        fi
        logError
        if [ -z "$rsp" ]; then
            logError "# session: default (see -ar ${cskSessionSaltFile})"
        fi
        sSecret="${sessionData}${rsp}"
        cskSessionKey="$(echo -n "${sSecret}" | sha256sum | cut -d ' ' -f 1)"
        debugData "SessionSecret:" "${sSecret}" "SessionKey:" "${cskSessionKey}"
    fi
}

# file
function readSessionPassFromFile()
{
    logError "# session: reading password from: $1"
    if [ -e "$1" ] || [ "$1" = "-" ]; then
        if [ -z "$cskSessionKey" ]; then
            onFailed "no session key"
        fi
        local p
        p=$(cat -- "$1" | base64 -w 0)
        if [ -z "$p" ]; then
            onFailed "cannot read session password from: ${1}"
        fi
        echo -n "$p" | base64 -d | decryptAesSession "$cskSessionKey"
    else
        onFailed "cannot read from: ${1}"
    fi
}

function askOverwriteFile()
{
    local file="$1"
    local fsp=""
    if [ -f "$file" ]; then
        read -p "Overwrite ${file}? [y - (overwrite) | Enter (leave as is)]: " fsp
        if [ "$fsp" != "y" ]; then
            logError "# unchanged: ${file}"
            logError
            return
        fi
        logError
        echo "y"
    else
        echo "y"
    fi
}

# file [pass]
function createSessionPass()
{
    local file="$1"
    local pass="${2:-}"
    logError
    #logError "# session: creating password file: ${cskSessionSaveDecodePassFile}"
    if [ -z "$pass" ]; then
        pass=$(readPassword)
    fi
    readSessionPass
    debugData "${cskSessionKey}" "${pass}"

    # add a token to pass
    restrictFile "${file}"
    echo -n "${pass}CSKEY" | encryptAesSession "$cskSessionKey" > "${file}"
    #ownFile "$file"
    logError
    logError "# session: stored password in: ${file}"
    debugData "$(cat -- ${file} | base64 -w 0)"
    logError
}

# file
function loadSessionPass()
{
    local file="${1:-}"
    if [ -z "$file" ]; then
        return
    fi
    readSessionPass
    set +e
    local pass
    pass=$(readSessionPassFromFile "$file")
    set -e
    if [ -z "${pass}" ] || [ "${pass: -5}" != "CSKEY" ]; then
        debugData "${pass}"
        onFailed "invalid session password in: ${file}"
    fi
    pass="${pass:0:${#pass}-5}" #remove token
    debugData "${pass}"
    cskSessionPassFile="${pass}"
}

# file
function loadSessionSecret()
{
    local file="${1:-}"
    if [ -z "$file" ]; then
        return
    fi
    readSessionPass
    logError "# session: reading secret from: ${file}"
    cskSecret="$(cat -- ${file} | decryptAesSession "$cskSessionKey" | base64 -w 0)"
    if [ -z "$cskSecret" ]; then
        onFailed "cannot read session secret from: ${file}"
    fi
}

# file
function createRndFile()
{
    local file="$1"
    if [ "$file" = "-" ]; then file="/dev/stdout"; fi
    if [ -z "$cskRndLen" ]; then
        local secretLength=$(encryptedSecretLength)
        local maxRndLength=$((1024 - $secretLength))
        cskRndLen=$(($secretLength + RANDOM % $maxRndLength))
    fi
    head -c "$cskRndLen" /dev/urandom > "$file"
    if [ "$1" != "-" ]; then
        local count=$(($cskRndBatch + 0))
        if [ "$count" -gt "64" ]; then
            count=64
        fi
        for ((i=1 ; i <= $count; i++))
        {
            local pad=$(printf "%02d" ${i})
            local file="${1}.${pad}"
            logError "$file"
            createDir "$file"
            head -c "$cskRndLen" /dev/urandom > "$file"
        }
    fi
}

function clearSessionTempDir()
{
    local tfs="${userHome}/mnt/tmpcsm"
    if [ -d "${tfs}" ]; then
        set +e
        mountpoint "${tfs}" &>/dev/null
        if [ "$?" = "0" ]; then
            fuser -km "${tfs}"
            sleep 1
            umount "${tfs}" 2> /dev/null
            logError "# umount: ${tfs}"
        fi
        rmdir "${tfs}"
        set -e
    fi
}

########################################################################

function showHelp()
{
    cat << EOF
Usage: $(basename -- "$0") [enc | dec | ses | rnd | x] file [options]
For dec|enc in place of file any of can be used:
    -  stdout (dec) or stdin (enc)
    -- file is a shortcut not to use a secret file (weak)
    ?  read file path from console
Options:
 -i inputMode : (enc|dec|ses) used for password
    Password input modes:
     0 read from console, no echo (default)
     1|echo|e read from console with echo (-ie can also be used)
     2|copy|c read from 'xclip -o -selection clipboard' (-ic can also be used)
 -c encryptMode : (enc|dec|ses) tool used to encrypt secret
    Use 1 for aes tool (default), 2 for crypt, 3 for gpg
    Ecrypted data of both ccrypt and gpg have indentifying bytes
 -p passFile : (enc|dec|ses) read pass from first line in passFile
 -ap @file : (enc|dec) session: read pass from encrypted file (see -apo)
    Any other password input options are ignored
 -k : (enc|dec) do not ask for keyfiles
 -kf keyFile : (enc|dec) use keyFile (combine with -k)
 -b count : (enc) generate file.count backup copies
 -bs : (enc) generate a new secret for each -b file
 -h hashToolOptions - : (enc|dec) default -h ${cskHashToolOptions[@]} -
 -su : (enc) use only /dev/urandom to generate secret
 -s file : (enc) read secret data (512 binary bytes encoded as 'base64 -w 0') from file
 -as @file : (enc) session: read secret data from a session file (see -aso)
 -aso @outFile : (dec) session: write secret data to a encrypted file
 -apo @outFile : (dec) session: write password data to a encrypted file
 -ar file : (enc|dec|ses) session: use file data as part of session seed
     Created if not exists in $cskSessionLocation
 -aa : (enc|dec|ses) session: do not ask for session key (use default)
 -ak file : (enc|dec|ses) session: read session key from file
 -r length : (rnd) length of random bytes (default random <= 1024)
 -rb count : (rnd) generate file.count files
 -d : dump password and secret on stderr for debug
 -t : (enc) truncate output file, applied only if not -o or -slot
 -o offset : (enc|dec) write/read to/from offset in bytes, default 0
      if not set ent -t truncates output file
      if set, even if zero, enc does not truncate and pads to 1024 length
 -slot|-os|-es slot: (enc|dec) use slot, default 1 is same as -o 0 and -os 1 is same as -o 1024
Examples:
EOF
echo ' sudo bash -c '"'"'secret=$(cskey.sh dec d.txt | base64 -w 0) && cskey.sh enc d.txt -s <(echo -n "$secret")'"'"''
} >&2

# cmd file options
function main()
{
    logError
    local cskCmd="${1:-}"
    if [ -z "$cskCmd" ]; then
        showHelp
        exit 1
    fi
    shift

    if [ "$cskCmd" != "x" ]; then
        cskFile="${1:?"! file"}"
        shift
    fi

    local apf=""
    local asf=""

    while (( $# > 0 )); do
        local current="${1:-}"
        case "$current" in
            -d)
                cskDebug="1"
            ;;
            -i)
                cskInputMode="${2:?"! -i inputMode"}"
                shift
            ;;
            -ie)
                cskInputMode="e"
            ;;
            -ic)
                cskInputMode="c"
            ;;
            -b)
                cskBackup="${2:?"! -b backupCount"}"
                checkNumber "$cskBackup"
                shift
            ;;
            -bs)
                cskBackupNewSecret="1"
            ;;
            -h)
                shift
                cskHashToolOptions=()
                while [ "${1:-}" != "-" ]; do
                    cskHashToolOptions+=( "${1:-}" )
                    set +e
                    shift
                    if [ $? != 0 ]; then
                        onFailed "-h no -"
                    fi
                    set -e
                done
            ;;
            -p)
                local passFile="${2:?"! -p passFile"}"
                cskPassFile=$(readPassFromFile "${passFile}")
                shift
            ;;
            -aa)
                createSessionStore
                cskSessionAutoKey="1"
            ;;
            -ak)
                local sKeyFile="${2:?"! -ak file"}"
                cskSessionAutoKeyFile=$(readPassFromFile "${sKeyFile}")
                shift
            ;;
            -ar)
                createSessionStore
                cskSessionSaltFile="${2:?"! -ar saltFile"}"
                shift
            ;;
            -ap)
                createSessionStore
                apf="${2:?"! -ap file"}"
                apf=$(fixSessionFilePath "${apf}")
                shift
            ;;
            -k)
                cskNoKeyFiles="1"
            ;;
            -kf)
                local kf="${2:?"! -kf file"}"
                cskKeyFiles+=( "$(keyFileHash "$kf")" )
                shift
            ;;
            -s)
                local kk="${2:?"! -s file"}"
                cskSecret=$(cat -- "${kk}")
                if [ -z "$cskSecret" ]; then
                    onFailed "cannot read: ${kk}"
                fi
                shift
            ;;
            -su)
                cskUseURandom="1"
            ;;
            -as)
                createSessionStore
                asf="${2:?"! -as file"}"
                asf=$(fixSessionFilePath "${asf}")
                shift
            ;;
            -c)
                useAes="${2:?"! -c encryptMode"}"
                shift
            ;;
            -aso)
                createSessionStore
                cskSessionSecretFile="${2:?"! -ao file"}"
                cskSessionSecretFile=$(fixSessionFilePath "${cskSessionSecretFile}")
                if [ "$(askOverwriteFile "${cskSessionSecretFile}")" != "y" ]; then
                    cskSessionSecretFile=""
                fi
                shift
            ;;
            -apo)
                createSessionStore
                cskSessionSaveDecodePassFile="${2:?"! -aop file"}"
                cskSessionSaveDecodePassFile=$(fixSessionFilePath "${cskSessionSaveDecodePassFile}")
                if [ "$(askOverwriteFile "${cskSessionSaveDecodePassFile}")" != "y" ]; then
                    cskSessionSaveDecodePassFile=""
                fi
                shift
            ;;
            -r)
                cskRndLen="${2:?"! -r length"}"
                shift
            ;;
            -rb)
                cskRndBatch="${2:?"! -rb count"}"
                checkNumber "$cskRndBatch"
                shift
            ;;
            -o)
                cskDecodeOffset="${2:-0}"
                if [ "$cskDecodeOffset" -lt "0" ]; then
                    onFailed "-o should be >= 0"
                fi
                shift
            ;;
            -os|-es|-slot)
                local slot="${2:-1}"
                if [ "$slot" -lt "1" ]; then
                    onFailed "-slot number should be >= 1"
                fi
                shift
                cskDecodeOffset=$((("$slot" - 1) * 1024))
            ;;
            -t)
                cskTruncate="1"
            ;;
            *)
                logError "! unknown option: $current"
                exit 1
            ;;
        esac
        shift
    done

    case "$cskCmd" in
        enc|e)
            loadSessionPass "${apf}"
            loadSessionSecret "${asf}"
            encryptFile "$cskFile"
        ;;
        dec|d)
            loadSessionPass "${apf}"
            loadSessionSecret "${asf}"
            decryptFile "$cskFile"
        ;;
        ses|s)
            createSessionStore
            cskFile=$(fixSessionFilePath "${cskFile}")
            createSessionPass "$cskFile"
        ;;
        sesp)
            cskFile=$(fixSessionFilePath "${cskFile}")
            loadSessionPass "$cskFile"
            echo "$cskSessionPassFile"
        ;;
        sess)
            cskFile=$(fixSessionFilePath "${cskFile}")
            loadSessionSecret "$cskFile"
            echo "$cskSecret"
        ;;
        x)
            # file arg is ignored
            clearSessionTempDir
        ;;
        rnd|r)
            createRndFile "$cskFile"
        ;;
        *)
            logError "! unknown command: $cskCmd"
            showHelp
        ;;
    esac
}

main "$@"
