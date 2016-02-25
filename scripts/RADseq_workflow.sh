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
if [[ -f $mapfile ]]; then
	rm -r $tempdir
fi
}
trap finish EXIT

set -e

	scriptdir="$(cd "$(dirname "$0")" && pwd)"
	repodir=`dirname $scriptdir`
	tempdir="$repodir/temp/"
	workdir=$(pwd)
	akutilspath=`command -v akutils`
	akutilsscriptdir="$(dirname $akutilspath)"
	akutilsrepodir="$(dirname $akutilsscriptdir)"
	randcode=`cat /dev/urandom |tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1` 2>/dev/null

## Check whether user had supplied -h or --help. If yes display help 
	if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
	less $scriptdir/docs/RADseq_workflow.help
	exit 0
	fi 

## If different than 5 or 6 arguments supplied, display usage 
	if [[  "$#" -le 4 ]] || [[  "$#" -ge 7 ]]; then 
		echo "
Usage (order is important):
RADseq_workflow.sh <databasename> <sample mapping file> <reference> <index_fastq> <read1_fastq> <read2_fastq>

	<databasename> should NOT include \"_radtags\" suffix

	<read2_fastq> is optional

	<reference> is absolute path to bowtie2-indexed reference or 
	specify \"denovo\" for denovo analysis

Mapping file must be in the following format:
Sample1	AAAATTTTCCCCGGGG
Sample2	ATATTATACGCGGCGC

Where sample names and index sequences are separated by a tab character.
		"
		exit 1
	fi

## Define inputs and working directory
	dbname=($1)
	metadatafile=($2)
	ref=($3)
	index=($4)
	read1=($5)
	read2=($6)
	issuedcommand="RADseq_workflow.sh $1 $2 $3 $4 $5 $6"

## Define sequencing mode based on number of supplied inputs
	if [[ "$#" == 5 ]]; then
	mode=(single)
	mode1=(SingleEnd)
	elif [[ "$#" == 6 ]]; then
	mode=(paired)
	mode1=(PairedEnd)
	fi

## Determine analysis mode based user input
	if [[  "$ref" == "denovo" ]]; then
	analysis="denovo"
	analysis1="De novo"
	else
	analysis="reference"
	analysis1="Reference-based"
	fi

## Define database names
	if [[  "$ref" == "denovo" ]]; then
	dbunc=(${dbname}_denovo_uncor_radtags)
	dbuncderep=(${dbname}_denovo_uncor_derep_radtags)
	dbcor=(${dbname}_denovo_cor_radtags)
	dbcorderep=(${dbname}_denovo_cor_derep_radtags)
	else
	dbunc=(${dbname}_ref_uncor_radtags)
	dbuncderep=(${dbname}_ref_uncor_derep_radtags)
	dbcor=(${dbname}_ref_cor_radtags)
	dbcorderep=(${dbname}_ref_cor_derep_radtags)
	fi

## Batch variable (may need to update for flexibility)
	batch="1"

## Define working directory and log file
	date0=`date +%Y%m%d_%I%M%p`
	date100=`date -R`
	outdir="$workdir/RADseq_workflow_${analysis}"
	outdirunc=($outdir/uncorrected_output)
	outdircor=($outdir/corrected_output)
	if [[ -d $outdir ]]; then
	echo "
Output directory already exists.  Attempting to use previously generated
ouputs.
	"
	log=`ls $outdir/log_RADseq_workflow_* | head -1`
	echo "
********************************************************************************
********************************************************************************

RADseq_workflow.sh was rerun.
$date100

Command as issued:
	$issuedcommand

********************************************************************************
********************************************************************************
	" >> $log
	else
	mkdir -p $outdir
	log=($outdir/log_RADseq_workflow_${date0})
	touch $log
	echo "
********************************************************************************
********************************************************************************

RADseq_workflow.sh was run.
$date100

Command as issued:
	$issuedcommand

********************************************************************************
********************************************************************************
	" >> $log
	fi

## Read in variables from config file
	local_config_count=(`ls akutils*.config 2>/dev/null | wc -w`)
	if [[ $local_config_count -ge 1 ]]; then
	config=`ls akutils*.config`
	echo "Using local akutils config file.
$config
	"
	echo "
Referencing local akutils config file.
$config
	" >> $log
	else
		global_config_count=(`ls $akutilsrepodir/akutils_resources/akutils*.config 2>/dev/null | wc -w`)
		if [[ $global_config_count -ge 1 ]]; then
		config=`ls $akutilsrepodir/akutils_resources/akutils*.config`
		echo "Using global akutils config file.
$config
		"
		echo "
Referencing global akutils config file.
$config
		" >> $log
		fi
	fi

	cores=(`grep "CPU_cores" $config | grep -v "#" | cut -f 2`)
	threads=$(expr $cores + 1)
	qual=(`grep "Split_libraries_qvalue" $config | grep -v "#" | cut -f 2`)
	multx_errors=(`grep "Multx_errors" $config | grep -v "#" | cut -f 2`)
	slminpercent=(`grep "Split_libraries_minpercent" $config | grep -v "#" | cut -f 2`)

res0=$(date +%s.%N)
echo "RADseq workflow beginning.
Sequencing mode detected: $mode1
Analysis type: $analysis1
CPU cores: $cores
"

## Parse metadata file contents
SampleIDcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "SampleID") printf(i) } exit 0}' $metadatafile)
Indexcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "IndexSequence") printf(i) } exit 0}' $metadatafile)
Repcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "Rep") printf(i) } exit 0}' $metadatafile)
Popcol=$(awk '{for(i=1; i<=NF; i++) {if($i == "PopulationID") printf(i) } exit 0}' $metadatafile)
wait

## Extract data from metadata file
	#Demultiplexing file
mapfile="$tempdir/${randcode}_map.temp"
touch $tempdir/${randcode}_sampleids.temp
grep -v "#" $metadatafile | cut -f${SampleIDcol} > $tempdir/${randcode}_sampleids.temp
grep -v "#" $metadatafile | cut -f${Indexcol} > $tempdir/${randcode}_indexes.temp
grep -v "#" $metadatafile | cut -f${Popcol} > $tempdir/${randcode}_pops.temp
wait
paste $tempdir/${randcode}_sampleids.temp $tempdir/${randcode}_indexes.temp > $mapfile
wait

	if [[ ! -f $mapfile ]]; then
		echo "Unexpected problem.  Demultiplexing map not generated.
