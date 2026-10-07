#!/data/data/com.termux/files/usr/bin/bash

# ============================================================
# MP4/MKV -> AMV Batch Converter
# ============================================================
#
# Usage:
#
#   ./convert_amv.sh
#
#   ./convert_amv.sh --subtitles
#
#   ./convert_amv.sh \
#       --cores 2 \
#       --threads 1 \
#       --mode fill \
#       --subtitles \
#       --delete \
#       --input "/path/to/input" \
#       --output "/path/to/output"
#
# ============================================================


# ============================================================
# Defaults
# ============================================================

DEFAULT_INPUT="$HOME/storage/downloads/videos"

CORES=1
THREADS=1
MODE="ratio"
SUBTITLES="no"
SUBTITLE_MODE="normal"
DELETE_MODE="no"

INPUT="$DEFAULT_INPUT"
OUTPUT=""


# ============================================================
# Help
# ============================================================

show_help() {

    cat << EOF

MP4/MKV -> AMV Converter

Usage:

  ./convert_amv.sh [options]

Options:

  --cores N
      Number of videos to convert simultaneously.
      Default: 1

  --threads N
      FFmpeg threads per conversion.
      Default: 1

  --mode MODE
      ratio = preserve aspect ratio
      fill  = fill 320x240 and crop excess

      Default: ratio

  --subtitles [ss]
      Burn embedded subtitles into the AMV when available.

      With --subtitles alone, English/en subtitles are preferred,
      then the first available subtitle stream.

      With --subtitles ss, Signs & Songs subtitles are preferred,
      then English/en subtitles, then the first available stream.

      If no embedded subtitles exist, conversion continues without subtitles.

      ASS/HTML formatting is removed before
      rendering. Long subtitles are then
      hard-wrapped to prevent cutoff.

  --delete
      Delete original video ONLY after successful
      conversion.

  PAUSE / RESUME
      Ctrl+C stops the batch safely. Completed
      conversions are saved and skipped automatically
      when you run the script again.

      Ctrl+Z pauses the entire foreground job.
      Type "fg" to resume it.

  --input PATH
      Input directory containing MP4/MKV files.

  --output PATH
      Output directory for AMV files.

  --help
      Show this help.

EOF

}


# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --cores)

            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 ]]; then
                echo "ERROR: --cores requires a positive integer."
                exit 1
            fi

            CORES="$2"
            shift 2
            ;;


        --threads)

            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 ]]; then
                echo "ERROR: --threads requires a positive integer."
                exit 1
            fi

            THREADS="$2"
            shift 2
            ;;


        --mode)

            if [[ -z "$2" ]]; then
                echo "ERROR: --mode requires 'ratio' or 'fill'."
                exit 1
            fi

            case "$2" in

                ratio|fill)
                    MODE="$2"
                    ;;

                *)
                    echo "ERROR: Invalid mode '$2'."
                    echo "Valid modes: ratio, fill"
                    exit 1
                    ;;

            esac

            shift 2
            ;;


        --subtitles)

            SUBTITLES="yes"
            SUBTITLE_MODE="normal"

            if [[ "${2:-}" == "ss" ]]; then
                SUBTITLE_MODE="ss"
                shift 2
            else
                shift
            fi
            ;;


        --delete)

            DELETE_MODE="yes"
            shift
            ;;


        --input)

            if [[ -z "$2" ]]; then
                echo "ERROR: --input requires a directory path."
                exit 1
            fi

            INPUT="$2"
            shift 2
            ;;


        --output)

            if [[ -z "$2" ]]; then
                echo "ERROR: --output requires a directory path."
                exit 1
            fi

            OUTPUT="$2"
            shift 2
            ;;


        --help|-h)

            show_help
            exit 0
            ;;


        *)

            echo "ERROR: Unknown option: $1"
            echo
            show_help
            exit 1
            ;;

    esac

done


# ============================================================
# Default output
# ============================================================

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$INPUT/amv"
fi


# ============================================================
# Validate input
# ============================================================

if [[ ! -d "$INPUT" ]]; then

    echo "ERROR: Input directory does not exist:"
    echo "  $INPUT"

    exit 1

fi


# ============================================================
# Create output directory
# ============================================================

if ! mkdir -p "$OUTPUT"; then

    echo "ERROR: Could not create output directory:"
    echo "  $OUTPUT"

    exit 1

fi


