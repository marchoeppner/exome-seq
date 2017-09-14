![](images/ikmb_bfx_logo.png)

# Overview

This pipeline performs exome analysis on a set of samples. The following steps are included:

* Read trimming (Trimmomatic 0.36)

* Read alignment (BWA 0.7.15, Samtools 1.5)

* Marking of duplicates (GATK4b5)

* Base quality recalibration (GATK4b5)

* Variant calling using HaplotypeCaller (GATK4b5) 

* Merged genotype calls using GenotypeGVCFs (GATK4b5) [Includes 17 IKMB control exomes)

* Recalibration of SNPs and Indels (GATK4b5)

* Merged gVCF with control exomes removed

* Effect prediction with VEP (EnsEMBL86) and Annovar (2016)

## Input format

The pipeline parses a config file to find the input files and relevant meta data. The expected format is semicolon-separated CSV with the following headers:

  * INDIVIDUAl_ID - The ID of the individual from which the sample was derived.
  * SAMPLE_ID - The ID of the sample. Note that more than one sample can come from the same individual (e.g. tumor/normal pair)
  * LIBRARY_ID - The ID of the DNA library. Multiple sequencing libraries can be prepared from the same sample.
  * RG_ID - Read group ID
  * PLATFORM_UNIT - Generally, this is the read group ID plus the library ID
  * PLATFORM - Sequencer (e.g. illumina)
  * PLATFORM_MODEL - Sequencer (e.g. HiSeq2500)
  * RUN_DATE - Date of sequencing run
  * CENTER - Location of sequencing run
  * R1 - Full path to Fastq file 1
  * R2 - Full path to Fastq file 2

A template file (SampleTemplate.csv) is included with this code base. 

### Read group ID tags

The read group ID and platform unit can be derived from the fastq headers like so:

Header: `@J00124:23:HGJJMBBXX:3:1101:31477:1138 1:N:0:CGTACTAG+ATAGAGAG`

RG_ID : `HGJJMBBXX.3`

PU : `HGJJMBBXX.3` (This may not be 100% accurate, but available information is vague...)

## Output format

This pipeline produces read alignments in CRAM format rather than BAM to save disk space. 

## Executing the pipeline

The pipeline can be run as follows:

`nextflow -c nextflow.config run main.nf --samples /path/to/sample_list.csv`

Should the pipeline crash, you can try and resume it (after the problem has been fixed) adding "-resume" to the execution. 

If you set up a scm configuration file (please see: https://www.nextflow.io/docs/latest/sharing.html#scm-configuration-file), you can also run the pipeline without cloning the repository:

`nextflow run bfx-core/NF-diagnostics-exome --samples /path/to/sample_list.csv -hub ikmb`

Make sure to keep your version of the pipeline up-to-date with the repository:

`nextflow pull bfx-core/NF-diagnostics-exome -hub ikmb`

## Supported enrichment kits

The pipeline is built to support more than one Exome kit. These can be selected from the command line using the --kit option.

`--kit Nextera` (the nextera rapid exome kit, 2017)

`--kit xGen` (the IDT xGEN panel, version 1.0)

This option defaults to "Nextera", so make sure this is in fact the kit you have used!

## Email notification

The pipeline will send out an Email notification upon completion if a recipient is speciefied via the flag `--email`:

`--email 'your.username@ikmb.uni-kiel.de'` 

## Output

By default, the pipeline output will be stored in the "output" subfolder from where you ran the nextflow process. You can provide an alternative location 
by specifying "--outdir /some/other/folder" on the command line. 

The output will be spread across several folders - one for each sample, one for the combined variant calls and a generic folder for library statistics and such. 
