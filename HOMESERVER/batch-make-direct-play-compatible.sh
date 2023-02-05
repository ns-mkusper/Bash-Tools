#!/usr/bin/env sh
# converts video files to direct play them over plex through
# chromecast devices
# ref: https://developers.google.com/cast/docs/media

# ARGUMENTS
VERBOSE=${VERBOSE:-0}
# TODO: show usage and handle args with switches
RUN_MULTIPLE=${1:-FALSE}
ORDER=${2:-newest}
DELETE_CORRUPTED_VIDEO_FILES=${3:-FALSE}
H264_OUTPUT_PROFILE=${4:-high}
# TODO: figure out why latest google tv chromecast isn't supported >4.2 directplay
H264_OUTPUT_LEVEL=${5:-4.2}
DECODER_BUFFER_SIZE=${6:-32000k}
DECODER_MIN_RATE=${7:-4500k}
DECODER_MAX_RATE=${8:-16000k} # ~80% of total upload speed
SEARCH_DIRECTORIES=(/mnt/data1/tv/ /mnt/data2/movies/)
# SYSTEM INFERENCE
# ref: https://nvidia.custhelp.com/app/answers/detail/a_id/3742/~/useful-nvidia-smi-queries
GPU_COUNT=$(nvidia-smi -L | wc -l)

if [ $ORDER == "newest" ]
then
    declare -a SORT_OPTIONS=(-rn)
else
    declare -a SORT_OPTIONS=(-n)
fi

if [ $VERBOSE -eq 1 ]
then
    echo "running in VERBOSE mode"
    FFMPEG_LOG_LEVEL=verbose
    set -x
else
    FFMPEG_LOG_LEVEL=quiet
fi

START_TIME=$(date -d '1 day ago' +'%Y-%m-%d %H:%M:%S.%N')
if [ ! -f /mnt/data1/tv/start_time ]
then
    touch -d "$(date -d '4 months ago' +'%Y-%m-%d %H:%M:%S.%N')"  /mnt/data1/tv/start_time
fi

TEMP_VIDEO_FILES_LIST=$(mktemp /tmp/make-direct-play-video-files-list.XXXXXXXXX)
FILTERED_TEMP_VIDEO_FILES_LIST=$(mktemp /tmp/make-direct-play-filtered-video-files-list.XXXXXXXXX)
REVERSED_FILTERED_TEMP_VIDEO_FILES_LIST=$(mktemp /tmp/make-direct-play-reversed-filtered-video-files-list.XXXXXXXXX)

# VIDEO CONVERTING / FFMPEG OPTIONS
FFMPEG_OPTIONS=(-analyzeduration 200000000 -probesize 200000000 -loglevel $FFMPEG_LOG_LEVEL  -nostdin -hwaccel auto)
# map all input streams to output streams except mjpeg and
# attachments which are unsupported in the direct_play codecs
# TODO: Do we wanna handle them in some way?
FFMPEG_VIDEO_AUDIO_INPUT_OPTIONS=(-map V -map 0:a)
# output options ensured to be directy play compliant across all
# chromecast devices
FFMPEG_VIDEO_OPTIONS=(-c:v h264_nvenc -minrate $DECODER_MIN_RATE -maxrate $DECODER_MAX_RATE -bufsize $DECODER_BUFFER_SIZE -profile:v $H264_OUTPUT_PROFILE -level:v $H264_OUTPUT_LEVEL -movflags +faststart -pix_fmt yuv420p)
FFMPEG_AUDIO_OPTIONS=(-c:a aac)

function round() {
    # round decimal values returned by ffmpeg
    local number=$1
    echo $number | awk '{printf("%d\n",$1 + 0.5)}'
}

function log_line () {
    local level=$1
    shift
    if [[ $level == "INFO" || $level == "ERROR" ]]
    then
        echo "${level}: $@"
    elif [[ $level == "VERBOSE" && $VERBOSE -eq 1 ]]
    then
        echo "${level}: $@"
    fi
}

