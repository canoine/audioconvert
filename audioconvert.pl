#!/usr/bin/perl
#
# Conversion des fichiers audio
# de divers formats vers divers formats
#
# Ce script a besoin d'un certain nombre de dépendances
# en fonction des actions demandées :
# - compression : selon le format (voir %codecs)
# - décompression : selon le format (voir %codecs)
# - découpage (WAV) : binaire bchunk
# - rééchantillonnage (WAV) : binaire sox
# - lecture des metatags :
#		- dans un fichier CUE : binaire cueprint
#		- dans un fichier audio : selon le format (voir %codecs)
#
###
#
# Changelog :
# 0.6 :	- réécriture complète du script (intialement en shell) en perl
#		- écriture des tags
#		- écriture ou réécriture des playlists M3U
#		- rééchantillonnement des fichiers WAV selon les codecs
#
# En cours :
# 	- Ajout ReplayGain
#
# TODO :
#	- maintenant qu'on a introduit sox, on devrait pouvoir remplacer
# 		d'autres binaires, histoire de réduire les dépendances
#	- split_wav : récupération des tags à partir du fichier CUE uniquement...
#
###
#
# CNE - 20200327
#
my $version = "0.6";

use strict;
use warnings;
use Audio::Musepack;
use Data::Dumper;
use File::Basename;
use File::MimeInfo::Magic;
use File::Spec;
use File::Which;
use Fcntl;
use Getopt::Long qw(:config no_ignore_case bundling);

my $prog = basename $0;

# Options par défaut
my $debug;						# Sortie debug ?
my $dec_opts;					# Options supplémentaires à passer au décodeur
my $empty;						# Doit-on supprimer le fichier source ?
my $enc_opts;					# Options supplémentaires à passer à l'encodeur
my $fic_cue;					# Nom du fichier .CUE
my $fic_src;					# Nom du fichier ou du répertoire source
my $fmt_src			= 'flac';	# Format des fichiers sources
my $fmt_dst			= 'flac';	# Format des fichiers destinations
my $noreplaygain;				# Doit-on désactiver les tags ReplayGain ?
my $src_is_rep;					# La source est-elle un répertoire ?
my $verbose;					# Sortie verbeuse ?
# Et ça, c'est pour alléger le code.
my %fmt_src;					# options par défaut du format source
my %fmt_dst;					# options par défaut du format destination

# Formats pris en charge, binaires, et options
# Format du tableau :
#
#	format1 => {
#		dec_bin			=>	"exécutable",		# scalaire
#		dec_opts		=>	"--options",		# chaîne scalaire
#		dec_verb_opt	=>	"--verbose",		# scalaire
#		dec_info_opt	=>	"--silent",			# scalaire
#		dec_tag_sub		=>	\&fonction,			# fonction
#		dec_tag_bin		=>	"exécutable",		# scalaire
#		dec_tags_opts	=>	"--option=",		# chaîne scalaire
#		enc_bin			=>	"exécutable",		# scalaire
#		enc_opts		=>	"--options",		# chaîne scalaire
#		enc_verb_opt	=>	"--verbose",		# scalaire
#		enc_info_opt	=>	"--silent",			# scalaire
#		enc_tags_sub	=>	"fonction",			# scalaire
#		enc_tags_bin	=>	"exécutable",		# scalaire
#		enc_tags_opts	=>	"--option=",		# chaîne scalaire
#		ext				=>	"extension",		# scalaire
#		rg_bin			=>	"exécutable",		# scalaire
#		rg_opts			=>	""--options",		# chaîne scalaire
#		tags			=>	{					# hash
#			artist			=>	'nom',			# scalaire
#			album			=>	'nom',			# scalaire
#			title			=>	'nom',			# scalaire
#			date			=>	'nom',			# scalaire
#			track_number	=>	'nom',			# scalaire
#			tracks_total	=>	'nom',			# scalaire
#			disc_number		=>	'nom',			# scalaire
#			discs_total		=>	'nom'			# scalaire
#		}
#	},
#
#	format2 => {
#		(...)
#
# Toutes les clefs ne sont pas obligatoires :
# - "dec_bin" est facultatif, mais il ne sera pas possible de décompresser
#		des fichiers de ce format si absent,
# - "dec_opts", "dec_verb_opt" et "dec_info_opt" sont facultatifs,
# - au moins une des deux clefs "dec_tag_sub" / "dec_tag_bin" est nécessaire
#		pour extraire les tags d'un fichier compressé (mais le script utilise
#		de préférence les données du fichier CUE lorsque c'est possible),
# - "dec_tags"_opts est facultatif,
# - "enc_bin" est facultatif, mais il ne sera pas possible d'utiliser
#		ce codec pour compresser des fichiers si absent,
# - "enc_opts", "enc_verb_opt" et "enc_info_opt" sont facultatifs,
# - au moins une des deux clefs "enc_tag_sub" / "enc_tag_bin" est nécessaire
#		pour écrire les tags d'un fichier destination,
# - "enc_tags"_opts est facultatif ("enc_bin" sera utilisé si absent),
# - "ext" est facultatif ("format" sera utilisé comme extension si absent),
# - "rg_bin" est facultatif, mais il ne sera pas possible d'ajouter des tags
#		ReplayGain sur des fichiers de ce format si absent,
# - "rg_opts" est facultatif,
# - le sous-tableau "tags" complet est obligatoire :
#		- pour extraire les tags d'un fichier source (mais le script utilise
#			de préférence les données du fichier CUE lorsque c'est possible).
#		- pour écrire les tags d'un fichier destination.
#

