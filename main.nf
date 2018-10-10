#!/usr/bin/env nextflow

/**
===============================
IKMB Diagnostic Exome Pipeline
===============================

This Pipeline performs one of two workflows to generate variant calls and effect predictions
using either the GATK processing chain or Freebayes.

### Homepage / git
http://git.ikmb.uni-kiel.de/bfx-core/NF-diagnostics-exome
### Implementation
Implemented in Q1 2018

This pipeline is based on the updated GATK best-practices (where applicable).
 - trimming (Trimgalore)
 - Alignment (BWA)
 - Duplicate marking (GATK)
 - recalibration 
 - variant calling
 - variant recalibration and filtering
 - variant effect prediction

Author: Marc P. Hoeppner, m.hoeppner@ikmb.uni-kiel.de

**/

// Pipeline version
VERSION = "1.0-alpha1"

// Help message
helpMessage = """
===============================================================================
IKMB Diagnostic Exome pipeline | version ${VERSION}
===============================================================================
Usage: nextflow -c /path/to/git/nextflow.config run /path/to/git/main.nf --assembly hg19_clinical --kit Nextera --samples Samples.csv
This example will perform an exome analysis against the hg19 (with decoys) assembly, assuming that exome reads were generated with
the Nextera kit and using the GATK4 best-practice workflow. 
Required parameters:
--samples                      A sample list in CSV format (see website for formatting hints)
--assembly                     Name of the reference assembly to use
--effect_prediction	       Whether to run effect prediction on the final variant set (default: false)
--hard_filter			Whether to run hard filtering on raw variants instead of machine learning (default: false)
Optional parameters:
--run_name 		       A descriptive name for this pipeline run
--bam				Whether to output the alignments in BAM format (default: cram)
--fasta				A reference genome in FASTA format (set automatically if using --assembly)
--dbsnp				dbSNP data in VCF format (set automatically if using --assembly)
--g1k				A SNP reference (usually 1000genomes, set automatically if using --assembly)
--mills_indels			An INDEL reference (usually MILLS/1000genomes, set automatically if using --assembly)
--omni				An SNP reference (usually OMNI, set automatically if using --assembly)
--hapmap			A SNP reference (usually HAPMAP, set automatically if using --assembly)
--targets			A interval_list target file (set automatically if using the --kit option)
--baits				A interval_list bait file (set automatically if using the --kit option)
Output:
--outdir                       Local directory to which all output is written (default: output)
Exome kit:
--kit                          Exome kit used (default: Nextera)
"""

params.help = false

// Show help when needed
if (params.help){
    log.info helpMessage
    exit 0
}

// #############
// INPUT OPTIONS
// #############

// Sample input file
inputFile = file(params.samples)

// Giving this pipeline run a name
params.run_name = workflow.sessionId

// This will eventually enable switching between multiple assembly versions
// Currently, only hg19 has all the required reference files available
params.assembly = "hg19"

REF = params.fasta ?: file(params.genomes[ params.assembly ].fasta)
DBSNP = params.dbsnp ?: file(params.genomes[ params.assembly ].dbsnp )
G1K = params.g1k ?: file(params.genomes[ params.assembly ].g1k )
MILLS = params.mills_indels ?: file(params.genomes[ params.assembly ].mills )
OMNI = params.omni ?: file(params.genomes[ params.assembly ].omni )
HAPMAP = params.hapmap ?: file(params.genomes[ params.assembly ].hapmap )
VEP_CACHE = params.vep_cache
MITOCHONDRION = params.mitochondrion ?: params.genomes[ params.assembly ].mitochondrion

TARGETS = params.targets ?: params.genomes[params.assembly].kits[ params.kit ].targets
BAITS = params.baits ?: params.genomes[params.assembly].kits[ params.kit ].baits

SNP_RULES = params.snp_filter_rules
INDEL_RULES = params.indel_filter_rules

params.effect_prediction = true
params.hard_filter = false

// Whether to produce BAM output instead of CRAM
params.bam = false
align_suffix = (params.bam == false) ? "cram" : "bam"

// Location of applications used
OUTDIR = file(params.outdir)

// Available exome kits

if (TARGETS == false || BAITS == false ) {
   exit 1, "Information on enrichment kit incomplete or missing (please see the documentation for details!"
}

// We add 17 reference exome gVCFs to make sure that variant filtration works
// These are in hg19 so need to be updated to other assemblies if multiple assemblies are to be supported

