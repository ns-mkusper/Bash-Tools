#!/usr/bin/env sh
# removes black bars from video files

# USAGE: ./remove-black-bars.sh "video.mp4"

INPUT_VIDEO_FILE=$1
VERBOSE=${VERBOSE:-0}
H264_OUTPUT_PROFILE=${4:-main}
H264_OUTPUT_LEVEL=${5:-5.1}
DECODER_BUFFER_SIZE=${6:-32000k}
DECODER_MIN_RATE=${7:-4500k}
DECODER_MAX_RATE=${8:-16000k} # ~80% of total upload speed

if [ $VERBOSE -eq 1 ]
then
    echo "running in VERBOSE mode"
    FFMPEG_LOG_LEVEL=verbose
    set -x
else
    FFMPEG_LOG_LEVEL=quiet
fi

function round() {
    # round decimal values returned by ffmpeg
    local number=$1
    echo $number | awk '{printf("%d\n",$1 + 0.5)}'
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
    local original_resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$video_file")
    local original_height=${original_resolution/*x/}
    local original_width=${original_resolution/x*/}
    local original_area=$((original_width * original_height))
    local crop_lines=()
    local crop_detect_argument=

    # detect black bars at 4/6 points split throughout the middle of the video
    for seconds in `seq $((video_duration_seconds / 6))  $((video_duration_seconds / 6)) $((video_duration_seconds - video_duration_seconds / 6))`
    do
        crop_lines+=($(ffmpeg -ss $seconds -i "$video_file" -vframes 10 -vf cropdetect -f null - 2>&1 | awk '/crop/ { print $NF }' | sed 's/crop=//' | tail -1))
    done

    # take the average of all cropdetect results
    crop_detect_dimensions=$(for line in "${crop_lines[@]}"
                             do
                                 echo $line
                             done | awk -F':' '{for (i=1;i<=NF;i++){a[i]+=$i;}} END {for (i=1;i<=NF;i++){printf "%.0f", a[i]/NR; printf ":"};printf "\n"}' | sed 's/:$//')

    local cropped_resolution=$(echo "${crop_detect_dimensions}" | sed 's/\(:[0-9]\{1,\}\)\{2\}$//')
    local cropped_height=${cropped_resolution/*:/}
    local cropped_width=${cropped_resolution/:*/}
    local cropped_area=$((cropped_width * cropped_height))

    # if the difference is too small or large we might as well not crop anything
    if [ $(echo "($original_area - $cropped_area) < (.05 * $original_area)" | bc) -eq 1 -o  $(echo "($original_area - $cropped_area) > (.40 * $original_area)" | bc) -eq 1 ]
    then
        return 1
    fi


    echo "crop=${crop_detect_dimensions}"
    return 0
}

# VIDEO CONVERTING / FFMPEG OPTIONS
FFMPEG_OPTIONS=(-analyzeduration 2000000000 -probesize 2000000000 -loglevel $FFMPEG_LOG_LEVEL  -nostdin -hwaccel auto)


INPUT_VIDEO_FILE_NAME=$(basename "$INPUT_VIDEO_FILE")
BAD_VIDEO_PATH=$(dirname "$INPUT_VIDEO_FILE")
BAD_EXTENSION=${INPUT_VIDEO_FILE: -3}
VIDEO_FILE_NAME="${INPUT_VIDEO_FILE_NAME%????}"
TEMP_OUTPUT_FILE="${BAD_VIDEO_PATH}/${VIDEO_FILE_NAME} temp.mp4"
FINAL_OUTPUT_FILE="$(clean_file_name "${BAD_VIDEO_PATH}/${VIDEO_FILE_NAME}") fixed.mp4"

# remove black bars
CROP_OPTION=$(build_crop_detect_args "$INPUT_VIDEO_FILE")
if [ $? -eq 0 ]
then

    timeout -s9 -k 5 600m ffmpeg ${FFMPEG_OPTIONS[@]} -i "$INPUT_VIDEO_FILE" -map 0 -c:a copy -c:s copy -filter:v "$CROP_OPTION" "${TEMP_OUTPUT_FILE}" -y

    #remove old files when done
    if [ $? -le 0 -a -f "$TEMP_OUTPUT_FILE" ]
    then
        SIZE_OF_OUTPUT=$(stat -c '%s' "$TEMP_OUTPUT_FILE")
	if [ $SIZE_OF_OUTPUT -gt 9074118 ]
        then
	    rm "$INPUT_VIDEO_FILE"
            mv "${TEMP_OUTPUT_FILE}" "${FINAL_OUTPUT_FILE}"
        else
            rm "$TEMP_OUTPUT_FILE"
	fi

    fi
fi