my %codecs = (

# Monkey audio. Lossless, mais pas libre.
# En décompression uniquement.
	'ape'	=>	{
		dec_bin			=>	"mac",
		dec_opts		=>	"-d",
		dec_tag_sub		=>	\&extract_APE_tags,
		tags			=>	{
			artist			=>	'ARTIST',
			album			=>	'ALBUM',
			albumartist		=>	'ALBUM ARTIST',
			title			=>	'TITLE',
			date			=>	'YEAR',
			track_number	=>	'TRACK',
			tracks_total	=>	'/TRACK',
			disc_number		=>	'DISC',
			discs_total		=>	'/DISC'
		}
	},

# FLAC. Libre, et Lossless.
	'flac'	=>	{
		dec_opts		=>	"--decode --force --decode-through-errors",
		dec_info_opt	=>	"--silent",
		dec_tag_bin		=>	"metaflac",
		dec_tags_opts	=>	"--export-tags-to='-'",
		enc_bin			=>	"flac",
		enc_opts		=>	"--best --force --output-name",
		enc_info_opt	=>	"--silent",
		enc_tags_opts	=>	"--tag=",
		dec_bin			=>	"flac",
		rg_bin			=>	"metaflac",
		rg_opts			=>	"--add-replay-gain",
		tags			=>	{
			artist			=>	'ARTIST',
			album			=>	'ALBUM',
			albumartist		=>	'ALBUMARTIST',
			title			=>	'TITLE',
			date			=>	'DATE',
			track_number	=>	'TRACKNUMBER',
			tracks_total	=>	'TRACKTOTAL',
			disc_number		=>	'DISCNUMBER',
			discs_total		=>	'DISCTOTAL'
		}
	},

# MP3. Ben oui.
# Un peu incontournable. Mais ni libre, ni lossless.
# En compression uniquement.
	'mp3'	=>	{
		enc_bin			=>	"lame",
		enc_opts		=>	"-V 3",
		enc_verb_opt	=>	"--verbose",
		enc_info_opt	=>	"--brief",
		enc_tags_opts	=>	"--add-id3v2",
		tags			=>	{
			artist			=>	'--ta',
			album			=>	'--tl',
			albumartist		=>	'--tv TPE2',
			title			=>	'--tt',
			date			=>	'--ty',
			track_number	=>	'--tn',
			tracks_total	=>	'/--tn',
			disc_number		=>	'--tv TPOS',
			discs_total		=>	'/--tv TPOS'
		}
	},

# Musepack SV8 est plus récent que la version SV7. C'est la version recommandée
# par ses créateurs et celle qui devrait être privilégiée.
# Problème : pas grand chose n'est compatible avec cette version.
# Bugs :
#	- ne sait pas compresser des fichiers WAV avec plus de deux canaux
#	- ne sait pas compresser des fichiers WAV cadencé à plus de 48 kHz
# Le script essaiera de rééchantillonner les fichiers s'il trouve sox
	'mpc8'	=>	{
		enc_bin			=>	"mpcenc",
		enc_opts		=>	"--insane --overwrite",
		enc_verb_opt	=>	"--verbose",
		enc_tags_opts	=>	"--tag",
		dec_bin			=>	"mpcdec",
		dec_tag_sub		=>	\&extract_APE_tags,
		ext				=>	"mpc",
		rg_bin			=>	"mpcgain",
		tags			=>	{
			artist			=>	'ARTIST',
			album			=>	'ALBUM',
			albumartist		=>	'ALBUM ARTIST',
			title			=>	'TITLE',
			date			=>	'YEAR',
			track_number	=>	'TRACK',
			tracks_total	=>	'/TRACK',
			disc_number		=>	'DISC',
			discs_total		=>	'/DISC'
		}
	},

# Musepack SV7. Officiellement obsolète, mais, au moins, la plupart des
# logiciels compatibles savent les lire...
# Problèmes :
# - la plupart du temps, il faut télécharger les binaires à la main
# - tout est compilé en 32 bits
# - replaygain a besoin de bibliothèques esound (!)
# - impossible de mettre la main sur les sources
# Bugs :
# - ne sait pas compresser des fichiers WAV avec plus de deux canaux
# - ne sait pas compresser des fichiers WAV cadencé à plus de 48 kHz
# - ne sait pas compresser des fichiers WAV avec plus de 16 bits par échantillon
# Le script essaiera de rééchantillonner les fichiers s'il trouve sox
# Note : le décodeur est le SV8, pour éviter les incompatibilités. Mais le SV7
# (nommé mppdec, avec deux "p"), doit être installé pour replaygain.
	'mpc'	=>	{
		enc_bin			=>	"mppenc",
		enc_opts		=>	"--insane --overwrite",
		enc_verb_opt	=>	"--verbose",
		enc_tags_opts	=>	"--tag",
		dec_bin			=>	"mpcdec",
		dec_tag_sub		=>	\&extract_APE_tags,
		rg_bin			=>	"replaygain",
		rg_opts			=>	"--auto",
		tags			=>	{
			artist			=>	'ARTIST',
			album			=>	'ALBUM',
			albumartist		=>	'ALBUM ARTIST',
			title			=>	'TITLE',
			date			=>	'YEAR',
			track_number	=>	'TRACK',
			tracks_total	=>	'/TRACK',
			disc_number		=>	'DISC',
			discs_total		=>	'/DISC'
		}
	},

# Wavpack. Libre, mais pas forcément Lossless.
# En décompression uniquement.
	'wavpack'	=>	{
		dec_bin			=>	"wvunpack",
		dec_opts		=>	"--wav -y",
		dec_verb_opt	=>	"",
		dec_info_opt	=>	"-q",
		dec_tag_sub		=>	\&extract_APE_tags,
		ext				=>	"wv",
		tags			=>	{
			artist			=>	'ARTIST',
			album			=>	'ALBUM',
			albumartist		=>	'ALBUM ARTIST',
			title			=>	'TITLE',
			date			=>	'YEAR',
			track_number	=>	'TRACK',
			tracks_total	=>	'/TRACK',
			disc_number		=>	'DISC',
			discs_total		=>	'/DISC'
		}
	},

# WAV. La base. Pas de compression. Pas de tags non plus.
# Ajouté ici pour des raisons de facilité.
	'wav'	=>	{
		enc_bin			=>	"true",
		dec_bin			=>	"true",
		#~ tags			=>	{
			#~ artist			=>	'ARTIST',
			#~ album			=>	'ALBUM',
			#~ title			=>	'TITLE',
			#~ date			=>	'DATE',
			#~ track_number	=>	'TRACKNUMBER',
			#~ tracks_total	=>	'TRACKTOTAL',
			#~ disc_number		=>	'DISCNUMBER',
			#~ discs_total		=>	'DISCTOTAL'
		#~ }
		ext				=>	"wav"
	}
);