Exiting.
		"
	exit 1
	fi

	#Dereplication file
repfile="$tempdir/${randcode}_repids.temp"
repfile1="$tempdir/${randcode}_repids1.temp"
awk -v repcol="$Repcol" '$repcol == 1' $metadatafile | cut -f${SampleIDcol} | cut -f1 -d"." > $repfile
awk -v repcol="$Repcol" '$repcol == 1' $metadatafile > $repfile1

	#Populations file
popmap="$tempdir/${randcode}_popids.temp"
popmap1="$tempdir/${randcode}_popids1.temp"
paste $tempdir/${randcode}_sampleids.temp $tempdir/${randcode}_pops.temp 2>/dev/null > $popmap

	#Populations file for dereplicated data
cat $repfile1 | cut -f${SampleIDcol} | cut -f1 -d"." > $tempdir/${randcode}_derep_ids.temp
cat $repfile1 | cut -f${Popcol} | cut -f1 -d"." > $tempdir/${randcode}_derep_pops.temp
paste $tempdir/${randcode}_derep_ids.temp $tempdir/${randcode}_derep_pops.temp 2>/dev/null > $popmap1

## Demultiplex quality-filtered sequencing data with fastq-multx
if [[ -d $outdir/demultiplexed_data ]]; then
echo "Demultiplexing previously completed.  Skipping step.
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
	echo "No replicates detected.  Skipping dereplication step.
	"
	else
	reps="yes"

	if [[ -d $outdir/dereplicated_data ]]; then
	echo "Dereplication previously completed.  Skipping step.
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
echo "Quality filtering previously performed.  Skipping step.
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
echo "Combining previously performed.  Skipping step.
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
echo "Combining previously performed (dereplicated data).  Skipping step.
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

#if [[ ! -d $outdir/joined_data || ! -d $outdir/dereplicated_joined_data ]]; then
#	if [[ -d $outdir/joined_data ]]; then
#echo "Joining/combining previously performed.  Skipping step.
#$outdir/joined_data
#"
#else
#echo "Joining read data with fastq-join (-p 10 -m 20).
#"
#echo "Joining read data with fastq-join (-p 10 -m 20).
#" >> $log
#	mkdir -p $outdir/joined_data
#	for sampleid in `cat $tempdir/${randcode}_sampleids.temp`; do
#	echo "	fastq-join -m 20 $outdir/quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/quality_filtered_data/${sampleid}.read2.mcf.fq -o $outdir/joined_data/${sampleid}.%.fq &> $outdir/joined_data/${sampleid}.fqjoin.log" >> $log
#	echo "SampleID: $sampleid" > $outdir/joined_data/${sampleid}.fqjoin.log
#	fastq-join -m 20 $outdir/quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/quality_filtered_data/${sampleid}.read2.mcf.fq -o $outdir/joined_data/${sampleid}.%.fq &>> $outdir/joined_data/${sampleid}.fqjoin.log
#	cat $outdir/joined_data/${sampleid}.join.fq $outdir/joined_data/${sampleid}.un1.fq $outdir/joined_data/${sampleid}.un2.fq > $outdir/joined_data/${sampleid}.fq
#	wait
#	rm $outdir/joined_data/${sampleid}.join.fq $outdir/joined_data/${sampleid}.un1.fq $outdir/joined_data/${sampleid}.un2.fq
#	done
#	echo "" >> $log
#	fi

#	if [[ $reps == "yes" ]]; then
#	if [[ -d $outdir/dereplicated_joined_data ]]; then
#echo "Joining/combining previously performed (dereplicated data).  Skipping step.
#$outdir/dereplicated_joined_data
#"
#else
#echo "Joining read data with fastq-join (dereplicated data, -p 10 -m 20).
#"
#echo "Joining read data with fastq-join (dereplicated data, -p 10 -m 20).
#" >> $log
#	mkdir -p $outdir/dereplicated_joined_data
#	for sampleid in `cat $tempdir/${randcode}_derep_ids.temp`; do
#	echo "	fastq-join -m 20 $outdir/dereplicated_quality_filtered_data/${sampleid}.read1.mcf.fq $outdirdereplicated_/quality_filtered_data/${sampleid}.read2.mcf.fq -o $outdir/dereplicated_joined_data/${sampleid}.%.fq &> $outdir/dereplicated_joined_data/${sampleid}.fqjoin.log" >> $log
#	echo "SampleID: $sampleid" > $outdir/dereplicated_joined_data/${sampleid}.fqjoin.log
#	fastq-join -m 20 $outdir/dereplicated_quality_filtered_data/${sampleid}.read1.mcf.fq $outdir/dereplicated_quality_filtered_data/${sampleid}.read2.mcf.fq -o $outdir/dereplicated_joined_data/${sampleid}.%.fq &>> $outdir/dereplicated_joined_data/${sampleid}.fqjoin.log
#	cat $outdir/dereplicated_joined_data/${sampleid}.join.fq $outdir/dereplicated_joined_data/${sampleid}.un1.fq $outdir/dereplicated_joined_data/${sampleid}.un2.fq > $outdir/dereplicated_joined_data/${sampleid}.fq
#	wait
#	rm $outdir/dereplicated_joined_data/${sampleid}.join.fq $outdir/dereplicated_joined_data/${sampleid}.un1.fq $outdir/dereplicated_joined_data/${sampleid}.un2.fq
#	done
#	echo "" >> $log
#	fi
#	fi

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Read joining runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi
fi

