#!/bin/bash
set -ue -o pipefail

# Quelques variables
VERSION="0.6"

FORMAT_SRC="FLAC"			# Format des fichiers a traiter
FORMAT_DEST="FLAC"			# Format des fichiers en fin de traitement

APEBIN="mac"				# Monkey audio
APEDECOPTS="-d"				# Monkey audio (args)

FLACBIN="flac"				# FLAC
FLACDECOPTS="-df"			# FLAC (args)
FLACENCOPTS="-8f"			# FLAC (args)
FLACTAGBIN="metaflac"			# FLAC

WVBIN="wvunpack"			# WAVPACK
WVDECOPTS="-cc"				# WAVPACK (args)

SPLITBIN="bchunk"
SPLITOPTS="-vw"

CUEPRINT="cueprint"

MPC7ENCBIN="mppenc" 			# Musepack SV7
MPC8ENCBIN="mpcenc"			# Musepack SV8, pas encore bien supporte...
MPCENCOPTS="--verbose --insane --deleteinput --overwrite"

MP3BIN="lame"				# MP3
MP3ENCOPTS="-V 3 --vbr-new --brief"	# MP3 (args)

SPLIT=0
FIC_SRC=""
FIC_CUE=""
FIC_DEC=""
FIC_TAG=""
ENCSUPPOPTS=""

### Fonctions
##################
function usage () {
	cat <<-EOF

	Audioconvert v${VERSION}

	Usage :
		$0 [ -h ] [ -s <format> ] [ -d <format> ] [ -o <options> ] <fichier>

	ou :
		-h affiche cette aide
		-d designe le format des fichiers en fin de traitement	(defaut : FLAC)
		-c designe le nom du fichier CUE (pour decoupe d'un album en morceaux)
		-s designe le format des fichiers a traiter si un repertoire est donne
		   comme argument a -f (defaut : FLAC)
		-o designe des options supplementaires a passer a l'encodeur
		<fichier> designe le fichier ou le repertoire a traiter (obligatoire)

	Formats acceptes :
	- en decompression : WAV, FLAC, APE, WAVPACK
	- en compression : FLAC (defaut), MPC, MP3, WAV (pas de compression)

	Exemples de parametres a passer a l'encodeur :
	MP3/MPC : "--scale 0.8"

	EOF
	exit 1
}

# Determination des formats source et destination
# en fonction des arguments donnes au script
function detect_formats () {
	# Formats source
	# Fichier ou repertoire
	[ -z "${FIC_SRC}" ] && usage
	if [ -f "${FIC_SRC}" ]
	then
		REP_SRC=$(dirname "${FIC_SRC}")
		SPLIT=1

		# Format source
		case $(file "${FIC_SRC}" | cut -d: -f2 | awk '{print $1}') in
			"RIFF")
				echo " *****  ${FIC_SRC} est un fichier WAV."
				FORMAT_SRC="WAV"
				;;
			"Monkey's")
				echo " *****  ${FIC_SRC} est un fichier Monkey Audio (APE)."
				FORMAT_SRC="APE"
				;;
			"FLAC")
				echo " *****  ${FIC_SRC} est un fichier FLAC."
				FORMAT_SRC="FLAC"
				;;
			"MPEG")
				echo "${FIC_SRC} est un fichier MP3."
				echo "Format d'entree non gere. Stop."
				exit 12
				;;
			"Musepack")
				echo "${FIC_SRC} est un fichier Musepack (MPC)."
				echo "Format d'entree non gere. Stop."
				exit 12
				;;
			*)
				EXT=`echo "${FIC_SRC}" | awk -F "." {'print $NF'}`
				if [ "x${EXT^^}" == "xWV" ]
				then
					echo "${FIC_SRC} est un fichier WAVPACK."
					FORMAT_SRC="WV"
				else
					echo "${FIC_SRC} est un fichier de format inconnu. Stop."
					exit 13
				fi
				;;
		esac

	elif [ -d "${FIC_SRC}" ]
	then
		echo " *****  ${FIC_SRC} est un repertoire."
		REP_SRC="${FIC_SRC}"
		SPLIT=0

		# Formats source
		case ${FORMAT_SRC^^} in
			WAV)
				echo " *****  Format d'entree : non compresse (WAV)"
				FORMAT_SRC="WAV"
				;;
			APE|MONKEY|MAC)
				echo " *****  Format d'entree : Monkey Audio (APE)"
				FORMAT_SRC="APE"
				;;
			FLAC)
				echo " *****  Format d'entree : FLAC"
				FORMAT_SRC="FLAC"
				;;
			WAVPACK)
				echo " *****  Format d'entree : WAVPACK"
				FORMAT_SRC="WV"
				;;
			*)
				echo "Format d'entree non gere. Stop."
				exit 13
				;;
		esac

	else
		echo "Le fichier ${FIC_SRC} n'existe pas. Stop."
		exit 4
	fi

	# Recuperation du chemin absolu du repertoire
	cd "${REP_SRC}"
	REP_SRC="$(pwd)"

	# Formats destination
	case ${FORMAT_DEST^^} in
		MPC8|MUSEPACKV8|MUSEV8)
			echo " *****  Format de sortie : Musepack SV8 (MPC)"
			FORMAT_DEST="MPC8"
			;;
		MPC|MUSE*)
			echo " *****  Format de sortie : Musepack SV7 (MPC)"
			FORMAT_DEST="MPC7"
			;;
		MP3)
			echo " *****  Format de sortie : MP3"
			FORMAT_DEST="MP3"
			;;
		FLAC)
			echo " *****  Format de sortie : FLAC"
			FORMAT_DEST="FLAC"
			;;
		WAV)
			echo " *****  Format de sortie : WAV"
			FORMAT_DEST="WAV"
			;;
		*)
			echo "Format de sortie inconnu. Stop."
			exit 11
			;;
	esac

}

