# audioconvert
Script de conversion automatisée de fichiers son d'un format à un autre.

Destiné à mon usage personnel, il fait les choix qui me conviennent, et ces choix ne conviendront pas nécessairement à tout le monde...

## Usage
```
audioconvert -h
audioconvert [ <options> ] SOURCE
```

Options :
```
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
        (défaut : le format le plus représenté, ou flac)

     -i|--dec_opts "OPTIONS"
        indique des options supplémentaires à passer au décodeur
        (défaut : -bitexact -acodec pcm_s16le -ar 44100 -y)

     -O|--fmt_dst FORMAT
        indique le format des fichiers en fin de traitement
        (défaut : musepack7)

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
```

Note :
        SOURCE est le chemin du fichier ou du répertoire à traiter (obligatoire)

Exemples d'options à passer à l'encodeur :
```
MP3/MPC : "--scale 0.8"
```

## Formats acceptés
- en décompression : alac, ape, dsd, flac, mp3, musepack7, musepack8, opus, vorbis, wav, wavpack
- en compression : flac, mp3, musepack7, musepack8, opus, vorbis, wav


## Dépendances
Ce script a besoin d'un certain nombre de dépendances en fonction des actions demandées :
- compression, écriture des tags (+ReplayGain) : selon le format
- décompression : ffmpeg
- découpage (WAV) : bchunk
- calcul anti-clipping : metaflac
- extraction des tags : module perl Audio::Scan