## Align each sample to reference (reference-based analysis only)
res2=$(date +%s.%N)
if [[ "$analysis" == "reference" ]]; then
if [[ ! -d $outdir/bowtie2_alignments || ! -d $outdir/dereplicated_bowtie2_alignments ]]; then
if [[ -d $outdir/bowtie2_alignments ]]; then
echo "Alignments previously performed.  Skipping step.
$outdir/bowtie2_alignments
"
else
echo "Aligning quality-filtered data to reference sequence(s).
Supplied reference: $ref
"
echo "Aligning quality-filtered data to reference sequence(s).
Supplied reference: $ref
" >> $log
mkdir -p $outdir/bowtie2_alignments
	if [[ "$mode" == "single" ]]; then
	for line in `cat $mapfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	bowtie2-align --local -x $ref -U $outdir/quality_filtered_data/${line}.read.mcf.fq -S $outdir/bowtie2_alignments/${line}.sam > $outdir/bowtie2_alignments/log_${line}_bowtie2.txt" >> $log
		( bowtie2-align --local -x $ref -U $outdir/quality_filtered_data/${line}.read.mcf.fq -S $outdir/bowtie2_alignments/${line}.sam > $outdir/bowtie2_alignments/log_${line}_bowtie2.txt 2>&1 || true ) &
	done
	fi
	if [[ "$mode" == "paired" ]]; then
	for line in `cat $mapfile | cut -f1`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	bowtie2-align --local -x $ref -1 $outdir/quality_filtered_data/${line}.read1.mcf.fq -2 $outdir/quality_filtered_data/${line}.read2.mcf.fq -S $outdir/bowtie2_alignments/${line}.sam > $outdir/bowtie2_alignments/log_${line}_bowtie2.txt" >> $log
		( bowtie2-align --local -x $ref -1 $outdir/quality_filtered_data/${line}.read1.mcf.fq -2 $outdir/quality_filtered_data/${line}.read2.mcf.fq -S $outdir/bowtie2_alignments/${line}.sam > $outdir/bowtie2_alignments/log_${line}_bowtie2.txt 2>&1 || true ) &
	done
	fi
wait
fi

if [[ -d $outdir/dereplicated_bowtie2_alignments ]]; then
echo "Alignments previously performed (dereplicated data).  Skipping step.
$outdir/dereplicated_bowtie2_alignments
"
else
echo "Aligning dereplicated quality-filtered data to reference sequence(s).
Supplied reference: $ref
"
echo "Aligning dereplicated quality-filtered data to reference sequence(s).
Supplied reference: $ref
" >> $log
mkdir -p $outdir/dereplicated_bowtie2_alignments
	if [[ "$mode" == "single" ]]; then
	for line in `cat $repfile`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	bowtie2-align --local -x $ref -U $outdir/dereplicated_quality_filtered_data/${line}.read.mcf.fq -S $outdir/dereplicated_bowtie2_alignments/${line}.sam > $outdir/dereplicated_bowtie2_alignments/log_${line}_bowtie2.txt" >> $log
		( bowtie2-align --local -x $ref -U $outdir/dereplicated_quality_filtered_data/${line}.read.mcf.fq -S $outdir/dereplicated_bowtie2_alignments/${line}.sam > $outdir/dereplicated_bowtie2_alignments/log_${line}_bowtie2.txt 2>&1 || true ) &
	done
	fi
	if [[ "$mode" == "paired" ]]; then
	for line in `cat $repfile`; do
		while [ $( pgrep -P $$ |wc -w ) -ge ${threads} ]; do
		sleep 1
		done
		echo "	bowtie2-align --local -x $ref -1 $outdir/dereplicated_quality_filtered_data/${line}.read1.mcf.fq -2 $outdir/dereplicated_quality_filtered_data/${line}.read2.mcf.fq -S $outdir/dereplicated_bowtie2_alignments/${line}.sam > $outdir/dereplicated_bowtie2_alignments/log_${line}_bowtie2.txt" >> $log
		( bowtie2-align --local -x $ref -1 $outdir/dereplicated_quality_filtered_data/${line}.read1.mcf.fq -2 $outdir/dereplicated_quality_filtered_data/${line}.read2.mcf.fq -S $outdir/dereplicated_bowtie2_alignments/${line}.sam > $outdir/dereplicated_bowtie2_alignments/log_${line}_bowtie2.txt 2>&1 || true ) &
	done
	fi
wait
fi

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Reference alignment runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi
fi

###################################
## START OF UNCORRECTED ANALYSIS ##
###################################
echo "Start of uncorrected analysis steps.
"
echo "Start of uncorrected analysis steps.
" >> $log

## Run pstacks for reference-aligned samples
res2=$(date +%s.%N)
if [[ "$analysis" == "reference" ]]; then
	if [[ ! -d $outdirunc/pstacks_output || ! -d $outdirunc/dereplicated_pstacks_output ]]; then
		if [[ -d $outdirunc/pstacks_output ]]; then
echo "Pstacks output directory present.  Skipping step.
$outdirunc/pstacks_output
"
else
echo "Extracting stacks from sam files with pstacks.
"
echo "Extracting stacks from sam files with pstacks.
" >> $log
mkdir -p $outdirunc/pstacks_output
#i=1
	for line in `cat $mapfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  pstacks -t sam -f $outdir/bowtie2_alignments/${line}.aligned.sam -p $cores -o $outdirunc/pstacks_output -i $sqlid" >> $log
	pstacks -t sam -f $outdir/bowtie2_alignments/${line}.sam -p $cores -o $outdirunc/pstacks_output -i $sqlid &> $outdirunc/pstacks_output/log_${line}_pstacks.txt
	#let "i+=1"
	done
		fi

		if [[ $reps == "yes" ]]; then
			if [[ -d $outdirunc/dereplicated_pstacks_output ]]; then
echo "Pstacks output directory present (dereplicated data).  Skipping step.
$outdirunc/dereplicated_pstacks_output
"
else
echo "Extracting stacks from sam files with pstacks (dereplicated data).
"
echo "Extracting stacks from sam files with pstacks (dereplicated data).
" >> $log
mkdir -p $outdirunc/dereplicated_pstacks_output
	for line in `cat $repfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  pstacks -t sam -f $outdir/dereplicated_bowtie2_alignments/${line}.aligned.sam -p $cores -o $outdirunc/dereplicated_pstacks_output -i $sqlid" >> $log
	pstacks -t sam -f $outdir/dereplicated_bowtie2_alignments/${line}.sam -p $cores -o $outdirunc/dereplicated_pstacks_output -i $sqlid &> $outdirunc/dereplicated_pstacks_output/log_${line}_pstacks.txt
	done
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

runtime=`printf "Pstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
	fi
fi

## Run ustacks for denovo samples
res2=$(date +%s.%N)
if [[ "$analysis" == "denovo" ]]; then
	if [[ ! -d $outdirunc/ustacks_output || ! -d $outdirunc/dereplicated_ustacks_output ]]; then
		if [[ -d $outdirunc/ustacks_output ]]; then
