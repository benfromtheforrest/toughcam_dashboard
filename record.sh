#!/bin/bash

# Variables
DURATION=600   # Duration of each segment in seconds
WIDTH=2304
HEIGHT=1296
FRAMERATE=56
BITRATE=10000000
SEGMENT_SIZE=100000000 # Segment size in bytes
TEMP_DIR="./temp_videos"
OUTPUT_DIR="./output_videos"
LOG_FILE="./video_processing.log"
GPS_DEVICE="/dev/ttyACM0"
GPS_BAUDRATE=38400
ENABLE_GPS_LOGGING=true  # Set to false to disable GPS logging
POWER_CYCLE_GPS=false  # Set to false to disable power cycling the GPS
RETRY_INTERVAL=5  # Interval (in seconds) to check for GPS device availability

# Path to the USB reset script
USB_RESET_SCRIPT="./reset_gps_usb.sh"

# Create directories if they don't exist
mkdir -p $TEMP_DIR
mkdir -p $OUTPUT_DIR

# Variables to hold process IDs
recording_pid=0
gps_pid=0
processing_pid=0

# Function to log timestamps with millisecond accuracy
log_time() {
    local event=$1
    local specific_log_file=$2
    echo "$(date +%Y-%m-%dT%H:%M:%S.%3N) - $event" | tee -a $LOG_FILE $specific_log_file
}

# Function to process video segments
process_segment() {
    local input_file=$1
    local output_pattern=$2
    local start_time=$3
    local specific_log_file=$4

    # Capture processing start time
    local processing_start_time=$(date +%s%3N)
    log_time "Processing started for $input_file" $specific_log_file

    gst-launch-1.0 filesrc location=$input_file ! qtdemux ! queue ! h264parse ! splitmuxsink location=$output_pattern max-size-bytes=$SEGMENT_SIZE

    # Capture processing end time
    local processing_end_time=$(date +%s%3N)
    log_time "Processing finished for $input_file" $specific_log_file

    # Calculate and print processing elapsed time
    local processing_elapsed_time=$((processing_end_time - processing_start_time))
    echo "Processing time for $input_file: $processing_elapsed_time ms" | tee -a $specific_log_file

    # Add start time metadata to the first output file
    first_output_file=$(printf "$output_pattern" 0)
    ffmpeg -i $first_output_file -metadata creation_time="$(date -d @$((start_time/1000)) +'%Y-%m-%dT%H:%M:%S.%3N')" -codec copy "${first_output_file%.mp4}_sync.mp4"

    # Replace original file with sync file
    mv "${first_output_file%.mp4}_sync.mp4" "${first_output_file}"

    rm $input_file
}

# Function to log GPS data
log_gps_data() {
    local gps_log_file=$1

    # Wait for the GPS device to become available
    while [ ! -e $GPS_DEVICE ]; do
        echo "Waiting for GPS device $GPS_DEVICE to become available..."
        sleep $RETRY_INTERVAL
    done

    stty -F $GPS_DEVICE $GPS_BAUDRATE
    cat $GPS_DEVICE > $gps_log_file &
    gps_pid=$!

    # Return the PID of the GPS logging process
    echo $gps_pid
}

# Function to power cycle the USB device without holding execution
power_cycle_usb() {
    echo "Power cycling USB device using $USB_RESET_SCRIPT"
    sudo $USB_RESET_SCRIPT &
}

# Graceful shutdown function
graceful_shutdown() {
    echo "Graceful shutdown initiated..."

    if [ $recording_pid -ne 0 ]; then
        kill $recording_pid 2>/dev/null
        wait $recording_pid 2>/dev/null
    fi

    if [ $gps_pid -ne 0 ]; then
        kill $gps_pid 2>/dev/null
        wait $gps_pid 2>/dev/null
    fi

    if [ $processing_pid -ne 0 ]; then
        kill $processing_pid 2>/dev/null
        wait $processing_pid 2>/dev/null
    fi

    echo "Shutdown complete."
    exit 0
}

# Set trap to catch termination signals and call graceful_shutdown
trap graceful_shutdown SIGINT SIGTERM

# Record and process in parallel
while true; do
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    TEMP_FILENAME="$TEMP_DIR/${TIMESTAMP}_video.mp4"
    OUTPUT_PATTERN="$OUTPUT_DIR/${TIMESTAMP}_video_%05d.mp4"
    SPECIFIC_LOG_FILE="$OUTPUT_DIR/${TIMESTAMP}_log.log"
    GPS_LOG_FILE="$OUTPUT_DIR/${TIMESTAMP}_gps.log"

    # Log the script start time
    log_time "Script started" $SPECIFIC_LOG_FILE

    # Power cycle the USB device if enabled
    if [ "$POWER_CYCLE_GPS" = true ]; then
        power_cycle_usb
        log_time "Power cycled the USB device" $SPECIFIC_LOG_FILE
    fi

    # Capture the precise start time before recording
    precise_start_time=$(date +%s%3N)
    log_time "Recording start time captured: $precise_start_time" $SPECIFIC_LOG_FILE

    if [ "$ENABLE_GPS_LOGGING" = true ]; then
        # Start logging GPS data
        gps_pid=$(log_gps_data $GPS_LOG_FILE)
        log_time "Started logging GPS data to $GPS_LOG_FILE" $SPECIFIC_LOG_FILE
    fi

    # Record the video segment
    libcamera-vid -t $((DURATION * 1000)) --height $HEIGHT --width $WIDTH --framerate $FRAMERATE --bitrate $BITRATE -o $TEMP_FILENAME &
    recording_pid=$!
    wait $recording_pid

    # Log the recording end time
    recording_end_time=$(date +%s%3N)
    log_time "Recording ended: $recording_end_time" $SPECIFIC_LOG_FILE

    if [ "$ENABLE_GPS_LOGGING" = true ]; then
        # Stop logging GPS data
        kill $gps_pid
        wait $gps_pid
        log_time "Stopped logging GPS data" $SPECIFIC_LOG_FILE
    fi

    # Detect when the file is created in the filesystem
    while [ ! -f "$TEMP_FILENAME" ]; do
        sleep 0.001
    done
    file_detect_time=$(date +%s%3N)
    log_time "File detected in filesystem: $TEMP_FILENAME at $file_detect_time" $SPECIFIC_LOG_FILE

    # Process the recorded segment
    process_segment "$TEMP_FILENAME" "$OUTPUT_PATTERN" "$precise_start_time" "$SPECIFIC_LOG_FILE" &
    processing_pid=$!
    wait $processing_pid

    # Log the processing end time
    processing_end_time=$(date +%s%3N)
    log_time "Processing ended for $TEMP_FILENAME: $processing_end_time" $SPECIFIC_LOG_FILE

    # Calculate and print segmenting elapsed time
    segmenting_time=$((processing_end_time - recording_end_time))
    echo "Time between end of recording and output file creation: $segmenting_time ms" | tee -a $SPECIFIC_LOG_FILE
done
