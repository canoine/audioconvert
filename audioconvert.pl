#!/usr/bin/perl
#
# Conversion des fichiers audio de divers formats vers divers formats
#
# Ce script a besoin d'un certain nombre de dépendances
# en fonction des actions demandées :
# - compression, écriture des tags (+ReplayGain) : selon le format (cf. %codecs)
# - décompression : ffmpeg
# - découpage (WAV) : bchunk
# - calcul anti-clipping : metaflac
# - extraction des tags : modules perl selon le format (cf. %codecs)
#
###
#
# Changelog :
# 0.6 :
#	- réécriture complète du script (intialement en shell) en perl
#	- écriture des tags
#	- écriture ou réécriture des playlists M3U
#	- rééchantillonnement des fichiers WAV selon les codecs et
#		le format des fichiers WAV
# 0.7 :
#	- ajout des options -t en ligne de comande
#	- ajout des tags ReplayGain
#	- création et utilisation de tags globaux
#	- détection du clipping et application du niveau de réduction du signal
#	- option forcée ou non de déplacement des fichiers SOURCE et CUE
# 		dans un sous-répertoire ./SRC/
# 0.8 :
#	- remplacement de cueprint, décidément trop capricieux, par une fonction
#	- remplacement de metaflac par une fonction pour l'extraction des tags FLAC
#	- utilisation systématique d'une fonction pour l'extraction des tags
#	- utilisation systématique de ffmpeg pour la décompression
#	- utilisation des formats ffmpeg dans %codecs
#	- réécriture de la détermination du type MIME + %codecs{mime}
#	- réécriture de la détermination du fichier SOURCE forcé
# 	- déduction de TRACKSTOTAL du nombre de fichiers traités si absent
#	- ajout du format ALAC (décompression + tags)
#	- ajout du format Opus (décompression + compression + tags)
#	- ajout du format Vorbis (décompression + compression + tags)
#	- (archive) compression des fichiers sources en FLAC si nécessaire
#	- correction de bugs sur l'option -c
#	- correction de bugs en cas de non-(dé)compression (WAV)
#	- un peu de nettoyage des bouts de code devenus inutiles
#
###
#
# CNE - 20200424
#
###
use strict;
use warnings;
use Audio::FLAC::Header;
use Audio::Musepack;
#~ use Data::Dumper;
use File::Basename;
use File::Copy;
use File::MimeInfo::Magic;
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Which;
use Fcntl;
use Getopt::Long qw(:config no_ignore_case bundling);
use MP4::Info;
use Ogg::Vorbis::Header;

my $prog = basename $0;
my $version = "0.8";

# Options par défaut
my $archive;					# Archivage des fichiers sources dans ./SRC/ ?
my $debug;						# Sortie debug ?
my $dec_opts;					# Options supplémentaires à passer au décodeur
my @decformats;					# Formats de décompression supportés
my @def_tags = (
		"ALBUMARTIST",
		"ARTIST",
		"ALBUM",
		"TITLE",
		"DATE",
		"TRACKNUMBER",
		"TRACKSTOTAL",
		"DISCNUMBER",
		"DISCSTOTAL",
		);						# Liste des tags qui nous intéressent
my $empty;						# Doit-on supprimer le fichier source ?
my $enc_opts;					# Options supplémentaires à passer à l'encodeur
my @encformats;					# Formats de compression supportés
my $fic_cue;					# Nom du fichier CUE
my $fic_src;					# Nom du fichier ou du répertoire SOURCE
my $fic_wav;					# Nom du fichier WAV
my $fmt_arch	= 'flac';		# Format des fichiers archivés (dans ./SRC/)
my $fmt_src		= 'flac';		# Format des fichiers sources
my $fmt_dst		= 'musepack7';	# Format des fichiers destinations
my %gtags;						# Ensemble des tags globaux
my $noclip;						# Doit-on désactiver le calcul anti-clipping ?
my $noreplaygain;				# Doit-on désactiver les tags ReplayGain ?
my $split;						# La source est-elle un fichier à découper ?
my $src_is_rep;					# Le chemin SOURCE est-il un répertoire ?
my $verbose;					# Sortie verbeuse ?
my $volume		= 1;			# Volume des fichiers lossy finaux (anti-clip)
# Et ça, c'est pour alléger le code.
my %fmt_arch;					# Options par défaut du format d'archive
my %fmt_src;					# Options par défaut du format source
my %fmt_dst;					# Options par défaut du format destination

# Formats pris en charge, binaires, et options
# Format du tableau :
#
#	format1 => {
#		dec_tag_sub		=>	\&fonction,			# fonction
#		enc_bin			=>	"exécutable",		# scalaire
#		enc_info_opt	=>	"--silent",			# scalaire
#		enc_opts		=>	"--options",		# chaîne scalaire
#		enc_tags_bin	=>	"exécutable",		# scalaire
#		enc_tags_opts	=>	"--option=",		# chaîne scalaire
#		enc_verb_opt	=>	"--verbose",		# scalaire
#		enc_vol_opt		=>	"--option=",		# chaîne scalaire
#		ext				=>	"extension",		# scalaire
#		mime			=>	"type/MIME",		# scalaire
#		rpg_bin			=>	"exécutable",		# scalaire
#		rpg_opts		=>	""--options",		# chaîne scalaire
#		tags			=>	{					# hash
#			TAG1			=>	'nom',			# scalaire
#			TAG2			=>	'nom',			# scalaire
#			(...)								# liste des tags : @def_tags
#		}
#	},
#
#	format2 => {
#		(...)
#
# Toutes les clefs ne sont pas obligatoires :
# - "dec_tag_sub" est nécessaire pour extraire les tags d'un fichier compressé
#		(mais le script utilise	de préférence les données du fichier CUE
#		lorsque c'est possible, avec -s),
# - "enc_bin" est facultatif, mais il ne sera pas possible d'utiliser
#		ce codec pour compresser des fichiers si absent,
# - "enc_opts", "enc_verb_opt", "enc_vol_opt" et "enc_info_opt"
#		sont facultatifs,
# - "enc_tag_bin" et "enc_tags_opts" sont facultatifs (l'écriture des tags
#		nécessite de toute façon du code spécifique),
# - "ext" est facultatif ("format" sera utilisé comme extension si absent),
# - "mime" est facultatif, mais il ne sera pas possible de décompresser
#		des fichiers de ce format si absent,
# - "rpg_bin" est facultatif, mais il ne sera pas possible d'ajouter des tags
#		ReplayGain sur des fichiers de ce format si absent,
# - "rpg_opts" est facultatif,
# - le sous-tableau "tags" complet est obligatoire :
#		- pour extraire les tags d'un fichier source (mais le script utilise
#			de préférence les données du fichier CUE lorsque c'est possible).
#		- pour écrire les tags d'un fichier destination.
#