# ============================================================
# Temporary files
# ============================================================

PROGRESS_FILE="$OUTPUT/.progress"
PROGRESS_LOCK="$OUTPUT/.progress_lock"

FAILED_FILE="$OUTPUT/.failed"
FAILED_LOCK="$OUTPUT/.failed_lock"


# ============================================================
# Permanent failure report
#
# Stored in the INPUT folder.
# Contains ONLY filenames, one per line.
# ============================================================

FAILED_REPORT="$INPUT/failed_conversions.txt"
FAILED_REPORT_LOCK="$INPUT/.failed_conversions.lock"


# Keep .progress between runs so interrupted batches can resume.
rm -f \
    "$PROGRESS_LOCK" \
    "$FAILED_FILE" \
    "$FAILED_LOCK" \
    "$FAILED_REPORT" \
    "$FAILED_REPORT_LOCK"


touch "$PROGRESS_FILE"
touch "$FAILED_FILE"
touch "$FAILED_REPORT"


# ============================================================
# AMV settings
# ============================================================

BITRATE="100k"


# ============================================================
# Subtitle settings
#
# Output canvas:
#
#   320x240
#
# Safe subtitle area:
#
#   40 px left
#   240 px usable
#   40 px right
#
# IMPORTANT:
#
# SUBTITLE_MAX_CHARS is now actually used by the
# subtitle hard-wrapping function below.
# ============================================================

SUBTITLE_FONT="DejaVu Sans"

SUBTITLE_FONT_SIZE="28"

SUBTITLE_SPACING="1"

SUBTITLE_OUTLINE="1"

SUBTITLE_SHADOW="1"

SUBTITLE_MARGIN_LEFT="50"

SUBTITLE_MARGIN_RIGHT="0"

SUBTITLE_MARGIN_V="4"

SUBTITLE_MAX_CHARS="20"


# ============================================================
# Build normal video filter
# ============================================================

build_normal_filter() {

    if [[ "$MODE" == "fill" ]]; then

        echo "scale=320:240:force_original_aspect_ratio=increase,crop=320:240"

    else

        echo "scale=320:240:force_original_aspect_ratio=decrease"

    fi

}


# ============================================================
# Build subtitle video filter
#
# The video preserves its aspect ratio.
#
# The video is flush with the top of the 320x240 canvas.
#
# In ratio mode, the video is centered horizontally.
#
# Subtitles are allowed to overlap the video.
# ============================================================

build_subtitle_video_filter() {

    if [[ "$MODE" == "fill" ]]; then

        echo "scale=320:240:force_original_aspect_ratio=increase,crop=320:240"

    else

        echo "scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:0:black"

    fi

}


# ============================================================
# Escape filename for FFmpeg subtitles filter
# ============================================================

escape_subtitle_filename() {

    local FILE="$1"

    FILE="${FILE//\\/\\\\}"
    FILE="${FILE//:/\\:}"
    FILE="${FILE//\'/\\\'}"

    echo "$FILE"

}


# ============================================================
# Find subtitle stream
#
# Signs & Songs subtitles are preferred. English subtitles are used as a fallback.
#
# If no English subtitle exists, the first subtitle stream
# is used.
# ============================================================

