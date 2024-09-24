#!/usr/bin/env zsh
setopt nullglob
set -Eeo pipefail
IFS=$'\n\t'

p() { print -lnNr -- "${@}"; }

fz() { fzf --multi --border=bold --border-label=" ${1} " --header="${2}:" }

ff_1=(
	ffmpeg
	-loglevel "quiet"
	-hide_banner
	-nostdin
	-stats
	-y
)

ff_2=(
	-fflags "+genpts+igndts+discardcorrupt+bitexact"
	-avoid_negative_ts "make_zero"
	-err_detect "ignore_err"
	-ignore_unknown
	-reset_timestamps "1"
 	-start_at_zero
)

fd_code() {
	sed -nE '
		/id="'${1}'"/{
		:a
		n
		/reference_name/!ba
		s/.*reference_name="([^"]+)".*/\1/p
		q
		}' "/usr/share/xml/iso-codes/iso_639-3.xml"
}

probe() {
	ffprobe \
		-v quiet \
		-show_entries stream=index,codec_type,codec_name,channels \
		-show_entries stream_tags=language,BPS,BPS-eng \
		-of compact=p=0:nk=1 \
		"${src}"
}

chkpkg() {
	packages=("${@}")
	for pkg in ${packages}; do
		command -v "${pkg}" > "/dev/null" 2>&1 || {
			p "You need to install: \"${pkg}\""
			exit
		}
	done
}

extract() {
	src="$(p *.{mkv,mp4,m2ts} | fz "SOURCES" "Select the source")"

	ext="${src:e}"

	str=("${(f)$(probe)}")
	
	sel="$(p "${(M)str[@]:#*(audio|video|subrip)*}" | fz "STREAMS" "Select a stream")"
	ext="${${(s.|.)sel}[2]}"

	case "${sel}" in
		*"audio"*)
			lang="${${(s.|.)sel}[5]}"
			fl="-vn -sn"
			# ext="mka"
			;;
		*"video"*)
			lang="out_video"
			fl="-an -sn"
			;;
		*"subrip"*)
			ext="srt"
			lang="${${(s.|.)sel}[4]}"
			fl="-vn -an"
			;;
	esac

	sel="${sel%%|*}"

	${ff_1[@]} \
		-i "${src}" \
		-c "copy" \
		-dn \
		-map_chapters -1 \
		${ff_2[@]} \
		-metadata title="" \
		${(z)fl} \
		-map "0:${sel}" \
		"${lang}.${ext}"
}