my %codecs = (

# Apple (hum...) Lossless Audio Codec
# Libre depuis 2011. Lossless, rapide, mais peu performant.
# En décompression uniquement, parce que, bon, faut pas déconner non plus, hein.
	'alac'	=>	{
		dec_tag_sub		=>	\&extract_MP4_tags,
		ext				=>	"m4a",
		mime			=>	"audio/mp4",
		tags			=>	{
			ARTIST			=>	'ART',
			ALBUM			=>	'ALB',
			ALBUMARTIST		=>	'ART',
			TITLE			=>	'NAM',
			DATE			=>	'DAY',
			TRACKNUMBER		=>	'TRKN',
			TRACKSTOTAL		=>	'/TRKN',
			DISCNUMBER		=>	'DISK',
			DISCSTOTAL		=>	'/DISK'
		}
	},

# Monkey's Audio
# Lossless, mais privateur. Et lent.
# En décompression uniquement.
	'ape'	=>	{
		dec_tag_sub		=>	\&extract_APE_tags,
		mime			=>	"audio/x-ape",
		tags			=>	{
			ARTIST			=>	'ARTIST',
			ALBUM			=>	'ALBUM',
			TITLE			=>	'TITLE',
			DATE			=>	'YEAR',
			TRACKNUMBER		=>	'TRACK',
			TRACKSTOTAL		=>	'/TRACK',
			DISCNUMBER		=>	'DISC',
			DISCSTOTAL		=>	'/DISC'
		}
	},

# Free Lossless Audio Codec
# Libre, rapide, et Lossless.
# Utilisé par défaut pour les fichiers archives (./SRC/)
# Sert à déterminer le niveau de clipping.
	'flac'	=>	{
		dec_tag_sub		=>	\&extract_FLAC_tags,
		enc_bin			=>	"flac",
		enc_info_opt	=>	"--silent",
		enc_opts		=>	"--best --force --output-name",
		enc_tags_opts	=>	"--tag=",
		mime			=>	"audio/flac",
		rpg_bin			=>	"metaflac",
		rpg_opts		=>	"--add-replay-gain",
		tags			=>	{
			ARTIST			=>	'ARTIST',
			ALBUM			=>	'ALBUM',
			ALBUMARTIST		=>	'ALBUMARTIST',
			TITLE			=>	'TITLE',
			DATE			=>	'DATE',
			TRACKNUMBER		=>	'TRACKNUMBER',
			TRACKSTOTAL		=>	'TRACKTOTAL',
			DISCNUMBER		=>	'DISCNUMBER',
			DISCSTOTAL		=>	'DISCTOTAL'
		}
	},

# MPEG-1/2 Audio Layer III
# Le MP3, ben oui. Un peu incontournable.
# Libre (enfin !) depuis 2017, mais méchamment lossy.
	'mp3'	=>	{
		enc_bin			=>	"lame",
		enc_opts		=>	"-V 3",
		enc_tags_opts	=>	"--add-id3v2",
		enc_verb_opt	=>	"--verbose",
		enc_vol_opt		=>	"--scale",
		enc_info_opt	=>	"--brief",
		mime			=>	"audio/mpeg",
		tags			=>	{
			ARTIST			=>	'--ta',
			ALBUM			=>	'--tl',
			ALBUMARTIST		=>	'--tv TPE2',
			TITLE			=>	'--tt',
			DATE			=>	'--ty',
			TRACKNUMBER		=>	'--tn',
			TRACKSTOTAL		=>	'/--tn',
			DISCNUMBER		=>	'--tv TPOS',
			DISCSTOTAL		=>	'/--tv TPOS'
		}
	},

# Musepack SV8
# Libre. Lossy. Plus récent que la version SV7. C'est la version recommandée
# par ses créateurs et celle qui devrait être privilégiée.
# Problème : pas grand chose n'est compatible avec cette version.
# Bugs :
# - ne sait pas compresser des fichiers WAV avec plus de deux canaux
# - ne sait pas compresser des fichiers WAV cadencés à plus de 48 kHz
# - ne sait pas compresser des fichiers WAV avec plus de 16 bits par échantillon
# ffmpeg fait le nécessaire pour que ça ne pose pas de problème.
	'musepack8'	=>	{
		enc_bin			=>	"mpcenc",
		enc_opts		=>	"--insane --overwrite",
		enc_tags_opts	=>	"--tag",
		enc_verb_opt	=>	"--verbose",
		enc_vol_opt		=>	"--scale",
		dec_tag_sub		=>	\&extract_APE_tags,
		ext				=>	"mpc",
		mime			=>	"audio/x-musepack",
		rpg_bin			=>	"mpcgain",
		tags			=>	{
			ARTIST			=>	'ARTIST',
			ALBUM			=>	'ALBUM',
			ALBUMARTIST		=>	'ALBUM ARTIST',
			TITLE			=>	'TITLE',
			DATE			=>	'YEAR',
			TRACKNUMBER		=>	'TRACK',
			TRACKSTOTAL		=>	'/TRACK',
			DISCNUMBER		=>	'DISC',
			DISCSTOTAL		=>	'/DISC'
		}
	},

# Musepack SV7
# Libre. Lossy, mais propre.
# Officiellement obsolète, mais, au moins, la plupart des logiciels compatibles
# savent à peu près le lire...
# Problèmes :
# - la plupart du temps, il faut télécharger les binaires à la main
# - tout est compilé en 32 bits
# - impossible de mettre la main sur les sources
# - replaygain a besoin de bibliothèques esound (!)
# Bugs :
# - ne sait pas compresser des fichiers WAV avec plus de deux canaux
# - ne sait pas compresser des fichiers WAV cadencés à plus de 48 kHz
# - ne sait pas compresser des fichiers WAV avec plus de 16 bits par échantillon
# ffmpeg fait le nécessaire pour que ça ne pose pas de problème.
	'musepack7'	=>	{
		enc_bin			=>	"mppenc",
		enc_opts		=>	"--insane --overwrite",
		enc_tags_opts	=>	"--tag",
		enc_verb_opt	=>	"--verbose",
		enc_vol_opt		=>	"--scale",
		dec_tag_sub		=>	\&extract_APE_tags,
		ext				=>	"mpc",
		mime			=>	"audio/x-musepack",
		rpg_bin			=>	"replaygain",
		rpg_opts			=>	"--auto",
		tags			=>	{
			ARTIST			=>	'ARTIST',
			ALBUM			=>	'ALBUM',
			ALBUMARTIST		=>	'ALBUM ARTIST',
			TITLE			=>	'TITLE',
			DATE			=>	'YEAR',
			TRACKNUMBER		=>	'TRACK',
			TRACKSTOTAL		=>	'/TRACK',
			DISCNUMBER		=>	'DISC',
			DISCSTOTAL		=>	'/DISC'
		}
	},

# Opus Interactive Audio Codec
# Le nouveau Vorbis. Libre, et lossy. Ne permet pas de réduire le volume.
# La compatibilité semble très limitée (inconnu par EasyTAG, par exemple).
	'opus'	=>	{
		dec_tag_sub		=>	\&extract_OGG_tags,
		enc_bin			=>	"opusenc",
		enc_opts		=>	"--bitrate 192",
		enc_tags_opts	=>	"",
		enc_info_opt	=>	"--quiet",
		mime			=>	"audio/x-opus+ogg",
		tags			=>	{
			ARTIST			=>	'--artist',
			ALBUM			=>	'--album',
			ALBUMARTIST		=>	'--comment ALBUMARTIST',
			TITLE			=>	'--title',
			DATE			=>	'--date',
			TRACKNUMBER		=>	'--tracknumber',
			TRACKSTOTAL		=>	'--comment TRACKTOTAL',
			DISCNUMBER		=>	'--comment DISCNUMBER',
			DISCSTOTAL		=>	'--comment DISCTOTAL'
		}
	},

# Vorbis
# _Le_ format ouvert par excellence. Lossy. Ne permet pas de réduire le volume.
	'vorbis'	=>	{
		dec_tag_sub		=>	\&extract_OGG_tags,
		enc_bin			=>	"oggenc",
		enc_opts		=>	"--quality 7",
		enc_tags_opts	=>	"",
		enc_info_opt	=>	"--quiet",
		ext				=>	"ogg",
		mime			=>	"audio/x-vorbis+ogg",
		tags			=>	{
			ARTIST			=>	'--artist',
			ALBUM			=>	'--album',
			ALBUMARTIST		=>	'--comment ALBUMARTIST',
			TITLE			=>	'--title',
			DATE			=>	'--date',
			TRACKNUMBER		=>	'--tracknum',
			TRACKSTOTAL		=>	'--comment TRACKTOTAL',
			DISCNUMBER		=>	'--comment DISCNUMBER',
			DISCSTOTAL		=>	'--comment DISCTOTAL'
		}
	},

# Wavpack
# Libre, mais pas forcément Lossless.
# En décompression uniquement.
	'wavpack'	=>	{
		dec_tag_sub		=>	\&extract_APE_tags,
		ext				=>	"wv",
		mime			=>	"audio/x-wavpack",
		tags			=>	{
			ARTIST			=>	'ARTIST',
			ALBUM			=>	'ALBUM',
			ALBUMARTIST		=>	'ALBUM ARTIST',
			TITLE			=>	'TITLE',
			DATE			=>	'YEAR',
			TRACKNUMBER		=>	'TRACK',
			TRACKSTOTAL		=>	'/TRACK',
			DISCNUMBER		=>	'DISC',
			DISCSTOTAL		=>	'/DISC'
		}
	},

# Waveform Audio File Format
# La base. Libre. Pas de compression. Pas de tags non plus.
# Ajouté ici pour des raisons de facilité.
# Le tag TITLE est utile pour renommer le fichier si -O wav.
	'wav'	=>	{
		enc_bin			=>	"true",
		mime			=>	"audio/x-wav",
		tags			=>	{
			TITLE			=>	'TITLE'
		}
	}
);

# Exécutable pour compresser
my $enc_bin;

# Exécutable et options pour la décompression
my $dec_bin	= "ffmpeg";
my $dec_verb_opt = "-v info";		# verbose, c'est très bavard
my $dec_info_opt = "-v warning";
my $dec_def_opts = "-bitexact -acodec pcm_s16le -ar 44100 -y",

# Exécutable et options pour la découpe des fichiers WAV
my $split_bin = "bchunk";
my $split_opts = "-w";
my $split_verb_opts = "-v";
my $split_info_opts = "";

###
# Fonctions

# Affichage d'un message
# Argument attendu : <le message>
sub msg_info {
	my $message = shift;
	chomp $message;
	print "      INFO : $message\n";
}

# Affichage d'un message (mode debug)
# Arguments attendus : les messages (tableau)
sub msg_debug {
	return unless ( $debug );
	my @message = @_ ;
	foreach my $ligne ( @message ) {
		chomp $ligne;
		print "     DEBUG : $ligne\n";
	}
}

# Affichage d'un message (mode verbeux)
# Arguments attendus : les messages (tableau)
sub msg_verb {
	return unless ( $verbose );
	my @message = @_ ;
	foreach my $ligne ( @message ) {
		chomp $ligne;
		print "   VERBOSE : $ligne\n";
	}
}

# Affichage d'un message d'interpellation
# Argument attendu : <le message>
sub msg_attention {
	my $message = shift;
	chomp $message;
	print " ATTENTION : $message\n";
}

# Affichage d'un message d'erreur
# Argument attendu : <le message>
sub msg_erreur {
	my $message = shift;
	chomp $message;
	print " !! ERREUR : $message\n";
}

# Affichage d'un message d'erreur et sortie en erreur
# Argument attendu : <le message>
sub sortie_erreur {
	my $message = shift;
	chomp $message;
	print "\n"; msg_erreur("$message"); print "\n";
	exit 1;
}

# Lance une commande système, avec affichage ou non.
# Renvoie 1 si la commande sort en erreur, et rien sinon.
# Argument attendu : <la commande>
sub commande_ok {
	my $commande = shift;
	chomp $commande;
	msg_debug("lancement de la commande $commande");
	if ( $debug ) {
		system("set -x && $commande") && return;
	}
	else {
		system("$commande") && return;
	}
	return 1;
}

# Lance une commande système, avec affichage ou non.
# Renvoie la sortie de la commande
# - sous forme scalaire si elle tient sur une ligne
# - sous forme de tableau sinon
# Argument attendu : <la commande>
sub commande_res {
	my $commande = shift;
	chomp $commande;
	$commande .= " 2>&1";
	msg_debug("lancement de la commande $commande");
	my @result = `$commande`;
	@result = `set -x && $commande` if ( $debug );
	return join("\n", @result) if ( scalar(@result) < 2 );
	return @result;
}

# Copie depuis https://perlmaven.com/unique-values-in-an-array-in-perl
sub uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

# Conversion de toutes les clefs d'un hash en MAJUSCULES
# Renvoie le hash modifié
# Argument attendu : <un hash>
sub uc_clefs_hash {
	my %hsrc = @_;
	my %hdst;
	foreach my $clef ( keys %hsrc ) {
		my $uclef = uc($clef);
		$hdst{$uclef} = $hsrc{$clef};
	}
	return %hdst;
}

# Construction de la liste des formats supportés
# Ne renvoie rien
# Arguments attendus : aucun
sub make_formats {
	# Décompression
	my @ffdec = commande_res("'$dec_bin' -codecs");
	foreach my $ligne (@ffdec) {
		chomp $ligne;
		if ( $ligne =~ /^ D.A/ ) { # Dec + Audio
			my $cdc = (split(/ /, $ligne))[2];
			push (@decformats, "$cdc") if ( defined $codecs{$cdc} );
		}
	}
	push (@decformats, "wav");
	# Compression
	foreach my $fmt ( sort(keys %codecs) ) {
		push (@encformats, "$fmt") if ( defined $codecs{$fmt}{enc_bin} );
	}
	return;
}

# Supprime un fichier, ou le renomme si le mode debug est activé
# Argument attendu : <le chemin du fichier>
sub suppr_fic {
	my $chemin = shift;
	if ( -f "$chemin" ) {
		if ( $debug ) {
			msg_debug("renommage du fichier $chemin");
			rename ("$chemin", "$chemin.OK");
		}
		else {
			msg_debug("suppression du fichier $chemin");
			unlink "$chemin";
		}
	}
	else {
		sortie_erreur("le fichier $chemin n'existe pas");
	}
}

# Recherche du chemin d'un binaire et retourne une erreur
# (mais ne sort pas) s'il n'est pas trouvé
# Argument attendu : <le nom du binaire>
sub chem_bin_ou_continue {
	my $binaire = shift;
	chomp $binaire;
	my $chemin = which "$binaire";
	return "$chemin" if ( defined $chemin );
	msg_erreur("le binaire $binaire n'a pas été trouvé. Est-il installé ?");
	return "__inconnu__";
}

# Recherche du chemin d'un binaire et sortie en erreur s'il n'est pas trouvé
# Argument attendu : <le nom du binaire>
sub chem_bin_ou_stop {
	my $binaire = shift;
	chomp $binaire;
	my $chemin = which "$binaire";
	return "$chemin" if ( defined $chemin );
	sortie_erreur("le binaire $binaire n'a pas été trouvé. Est-il installé ?");
}