find_subtitle_stream() {

    local INPUT_FILE="$1"

    local SIGNS_SONGS_STREAM
    local ENGLISH_STREAM
    local FIRST_STREAM


    # --------------------------------------------------------
    # In normal mode, English/en is preferred.
    # In ss mode, Signs & Songs is preferred first.
    # --------------------------------------------------------

    if [[ "$SUBTITLE_MODE" == "ss" ]]; then
        SIGNS_SONGS_STREAM="$({
            ffprobe \
                -v error \
                -select_streams s \
                -show_entries stream=index:stream_tags=language,title \
                -of csv=p=0 \
                "$INPUT_FILE" 2>/dev/null || true
        } | awk -F',' '
            BEGIN {
                IGNORECASE=1
                SUB_INDEX=0
            }
            {
                TITLE = ""
                if ($3 != "") TITLE = $3

                if (TITLE ~ /signs[[:space:]]*&[[:space:]]*songs/ ||
                    TITLE ~ /signs[[:space:]]+and[[:space:]]+songs/) {
                    print SUB_INDEX
                    exit
                }
                SUB_INDEX++
            }
        ')"

        if [[ -n "$SIGNS_SONGS_STREAM" ]]; then
            echo "$SIGNS_SONGS_STREAM"
            return 0
        fi
    fi


    # --------------------------------------------------------
    # Find English subtitle.
    # Accept common English language tags such as:
    #   eng, en, en-US, en-GB, English
    # --------------------------------------------------------

    ENGLISH_STREAM="$({
        ffprobe \
            -v error \
            -select_streams s \
            -show_entries stream=index:stream_tags=language,title \
            -of csv=p=0 \
            "$INPUT_FILE" 2>/dev/null || true
    } | awk -F',' '
        BEGIN {
            IGNORECASE=1
            SUB_INDEX=0
        }
        {
            LANGUAGE = $2
            gsub(/^"|"$/, "", LANGUAGE)
            gsub(/[[:space:]]+/, "", LANGUAGE)
            LANGUAGE = tolower(LANGUAGE)

            if (LANGUAGE == "eng" ||
                LANGUAGE == "en" ||
                LANGUAGE ~ /^en[-_]/ ||
                LANGUAGE == "english") {
                print SUB_INDEX
                exit
            }
            SUB_INDEX++
        }
    ')"

    if [[ -n "$ENGLISH_STREAM" ]]; then
        echo "$ENGLISH_STREAM"
        return 0
    fi


    # --------------------------------------------------------
    # Fall back to the first subtitle stream.
    # --------------------------------------------------------

    FIRST_STREAM="$({
        ffprobe \
            -v error \
            -select_streams s \
            -show_entries stream=index \
            -of csv=p=0 \
            "$INPUT_FILE" 2>/dev/null || true
    } | awk 'NR == 1 { print 0; exit }')"

    if [[ -n "$FIRST_STREAM" ]]; then
        echo "$FIRST_STREAM"
        return 0
    fi

    return 1
}

# ============================================================
# Extract embedded subtitle stream
#
# The Signs & Songs track is ASS and contains literal HTML
# <font ...> markup. Converting it to SRT first can split the
# HTML tag itself into separate subtitle lines, which is what
# caused the floating "face=", "size=", color numbers, etc.
#
# We therefore extract the subtitle as ASS and convert the
# Dialogue events ourselves, stripping the formatting before
# the text ever reaches the SRT renderer.
# ============================================================