# Construction de la liste des formats supportés
my (@decformats, @encformats);
foreach my $fmt ( sort(keys %codecs) ) {
	push (@decformats, "$fmt")
		if ( defined $codecs{$fmt}{dec_bin} );
	push (@encformats, "$fmt")
		if ( defined $codecs{$fmt}{enc_bin} );
}

# Exécutable et options pour la découpe des fichiers WAV
my $split_bin = "bchunk";
my $split_opts = "-w";
my $split_verb_opts = "-v";
my $split_info_opts = "";

# Exécutable et options pour la lecture des tags dans un fichier CUE
my $cueprint_bin = chem_bin("cueprint");
my %cueprint_discinfo = (
	albumartist	 =>	"$cueprint_bin --disc-template \'%P\\n\'",
	album		 =>	"$cueprint_bin --disc-template \'%T\\n\'",
	tracks_total =>	"$cueprint_bin --disc-template \'%N\\n\'"
);
my %cueprint_trackinfo = (
	artist		 =>	"$cueprint_bin --track-template \'%p\\n\' --track-number ",
	title		 =>	"$cueprint_bin --track-template \'%t\\n\' --track-number ",
	track_number =>	"$cueprint_bin --track-template \'%n\\n\' --track-number ",
);

# Exécutable et options pour le rééchantillonnage des fichiers WAV
my $sox_bin = "sox";
my $sox_v09_opts = "--volume 0.9";
my $sox_r48_opts = "--rate 48000";
my $sox_b16_opts = "--bits 16";
my $sox_verb_opts = "-V4 --show-progress";
my $sox_info_opts = "-V2";

# Exécutables pour décompresser et compresser
my ($dec_bin, $enc_bin);

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
sub commande {
	my $commande = shift;
	chomp $commande;
	msg_debug("lancement de la commande $commande");
	system("$commande") && return;
	return 1;
}

# Copie depuis https://perlmaven.com/unique-values-in-an-array-in-perl
sub uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

# Ajoute une ligne vide à la fin d'un fichier si besoin.
# Lorsqu'un fichier CUE, par exemple, ne se termine pas par une ligne vide,
# ça peut poser problème avec certains outils (cueprint, par exemple)
# Argument attendu : <le chemin du fichier>
sub add_nl {
	my $fic = shift;
	open (FIC, "<$fic")
		or sortie_erreur("impossible d'ouvrir le fichier $fic");
	my @fic = (<FIC>);
	close FIC;
	if ( $fic[-1] !~ /\n$/ ) {
		msg_debug("ajout d'un LF dans $fic");
		open (FIC, ">>$fic")
			or sortie_erreur("impossible d'écrire dans le fichier $fic");
		print FIC "\n";
		close FIC;
	}
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
# Renvoie 0 si le chemin est un fichier, si le chemin est un répertoire
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
	my $mime_type = mimetype("$fichier");
	msg_debug("format du fichier $fichier : $mime_type");
	return "flac"		if ( $mime_type eq "audio/flac" );
	return "ape"		if ( $mime_type eq "audio/x-ape" );
	return "wav"		if ( $mime_type eq "audio/x-wav" );
	return "wavpack"	if ( $mime_type eq "audio/x-wavpack" );
	return "mpc"		if ( $mime_type eq "audio/x-musepack" );
	return "mp3"		if ( $mime_type eq "audio/mpeg" );
	return "m3u"		if ( $mime_type eq "audio/x-mpegurl" );
	return "inconnu";
}

# Interprète le format de fichier donné en argument
# Sort en erreur si inconnu
# Argument attendu : <un format>
sub int_format {
	my $fmt = shift;
	# Attention à l'ordre des tests !
	return "flac"		if (	lc($fmt) =~ /^flac/ );
	return "ape"		if ( (	lc($fmt) =~ /^ape/ )
						 || (	lc($fmt) =~ /^monk/ ) );
	return "mpc8"		if ( (	lc($fmt) =~ /^mpc(.*)8$/ )
						 || (	lc($fmt) =~ /^muse(.*)8$/ ) );
	return "mpc"		if ( (	lc($fmt) =~ /^mpc/ )
						 || (	lc($fmt) =~ /^muse/ ) );
	return "mp3"		if (	lc($fmt) =~ /^mp/ );
	return "wavpack"	if ( (	lc($fmt) =~ /^wavp/ )
						 || (	lc($fmt) =~ /^wv/ ) );
	return "wav"		if (	lc($fmt) =~ /^wav/ );
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
	sortie_erreur
		("impossible de trouver un fichier .CUE.".
		" Soit il n'y en a pas, soit il y en a plusieurs,".
		" dont aucun avec un nom facilement detectable");
}