# Fonction passe-plat. Sert juste à déterminer facilement
# le comportement par défaut si le script ne trouve pas un binaire.
# Argument attendu : <le nom du binaire>
sub chem_bin {
	return my $binaire = chem_bin_ou_stop(shift);
}

# Détermine si le chemin donné en argument est un fichier ou un répertoire
# Renvoie 0 si le chemin est un fichier, 1 si le chemin est un répertoire
# Sort en erreur sinon
# Argument attendu : <le chemin à tester>
sub fic_ou_rep {
	my $chemin = shift;
	if ( -f "$chemin" ) {
		msg_verb("$chemin est un fichier");
		return 0;
	}
	if ( -d "$chemin" ) {
		msg_verb("$chemin est un répertoire");
		return 1;
	}
	sortie_erreur("le chemin $chemin semble ne pas exister");
}

# Renvoie de la liste des fichiers d'un répertoire
# ou le nom du fichier selon le chemin donné
# Argument attendu : <le chemin a parcourir>
sub recup_liste_fics {
	my $rep = shift;
	chomp $rep;
	return "$rep" if ( -f "$rep" );

	my @reps;
	opendir (REP, "$rep/") or sortie_erreur("impossible d'ouvrir $rep");
	foreach my $fichier (readdir(REP)) {
		chomp $fichier;
		push (@reps, "$rep/$fichier") if ( -f "$rep/$fichier" );
	}
	close (REP);
	return (sort(uniq(@reps)));
}

# Renvoie le format probable des fichiers d'un répertoire
# ou du fichier selon le chemin donné
# Argument attendu : <le chemin a parcourir>
sub detect_formats {
	my $chemin = shift;

	# On récupère le format de tous les fichiers, et on part du principe
	# que c'est le format le plus représenté qui nous intéresse.
	# Il y a certainement moyen de faire plus propre...
	my %formats;
	foreach my $fic ( recup_liste_fics("$chemin") ) {
		my $format = fic_format("$fic");
		$formats{$format}++
			unless ( ( "$format" eq "" ) || ( "$format" eq "inconnu" ) );
	}
	# print Dumper %formats;
	my $format = (sort { $formats{$b} cmp $formats{$a} } keys %formats)[0];
	return "inconnu" unless ( defined $format );
	return "$format";
}

# Détermine le format d'un fichier (type MIME)
# Argument attendu : <le chemin du fichier à tester>
sub fic_format {
	my $fichier = shift;
	my $format;
	my $mime_type = mimetype("$fichier");
	msg_debug("format du fichier $fichier : $mime_type");

	# Comme ça, on est sûr de prendre tous les formats supportés
	foreach my $fmt ( keys %codecs ) {
		if ( ( defined $codecs{$fmt}{mime} )
			&& ( $mime_type eq $codecs{$fmt}{mime} ) ) {
			msg_debug(" -MIME- : $fmt");
			return "$fmt";
		}
	}
	return "inconnu";
}

# Interprète le format de fichier donné en argument
# Sort en erreur si inconnu
# Argument attendu : <un format>
sub int_format {
	my $fmt = shift;
	$fmt = lc($fmt);

	# Attention à l'ordre des tests !
	return "$fmt" if ( defined $codecs{$fmt} );
	# Cas particuliers
	return "ape"		if ( $fmt =~ /^monk/ );
	return "musepack8"	if ( $fmt =~ /^mpc(.*)8$/ );
	return "musepack7"	if ( $fmt =~ /^mpc/ );

	# Comme ça, on est sûr de prendre tous les formats supportés
	foreach my $cdc ( keys %codecs ) {
		msg_debug(" -FMT1- : $cdc");
		return "$cdc" if ( $fmt =~ /^$cdc/ );
		msg_debug(" -FMT2- : $cdc");
		return "$cdc" if ( ( defined $codecs{$cdc}{ext} )
			&& ( $fmt =~ /^$codecs{$cdc}{ext}/ ) );
		msg_debug(" -FMT3- : $fmt");
	}
	sortie_erreur("le format indiqué $fmt est inconnu");
}

# Détermination d'un nom unique pour un fichier
# (on incrémente un compteur s'il existe déjà, quoi...)
# Argument attendu : <le chemin du fichier>
sub fic_unique {
	my $fichier = shift;
	if ( -f "$fichier" ) {
		msg_debug("$fichier existe déjà");
		my $fn = $fichier;
		$fn =~ s/\.[^.]+$//;
		my $fx = (split (/\./, $fichier))[-1];

		# Si on arrive à dix fichiers identiques, il faudra se poser
		# des questions...
		for (my $num = 2; $num <= 10; $num++) {
			my $tf = "$fn"." \($num\)"."\.$fx";
			return "$tf" unless ( -f "$tf" );
		}
	}
	else {
		return "$fichier";
	}
	sortie_erreur("impossible de déterminer un nom unique pour $fichier");
}

# Essaie de trouver le fichier .CUE qui va avec le fichier source donné
# Argument attendu : <le chemin du fichier à tester>
sub recup_cue {
	my $fic = shift;

	# On commence par le plus simple :
	# s'il n'y a qu'un fichier, on dira que c'est le bon.
	my $rep = dirname "$fic";
	opendir (REP, "$rep/") or sortie_erreur("impossible d'ouvrir $rep");
	my @cues = map { "$rep/$_" } grep { /.cue$/ } readdir(REP);
	close REP;
	return join("", @cues) if ( @cues == 1 );

	# Sinon, on prend le fichier dont le nom est le plus proche
	# de celui du fichier source
	# Essai 1 : on _remplace_ l'extension
	my $cue = $fic;
	$cue =~ s/\.[^.]+$/\.cue/;
	return "$cue" if ( -f "$cue" );

	# Essai 2 : on _ajoute_ l'extension
	$cue = "$fic.cue";
	return "$cue" if ( -f "$cue" );

	# Sinon, on ne peut plus faire grand-chose...
	msg_attention
		("impossible de trouver un fichier .CUE.".
		" Soit il n'y en a pas, soit il y en a plusieurs,".
		" dont aucun avec un nom facilement detectable");
	return "__nocue__";
}

# Décompression du ou des fichiers sources
# Le but est de sortir avec uniquement des fichiers WAV
# Argument attendu : <le chemin de la source>
sub decompress_src {
	my $chemin = shift;

	my $fwav = $chemin;
	if ( $src_is_rep == 0 ) {
		sortie_erreur("$chemin n'est pas un fichier $fmt_src")
			if ( fic_format("$chemin") ne "$fmt_src" );
		$fwav = decompress_fic("$chemin");
	}
	else {
		# Compteur de pistes, au cas où...
		my %tt = ( TRACKSTOTAL => 0 );
		# On décompresse tous les fichiers qui conviennent
		# mais on ne pourra en retourner qu'un seul...
		foreach my $fic ( recup_liste_fics("$chemin") ) {
			chomp $fic;
			next if ( fic_format("$fic") ne "$fmt_src" );
			decompress_fic("$fic");
			$tt{TRACKSTOTAL}++;
		}
		# Mise à jour des tags globaux
		maj_gtags(%tt);
	}
	return "$fwav";
}

# Décompression d'un (et un seul) fichier source
# Argument attendu : <le chemin du fichier>
sub decompress_fic {
	my $fic_orig = shift;

	# Logique, mais bon...
	return "$fic_orig" if ( "$fmt_src" eq "wav" );
	msg_info("décompression du fichier $fic_orig");

	# Remplacement des caractères interdits
	my $fic_cps = $fic_orig;
	$fic_cps =~ s/\$/S/g;
	rename ( $fic_orig, $fic_cps ) if ( "$fic_orig" ne "$fic_cps" );

	# Pour un éventuel besoin de modifier une playlist,
	# on va transmettre le nom original dans les tags.
	$fic_orig = basename $fic_orig;

	## Construction des commandes à lancer
	my ($ldec_opts, $ltag_bin, $ltag_opts);

	# Décompression
	msg_debug("utilisation du binaire $dec_bin");

	## Options de décompression
	# Niveau de causerie
	if ( $verbose ) {
		$ldec_opts = " $dec_verb_opt";
	}
	else {
		$ldec_opts = " $dec_info_opt";
	}
	# Paramètres donnés par l'utilisateur
	$ldec_opts .= " $dec_opts" if ( defined $dec_opts );

	# Les paramètres par défaut doivent être placés en dernier, car, selon
	# les codecs, le nom du fichier destination doit être ajouté juste après.
	$ldec_opts .= " $dec_def_opts";
	msg_debug("options de la commande : \"$ldec_opts\"");

	# Nom du fichier wav
	my $fwav = $fic_cps;
	$fwav =~ s/\.[^.]+$/\.wav/;
	msg_debug("fichier décompressé : $fwav");

	# Extraction des tags si nécessaire, et si possible
	#~ my (%tags, $fic_tag);
	if ( ( %{$fmt_src{tags}} ) && ( defined $fmt_src{dec_tag_sub} ) ) {
		my $fic_tag = $fic_cps;
		$fic_tag =~ s/\.[^.]+$/\.tag/;
		msg_debug("fichier contenant les tags : $fic_tag");

		msg_debug("extraction des tags");
		$ltag_bin = $fmt_src{dec_tag_sub};
		my %tags = $ltag_bin->("$fic_cps");

		# Mise en forme de la date
		if ( defined $gtags{DATE} ) {
			$tags{DATE} = $gtags{DATE};
		}
		else {
			if ( ( defined $tags{DATE} ) && ( $tags{DATE} =~ /^[0-9]+\-/ ) ) {
				$tags{DATE} = (split (/\-/, $tags{DATE}))[0];
			}
		}

		# Mise en forme des numéros de disques
		if ( ( defined $gtags{DISCNUMBER} )
			&& ( defined $gtags{DISCSTOTAL} ) ) {
			$tags{DISCNUMBER} = $gtags{DISCNUMBER};
			$tags{DISCSTOTAL} = $gtags{DISCSTOTAL};
		}
		else {
			if ( defined $tags{DISCSTOTAL} ) {
				if ( $tags{DISCSTOTAL} > 1 ) {
					$tags{DISCNUMBER} = sprintf ("%02d", $tags{DISCNUMBER})
						if ( defined $tags{DISCNUMBER} );
					$tags{DISCSTOTAL} = sprintf ("%02d", $tags{DISCSTOTAL});
				}
				else {
					undef $tags{DISCSTOTAL};
					undef $tags{DISCNUMBER} if ( defined $tags{DISCNUMBER} );
				}
			}
		}

		# Mise en forme des numéros de morceau
		if ( ( defined $gtags{TRACKNUMBER} )
			&& ( defined $gtags{TRACKSTOTAL} ) ) {
			$tags{DISCNUMBER} = $gtags{TRACKNUMBER};
			$tags{DISCSTOTAL} = $gtags{TRACKSTOTAL};
		}
		else {
			$tags{TRACKSTOTAL} = sprintf ("%02d", $tags{TRACKSTOTAL})
				if ( defined $tags{TRACKSTOTAL} );
			$tags{TRACKNUMBER} = sprintf ("%02d", $tags{TRACKNUMBER})
				if ( defined $tags{TRACKNUMBER} );
		}

		# Mise à jour des tags globaux
		maj_gtags(%tags);

		# Écriture du fichier tag (enfin !)
		open (FTAG, ">$fic_tag")
			or sortie_erreur("impossible d'écrire le fichier $fic_tag");
		foreach my $tag ( keys %tags ) {
			if ( defined $tags{$tag} ) {
				msg_debug(" -FICTAG- $tag=$tags{$tag}");
				print FTAG "$tag=$tags{$tag}\n";
			}
		}
		# Nom original du fichier
		print FTAG "NOM=$fic_orig\n";
		close FTAG;
	}

	# Décompression du fichier
	commande_ok("'$dec_bin' -i \"$fic_cps\" $ldec_opts \"$fwav\"")
		or sortie_erreur("impossible de décompresser le fichier $fic_cps");

	# Archivage du fichier source
	if ( ( ! $split ) && ( $archive ) ) {
		# On ne conerve que des fichiers au format archive déterminé
		# TODO : même pour les formats lossy ???
		if ( "$fmt_src" eq "flac" ) {
			archive_fic("$fic_cps");
		}
		else {
			my $farch = compress_archive("$fwav");
			archive_fic("$farch");
			suppr_fic("$fic_cps") unless ( "$fmt_src" eq "wav" );
		}
	}
	suppr_fic("$fic_cps") if ( $empty );

	return "$fwav";
}

