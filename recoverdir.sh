#!/usr/bin/env bash
set -o noglob

#
# recoverdir.sh
#

# Embolden Text
b() {
    echo -ne "\e[1m$*\e[21m"
}

# Calculate Time Elapsed
stopwatch() {
    local date_format='%s'
    if [[ $1 == -s ]]; then
        stopwatch_start="$(date +"$date_format")"
        return 0
    fi
    local stop="$(date +"$date_format")"
    local start="$stopwatch_start"
    local difference="$((stop - start))"
    local s="$((difference % 60))"
    [[ ${#s} -lt 2 ]] && s="0$s"
    local m="$((difference / 60))"
    [[ ${#m} -lt 2 ]] && m="0$m"
    local h="$((m / 60))"
    [[ ${#h} -lt 2 ]] && h="0$h"
    echo "$(b TIME) $h:$m:$s"
}
stopwatch -s

# Print Help Message
help_message="\
$(b USAGE)
    recoverdir.sh IMAGE_FILE BASE_INODE [EXCEPT_INODE ...]
$(b OPTIONS)
    -h  Print this help message, then exit successfully.
    -R  Do not recover files, instead exit successfully.
    -s  Calculate the size of all catalogued files and directories.
    -q  Do not print catalogue entries, time elapsed, or recovery operations.
    -b  Do not recover files or directories deeper than base level."
print_help() {
    echo -e "$help_message"
    exit 0
}

# Parse Options
opt_regex='^-[A-Za-z]+$'
for param in "$@"; do
    #echo "ARGS $*"
    if [[ $param == -- ]]; then
        set -- ${*#--}
        break
    elif [[ $param =~ $opt_regex ]]; then
        opts="$opts${param//-}"
        set -- ${*%$param}
    fi
done
[[ $opts == *h* ]] && print_help
echo "$(b OPTS) -${opts:--}"
[[ $opts == *R* ]] && no_recover=0
[[ $opts == *s* ]] && calc_size=0
[[ $opts == *q* ]] && quiet=0
[[ $opts == *b* ]] && base_only=0


# Handle Errors
error() {
    echo -e "\e[31;7m$*\e[0m" 1>&2
    exit 1
}

# Parse Arguments
[[ $# -lt 2 ]] && error 'ARGS ERROR'

image="$1"
[[ ! -r $image ]] && error 'IMAGE ERROR'
image_fstype="$(fsstat -t "$image")"
image_format="$(img_stat -t "$image")"
echo "$(b IMAGE) $image $(b FSTYPE) $image_fstype $(b FORMAT) $image_format"

inode_regex='^[0-9]+$'
base_inode="$2"
except_inodes=("${@:3}")
for inode in "$base_inode" "${except_inodes[@]}"; do
    [[ ! $inode =~ $inode_regex ]] && error 'INODE ERROR'
done
echo "$(b INODE) $base_inode${except_inodes[@]:+ $(b EXCEPT) }${except_inodes[*]}"

base_dir="$PWD"
[[ ! -w $base_dir ]] && error 'DIR ERROR'

# Format Catalogue Entries
# (RECURSION_LEVEL/)NAME/INODE
format_entry() {
    local pluses
    local rlvl
    if [[ $1 == -r ]]; then
        shift
        pluses="${*//[^+]}"
        rlvl="${#pluses}/"
    fi
    echo -n "$rlvl$(echo "$*" | cut -f2)/$(echo "$*" | sed -e 's/:.*//' -e 's/\+* *.\/. //')"
}

# Catalogue Directories
[[ $base_only ]] && fls_opts='Du'
dirs=()
while read -r; do
    dir="$(format_entry -r "$REPLY")"
    
    # Exclude Directories
    rlvl="$(echo "$dir" | cut -d/ -f1)"
    dir_inode="$(echo "$dir" | cut -d/ -f3)"
    for inode in "${except_inodes[@]}"; do
        if [[ $dir_inode -eq $inode ]]; then
            skip_rlvl="$rlvl"
            continue 2
        fi
    done
    if [[ $skip_rlvl ]]; then
        if [[ $rlvl -le $skip_rlvl ]]; then
            unset skip_rlvl
        else
            continue
        fi
    fi
    
    dirs+=("$dir")
    [[ ! $quiet ]] && echo "$(b DIR) $dir"
done < <(fls -"${fls_opts:-Dru}" -f "$image_fstype" -i "$image_format" "$image" "$base_inode")


# Catalogue Files
files=()
while read -r; do
    file="$(format_entry "$REPLY")"
    files+=("$file")
    [[ ! $quiet ]] && echo "$(b FILE) $file"
done < <(fls -Fu -f "$image_fstype" -i "$image_format" "$image" "$base_inode")

if [[ ! $base_only ]]; then
    newline=$'\n'
    dir_files=()
    for dir in "${dirs[@]}"; do
        dir_inode="$(echo "$dir" | cut -d/ -f3)"
        while read -r; do
            file="$(format_entry "$REPLY")"
            declare dir_files["$dir_inode"]="${dir_files[$dir_inode]}$file$newline"
            [[ ! $quiet ]] && echo "$(b DIR) $dir $(b FILE) $file"
        done < <(fls -Fu -f "$image_fstype" -i "$image_format" "$image" "$dir_inode")
    done
fi

[[ ! $quiet ]] && stopwatch

# Calculate Total Size of Catalogued Files
if [[ $calc_size ]]; then
    total_size=0
    for file in "${files[@]}"; do
        file_name="$(echo "$file" | cut -d/ -f1)"
        file_inode="$(echo "$file" | cut -d/ -f2)"
        file_size="$(istat -f "$image_fstype" -i "$image_format" "$image" "$file_inode" | grep '^size:' | cut -d' ' -f2)"
        ((total_size += file_size))
        echo "$(b FSIZE) $file_size $(b FNAME) $file_name"
    done
    dir_size=-1
    for dir in "${dirs[@]}"; do
        rlvl="$(echo "$dir" | cut -d/ -f1)"
        dir_inode="$(echo "$dir" | cut -d/ -f3)"
        if [[ $rlvl -eq 0 && $dir_size -ne -1 ]]; then
            echo "$(b DSIZE) $dir_size $(b DNAME) $dir_name"
            dir_name="$(echo "$dir" | cut -d/ -f2)"
            dir_size=0
        elif [[ $dir_size -eq -1 ]]; then
            dir_name="$(echo "$dir" | cut -d/ -f2)"
            dir_size=0
        fi
        IFS="$newline"
        for file in ${dir_files[$dir_inode]}; do
            file_inode="$(echo "$file" | cut -d/ -f2)"
            file_size="$(istat -f "$image_fstype" -i "$image_format" "$image" "$file_inode" | grep '^size:' | cut -d' ' -f2)"
            ((total_size += file_size))
            ((dir_size += file_size))
            #echo "FSIZE $file_size"
        done
        unset IFS
    done
    [[ $dir_size -ne -1 ]] && echo "$(b DSIZE) $dir_size $(b DNAME) $dir_name"
    bil=1000000000
    echo "$(b TSIZE) $total_size ($((total_size / bil)).$(echo "$((total_size % bil))" | cut -c -2) GB)"
    
    [[ ! $quiet ]] && stopwatch
fi

# Recover Base Files
[[ $no_recover ]] && exit 0

for file in "${files[@]}"; do
    file_name="$(echo "$file" | cut -d/ -f1)"
    file_inode="$(echo "$file" | cut -d/ -f2)"
    icat -r -f "$image_fstype" -i "$image_format" "$image" "$file_inode" > "$base_dir/$file_name"
    [[ ! $quiet ]] && echo "$(b RFILE) ./$file_name"
done

# Reconstruct Directories
for dir in "${dirs[@]}"; do
    rlvl="$(echo "$dir" | cut -d/ -f1)"
    dir_name="$(echo "$dir" | cut -d/ -f2)"
    dir_inode="$(echo "$dir" | cut -d/ -f3)"
    if [[ $rlvl -eq 0 ]]; then
        make_dir="$base_dir/$dir_name"
    elif [[ $rlvl -eq $last_rlvl ]]; then
        make_dir="${make_dir%/*}/$dir_name"
    elif [[ $rlvl -gt $last_rlvl ]]; then
        make_dir="$make_dir/$dir_name"
    elif [[ $rlvl -lt $last_rlvl ]]; then
        rlvl_diff=$(((last_rlvl - rlvl) + 1))
        until [[ $rlvl_diff -eq 0 ]]; do
            make_dir="${make_dir%/*}"
            ((rlvl_diff -= 1))
        done
        make_dir="$make_dir/$dir_name"
    fi
    mkdir -p "$make_dir"
    [[ ! $quiet ]] && echo "$(b MKDIR) ${make_dir/#$base_dir/.}"
    
    # Recover Directory Files
    IFS="$newline"
    for file in ${dir_files[$dir_inode]}; do
        file_name="$(echo "$file" | cut -d/ -f1)"
        file_inode="$(echo "$file" | cut -d/ -f2)"
        icat -r -f "$image_fstype" -i "$image_format" "$image" "$file_inode" > "$make_dir/$file_name"
        [[ ! $quiet ]] && echo "$(b RFILE) ${make_dir/#$base_dir/.}/$file_name"
    done
    unset IFS
    
    last_rlvl="$rlvl"
done

[[ ! $quiet ]] && stopwatch

