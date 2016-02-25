#!/usr/bin/env bash
#
#  Stacks workflow - process raw RADseq data all the way through Stacks pipline
#
#  Version 1.1.0 (June 16, 2015)
#
#  Copyright (c) 2014-2015 Andrew Krohn
#
#  This software is provided 'as-is', without any express or implied
#  warranty. In no event will the authors be held liable for any damages
#  arising from the use of this software.
#
#  Permission is granted to anyone to use this software for any purpose,
#  including commercial applications, and to alter it and redistribute it
#  freely, subject to the following restrictions:
#
#  1. The origin of this software must not be misrepresented; you must not
#     claim that you wrote the original software. If you use this software
#     in a product, an acknowledgment in the product documentation would be
#     appreciated but is not required.
#  2. Altered source versions must be plainly marked as such, and must not be
#     misrepresented as being the original software.
#  3. This notice may not be removed or altered from any source distribution.
#
## Trap function on exit.
function finish {
if [[ -f $stdout ]]; then
	rm -r $stdout
fi
if [[ -f $stderr ]]; then
	rm -r $stderr
fi
if [[ -f $idtemp ]]; then
	rm -r $idtemp
fi
if [[ -f $indtemp ]]; then
	rm -r $indtemp
fi
if [[ -f $poptemp ]]; then
	rm -r $poptemp
fi
if [[ -f $repfile ]]; then
	rm -r $repfile
fi
if [[ -f $popmap0 ]]; then
	rm -r $popmap0
fi
if [[ -f $popmap1 ]]; then
	rm -r $popmap1
fi
}
trap finish EXIT
#set -e

## Define inputs and working directory
	scriptdir="$(cd "$(dirname "$0")" && pwd)"
	repodir=`dirname $scriptdir`
	tempdir="$repodir/temp/"
	workdir=$(pwd)

	stdout=($1)
	stderr=($2)
	randcode=($3)
	config=($4)
	globallocal=($5)
	metadatafile0=($6)
	index=($7)
	read1=($8)
	read2=($9)

## If incorrect number of arguments supplied, display usage
	if [[ "$#" -le "7" ]] || [[ "$#" -ge "10" ]]; then
		cat $repodir/docs/demult-derep.usage
		exit 1
	fi

## Define sequencing mode based on number of supplied inputs
	if [[ -z "$9" ]]; then
	mode=(single)
	mode1=(SingleEnd)
	else
	mode=(paired)
	mode1=(PairedEnd)
	fi

## Define working directory and log file
	date0=`date +%Y%m%d_%I%M%p`
	date100=`date -R`
	outdir="$workdir/demult-derep_output"
	if [[ ! -d "$outdir" ]]; then
		mkdir -p $outdir
		log="${outdir}/log_demult-derep_${date0}.txt"
	else
		logtest=$(ls $outdir/log_demult-derep_* | wc -l)
		if [[ "$logtest" == "1" ]]; then
		log=$(ls $outdir/log_demult-derep_*)
		else
		log="${outdir}/log_demult-derep_${date0}.txt"
		fi
	fi

## Read in variables from config file
	cores=(`grep "CPU_cores" $config | grep -v "#" | cut -f 2`)
	threads=$(expr $cores + 1)
	qual=(`grep "Split_libraries_qvalue" $config | grep -v "#" | cut -f 2`)
	multx_errors=(`grep "Multx_errors" $config | grep -v "#" | cut -f 2`)
	slminpercent=(`grep "Split_libraries_minpercent" $config | grep -v "#" | cut -f 2`)

## Log demult-derep start
	res0=$(date +%s.%N)
echo "RADseq_utility demult-derep beginning.
Sequencing mode detected: $mode1
"
echo "RADseq_utility demult-derep beginning.
Sequencing mode detected: $mode1
" >> $log


## Parse metadata file contents
echo "Parsing metadata file contents.
"
	metabase=$(basename $metadatafile0)
	cp $metadatafile0 $outdir
	metadatafile="$outdir/$metabase"
	SampleIDcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "SampleID") printf(i) } exit 0}' $metadatafile)
	Indexcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "IndexSequence") printf(i) } exit 0}' $metadatafile)
	Repcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "Rep") printf(i) } exit 0}' $metadatafile)
	Popcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "PopulationID") printf(i) } exit 0}' $metadatafile)
	wait

## Extract data from metadata file
	#Demultiplexing file
	mapfile="$outdir/demultfile.txt"
	idtemp="$tempdir/${randcode}_sampleids.temp"
	indtemp="$tempdir/${randcode}_indexes.temp"
	poptemp="$tempdir/${randcode}_pops.temp"
	touch $tempdir/${randcode}_sampleids.temp
	grep -v "#" $metadatafile | cut -f${SampleIDcol} > $idtemp
	grep -v "#" $metadatafile | cut -f${Indexcol} > $indtemp
	grep -v "#" $metadatafile | cut -f${Popcol} > $poptemp
	wait
	paste $idtemp $indtemp > $mapfile
	wait

	if [[ ! -f $mapfile ]]; then
		echo "Unexpected problem. Demultiplexing map not generated. Check