combine() {
        video_src="$(p *.{mkv,ivf} | fz "VIDEO SOURCE" "Select the video source")"

        audio_srcs=($(p *.{mka,opus} | fz "AUDIO SOURCES" "Select the audio source(s)"))

	subtitle_srcs=($(p *.srt | fz "SUBTITLE SOURCES" "Select the subtitle source(s)"))

        map_opts=(-map "0:v")
        meta_opts=()
        input_opts=(-i "${video_src}")

	for ((i = 1; i <= ${#audio_srcs[@]}; i++)); do
		input_opts+=(-i "${audio_srcs[i]}")
		map_opts+=(-map "${i}")
		lang_code="${audio_srcs[i]%.*}"
		lang_code="${lang_code##*_}"
		lang_name="$(fd_code "${lang_code}")"
		meta_opts+=(-metadata:s:a:"$((i-1))" "language=${lang_code}" \
			-metadata:s:a:"$((i-1))" "title=${lang_name}")
	done

	for ((i = 1; i <= ${#subtitle_srcs[@]}; i++)); do
		input_opts+=(-sub_charenc "UTF-8" -i "${subtitle_srcs[i]}")
		map_opts+=(-map "$((i + 1))")
		lang_code="${subtitle_srcs[i]%.*}"
		lang_code="${lang_code##*.}"
		lang_name="$(fd_code "${lang_code}")"
		meta_opts+=(-metadata:s:s:"$((i-1))" "language=${lang_code}" \
			-metadata:s:s:"$((i-1))" "title=${lang_name}")
	done

	p "Enter the Title: "
	read -r title

	input_cnt="$((1 + ${#audio_srcs[@]} + ${#subtitle_srcs[@]}))"
	[[ -s "FFMETADATAFILE" ]] && {
		input_opts+=(-i "FFMETADATAFILE")
		map_opts+=(-map_metadata "${input_cnt}")
	} || map_opts+=(-map_metadata -1 -map_chapters -1)

	${ff_1[@]} \
		${input_opts[@]} \
		${map_opts[@]} \
		-c:v "copy" \
		-c:a "copy" \
		-c:s "srt" \
		${meta_opts[@]} \
		-metadata title="${title:-}" \
		${ff_2[@]} \
		"output_combined.mkv"
}

print_pts() {
	(( ${#funcstack[@]} > 2 )) || src="$(p *.{mkv,mp4,m2ts} | fz "SOURCES" "Select the source")"

	ffprobe \
		-v "quiet" \
		-select_streams "v" \
		-show_entries packet=pts_time,flags -of csv=print_section=0 \
		"${src}" | awk -F',' '$2 ~ /K/ {print $1}'
}

fcut() {
	opt="$(p "Extract Video" "Extract Audio" "Copy Everything" |
		fz "OPTIONS" "Extract the stream or cut with everything")"

	src="$(p *.{mkv,mp4,m2ts} | fz "SOURCES" "Select the source")"

	frames=($(print_pts))

	init="$(p ${frames} | fz "Keyframes" "Select the Initial Keyframe")"
	init_ind=${frames[(ie)$init]}

	frames[1,init_ind]=()

	ending="$(p ${frames} | fz "Keyframes" "Select the Ending Keyframe")"

	common_1=(
		"${ff_1[@]}"
		-i "${src}"
		-c "copy"
		"${ff_2[@]}"
		-ss "${init}"
		-to "${ending}"
	)

	common_2=(
		-dn -sn
		-map_chapters -1
		-metadata title=""
	)

	case "${opt}" in
		"Extract Video")
			"${common_1[@]}" \
				"${common_2[@]}" \
				-map "0:v" \
				-an \
				"cut_${src%.*}.mkv"
			;;
		"Extract Audio")
			"${common_1[@]}" \
				"${common_2[@]}" \
				-map "0:a" \
				-vn \
				"cut_${src%.*}.mka"
			;;
	        "Copy Everything") "${common_1[@]}" -map "0" "cut_${src%.*}.mkv" ;;
	esac
}

metform() {
	[[ -s "FFMETADATAFILE" ]] || return 0

	grep -q 'FFMETADATA1' "FFMETADATAFILE" && return 0

	print -rl ';FFMETADATA1' > "tmp_meta"
	awk 'BEGIN {
		FS = "="
		chapter_count = 0
		CONVFMT = "%.0f"
	}

	/CHAPTER[0-9]+=/ {
		chapter_count++
		split($2, time, ":")
		start_ms = ((time[1] * 3600) + (time[2] * 60) + time[3]) * 1000
		starts[chapter_count] = sprintf("%.0f", start_ms)
	}

	/CHAPTER[0-9]+NAME=/ {
		titles[chapter_count] = $2
	}

	END {
		for (i = 1; i <= chapter_count; i++) {
			print "[CHAPTER]"
			print "TIMEBASE=1/1000"
			print "START=" starts[i]
			if (i == chapter_count) {
				print "END=99999999"
			} else {
				print "END=" starts[i+1]
			}
			print "title=" titles[i]
			if (i < chapter_count) print ""
		}
	}' "FFMETADATAFILE" >> "tmp_meta"

	mv -f "tmp_meta" "FFMETADATAFILE"
}

encopus() {
	src="$(p *.{mkv,mp4,m2ts,dts,ac3,aac,mka} | fz "SOURCES" "Select the source")"

	str=("${(f)$(probe)}")
	sel="$(p "${(M)str[@]:#*audio*}" | fz "STREAMS" "Select a stream")"

	lang="${${(s.|.)sel}[5]}"

	sel="${sel%%|*}"

	p "Enter the desired bitrate: "
	read -r br

	${ff_1[@]} \
		-i "${src}" \
		-metadata title="" \
		-metadata language="" \
		-metadata:s:a:0 language="" \
		-map_metadata -1 \
		-map_chapters -1 \
		-dn -sn -vn \
		-map "0:${sel}" \
		-c:a "libopus" \
		-b:a "${br}k" \
	        -application "audio" \
		-frame_duration "20" \
		-compression_level "10" \
		-vbr "on" \
		-mapping_family "255" \
		-apply_phase_inv "true" \
		-packet_loss "0" \
		${ff_2[@]} \
		"${lang:-${src%.*}}.opus"
}

ask() {
	src="$(p *.{mkv,mp4,m2ts,hevc} | fz "SOURCES" "Select the source")"

	preset="$(p {-1..13} | fz "PRESET" "Select a preset")"

	crf="$(p {10..63} | fz "CRF" "Select the CRF")"

	FG="$(p {0..50} | fz "Film Grain" "Amount of Film Grain")"
}

populate() {
	params=(
		--preset "${preset}"
		--crf "${crf}"
		--film-grain "${FG}"
		--tune "3"
		--qp-scale-compress-strength "3"
		--sharpness "1"
	)
}

map_color() { print -r -- "${color_map[$1]:-$1}"; }

colors() {
	typeset -A color_map=(
		[bt2020nc]=bt2020-ncl
		[bt2020c]=bt2020-cl
		[smpte170m]=bt601
		[iec61966-2-1]=srgb
		[arib-std-b67]=hlg
	)
	
	matrix_opts=(
		identity bt709 unspecified fcc bt470bg bt601 smpte240 ycgco
		bt2020-ncl bt2020-cl smpte2085 chroma-ncl chroma-cl ictcp
	)

	trans_opts=(
		bt709 unspecified bt470m bt470bg bt601 smpte240 linear log100 log100-sqrt10
		iec61966 bt1361 srgb bt2020-10 bt2020-12 smpte2084 smpte428 hlg
	)

	prime_opts=(
		bt709 unspecified bt470m bt470bg bt601 smpte240
		film bt2020 xyz smpte431 smpte432 ebu3213
	)

	hdr_opts=(bt2020-ncl bt2020-cl ictcp bt2020-10 bt2020-12 smpte2084 hlg bt2020)

	eval "$(ffprobe -v quiet -y -hide_banner \
		-select_streams v:0 \
		-show_entries stream=color_range,color_space,color_transfer,color_primaries,chroma_location \
		-of default=noprint_wrappers=1 "${src}")" || true

	case "${color_range}" in
		"tv"|"limited") params+=( --color-range 0 ) ;;
		"full"|"pc") params+=( --color-range 1 ) ;;
		*) true ;;
	esac

	[[ "${color_space}" && "${color_space}" != "unknown" ]] && {
		map_matrix="$(map_color "${color_space}")"
		params+=( --matrix-coefficients "${map_matrix}" )
	}

	[[ "${color_transfer}" && "${color_transfer}" != "unknown" ]] && {
		map_trans="$(map_color "${color_transfer}")"
		params+=( --transfer-characteristics "${map_trans}" )
	}

	[[ "${color_primaries}" && "${color_primaries}" != "unknown" ]] && {
		map_prime="$(map_color "${color_primaries}")"
		params+=( --color-primaries "${map_prime}" )
	}

	case "${chroma_location}" in
		"topleft") params+=( --chroma-sample-position 2 ) ;;
		"left") params+=( --chroma-sample-position 1 ) ;;
		*) params+=( --chroma-sample-position 0 ) ;;
	esac

	(($hdr_opts[(Ie)$map_matrix] || $hdr_opts[(Ie)$map_trans] || $hdr_opts[(Ie)$map_prime])) && {
		params+=( --enable-hdr 1 )
		info="$(mediainfo "${src}")"
		dcp="$(p "${info}" | sed -nE '/Mastering display color/{s/.*: *//p}' || true)"
		max_l="$(p "${info}" | sed -nE '/Mastering display luminance/{s/.*max: ([0-9.]+) cd.*/\1/p}' || true)"
		min_l="$(p "${info}" | sed -nE '/Mastering display luminance/{s/.*min: ([0-9.]+) cd.*/\1/p}' || true)"
		max_cl="$(p "${info}" | sed -nE '/Maximum Content Light Level/{s/.*: *([0-9]+).*/\1/p}' || true)"
		max_fa="$(p "${info}" | sed -nE '/Maximum Frame-Average/{s/.*: *([0-9]+).*/\1/p}' || true)"

		case "${dcp}" in
			"Display P3")
				r_c="0.6800"; r_y="0.3200"
				g_c="0.2650"; g_y="0.6900"
				b_c="0.1500"; b_y="0.0600"
				w_x="0.3127"; w_y="0.3290"
				;;
			"BT.2020")
				r_c="0.7080"; r_y="0.2920"
				g_c="0.1700"; g_y="0.7970"
				b_c="0.1310"; b_y="0.0460"
				w_x="0.3127"; w_y="0.3290"
				;;
			"DCI P3")
				r_c="0.6800"; r_y="0.3200"
				g_c="0.2650"; g_y="0.6900"
				b_c="0.1500"; b_y="0.0600"
				w_x="0.3140"; w_y="0.3510"
				;;
			"BT.2100")
				r_c="0.7080"; r_y="0.2920"
				g_c="0.1700"; g_y="0.7970"
				b_c="0.1310"; b_y="0.0460"
				w_x="0.3127"; w_y="0.3290"
				;;
			"SMPTE ST 2085")
				r_c="0.7347"; r_y="0.2653"
				g_c="0.1596"; g_y="0.8404"
				b_c="0.0366"; b_y="0.0001"
				w_x="0.3127"; w_y="0.3290"
				;;
			"xvYCC")
				r_c="0.6400"; r_y="0.3300"
				g_c="0.3000"; g_y="0.6000"
				b_c="0.1500"; b_y="0.0600"
				w_x="0.3127"; w_y="0.3290"
				;;
			*) true ;;
		esac

		[[ "${dcp}" && "${max_l}" && "${min_l}" && "${max_cl}" && "${max_fa}" ]] &&
			md=G(${g_c},${g_y})B(${b_c},${b_y})R(${r_c},${r_y})WP(${w_x},${w_y})L(${max_l},${min_l})
			cl=${max_cl},${max_fa}
			params+=( --mastering-display ${md} --content-light "${cl}" )
		}

		ffprobe -v quiet -hide_banner -show_streams -show_format -show_entries side_data \
			-count_packets -count_frames -read_intervals "%+#1" \
			"tmp_output.hevc" | grep -Eiq 'dovi|dolby' && {
				[[ "rpu.bin" ]] && params+=( --dolby-vision-rpu *.rpu )
		} || true
		
		mediainfo "${src}" | grep -iq 'SMPTE ST 2094' && {
			[[ -s "hdr10plus.json" ]] && params+=( --hdr10plus-json *.json )
		} || true
}