extract_subtitle() {

    local INPUT_FILE="$1"
    local SUBTITLE_INDEX="$2"
    local OUTPUT_SRT="$3"
    local TEMP_ASS="${OUTPUT_SRT}.ass"


    # Extract the original subtitle without converting it.
    if ! ffmpeg \
        -hide_banner \
        -loglevel error \
        -y \
        -i "$INPUT_FILE" \
        -map "0:s:$SUBTITLE_INDEX" \
        -c:s ass \
        "$TEMP_ASS"; then

        rm -f "$TEMP_ASS"
        return 1
    fi


    # Convert ASS Dialogue events to clean SRT.
    awk '

    function ass_ms(T,    a,b,c,d) {
        split(T,a,":")
        split(a[3],b,"\\.")
        c = (a[1] * 3600) + (a[2] * 60) + b[1]
        d = (b[2] == "" ? 0 : b[2])
        while (length(d) < 2) d = d "0"
        return c * 1000 + d * 10
    }

    function srt_time(ms,    h,m,s,x) {
        if (ms < 0) ms = 0
        h = int(ms / 3600000)
        m = int(ms / 60000) % 60
        s = int(ms / 1000) % 60
        x = ms % 1000
        return sprintf("%02d:%02d:%02d,%03d", h,m,s,x)
    }

    function clean_text(T) {

        # Remove complete ASS override blocks.
        gsub(/\{[^}]*\}/, "", T)

        # Remove literal HTML/XML tags, including font tags.
        gsub(/<[^>]*>/, "", T)

        # ASS line-break escapes.
        gsub(/\\[NnHh]/, " ", T)

        # Common leftover ASS commands.
        gsub(/\\(pos|move|org|clip|iclip|t|fad|fade|fs|fn|bord|shad|blur|be|an|a|k|K|kf|ko|fr|frx|fry|frz|p|q|r|c|alpha|1c|2c|3c|4c|1a|2a|3a|4a)[^[:space:]]*/, "", T)

        # HTML entities.
        gsub(/&nbsp;/, " ", T)
        gsub(/&amp;/, "&", T)
        gsub(/&lt;/, "<", T)
        gsub(/&gt;/, ">", T)
        gsub(/&quot;/, "\"", T)

        # Remove any remaining angle-bracket fragments.
        gsub(/<+/, "", T)
        gsub(/>+/, "", T)

        # Normalize whitespace.
        gsub(/[[:space:]]+/, " ", T)
        sub(/^ +/, "", T)
        sub(/ +$/, "", T)

        # Reject pure numeric/coordinate garbage.
        if (T ~ /^[[:digit:][:space:][:punct:]]+$/ &&
            T !~ /[[:alpha:]]/)
            return ""

        return T
    }

    function emit(    wrapped) {
        if (cur_text == "")
            return

        wrapped = cur_text
        if (wrapped == "")
            return

        count++
        print count
        print srt_time(cur_start) " --> " srt_time(cur_end)
        print wrapped
        print ""

        cur_text = ""
        cur_start = ""
        cur_end = ""
    }

    # --------------------------------------------------------
    # ASS Dialogue line.
    #
    # Fields:
    # Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,
    #           MarginV,Effect,Text
    #
    # Text may itself contain commas, so everything after the
    # ninth comma belongs to Text.
    # --------------------------------------------------------

    /^Dialogue:/ {

        line = $0
        sub(/^Dialogue:[[:space:]]*/, "", line)

        n = split(line, f, ",")
        if (n < 10)
            next

        start = ass_ms(f[2])
        end   = ass_ms(f[3])

        text = f[10]

        for (i = 11; i <= n; i++)
            text = text "," f[i]

        text = clean_text(text)

        if (text == "")
            next

        # ----------------------------------------------------
        # Merge ONLY overlapping/near-contiguous word events.
        #
        # This is deliberately NOT allowed to merge across
        # arbitrary subtitle events or the entire video.
        #
        # A Signs & Songs word that starts while the previous
        # word is still active gets appended to the same line.
        # ----------------------------------------------------

        if (cur_text == "") {

            cur_start = start
            cur_end = end
            cur_text = text

        }
        else if (start <= cur_end + 75 &&
                 start - cur_start <= 2000) {

            if (cur_text !~ /[[:space:]]$/)
                cur_text = cur_text " "

            cur_text = cur_text text

            if (end > cur_end)
                cur_end = end

        }
        else {

            emit()

            cur_start = start
            cur_end = end
            cur_text = text

        }

        next
    }

    END {
        emit()
    }

    ' "$TEMP_ASS" > "$OUTPUT_SRT"

    RESULT=$?

    rm -f "$TEMP_ASS"

    return $RESULT

}


# ============================================================
# Hard-wrap already-clean SRT subtitle text
#
# This stage ONLY wraps text. It does not attempt to interpret
# ASS/HTML markup because that markup has already been removed
# by extract_subtitle().
# ============================================================

wrap_subtitle_text() {

    local INPUT_SRT="$1"
    local OUTPUT_SRT="$2"


    awk -v MAX="$SUBTITLE_MAX_CHARS" '

    function wrap_line(TEXT,    words,n,i,word,current,result,part) {

        gsub(/[[:space:]]+/, " ", TEXT)
        sub(/^ /, "", TEXT)
        sub(/ $/, "", TEXT)

        if (TEXT == "")
            return ""

        n = split(TEXT, words, " ")

        current = ""
        result = ""

        for (i = 1; i <= n; i++) {

            word = words[i]

            while (length(word) > MAX) {

                part = substr(word, 1, MAX)

                if (current != "") {

                    if (result != "")
                        result = result "\n"

                    result = result current
                    current = ""

                }

                if (result != "")
                    result = result "\n"

                result = result part

                word = substr(word, MAX + 1)

            }

            if (word == "")
                continue

            if (current == "") {

                current = word

            }
            else if (length(current) + 1 + length(word) <= MAX) {

                current = current " " word

            }
            else {

                if (result != "")
                    result = result "\n"

                result = result current

                current = word

            }

        }

        if (current != "") {

            if (result != "")
                result = result "\n"

            result = result current

        }

        return result
    }


    # --------------------------------------------------------
    # SRT sequence number
    # --------------------------------------------------------

    /^[0-9]+$/ {

        if (block != "")
            printf "%s\n\n", block

        block = $0
        in_text = 0
        next
    }


    # --------------------------------------------------------
    # SRT timestamp
    # --------------------------------------------------------

    /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9],[0-9][0-9][0-9][[:space:]]+-->[[:space:]]+/ {

        block = block "\n" $0
        in_text = 1
        next
    }


    # --------------------------------------------------------
    # Subtitle text
    # --------------------------------------------------------

    {
        if (in_text) {

            wrapped = wrap_line($0)

            if (wrapped != "")
                block = block "\n" wrapped

        }
    }


    END {

        if (block != "")
            printf "%s\n", block

    }

    ' "$INPUT_SRT" > "$OUTPUT_SRT"

    return $?
}


