#!/usr/bin/env bash
set -o noglob

#
# recoverdir.sh
#

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
[[ $opts ]] && echo "OPTS $opts"
[[ $opts == *R* ]] && no_recover=0
[[ $opts == *s* ]] && calc_size=0

# Parse Arguments
error() {
    echo -e "\e[31m$*\e[0m" 1>&2
    exit 1
}

[[ $# -lt 2 ]] && error 'ARGS ERROR'

image="$1"
[[ ! -r $image ]] && error 'IMAGE ERROR'
image_fstype="$(fsstat -t "$image")"
image_format="$(img_stat -t "$image")"
echo "IMAGE $image FSTYPE $image_fstype FORMAT $image_format"

inode_regex='^[0-9]+$'
base_inode="$2"
except_inodes=("${@:3}")
for inode in "$base_inode" "${except_inodes[@]}"; do
    [[ ! $inode =~ $inode_regex ]] && error 'INODE ERROR'
done
echo "INODE $base_inode${except_inodes[@]:+ EXCEPT }${except_inodes[*]}"

base_dir="$PWD"
[[ ! -w $base_dir ]] && error 'DIR ERROR'

# Format Catalogue Entry
# (RECURSION_LEVEL/)NAME/INODE
format_entry() {
    if [[ $1 == -r ]]; then
        shift
        pluses="${*//[^+]}"
        rlvl="${#pluses}/"
    fi
    echo -n "$rlvl$(echo "$*" | cut -f2)/$(echo "$*" | sed -e 's/:.*//' -e 's/\+* *.\/. //')"
}

# Catalogue Directories
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
            unset skip_level
        else
            continue
        fi
    fi
    
    dirs+=("$dir")
    echo "DIR $dir"
done < <(fls -Dru -f "$image_fstype" -i "$image_format" "$image" "$base_inode")

# Catalogue Files
files=()
while read -r; do
    file="$(format_entry "$REPLY")"
    files+=("$file")
    echo "FILE $file"
done < <(fls -Fu -f "$image_fstype" -i "$image_format" "$image" "$base_inode")

newline=$'\n'
dir_files=()
for dir in "${dirs[@]}"; do
    dir_inode="$(echo "$dir" | cut -d/ -f3)"
    while read -r; do
        file="$(format_entry "$REPLY")"
        declare dir_files["$dir_inode"]="${dir_files[$dir_inode]}$file$newline"
        echo "DIR $dir FILE $file"
    done < <(fls -Fu -f "$image_fstype" -i "$image_format" "$image" "$dir_inode")
done

# Calculate Total Size of Catalogued Files
if [[ $calc_size ]]; then
    tsize=0
    for file in "${files[@]}"; do
        file_inode="$(echo "$file" | cut -d/ -f2)"
        file_size="$(istat -f "$image_fstype" -i "$image_format" "$image" "$file_inode" | grep '^size:' | cut -d' ' -f2)"
        ((tsize += file_size))
        echo "FSIZE $file_size"
    done
    for dir in "${dirs[@]}"; do
        dir_inode="$(echo "$dir" | cut -d/ -f3)"
        IFS="$newline"
        for file in ${dir_files[$dir_inode]}; do
            file_inode="$(echo "$file" | cut -d/ -f2)"
            file_size="$(istat -f "$image_fstype" -i "$image_format" "$image" "$file_inode" | grep '^size:' | cut -d' ' -f2)"
            ((tsize += file_size))
            echo "FSIZE $file_size"
        done
        unset IFS
    done
    bil=1000000000
    echo "TSIZE $tsize ($((tsize / bil)).$(echo "$((tsize % bil))" | cut -c -2) GB)"
fi

# Recover Base Files
[[ $no_recover ]] && exit 0

for file in "${files[@]}"; do
    file_name="$(echo "$file" | cut -d/ -f1)"
    file_inode="$(echo "$file" | cut -d/ -f2)"
    icat -r -f "$image_fstype" -i "$image_format" "$image" "$file_inode" > "$base_dir/$file_name"
    echo "RFILE ~~/$file_name"
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
    echo "MDIR ${make_dir/#$base_dir/~~}"
    
    # Recover Directory Files
    IFS="$newline"
    for file in ${dir_files[$dir_inode]}; do
        file_name="$(echo "$file" | cut -d/ -f1)"
        file_inode="$(echo "$file" | cut -d/ -f2)"
        icat -r -f "$image_fstype" -i "$image_format" "$image" "$file_inode" > "$make_dir/$file_name"
        echo "RFILE ${make_dir/#$base_dir/~~}/$file_name"
    done
    unset IFS
    
    last_rlvl="$rlvl"
done