echo "Ustacks output directory present.  Skipping step.
$outdirunc/ustacks_output
"
else
echo "Assembling loci denovo with ustacks.
"
echo "Assembling loci denovo with ustacks.
" >> $log
mkdir -p $outdirunc/ustacks_output
			if [[ "$mode" == "single" ]]; then
	for line in `cat $mapfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  ustacks -t fastq -f $outdir/quality_filtered_data/${line}.read.mcf.fq -p $cores -o $outdirunc/ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d" >> $log
	ustacks -t fastq -f $outdir/quality_filtered_data/${line}.read.mcf.fq -p $cores -o $outdirunc/ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d &> $outdirunc/ustacks_output/log_${line}_ustacks.txt
	done
			fi
			if [[ "$mode" == "paired" ]]; then
	for line in `cat $mapfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  ustacks -t fastq -f $outdir/combined_data/${line}.fq -p $cores -o $outdirunc/ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d" >> $log
	ustacks -t fastq -f $outdir/combined_data/${line}.fq -p $cores -o $outdirunc/ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d &> $outdirunc/ustacks_output/log_${line}_ustacks.txt
	done
			fi
		fi

		if [[ $reps == "yes" ]]; then
			if [[ -d $outdirunc/dereplicated_ustacks_output ]]; then
echo "Ustacks output directory present (dereplicated data).  Skipping step.
$outdirunc/dereplicated_ustacks_output
"
else
echo "Assembling loci denovo with ustacks (dereplicated data).
"
echo "Assembling loci denovo with ustacks (dereplicated data).
" >> $log
mkdir -p $outdirunc/dereplicated_ustacks_output
				if [[ "$mode" == "single" ]]; then
	for line in `cat $repfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  ustacks -t fastq -f $outdir/dereplicated_quality_filtered_data/${line}.read.mcf.fq -p $cores -o $outdirunc/dereplicated_ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d" >> $log
	ustacks -t fastq -f $outdir/dereplicated_quality_filtered_data/${line}.read.mcf.fq -p $cores -o $outdirunc/dereplicated_ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d &> $outdirunc/dereplicated_ustacks_output/log_${line}_ustacks.txt
	done
				fi
				if [[ "$mode" == "paired" ]]; then
	for line in `cat $repfile | cut -f1`; do
	sqlid=$(cat /dev/urandom |tr -dc '0-9' | fold -w 8 | head -n 1)
	echo "  ustacks -t fastq -f $outdir/dereplicated_combined_data/${line}.fq -p $cores -o $outdirunc/dereplicated_ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d" >> $log
	ustacks -t fastq -f $outdir/dereplicated_combined_data/${line}.fq -p $cores -o $outdirunc/dereplicated_ustacks_output -i $sqlid -m 2 -M 4 -N 6 -r -d &> $outdirunc/dereplicated_ustacks_output/log_${line}_ustacks.txt
	done
				fi
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

runtime=`printf "Ustacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
	fi
fi

## Run cstacks to catalog loci across samples
res2=$(date +%s.%N)
if [[ ! -d $outdirunc/cstacks_output || ! -d $outdirunc/dereplicated_cstacks_output ]]; then
	if [[ -d $outdirunc/cstacks_output ]]; then
echo "Cstacks output directory present.  Skipping step.
$outdirunc/cstacks_output
"
else
echo "Cataloging loci with cstacks.
"
echo "Cataloging loci with cstacks.
" >> $log
	mcfcount=`ls $outdirunc/ustacks_output/*mcf* 2>/dev/null | wc -l`
		if [[ $mcfcount -ge 1 ]]; then
	cd $outdirunc/ustacks_output
	rename 's/read.mcf.//' *read.mcf*
	rename 's/read1.mcf.//' *read1.mcf*
	rename 's/read2.mcf.//' *read2.mcf*
	cd $workdir
		fi

mkdir -p $outdirunc/cstacks_output
	samp=""
		if [[ "$analysis" == "reference" ]]; then
	for line in `cat $mapfile | cut -f1`; do
	samp+="-s $outdirunc/pstacks_output/$line "
	done
	echo "	cstacks -g -p $cores -b ${batch} -n 1 $samp -o $outdirunc/cstacks_output &> $outdirunc/cstacks_output/log_cstacks.txt" >> $log
	cstacks -g -p $cores -b ${batch} -n 1 $samp -o $outdirunc/cstacks_output &> $outdirunc/cstacks_output/log_cstacks.txt
		fi
		if [[ "$analysis" == "denovo" ]]; then
	for line in `cat $mapfile | cut -f1`; do
	samp+="-s $outdirunc/ustacks_output/$line "
	done
	echo "	cstacks -p $cores -b ${batch} -n 4 -m $samp -o $outdirunc/cstacks_output &> $outdirunc/cstacks_output/log_cstacks.txt" >> $log
	cstacks -p $cores -b ${batch} -n 4 -m $samp -o $outdirunc/cstacks_output &> $outdirunc/cstacks_output/log_cstacks.txt
		fi
	fi

	if [[ $reps == "yes" ]]; then
		if [[ -d $outdirunc/dereplicated_cstacks_output ]]; then
echo "Cstacks output directory present (dereplicated data).  Skipping step.
$outdirunc/dereplicated_cstacks_output
"
else
echo "Cataloging loci with cstacks (dereplicated data).
"
echo "Cataloging loci with cstacks (dereplicated data).
" >> $log
	mcfcount=`ls $outdirunc/dereplicated_ustacks_output/*mcf* 2>/dev/null | wc -l`
			if [[ $mcfcount -ge 1 ]]; then
	cd $outdirunc/dereplicated_ustacks_output
	rename 's/read.mcf.//' *read.mcf*
	rename 's/read1.mcf.//' *read1.mcf*
	rename 's/read2.mcf.//' *read2.mcf*
	cd $workdir
			fi