# ============================================================
# Build complete video filter
#
# IMPORTANT:
#
# This function receives the ALREADY WRAPPED subtitle SRT.
#
# It no longer extracts subtitles directly from the original
# video. That happens earlier in convert_file().
# ============================================================

build_video_filter() {

    local SUBTITLE_FILE="$1"

    local FILTER


    # --------------------------------------------------------
    # Normal conversion
    # --------------------------------------------------------

    if [[ -z "$SUBTITLE_FILE" || ! -s "$SUBTITLE_FILE" ]]; then

        FILTER="$(build_normal_filter)"

        echo "$FILTER"

        return 0

    fi


    # --------------------------------------------------------
    # Escape subtitle filename.
    # --------------------------------------------------------

    local ESCAPED_FILE

    ESCAPED_FILE="$(escape_subtitle_filename "$SUBTITLE_FILE")"


    # --------------------------------------------------------
    # Build video portion.
    # --------------------------------------------------------

    FILTER="$(build_subtitle_video_filter)"


    # --------------------------------------------------------
    # Add subtitle renderer.
    #
    # Alignment=2:
    #
    #   Bottom-center
    #
    # MarginL=40 / MarginR=40:
    #
    #   Keeps subtitle area away from the 40-pixel
    #   crop zones.
    #
    # The SRT has already been hard-wrapped.
    #
    # WrapStyle=2 remains as an additional safeguard.
    # --------------------------------------------------------

    FILTER="$FILTER,subtitles='${ESCAPED_FILE}':force_style='FontName=${SUBTITLE_FONT},FontSize=${SUBTITLE_FONT_SIZE},Spacing=${SUBTITLE_SPACING},Outline=${SUBTITLE_OUTLINE},Shadow=${SUBTITLE_SHADOW},Alignment=2,MarginL=${SUBTITLE_MARGIN_LEFT},MarginR=${SUBTITLE_MARGIN_RIGHT},MarginV=${SUBTITLE_MARGIN_V},WrapStyle=2'"


    echo "$FILTER"

    return 0

}


# ============================================================
# Print configuration
# ============================================================

echo
echo "=========================================="
echo "           AMV CONVERTER"
echo "=========================================="
echo
echo "Input:       $INPUT"
echo "Output:      $OUTPUT"
echo "Cores:       $CORES"
echo "Threads:     $THREADS"
echo "Mode:        $MODE"
echo "Subtitles:   $SUBTITLES"
if [[ "$SUBTITLES" == "yes" ]]; then
    echo "Subtitle mode: $SUBTITLE_MODE"
fi
echo "Delete:      $DELETE_MODE"
echo
echo "Resolution:  320x240"
echo "Video codec: AMV"
echo "Bitrate:     $BITRATE"
echo "FPS:         25"

if [[ "$SUBTITLES" == "yes" ]]; then

    echo
    echo "Subtitle font:     $SUBTITLE_FONT"
    echo "Subtitle size:     $SUBTITLE_FONT_SIZE"
    echo "Character spacing: $SUBTITLE_SPACING"
    echo "Max chars/line:    $SUBTITLE_MAX_CHARS"
    echo "Safe left:         ${SUBTITLE_MARGIN_LEFT}px"
    echo "Safe right:        ${SUBTITLE_MARGIN_RIGHT}px"
    echo "Safe width:        240px"

fi

echo
echo "Failure log: $FAILED_REPORT"
echo
echo "=========================================="
echo


# ============================================================
# Resume helpers
# ============================================================