encav1() {
	ask

	populate

	colors

	params+=(
		--keyint "10s"
		--progress "3"
		--lp "0"
		--pin "1"
	)

	echo "${params[@]}"
	echo ""

	${ff_1[@]} \
		-i "${src}" \
		-pix_fmt "yuv420p10le" \
		-an -dn -sn \
		-metadata title="" \
		-map_metadata -1 \
		-map_chapters -1 \
		-f "yuv4mpegpipe" \
		-strict -1 \
		${ff_2[@]} \
		- | SvtAv1EncApp \
			-i "stdin" \
			${params[@]} \
			-b "av1_${src}.ivf"
}

max_cores() {
	lscpu | sed -n '/^Core(s) per socket:/s/.*\([0-9]\+\)$/\1/p'
}

encode_av1an() {
	command -v mkvmerge > /dev/null 2>&1 && con="mkvmerge" || con="ffmpeg"

	ask

	populate

	colors

	cores="$(max_cores)"
	worker="$(p {1..${cores}} | fz "WORKERS" "Select the desired number of workers")"

	affinity="$(p {1..$(nproc)} | fz "AFFINITY" "Set thread affinity")"

	params+=( --keyint -1 )

	echo "${params[@]}"
	echo ""

	av1an \
		-i "${src}" \
		-o "av1_${src%.*}.mkv" \
		--encoder "svt-av1" \
		--workers "${worker}" \
		--set-thread-affinity "${affinity}" \
		--concat "${con}" \
		--sc-pix-format "yuv420p" \
		--pix-format "yuv420p10le" \
		--resume \
		--video-params "${params[*]} --lp ${affinity}"
}