mkdir -p $outdirunc/dereplicated_cstacks_output
	samp=""
			if [[ "$analysis" == "reference" ]]; then
	for line in `cat $repfile | cut -f1`; do
	samp+="-s $outdirunc/dereplicated_pstacks_output/$line "
	done
	echo "	cstacks -g -p $cores -b ${batch} -n 1 $samp -o $outdirunc/dereplicated_cstacks_output &> $outdirunc/dereplicated_cstacks_output/log_cstacks.txt" >> $log
	cstacks -g -p $cores -b ${batch} -n 1 $samp -o $outdirunc/dereplicated_cstacks_output &> $outdirunc/dereplicated_cstacks_output/log_cstacks.txt
			fi
			if [[ "$analysis" == "denovo" ]]; then
	for line in `cat $repfile | cut -f1`; do
	samp+="-s $outdirunc/dereplicated_ustacks_output/$line "
	done
	echo "	cstacks -p $cores -b ${batch} -n 4 -m $samp -o $outdirunc/dereplicated_cstacks_output &> $outdirunc/dereplicated_cstacks_output/log_cstacks.txt" >> $log
	cstacks -p $cores -b ${batch} -n 4 -m $samp -o $outdirunc/dereplicated_cstacks_output &> $outdirunc/dereplicated_cstacks_output/log_cstacks.txt
			fi

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

runtime=`printf "Cstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

## Search individual stacks against population catalog
## Need variables to manage batch IDs and catalog names
res2=$(date +%s.%N)
if [[ ! -d $outdirunc/sstacks_output || ! -d $outdirunc/dereplicated_sstacks_output ]]; then
	if [[ -d $outdirunc/sstacks_output ]]; then
echo "Sstacks output directory present.  Skipping step.
$outdirunc/sstacks_output
"
else
echo "Searching cataloged loci for each sample with sstacks.
"
echo "Searching cataloged loci for each sample with sstacks.
" >> $log
mkdir -p $outdirunc/sstacks_output
	for line in `cat $mapfile | cut -f1`; do
		if [[ "$analysis" == "reference" ]]; then
	echo "	sstacks -b ${batch} -c $outdirunc/cstacks_output/batch_${batch} -s $outdirunc/pstacks_output/$line -p $cores -o $outdirunc/sstacks_output &> $outdirunc/sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdirunc/cstacks_output/batch_${batch} -s $outdirunc/pstacks_output/$line -p $cores -o $outdirunc/sstacks_output &> $outdirunc/sstacks_output/log_${line}_sstacks.txt
		fi
		if [[ "$analysis" == "denovo" ]]; then
	echo "	sstacks -b ${batch} -c $outdirunc/cstacks_output/batch_${batch} -s $outdirunc/ustacks_output/$line -p $cores -o $outdirunc/sstacks_output &> $outdirunc/sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdirunc/cstacks_output/batch_${batch} -s $outdirunc/ustacks_output/$line -p $cores -o $outdirunc/sstacks_output &> $outdirunc/sstacks_output/log_${line}_sstacks.txt
		fi
	done
	fi

		if [[ $reps == "yes" ]]; then
			if [[ -d $outdirunc/dereplicated_sstacks_output ]]; then
echo "Sstacks output directory present (dereplicated data).  Skipping step.
$outdirunc/dereplicated_sstacks_output
"
else
echo "Searching cataloged loci for each sample with sstacks (dereplicated data).
"
echo "Searching cataloged loci for each sample with sstacks (dereplicated data).
" >> $log
mkdir -p $outdirunc/dereplicated_sstacks_output
	for line in `cat $repfile | cut -f1`; do
				if [[ "$analysis" == "reference" ]]; then
	echo "	sstacks -b ${batch} -c $outdirunc/dereplicated_cstacks_output/batch_${batch} -s $outdirunc/dereplicated_pstacks_output/$line -p $cores -o $outdirunc/dereplicated_sstacks_output &> $outdirunc/dereplicated_sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdirunc/dereplicated_cstacks_output/batch_${batch} -s $outdirunc/dereplicated_pstacks_output/$line -p $cores -o $outdirunc/dereplicated_sstacks_output &> $outdirunc/dereplicated_sstacks_output/log_${line}_sstacks.txt
				fi
				if [[ "$analysis" == "denovo" ]]; then
	echo "	sstacks -b ${batch} -c $outdirunc/dereplicated_cstacks_output/batch_${batch} -s $outdirunc/dereplicated_ustacks_output/$line -p $cores -o $outdirunc/dereplicated_sstacks_output &> $outdirunc/dereplicated_sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdirunc/dereplicated_cstacks_output/batch_${batch} -s $outdirunc/dereplicated_ustacks_output/$line -p $cores -o $outdirunc/dereplicated_sstacks_output &> $outdirunc/dereplicated_sstacks_output/log_${line}_sstacks.txt
				fi
	done
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

runtime=`printf "Sstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log

fi

## Copy all useful outputs to same directory for populations calculations
res2=$(date +%s.%N)
if [[ ! -d $outdirunc/stacks_all_output || ! -d $outdirunc/dereplicated_stacks_all_output ]]; then
	if [[ -d $outdirunc/stacks_all_output ]]; then
echo "Populations directory present.  Skipping step.
$outdirunc/stacks_all_output
"
else
mkdir -p $outdirunc/stacks_all_output
		if [[ "$analysis" == "denovo" ]]; then