already_converted() {

    local INPUT_FILE="$1"
    local RELATIVE_PATH="${INPUT_FILE#$INPUT/}"
    local RELATIVE_DIR="$(dirname "$RELATIVE_PATH")"
    local BASE_NAME="$(basename "$RELATIVE_PATH")"
    BASE_NAME="${BASE_NAME%.*}"

    local OUTPUT_DIR

    if [[ "$RELATIVE_DIR" == "." ]]; then
        OUTPUT_DIR="$OUTPUT"
    else
        OUTPUT_DIR="$OUTPUT/$RELATIVE_DIR"
    fi

    local OUTPUT_FILE="$OUTPUT_DIR/$BASE_NAME.amv"

    # A file is considered complete only when:
    # 1. It is recorded in .progress
    # 2. The AMV still exists and is non-empty
    [[ -s "$OUTPUT_FILE" ]] || return 1
    grep -Fxq "$INPUT_FILE" "$PROGRESS_FILE" 2>/dev/null
}


record_success() {

    local INPUT_FILE="$1"

    (
        flock -x 200

        if ! grep -Fxq "$INPUT_FILE" "$PROGRESS_FILE" 2>/dev/null; then
            echo "$INPUT_FILE" >> "$PROGRESS_FILE"
        fi

    ) 200>"$PROGRESS_LOCK"
}


record_failure() {

    local INPUT_FILE="$1"

    (
        flock -x 200
        echo "$INPUT_FILE" >> "$FAILED_FILE"
    ) 200>"$FAILED_LOCK"

    (
        flock -x 200
        basename "$INPUT_FILE" >> "$FAILED_REPORT"
    ) 200>"$FAILED_REPORT_LOCK"
}


# ============================================================
# Ctrl+C handler
#
# Ctrl+C stops the batch.
#
# Completed conversions remain in .progress.
# Run the script again to resume.
# ============================================================

handle_interrupt() {

    echo
    echo "=========================================="
    echo "       CONVERSION STOPPED BY USER"
    echo "=========================================="
    echo
    echo "Completed files have been saved."
    echo "Run the script again to resume."
    echo

    exit 130
}


# ============================================================
# Conversion function
# ============================================================