function clean_file_name () {
    # remove script artifacts from filename
    local file_name=$1
    # ensure we're not adding multiple 'fixed' tags in filename
    while [[ "$file_name" =~ .*" fixed" ]]
    do
        file_name="${file_name// fixed/}"
    done

    echo $file_name
}

function build_crop_detect_args() {
    # get arguments for ffmpeg to remove black bars from video files
    local video_file=$1
    local video_duration_seconds=$(round $(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file"))
    local original_resolution=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$video_file")
    local original_height=${original_resolution/*x/}
    local original_width=${original_resolution/x*/}
    local original_area=$((original_width * original_height))
    local crop_lines=()
    local crop_detect_argument=

    # detect black bars at 6/8 points split throughout the middle of the video
    for seconds in `seq $((video_duration_seconds  / 8))  $((video_duration_seconds  / 8)) $((video_duration_seconds - video_duration_seconds  / 8))`
    do
        crop_lines+=($(ffmpeg -ss $seconds -i "$video_file" -vframes 10 -vf cropdetect -f null - 2>&1 | awk '/crop/ { print $NF }' | sed 's/crop=//' | tail -1))
    done

    # take the average of all cropdetect results
    local crop_detect_dimensions=$(printf '%s\n' "${crop_lines[@]}" | sort | uniq -c | sort -k1,1nr -k2 | awk '{print $2; exit}')

    local cropped_resolution=$(echo "${crop_detect_dimensions}" | sed 's/\(:[0-9]\{1,\}\)\{2\}$//')
    local cropped_height=${cropped_resolution/*:/}
    local cropped_width=${cropped_resolution/:*/}
    local cropped_area=$((cropped_width * cropped_height))

    # if the difference is too small or large we might as well not crop anything
    if [ $(echo "($original_area - $cropped_area) < (.05 * $original_area) || ($original_area - $cropped_area) > (.40 * $original_area)" | bc) -eq 1 ]
    then
        return 1
    fi


    echo "crop=${crop_detect_dimensions}"
    return 0
}

function get_subtitles_count () {
    # get subtitle count of video file
    local video_file=$1
    local subtitle_count=$(ffprobe -v quiet  -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 -i "$video_file" | wc -l)
    echo $subtitle_count
}

function get_subtitle_map () {
    # get the full ffmpeg cli -map... sequence for subtitle streams for a given video file
    local video_file=$1
    ffprobe -v quiet -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 -i "$video_file" | sed 's/\([0-9]\{1,\}\),\([a-z0-9]\{1,\}\)/-map 0:s:m:language:\2/'
}

function get_video_codec () {
    local video_file=$1
    local original_video_codec=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    # check if the video file is direct-play-ready
    echo $original_video_codec
}

function get_audio_codec () {
    local video_file=$1
    local original_audio_codec=$(ffprobe -v quiet -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    echo $original_audio_codec
}

function get_h264_level () {
    local video_file=$1
    local original_level=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=level -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local number_re='^[0-9]+$'
    # any non-numerical is invalid
    if ! [[ $original_level =~ $number_re ]]
    then
        original_level=99
    fi

    echo $original_level
}

function get_h264_profile () {
    local video_file=$1
    local original_profile=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 "$video_file")
    echo $original_profile
}

function get_subtitle_codec () {
    local video_file=$1
    local original_subtitle_codec=$(ffprobe -v quiet -select_streams s:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    echo $original_subtitle_codec
}

function is_direct_play_ready () {
    local video_file=$1
    local original_video_codec=$(get_video_codec "$video_file")
    local original_audio_codec=$(get_audio_codec "$video_file")
    local original_level=$(get_h264_level "$video_file")
    local original_profile=$(get_h264_profile "$video_file")
    # check if the video file is direct-play-ready
    # check h264 profile (High works across all chromecast devices) and level (oldest chromecast needs <=41, while newer need >=42)
    if [ "$original_video_codec" != 'h264' -o "$original_audio_codec" != 'aac' -o "$original_level" -gt $H264_OUTPUT_LEVEL -o "$original_profile" != "High" ]
    then
        return 1
    fi

    return 0
}

# filter the found video files and output only those we need to
# convert
function filter_video_list () {
    local video_file=$1
    local output_file=$2

    # check if the file needs converting
    if is_direct_play_ready "$video_file"
    then
        log_line VERBOSE "$video_file is GOOD! Skipping..."
    else
        echo "$video_file" >> $output_file
    fi
}

function make_direct_play () {

    local hwaccel_device=$1
    local bad_video_file=$2

    # skip if the only reason we're converting is lack of subs
    # TODO: grab subs in this case
    if [ -z "$(get_subtitle_codec "$bad_video_file")" ]
    then
        continue
    fi
    local bad_video_file_name=$(basename "$bad_video_file")
    local bad_video_path=$(dirname "$bad_video_file")
    local bad_extension=${bad_video_file: -3}
    local video_file_name="${bad_video_file_name%????}"
    local temp_output_file="${bad_video_path}/${video_file_name} temp.mp4"
    local final_output_file="$(clean_file_name "${bad_video_path}/${video_file_name}") fixed.mp4"
    local ffmpeg_video_options=(${FFMPEG_VIDEO_OPTIONS[@]})

    # set GPU device
    local ffmpeg_options=(${FFMPEG_OPTIONS[@]} -hwaccel_device $hwaccel_device)
    # set correct subtitle options
    local input_subtitle_codec=$(get_subtitle_codec "$bad_video_file")
    if [[ $input_subtitle_codec == hdmv* || $input_subtitle_codec == "dvd"* || $input_subtitle_codec == *"pgs"* || $input_subtitle_codec == "xsub" ]]
    then
        # TODO: OCR bitmap subs (they can't be direct played)?
        local output_subtitle_codec="dvd_subtitle"
        # FFMPEG_INPUT_OPTIONS+=(-map -0:s)
    else
        local output_subtitle_codec="mov_text"

    fi
    local ffmpeg_subtitle_options=(-c:s $output_subtitle_codec)

    # set correct input subtitle mapping options
    readarray -t subtitle_mapping < <(get_subtitle_map "$bad_video_file")
    FFMPEG_INPUT_OPTIONS=(${FFMPEG_VIDEO_AUDIO_INPUT_OPTIONS[@]} ${subtitle_mapping[@]})

    # remove black bars
    local crop_option=$(build_crop_detect_args "$bad_video_file")
    if [ ! -z $crop_option ]
    then
        ffmpeg_video_options+=(-vf $crop_option)
    fi
    # decide what GPU to use
    #GPU=$(hwaccel_device)

    log_line VERBOSE "Converting $bad_video_file_name with extension $bad_extension ..."
    log_line VERBOSE "Creating file: ${final_output_file}..."

    timeout -s9 -k 5 600m ffmpeg ${ffmpeg_options[@]} -i "$bad_video_file" ${FFMPEG_INPUT_OPTIONS[@]} ${ffmpeg_video_options[@]} ${FFMPEG_AUDIO_OPTIONS[@]} ${ffmpeg_subtitle_options[@]} "${temp_output_file}" -y

    #remove old files when done
    if [ $? -le 0 -a -f "$temp_output_file" ]
    then
        local size_of_output=$(stat -c '%s' "$temp_output_file")
        local sub_count_of_output=$(get_subtitles_count "$temp_output_file")
        local sub_count_of_original=$(get_subtitles_count "$bad_video_file")
        if [ $size_of_output -gt 9074118 -a $sub_count_of_output -ge $sub_count_of_original ]
        then
            rm "$bad_video_file"
            mv "${temp_output_file}" "${final_output_file}"
        else
            rm "$temp_output_file"
            log_line ERROR "ERROR: ${temp_output_file} failed check! Deleting and preserving original video file..."
            if [ $DELETE_CORRUPTED_VIDEO_FILES == "TRUE" ]
            then
                log_line VERBOSE "Deleting corrupt ${bad_video_file} ..."
                rm "$bad_video_file"
            fi
        fi
    fi


}

function make_direct_play_with(){
    local gpu=$1
    local next=
    while
        # lock the file, and pop one line from the video files list
        while ! next=$((flock -n 9 || exit 1; sed -e \$$'{w/dev/stdout\n;d}' -i~ "$REVERSED_FILTERED_TEMP_VIDEO_FILES_LIST") 9> ${REVERSED_FILTERED_TEMP_VIDEO_FILES_LIST}.lock)
        do :; done
        # if there is no next line; we're done
        [[ -n $next ]]
    do
        make_direct_play  "$gpu" "$next"
    done
}


ps aux | grep -v grep | grep -qE 'find|ffprobe|ffmpeg'
RUNNING_TEST=$?
if [ $RUNNING_TEST -gt 0 -o $RUN_MULTIPLE == "TRUE" ]
then
    log_line INFO "searching for video files newer than $(stat -c '%y' /mnt/data1/tv/start_time)"


    export -f get_video_codec
    export -f get_audio_codec
    export -f get_h264_level
    export -f get_h264_profile
    export -f get_subtitle_codec
    export -f is_direct_play_ready
    export -f filter_video_list
    export -f log_line
    # build up list of videos we need to check & convert (if needed)
    find ${SEARCH_DIRECTORIES[@]} -size +50M \( -iname \*.262 -or -iname \*.263 -or -iname \*.264 -or -iname \*.3g2 -or -iname \*.3gp -or -iname \*.723 -or -iname \*.amv -or -iname \*.asf -or -iname \*.avi -or -iname \*.drc -or -iname \*.f4a -or -iname \*.f4b -or -iname \*.f4p -or -iname \*.f4v -or -iname \*.flv -or -iname \*.gif -or -iname \*.gifv -or -iname \*.M2TS -or -iname \*.m2v -or -iname \*.m4p -or -iname \*.m4v -or -iname \*.mkv -or -iname \*.mng -or -iname \*.mov -or -iname \*.mp2 -or -iname \*.mp4 -or -iname \*.mpe -or -iname \*.mpeg -or -iname \*.mpg -or -iname \*.mpv -or -iname \*.MTS -or -iname \*.mxf -or -iname \*.net -or -iname \*.nsv -or -iname \*.ogg -or -iname \*.ogv -or -iname \*.rmvb -or -iname \*.roq -or -iname \*.svi -or -iname \*.viv -or -iname \*.vob -or -iname \*.webm -or -iname \*.wmv -or -iname \*.yuv \) -newer /mnt/data1/tv/start_time -printf "%T@ %Tc %p\n" | sort ${SORT_OPTIONS[@]} | sed 's/.* [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} [A-Z]\{2\} [A-Z]\{3\} //' | parallel --silent --jobs 10 "filter_video_list "{}" $FILTERED_TEMP_VIDEO_FILES_LIST"

    # we pop file lines off the bottom of the file
    tac "$FILTERED_TEMP_VIDEO_FILES_LIST" > "$REVERSED_FILTERED_TEMP_VIDEO_FILES_LIST"



    NUMBER_OF_FILES_TO_CONVERT=$(wc -l $FILTERED_TEMP_VIDEO_FILES_LIST | sed 's/ .*//')
    log_line INFO "Converting [ $NUMBER_OF_FILES_TO_CONVERT ] files to direct-play comatible format..."

    # most NVIDIA cards only support 2 video encode sessions so we run
    # only two conversions maximum per card
    #
    # ref: https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new#Encoder
    # TODO: find a more intelligent way to determine this limit
    for gpu in $(seq 0 $((GPU_COUNT - 1)))
    do
        make_direct_play_with "$gpu" &
        #        make_direct_play_with "$gpu" &
    done

    # let all encoding jobs finish before we continue
    wait

    # let the subsequent run know from where to start
    touch -d "$START_TIME" /mnt/data1/tv/start_time
else
    log_line INFO "CHECK STATUS: $RUNNING_TEST"
    log_line ERROR "I'm Already running!"
fi