# Decodage du format d'entree initial
# Format de sortie : WAV
function decode_src () {
	SOURCE="${REP_SRC}/$(basename "$1")"

	FIC_DEC=$(echo "${SOURCE}" | sed s/\.[a-zA-Z0-9]*$/\.wav/)
	FIC_TAG=$(echo "${SOURCE}" | sed s/\.[a-zA-Z0-9]*$/\.tag/)
	case ${FORMAT_SRC} in
		WAV)
			echo " *****  Fichier ${SOURCE} non compresse."
			;;
		FLAC)
			${FLACBIN} ${FLACDECOPTS} "${SOURCE}"
			${FLACTAGBIN} --export-tags-to="${FIC_TAG}" "${SOURCE}"
			;;
		APE)
			${APEBIN} "${SOURCE}" "${FIC_DEC}" ${APEDECOPTS}
			;;
		WV)
			${WVBIN} ${WVDECOPTS} "${SOURCE}"
			;;
	esac

	[ $? -eq 0 ] && return 0
	echo "$SOURCE : Decompression KO."
	exit 20
}

# Decoupage du fichier WAV, s'il contient plusieurs morceaux
# Necessite un fichier CUE
function split_wav () {
	local FIC_WAV="$1"
	local FIC_WAV_SPLIT=$(echo "${FIC_WAV}" | sed s/.wav$/_/)

	if [ -z "${FIC_CUE}" ]
	then
		# Pour trouver le fichier CUE, soit il n'y en a qu'un,
		# soit on prend celui dont le nom est exactement identique au fichier WAV
		# a l'extension pres. Sinon, sortie en erreur.
		if [ $(ls -1 "${REP_SRC}"/*.cue | wc -l) -eq 1 ]
		then
			FIC_CUE=$(ls -1 "${REP_SRC}"/*.cue)
		else
			for fic in "${REP_SRC}/${FIC_WAV}.cue" "$(echo ${FIC_WAV} | sed s/.wav$/.cue/)"
			do
				[ ! -f "$fic" ] && continue
				FIC_CUE="$fic"
				break
			done
		fi
	else
		# Avec ça, on est sur d'avoir le chemin absolu du fichier
		[ -f "${REP_SRC}"/"${FIC_CUE}" ] && FIC_CUE="${REP_SRC}/${FIC_CUE}"
		[ ! -f "${FIC_CUE}" ] && FIC_CUE=""
	fi

	if [ -z "${FIC_CUE}" ]
	then
       		echo "ERREUR lors de la detection du fichier CUE."
       		echo "Soit il n'y en a pas, soit il y en a plusieurs, dont aucun avec un nom facilement detectable."
       		exit 30
	fi

	echo " *****  Récupération des tags (lorsque c'est possible)."
	local ARTIST=""
	local ALBUM=""
	local DATE=""
	local TRACKTOTAL=""
	local DISCNUMBER=""
	local DISCTOTAL=""

	# On commence par le plus facile : ce qu'on a déjà essayé de récupérer
	if [ -f "${FIC_TAG}" ]
	then
		ARTIST="$(grep ARTIST "${FIC_TAG}" | cut -d '=' -f2 || true)"
		ALBUM="$(grep ALBUM "${FIC_TAG}" | cut -d '=' -f2 || true)"
		DATE="$(grep DATE "${FIC_TAG}" | cut -d '=' -f2 || true)"
		TRACKTOTAL="$(grep TRACKTOTAL "${FIC_TAG}" | cut -d '=' -f2 || true)"
		DISCNUMBER="$(grep DISCNUMBER "${FIC_TAG}" | cut -d '=' -f2 || true)"
		DISCTOTAL="$(grep DISCTOTAL "${FIC_TAG}" | cut -d '=' -f2 || true)"
	fi

	# Et sinon, à partir du fichier .cue
	[ -n "${ARTIST}" ] || ARTIST="$("${CUEPRINT}" --disc-template '%P\n' "${FIC_CUE}")"
	[ -n "${ALBUM}" ] || ALBUM="$("${CUEPRINT}" --disc-template '%T\n' "${FIC_CUE}")"
	[ -n "${DATE}" ] || DATE="$(grep "DATE" "${FIC_CUE}" | head -n 1 | awk '{print $NF}')"
	[ -n "${TRACKTOTAL}" ] || TRACKTOTAL="$("${CUEPRINT}" --disc-template '%N\n' "${FIC_CUE}")"

	echo " *****  Decoupage du fichier selon les informations fournies par ${FIC_CUE}."
	${SPLITBIN} ${SPLITOPTS} "${FIC_WAV}" "${FIC_CUE}" "${FIC_WAV_SPLIT}" \
	 && rm -f "${FIC_WAV}"	\
	 && rm -f "${FIC_TAG}"

	for num in $(seq -w 01 ${TRACKTOTAL})
	do
		[ -f "${FIC_WAV_SPLIT}${num}.wav" ] || continue
		local TITLE="$("${CUEPRINT}" --track-number "${num}" "${FIC_CUE}" \
		       	| grep "^title:" | awk -F ':' '{print $NF}' | sed 's/^[[:space:]]*//g')"
		echo "ARTIST=${ARTIST}" >"${FIC_WAV_SPLIT}${num}.tag"
		echo "ALBUM=${ALBUM}" >>"${FIC_WAV_SPLIT}${num}.tag"
		echo "TITLE=${TITLE}" >>"${FIC_WAV_SPLIT}${num}.tag"
		echo "DATE=${DATE}" >>"${FIC_WAV_SPLIT}${num}.tag"
		echo "TRACKNUMBER=${num}" >>"${FIC_WAV_SPLIT}${num}.tag"
		echo "TRACKTOTAL=${TRACKTOTAL}" >>"${FIC_WAV_SPLIT}${num}.tag"
		if [ -n "${DISCTOTAL}" ] && [ ${DISCTOTAL} -gt 1 ]
		then
			echo "DISCNUMBER=${DISCNUMBER}" >>"${FIC_WAV_SPLIT}${num}.tag"
			echo "DISCTOTAL=${DISCTOTAL}" >>"${FIC_WAV_SPLIT}${num}.tag"
		fi
	done
}

# Détermination d'un nom unique pour un fichier
# (on incrémente un compteur s'il existe déjà, quoi...)
# Argument attendu : <le chemin du fichier>
fic_unique() {
	local FUNIQ="${1}"
	local FN="${FUNIQ%%.*}"
	local FEXT="${FUNIQ##*.}"
	if [ -f "${FUNIQ}" ]
	then
		for num in $(seq 2 10)
		do
			[ ! -f "${FN} ($num).${FEXT}" ] || continue
			echo "${FN} ($num).${FEXT}"
			return 0
		done
	else
		echo "${FUNIQ}"
		return 0
	fi
	return 1
}

# Encodage du fichier WAV
# Format de sortie selon options donnes au script
function encode_dest () {
	local M3U="$(echo "${REP_SRC}" | awk -F '/' '{print $NF}').m3u"
	[ -f "${M3U}" ] && rm -f "${M3U}"
	ls "${REP_SRC}"/*.wav | while read fic
	do
		local FTAG="$(echo "${fic}" | sed s/.wav$/.tag/)"
		local ARTIST=""
		local ALBUM=""
		local TITLE=""
		local DATE=""
		local TRACKNUMBER=""
		local TRACKTOTAL=""
		local DISCNUMBER=""
		local DISCTOTAL=""

		# Nommage du fichier
		local FENC=""
		if [ -f "${FTAG}" ]
		then
			FENC="$(grep "^TITLE" "${FTAG}" | cut -d '=' -f2)"
			TITLE="${FENC}"
			ARTIST="$(grep "^ARTIST" "${FTAG}" | cut -d '=' -f2)"
			ALBUM="$(grep "^ALBUM" "${FTAG}" | cut -d '=' -f2)"
			DATE="$(grep "^DATE" "${FTAG}" | cut -d '=' -f2)"
			TRACKNUMBER="$(grep "^TRACKNUMBER" "${FTAG}" | cut -d '=' -f2)"
			TRACKTOTAL="$(grep "^TRACKTOTAL" "${FTAG}" | cut -d '=' -f2)"
			DISCNUMBER="$(grep "^DISCNUMBER" "${FTAG}" | cut -d '=' -f2 || true)"
			DISCTOTAL="$(grep "^DISCTOTAL" "${FTAG}" | cut -d '=' -f2 || true)"
		else
			FENC="$(echo "${fic}" | sed s/.wav$//)"
		fi

		case "${FORMAT_DEST}" in
			FLAC)
				FENC="$(fic_unique "${REP_SRC}/${FENC}.flac")"
				${FLACBIN} ${FLACENCOPTS} ${ENCSUPPOPTS} --output-name="${FENC}" "${fic}" \
				 && rm -vf "${fic}"
				${FLACTAGBIN} --import-tags-from="${FTAG}" "${FENC}" \
				 && rm -vf "${FTAG}"
				;;
			MPC7)
				FENC="$(fic_unique "${REP_SRC}/${FENC}.mpc")"
				TAGOPTS="	--artist '"${ARTIST}"'			\
						--album "${ALBUM}"				\
						--title '"${TITLE}"'				\
						--year '${DATE}'				\
						--track '${TRACKNUMBER}/${TRACKTOTAL}'	\
					"
				if [ -n "${DISCTOTAL}" ] && [ ${DISCTOTAL} -gt 1 ]
				then
					TAGOPTS="${TAGOPTS} --tag Media='${DISCNUMBER}/${DISCTOTAL}' "
				fi

				${MPC7ENCBIN} ${MPCENCOPTS} ${ENCSUPPOPTS} ${TAGOPTS} "${fic}" "${FENC}" \
				 && rm -vf "${fic}" && rm -vf "${FTAG}"
				;;
			MPC8)
				FENC="$(fic_unique "${REP_SRC}/${FENC}.mpc")"
				TAGOPTS="	--tag Artist=\"${ARTIST}\"			\
						--tag Album=\"${ALBUM}\"			\
						--tag Title=\"${TITLE}\"			\
						--tag Year=\"${DATE}\"				\
						--tag Track=\"${TRACKNUMBER}/${TRACKTOTAL}\"	\
					"
				if [ -n "${DISCTOTAL}" ] && [ ${DISCTOTAL} -gt 1 ]
				then
					TAGOPTS="${TAGOPTS} --tag Media=\"${DISCNUMBER}/${DISCTOTAL}\" "
				fi

				${MPC8ENCBIN} ${MPCENCOPTS} ${ENCSUPPOPTS} ${TAGOPTS} "${fic}" "${FENC}" \
				 && rm -vf "${fic}" && rm -vf "${FTAG}"
				;;
			MP3)
				FENC="$(fic_unique "${REP_SRC}/${FENC}.mp3")"
				${MP3BIN}	${MP3ENCOPTS}	${ENCSUPPOPTS} "$fic" "${FIC_ENC}" \
				 && rm -vf "$fic"
				;;
		esac
		if [ $? -ne 0 ]
		then
	       		echo "${fic} : Encodage KO."
	       		exit 40
		fi
		basename "${FENC}" >>"${REP_SRC}/${M3U}"
	done
}

### Debut du script
##########################
# Traitement des arguments
while getopts c:d:f:o:s: option
do
	case ${option} in
		h)	usage				;;
		s)	FORMAT_SRC="${OPTARG}"		;;
		d)	FORMAT_DEST="${OPTARG}"		;;
		c)	OPT_CUE="${OPTARG}"		;;
		o)	ENCSUPPOPTS="${OPTARG}"		;;
	esac
done
shift $((OPTIND-1))

[ $# -eq 1 ] || usage
FIC_SRC="${1}"
detect_formats

# Decompression
if [ ${SPLIT} -eq 1 ]
then
	decode_src "${FIC_SRC}"
	split_wav "${FIC_DEC}"
else
	ls "${REP_SRC}"/*.${FORMAT_SRC,,} | while read fic
	do
		decode_src "${fic}"
	done
fi

# Arrive ici, quelles que soient les options, on a des fichiers WAV
# separes, un par morceau
# Reste plus qu'a recompresser dans le format voulu
[ "${FORMAT_DEST}" != "WAV" ] && encode_dest
