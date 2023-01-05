#!/bin/bash
set -ue -o pipefail

# Quelques variables
VERSION="0.5"

FORMAT_SRC="FLAC"		# Format des fichiers a traiter
FORMAT_DEST="FLAC"		# Format des fichiers en fin de traitement

APEBIN="mac"			# Monkey audio
APEDECOPTS="-d"			# Monkey audio (args)

FLACBIN="flac"			# FLAC
FLACDECOPTS="-df"		# FLAC (args)
FLACENCOPTS="-8f"		# FLAC (args)

WVBIN="wvunpack"		# WAVPACK
WVDECOPTS=""			# WAVPACK (args)

SPLITBIN="bchunk"
SPLITOPTS="-vw"

MPC7ENCBIN="mppenc" 		# Musepack SV7
MPC8ENCBIN="mpcenc"		# Musepack SV8, pas encore bien supporte...
MPCENCOPTS="--verbose --insane --deleteinput --overwrite"

MP3BIN="lame"				# MP3
MP3ENCOPTS="-V 3 --vbr-new --brief"	# MP3 (args)

FIC_CUE=""
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
	REP_SRC=$(pwd)

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
	case ${FORMAT_SRC} in
		WAV)	echo " *****  Fichier ${SOURCE} non compresse."		;;
		FLAC)	${FLACBIN} ${FLACDECOPTS} "${SOURCE}"			;;
		APE)	${APEBIN} "${SOURCE}" "${FIC_DEC}" ${APEDECOPTS}	;;
		WV)	${WVBIN} ${WVDECOPTS} "${SOURCE}"			;;
	esac

	[ $? -eq 0 ] && return 0
	echo "$SOURCE : Decompression KO."
	exit 20
}

# Decoupage du fichier WAV, s'il contient plusieurs morceaux
# Necessite un fichier CUE
function split_wav () {
	FIC_WAV="$1"
	FIC_WAV_SPLIT=$(echo "${FIC_WAV}" | sed s/.wav$/_/)

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

	echo " *****  Decoupage du fichier selon les informations fournies par ${FIC_CUE}."
	${SPLITBIN} ${SPLITOPTS} "${FIC_WAV}" "${FIC_CUE}" "${FIC_WAV_SPLIT}" \
	 && rm -f "${FIC_WAV}"
	# && mv "${FIC_WAV}" "${FIC_WAV}.ok"
}

# Encodage du fichier WAV
# Format de sortie selon options donnes au script
function encode_dest () {
	ls "${REP_SRC}"/*.wav | while read fic
	do
		case "${FORMAT_DEST}" in
			FLAC)	FIC_ENC=$(echo "$fic" | sed s/.wav$/.flac/)
				${FLACBIN}	${FLACENCOPTS}	${ENCSUPPOPTS} "$fic" "${FIC_ENC}" \
				 && rm -vf "$fic"	;;
			MPC7)	FIC_ENC=$(echo "$fic" | sed s/.wav$/.mpc/)
				${MPC7ENCBIN}	${MPCENCOPTS}	${ENCSUPPOPTS} "$fic" "${FIC_ENC}" \
				 && rm -vf "$fic"	;;
			MPC8)	FIC_ENC=$(echo "$fic" | sed s/.wav$/.mpc/)
				${MPC8ENCBIN}	${MPCENCOPTS}	${ENCSUPPOPTS} "$fic" "${FIC_ENC}" \
				 && rm -vf "$fic"	;;
			MP3)	FIC_ENC=$(echo "$fic" | sed s/.wav$/.mp3/)
				${MP3BIN}	${MP3ENCOPTS}	${ENCSUPPOPTS} "$fic" "${FIC_ENC}" \
				 && rm -vf "$fic"	;;
		esac
		[ $? -eq 0 ] && continue
	       	echo "$fic : Encodage KO."
	       	exit 40
	done
}

### Debut du script
##########################
# Traitement des arguments
while getopts c:d:f:o:s: option
do
	case $option in
		h)	usage				;;
		s)	FORMAT_SRC="$OPTARG"		;;
		d)	FORMAT_DEST="$OPTARG"		;;
		c)	OPT_CUE="$OPTARG"		;;
		o)	ENCSUPPOPTS="$OPTARG"		;;
	esac
done
shift $((OPTIND-1))

[ $# -ne 1 ] && usage
FIC_SRC="$1"
detect_formats

# Decompression
if [ ${SPLIT} -eq 1 ]
then
	decode_src "${FIC_SRC}"
	split_wav "${FIC_DEC}"
else
	ls "${REP_SRC}"/*.${FORMAT_SRC,,} | while read fic
	do
		decode_src "$fic"
	done
fi

# Arrive ici, quelles que soient les options, on a des fichiers WAV
# separes, un par morceau
# Reste plus qu'a recompresser dans le format voulu
[ "${FORMAT_DEST}" != "WAV" ] && encode_dest