your inputs and try again. Exiting.
		"
	exit 1
	fi

	#Dereplication file
	repfile="$tempdir/${randcode}_repids.temp"
	awk -v repcol="$Repcol" '$repcol == 1' $metadatafile | cut -f${SampleIDcol} | cut -f1 -d"." > $repfile

	#Initial populations file (non-dereplicated)
	popmap0="$tempdir/${randcode}_popids0.temp"
	paste $idtemp $poptemp > $popmap0

	#Populations file for dereplicated data
	popmap1="$tempdir/${randcode}_popids1.temp"
	popmap="$outdir/populations_file.txt"
	for line in `cat $repfile`; do
	grep $line.1 $popmap0 | cut -f2 >> $popmap1
	done
	paste $repfile $popmap1 > $popmap

## Demultiplex quality-filtered sequencing data with fastq-multx
	if [[ -d $outdir/demultiplexed_data ]]; then
		echo "Demultiplexing previously completed. Skipping step.
$outdir/demultiplexed_data
		"
	else
		echo "Demultiplexing raw data with fastq-multx.
		"
		echo "Demultiplexing raw data with fastq-multx.
		" >> $log
		res2=$(date +%s.%N)
		mkdir -p $outdir/demultiplexed_data
		echo "Demultiplexing command:" >> $log
	if [[ "$mode" == "single" ]]; then
		echo "fastq-multx -m $multx_errors -B $mapfile $index $read1 -o $outdir/demultiplexed_data/index.%.fq -o $outdir/demultiplexed_data/%.read.fq &> $outdir/demultiplexed_data/log_fastq-multx.txt
		" >> $log
		fastq-multx -m $multx_errors -B $mapfile $index $read1 -o $outdir/demultiplexed_data/index.%.fq -o $outdir/demultiplexed_data/%.read.fq &> $outdir/demultiplexed_data/log_fastq-multx.txt
	elif [[ "$mode" == "paired" ]]; then
		echo "fastq-multx -m $multx_errors -B $mapfile $index $read1 $read2 -o $outdir/demultiplexed_data/index.%.fq -o $outdir/demultiplexed_data/%.read1.fq -o $outdir/demultiplexed_data/%.read2.fq &> $outdir/demultiplexed_data/log_fastq-multx.txt
		" >> $log
		fastq-multx -m $multx_errors -B $mapfile $index $read1 $read2 -o $outdir/demultiplexed_data/index.%.fq -o $outdir/demultiplexed_data/%.read1.fq -o $outdir/demultiplexed_data/%.read2.fq &> $outdir/demultiplexed_data/log_fastq-multx.txt
	fi
		rm $outdir/demultiplexed_data/index.*
		rm $outdir/demultiplexed_data/unmatched*

	res3=$(date +%s.%N)
	dt=$(echo "$res3 - $res2" | bc)
	dd=$(echo "$dt/86400" | bc)
	dt2=$(echo "$dt-86400*$dd" | bc)
	dh=$(echo "$dt2/3600" | bc)
	dt3=$(echo "$dt2-3600*$dh" | bc)
	dm=$(echo "$dt3/60" | bc)
		ds=$(echo "$dt3-60*$dm" | bc)

	runtime=`printf "Demutliplexing runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
	echo "$runtime
	" >> $log
	fi

## Dereplicate samples if necessary
samplecount=$(grep -v "#" $metadatafile 2>/dev/null | wc -l)
repscount=$(awk -v repcol="$Repcol" '$repcol == 1' $metadatafile 2>/dev/null | wc -l)

	if [[ $samplecount == $repscount ]]; then
	reps="no"
	echo "No replicates detected. Skipping dereplication step.
	"
	else
	reps="yes"

	if [[ -d $outdir/dereplicated_data ]]; then
	echo "Dereplication previously completed. Skipping step.
$outdir/dereplicated_data
	"
	else
	mkdir -p $outdir/dereplicated_data

	for sampleid in `cat $repfile`; do
		cat $outdir/demultiplexed_data/${sampleid}*read1.fq > $outdir/dereplicated_data/${sampleid}.read1.fq
		cat $outdir/demultiplexed_data/${sampleid}*read2.fq > $outdir/dereplicated_data/${sampleid}.read2.fq
	done

	fi
	fi

## Quality filter sequencing data with fastq-mcf
	if [[ -d $outdir/quality_filtered_data ]]; then
	echo "Quality filtering previously performed. Skipping step.
$outdir/quality_filtered_data
	"
	else
	seqlength=$((`sed '2q;d' $read1 | egrep "\w+" | wc -m`-1))
	length=$(echo "$slminpercent*$seqlength" | bc | cut -d. -f1)
	echo "Quality filtering raw data with fastq-mcf.
Read lengths detected: $seqlength
Minimum quality threshold: $qual
Minimum length to retain: $length
	"
	echo "Quality filtering raw data with fastq-mcf.
Read lengths detected: $seqlength
Minimum quality threshold: $qual
Minimum length to retain: $length
	" >> $log
	res2=$(date +%s.%N)
	mkdir -p $outdir/quality_filtered_data
		if [[ "$mode" == "single" ]]; then
	for line in `cat $mapfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/demultiplexed_data/$line.read.fq -o $outdir/quality_filtered_data/$line.read.mcf.fq" >> $log
		( fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/demultiplexed_data/$line.read.fq -o $outdir/quality_filtered_data/$line.read.mcf.fq > $outdir/quality_filtered_data/log_${line}_fastq-mcf.txt 2>&1 || true ) &
	done
		fi
		if [[ "$mode" == "paired" ]]; then
	for line in `cat $mapfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/demultiplexed_data/$line.read1.fq $outdir/demultiplexed_data/$line.read2.fq -o $outdir/quality_filtered_data/$line.read1.mcf.fq -o $outdir/quality_filtered_data/$line.read2.mcf.fq" >> $log
		( fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/demultiplexed_data/$line.read1.fq $outdir/demultiplexed_data/$line.read2.fq -o $outdir/quality_filtered_data/$line.read1.mcf.fq -o $outdir/quality_filtered_data/$line.read2.mcf.fq > $outdir/quality_filtered_data/log_${line}_fastq-mcf.txt 2>&1 || true ) &
	done
		fi
wait

	if [[ $reps == "yes" ]]; then
		if [[ ! -d $outdir/dereplicated_quality_filtered_data ]]; then
			mkdir -p $outdir/dereplicated_quality_filtered_data

	if [[ "$mode" == "single" ]]; then
	for line in `cat $repfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/dereplicated_data/$line.read.fq -o $outdir/dereplicated_quality_filtered_data/$line.read.mcf.fq" >> $log
		( fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/dereplicated_data/$line.read.fq -o $outdir/dereplicated_quality_filtered_data/$line.read.mcf.fq > $outdir/dereplicated_quality_filtered_data/log_${line}_fastq-mcf.txt 2>&1 || true ) &
	done
	fi
	if [[ "$mode" == "paired" ]]; then
	for line in `cat $repfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/dereplicated_data/$line.read1.fq $outdir/dereplicated_data/$line.read2.fq -o $outdir/dereplicated_quality_filtered_data/$line.read1.mcf.fq -o $outdir/dereplicated_quality_filtered_data/$line.read2.mcf.fq" >> $log
		( fastq-mcf -q $qual -l $length -L $length -k 0 -t 0.001 $adapters $outdir/dereplicated_data/$line.read1.fq $outdir/dereplicated_data/$line.read2.fq -o $outdir/dereplicated_quality_filtered_data/$line.read1.mcf.fq -o $outdir/dereplicated_quality_filtered_data/$line.read2.mcf.fq > $outdir/dereplicated_quality_filtered_data/log_${line}_fastq-mcf.txt 2>&1 || true ) &
	done
	fi
wait

		fi
	fi

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Quality filtering runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

## Join and concatenate separate fastq files (denovo analysis only) ## Stacks is choking on variable length reads. Combine only.
## Combine separate read files
res2=$(date +%s.%N)
if [[ "$analysis" == "denovo" && "$mode" == "paired" ]]; then
if [[ ! -d $outdir/combined_data || ! -d $outdir/dereplicated_combined_data ]]; then
	if [[ -d $outdir/combined_data ]]; then
echo "Combining previously performed. Skipping step.
$outdir/combined_data
"
else
echo "Combining read data.
"
echo "Combining read data.
" >> $log
	mkdir -p $outdir/combined_data
	for sampleid in `cat $tempdir/${randcode}_sampleids.temp`; do
	echo "	cat $outdir/quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/quality_filtered_data/${sampleid}.read2.mcf.fq > $outdir/combined_data/${sampleid}.fq" >> $log
	cat $outdir/quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/quality_filtered_data/${sampleid}.read2.mcf.fq > $outdir/combined_data/${sampleid}.fq
	done
	echo "" >> $log
	fi

	if [[ $reps == "yes" ]]; then
	if [[ -d $outdir/dereplicated_combined_data ]]; then
echo "Combining previously performed (dereplicated data). Skipping step.
$outdir/dereplicated_combined_data
"
else
echo "Combining read data (dereplicated data).
"
echo "Combining read data (dereplicated data).
" >> $log
	mkdir -p $outdir/dereplicated_combined_data
	for sampleid in `cat $tempdir/${randcode}_derep_ids.temp`; do
	echo "	cat $outdir/dereplicated_quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/dereplicated_quality_filtered_data/${sampleid}.read2.mcf.fq > $outdir/dereplicated_combined_data/${sampleid}.fq" >> $log
	cat $outdir/dereplicated_quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/dereplicated_quality_filtered_data/${sampleid}.read2.mcf.fq > $outdir/dereplicated_combined_data/${sampleid}.fq
	done
	echo "" >> $log
	fi
	fi



res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Read combining runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi
fi