# Extraction des tags MP4 d'un fichier ALAC.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_MP4_tags {
	my $fic = shift;
	my %tags;

	my $mp4Tags = get_mp4tag("$fic")
		or sortie_erreur("impossible de lire les tags de $fic");
	my %mp4Tags = uc_clefs_hash(%$mp4Tags);

	if ( $debug ) {
		foreach my $dt ( keys %mp4Tags ) {
			next if ( $dt =~ /^COVR/);	# image
			msg_debug(" -MP4TAG- $dt=$$mp4Tags{$dt}");
		}
	}

	foreach my $typetag ( keys %{$fmt_src{tags}} ) {
		chomp $typetag;

		# Il faut traiter ces tags à part
		next if ( $typetag eq "DISCSTOTAL" );
		next if ( $typetag eq "TRACKSTOTAL" );

		# Simplification des correspondances
		$tags{$typetag} = $mp4Tags{uc($fmt_src{tags}{$typetag})};

		# Traitement à part
		if ( defined $tags{$typetag} ) {
			if ( $typetag eq "DISCNUMBER" ) {
				($tags{DISCNUMBER}, $tags{DISCSTOTAL}) = @{$tags{$typetag}};
				msg_debug(" -TAG- DISCSTOTAL=$tags{DISCSTOTAL}");
			}
			if ( $typetag eq "TRACKNUMBER" ) {
				($tags{TRACKNUMBER}, $tags{TRACKSTOTAL}) = @{$tags{$typetag}};
				msg_debug(" -TAG- TRACKSTOTAL=$tags{TRACKSTOTAL}");
			}
			msg_debug(" -TAG- $typetag=$tags{$typetag}")
				if ( defined $tags{$typetag} );
		}
	}
	return %tags;
}

# Extraction des tags APE d'un fichier MPC ou APE.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_APE_tags {
	my $fic = shift;
	my %tags;

	my $mpc = Audio::Musepack->new("$fic");
	my $mpcTags = $mpc->tags();
	my %mpcTags = uc_clefs_hash(%$mpcTags);

	if ( $debug ) {
		foreach my $dt ( keys %mpcTags ) {
			next if ( $dt =~ /^COVER /);	# image
			msg_debug(" -APETAG- $dt=$$mpcTags{$dt}");
		}
	}

	foreach my $typetag ( keys %{$fmt_src{tags}} ) {
		chomp $typetag;

		# Il faut traiter ces tags à part
		next if ( $typetag eq "DISCSTOTAL" );
		next if ( $typetag eq "TRACKSTOTAL" );

		# Simplification des correspondances
		$tags{$typetag} = $mpcTags{uc($fmt_src{tags}{$typetag})};

		# Traitement à part
		if ( defined $tags{$typetag} ) {
			if ( $typetag eq "DISCNUMBER" ) {
				if ( $tags{$typetag} =~ /^[0-9]+\/[0-9]+$/ ) {
					($tags{DISCNUMBER}, $tags{DISCSTOTAL}) =
						split (/\//, $tags{DISCNUMBER});
					msg_debug(" -TAG- DISCSTOTAL=$tags{DISCSTOTAL}");
				}
			}
			if ( $typetag eq "TRACKNUMBER" ) {
				if ( $tags{$typetag} =~ /^[0-9]+\/[0-9]+$/ ) {
					($tags{TRACKNUMBER}, $tags{TRACKSTOTAL}) =
						split (/\//, $tags{TRACKNUMBER});
					msg_debug(" -TAG- TRACKSTOTAL=$tags{TRACKSTOTAL}");
				}
			}
			msg_debug(" -TAG- $typetag=$tags{$typetag}");
		}
	}
	return %tags;
}

# Extraction des tags Vorbis d'un fichier FLAC.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_FLAC_tags {
	my $fic = shift;
	my %tags;

	my $flac = Audio::FLAC::Header->new("$fic");
	my $flacTags = $flac->tags();
	my %flacTags = uc_clefs_hash(%$flacTags);

	if ( $debug ) {
		foreach my $dt ( keys %flacTags ) {
			msg_debug(" -FLACTAG- $dt=$flacTags{$dt}");
		}
	}

	foreach my $typetag ( keys %{$fmt_src{tags}} ) {
		chomp $typetag;

		# Simplification des correspondances
		$tags{$typetag} = $flacTags{uc($fmt_src{tags}{$typetag})};

		msg_debug(" -TAG- $typetag=$tags{$typetag}")
			if ( defined $tags{$typetag} );
	}
	return %tags;
}

# Extraction des tags Vorbis d'un fichier OGG.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_OGG_tags {
	my $fic = shift;
	my %tags;

	my $ogg = Ogg::Vorbis::Header->new("$fic");
	my @oggTags = $ogg->comment_tags();
	my %oggTags;

	# Le module oblige à utiliser un tableau de références
	if ( $debug ) {
		foreach my $tag ( @oggTags ) {
			foreach my $dt ($ogg->comment($tag)) {
				msg_debug(" -OGGTAGS- ".uc($tag)."=$dt");
			}
		}
	}

	foreach my $typetag ( keys %{$fmt_src{tags}} ) {
		chomp $typetag;
		foreach my $tag ( @oggTags ) {
			if ( uc($tag) eq $typetag ) {
				$tags{$typetag} = join(" ", $ogg->comment($tag));
				msg_debug(" -TAG- $typetag=$tags{$typetag}");
				next;
			}
		}
	}
	return %tags;
}

# Mise à jour des tags globaux (%gtags) avec les informations fournies
# Ne renvoie rien
# Argument attendu : <un hash de tags>
sub maj_gtags {
	my %tmptags = @_;
	foreach my $gtag (@def_tags) {
		# Ces tags n'ont rien de "global"
		next if ( $gtag eq "TITLE" );
		next if ( $gtag eq "TRACKNUMBER" );
		# Celui-ci est particulier
		if ( $gtag eq "ARTIST" ) {
			next if ( defined $gtags{"ALBUMARTIST"} );
		}
		# Règle générale
		next if ( defined $gtags{$gtag} );
		next if ( ! defined $tmptags{$gtag} );
		# Et si après tout ça, on est encore là,
		# c'est qu'il y a un tag à définir
		$gtags{$gtag} = $tmptags{$gtag};
		$gtags{TRACKSTOTAL} = sprintf ("%02d", $gtags{TRACKSTOTAL})
			if ( $gtag eq "TRACKSTOTAL" );
		$gtags{DISCNUMBER} = sprintf ("%02d", $gtags{DISCNUMBER})
			if ( $gtag eq "DISCNUMBER" );
		$gtags{DISCSTOTAL} = sprintf ("%02d", $gtags{DISCSTOTAL})
			if ( $gtag eq "DISCSTOTAL" );

		msg_debug(" -GLOBALTAG-MAJ- $gtag = $gtags{$gtag}");
	}

	foreach my $afftag ( keys %gtags ) {
		msg_debug(" -GLOBALTAG- $afftag = $gtags{$afftag}");
	}
	return;
}

# Extraction des infos d'un fichier MPC.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_MPC_infos {
	my $fic_mpc = shift;
	my %tags;

	my $mpc = Audio::Musepack->new("$fic_mpc");
	my $mpc_infos = $mpc->info();

	foreach my $dt ( keys %$mpc_infos ) {
		msg_debug(" -MPCINFO- $dt=$$mpc_infos{$dt}");
	}
}

# Récupération des tags d'un album à partir du fichier CUE
# Renvoie toutes les valeurs sous forme de hash :
#	%cuetags => {
#		ALBUM			=>	"album",		# chaîne scalaire
#		ALBUMARTIST		=>	"artistes",		# chaîne scalaire
#		ARTIST			=>	"artistes",		# chaîne scalaire
#		DATE			=>	"année",		# entier en quatre chiffres
#		TRACKSTOTAL		=>	"numéro,		# entier en deux chiffres
#		1				=>	{				# un sous-hash par morceau
#			ARTIST			=>	"artistes",	# chaîne scalaire
#			TITLE			=>	"titre",	# chaîne scalaire
#			TRACKNUMBER		=>	"numéro"	# entier en deux chiffres
#		}
#		2				=>	{				# etc.
#		(...)
#		}
#	},
# Argument attendu : <le chemin du fichier CUE>
sub extract_CUE_infos {
	my $lcue = shift;
	my %cuetags;
	msg_info("récupération des informations du fichier $lcue");

	# On récupère tout de suite le contenu du fichier,
	# comme ça on n'aura plus à y revenir
	open (CUE, "<$lcue")
		or sortie_erreur("impossible de lire le fichier $lcue");
	my @cuetags = <CUE>;
	close CUE;

	# Récupération des informations
	my $numtrack;
	$cuetags{TRACKSTOTAL} = 0;
	foreach my $ligne (@cuetags) {
		chomp $ligne;
		$ligne =~ s/\r//sg;		# format DOS CR-LF ?

		# Champs globaux
		if ( ( $ligne =~ /^REM DATE / ) || ( $ligne =~ /^REM YEAR / ) ) {
			$cuetags{DATE} = (split(/ /, $ligne))[-1];
			$cuetags{DATE} = (split(/-/, $cuetags{DATE}))[0];
			next;
		}
		if ( $ligne =~ /^PERFORMER / ) {
			$cuetags{ALBUMARTIST} = $ligne;
			$cuetags{ALBUMARTIST} =~ s/^PERFORMER //;
			$cuetags{ALBUMARTIST} =~ s/\"//g;
			$cuetags{ARTIST} = $cuetags{ALBUMARTIST};
			next;
		}
		if ( $ligne =~ /^TITLE / ) {
			$cuetags{ALBUM} = $ligne;
			$cuetags{ALBUM} =~ s/^TITLE //;
			$cuetags{ALBUM} =~ s/\"//g;
			next;
		}
		# Champs relatifs aux morceaux
		if ( $ligne =~ /^\s+TRACK / ) {
			$numtrack = $ligne;
			$numtrack =~ s/^\s+TRACK //;
			$numtrack =~ s/\s+.*//;
			$numtrack = sprintf("%02d", $numtrack);
			$cuetags{TRACKSTOTAL}++;
			$cuetags{$numtrack}{TRACKNUMBER} = $numtrack;
			next;
		}
		if ( $ligne =~ /^\s+PERFORMER / ) {
			$cuetags{$numtrack}{ARTIST} = $ligne;
			$cuetags{$numtrack}{ARTIST} =~ s/^\s+PERFORMER //;
			$cuetags{$numtrack}{ARTIST} =~ s/\"//g;
			next;
		}
		if ( $ligne =~ /^\s+TITLE / ) {
			$cuetags{$numtrack}{TITLE} = $ligne;
			$cuetags{$numtrack}{TITLE} =~ s/^\s+TITLE //;
			$cuetags{$numtrack}{TITLE} =~ s/\"//g;
			next;
		}
		# Le reste, on s'en fiche... Non ? :)
	}

	# Quelques vérifications et reformatages
	$cuetags{TRACKSTOTAL} = sprintf("%02d", $cuetags{TRACKSTOTAL});
	msg_attention("le champ DATE est vide") unless ( defined $cuetags{DATE} );

	# DEBUG
	# Affichage des informations en mode debug
	#~ if ( $debug ) {
		#~ foreach my $ligne ( Dumper \%cuetags ) {
			#~ chomp $ligne;
			#~ msg_debug(" -CUETAG- $ligne");
		#~ }
		#~ exit 0;
	#~ }
	# /DEBUG

	# Mise à jour des tags globaux, tant qu'à faire...
	maj_gtags(%cuetags);

	return %cuetags;
}