convert_file() {

    local INPUT_FILE="$1"


    # --------------------------------------------------------
    # Skip files already converted in an earlier run.
    # --------------------------------------------------------

    if already_converted "$INPUT_FILE"; then

        echo
        echo "SKIPPING (already converted):"
        echo "  ${INPUT_FILE#$INPUT/}"

        return 0

    fi


    # --------------------------------------------------------
    # Relative path
    # --------------------------------------------------------

    local RELATIVE_PATH

    RELATIVE_PATH="${INPUT_FILE#$INPUT/}"


    # --------------------------------------------------------
    # Determine output directory
    # --------------------------------------------------------

    local RELATIVE_DIR

    RELATIVE_DIR="$(dirname "$RELATIVE_PATH")"


    local BASE_NAME

    BASE_NAME="$(basename "$RELATIVE_PATH")"
    BASE_NAME="${BASE_NAME%.*}"


    local OUTPUT_DIR


    if [[ "$RELATIVE_DIR" == "." ]]; then

        OUTPUT_DIR="$OUTPUT"

    else

        OUTPUT_DIR="$OUTPUT/$RELATIVE_DIR"

    fi


    mkdir -p "$OUTPUT_DIR"


    local OUTPUT_FILE

    OUTPUT_FILE="$OUTPUT_DIR/$BASE_NAME.amv"


    # --------------------------------------------------------
    # Start message
    # --------------------------------------------------------

    echo
    echo "Converting:"
    echo "  $RELATIVE_PATH"


    # ========================================================
    # Subtitle preparation
    # ========================================================

    local TEMP_SUBTITLE=""
    local WRAPPED_SUBTITLE=""
    local SUBTITLE_INDEX=""


    if [[ "$SUBTITLES" == "yes" ]]; then


        # ----------------------------------------------------
        # Find subtitle stream. Missing subtitles are NOT an
        # error: the conversion simply continues without them.
        # ----------------------------------------------------

        SUBTITLE_INDEX="$(find_subtitle_stream "$INPUT_FILE")"


        if [[ -z "$SUBTITLE_INDEX" ]]; then
            echo "  No embedded subtitles found; converting without subtitles."
            SUBTITLES_FOR_FILE="no"
        else

            # ------------------------------------------------
            # Temporary subtitle filenames.
            # ------------------------------------------------

            TEMP_SUBTITLE="$OUTPUT_DIR/.${BASE_NAME}_subtitle_$$.srt"
            WRAPPED_SUBTITLE="$OUTPUT_DIR/.${BASE_NAME}_wrapped_$$.srt"


            # ------------------------------------------------
            # Extract embedded subtitle.
            # ------------------------------------------------

            if ! extract_subtitle \
                "$INPUT_FILE" \
                "$SUBTITLE_INDEX" \
                "$TEMP_SUBTITLE"; then

                echo "  Could not extract subtitle; converting without subtitles."
                rm -f "$TEMP_SUBTITLE" "$WRAPPED_SUBTITLE"
                TEMP_SUBTITLE=""
                WRAPPED_SUBTITLE=""

            # ------------------------------------------------
            # HARD-WRAP subtitle text.
            # ------------------------------------------------

            elif ! wrap_subtitle_text \
                "$TEMP_SUBTITLE" \
                "$WRAPPED_SUBTITLE"; then

                echo "  Could not process subtitle; converting without subtitles."
                rm -f "$TEMP_SUBTITLE" "$WRAPPED_SUBTITLE"
                TEMP_SUBTITLE=""
                WRAPPED_SUBTITLE=""
            fi
        fi
    fi


    # ========================================================
    # Build video filter
    # ========================================================

    local FILTER


    FILTER="$(build_video_filter "$WRAPPED_SUBTITLE")"


    # ========================================================
    # Find English audio track
    # ========================================================

    local AUDIO_STREAM


    AUDIO_STREAM="$(
        ffprobe \
            -v error \
            -select_streams a \
            -show_entries stream=index:stream_tags=language \
            -of csv=p=0 \
            "$INPUT_FILE" 2>/dev/null |
        awk -F',' '
            BEGIN {
                IGNORECASE=1
            }

            /,eng$/ {
                print $1
                exit
            }
        '
    )"


    # --------------------------------------------------------
    # If no English track, use first audio track.
    # --------------------------------------------------------

    if [[ -z "$AUDIO_STREAM" ]]; then

        AUDIO_STREAM="$(
            ffprobe \
                -v error \
                -select_streams a \
                -show_entries stream=index \
                -of csv=p=0 \
                "$INPUT_FILE" 2>/dev/null |
            head -n 1
        )"

    fi


    # ========================================================
    # Conversion
    # ========================================================

    local RESULT=0


    # --------------------------------------------------------
    # Video WITH audio
    # --------------------------------------------------------

    if [[ -n "$AUDIO_STREAM" ]]; then

        ffmpeg \
            -hide_banner \
            -loglevel error \
            -y \
            -i "$INPUT_FILE" \
            -map 0:v:0 \
            -map "0:$AUDIO_STREAM" \
            -af "aresample=22050:async=1:first_pts=0" \
            -vf "$FILTER" \
            -c:v amv \
            -b:v "$BITRATE" \
            -r 25 \
            -c:a adpcm_ima_amv \
            -ar 22050 \
            -ac 1 \
            -block_size 882 \
            -threads "$THREADS" \
            -strict -1 \
            "$OUTPUT_FILE"

        RESULT=$?


    # --------------------------------------------------------
    # Video WITHOUT audio
    # --------------------------------------------------------

    else

        ffmpeg \
            -hide_banner \
            -loglevel error \
            -y \
            -i "$INPUT_FILE" \
            -f lavfi \
            -i "anullsrc=channel_layout=mono:sample_rate=22050" \
            -map 0:v:0 \
            -map 1:a:0 \
            -shortest \
            -af "aresample=22050:async=1:first_pts=0" \
            -vf "$FILTER" \
            -c:v amv \
            -b:v "$BITRATE" \
            -r 25 \
            -c:a adpcm_ima_amv \
            -ar 22050 \
            -ac 1 \
            -block_size 882 \
            -threads "$THREADS" \
            -strict -1 \
            "$OUTPUT_FILE"

        RESULT=$?

    fi


    # ========================================================
    # Clean temporary subtitle files
    # ========================================================

    if [[ -n "$TEMP_SUBTITLE" ]]; then
        rm -f "$TEMP_SUBTITLE"
    fi

    if [[ -n "$WRAPPED_SUBTITLE" ]]; then
        rm -f "$WRAPPED_SUBTITLE"
    fi


    # ========================================================
    # Successful conversion
    # ========================================================

    if [[ "$RESULT" -eq 0 && -s "$OUTPUT_FILE" ]]; then

        echo "SUCCESS:"
        echo "  $OUTPUT_FILE"


        # ----------------------------------------------------
        # Record success
        # ----------------------------------------------------
        record_success "$INPUT_FILE"


        # ----------------------------------------------------
        # Delete original only after successful conversion
        # ----------------------------------------------------

        if [[ "$DELETE_MODE" == "yes" ]]; then

            if rm -f "$INPUT_FILE"; then

                echo "Deleted original:"
                echo "  $INPUT_FILE"

            else

                echo "WARNING: Could not delete original:"
                echo "  $INPUT_FILE"

            fi

        fi


        return 0

    fi


    # ========================================================
    # Failed conversion
    # ========================================================

    echo "FAILED:"
    echo "  $RELATIVE_PATH"


    # Remove incomplete AMV.
    rm -f "$OUTPUT_FILE"


    # --------------------------------------------------------
    # Record failure
    # --------------------------------------------------------
    record_failure "$INPUT_FILE"


    return 1

}