metric_test() {
	chkpkg "ab-av1" "ssimulacra2_rs"

	ffmpeg -filters 2>&1 | grep -iq 'xpsnr' || p "Compile ffmpeg upstream with XPSNR filter & Change the below path"

	ref="$(p *.{mkv,mp4,m2ts} | fz "REFERENCE" "Select the reference")"
	dis="$(print -rl -- *.{mkv,mp4,m2ts,ivf} | grep -vxF "${ref}" | fz "DISTORTED" "Select the distorted")"

	echo "VMAF: "
	ab-av1 vmaf --reference "${ref}" --distorted "${dis}" --vmaf n_subsample="1" --vmaf n_threads="$(nproc)"

	echo ""

	eval "$(ffprobe -v quiet -y -hide_banner \
		-select_streams v:0 \
		-show_entries stream=color_space,color_transfer,color_primaries \
		-of default=noprint_wrappers=1 "${ref}")" || true

	[[ "${color_space}" ]] && {
		params+=( --src-matrix "${color_space}" --dst-matrix "${color_space}" )
	}

	[[ "${color_transfer}" ]] && {
		params+=( --src-transfer "${color_transfer}" --dst-transfer "${color_transfer}" )
	}

	[[ "${color_primaries}" ]] && {
		params+=( --src-primaries "${color_primaries}" --dst-primaries "${color_primaries}" )
	}

	print -rl "SSIMU2:"
	ssimulacra2_rs video \
		-i "1" \
		-f "$(max_cores)" \
		${params[@]} \
		"${ref}" "${dis}"

	echo ""

	print -rl "XPSNR:"
	"${HOME}/.local/src/FFmpeg/ffmpeg" -hide_banner -loglevel "quiet" -y -nostdin \
		-i "${ref}" -i "${dis}" -lavfi xpsnr=stats_file="xpsnr.log" -f null -

	IFS=" "
	ll=${${(f)"$(<xpsnr.log)"}[-1]}
	set -- ${=ll}
	y_p=$6
	u_p=$8
	v_p=${10}

	weighted_xp="$(( (y_p * 4 + u_p + v_p) / 6 ))"
	
	print -rl "Y XPSNR: ${y_p}"
	print -rl "U XPSNR: ${u_p}"
	print -rl "V XPSNR: ${v_p}"
	print -rl "Weighted XPSNR: ${weighted_xp}"

	echo ""

	print -rl "SSIM & PSNR:"
	ffmpeg -loglevel "info" -y -nostdin -hide_banner \
		-i "${ref}" -i "${dis}" \
		-filter_complex "[0:v][1:v]ssim;[0:v][1:v]psnr" \
		-f null - 2>&1 | grep -oE '(SSIM|PSNR).+'
	
	rm -f *".lwi" "xpsnr.log"
}