# Découpage du fichier WAV, s'il contient plusieurs morceaux
# et, tant que faire se peut, transfère les tags extraits.
# Nécessite un fichier CUE
# Argument attendu : <le chemin du fichier>
sub split_wav {
	my $fwav = shift;
	msg_info("découpage du fichier $fwav");

	# Le découpage crée des fichiers numérotés de la forme fichierXX.wav
	# On prépare donc le terrain
	my $base_fic_split = $fwav;
	$base_fic_split =~ s/\.[^.]+$/_/;
	msg_debug("les fichiers seront nommés $base_fic_split"."XX".".wav");

	# Construction de la commande
	if ( $verbose ) {
		$split_opts .= " $split_verb_opts";
	}
	else {
		$split_opts .= " $split_info_opts";
	}
	msg_debug("utilisation du binaire $split_bin");
	msg_debug("options de la commande : \"$split_opts\"");

	# Lancement de la commande
	commande_ok("\"$split_bin\" $split_opts".
		" \"$fwav\" \"$fic_cue\" \"$base_fic_split\"")
		or sortie_erreur("impossible de découper le fichier $fwav");

	# Nom du fichier tag (pour... le supprimer)
	my $fic_tag = $fwav;
	$fic_tag =~ s/\.[^.]+$/\.tag/;
	msg_debug("fichier contenant les tags : $fic_tag") if ( -f "$fic_tag" );

	# Récupération des tags "disque"
	# Note : les tags globaux seront choisis en priorité
	msg_debug("récupération des tags disque");
	my %wav_tags = extract_CUE_infos("$fic_cue");

	# Récupération des tags "morceau"
	for (my $num = 1; $num <= $wav_tags{TRACKSTOTAL}; $num++) {
		my $snum = sprintf("%02d", $num);

		# Nom du fichier
		my $sfic = "$base_fic_split"."$snum";
		msg_debug("traitement du fichier $sfic.wav");

		# On récupère les tags globaux...
		my %ttags = %gtags;

		# Pour le marceau, on n'a pas le choix, il faut faire confiance au CUE
		foreach my $tag ( keys %{$wav_tags{$snum}} ) {
			$ttags{$tag} = $wav_tags{$snum}{$tag};
			chomp $ttags{$tag};
			msg_debug(" -CUETAG- $tag = '$ttags{$tag}'");
		}

		# Écriture du fichier tag
		open (STAG, ">$sfic.tag")
			or sortie_erreur("impossible d'écrire le fichier $sfic.tag");
		foreach my $tag ( keys %ttags ) {
			print STAG "$tag=$ttags{$tag}\n";
		}
		close STAG;
	}

	# DEBUG
	#~ exit 0;
	# /DEBUG

	suppr_fic("$fic_tag") if ( -f "$fic_tag" );
}

# Déplace un fichier dans un répertoire archive ./SRC/
# Ne renvoie rien
# Argument attendu : <le chemin du fichier>
sub archive_fic {
	my $chemin = shift;

	my $rep_src;
	if ( -f $chemin ) {
		$rep_src = dirname $chemin;
	}
	else {
		sortie_erreur("$chemin n'existe pas, ou n'est pas un fichier");
	}
	msg_info("archivage du fichier $chemin dans le sous-répertoire SRC/");
	unless ( $debug ) {
		unless ( -d "$rep_src/SRC" ) {
			make_path("$rep_src/SRC", { mode => 0755 });
		}
		move("$chemin", "$rep_src/SRC/");
	}
	return;
}

# Compresse un fichier WAV au format d'archivage
# Renvoie le chemin du fichier compressé
# Argument attendu : <le chemin du fichier>
sub compress_archive {
	my $chemin = shift;
	sortie_erreur("$chemin n'existe pas, ou n'est pas un fichier")
		unless ( -f $chemin );

	# Compression du fichier WAV en FLAC
	msg_info("compression du fichier $chemin ($fmt_arch)");
	%fmt_arch = %{$codecs{$fmt_arch}};
	my $tmp_fmt = $fmt_dst;
	my %tmp_fmt = %fmt_dst;
	my $tmp_bin = $enc_bin;
	$fmt_dst = $fmt_arch;
	%fmt_dst = %fmt_arch;
	$enc_bin = chem_bin("$fmt_dst{enc_bin}");
	my $fic_cps = compress_fic("$chemin");
	$fmt_dst = $tmp_fmt;
	%fmt_dst = %tmp_fmt;
	$enc_bin = $tmp_bin;

	return "$fic_cps";
}

# Archive les fichiers SOURCE et CUE.
# Recompresse le fichier SOURCE en FLAC si besoin.
# Renomme les fichiers "ARTIST - ALBULM.ext" si les tags globaux existent.
# Arguments attendus : aucun
sub archive_src {
	msg_info("archivage des fichiers source");

	my $arch_src = $fic_src;	# Fichier SOURCE
	my $arch_cue = $fic_cue;	# Fichier CUE

	# On doit déjà avoir tout ça, mais bon...
	# Répertoire
	my $rep_src = $fic_src;
	$rep_src = dirname $fic_src if ( -f $fic_src );
	my $bn_fic_src = basename $fic_src;
	# Extension
	%fmt_arch = %{$codecs{$fmt_arch}};
	my $fext = $fmt_arch;
	$fext = $fmt_arch{ext} if ( defined $fmt_arch{ext} );

	# Est-ce qu'on peut renommer les fichiers ?
	if ( ( defined $gtags{ALBUMARTIST} ) && ( defined $gtags{ALBUM} ) ) {
		my $nsrc = "$gtags{ALBUMARTIST} - $gtags{ALBUM}";
		$nsrc =~ s/\//-/g;

		# On ajoute le numéro de disque si nécessaire
		if ( ( defined $gtags{DISCNUMBER} )
			&& ( defined $gtags{DISCSTOTAL} )
			&& ( $gtags{DISCSTOTAL} > 1 ) ) {
			$nsrc .= " CD$gtags{DISCNUMBER}";
		}
		$arch_src = "$rep_src/$nsrc.$fext";
		$arch_cue = "$rep_src/$nsrc.cue";
		rename("$fic_cue", "$arch_cue")
			if ( ( $fic_cue ) && ( -f $fic_cue ) && ( $fic_cue ne $arch_cue ) );
	}

	# Faut-il recompresser la source ?
	if ( $fmt_arch eq $fmt_src ) {
		rename("$fic_src", "$arch_src") unless ( $fic_src eq $arch_src );
	}
	else {
		# Compression du fichier WAV en FLAC
		my $fic_cps = compress_archive("$fic_wav");
		# Premier renommage du fichier
		rename("$fic_cps", "$arch_src") unless ( $fic_cps eq $arch_src );
		# On n'aura plus besoin de ça
		suppr_fic("$fic_src") if ( -f $fic_src );
	}
	# On n'aura plus besoin de ça
	suppr_fic("$fic_wav") if ( ( -f $fic_wav ) && ( $fmt_src ne "wav" ) );

	# Dans tous les cas, ou presque, il faut retoucher le fichier CUE
	if ( ( $arch_cue ) && ( -f $arch_cue ) ) {
		if ( $fic_src ne $arch_src ) {
			my $bsrc = basename $arch_src;
			# Lecture...
			open (CUE, "<$arch_cue")
				or sortie_erreur("impossible de lire le fichier $arch_cue");
			my @cuetags = <CUE>;
			close CUE;
			# Et réécriture
			open (CUE, ">$arch_cue")
				or sortie_erreur("impossible de réécrire le fichier $arch_cue");
			foreach my $ligne (@cuetags) {
				chomp $ligne;
				$ligne = "FILE \"$bsrc\" WAVE" if ( $ligne =~ /^FILE / );
				print CUE "$ligne\n";
			}
			close CUE;
		}
		archive_fic("$arch_cue");
	}
	archive_fic("$arch_src") if ( $split );
	return;
}

# Concatène les fichiers M3U CDXX dans un fichier ALBUM.m3u
# Ne renvoie rien
# Argument attendu : <le chemin de la source>
sub concat_m3u {
	my $chemin = shift;

	# L'utilisation de la fonction recup_m3u est problématique,
	# car elle va ignorer le contenu du répertoire dans certains cas
	my @fics_de_rep = recup_liste_fics("$chemin");
	my @fics_m3u_cd = sort(grep(/\/CD[0-9]+.m3u$/, @fics_de_rep));
	return if ( scalar @fics_m3u_cd <= 1 );
	msg_info("création d'une playlist globale pour l'album");

	# Nom du fichier cible
	my $fic_m3u_album = "$chemin/aa_global.m3u";
	$fic_m3u_album = "$chemin/$gtags{ALBUM}.m3u" if ( defined $gtags{ALBUM} );
	open(M3UG, ">$fic_m3u_album")
		or sortie_erreur("impossible d'écrire le fichier $fic_m3u_album");

	# Écriture
	foreach my $fic (@fics_m3u_cd) {
		open(M3UD, "<$fic")
			or sortie_erreur("impossible de lire le fichier $fic");
		print M3UG (<M3UD>);
		close M3UD;
	}
	close M3UG;
	return;
}