# Décompression du ou des fichiers sources
# Le but est de sortir avec uniquement des fichiers WAV
# Argument attendu : <le chemin de la source>
sub decompress_src {
	my $chemin = shift;

	my $fic_wav = $chemin;
	if ( $src_is_rep == 0 ) {
		sortie_erreur("$chemin n'est pas un fichier $fmt_src")
			if ( fic_format("$chemin") ne "$fmt_src" );
		$fic_wav = decompress_fic("$chemin");
	}
	else {
		# On décompresse tous les fichiers qui conviennent
		# mais on ne pourra en retourner qu'un seul...
		foreach my $fic ( recup_liste_fics("$chemin") ) {
			chomp $fic;
			next if ( fic_format("$fic") ne "$fmt_src" );
			decompress_fic("$fic");
		}
	}
	return "$fic_wav";
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
	my $ldec_opts = " ";
	my ($ltag_bin, $ltag_opts);

	# Décompression
	msg_debug("utilisation du binaire $dec_bin");

	## Options de décompression
	# Niveau de causerie
	if ( $verbose ) {
		$ldec_opts = "$fmt_src{dec_verb_opt}"
			if ( defined $fmt_src{dec_verb_opt} );
	}
	else {
		$ldec_opts = "$fmt_src{dec_info_opt}"
			if ( defined $fmt_src{dec_info_opt} );
	}
	# Paramètres donnés par l'utilisateur
	$ldec_opts .= " $dec_opts" if ( defined $dec_opts );

	# Les paramètres par défaut doivent être placés en dernier, car, selon
	# les codecs, le nom du fichier destination doit être ajouté juste après.
	$ldec_opts .= "$fmt_src{dec_opts}" if ( defined $fmt_src{dec_opts} );
	msg_debug("options de la commande : \"$ldec_opts\"");

	# Nom du fichier wav
	my $fic_wav = $fic_cps;
	$fic_wav =~ s/\.[^.]+$/\.wav/;
	msg_debug("fichier décompressé : $fic_wav");

	# Si nécessaire, pour extraction des tags
	my (%tags, $fic_tag);
	if ( %{$fmt_src{tags}} ) {
		if ( defined $fmt_src{dec_tag_sub} ) {
			$ltag_bin = $fmt_src{dec_tag_sub};
			msg_debug("extraction des tags par routine interne");
		}
		else {
			if ( defined $fmt_src{dec_tag_bin} ) {
				$ltag_bin = chem_bin("$fmt_src{dec_tag_bin}");
				msg_debug
					("utilisation du binaire $ltag_bin pour extraire les tags");
			}
			else {
				msg_info("aucun moyen d'extraction des tags".
					" pour le format $fmt_src ?")
			}
			$ltag_opts = " ";
			$ltag_opts = "$fmt_src{dec_tags_opts}"
				if ( defined $fmt_src{dec_tags_opts} );
			msg_debug("options d'extraction des tags : $ltag_opts");
		}
		# Nom du fichier tag
		if ( defined $ltag_bin ) {
			$fic_tag = $fic_cps;
			$fic_tag =~ s/\.[^.]+$/\.tag/;
			msg_debug("fichier contenant les tags : $fic_tag");
		}
	}

	## Certaines actions dépendent du format.
	# FLAC
	if ( "$fmt_src" eq "flac" ) {
		# Décompression du fichier
		commande("'$dec_bin' $ldec_opts \"$fic_cps\"")
			or sortie_erreur("impossible de décompresser le fichier $fic_cps");

		# Extraction des tags
		if ( ( defined $ltag_bin ) && ( %{$fmt_src{tags}} ) ) {
			msg_debug("lancement de la commande '$ltag_bin'".
				" $ltag_opts '\"$fic_cps\"");
			my @tmptags = `'$ltag_bin' $ltag_opts \"$fic_cps\"`;
			sortie_erreur
				("impossible de récupérer les tags du fichier $fic_cps")
				unless ( $? == 0 );

			foreach my $tag (@tmptags) {
				chomp $tag;
				msg_debug(" -FLACTAG- $tag");
				foreach my $typetag ( keys %{$fmt_src{tags}} ) {
					if ( $tag =~ /^$fmt_src{tags}{$typetag}=/ )	{
						$tags{$typetag} = (split (/\=/, $tag))[1];
						next;
					}
				}
			}
		}
	}
	# Wavpack
	elsif ( "$fmt_src" eq "wv" ) {
		# Décompression du fichier
		commande("'$dec_bin' $ldec_opts \"$fic_cps\"")
			or sortie_erreur("impossible de décompresser le fichier $fic_cps");

		# Extraction des tags
		if ( ( defined $ltag_bin ) && ( %{$fmt_src{tags}} ) ) {
			msg_debug("extraction des tags");
			%tags = $ltag_bin->("$fic_cps");
		}
	}
	# Monkey audio
	elsif ( "$fmt_src" eq "ape" ) {
		# Décompression du fichier
		commande("'$dec_bin' \"$fic_cps\" \"$fic_wav\" $ldec_opts")
			or sortie_erreur("impossible de décompresser le fichier $fic_cps");

		# Extraction des tags
		if ( ( defined $ltag_bin ) && ( %{$fmt_src{tags}} ) ) {
			msg_debug("extraction des tags");
			%tags = $ltag_bin->("$fic_cps");
		}
	}
	# Musepack
	elsif ( ( "$fmt_src" eq "mpc" )	|| ( "$fmt_src" eq "mpc8" ) ) {
		# Décompression du fichier
		commande("'$dec_bin' $ldec_opts \"$fic_cps\" \"$fic_wav\"")
			or sortie_erreur("impossible de décompresser le fichier $fic_cps");

		# Extraction des tags
		if ( ( defined $ltag_bin ) && ( %{$fmt_src{tags}} ) ) {
			msg_debug("extraction des tags");
			%tags = $ltag_bin->("$fic_cps");
			extract_MPC_infos("$fic_cps");
		}
	}
	suppr_fic("$fic_cps") if ( $empty );

	# Traitement des tags
	if ( ( defined $ltag_bin ) && ( %{$fmt_src{tags}} ) ) {

		# Mise en forme de la date
		if ( ( defined $tags{date} ) && ( $tags{date} =~ /^[0-9]+\-/ ) ) {
			$tags{date} = (split (/\-/, $tags{date}))[0];
		}

		# Mise en forme des numéros de disques
		if ( defined $tags{discs_total} ) {
			if ( $tags{discs_total} > 1 ) {
				$tags{disc_number} = sprintf ("%02d", $tags{disc_number})
					if ( defined $tags{disc_number} );
				$tags{discs_total} = sprintf ("%02d", $tags{discs_total});
			}
			else {
				undef $tags{discs_total};
				undef $tags{disc_number} if ( defined $tags{disc_number} );
			}
		}

		# Mise en forme des numéros de morceau
		$tags{tracks_total} = sprintf ("%02d", $tags{tracks_total})
			if ( defined $tags{tracks_total} );
		$tags{track_number} = sprintf ("%02d", $tags{track_number})
			if ( defined $tags{track_number} );

		# Écriture du fichier tag (enfin !)
		open (FTAG, ">$fic_tag")
			or sortie_erreur("impossible d'écrire le fichier $fic_tag");

		# Nom original du fichier
		print FTAG "nom=$fic_orig\n";
		foreach my $tag ( keys %tags ) {
			if ( defined $tags{$tag} ) {
				msg_debug(" -FICTAG- $tag=$tags{$tag}");
				print FTAG "$tag=$tags{$tag}\n";
			}
		}
		close FTAG;
	}
	return "$fic_wav";
}

