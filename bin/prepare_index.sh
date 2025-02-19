#!/usr/bin/env sh
#
# Copyright © 2022 Ye Chang yech1990@gmail.com
# Distributed under terms of the GNU license.
#
# Created: 2022-04-20 22:28

dbpath="https://raw.githubusercontent.com/y9c/m6A-SACseq/main/db"
species="human"
outdir="ref"
logfile="$outdir/indexing.log"
threads=16

if command -v axel >/dev/null 2>&1; then
  downloader="axel -n ${threads} -q -o"
else
  downloader="wget -q -O"
fi

# TODO: let docker to do this, since user might not hve STAR, bowtie2 installed
if ! command -v samtools >/dev/null 2>&1; then
  echo "samtools shold be installed"
  exit 1
fi
if ! command -v makeblastdb >/dev/null 2>&1; then
  echo "BLAST (makeblastdb) shold be installed"
  exit 1
fi

if ! command -v bowtie2-build >/dev/null 2>&1; then
  echo "bowtie2 (bowtie2-build) shold be installed"
  exit 1
fi

if ! command -v STAR >/dev/null 2>&1; then
  echo "STAR shold be installed"
  exit 1
fi

usage_error() {
  echo >&2 "$(basename $0):  $1"
  exit 2
}
assert_argument() { test "$1" != "$EOL" || usage_error "$2 requires an argument"; }

# One loop, nothing more.
if [ "$#" != 0 ]; then
  EOL=$(echo '\01\03\03\07')
  set -- "$@" "$EOL"
  while [ "$1" != "$EOL" ]; do
    opt="$1"
    shift
    case "$opt" in

    # Your options go here.
    -q | --quite) quite='true' ;;
    -t | --threads)
      assert_argument "$1" "$opt"
      threads="$1"
      shift
      ;;
    -s | --species)
      assert_argument "$1" "$opt"
      species="$1"
      shift
      ;;
    -i | --spikein)
      assert_argument "$1" "$opt"
      spikein="$1"
      shift
      ;;
    -o | --outdir)
      assert_argument "$1" "$opt"
      outdir="$1"
      shift
      ;;

    # Arguments processing. You may remove any unneeded line after the 1st.
    - | '' | [!-]*) set -- "$@" "$opt" ;;                             # positional argument, rotate to the end
    --*=*) set -- "${opt%%=*}" "${opt#*=}" "$@" ;;                    # convert '--name=arg' to '--name' 'arg'
    -[!-]?*) set -- $(echo "${opt#-}" | sed 's/\(.\)/ -\1/g') "$@" ;; # convert '-abc' to '-a' '-b' '-c'
    --) while [ "$1" != "$EOL" ]; do
      set -- "$@" "$1"
      shift
    done ;;                                             # process remaining arguments as positional
    -*) usage_error "unknown option: '$opt'" ;;         # catch misspelled options
    *) usage_error "this should NEVER happen ($opt)" ;; # sanity test for previous patterns

    esac
  done
  shift # $EOL
fi

download_db() {
  # Download the database (gz compressed file).
  local inurl="$1"
  local outfile="$2"
  if [ -f "${outfile}" ]; then
    echo "Reference file: ${outfile} exist. Do you want overwrite it? (y/N)"
    local yn="N"
    read yn
    if [ "$yn" = "${yn#[Nn]}" ]; then
      return
    fi
  fi
  echo "$(date -u)  Downloading db: ${outfile} from ${inurl}"
  ${downloader} ${outfile}.gz ${inurl} 2>&1 >>${logfile}
  gunzip -f ${outfile}.gz 2>&1 >>${logfile}
}

if [ -d "${outdir}" ]; then
  echo "Directory ${outdir} exist. Do you want overwrite it? (Y/n)"
  yn="Y"
  read yn
  if [ "$yn" != "${yn#[Nn]}" ]; then
    exit 0
  fi
else
  echo "The referece directory is not exist. Creating a new one..."
  mkdir -p "${outdir}"
fi

echo "$(date -u)  Start to build index..." >${logfile}

## prepare spike index
echo "$(date -u)  Preparing spike index..."
if [ -z ${spikein+x} ]; then
  cat <<EOF >${outdir}/spike_degenerate.fa
>probe_0
TATCTGTCTCGACGTNNANNGGCCTTTGCAACTAGAATTACACCATAATTGCT
>probe_25
TATCTGTCTCGACGTNNANNGGCATTCAAGCCTAGAATTACACCATAATTGCT
>probe_50
TATCTGTCTCGACGTNNANNGGCGAGGTGATCTAGAATTACACCATAATTGCT
>probe_75
TATCTGTCTCGACGTNNANNGGCTTCAACAACTAGAATTACACCATAATTGCT
>probe_100
TATCTGTCTCGACGTNNANNGGCGATGGTTTCTAGAATTACACCATAATTGCT
EOF
else
  cp $spike ${outdir}/spike_degenerate.fa