# Détermine le nom des fichiers M3U à utiliser si besoin
# et renvoie la liste sous forme de tableau
# Argument attendu : <le chemin de la source>
sub recup_m3u {
	my $chemin = shift;
	my $rep = $chemin;
	$rep = dirname $chemin if ( -f "$chemin" );

	# Si le fichier SOURCE doit être découpé, il faudra de toute façon
	# créer un fichier M3U tout neuf
	if ( ( ! $split ) && ( $src_is_rep == 1 ) ) {
		# Y a-t-il des fichiers M3U dans le répertoire ?
		my @fics_de_rep = recup_liste_fics("$rep");
		my @fics_m3u = grep (/\.m3u$/, @fics_de_rep);
		my $nb_m3u = scalar @fics_m3u;
		msg_debug("nombre de fichiers m3u dans $rep : $nb_m3u");

		# Oui ? Pas la peine d'aller plus loin. :)
		if ( scalar @fics_m3u > 0 ) {
			msg_debug("nom des fichiers m3u : ".join(', ', @fics_m3u));

			# On en profite pour faire une copie archive si nécessaire
			make_path("$rep/SRC", { mode => 0755 }) unless ( -d "$rep/SRC" );
			if ( $archive ) {
				foreach my $fic (@fics_m3u) {
					msg_info("archivage de $fic dans le sous-répertoire SRC/");
					copy("$fic", "$rep/SRC/");
				}
			}
			return @fics_m3u;
		}
	}

	# Sinon, il va falloir décider
	# Essai 1 : les global tags
	# Si plusieurs disques, M3U = CD$num
	if ( ( defined $gtags{DISCNUMBER} )
		&& ( defined $gtags{DISCSTOTAL} )
		&& ( $gtags{DISCSTOTAL} > 1 ) ) {
		return "$rep/CD$gtags{DISCNUMBER}.m3u";
	}
	# Sinon, M3U = ALBUM
	if ( defined $gtags{ALBUM} ) {
		# Caractères interdits
		my $nm3u = $gtags{ALBUM};
		$nm3u =~ s/\//-/g;
		return "$rep/$nm3u.m3u";
	}

	# Essai 2 : à partir du nom du fichier SOURCE
	my $fic_m3u = (split (/\//, $chemin))[-1];
	if ( -d "$chemin" ) {
		$fic_m3u .= ".m3u";
	}
	else {
		$fic_m3u =~ s/\.[^.]+$/\.m3u/;
	}
	msg_debug("nom du fichier m3u : $fic_m3u");
	return "$fic_m3u";
}

# Ajoute les tags ReplayGain sur les fichiers compatibles
# Ne renvoie rien
# Argument attendu : <le chemin du répertoire source>
sub ajout_RGtags {
	my $chemin = shift;

	# Pas de commande dédiée ? Pas la peine d'aller plus loin...
	return unless ( defined $fmt_dst{rpg_bin} );

	msg_info("ajout des tags ReplayGain");

	# Visiblement, le calcul se fait au niveau du répertoire
	sortie_erreur("$chemin n'est pas un répertoire") unless ( -d "$chemin" );

	# Extension des fichiers compressés
	my $fext = $fmt_dst;
	$fext = $fmt_dst{ext} if ( defined $fmt_dst{ext} );

	# Commandes
	my $rpg_bin = $fmt_dst{rpg_bin};
	msg_debug("utilisation du binaire $rpg_bin");

	my $rpg_opts = " ";
	$rpg_opts = $fmt_dst{rpg_opts} if ( defined $fmt_dst{rpg_opts} );
	msg_debug("options de la commande : \"$rpg_opts\"");

	# Les actions à entreprendre pour la conservation des tags
	# vont-elles dépendre du format ?

	# Ajout des tags
	commande_ok("'$rpg_bin' $rpg_opts \"$chemin\"/*.$fext")
		or sortie_erreur("impossible de tagger les fichiers de $chemin");

	# DEBUG
	# Vérification
	#~ opendir(REP, "$chemin")
		#~ or sortie_erreur("impossible de lister les fichiers de $chemin");

	#~ foreach my $fic (readdir(REP)) {
		#~ next if ( fic_format("$chemin/$fic") ne "$fmt_src" );
		#~ msg_debug("-RG- $chemin/$fic");
		#~ commande_ok
			#~ ("'$rpg_bin' --show-tag=REPLAYGAIN_TRACK_GAIN \"$chemin/$fic\"");
		#~ commande_ok
			#~ ("'$rpg_bin' --show-tag=REPLAYGAIN_ALBUM_GAIN \"$chemin/$fic\"");
		#~ msg_debug("-RG-");
	#~ }
	# /DEBUG

	return;
}

# Compresse une série de fichiers WAV en FLAC rapide
# et calcule le niveau de clipping via les tags RaplayGain.
# Renvoie une valeur comprise entre 0 et 1
# Arguments attendus : @les fichiers
sub calcul_clip {
	my @fics_wav = @_;
	my @fics_cps;

	msg_info("calcul du niveau de guerre du volume");
	my ($again, $tgain);
	my $apeak = 0;
	my $tpeak = 0;
	my $tmp_cpt = 0;

	# On ne va pas s'embarrasser avec les options compliquées. Le but, ici,
	# c'est d'aller le plus vite possible.
	my $tmp_fmt_dst = "flac";
	my %tmp_fmt_dst = %{$codecs{$tmp_fmt_dst}};
	my $tmp_ext = "tmp.flac";
	my $tmp_enc_bin = chem_bin("$tmp_fmt_dst{enc_bin}");
	my $tmp_enc_opt = "--fast --force --output-name";
	my $tmp_rpg_bin = chem_bin("$tmp_fmt_dst{rpg_bin}");
	my $tmp_rpg_opt	= "$tmp_fmt_dst{rpg_opts}";

	msg_verb("compression rapide en $tmp_fmt_dst");
	foreach my $fwav ( @fics_wav ) {
		$tmp_cpt++;
		msg_debug("traitement du fichier $fwav");
		my $fic_cps = "$fwav.$tmp_ext";
		# Compression du fichier
		commande_ok("'$tmp_enc_bin' $tmp_enc_opt \"$fic_cps\" \"$fwav\"")
			or sortie_erreur("impossible de compresser le fichier $fwav");
		push(@fics_cps, "$fic_cps");
	}

	# Ajout des tags
	msg_verb("calcul du niveau de réduction du volume");
	my $fichiers;
	foreach my $fic_cps (@fics_cps) {
		$fichiers .= " \"$fic_cps\"";
	}
	commande_ok("'$tmp_rpg_bin' $tmp_rpg_opt $fichiers")
		or sortie_erreur("impossible de tagger les fichiers");

	# Récupération des tags
	# Comme perl s'accomode mal des nombres avec plein de décimales (peak),
	# on va faire quelques multiplications
	foreach my $fic_cps (@fics_cps) {
		# Album peak et album gain. Comme ils sont identiques pour tout
		# un album, inutile de les recalculer à chaque fois
		if ( ! defined $apeak ) {
			my $ap = commande_res
			  ("'$tmp_rpg_bin' --show-tag=REPLAYGAIN_ALBUM_PEAK \"$fic_cps\"");
			$ap = (split(/=/, $ap))[1] * 1000000;
			$apeak = 1 if ( $ap >= 999956.000 );
		}
		if ( ! defined $again ) {
			my $ag = commande_res
			  ("'$tmp_rpg_bin' --show-tag=REPLAYGAIN_ALBUM_GAIN \"$fic_cps\"");
			$ag = (split(/=/, $ag))[1];
			$ag =~ s/ dB$//;
			$again = abs($ag);
		}
		# Track peak et track gain
		my $tp = commande_res
			("'$tmp_rpg_bin' --show-tag=REPLAYGAIN_TRACK_PEAK \"$fic_cps\"");
		my $tg = commande_res
			("'$tmp_rpg_bin' --show-tag=REPLAYGAIN_TRACK_GAIN \"$fic_cps\"");
		$tp = (split(/=/, $tp))[1] * 1000000;
		$tg = (split(/=/, $tg))[1];
		$tg =~ s/ dB$//;

		msg_debug("-RG- track gain : $tg");
		msg_debug("-RG- track peak : $tp");

		# Valeurs track max
		$tpeak++ if ( $tp >= 999956.000 );

		if ( defined $tgain ) {
			$tgain = abs($tg) if ( abs($tg) > $tgain );
		}
		else {
			$tgain = abs($tg);
		}
		# Un peu de ménage...
		suppr_fic("$fic_cps");
	}
	msg_debug("-RG- album gain : $again");
	msg_debug("-RG- album peak : $apeak");
	msg_debug("-RG- track gain max : $tgain");
	msg_debug("-RG- track peak max : $tpeak");

	# Cas 1 : pas de clipping du tout ?
	# Certains codecs/utilisateurs trichent en écrétant le signal...
	#~ return "1" if ( ( $apeak == 0 ) && ( $tpeak == 0 ) );

	# Cas 2 : il faut réduire le volume. De combien ?
	return "0.8"	if ( $tgain > 10 );
	return "0.85"	if ( $tgain >  8 );
	return "0.90"	if ( $tgain >  6 );
	return "0.95"	if ( $tgain >  4 );
	return "1";
}

# Compression du ou des fichiers WAV trouvés
# Argument attendu : <le chemin de la source>
sub compress_dest {
	my $chemin = shift;

	# Fichiers playlists
	# Note : %playlists est un hash de tableaux
	my @fics_m3u = recup_m3u("$chemin");
	my ($is_playlist, %playlists);

	# On récupère les playlists, si elles existent déjà
	foreach my $liste (@fics_m3u) {
		if ( ( $src_is_rep == 1 ) && ( -f "$liste" ) ) {
			msg_debug("la playlist $liste existe");
			$is_playlist = 1;
			open (M3U, "<$liste")
				or sortie_erreur("impossible d'écrire le fichier $liste");
			foreach my $ligne (<M3U>) {
				chomp $ligne;
				$ligne =~ s/\r//;
				push(@{$playlists{$liste}}, "$ligne");
			}
			close M3U;
		}
		else {
			@{$playlists{$liste}} = ();
		}
	}

	# On récupère la liste des fichiers WAV
	my @fics_wav;
	foreach my $fic ( recup_liste_fics("$chemin") ) {
		chomp $fic;
		next if ( $fic =~ /\.OK$/ );		# Résidus de debugs
		next if ( ( $split ) && ( "$fic" eq "$fic_wav" ) );	# Si $fmt_dst = WAV
		next if ( fic_format("$fic") ne "wav" );
		push (@fics_wav, $fic);
	}

	# Récupération du niveau de réduction à appliquer aux fichiers lossy
	if ( ( defined $fmt_dst{enc_vol_opt} ) && ( ! $noclip ) ) {
		$volume = calcul_clip(@fics_wav);
		msg_info("niveau de réduction calculé : $volume");
	}

	# On compresse tous les fichiers qui conviennent
	foreach my $fic ( @fics_wav ) {
		msg_debug("traitement du fichier $fic");

		# Fichier tag
		my $fic_tag = $fic;
		$fic_tag =~ s/\.[^.]+$/\.tag/;

		# On récupère le nom original du fichier,
		# pour modifier les playlists existantes
		my $fic_orig = "__no_orig__";
		if ( $is_playlist ) {
			if ( -f "$fic_tag" ) {
				open (FTAG, "<$fic_tag")
					or sortie_erreur("impossible de lire le fichier $fic_tag");
				$fic_orig = (split(/=/, (grep(/^NOM=/, <FTAG>))[0]))[-1];
				close FTAG;
				chomp $fic_orig ;
				msg_debug("nom original du fichier $fic : $fic_orig");
			}
			else {
				msg_attention
					("le fichier $fic_tag est introuvable.".
					" Les tags du fichier $fic ne seront pas modifiés.");
			}
		}

		# Compression du fichier
		my $fic_cps = compress_fic("$fic");
		suppr_fic("$fic") if ( ( -f $fic ) && ( $fmt_dst ne "wav" ) );;
		suppr_fic("$fic_tag") if ( -f "$fic_tag" );

		# Modification des playlists
		msg_debug("modification des playlists");
		my $bfic_cps = basename "$fic_cps";
		chomp $bfic_cps;

		foreach my $liste (keys %playlists) {
			msg_debug("playlist $liste");
			if ( ( $src_is_rep == 1 ) && ( $is_playlist ) ) {
				last if ( "$fic_orig" eq "__no_orig__" ); # ou pas
				msg_verb
					("remplacement de $fic_orig par $bfic_cps".
					" dans la playlist $liste");
				foreach my $entree (@{$playlists{$liste}}) {
					chomp $entree;
					if ( $entree =~ /\Q$fic_orig\E$/ ) {
						$entree =~ s/\Q$fic_orig\E$/$bfic_cps/g;
					}
				}
			}
			else {
				msg_verb("ajout du fichier $bfic_cps dans la playlist $liste");
				push(@{$playlists{$liste}}, "$bfic_cps");
			}
		}
	}

	# Écriture des fichiers m3u
	foreach my $fic_m3u (keys %playlists) {
		open (M3U, ">$fic_m3u")
			or sortie_erreur("impossible d'écrire le fichier $fic_m3u");
		msg_info("écriture de la playlist $fic_m3u");
		foreach my $ligne (@{$playlists{$fic_m3u}}) {
			chomp $ligne;
			print M3U "$ligne\n";
		}
		close M3U;
	}
}

# Compression d'un (et un seul) fichier source
# Argument attendu : <le chemin du fichier>
sub compress_fic {
	my $fwav = shift;

	# Logique, mais bon...
	msg_info("compression du fichier $fwav") unless ( "$fmt_dst" eq "wav" );

	# Nom du fichier tag
	my $fic_tag = $fwav;
	$fic_tag =~ s/\.[^.]+$/\.tag/;

	# Récupération des tags
	# Priorité aux tags globaux. Toujours.
	my %tags = %gtags;
	if ( ( %{$fmt_dst{tags}} ) && ( -f "$fic_tag" ) ) {
		msg_debug("fichier contenant les tags : $fic_tag");
		open (FTAG, "<$fic_tag")
			or sortie_erreur("impossible de lire le fichier $fic_tag");
		my @ftags = <FTAG>;
		close FTAG;

		foreach my $typetag	( keys %{$fmt_dst{tags}} ) {
			if ( defined $tags{$typetag} ) {
				msg_debug(" -GTAG- $typetag=$tags{$typetag}");
				next;
			}
			foreach my $ligne (@ftags) {
				chomp $ligne;
				if ( $ligne =~ /^$typetag=/ ) {
					$tags{$typetag}=(split (/\=/, $ligne))[1];
					# Il y a quelques caractères qui passent mal en argument
					$tags{$typetag} =~ s/\$/\\\$/g;
					msg_debug(" -FICTAG- $typetag=$tags{$typetag}");
				};
			}
		}
	}

	# Extension du fichier compressé
	my $fext = $fmt_dst;
	$fext = $fmt_dst{ext} if ( defined $fmt_dst{ext} );

	my ($lenc_opts, $ltag_bin, $ltag_opts);

	# Nom du fichier compressé
	my $rep_cps = dirname "$fwav";
	my $fic_cps = $fwav;
	# Si on a accès aux tags, le nom sera le titre. Parce que voilà.
	if ( defined $tags{TITLE} ) {
		my $tmp_fic = "$tags{TITLE}"."\.$fext";
		# Il y a quelques caractères interdits.
		# Attention, l'ordre des tests est important.
		$tmp_fic =~ s/\\\$/S/g;
		$tmp_fic =~ s/\\/-/g;
		$tmp_fic =~ s/\//-/g;
		$fic_cps = fic_unique("$rep_cps/$tmp_fic");
	}
	# Sinon, le nom est déterminé à partir de celui du fichier WAV.
	elsif ( "$fmt_dst" ne "wav" ) {
		$fic_cps = $fwav;
		$fic_cps =~ s/\.[^.]+$/\.$fext/;
	}

	# Cas des sorties en WAV :
	# on a le nom définitif du fichier, ça suffit. Le reste est inutile.
	if ( "$fmt_dst" eq "wav" ) {
		unless ( "$fwav" eq "$fic_cps" ) {
			msg_info("renommage du fichier $fwav en $fic_cps");
			rename ("$fwav", "$fic_cps")
				or sortie_erreur("impossible de renommer $fwav");
		}
		return ("$fic_cps");
	}

	## Options de compression
	msg_debug("utilisation du binaire $enc_bin");


	# Niveau de causerie
	if ( $verbose ) {
		$lenc_opts = "$fmt_dst{enc_verb_opt}"
			if ( defined $fmt_dst{enc_verb_opt} );
	}
	else {
		$lenc_opts = "$fmt_dst{enc_info_opt}"
			if ( defined $fmt_dst{enc_info_opt} );
	}
	# Paramètres donnés par l'utilisateur
	$lenc_opts .= " $enc_opts" if ( defined $enc_opts );

	# Niveau de réduction du volume
	$lenc_opts .= " $fmt_dst{enc_vol_opt} $volume"
		if ( ( defined $fmt_dst{enc_vol_opt} ) && ( $volume ne 1 ) );

	# Les paramètres par défaut doivent être placés en dernier, car, selon
	# les codecs, le nom du fichier destination doit être ajouté juste après.
	$lenc_opts .= " $fmt_dst{enc_opts}"	if ( defined $fmt_dst{enc_opts} );
	msg_debug("options de la commande : $lenc_opts");

	## Certaines actions dépendent du format
	# FLAC
	if ( "$fmt_dst" eq "flac" ) {
		$lenc_opts .= " \"$fic_cps\"";

		# Mise en forme des tags
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					"\"$fmt_dst{tags}{$tag}\"=\"$tags{$tag}\""
					if ( defined $tags{$tag} );
			}
		}

		# Compression du fichier
		commande_ok("'$enc_bin' $lenc_opts \"$fwav\"")
			or sortie_erreur("impossible de compresser le fichier $fwav");
	}

	# MPC
	elsif ( "$fmt_dst" =~ /^musepack/ ) {
		# Mise en forme des tags
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				next if ( $tag eq "TRACKNUMBER" );
				next if ( $tag eq "TRACKSTOTAL" );
				next if ( $tag eq "DISCNUMBER" );
				next if ( $tag eq "DISCSTOTAL" );
				$lenc_opts .= " $fmt_dst{enc_tags_opts} ".
					"\"$fmt_dst{tags}{$tag}\"=\"$tags{$tag}\"";
			}
		}
		# Numéros de morceaux
		if ( defined $tags{TRACKNUMBER} ) {
			$tags{TRACKNUMBER} = "$tags{TRACKNUMBER}/$tags{TRACKSTOTAL}"
				if ( defined $tags{TRACKSTOTAL} );
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" $fmt_dst{tags}{TRACKNUMBER}=\"$tags{TRACKNUMBER}\"";
		}
		# Numéros de disques
		if ( defined $tags{DISCNUMBER} ) {
			$tags{DISCNUMBER} = "$tags{DISCNUMBER}/$tags{DISCSTOTAL}"
				if ( defined $tags{DISCSTOTAL} );
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" $fmt_dst{tags}{DISCNUMBER}=\"$tags{DISCNUMBER}\"";
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" Part=\"$tags{DISCNUMBER}\"";
		}

		# Compression du fichier
		commande_ok("'$enc_bin' $lenc_opts \"$fwav\" \"$fic_cps\"")
			or sortie_erreur("impossible de compresser le fichier $fwav");
	}

	# MP3
	elsif ( "$fmt_dst" eq "mp3" ) {

		# Mise en forme des tags
		$lenc_opts .= " $fmt_dst{enc_tags_opts}";
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				next if ( $tag eq "TRACKNUMBER" );
				next if ( $tag eq "TRACKSTOTAL" );
				next if ( $tag eq "DISCNUMBER" );
				next if ( $tag eq "DISCSTOTAL" );
				$lenc_opts .= " $fmt_dst{tags}{$tag} \"$tags{$tag}\"";
			}
		}
		# Numéros de morceaux
		if ( defined $tags{TRACKNUMBER} ) {
			$tags{TRACKNUMBER} = "$tags{TRACKNUMBER}/$tags{TRACKSTOTAL}"
				if ( defined $tags{TRACKSTOTAL} );
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" $fmt_dst{tags}{TRACKNUMBER}=\"$tags{TRACKNUMBER}\"";
		}
		# Numéros de disques
		if ( defined $tags{DISCNUMBER} ) {
			$tags{DISCNUMBER} = "$tags{DISCNUMBER}/$tags{DISCSTOTAL}"
				if ( defined $tags{DISCSTOTAL} );
			$lenc_opts .= " $fmt_dst{tags}{DISCNUMBER}=\"$tags{DISCNUMBER}\"";
		}

		# Compression du fichier
		commande_ok("'$enc_bin' $lenc_opts \"$fwav\"")
			or sortie_erreur("impossible de compresser le fichier $fwav");
	}

	# OGG Opus/Vorbis
	elsif ( ( "$fmt_dst" eq "opus" ) || ( "$fmt_dst" eq "vorbis" ) ) {

		# Mise en forme des tags
		$lenc_opts .= " $fmt_dst{enc_tags_opts}";
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				next if ( $tag eq "ALBUMARTIST" );
				next if ( $tag eq "TRACKSTOTAL" );
				next if ( $tag eq "DISCNUMBER" );
				next if ( $tag eq "DISCSTOTAL" );
				$lenc_opts .= " $fmt_dst{tags}{$tag} \"$tags{$tag}\"";
			}
		}
		# Cas particuliers
		foreach my $tag ( qw/ALBUMARTIST TRACKSTOTAL DISCNUMBER DISCSTOTAL/ ) {
			$lenc_opts .= " $fmt_dst{tags}{$tag}=\"$tags{$tag}\""
				if ( defined $tags{$tag} );
		}

		# Compression du fichier
		if ( "$fmt_dst" eq "opus" ) {
			commande_ok("'$enc_bin' $lenc_opts \"$fwav\" \"$fic_cps\"")
				or sortie_erreur("impossible de compresser le fichier $fwav");
		}
		else {
			commande_ok("'$enc_bin' $lenc_opts -o \"$fic_cps\" \"$fwav\"")
				or sortie_erreur("impossible de compresser le fichier $fwav");
		}
	}

	msg_info("compression du fichier $fwav terminée");
	return "$fic_cps";
}