# Extraction des tags APE d'un fichier MPC ou APE.
# Retourne un tableau associatif avec les valeurs attendues.
# Argument attendu : <le chemin du fichier>
sub extract_APE_tags {
	my $fic_mpc = shift;
	my %tags;

	my $mpc = Audio::Musepack->new("$fic_mpc");
	my $mpcTags = $mpc->tags();

	foreach my $dt ( keys %$mpcTags ) {
		next if ( $dt =~ /^COVER /);	# image
		msg_debug(" -APETAG- $dt=$$mpcTags{$dt}");
	}

	foreach my $typetag ( keys %{$fmt_src{tags}} ) {
		chomp $typetag;

		# Il faut traiter ces tags à part
		next if ( $typetag eq "discs_total" );
		next if ( $typetag eq "tracks_total" );

		# Simplification des correspondances
		$tags{$typetag} = $$mpcTags{uc($fmt_src{tags}{$typetag})};

		# Traitement à part
		if ( defined $tags{$typetag} ) {
			if ( $typetag eq "disc_number" ) {
				if ( $tags{$typetag} =~ /^[0-9]+\/[0-9]+$/ ) {
					($tags{disc_number}, $tags{discs_total}) =
						split (/\//, $tags{disc_number});
					msg_debug(" -TAG- discs_total=$tags{discs_total}");
				}
			}
			if ( $typetag eq "track_number" ) {
				if ( $tags{$typetag} =~ /^[0-9]+\/[0-9]+$/ ) {
					($tags{track_number}, $tags{tracks_total}) =
						split (/\//, $tags{track_number});
					msg_debug(" -TAG- tracks_total=$tags{tracks_total}");
				}
			}
			msg_debug(" -TAG- $typetag=$tags{$typetag}")
				if ( defined $tags{$typetag} );
		}
	}
	return %tags;
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
		#~ next if ( $dt =~ /^COVER /);	# image
		msg_debug(" -MPCINFO- $dt=$$mpc_infos{$dt}");
	}
}

# Découpage du fichier WAV, s'il contient plusieurs morceaux
# et, tant que faire se peut, transfère les tags extraits.
# Nécessite un fichier CUE
# Argument attendu : <le chemin du fichier>
sub split_wav {
	my $fic_wav = shift;
	msg_info("découpage du fichier $fic_wav");

	# Le découpage crée des fichiers numérotés de la forme fichierXX.wav
	# On prépare donc le terrain
	my $base_fic_split = $fic_wav;
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
	commande("\"$split_bin\" $split_opts".
		" \"$fic_wav\" \"$fic_cue\" \"$base_fic_split\"")
		or sortie_erreur("impossible de découper le fichier $fic_wav");
	suppr_fic("$fic_wav");

	# Nom du fichier tag
	my $fic_tag = $fic_wav;
	$fic_tag =~ s/\.[^.]+$/\.tag/;
	msg_debug("fichier contenant les tags : $fic_tag") if ( -f "$fic_tag" );

	# TODO : on récupère les tags depuis le fichier CUE
	# mais rien depuis le fichier .tag... Est-ce bien raisonnable ?

	# Récupération des tags "disque"
	my %wav_tags;
	msg_debug("récupération des tags disque");
	foreach my $tag ( keys %cueprint_discinfo ) {
		$wav_tags{$tag} = `$cueprint_discinfo{$tag} '$fic_cue'`;
		sortie_erreur
			("impossible de récupérer le tag $tag du fichier $fic_cue")
			unless ( $? == 0 );
		chomp $wav_tags{$tag};
		msg_debug(" -CUETAG- $tag=$wav_tags{$tag}");
	}

	# Date
	open (CUE, "<$fic_cue")
		or sortie_erreur("impossible de lire le fichier $fic_cue");
	foreach my $ligne (<CUE>) {
		chomp $ligne;
		next unless ( $ligne =~ /DATE / );
		$wav_tags{date} = (split (/ /, $ligne))[-1];
		last;
	}
	close CUE;
	msg_debug(" -CUETAG- date=$wav_tags{date}");

	# Les actions à entreprendre pour la conservation des tags
	# vont-elles dépendre du format ?
	for (my $num = 1; $num <= $wav_tags{tracks_total}; $num++) {
		my $snum = sprintf ("%02d", $num);

		# Nom du fichier
		my $sfic = "$base_fic_split"."$snum";
		msg_debug("traitement du fichier $sfic.wav");

		# Récupération des tags "morceau"
		my %ttags;
		foreach my $tag ( keys %cueprint_trackinfo ) {
			$ttags{$tag} = `$cueprint_trackinfo{$tag} '$snum' '$fic_cue'`;
			sortie_erreur
				("impossible de récupérer le tag $tag du fichier $fic_cue")
				unless ( $? == 0 );
			chomp $ttags{$tag};
			msg_debug(" -CUETAG- $tag=$ttags{$tag}");
		}

		# Numéro
		msg_debug(" -CUETAG- track_number=$snum");

		# Écriture du fichier tag
		open (STAG, ">$sfic.tag")
			or sortie_erreur("impossible d'écrire le fichier $sfic.tag");
		print STAG "track_number=$snum\n";
		foreach my $tag ( keys %ttags ) {
			print STAG "$tag=$ttags{$tag}\n";
		}
		foreach my $tag ( keys %wav_tags ) {
			print STAG "$tag=$wav_tags{$tag}\n";
		}
		close STAG;
	}
	suppr_fic("$fic_tag");
}

# Détermine le nom des fichiers M3U à utiliser si besoin
# et renvoie la liste sous forme de tableau
# Argument attendu : <le chemin de la source>
sub recup_m3u {
	my $chemin = shift;
	my $rep = $chemin;
	$rep = dirname $chemin if ( -f "$chemin" );

	if ( $src_is_rep == 1 ) {
		# Y a-t-il des fichiers M3U dans le répertoire ?
		my @fics_de_rep = recup_liste_fics("$rep");
		my @fics_m3u = grep (/\.m3u$/, @fics_de_rep);
		my $nb_m3u = scalar @fics_m3u;
		msg_debug("nombre de fichiers m3u dans $rep : $nb_m3u");

		# Oui ? Pas la peine d'aller plus loin. :)
		if ( scalar @fics_m3u > 0 ) {
			msg_debug("nom des fichiers m3u : ".join(', ', @fics_m3u));
			return @fics_m3u;
		}
	}

	# Sinon, il va falloir décider
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
# Argument attendu : <le chemin du répertoire source>
sub ajout_RGtags {
	my $chemin = shift;
	msg_info("ajout des tags ReplayGain");
	msg_debug("cette fonction n'est pas encore prête, et vous non plus :p");

	# Visiblement, le calcul se fait au niveau du répertoire
	sortie_erreur("$chemin n'est pas un répertoire") unless ( -d "$chemin" );

	# Extension des fichiers compressés
	my $fext = $fmt_dst;
	$fext = $fmt_dst{ext} if ( defined $fmt_dst{ext} );

	# Commandes
	my ($rg_bin, $rg_opts);
	if ( defined $fmt_dst{rg_bin} ) {
		$rg_bin = $fmt_dst{rg_bin};
		$rg_opts = " ";
		$rg_opts = $fmt_dst{rg_opts} if ( defined $fmt_dst{rg_opts} );
	}
	else {
		sortie_erreur("pas de commande RG pour le format $fmt_dst");
	}
	msg_debug("utilisation du binaire $rg_bin");
	msg_debug("options de la commande : \"$rg_opts\"");

	# Les actions à entreprendre pour la conservation des tags
	# vont-elles dépendre du format ?

	# Ajout des tags
	commande("'$rg_bin' $rg_opts \"$chemin\"/*.$fext")
		or sortie_erreur("impossible de tagger les fichiers de $chemin");

	# DEBUG
	# Vérification
	opendir(REP, "$chemin")
		or sortie_erreur("impossible de lister les fichiers de $chemin");

	foreach my $fic (readdir(REP)) {
		next if ( fic_format("$chemin/$fic") ne "$fmt_src" );
		msg_debug("-RG- $chemin/$fic");
		commande("'$rg_bin' --show-tag=REPLAYGAIN_TRACK_GAIN \"$chemin/$fic\"");
		commande("'$rg_bin' --show-tag=REPLAYGAIN_ALBUM_GAIN \"$chemin/$fic\"");
		msg_debug("-RG-");
	}
	# /DEBUG
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

	# On compresse tous les fichiers qui conviennent
	foreach my $fic ( recup_liste_fics("$chemin") ) {
		chomp $fic;
		msg_debug("traitement du fichier $fic");
		next if ( $fic =~ /\.OK$/ );	# Résidus de debugs
		next if ( fic_format("$fic") ne "wav" );

		# On récupère le nom original du fichier,
		# pour modifier les playlists existantes
		my $fic_orig = "__no_orig__";
		if ( $is_playlist ) {
			my $fic_tag = $fic;
			$fic_tag =~ s/\.[^.]+$/\.tag/;

			if ( -f "$fic_tag" ) {
				open (FTAG, "<$fic_tag")
					or sortie_erreur("impossible de lire le fichier $fic_tag");
				$fic_orig = (split(/=/, (grep(/^nom=/, <FTAG>))[0]))[-1];
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
	my $fic_wav = shift;

	# Logique, mais bon...
	return "$fic_wav" if ( "$fmt_dst" eq "wav" );
	msg_info("compression du fichier $fic_wav");

	# Nom du fichier tag
	my %tags;
	my $fic_tag = $fic_wav;
	$fic_tag =~ s/\.[^.]+$/\.tag/;

	# Récupération des tags
	if ( -f "$fic_tag" ) {
		msg_debug("fichier contenant les tags : $fic_tag");
		if ( %{$fmt_dst{tags}} ) {
			open (FTAG, "<$fic_tag")
				or sortie_erreur("impossible de lire le fichier $fic_tag");
			foreach my $ligne (<FTAG>) {
				chomp $ligne;
				foreach my $typetag	( keys %{$fmt_dst{tags}} ) {
					if ( $ligne =~ /^$typetag=/ ) {
						$tags{$typetag}=(split (/\=/, $ligne))[1];
						# Il y a quelques caractères qui passent mal en argument
						$tags{$typetag} =~ s/\$/\\\$/g;
						msg_debug(" -FICTAG- $typetag=$tags{$typetag}");
					};
				}
			}
			close FTAG;
		}
		suppr_fic("$fic_tag");
	}

	## Construction des commandes à lancer
	my ($lenc_opts, $ltag_bin, $ltag_opts);

	# Compression
	msg_debug("utilisation du binaire $enc_bin");

	# Extension du fichier compressé
	my $fext = $fmt_dst;
	$fext = $fmt_dst{ext} if ( defined $fmt_dst{ext} );

	# Nom du fichier compressé
	my $rep_cps = dirname "$fic_wav";
	my $fic_cps;
	# Si on a accès aux tags, le nom sera le titre. Parce que voilà.
	if ( defined $tags{title} ) {
		my $tmp_fic = "$tags{title}"."\.$fext";
		# Il y a quelques caractères interdits.
		# Attention, l'ordre des tests est important.
		$tmp_fic =~ s/\\\$/S/g;
		$tmp_fic =~ s/\\/-/g;
		$tmp_fic =~ s/\//-/g;
		$fic_cps = fic_unique("$rep_cps/$tmp_fic");
	}
	# Sinon, le nom est déterminé à partir de celui du fichier WAV.
	else {
		$fic_cps = $fic_wav;
		$fic_cps =~ s/\.[^.]+$/\.$fext/;
	}

	## Options de compression
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
		commande("'$enc_bin' $lenc_opts \"$fic_wav\"")
			or sortie_erreur("impossible de compresser le fichier $fic_wav");
	}

	# MPC
	elsif ( ( "$fmt_dst" eq "mpc8" ) || ( "$fmt_dst" eq "mpc" ) ) {

		# Détection des bugs du compresseur _avant_ que ça plante
		# pour pouvoir afficher un message compréhensible
		my ($fmt,$long,$f,$cans,$freq,$ops,$ope,$bpe) =
			extract_WAV_infos("$fic_wav");

		if ( ( $freq > 48000 ) || ( $bpe > 16 ) ) {
			msg_attention("le format du fichier $fic_wav est incompatible".
			" avec le codec $fmt_dst.");
			msg_attention(" fréquence d'échantillonnage : $freq Hz");
			msg_attention("        bits par échantillon : $bpe");
			$fic_wav = resample_wav("$fic_wav");
		}

		if ( $cans > 2 ) {
			msg_erreur("le format du fichier $fic_wav est incompatible".
			" avec le codec $fmt_dst.");
			msg_erreur("cause : nombre de canaux trop élevé ($cans)");
			sortie_erreur("vous DEVEZ choisir un autre format")
		}

		# Mise en forme des tags
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				next if ( $tag eq "track_number" );
				next if ( $tag eq "tracks_total" );
				next if ( $tag eq "disc_number" );
				next if ( $tag eq "discs_total" );
				$lenc_opts .= " $fmt_dst{enc_tags_opts} ".
					"\"$fmt_dst{tags}{$tag}\"=\"$tags{$tag}\"";
			}
		}
		# Numéros de morceaux
		if ( defined $tags{track_number} ) {
			$tags{track_number} = "$tags{track_number}/$tags{tracks_total}"
				if ( defined $tags{tracks_total} );
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" $fmt_dst{tags}{track_number}=\"$tags{track_number}\"";
		}
		# Numéros de disques
		if ( defined $tags{disc_number} ) {
			$tags{disc_number} = "$tags{disc_number}/$tags{discs_total}"
				if ( defined $tags{discs_total} );
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" $fmt_dst{tags}{disc_number}=\"$tags{disc_number}\"";
			$lenc_opts .= " $fmt_dst{enc_tags_opts}".
					" Part=\"$tags{disc_number}\"";
		}

		# Compression du fichier
		commande("'$enc_bin' $lenc_opts \"$fic_wav\" \"$fic_cps\"")
			or sortie_erreur("impossible de compresser le fichier $fic_wav");
	}

	# MP3
	elsif ( "$fmt_dst" eq "mp3" ) {

		# Mise en forme des tags
		$lenc_opts .= " $fmt_dst{enc_tags_opts}";
		if ( %tags ) {
			foreach my $tag ( keys %tags ) {
				next if ( $tag eq "track_number" );
				next if ( $tag eq "tracks_total" );
				next if ( $tag eq "disc_number" );
				next if ( $tag eq "discs_total" );
				$lenc_opts .= " $fmt_dst{tags}{$tag} \"$tags{$tag}\"";
			}
		}
		# Numéros de morceaux
		if ( defined $tags{track_number} ) {
			$tags{track_number} = "$tags{track_number}/$tags{tracks_total}"
				if ( defined $tags{tracks_total} );
			$lenc_opts .=
				" $fmt_dst{tags}{track_number} \"$tags{track_number}\"";
		}
		# Numéros de disques
		if ( defined $tags{disc_number} ) {
			$tags{disc_number} = "$tags{disc_number}/$tags{discs_total}"
				if ( defined $tags{discs_total} );
			$lenc_opts .= " $fmt_dst{tags}{disc_number}=\"$tags{disc_number}\"";
		}

		# Compression du fichier
		commande("'$enc_bin' $lenc_opts \"$fic_wav\"")
			or sortie_erreur("impossible de compresser le fichier $fic_wav");
	}
	msg_info("compression du fichier $fic_wav terminée");
	suppr_fic("$fic_wav");
	return "$fic_cps";
}

# Extrait les en-êtes utiles d'un fichier WAV
# et les renvoie sous forme de tableau
# Argument attendu : <le chemin du fichier>
sub extract_WAV_infos {
	my $fic_wav = shift;
	my ($fmt, $d);

	# Récupération des en-têtes
	sysopen WAV, "$fic_wav", O_RDONLY
		or sortie_erreur("impossible de lire le fichier $fic_wav");
	sysread WAV, $d, 12;
	sysread WAV, $fmt, 24;
	close WAV;
	my @infos = unpack("A4VvvVVvv", $fmt);

	# DEBUG
	# Une explication de tout ça ne fait pas de mal...
	#~ msg_debug("informations du fichier \"$fic_wav\" :");
	#~ msg_debug("                      format : $infos[0]");
	#~ msg_debug("                    longueur : $infos[1]");
	#~ msg_debug("                     inutile : $infos[2]");
	#~ msg_debug("                      canaux : $infos[3]");
	#~ msg_debug(" fréquence d'échantillonnage : $infos[4] Hz");
	#~ msg_debug("          octets par seconde : $infos[5]");
	#~ msg_debug("      octets par échantillon : $infos[6]");
	#~ msg_debug("        bits par échantillon : $infos[7]");
	# /DEBUG

	return (@infos);
}

# Rééchantillonne un fichier WAV à 48 kHz
# Argument attendu : <le chemin du fichier>
sub resample_wav {
	my $fic_wav = shift;

	# On tente un rééchantillonnage si on a ce qu'il faut
	my $sox_bin = chem_bin_ou_continue("sox");
	if ( $sox_bin ne "__inconnu__" ) {
		msg_info("rééchantillonnage");

		# Renommage. Le but est que le fichier en sortie
		# ait le même nom que le fichier en entrée.
		my $fic_entree = $fic_wav.".tmp.wav";
		rename ($fic_wav, $fic_entree)
			or sortie_erreur("impossible de renommer le fichier $fic_wav");

		# Commande, avec quelles options ?
		my $cmd = "'$sox_bin'";
		$cmd .= " $sox_v09_opts";
		if ( $verbose ) {
			$cmd .= " $sox_verb_opts";
		}
		else {
			$cmd .= " $sox_info_opts";
		}
		$cmd .= " \"$fic_entree\"";
		$cmd .= " $sox_r48_opts";
		$cmd .= " $sox_b16_opts";
		$cmd .= " \"$fic_wav\"";
		$cmd .= " rate";
		# /Commande. Pfffou, rien que ça.

		commande("$cmd")
			or sortie_erreur
				("impossible de rééchantillonner le fichier $fic_wav");

		suppr_fic("$fic_entree");
		return "$fic_wav";
	}
	else {
		msg_erreur("rééachantillonnage impossible");
		sortie_erreur("vous DEVEZ choisir un autre format");
	}
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
		-c|--fic_cue FICHIER
			indique le nom du fichier CUE (pour découpe d'un album en morceaux)
			(défaut : selon le nom du fichier source)
		-D|--debug
			active le mode debug
		-e|--empty
			supprime le fichier SOURCE après la compression
		-g|--noreplaygain
			désactive l'ajout des tags ReplayGain
		-I|--fmt_src FORMAT
			indique le format des fichiers si FICHIER est un répertoire
			(défaut : le format le plus représenté, ou $fmt_src)
		-O|--fmt_dst FORMAT
			indique le format des fichiers en fin de traitement
			(défaut : $fmt_dst)
		-o|--enc_opts "OPTIONS"
			indique des options supplémentaires à passer à l'encodeur
			(défaut : selon le format d'encodage choisi)
		-r|--src_is_rep
			indique que SOURCE est un répertoire (debug uniquement)
			(défaut : déterminé automatiquement)
		-v|--verbose
			active le mode bavard

	Note :
		SOURCE est le chemin du fichier ou du répertoire à traiter (obligatoire)

	Formats acceptés :
	- en décompression : $fdec
	- en compression : $fenc

	Exemples de paramètres à passer à l'encodeur :
	MP3/MPC : "--scale 0.8"

EOF
	exit 0;
}

# /Fonctions
####

## Traitement des arguments
my %lconfig;
GetOptions (
	'c|fic_cue=s'		=> \$lconfig{fic_cue},
	'D|debug'			=> \$lconfig{debug},
	'e|empty'			=> \$lconfig{empty},
	'g|noreplaygain'	=> \$lconfig{noreplaygain},
	'h|help'			=> \$lconfig{help},
	'I|fmt_src=s'		=> \$lconfig{fmt_src},
	'i|dec_opts=s'		=> \$lconfig{dec_opts},
	'O|fmt_dst=s'		=> \$lconfig{fmt_dst},
	'o|enc_opts=s'		=> \$lconfig{enc_opts},
	'r|src_is_rep'		=> \$lconfig{src_is_rep},
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
$fic_src = $ARGV[0];
$empty = 1 if ( defined $lconfig{empty} );

# Fichier ou répertoire ?
if ( defined $lconfig{src_is_rep} ) {
	$src_is_rep = 1;
	msg_verb("$fic_src est un répertoire (option forcée)");
}
else {
	$src_is_rep = fic_ou_rep("$fic_src");
}
$fic_src = File::Spec->rel2abs("$fic_src");

# DEBUG - test de fonction
#~ nom_m3u("$fic_src");
#~ exit 0;
# /DEBUG

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
$dec_bin = chem_bin("$fmt_src{dec_bin}");

# Format destination
$fmt_dst = int_format("$lconfig{fmt_dst}")
	if ( defined $lconfig{fmt_dst} );
msg_verb("format de sortie : $fmt_dst");
sortie_erreur("le format de sortie $fmt_dst n'est pas pris en charge")
	unless grep(/$fmt_dst/, @encformats);
%fmt_dst = %{$codecs{$fmt_dst}};
$enc_bin = chem_bin("$fmt_dst{enc_bin}");

# Fichier .CUE ?
# Par définition, n'est utile que dans le cas d'un album non découpé, et donc
# lorsqu'on donne un fichier, et pas un répertoire, à traiter au script.
if ( $src_is_rep == 0 ) {
	if ( defined $lconfig{fic_cue} ) {
		$fic_cue = fic_ou_rep("$lconfig{fic_cue}");
		msg_verb("fichier CUE donné : $fic_cue (option forcée)");
	}
	else {
		$fic_cue = recup_cue("$fic_src");
		msg_verb("fichier CUE trouvé : $fic_cue");
	}
	add_nl("$fic_cue");
	$split_bin = chem_bin("$split_bin");
}

# Options supplémentaires
$dec_opts = $lconfig{dec_opts} if ( defined $lconfig{dec_opts} );
$enc_opts = $lconfig{enc_opts} if ( defined $lconfig{enc_opts} );

# Désactivation des ajouts ReplayGain
#~ $noreplaygain = $lconfig{noreplaygain} if ( defined $lconfig{noreplaygain} );
$noreplaygain = 1 unless ( $debug );

# Arrivé ici, tout les arguments ont été traités, on peut commencer
my $fic_wav = decompress_src("$fic_src");

# Dirname. Ça servira par la suite
my $rep_wav = $fic_wav;
$rep_wav = dirname $fic_wav if ( -f "$fic_wav" );

# Découpage du fichier si besoin
split_wav("$fic_wav") if ( $src_is_rep == 0 );

# Et, arrivé ici, on a des fichiers WAV séparés, un par morceau
# Reste plus qu'à recompresser dans le format voulu
# Pour éviter les embrouilles, désormais, on transmet un nom de _répertoire_
compress_dest("$rep_wav");

# Ajout des tags ReplayGain, éventuellement
ajout_RGtags("$rep_wav") unless ( $noreplaygain );

# Fin de la fin
msg_info("mission accomplie :)");
print "\n";
exit 0;