# ============================================================
# Export function and variables
# ============================================================

export -f convert_file
export -f already_converted
export -f record_success
export -f record_failure

export -f build_normal_filter
export -f build_subtitle_video_filter
export -f escape_subtitle_filename
export -f find_subtitle_stream
export -f extract_subtitle
export -f wrap_subtitle_text
export -f build_video_filter

export INPUT
export OUTPUT
export THREADS
export MODE
export SUBTITLES
export SUBTITLE_MODE
export DELETE_MODE
export BITRATE

export SUBTITLE_FONT
export SUBTITLE_FONT_SIZE
export SUBTITLE_SPACING
export SUBTITLE_OUTLINE
export SUBTITLE_SHADOW
export SUBTITLE_MARGIN_LEFT
export SUBTITLE_MARGIN_RIGHT
export SUBTITLE_MARGIN_V
export SUBTITLE_MAX_CHARS

export PROGRESS_FILE
export PROGRESS_LOCK

export FAILED_FILE
export FAILED_LOCK

export FAILED_REPORT
export FAILED_REPORT_LOCK


# ============================================================
# Find videos
# ============================================================

echo "Searching for videos..."
echo


mapfile -d '' FILES < <(

    find "$INPUT" \
        -type f \
        \( -iname "*.mp4" -o -iname "*.mkv" \) \
        ! -path "$OUTPUT/*" \
        ! -name "failed_conversions.txt" \
        -print0

)


TOTAL="${#FILES[@]}"


# ============================================================
# No videos found
# ============================================================

if [[ "$TOTAL" -eq 0 ]]; then

    echo "No MP4 or MKV files found."
    echo

    rm -f \
        "$PROGRESS_LOCK" \
        "$FAILED_FILE" \
        "$FAILED_LOCK" \
        "$FAILED_REPORT_LOCK"

    exit 0

fi


echo "Found $TOTAL video(s)."
echo

# Ctrl+C = clean batch stop.
# Ctrl+Z = shell-level pause; "fg" resumes.
trap 'handle_interrupt' INT


# ============================================================
# Parallel conversion
# ============================================================

printf '%s\0' "${FILES[@]}" |

xargs \
    -0 \
    -n 1 \
    -P "$CORES" \
    bash -c 'convert_file "$1"' _


# ============================================================
# Results
# ============================================================

SUCCESS_COUNT=$(wc -l < "$PROGRESS_FILE")
FAILED_COUNT=$(wc -l < "$FAILED_FILE")


echo
echo "=========================================="
echo "             CONVERSION DONE"
echo "=========================================="
echo
echo "Total:       $TOTAL"
echo "Successful:  $SUCCESS_COUNT"
echo "Failed:      $FAILED_COUNT"
echo


# ============================================================
# Failed files
# ============================================================

if [[ "$FAILED_COUNT" -gt 0 ]]; then

    echo "FAILED FILES:"
    echo

    while IFS= read -r FILE; do

        echo "  $(basename "$FILE")"

    done < "$FAILED_FILE"


    echo
    echo "Failure report:"
    echo "  $FAILED_REPORT"
    echo

else

    echo "All conversions completed successfully."
    echo

fi


# ============================================================
# Cleanup temporary files
# ============================================================

rm -f \
    "$PROGRESS_LOCK" \
    "$FAILED_FILE" \
    "$FAILED_LOCK" \
    "$FAILED_REPORT_LOCK"

echo
echo "Progress saved in:"
echo "  $PROGRESS_FILE"
echo "Run the script again to resume unfinished conversions."
echo
echo "Done."