# Extrait les en-êtes utiles d'un fichier WAV
# et les renvoie sous forme de tableau
# Argument attendu : <le chemin du fichier>
sub extract_WAV_infos {
	my $fwav = shift;
	my ($fmt, $d);

	# Récupération des en-têtes
	sysopen WAV, "$fwav", O_RDONLY
		or sortie_erreur("impossible de lire le fichier $fwav");
	sysread WAV, $d, 12;
	sysread WAV, $fmt, 24;
	close WAV;
	my @infos = unpack("A4VvvVVvv", $fmt);

	# DEBUG
	# Une explication de tout ça ne fait pas de mal...
	msg_debug(" -WAVINFO-                      format : $infos[0]");
	msg_debug(" -WAVINFO-                    longueur : $infos[1]");
	msg_debug(" -WAVINFO-                     inutile : $infos[2]");
	msg_debug(" -WAVINFO-                      canaux : $infos[3]");
	msg_debug(" -WAVINFO- fréquence d'échantillonnage : $infos[4] Hz");
	msg_debug(" -WAVINFO-          octets par seconde : $infos[5]");
	msg_debug(" -WAVINFO-      octets par échantillon : $infos[6]");
	msg_debug(" -WAVINFO-        bits par échantillon : $infos[7]");
	# /DEBUG
	return (@infos);
}