fi
makeblastdb -in ${outdir}/spike_degenerate.fa -dbtype nucl -out ${outdir}/spike_degenerate 2>&1 >>${logfile}
# expand ATGC
cat ${outdir}/spike_degenerate.fa |
  paste - - |
  awk 'BEGIN{Ns["A"]=1;Ns["T"]=2;Ns["G"]=3;Ns["C"]=4}{split($2,a,"NN");for(b1 in Ns)for(b2 in Ns)for(b3 in Ns)for(b4 in Ns)print $1"_"b1""b2"_"b3""b4"\n"a[1]""b1""b2""a[2]""b3""b4""a[3]}' >${outdir}/spike_expand.fa
bowtie2-build --threads {threads} ${outdir}/spike_expand.fa ${outdir}/spike_expand 1>>${logfile} 2>>${logfile}

# prepare contamination index
echo "$(date -u)  Preparing contamination index..."
download_db "${dbpath}/contamination.fa.gz" ${outdir}/contamination.fa
bowtie2-build --threads {threads} ${outdir}/contamination.fa ${outdir}/contamination 1>>${logfile} 2>>${logfile}

# prepare rRNA/ smallRNA/ genome index (base on different species)
if [ "$species" = "human" ]; then
  species_prefix="Homo_sapiens.GRCh38"
  url_gtf="http://ftp.ensembl.org/pub/release-106/gtf/homo_sapiens/Homo_sapiens.GRCh38.106.gtf.gz"
  url_fa="http://ftp.ensembl.org/pub/release-106/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna_sm.primary_assembly.fa.gz"
elif [ "$species" = "mouse" ]; then
  species_prefix="Mus_musculus.GRCm38"
  url_gtf="http://ftp.ensembl.org/pub/release-106/gtf/mus_musculus/Mus_musculus.GRCm39.106.gtf.gz"
  url_fa="http://ftp.ensembl.org/pub/release-106/fasta/mus_musculus/dna/Mus_musculus.GRCm39.dna_sm.primary_assembly.fa.gz"
else
  echo "ERROR: Only support human/mouse in current version"
  exit 0
fi

# prepare sncRNA index
echo "$(date -u)  Preparing index for rRNA + tRNA + snoRNA + snRNA + other non coding RNA (${species}) ..."
# prepare fa file
download_db "${dbpath}/${species_prefix}.sncRNA.fa.gz" ${outdir}/sncRNA_${species}.fa
# prepare fai file
samtools faidx ${outdir}/sncRNA_${species}.fa 2>&1 >>${logfile}
bowtie2-build --threads {threads} ${outdir}/sncRNA_${species}.fa ${outdir}/sncRNA_${species} 1>>${logfile} 2>>${logfile}

# prepare genome index
echo "$(date -u)  Preparing index for genomne (${species}) ..."
# prepare fa file
download_db ${url_fa} ${outdir}/genome_${species}.fa
# prepare fai file
samtools faidx ${outdir}/genome_${species}.fa 2>&1 >>${logfile}
# prepare gtf file
download_db ${url_gtf} ${outdir}/genome_${species}.gtf
# collpase gtf (TODO: check if python packages are installed)
wget -qO ${outdir}/collapse_annotation.py https://raw.githubusercontent.com/broadinstitute/gtex-pipeline/master/gene_model/collapse_annotation.py 1>>${logfile} 2>>${logfile}
python3 ${outdir}/collapse_annotation.py ${outdir}/genome_${species}.collapse.gtf ${outdir}/genome_${species}.gtf 1>>${logfile} 2>>${logfile}
rm "${outdir}/collapse_annotation.py"
# build star index
mkdir -p ${outdir}/genome_${species}
STAR --runThreadN ${threads} \
  --outTmpDir ${outdir}/genome_${species}_STARtmp \
  --runMode genomeGenerate \
  --limitGenomeGenerateRAM=55000000000 \
  --genomeDir ${outdir}/genome_${species} \
  --sjdbGTFfile ${outdir}/genome_${species}.gtf \
  --genomeFastaFiles ${outdir}/genome_${species}.fa 1>>${logfile} 2>>${logfile}

echo "\nCOPY THE CONFIGURE BELLOW"
echo "         ↓ ↓ ↓         \n"
echo '\033[0;32m'
echo "references:"
echo "  spike:"
echo "    fa: ${outdir}/spike_expand.fa"
echo "    bt2: ${outdir}/spike_expand"
echo "  spikeN:"
echo "    fa: ${outdir}/spike_degenerate.fa"
echo "    blast: ${outdir}/spike_degenerate"
echo "  contamination:"
echo "    fa: ${outdir}/contamination.fa"
echo "    bt2: ${outdir}/contamination"
echo "  sncRNA:"
echo "    fa: ${outdir}/sncRNA_${species}.fa"
echo "    fa: ${outdir}/sncRNA_${species}.fa.fai"
echo "    bt2: ${outdir}/sncRNA_${species}"
echo "  genome:"
echo "    fa: ${outdir}/genome_${species}.fa"
echo "    fai: ${outdir}/genome_${species}.fa.fai"
echo "    gtf: ${outdir}/genome_${species}.gtf"
echo "    gtf_collapse: ${outdir}/genome_${species}.collapse.gtf"
echo "    star: ${outdir}/genome_${species}"
echo '\033[0m'