extr_dv() {
	chkpkg dovi_tool
	
	src="$(p *.{mkv,mp4,m2ts,hevc} | fz "SOURCES" "Select the source")"
	
	[[ "${src##*.}" == "hevc" ]] && dovi_tool extract-rpu -i "${src}" -o "rpu.bin" || {
		${ff_1[@]} \
			-i "${src}" \
			-c:v copy \
			${ff_2[@]} \
			"tmp_output.hevc"
		dovi_tool extract-rpu -i "tmp_output.hevc" -o "rpu.bin"
	}
}

extr_hdrp() {
	chkpkg hdr10plus_tool
	
	src="$(p *.{mkv,mp4,m2ts,hevc} | fz "SOURCES" "Select the source")"
	
	[[ "${src##*.}" == "hevc" ]] && hdr10plus_tool extract "${src}" -o "hdr10plus.json" || {
		${ff_1[@]} \
			-i "${src}" \
			-c:v copy \
			${ff_2[@]} \
			"tmp_output.hevc"
		hdr10plus_tool extract "tmp_output.hevc" -o "hdr10plus.json"
	}
}

sc="${0##*/}"

h="
FFWRAPPER:
	- Extract & Combine streams according to choices.
	- Automated & Proper stream / metadata mapping.
	- Print PTS table for keyframes.
	- Cut streams easily from keyframes.
	- Supports any number of audio/subrip streams.
	- Supports parsing FFMETADATAFILE for chapters.
		Automated if the file is present.
	- Automatically finds the correct language based on filename.
		This requires \"iso-codes\" package providing the XML file.
	- Supports fixing / reformatting text based chapters file.
	- Fixes various common errors (negative timestamps, corrupted packets, and similar ones).
	- List the streams properly in order to select: ID, type, language, channels, bitrate
	- Encode the selected audio stream with OPUS.
	- Encode the selected video stream with svt-av1-psy directly or through Av1an.
	- Do extensive metric tests (VMAF, SSIMU2, Weighted XPSNR, SSIM, PSNR, possibly more).
	- Handle color related metadata automatically for encoding or metric testing.
	- Extract Dolby Vision RPU or HDR10+ JSON.