# Fonction principale
# Ne renvoie rien
# Arguments attendus : aucun
sub principal {
	# Décompression de la source
	$fic_wav = decompress_src("$fic_src");

	# Dirname. Ça servira par la suite
	my $rep_wav = $fic_wav;
	$rep_wav = dirname $fic_wav if ( -f "$fic_wav" );

	# Découpage + archivage du fichier si besoin
	if ( $split ) {
		split_wav("$fic_wav");
		archive_src() unless ( $empty );
	}

	# Nettoyage si besoin
	if ( $empty ) {
		suppr_fic("$fic_src") if ( -f "$fic_src" );
		suppr_fic("$fic_cue") if ( -f "$fic_cue" );
	}

	# Et, arrivé ici, on a des fichiers WAV séparés, un par morceau
	# Reste plus qu'à recompresser dans le format voulu
	# Pour éviter les embrouilles, désormais, on transmet un nom de _répertoire_
	compress_dest("$rep_wav");

	# Ajout des tags ReplayGain, éventuellement
	ajout_RGtags("$rep_wav") unless ( $noreplaygain );

	# Et le petit plus pour la fin : la concaténation de playlists
	# pour les albums multi-disques
	concat_m3u("$rep_wav");

	## Fin de la fin
	msg_info("mission accomplie :)");
	print "\n";
	return;
}


# Affichage de l'aide et sortie
# Arguments attendus : aucun
sub aide {
  my $fdec = join(", ", @decformats);
  my $fenc = join(", ", @encformats);

  print <<EOF;

  $prog v$version

  Usage :
     $prog -h
     $prog [ <options> ] SOURCE

  Options :
     -h|--help
        affiche cette aide

     -a|--archive
        déplace les fichiers SOURCE dans un sous-répertoire ./SRC/
	(défaut : activé par -s)

     -C|--noclip
        désactive le calcul de la réduction de volume à l'encodage

     -c|--fic_cue FICHIER
        indique le chemin du fichier CUE (pour découpe d'un album en morceaux)
        (défaut : selon le chemin du fichier source)
        implique -s

     -D|--debug
        active le mode debug

     -e|--empty
        supprime le fichier SOURCE après la compression

     -g|--noreplaygain
        désactive l'ajout des tags ReplayGain

     -I|--fmt_src FORMAT
        indique le format des fichiers si FICHIER est un répertoire
        (défaut : le format le plus représenté, ou $fmt_src)

     -i|--dec_opts "OPTIONS"
        indique des options supplémentaires à passer au décodeur
        (défaut : $dec_def_opts)

     -O|--fmt_dst FORMAT
        indique le format des fichiers en fin de traitement
        (défaut : $fmt_dst)

     -o|--enc_opts "OPTIONS"
        indique des options supplémentaires à passer à l'encodeur
        (défaut : selon le format d'encodage choisi)

     -s|--split
        indique que SOURCE est un fichier album à découper (debug uniquement)
        nécessite un fichier CUE (voir -c)
        (défaut : déterminé automatiquement. Mais pas toujours bien !)
        implique -a

     -t|--tag ARTIST="ARTIST"
              ALBUM="ALBUM"
              ALBUMARTIST="ALBUMARTIST"
              TITLE="TITLE"
              DATE="YEAR"
              TRACKNUMBER="NUMBER"
              TRACKSTOTAL="NUMBER"
              DISCNUMBER="NUMBER"
              DISCSTOTAL="NUMBER"
        ajoute ou remplace les tags correspondants lors de la recompression
        (défaut : déterminés automatiquement si les fichiers sources
        sont déjà taggés, ou grâce au fichier CUE si le fichier source doit
        être découpé)

     -v|--verbose
        active le mode bavard

     Note :
        SOURCE est le chemin du fichier ou du répertoire à traiter (obligatoire)

     Formats acceptés :
        - en décompression : $fdec
        - en compression : $fenc

     Exemples d'options à passer à l'encodeur :
        MP3/MPC : "--scale 0.8"

EOF
	exit 0;
}

# /Fonctions
####
make_formats;

## Traitement des arguments
my (%lconfig, %cmdtags);
GetOptions (
	'a|archive'			=> \$lconfig{archive},
	'C|noclip'			=> \$lconfig{noclip},
	'c|fic_cue=s'		=> \$lconfig{fic_cue},
	'D|debug'			=> \$lconfig{debug},
	'e|empty'			=> \$lconfig{empty},
	'g|noreplaygain'	=> \$lconfig{noreplaygain},
	'h|help'			=> \$lconfig{help},
	'I|fmt_src=s'		=> \$lconfig{fmt_src},
	'i|dec_opts=s'		=> \$lconfig{dec_opts},
	'O|fmt_dst=s'		=> \$lconfig{fmt_dst},
	'o|enc_opts=s'		=> \$lconfig{enc_opts},
	's|split'			=> \$lconfig{split},
	't|tag=s'			=> \%cmdtags,
	'v|verbose'			=> \$lconfig{verbose}
	)
or aide();
aide() if ( defined $lconfig{help} );

# Niveau de verbosité
$debug   = 1 if ( defined $lconfig{debug} );
$verbose = 1 if ( defined $lconfig{debug} );
$verbose = 1 if ( defined $lconfig{verbose} );
msg_verb("$prog v$version");

# Fichier source
aide() unless ( defined $ARGV[0] );
$fic_src = File::Spec->rel2abs("$ARGV[0]");
$src_is_rep = fic_ou_rep("$fic_src");

# Archive ? Suppression ? Mais pas les deux en tout cas !
if ( defined $lconfig{archive} ) {
	$archive = 1;
	if ( defined $lconfig{empty} ) {
		msg_attention("les options -a et -e ne peuvent pas cohabiter");
		msg_attention("par sécurité, seul -a est retenu");
	}
}
else {
	$empty = 1 if ( defined $lconfig{empty} );
}

# Fichier .CUE ?
if ( defined $lconfig{fic_cue} ) {
	sortie_erreur("l'option -c est activée, mais $fic_src est un répertoire")
		if ( $src_is_rep == 1 );
	$fic_cue = $lconfig{fic_cue};
	sortie_erreur("$fic_cue n'est pas un fichier")
		unless ( fic_ou_rep("$fic_cue") == 0 );
	$split = 1;
	msg_verb("fichier CUE : $fic_cue (option forcée)");
}

# Fichier à découper ?
if ( defined $lconfig{split} ) {
	sortie_erreur("l'option -c est activée, mais $fic_src est un répertoire")
		if ( $src_is_rep == 1 );
	$split = 1;
	msg_verb("$fic_src est un album à découper (option forcée)");
}
else {
	if ( $src_is_rep == 0 ) {
		unless ( $fic_cue ) {
			$fic_cue = recup_cue("$fic_src");
			if ( $fic_cue eq "__nocue__" ) {
				msg_attention("$fic_src ne sera pas découpé");
			}
			else {
				msg_verb("$fic_src est un album à découper");
				msg_verb("fichier CUE trouvé : $fic_cue");
				$split = 1;
			}
		}
	}
}
if ( $split ) {
	$split_bin = chem_bin("$split_bin");
	$archive = 1;
}

# Format source
if ( defined $lconfig{fmt_src} ) {
	$fmt_src = int_format("$lconfig{fmt_src}");
	if ( $src_is_rep == 1 ) {
		msg_verb("format d'entrée : $fmt_src (option forcée)");
	}
	else {
		msg_verb("$fic_src est un fichier $fmt_src (option forcée)");
	}
}
else {
	$fmt_src = detect_formats("$fic_src");
	msg_verb("format d'entrée : $fmt_src");
}
sortie_erreur("le format d'entrée $fmt_src n'est pas pris en charge")
	unless grep(/$fmt_src/, @decformats);
%fmt_src = %{$codecs{$fmt_src}};
$dec_bin = chem_bin("$dec_bin");

# Format destination
$fmt_dst = int_format("$lconfig{fmt_dst}")
	if ( defined $lconfig{fmt_dst} );
msg_verb("format de sortie : $fmt_dst");
sortie_erreur("le format de sortie $fmt_dst n'est pas pris en charge")
	unless grep(/$fmt_dst/, @encformats);
%fmt_dst = %{$codecs{$fmt_dst}};
$enc_bin = chem_bin("$fmt_dst{enc_bin}");

# DEBUG
#~ exit 0;
# /DEBUG

# Gestion des arguments tags
if ( scalar(keys %cmdtags) > 0 ) {
	%cmdtags = uc_clefs_hash(%cmdtags);
	maj_gtags(%cmdtags);
}

# Options supplémentaires
$dec_opts = $lconfig{dec_opts} if ( defined $lconfig{dec_opts} );
$enc_opts = $lconfig{enc_opts} if ( defined $lconfig{enc_opts} );

# Désactivation du calcul anti-clipping
$noclip = $lconfig{noclip} if ( defined $lconfig{noclip} );

# Désactivation des ajouts ReplayGain
$noreplaygain = $lconfig{noreplaygain} if ( defined $lconfig{noreplaygain} );

## /Arguments
# Maintenant, on peut commencer
principal;
exit 0;