cp $outdirunc/ustacks_output/*.tsv $outdirunc/stacks_all_output 2>/dev/null || true
		fi
		if [[ "$analysis" == "reference" ]]; then
cp $outdirunc/pstacks_output/*.tsv $outdirunc/stacks_all_output 2>/dev/null || true
		fi
cp $outdirunc/cstacks_output/*.tsv $outdirunc/stacks_all_output 2>/dev/null || true
cp $outdirunc/sstacks_output/*.tsv $outdirunc/stacks_all_output 2>/dev/null || true

## Run populations program to generate popgen stats plus various outputs
## Need to add a variable for the popmap file, and change path as appropriate
echo "Executing \"populations\" program to produce popgen stats and outputs.
"
echo "Executing \"populations\" program to produce popgen stats and outputs.
" >> $log
		if [[ "$analysis" == "denovo" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdirunc/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats &> $outdirunc/stacks_all_output/log_populations.txt
	" >> $log
	populations -t $cores -b ${batch} -P $outdirunc/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --genomic &> $outdirunc/stacks_all_output/log_populations.txt
		fi
		if [[ "$analysis" == "reference" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdirunc/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist &> $outdirunc/stacks_all_output/log_populations.txt
	" >> $log
	populations -t $cores -b ${batch} -P $outdirunc/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist --genomic &> $outdirunc/stacks_all_output/log_populations.txt
		fi
	fi

## Dereplicated populations step
	if [[ "$reps" == "yes" ]]; then
	if [[ -d $outdirunc/dereplicated_stacks_all_output ]]; then
echo "Populations directory present (dereplicated data).  Skipping step.
$outdirunc/dereplicated_stacks_all_output
"
else
mkdir -p $outdirunc/dereplicated_stacks_all_output
		if [[ "$analysis" == "denovo" ]]; then
cp $outdirunc/dereplicated_ustacks_output/*.tsv $outdirunc/dereplicated_stacks_all_output 2>/dev/null || true
		fi
		if [[ "$analysis" == "reference" ]]; then
cp $outdirunc/dereplicated_pstacks_output/*.tsv $outdirunc/dereplicated_stacks_all_output 2>/dev/null || true
		fi
cp $outdirunc/dereplicated_cstacks_output/*.tsv $outdirunc/dereplicated_stacks_all_output 2>/dev/null || true
cp $outdirunc/dereplicated_sstacks_output/*.tsv $outdirunc/dereplicated_stacks_all_output 2>/dev/null || true

## Run populations program to generate popgen stats plus various outputs
## Need to add a variable for the popmap file, and change path as appropriate
echo "Executing \"populations\" program to produce popgen stats and outputs
(dereplicated data).
"
echo "Executing \"populations\" program to produce popgen stats and outputs
(dereplicated data).
" >> $log
		if [[ "$analysis" == "denovo" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --genomic &> $outdirunc/dereplicated_stacks_all_output/log_populations.txt
	" >> $log
	populations -t $cores -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --genomic &> $outdirunc/dereplicated_stacks_all_output/log_populations.txt
		fi
		if [[ "$analysis" == "reference" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist --genomic &> $outdirunc/dereplicated_stacks_all_output/log_populations.txt
	" >> $log
	populations -t $cores -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist --genomic &> $outdirunc/dereplicated_stacks_all_output/log_populations.txt
		fi
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

runtime=`printf "Populations runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

#################################
## START OF CORRECTED ANALYSIS ##
#################################
echo "Start of corrected analysis steps.
"
echo "Start of corrected analysis steps.
" >> $log

## Population-based corrections using rxstacks
res2=$(date +%s.%N)
if [[ ! -d $outdircor/rxstacks_output || ! -d $outdircor/dereplicated_rxstacks_output ]]; then
	if [[ -d $outdircor/rxstacks_output ]]; then
echo "Rxstacks output directory present.  Skipping step.
$outdircor/rxstacks_output
"
else
echo "Running rxstacks to correct SNP calls.
"
echo "Running rxstacks to correct SNP calls.
" >> $log

mkdir -p $outdircor/rxstacks_output
	echo "	rxstacks -b ${batch} -P $outdirunc/stacks_all_output -o $outdircor/rxstacks_output --conf_lim 0.25 --prune_haplo --model_type bounded --bound_high 0.1 --lnl_lim -8.0 --lnl_dist -t $cores --verbose &> $outdircor/rxstacks_output/log_rxstacks.txt
	" >> $log
	rxstacks -b ${batch} -P $outdirunc/stacks_all_output -o $outdircor/rxstacks_output --conf_lim 0.25 --prune_haplo --model_type bounded --bound_high 0.1 --lnl_lim -8.0 --lnl_dist -t $cores --verbose &> $outdircor/rxstacks_output/log_rxstacks.txt
	fi

	if [[ "$reps" == "yes" ]]; then
	if [[ -d $outdircor/dereplicated_rxstacks_output ]]; then
echo "Rxstacks output directory present (dereplicated data).  Skipping step.
$outdircor/dereplicated_rxstacks_output
"
else
echo "Running rxstacks to correct SNP calls (dereplicated data).
"
echo "Running rxstacks to correct SNP calls (dereplicated data).
" >> $log

mkdir -p $outdircor/dereplicated_rxstacks_output
	echo "	rxstacks -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -o $outdircor/dereplicated_rxstacks_output --conf_lim 0.25 --prune_haplo --model_type bounded --bound_high 0.1 --lnl_lim -8.0 --lnl_dist -t $cores --verbose &> $outdircor/dereplicated_rxstacks_output/log_rxstacks.txt
	" >> $log
	rxstacks -b ${batch} -P $outdirunc/dereplicated_stacks_all_output -o $outdircor/dereplicated_rxstacks_output --conf_lim 0.25 --prune_haplo --model_type bounded --bound_high 0.1 --lnl_lim -8.0 --lnl_dist -t $cores --verbose &> $outdircor/dereplicated_rxstacks_output/log_rxstacks.txt
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

runtime=`printf "Rxstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

## Rerun cstacks to rebuild catalog
res2=$(date +%s.%N)
if [[ ! -d $outdircor/cstacks_output || ! -d $outdircor/dereplicated_cstacks_output ]]; then
	if [[ -d $outdircor/cstacks_output ]]; then
echo "Corrected cstacks output directory present.  Skipping step.
$outdircor/cstacks_output
"
else
echo "Rebuilding catalog with cstacks.
"
echo "Rebuilding catalog with cstacks.
" >> $log
mkdir -p $outdircor/cstacks_output
	samp=""
	for line in `cat $mapfile | cut -f1`; do
	samp+="-s $outdircor/rxstacks_output/$line "
	done
	echo "	cstacks -b ${batch} -n 3 -p $cores -o $outdircor/cstacks_output $samp &> $outdircor/cstacks_output/log_cstacks.txt" >> $log
	cstacks -b ${batch} -n 3 -p $cores -o $outdircor/cstacks_output $samp &> $outdircor/cstacks_output/log_cstacks.txt
	fi

	if [[ "$reps" == "yes" ]]; then
	if [[ -d $outdircor/dereplicated_cstacks_output ]]; then
echo "Corrected cstacks output directory present (dereplicated data).  Skipping step.
$outdircor/cstacks_output
"
else
echo "Rebuilding catalog with cstacks (dereplicated data).
"
echo "Rebuilding catalog with cstacks (dereplicated data).
" >> $log
mkdir -p $outdircor/dereplicated_cstacks_output
	samp=""
	for line in `cat $repfile | cut -f1`; do
	samp+="-s $outdircor/dereplicated_rxstacks_output/$line "
	done
	echo "	cstacks -b ${batch} -n 3 -p $cores -o $outdircor/dereplicated_cstacks_output $samp &> $outdircor/dereplicated_cstacks_output/log_cstacks.txt" >> $log
	cstacks -b ${batch} -n 3 -p $cores -o $outdircor/dereplicated_cstacks_output $samp &> $outdircor/dereplicated_cstacks_output/log_cstacks.txt
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

runtime=`printf "Cstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

## Rerun sstacks
res2=$(date +%s.%N)
if [[ ! -d $outdircor/sstacks_output || ! -d $outdircor/dereplicated_sstacks_output ]]; then
	if [[ -d $outdircor/sstacks_output ]]; then
echo "Corrected sstacks output directory present.  Skipping step.
$outdircor/sstacks_output
"
else
echo "Searching cataloged loci for each corrected sample with sstacks.
"
echo "Searching cataloged loci for each corrected sample with sstacks.
" >> $log
mkdir -p $outdircor/sstacks_output
	for line in `cat $mapfile | cut -f1`; do
	echo "	sstacks -b ${batch} -c $outdircor/cstacks_output/batch_${batch} -s $outdircor/rxstacks_output/$line -p $cores -o $outdircor/sstacks_output &> $outdircor/sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdircor/cstacks_output/batch_${batch} -s $outdircor/rxstacks_output/$line -p $cores -o $outdircor/sstacks_output &> $outdircor/sstacks_output/log_${line}_sstacks.txt
	done
	fi

	if [[ "$reps" == "yes" ]]; then
	if [[ -d $outdircor/dereplicated_sstacks_output ]]; then
echo "Corrected sstacks output directory present.  Skipping step.
$outdircor/sstacks_output
"
else
echo "Searching cataloged loci for each corrected sample with sstacks
(dereplicated data).
"
echo "Searching cataloged loci for each corrected sample with sstacks
(dereplicated data).
" >> $log
mkdir -p $outdircor/dereplicated_sstacks_output
	for line in `cat $repfile | cut -f1`; do
	echo "	sstacks -b ${batch} -c $outdircor/dereplicated_cstacks_output/batch_${batch} -s $outdircor/dereplicated_rxstacks_output/$line -p $cores -o $outdircor/dereplicated_sstacks_output &> $outdircor/dereplicated_sstacks_output/log_${line}_sstacks.txt" >> $log
	sstacks -b ${batch} -c $outdircor/dereplicated_cstacks_output/batch_${batch} -s $outdircor/dereplicated_rxstacks_output/$line -p $cores -o $outdircor/dereplicated_sstacks_output &> $outdircor/dereplicated_sstacks_output/log_${line}_sstacks.txt
	done
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

runtime=`printf "Sstacks runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

## Copy all useful outputs to same directory for populations calculations
res2=$(date +%s.%N)
if [[ ! -d $outdircor/stacks_all_output || ! -d $outdircor/dereplicated_stacks_all_output ]]; then
	if [[ -d $outdircor/stacks_all_output ]]; then
echo "Corrected populations output directory present.  Skipping step.
$outdircor/stacks_all_output
"
else
mkdir -p $outdircor/stacks_all_output
cp $outdircor/rxstacks_output/*.tsv $outdircor/stacks_all_output
cp $outdircor/cstacks_output/*.tsv $outdircor/stacks_all_output
cp $outdircor/sstacks_output/*.tsv $outdircor/stacks_all_output

## Rerun populations
echo "Executing \"populations\" program to produce popgen stats and outputs
for corrected data.
"
echo "Executing \"populations\" program to produce popgen stats and outputs
for corrected data.
" >> $log
		if [[ "$analysis" == "denovo" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdircor/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --genomic &> $outdircor/stacks_all_output/log_populations.txt" >> $log
	populations -t $cores -b ${batch} -P $outdircor/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --genomic &> $outdircor/stacks_all_output/log_populations.txt
		fi
		if [[ "$analysis" == "reference" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdircor/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist --genomic &> $outdircor/stacks_all_output/log_populations.txt" >> $log
	populations -t $cores -b ${batch} -P $outdircor/stacks_all_output -M $popmap -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist --genomic &> $outdircor/stacks_all_output/log_populations.txt
		fi
	fi

## Dereplicated populations
	if [[ -d $outdircor/dereplicated_stacks_all_output ]]; then
echo "Corrected populations output directory present.  Skipping step.
$outdircor/stacks_all_output
"
else
mkdir -p $outdircor/dereplicated_stacks_all_output
cp $outdircor/dereplicated_rxstacks_output/*.tsv $outdircor/dereplicated_stacks_all_output
cp $outdircor/dereplicated_cstacks_output/*.tsv $outdircor/dereplicated_stacks_all_output
cp $outdircor/dereplicated_sstacks_output/*.tsv $outdircor/dereplicated_stacks_all_output

## Rerun populations
echo "Executing \"populations\" program to produce popgen stats and outputs
for corrected data (dereplicated data).
"
echo "Executing \"populations\" program to produce popgen stats and outputs
for corrected data (dereplicated data).
" >> $log
		if [[ "$analysis" == "denovo" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdircor/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats &> $outdircor/dereplicated_stacks_all_output/log_populations.txt" >> $log
	populations -t $cores -b ${batch} -P $outdircor/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats &> $outdircor/dereplicated_stacks_all_output/log_populations.txt
		fi
		if [[ "$analysis" == "reference" ]]; then
	echo "	populations -t $cores -b ${batch} -P $outdircor/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats &> $outdircor/dereplicated_stacks_all_output/log_populations.txt" >> $log
	populations -t $cores -b ${batch} -P $outdircor/dereplicated_stacks_all_output -M $popmap1 -p 1 -f p_value -k -r 0.75 -s --structure --phylip --genepop --vcf --phase --fasta --fstats --merge_sites -- bootstrap --bootstrap_pifis --bootstrap_fst --bootstrap_div --bootstrap_phist &> $outdircor/dereplicated_stacks_all_output/log_populations.txt
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

runtime=`printf "Populations runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
fi

###################################
## Add results to mysql database ##
###################################

#adjust dbname variables here
echo "Adding Stacks output to mysql database for viewing.  This takes a
while so be patient.
"
echo "adding Stacks output to mysql database.
" >> $log
	echo $dbunc > $outdirunc/stacks_all_output/.mysql_database 2>/dev/null || true
	echo $dbcor > $outdircor/stacks_all_output/.mysql_database 2>/dev/null || true
	echo $dbuncderep > $outdirunc/dereplicated_stacks_all_output/.mysql_database 2>/dev/null || true
	echo $dbcorderep > $outdircor/dereplicated_stacks_all_output/.mysql_database 2>/dev/null || true

	# drop existing mysql databases in preparation for replacement
	mysql -e "DROP DATABASE $dbunc" 2>/dev/null || true
	mysql -e "DROP DATABASE $dbcor" 2>/dev/null || true
	mysql -e "DROP DATABASE $dbuncderep" 2>/dev/null || true
	mysql -e "DROP DATABASE $dbcorderep" 2>/dev/null || true

	# create new mysql databases
	echo "	mysql -e \"CREATE DATABASE $dbunc\"" >> $log
	mysql -e "CREATE DATABASE $dbunc"
	echo "	mysql -e \"CREATE DATABASE $dbcor\"" >> $log
	mysql -e "CREATE DATABASE $dbcor"
	echo "	mysql -e \"CREATE DATABASE $dbuncderep\"" >> $log
	mysql -e "CREATE DATABASE $dbuncderep"
	echo "	mysql -e \"CREATE DATABASE $dbcorderep\"" >> $log
	mysql -e "CREATE DATABASE $dbcorderep"

	echo "	mysql $dbunc < /usr/local/share/stacks/sql/stacks.sql" >> $log
	mysql $dbunc < /usr/local/share/stacks/sql/stacks.sql
	echo "	mysql $dbcor < /usr/local/share/stacks/sql/stacks.sql" >> $log
	mysql $dbcor < /usr/local/share/stacks/sql/stacks.sql
	echo "	mysql $dbuncderep < /usr/local/share/stacks/sql/stacks.sql" >> $log
	mysql $dbuncderep < /usr/local/share/stacks/sql/stacks.sql
	echo "	mysql $dbcorderep < /usr/local/share/stacks/sql/stacks.sql" >> $log
	mysql $dbcorderep < /usr/local/share/stacks/sql/stacks.sql
	echo "" >> $log
wait

## Loading databases (all samples)
res2=$(date +%s.%N)
echo "Loading and indexing uncorrected data.
"
echo "	load_radtags.pl -D $dbunc -b ${batch} -p $outdirunc/stacks_all_output -B -e \"$dbname uncorrected output\" -M $popmap -c -t population" >> $log
load_radtags.pl -D $dbunc -b ${batch} -p $outdirunc/stacks_all_output -B -e "$dbname uncorrected output" -M $popmap -c -t population &>/dev/null
echo "	index_radtags.pl -D $dbunc -c -t
" >> $log
index_radtags.pl -D $dbunc -c -t &>/dev/null

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Database load/index runtime (uncorrected data): %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
echo "Uncorrected data is ready for viewing.
"
wait
res2=$(date +%s.%N)
echo "Loading and indexing corrected data.
"
echo "	load_radtags.pl -D $dbcor -b ${batch} -p $outdircor/stacks_all_output -B -e \"$dbname corrected output\" -M $popmap -c -t population" >> $log
load_radtags.pl -D $dbcor -b ${batch} -p $outdircor/stacks_all_output -B -e "$dbname corrected output" -M $popmap -c -t population &>/dev/null
echo "	index_radtags.pl -D $dbcor -c -t
" >> $log
index_radtags.pl -D $dbcor -c -t &>/dev/null

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Database load/index runtime (corrected data): %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
echo "Corrected data is ready for viewing.
"
wait

## Loading databases (dereplicated)
if [[ "$reps" == "yes" ]]; then
res2=$(date +%s.%N)
echo "Loading and indexing uncorrected data (dereplicated data).
"
echo "	load_radtags.pl -D $dbuncderep -b ${batch} -p $outdirunc/dereplicated_stacks_all_output -B -e \"$dbname uncorrected and dereplicated output\" -M $popmap1 -c  -t population" >> $log
load_radtags.pl -D $dbuncderep -b ${batch} -p $outdirunc/dereplicated_stacks_all_output -B -e "$dbname uncorrected output" -M $popmap1 -c  -t population &>/dev/null
echo "	index_radtags.pl -D $dbuncderep -c -t
" >> $log
index_radtags.pl -D $dbunc -c -t &>/dev/null

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Database load/index runtime (uncorrected data): %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
echo "Uncorrected data is ready for viewing (dereplicated data).
"
wait
res2=$(date +%s.%N)
echo "Loading and indexing corrected data (dereplicated data).
"
echo "	load_radtags.pl -D $dbcorderep -b ${batch} -p $outdircor/dereplicated_stacks_all_output -B -e \"$dbname corrected and dereplicated output\" -M $popmap1 -c -t population" >> $log
load_radtags.pl -D $dbcorderep -b ${batch} -p $outdircor/dereplicated_stacks_all_output -B -e "$dbname corrected output" -M $popmap1 -c -t population &>/dev/null
echo "	index_radtags.pl -D $dbcorderep -c -t
" >> $log
index_radtags.pl -D $dbcorderep -c -t &>/dev/null

res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)

runtime=`printf "Database load/index runtime (corrected data): %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
echo "Corrected data is ready for viewing (dereplicated data).
"
wait
fi

## Final timing code and exit
res3=$(date +%s.%N)
dt=$(echo "$res3 - $res0" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)
runtime=`printf "Total RADseq workflow runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log
exit 0

#########################
## Spare code below here:
#########################

## Timing code
res2=$(date +%s.%N)
res3=$(date +%s.%N)
dt=$(echo "$res3 - $res2" | bc)
dd=$(echo "$dt/86400" | bc)
dt2=$(echo "$dt-86400*$dd" | bc)
dh=$(echo "$dt2/3600" | bc)
dt3=$(echo "$dt2-3600*$dh" | bc)
dm=$(echo "$dt3/60" | bc)
ds=$(echo "$dt3-60*$dm" | bc)
runtime=`printf "Function runtime: %d days %02d hours %02d minutes %02.1f seconds\n" $dd $dh $dm $ds`
echo "$runtime
" >> $log