USAGE:
	- Does not require any positional input.
	- Just run the script and follow instructions in a directory with files.
	- For combination, name the audio/subrip files with language codes beforehand such as:
		\"eng.opus\", \"eng.srt\", \"deu.opus\"
		The script already, automatically extract, or output in this naming scheme.
	- The script will search for the corresponding ISO code for the language for proper mapping:
		\"eng --> English\", \"deu --> German\"

EXAMPLES:
	${sc} --> Select the source --> Select stream --> Extract
	${sc} --> Select the streams --> Add optional metadata --> Combine
	${sc} --> Select the print option to print PTS table showing keyframes.
	${sc} --> Select two keyframe positions to cut or \"cut & extract\".
	${sc} --> Select \"Encode with *\" to encode the selected stream with the selected encoder.
	${sc} --> Select reference and distorted files to do extensive metric tests.
	${sc} --> Select a video source to extract Dolby Vision or HDR10+ metadata.
"

main() {
	chkpkg "fzf" "sed" "awk" "ffmpeg" "ffprobe"

	[[ -s "/usr/share/xml/iso-codes/iso_639-3.xml" ]] || p "You need to install iso-codes package."

	mod="$(p "Extract Stream" \
		"Combine Streams / Metadata" \
		"Print PTS" \
		"Cut from Keyframes" \
		"Encode with OPUS" \
		"Encode with AV1" \
		"Encode with Av1an" \
		"Run Metric Tests" \
		"Extract Dolby Vision RPU" \
		"Extract HDR10+ JSON" \
		"HELP" | fz "MODE" "Select an option below")"

	case "${mod}" in
		"Extract Stream") extract ;;
		"Combine Streams / Metadata") metform && combine ;;
		"Print PTS") print_pts ;;
		"Cut from Keyframes") fcut ;;
		"Encode with OPUS") encopus ;;
		"Encode with AV1") encav1 ;;
		"Encode with Av1an") encode_av1an ;;
		"Run Metric Tests") metric_test | tee -a "test_results.txt" ;;
		"Extract Dolby Vision RPU") extr_dv ;;
		"Extract HDR10+ JSON") extr_hdrp ;;
		*) p "${h}" ;;
	esac
}

main
