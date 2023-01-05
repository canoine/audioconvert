#!/bin/bash


# Quelques variables
VERSION="0.2a"
FORMAT_SRC="flac"		# Format des fichiers a traiter
FORMAT_DEST="mpc"		# Format des fichiers en fin de traitement

APEBIN="mac"			# Monkey audio
APEDECOPTS="-d"			# Monkey audio (args)
FLACBIN="flac"			# FLAC
FLACDECOPTS="-df"		# FLAC (args)

SPLITBIN="bchunk"
SPLITOPTS="-vw"

MPC7ENCBIN="mppenc" 		# Musepack SV7
MPC8ENCBIN="mpcenc"		# Musepack SV8, pas encore bien supporte...
MPCENCOPTS="--verbose --insane --deleteinput --overwrite"
MP3BIN="lame"				# MP3
MP3ENCOPTS="-V 3 --vbr-new --brief"	# MP3 (args)

ENCSUPPOPTS=""

### Fonctions
##################
function usage () {
	cat <<-EOF
	Usage :
		$O [ -h ] [ -c <options> ] [ -s <format> ] [ -d <format> ] -f fichier

	ou :
		-h affiche cette aide
		-d designe le format des fichiers en fin de traitement	(defaut : MPC)
		-c designe des options supplementaires a passer a l'encodeur
		-f designe le fichier ou le retpertoire a traiter (obligatoire)
		-s designe le format des fichiers a traiter si un repertoire est donne
		   comme argument a -f (defaut : FLAC)

	Formats acceptes :
	- en decompression : WAV, FLAC, APE
	- en compression : MPC, MP3

	Exemples de parametres a passer a l'encodeur :
	MP3/MPC : "--scale 0.8"

	EOF
	exit 1
}

# Determination des formats source et destination
# en fonction des arguments donnes au script
function detect_formats () {
	# Formats destination
	case $FORMAT_DEST in
		MPC8|mpc8|Mpc8|MUSEPACKv8|Musepackv8|musepackv8|MUSEv8|Musev8|musev8)
			echo " *****  Format de sortie : Musepack SV8 (MPC)"
			FORMAT_DEST="mpc8"
			;;
		MPC|mpc|Mpc|MUSE*|Muse*|muse*)
			echo " *****  Format de sortie : Musepack SV7 (MPC)"
			FORMAT_DEST="mpc7"
			;;
		MP3|mp3|Mp3)
			echo " *****  Format de sortie : MP3"
			FORMAT_DEST="mp3"
			;;
		*)
			echo "Format de sortie inconnu. Stop."
			exit 11
			;;
	esac

	# Fichier ou repertoire
	[ "x$FIC_SRC" == "x" ] && usage
	if [ -f "$FIC_SRC" ]
	then
		REP_SRC=`dirname "$FIC_SRC"`
		SPLIT=1

		# Format source
		TYPE=`file "$FIC_SRC" | cut -d: -f2 | awk '{print $1}'`
		case $TYPE in
			"RIFF")
				echo " *****  $FIC_SRC est un fichier WAV."
				FORMAT_SRC="wav"
				;;
			"Monkey's")
				echo " *****  $FIC_SRC est un fichier Monkey Audio (APE)."
				FORMAT_SRC="ape"
				;;
			"FLAC")
				echo " *****  $FIC_SRC est un fichier FLAC."
				FORMAT_SRC="flac"
				;;
			"MPEG")
				echo "$FIC_SRC est un fichier MP3."
				echo "Format d'entree non gere. Stop."
				exit 12
				;;
			"Musepack")
				echo "$FIC_SRC est un fichier Musepack (MPC)."
				echo "Format d'entree non gere. Stop."
				exit 12
				;;
			*)
				echo "$FIC_SRC est un fichier de format inconnu. Stop."
				exit 13
				;;
		esac

	elif [ -d "$FIC_SRC" ]
	then
		echo " *****  $FIC_SRC est un repertoire."
		REP_SRC="$FIC_SRC"
		SPLIT=0

		# Formats source
		case $FORMAT_SRC in
			WAV|Wav|wav)
				echo " *****  Format d'entree : non compresse (WAV)"
				FORMAT_SRC="wav"
				;;
			APE|ape|Ape|Monkey|monkey|MONKEY|MAC|Mac|mac)
				echo " *****  Format d'entree : Monkey Audio (APE)"
				FORMAT_SRC="ape"
				;;
			FLAC|flac|Flac)
				echo " *****  Format d'entree : FLAC"
				FORMAT_SRC="flac"
				;;
			*)
				echo "Format d'entree non gere. Stop."
				exit 13
				;;
		esac

	else
		echo "Le fichier $FIC_SRC n'existe pas. Stop."
		exit 4
	fi

	# Recuperation du chemin absolu du repertoire
	cd "$REP_SRC"
	REP_SRC=`pwd`
}