params.calibration_exomes = false
params.calibration_sample_list = false

calibration_exomes = params.calibration_exomes ?: file(params.genomes[params.assembly].calibration_exomes_gatk)
calibration_samples_list_args = params.calibration_sample_list ?: file(params.genomes[params.assembly].calibration_exomes_samples_args)

calibration_vcfs = [ ]
file(calibration_exomes).eachLine { line ->
        location = line.trim()
        calibration_vcfs << location
}

// Whether to send a notification upon workflow completion
params.email = false

if(params.email == false) {
	exit 1, "You must provide an Email address to which pipeline updates are send!"
}

// Whether to use a local scratch disc
use_scratch = params.scratch

// Make sure the Nextflow version is current enough
try {
    if( ! nextflow.version.matches(">= $params.nextflow_required_version") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $params.nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please use a more recent version of Nextflow!\n" +
              "============================================================"
}

logParams(params, "pipeline_parameters.txt")

// Header log info
log.info "========================================="
log.info "IKMB Diagnostic Exome pipeline v${VERSION}"
log.info "Nextflow Version:		$workflow.nextflow.version"
log.info "Assembly version: 		${params.assembly}"
log.info "Command Line:			$workflow.commandLine"
log.info "Run name: 			${params.run_name}"
log.info "========================================="

// Read sample file 
Channel.from(inputFile)
       .splitCsv(sep: ';', header: true)
       .set {  readPairsFastp }

process runFastp {

	tag "${indivID}|${sampleID}"

	input:
	set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, center, date, fastqR1, fastqR2 from readPairsFastp

	output:
	set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, date, center, file(left),file(right) into inputBwa
	set file(html),file(json) into fastp_results

	script:
	left = file(fastqR1).getBaseName() + "_trimmed.fastq.gz"
	right = file(fastqR2).getBaseName() + "_trimmed.fastq.gz"
	json = file(fastqR1).getBaseName() + ".fastp.json"
	html = file(fastqR1).getBaseName() + ".fastp.html"

	"""
		fastp --in1 $fastqR1 --in2 $fastqR2 --out1 $left --out2 $right -w ${task.cpus} -j $json -h $html
	"""
}

process runBWA {

    tag "${indivID}|${sampleID}|${libraryID}|${rgID}"
    // publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Libraries/${libraryID}/${rgID}/BWA/", mode: 'copy'

    //scratch use_scratch
	
    input:
    set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, run_date, center,file(left),file(right) from inputBwa
    
    output:
    set indivID, sampleID, file(outfile) into runBWAOutput
    
    script:
    outfile = sampleID + "_" + libraryID + "_" + rgID + ".aligned.bam"	

    """
	bwa mem -M -R "@RG\\tID:${rgID}\\tPL:ILLUMINA\\tPU:${platform_unit}\\tSM:${indivID}_${sampleID}\\tLB:${libraryID}\\tDS:${REF}\\tCN:${center}" -t ${task.cpus} ${REF} $left $right | samtools sort -O bam -m 2G -@ 4 - > $outfile
    """	
}

runBWAOutput_grouped_by_sample = runBWAOutput.groupTuple(by: [0,1])

process mergeBamFiles_bySample {

        tag "${indivID}|${sampleID}"
	
	input:
        set indivID, sampleID, file(aligned_bam_list) from runBWAOutput_grouped_by_sample

	output:
	set indivID,sampleID,file(merged_bam) into mergedBamFile_by_Sample

	script:
	merged_bam = sampleID + "merged.bam"

	"""
		picard MergeSamFiles \
			INPUT=${aligned_bam_list.join(' INPUT=')} \
			OUTPUT=${merged_bam} \
			CREATE_INDEX=false \
			CREATE_MD5_FILE=false \
			SORT_ORDER=coordinate
	"""
}

process runMarkDuplicates {

	tag "${indivID}|${sampleID}"
        // publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/MarkDuplicates", mode: 'copy'

        // scratch use_scratch

        input:
        set indivID, sampleID, file(merged_bam) from mergedBamFile_by_Sample

        output:
        set indivID, sampleID, file(outfile_bam),file(outfile_bai) into MarkDuplicatesOutput, BamForMultipleMetrics, runPrintReadsOutput_for_OxoG_Metrics, runPrintReadsOutput_for_HC_Metrics, BamForDepthOfCoverage
	file(outfile_md5) into MarkDuplicatesMD5
	file(outfile_metrics) into DuplicatesOutput_QC

        script:
        outfile_bam = sampleID + ".dedup.bam"
        outfile_bai = sampleID + ".dedup.bai"
	outfile_md5 = sampleID + ".dedup.bam.md5"

        outfile_metrics = sampleID + "_duplicate_metrics.txt"

	"""
        	picard -Xmx${task.memory.toGiga()-5}G -Djava.io.tmpdir=tmp/ MarkDuplicates \
                	INPUT=${merged_bam} \
	                OUTPUT=${outfile_bam} \
        	        METRICS_FILE=${outfile_metrics} \
                        CREATE_INDEX=true \
			ASSUME_SORTED=true \
			MAX_RECORDS_IN_RAM=300000
                        TMP_DIR=tmp && md5sum ${outfile_bam} > ${outfile_md5}
	"""

}

// ------------------------------------------------------------------------------------------------------------
//
// Perform base quality score recalibration (BQSR) including
// 1) Generate a recalibration table
// 2) Generate a new table after applying recalibration
// 3) Compare differences between recalibration tables
// 4) Apply recalibration
//
// ------------------------------------------------------------------------------------------------------------

process runBaseRecalibrator {

	tag "${indivID}|${sampleID}"
	// publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/BaseRecalibrator/", mode: 'copy'
	    
	input:
	set indivID, sampleID, dedup_bam, dedup_bai from MarkDuplicatesOutput
    
	output:
	set indivID, sampleID, dedup_bam, file(recal_table) into runBaseRecalibratorOutput
    
	script:
	recal_table = sampleID + "_recal_table.txt" 

	"""
		gatk --java-options "-Xmx${task.memory.toGiga()}G" BaseRecalibrator \
		--reference ${REF} \
		-L $TARGETS \
		-L $MITOCHONDRION \
		-ip 150 \
		--input ${dedup_bam} \
		--known-sites ${MILLS} \
		--known-sites ${DBSNP} \
       	        --known-sites ${G1K} \
		--output ${recal_table}
	"""
}

process runApplyBQSR {

	tag "${indivID}|${sampleID}"
	publishDir "${OUTDIR}/${indivID}/${sampleID}/", mode: 'copy'

	scratch use_scratch
	    
	input:
	set indivID, sampleID, realign_bam, recal_table from runBaseRecalibratorOutput 

	output:
	set indivID, sampleID, file(outfile_bam), file(outfile_bai) into runPrintReadsOutput_for_Multiple_Metrics,inputHCSample,inputCollectReadCounts
	set indivID, sampleID, realign_bam, recal_table into runPrintReadsOutput_for_PostRecal
	set indivID, outfile_md5 into BamMD5
            
	script:

	outfile_bam = sampleID + ".clean.${align_suffix}"
	outfile_bai = sampleID + ".clean.${align_suffix}.bai"
	outfile_md5 = sampleID + ".clean.${align_suffix}.md5"
           
    	"""
        	gatk --java-options "-Xmx${task.memory.toGiga()}G" ApplyBQSR \
                --reference ${REF} \
                --input ${realign_bam} \
		-OBI true \
		-L $TARGETS \
		-L $MITOCHONDRION \
		-ip 150 \
                -bqsr ${recal_table} \
                --output ${outfile_bam} \
                -OBM true \
    	"""
}    


// Call variants on a per-sample basis

process runHCSample {

	tag "${indivID}|${sampleID}"
	publishDir "${OUTDIR}/${indivID}/${sampleID}/Variants/HaplotypeCaller" , mode: 'copy'

	input: 
	set indivID,sampleID,file(bam),file(bai) from inputHCSample

	output:
	file(vcf) into outputHCSample
        file(vcf_index) into outputHCSampleIndex

	script:
 
	vcf = sampleID + ".raw_variants.g.vcf.gz"
	vcf_index = vcf + ".tbi"

	"""
	gatk --java-options "-Xmx${task.memory.toGiga()}G" HaplotypeCaller \
		-R $REF \
		-I ${bam} \
		-L $TARGETS \
		-L $MITOCHONDRION \
		--genotyping-mode DISCOVERY \
		--emit-ref-confidence GVCF \
		-OVI true \
    		--output $vcf \
		--native-pair-hmm-threads ${task.cpus} &> log.txt \
  	"""
}

// Import individual vcf files into a GenomicsDB database on a per chromosome basis
// From here on all samples are in the same file
process runGenomicsDBImport  {

	tag "ALL"
        // publishDir "${OUTDIR}/Variants/JointGenotypes/"

	input:
        file(vcf_list) from outputHCSample.collect()
	file(index_list) from outputHCSampleIndex.collect()

	output:
        set file(merged_vcf),file(merged_vcf_index) into inputGenotypeGVCFs

	script:
	merged_vcf = "merged.g.vcf.gz"
	merged_vcf_index = merged_vcf + ".tbi"

	def options = ""
	if (calibration_vcfs) {
		options = "--variant ${calibration_vcfs.join(' --variant ')}"
	}

	"""
	gatk --java-options "-Xmx${task.memory.toGiga()}G" CombineGVCFs  \
		--variant ${vcf_list.join(" --variant ")} \
		--reference $REF \
		--intervals $TARGETS \
		-L $MITOCHONDRION \
		--OVI true \
		--output $merged_vcf \
                $options
	"""

}

// Perform genotyping on a per chromosome basis

process runGenotypeGVCFs {
  
	tag "ALL"
	publishDir "${OUTDIR}/Variants/JointGenotypes"
  
	input:
	set file(merged_vcf), file(merged_vcf_index) from inputGenotypeGVCFs
  
	output:
	set file(gvcf), file(gvcf_index) into (inputHardFilterSNP, inputRecalSNP, inputHardFilterIndel, inputRecalIndel )
  
	script:
  
	gvcf = "genotypes.vcf.gz"
	gvcf_index = gvcf + ".tbi"
  
	"""
 	gatk --java-options "-Xmx${task.memory.toGiga()}G" GenotypeGVCFs \
		--reference $REF \
		--dbsnp $DBSNP \
		-L $TARGETS \
		-L $MITOCHONDRION \
		-new-qual \
		--only-output-calls-starting-in-intervals \
		-V $merged_vcf \
              	--output $gvcf \
                -G StandardAnnotation \
		-OVI true
	"""
}

if ( params.hard_filter == true ) {

	inputRecalSNP = Channel.from(false)
	inputRecalIndel = Channel.from(false)

	process runHardFilterSNP {
		
		tag "ALL"
		//publishDir "${OUTDIR}/Variants", mode: 'copy'

		input:
		set file(vcf),file(vcf_index) from inputHardFilterSNP

		output:
		set file(vcf_filtered),file(vcf_filtered_index) into outputHardFilterSNP

		script:
		vcf_filtered = "genotypes.merged.snps.filtered.vcf.gz"
		vcf_filtered_index = vcf_filtered + ".tbi"

		"""
			gatk SelectVariants \
				-R $REF \
				-V $vcf \
				--select-type-to-include SNP
				-O genotypes.merged.snps.vcf.gz
				-OVI true
				
			gatk VariantFiltration \
				-R $REF \
				-V genotypes.merged.snps.vcf.gz \
				-O $vcf_filtered \
				-filterExpression "${SNP_RULES}" \
				--filterName "hard_snp_filter" \
				-OVI true
		"""

	}

	process runHardFilterIndel {

                tag "ALL"
                //publishDir "${OUTDIR}/Variants", mode: 'copy'

                input:
                set file(vcf),file(vcf_index) from inputHardFilterIndel

                output:
                set file(vcf_filtered),file(vcf_filtered_index) into outputHardFilterIndel

                script:
                vcf_filtered = "genotypes.merged.snps.filtered.vcf.gz"
                vcf_filtered_index = vcf_filtered + ".tbi"

                """
                        gatk SelectVariants \
                                -R $REF \
                                -V $vcf \
                                --select-type-to-include SNP
                                -O genotypes.merged.snps.vcf.gz
                                -OVI true

                        gatk VariantFiltration \
                                -R $REF \
                                -V genotypes.merged.snps.vcf.gz \
                                -O $vcf_filtered \
				--filterExpression "${INDEL_RULES}" \
                                --filterName "hard_indel_filter" \
				-OVI true
                """
        }

        process runCombineHardVariants {

                tag "ALL"
                // publishDir "${OUTDIR}/Variants/Final", mode: 'copy'

                input:
                set file(indel),file(indel_index) from outputHardFilterIndel
		set file(snp),file(snp_index) fromoutputHardFilterSNP

                output:
                set file(merged_file),file(merged_file_index) into inputVep

                script:
                merged_file = "merged_callset.hard.vcf.gz"
                merged_file_index = merged_file + ".tbi"

                """
                        gatk SortVcf -I $indel -O indels.sorted.vcf.gz
                        gatk SortVcf -I $snp -O snps.sorted.vcf.gz
                        picard MergeVcfs \
                        I=indels.sorted.vcf.gz \
                        I=snps.sorted.vcf.gz \
                        O=merged.vcf.gz \
                        R=$REF \

			gatk IndexFeatureFile -F merged.vcf.gz

                        gatk SelectVariants \
                        -R $REF \
                        -V merged.vcf.gz \
                        -O $merged_file \
                        --remove-unused-alternates true \
                        --exclude-non-variants true
                """
	}

} else  {

	inputHardFilterSNP = Channel.from(false)
	inputHardFilterIndel = Channel.from(false)

	process runRecalibrationModeSNP {

        	tag "ALL"
	        //publishDir "${OUTDIR}/Variants/Recal"
		input:
		set file(vcf),file(vcf_index) from inputRecalSNP

		output:
	 	set file(recal_file),file(tranches) into inputRecalSNPApply

		script:
		recal_file = "genotypes.merged.snps.recal"
		tranches = "genotypes.merged.snps.tranches"

		"""

		gatk --java-options "-Xmx${task.memory.toGiga()}G" VariantRecalibrator \
			-R $REF \
			-V $vcf \
	               	-O $recal_file \
       		        --tranches-file $tranches \
			-an MQ -an MQRankSum -an FS -an QD -an SOR -an ReadPosRankSum \
	       	        -mode SNP \
			-OVI true \
			--resource hapmap,known=false,training=true,truth=true,prior=15.0:$HAPMAP \
			--resource omni,known=false,training=true,truth=true,prior=12.0:$OMNI \
			--resource 1000G,known=false,training=true,truth=false,prior=10.0:$G1K \
			--resource dbsnp,known=true,training=false,truth=false,prior=2.0:$DBSNP \
	                -tranche 100.0 -tranche 99.9 -tranche 99.0 -tranche 90.0 \
			--max-gaussians 4
		"""
	}

	process runRecalibrationModeIndel {
	
		tag "ALL"
		// publishDir "${OUTDIR}/Variants/Recal"

  		input:
	  	set file(vcf),file(vcf_index) from inputRecalIndel

  		output:
	  	set file(recal_file),file(tranches),file(vcf),file(vcf_index) into inputRecalIndelApply

  		script:
	  	recal_file = "genotypes.merged.indel.recal"
  		tranches = "genotypes.merged.indel.tranches"

  		"""
		gatk --java-options "-Xmx${task.memory.toGiga()}G" VariantRecalibrator \
        	        -R $REF \
	        	-V $vcf \
	               	-O $recal_file \
        	        --tranches-file $tranches \
               		-an MQ -an MQRankSum -an SOR -an FS -an ReadPosRankSum -an QD -an InbreedingCoeff \
	                -mode INDEL \
			-OVI true \
	        	--resource mills,known=false,training=true,truth=true,prior=15.0:$MILLS \
	               	--resource dbsnp,known=true,training=false,truth=false,prior=2.0:$DBSNP \
			-tranche 100.0 -tranche 99.9 -tranche 99.0 -tranche 90.0 \
			--max-gaussians 3
	  	"""

	}

 	process runRecalIndelApply {

                tag "ALL"
                // publishDir "${OUTDIR}/Variants/Recal"

                input:
                set file(recal_file),file(tranches),file(gvcf),file(gvcf_index) from inputRecalIndelApply

                output:
                set file(vcf_indel),file(vcf_indel_index) into outputRecalIndelApply

                script:

                vcf_indel = "genotypes.recal_Indel.vcf.gz"
                vcf_indel_index = vcf_indel + ".tbi"

                """
                        gatk IndexFeatureFile -F $recal_file
                        gatk --java-options "-Xmx${task.memory.toGiga()}G" ApplyVQSR \
                        -R $REF \
                        -V $gvcf \
                        --recal-file $recal_file \
                        --tranches-file $tranches \
                        -mode INDEL \
                        --ts-filter-level 99.0 \
                        -OVI true \
                         -O $vcf_indel
                """
        }

	process runRecalSNPApply {
	
		tag "ALL"
		// publishDir "${OUTDIR}/Variants/Filtered"
	
		input:
		set file(vcf),file(index) from outputRecalIndelApply
		set file(recal_file),file(tranches) from inputRecalSNPApply

		output:
		set file(vcf_snp),file(vcf_snp_index) into outputRecalSNPApply

		script:
 
		vcf_snp = "genotypes.recal_Indel.recal_SNP.vcf.gz"
		vcf_snp_index = vcf_snp + ".tbi"

		"""
		gatk IndexFeatureFile -F $recal_file
		gatk --java-options "-Xmx${task.memory.toGiga()}G" ApplyVQSR \
			-R $REF \
			-V $vcf \
		        --recal-file $recal_file \
        	       	--tranches-file $tranches \
			-mode SNP \
			--ts-filter-level 99.0 \
			-O $vcf_snp \
			-OVI true	
  		"""
	}

	process runVariantFiltrationIndel {

		tag "ALL"
		// publishDir "${OUTDIR}/Variants/Filtered"

	  	input:
		set file(vcf),file(vcf_index) from outputRecalIndelApply

	  	output:
	  	set file(filtered_gvcf),file(filtered_gvcf_index) into inputSelectVariants

	  	script:

	  	filtered_gvcf = "genotypes.filtered.final.vcf.gz"
		filtered_gvcf_index = filtered_gvcf + ".tbi"

		"""
		gatk --java-options "-Xmx${task.memory.toGiga()}G" VariantFiltration \
        	       -R $REF \
	               	-V $vcf \
			--filter-expression "QD < 2.0" \
			--filter-name "QDFilter" \
                	-O $filtered_gvcf \
			-OVI true
	  	"""
	}

}

process runSelectVariants {

	tag "ALL|${params.assembly}"
	publishDir "${OUTDIR}/Variants/Final", mode: 'copy'

	input:
	set file(vcf),file(vcf_index) from inputSelectVariants

	output:
	set file(vcf_clean),file(vcf_clean_index) into inputVep

	script:
	vcf_clean = params.run_name + ".variants.merged.filtered.controls_removed.vcf.gz"
	vcf_clean_index = vcf_clean + ".tbi"

	"""
		gatk SelectVariants \
		-V $vcf \
		-R $REF \
		-O $vcf_clean \
		-sn $calibration_samples_list_args \
		--remove-unused-alternates true \
		--exclude-non-variants
	
	"""
}

// *********************
// Compute statistics for fastQ files, libraries and samples
// *********************

process runCollectMultipleMetrics {
	tag "${indivID}|${sampleID}"
	publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Picard_Metrics", mode: 'copy'
 
	scratch use_scratch
	    
	input:
	set indivID, sampleID, bam, bai from BamForMultipleMetrics

	output:
	file("${prefix}*") into CollectMultipleMetricsOutput mode flatten

	script:       
	prefix = sampleID + "."

	"""
		picard -Xmx5g CollectMultipleMetrics \
		PROGRAM=MeanQualityByCycle \
		PROGRAM=QualityScoreDistribution \
		PROGRAM=CollectAlignmentSummaryMetrics \
		PROGRAM=CollectInsertSizeMetrics\
       	        PROGRAM=CollectSequencingArtifactMetrics \
                PROGRAM=CollectQualityYieldMetrics \
	        PROGRAM=CollectGcBiasMetrics \
		PROGRAM=CollectBaseDistributionByCycle \
		INPUT=${bam} \
		REFERENCE_SEQUENCE=${REF} \
		DB_SNP=${DBSNP} \
		INTERVALS=${BAITS} \
		ASSUME_SORTED=true \
		QUIET=true \
		OUTPUT=${prefix} \
		TMP_DIR=tmp
	"""
}	

process runHybridCaptureMetrics {

    tag "${indivID}|${sampleID}"
    publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Picard_Metrics", mode: 'copy'

    input:
    set indivID, sampleID, file(bam), file(bai) from runPrintReadsOutput_for_HC_Metrics

    output:
    file(outfile) into HybridCaptureMetricsOutput mode flatten

    script:
    outfile = sampleID + ".hybrid_selection_metrics.txt"

    """
        picard -Xmx${task.memory.toGiga()}G CollectHsMetrics \
                INPUT=${bam} \
                OUTPUT=${outfile} \
                TARGET_INTERVALS=${TARGETS} \
                BAIT_INTERVALS=${BAITS} \
                REFERENCE_SEQUENCE=${REF} \
                TMP_DIR=tmp
        """
}

process runOxoGMetrics {

    tag "${indivID}|${sampleID}"
    publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Picard_Metrics", mode: 'copy'

    input:
    set indivID, sampleID, file(bam), file(bai) from runPrintReadsOutput_for_OxoG_Metrics

    output:
    file(outfile) into runOxoGMetricsOutput mode flatten

    script:
    outfile = sampleID + ".OxoG_metrics.txt"

    """

         picard -Xmx${task.memory.toGiga()}G CollectOxoGMetrics \
                INPUT=${bam} \
                OUTPUT=${outfile} \
                DB_SNP=${DBSNP} \
                INTERVALS=${TARGETS} \
                REFERENCE_SEQUENCE=${REF} \
                TMP_DIR=tmp
        """
}

// ------------------------------------------------------------------------------------------------------------
//
// Plot results with multiqc
//
// ------------------------------------------------------------------------------------------------------------

process runMultiqcFastq {

    tag "Generating fastq level summary and QC plots"
    publishDir "${OUTDIR}/Summary/Fastq", mode: 'copy'
	    
    input:
    file('*') from fastp_results.flatten().toList()
    
    output:
    file("fastp_multiqc*") into runMultiQCFastqOutput
    	
    script:

    """
    cp $baseDir/config/multiqc_config.yaml multiqc_config.yaml
    multiqc -n fastp_multiqc *.json *.html
    """
}

process runMultiqcLibrary {

    tag "Generating library level summary and QC plots"
    publishDir "${OUTDIR}/Summary/Library", mode: 'copy'
	    
    input:
    file('*') from DuplicatesOutput_QC.flatten().toList()

    output:
    file("library_multiqc*") into runMultiQCLibraryOutput
    	
    script:

    """
    cp $baseDir/config/multiqc_config.yaml multiqc_config.yaml
    multiqc -n library_multiqc *.txt
    """
}

process runMultiqcSample {

    tag "Generating sample level summary and QC plots"
    publishDir "${OUTDIR}/Summary/Sample", mode: 'copy'
	    
    input:
    file('*') from CollectMultipleMetricsOutput.flatten().toList()
    file('*') from HybridCaptureMetricsOutput.flatten().toList()
    file('*') from runOxoGMetricsOutput.flatten().toList()
        
    output:
    file("sample_multiqc.html") into runMultiQCSampleOutput
    	
    script:

    def subject = 'Diagnostic exome analysis quality report'
    def recipient = params.email

    """
    cp $baseDir/config/multiqc_config.yaml multiqc_config.yaml
    multiqc -n sample_multiqc *

    """
}

// *************************
// Variant effect prediction
// *************************

process runVep {

 tag "ALL"
 publishDir "${OUTDIR}/Annotation/VEP", mode: 'copy'
 
input:
   file(vcf_file) from inputVep

 output:
   file(annotated_vcf) into outputVep

 when:
 	params.effect_prediction == true

 script:
   annotated_vcf = params.run_name + ".annotation.vep.vcf"

   """
      vep --offline --cache --dir $VEP_CACHE --fork ${task.cpus} \
 	--assembly GRCh37 -i $vcf_file -o $annotated_vcf --allele_number --canonical \
	--force_overwrite --vcf --no_progress \
	--merged \
	--pubmed \
	--plugin LoFtool --plugin LoF \
	--fasta ${params.vep_fasta}
   """

}

workflow.onComplete {
  log.info "========================================="
  log.info "Duration:		$workflow.duration"
  log.info "========================================="

  if (params.email) {

            def subject = 'Diagnostic exome analysis finished.'
            def recipient = params.email

            ['mail', '-s', subject, recipient].execute() << """

            Pipeline execution summary
            ---------------------------
            Completed at: ${workflow.complete}
            Duration    : ${workflow.duration}
            Success     : ${workflow.success}
            workDir     : ${workflow.workDir}
            exit status : ${workflow.exitStatus}
            Error report: ${workflow.errorReport ?: '-'}
            """
  }

}


//#############################################################################################################
//#############################################################################################################
//
// FUNCTIONS
//
//#############################################################################################################
//#############################################################################################################


// ------------------------------------------------------------------------------------------------------------
//
// Read input file and save it into list of lists
//
// ------------------------------------------------------------------------------------------------------------
def logParams(p, n) {
  File file = new File(n)
  file.write "Parameter:\tValue\n"

  for(s in p) {
     file << "${s.key}:\t${s.value}\n"
  }
}