# Decodage du format d'entree initial
# Format de sortie : WAV
function decode_src () {
	SOURCE="$1"

	FIC_DEC=`echo "$SOURCE" | sed s/\.[a-zA-Z0-9]*$/\.wav/`
	case $FORMAT_SRC in
		wav)	echo " *****  Fichier $SOURCE non compresse."	;;
		flac)	$FLACBIN $FLACDECOPTS "$SOURCE"			;;
		ape)	$APEBIN "$SOURCE" "$FIC_DEC" $APEDECOPTS	;;
	esac

	if [ $? -ne 0 ]
	then
	        echo "$SOURCE : Decompression KO."
	        exit 20
	fi
}

# Decoupage du fichier WAV, s'il contient plusieurs morceaux
# Necessite un fichier CUE
function split_wav () {
	FIC_WAV="$1"
	FIC_WAV_SPLIT=`echo "$FIC_WAV" | sed s/.wav$/_/`

	# Pour trouver le fichier CUE, soit il n'y en a qu'un,
	# soit on prend celui dont le nom est exactement identique au fichier WAV
	# a l'extension pres. Sinon, sortie en erreur.
	if [ `ls -1 "$REP_SRC"/*.cue | wc -l` -eq 1 ]
	then
		FIC_CUE=`ls -1 "$REP_SRC"/*.cue`
	else
		FIC_CUE=`echo "$FIC_WAV" | sed s/.wav$/.cue/`
		if [ ! -f "$FIC_CUE" ]
		then
	       		echo "ERREUR lors de la detection du fichier CUE."
	       		echo "Soit il n'y en a pas, soit il y en a plusieurs, dont aucun avec un nom facilement detectable."
	       		exit 30
		fi
	fi

	echo " *****  Decoupage du fichier selon les informations fournies par $FIC_CUE."
	$SPLITBIN $SPLITOPTS "$FIC_WAV" "$FIC_CUE" "$FIC_WAV_SPLIT"
	mv "$FIC_WAV" "$FIC_WAV.ok"
}

# Encodage du fichier WAV
# Format de sortie selon options donnes au script
function encode_dest () {
	ls "$REP_SRC"/*.wav | while read fic
	do
		case $FORMAT_DEST in
			mpc7)	FIC_ENC=`echo "$fic" | sed s/.wav$/.mpc/`
				$MPC7ENCBIN $MPCENCOPTS $BINENCOPTS $ENCSUPPOPTS "$fic" "$FIC_ENC"	;;
			mpc8)	FIC_ENC=`echo "$fic" | sed s/.wav$/.mpc/`
				$MPC8ENCBIN $MPCENCOPTS $BINENCOPTS $ENCSUPPOPTS "$fic" "$FIC_ENC"	;;
			mp3)	FIC_ENC=`echo "$fic" | sed s/.wav$/.mp3/`
				$MP3BIN $MP3ENCOPTS $ENCSUPPOPTS "$fic" "$FIC_ENC" && rm -vf "$fic"	;;
		esac
		if [ $? -ne 0 ]
		then
	        	echo "$SOURCE : Decompression KO."
	        	exit 40
		fi
	done
}

### Debut du script
##########################
# Traitement des arguments
while getopts s:d:f:c: option
do
	case $option in
		h)	usage		i		;;
		s)	FORMAT_SRC="$OPTARG"		;;
		d)	FORMAT_DEST="$OPTARG"		;;
		c)	ENCSUPPOPTS="$OPTARG"		;;
		f)	FIC_SRC="$OPTARG"		;;
	esac
done
detect_formats

# Decompression
if [ $SPLIT -eq 1 ]
then
	decode_src "$FIC_SRC"
	split_wav "$FIC_DEC"
else
	ls "$REP_SRC"/*.$FORMAT_SRC | while read fic
	do
		decode_src "$fic"
	done
fi

# Arrive ici, quelles que soient les options, on a des fichiers WAV
# separes, un par morceau
# Reste plus qu'a recompresser dans le format voulu
encode_dest

