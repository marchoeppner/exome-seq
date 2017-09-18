#!/usr/bin/env nextflow

/**
IKMB Diagnostic Exome Pipeline

This Pipeline performs one of two workflows to generate variant calls and effect predictions
using either the GATK processing chain or Freebayes
**/

inputFile = file(params.samples)

// Specify the tool chain to use - can be either gatk for GATK4 or freebayes for Freebayes 1.10
params.tool = "gatk"

// This will eventually enable switching between multiple assembly versions
// Currently, only hg19 has all the required reference files available
params.assembly = "hg19"

if (params.genomes.containsKey(params.assembly) == false) {
   exit 1, "Specified unknown genome assembly, please consult the documentation for valid kits."
}

REF = file(params.genomes[ params.assembly ].fasta)
DBSNP = file(params.genomes[ params.assembly ].dbsnp )
G1K = file(params.genomes[ params.assembly ].g1k )
GOLD1 = file(params.genomes[ params.assembly ].gold )
OMNI = file(params.genomes[ params.assembly ].omni )
HAPMAP = file(params.genomes[ params.assembly ].hapmap )

PICARD = file(params.picard_jar)
OUTDIR = file(params.outdir)

if (params.kits.containsKey(params.kit) == false) {
   exit 1, "Specified unknown Exome kit, please consult the documentation for valid kits."
}

TARGETS= params.kits[ params.kit ].targets
BAITS= params.kits[ params.kit ].baits

// We add 17 reference exome gVCFs to make sure that variant filtration works
// These are in hg19 so need to be updated to other assemblies if multiple assemblies are to be supported
calibration_exomes = file(params.calibration_exomes)
calibration_samples_list = file(params.calibration_exomes_samples)

TRIMMOMATIC=file(params.trimmomatic)

params.email = false

// Whether to use a local scratch disc
use_scratch = params.scratch

leading = params.leading
trailing = params.trailing
slidingwindow = params.slidingwindow
minlen = params.minlen
adapters = params.adapters

logParams(params, "nextflow_parameters.txt")

VERSION = "0.1"

// Header log info
log.info "========================================="
log.info "IKMB Diagnostic Exome pipeline v${VERSION}"
log.info "Nextflow Version:	$workflow.nextflow.version"
log.info "Adapter sequence used: ${adapters}"
log.info "Command Line:		$workflow.commandLine"
log.info "========================================="

Channel.from(inputFile)
       .splitCsv(sep: ';', header: true)
       .set {  readPairsTrimmomatic }

process runTrimmomatic {

    tag "${indivID}|${sampleID}|${libraryID}|${rgID}"
    publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Libraries/${libraryID}/${rgID}/Trimmomatic/", mode: 'copy'

    scratch use_scratch

    input:
    set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, run_date, center, fastqR1, fastqR2 from readPairsTrimmomatic

    output:
    set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, run_date, center, file("${libraryID}_R1.paired.fastq.gz"),file("${libraryID}_R2.paired.fastq.gz") into inputBwa, readPairsFastQC

    script:

    """
	java -jar ${TRIMMOMATIC}/trimmomatic-0.36.jar PE -threads 8 $fastqR1 $fastqR2 ${libraryID}_R1.paired.fastq.gz ${libraryID}.1U.fastq.gz ${libraryID}_R2.paired.fastq.gz ${libraryID}.2U.fastq.gz ILLUMINACLIP:${TRIMMOMATIC}/adapters/${adapters}:2:30:10:3:TRUE LEADING:${leading} TRAILING:${trailing} SLIDINGWINDOW:${slidingwindow} MINLEN:${minlen}
     """
}

process runBWA {

    tag "${indivID}|${sampleID}|${libraryID}|${rgID}"
    publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Libraries/${libraryID}/${rgID}/BWA/", mode: 'copy'

    scratch use_scratch
	
    input:
    set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, run_date, center,file(left),file(right) from inputBwa
    
    output:
    set indivID, sampleID, file(outfile) into runBWAOutput
    
    script:
    outfile = sampleID + "_" + libraryID + "_" + rgID + ".aligned.bam"	

    """
	bwa mem -M -R "@RG\\tID:${rgID}\\tPL:ILLUMINA\\tPU:${platform_unit}\\tSM:${indivID}_${sampleID}\\tLB:${libraryID}\\tDS:${REF}\\tCN:${center}" -t 16 ${REF} $left $right | samtools sort - > $outfile
    """	
}

runBWAOutput_grouped_by_sample = runBWAOutput.groupTuple(by: [0,1])


process runMarkDuplicates {

	tag "${indivID}|${sampleID}"
        publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/MarkDuplicates", mode: 'copy'

        scratch use_scratch

        input:
        set indivID, sampleID, aligned_bam_list from runBWAOutput_grouped_by_sample

        output:
        set indivID, sampleID, file(outfile_bam),file(outfile_bai) into MarkDuplicatesOutput, BamForMultipleMetrics
	file(outfile_bam) into FreebayesBamInput
	file(outfile_bai) into FreebayesBaiInput

	file(outfile_metrics) into DuplicatesOutput_QC

        script:
        outfile_bam = sampleID + ".dedup.bam"
        outfile_bai = sampleID + ".dedup.bai"

        outfile_metrics = sampleID + "_duplicate_metrics.txt"

	if (params.tool == "freebayes") {

		"""
        	java -Xmx25G -XX:ParallelGCThreads=5 -Djava.io.tmpdir=tmp/ -jar ${PICARD} MarkDuplicates \
                	INPUT=${aligned_bam_list.join(" INPUT=")} \
	                OUTPUT=${outfile_bam} \
        	        METRICS_FILE=${outfile_metrics} \
                        CREATE_INDEX=true \
                        TMP_DIR=tmp
       		"""

	} else if (params.tool == "gatk") {
		"""
                gatk-launch --javaOptions "-Xmx25G" MarkDuplicates \
                       	--input ${aligned_bam_list.join(" --input ")} \
                        --output ${outfile_bam} \
                        --reference ${REF} \
                        --METRICS_FILE ${outfile_metrics} \
                        --CREATE_INDEX true \
                        --TMP_DIR tmp \
                        --CREATE_MD5_FILE true
   	       	"""
	}

}

// *******************
// FREEBAYES WORKFLOW
// *******************

if (params.tool == "freebayes") {

	process runFreebayes {

		tag "ALL"
                publishDir "${OUTDIR}/Variants", mode: 'copy'

		input:
		file(bam_files) from FreebayesBamInput.collect()
		file(bai_files) from FreebayesBaiInput.collect()

		output:
		file(vcf) into outputFreebayes
		
		script:
		vcf = "freebayes.vcf"

		"""
			freebayes-parallel <(fasta_generate_regions.py ${REF}.fai 100000) ${task.cpus} -f ${REF} ${bam_files} > ${vcf}
		"""
	
	}

	process runFilterVcf {

		tag "ALL"
		publishDir "${OUTDIR}/Variants", mode: 'copy'	

		input:
		file(vcf) from outputFreebayes

		output:
		file(vcf_filtered) into ( inputVep, inputAnnovar )

		script: 
		vcf_filtered = "freebayes.filtered.vcf"

		"""
			vcftools --vcf ${vcf} --minQ 20 --out ${vcf_filtered}
		"""
	}

// *********************
// GATK WORKFLOW
// *********************
} else if (params.tool == "gatk") {

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
    		publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/BaseRecalibrator/", mode: 'copy'
	    
    		input:
    		set indivID, sampleID, dedup_bam, dedup_bai from MarkDuplicatesOutput
    
    		output:
    		set indivID, sampleID, dedup_bam, file(recal_table) into runBaseRecalibratorOutput
    
    		script:
    		recal_table = sampleID + "_recal_table.txt" 
       
    		"""
			gatk-launch --javaOptions "-Xmx25G" BaseRecalibrator \
			--reference ${REF} \
			--input ${dedup_bam} \
			--knownSites ${GOLD1} \
			--knownSites ${DBSNP} \
        	        --knownSites ${G1K} \
			--output ${recal_table}
		"""
	}

	process runPrintReads {

		tag "${indivID}|${sampleID}"
    		publishDir "${OUTDIR}/${indivID}/${sampleID}/", mode: 'copy'

    		scratch use_scratch
	    
    		input:
    		set indivID, sampleID, realign_bam, recal_table from runBaseRecalibratorOutput 

    		output:
    		set indivID, sampleID, file(outfile_bam), file(outfile_bai) into BamForDepthOfCoverage, runPrintReadsOutput_for_HC_Metrics, runPrintReadsOutput_for_Multiple_Metrics, runPrintReadsOutput_for_OxoG_Metrics
    		set indivID, sampleID, realign_bam, recal_table into runPrintReadsOutput_for_PostRecal
    		set indivID, sampleID, outfile_bam into inputHCSample
            
    		script:
    		outfile_bam = sampleID + ".clean.bam"
    		outfile_bai = sampleID + ".clean.bai"
           
    		"""
			gatk-launch --javaOptions "-Xmx25G" PrintReads \
				--reference ${REF} \
				--input ${realign_bam} \
				--BQSR ${recal_table} \
				--outfile ${outfile_bam} \
				--createOutputBamMD5 true
    		"""
	}    

	process runBaseRecalibratorPostRecal {

		tag "${indivID}|${sampleID}"
    		publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/BaseRecalibratorPostRecal/", mode: 'copy'
	    
    		input:
    		set indivID, sampleID, realign_bam, recal_table from runPrintReadsOutput_for_PostRecal
    
    		output:
    		set indivID, sampleID, recal_table, file(post_recal_table) into runBaseRecalibratorPostRecalOutput_Analyze
        
    		script:
    		post_recal_table = sampleID + "_post_recal_table.txt" 
   
    		"""
			gatk-launch --javaOptions "-Xmx25G" BaseRecalibrator \
			--reference ${REF} \
			--input ${realign_bam} \
			--knownSites ${GOLD1} \
			--knownSites ${DBSNP} \
			--bqsr_recal_file ${recal_table} \
			--outfile ${post_recal_table}
		"""
	}	

	process runAnalyzeCovariates {

    		tag "${indivID}|${sampleID}"
    		publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/AnalyzeCovariates/", mode: 'copy'
	    
    		input:
    		set indivID, sampleID, recal_table, post_recal_table from runBaseRecalibratorPostRecalOutput_Analyze

		output:
		set indivID, sampleID, recal_plots into runAnalyzeCovariatesOutput
	    
    		script:
    		recal_plots = sampleID + "_recal_plots.pdf" 

    		"""
			gatk-launch --javaOptions "-Xmx5G" AnalyzeCovariates \
				--reference ${REF} \
				--beforeReportFile ${recal_table} \
				--afterReportFile ${post_recal_table} \
				--plotsReportFile ${recal_plots}
		"""
	}    

	// ------------------------------------------------------------------------------------------------------------
	//
	// Perform a several tasks to assess QC:
	// 1) Depth of coverage over targets
	// 2) Generate alignment stats, insert size stats, quality score distribution
	// 3) Generate hybrid capture stats
	// 4) Run FASTQC to assess read quality
	//
	// ------------------------------------------------------------------------------------------------------------

	process runDepthOfCoverage {

    		tag "${indivID}|${sampleID}"
    		publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/DepthOfCoverage", mode: 'copy'

    		scratch use_scratch
	    
    		input:
    		set indivID, sampleID, bam, bai from BamForDepthOfCoverage

    		output:
    		file("${prefix}*") into DepthOfCoverageOutput
    
    		script:
    		prefix = sampleID + "."

    		"""

			java -XX:ParallelGCThreads=1 -Djava.io.tmpdir=tmp/ -Xmx10g -jar ${GATK} \
			-R ${REF} \
			-T DepthOfCoverage \
			-I ${bam} \
			--omitDepthOutputAtEachBase \
			-ct 10 -ct 20 -ct 50 -ct 100 \
			-o ${sampleID}

		"""
	}	

	process runHCSample {

  		tag "${indivID}|${sampleID}"
  		publishDir "${OUTDIR}/${indivID}/${sampleID}/Variants/HaplotypeCaller/${id}" , mode: 'copy'

  		input: 
  		set indivID,sampleID,file(bam) from inputHCSample

  		output:
  		file(vcf) into outputHCSample

  		script:
  
  		vcf = id + ".raw_variants.g.vcf"

  		"""
		gatk-launch --javaOptions "-Xmx25G" HaplotypeCaller \
			-R $REF \
			-I $bam \
			-L $TARGETS \
			-L chrM \
			--genotyping_mode DISCOVERY \
			--emitRefConfidence GVCF \
    			-o $vcf \
  		"""
	}

	inputHCJoined = outputHCSample.collect()

	process runJoinedGenotyping {
  
  		tag "ALL - using 17 IKMB reference exomes for calibration"
  		publishDir "${OUTDIR}/Variants/JoinedGenotypes"
  
  		input:
  		file(vcf_list) from inputHCJoined
  
  		output:
  		file(gvcf) into (inputRecalSNP , inputRecalIndel)
  
  		script:
  
  		gvcf = "genotypes.gvcf"
  
  		"""
	 	gatk-launch --javaOptions "-Xmx25G" GenotypeGVCFs \
                	-R $REF \
                	--variant ${vcf_list.join(" --variant ")} \
			--variant $calibration_exomes \
			--dbsnp $DBSNP \
                	-o $gvcf \
			--useNewAFCalculator
  		"""
	}

	process runRecalibrationModeSNP {

  		tag "ALL"
  		publishDir "${OUTDIR}/Variants/Recal"

  		input:
  		file(gvcf) from inputRecalSNP

  		output:
	  	set file(recal_file),file(tranches),file(rscript),file(gvcf) into inputRecalSNPApply

  		script:
  		recal_file = "genotypes.recal_SNP.recal"
  		tranches = "genotypes.recal_SNP.tranches"
  		rscript = "genotypes.recal_SNP.R"

  		"""
		gatk-launch --javaOptions "-Xmx25G" VariantRecalibrator \
			-R $REF \
			-input $gvcf \
                	--recal_file $recal_file \
        	        --tranches_file $tranches \
	                --rscript_file $rscript \
			-an MQ -an MQRankSum -an ReadPosRankSum -an FS -an DP \
        	        --mode SNP \
			-resource:hapmap,known=false,training=true,truth=true,prior=15.0 $HAPMAP \
			-resource:omni,known=false,training=true,truth=true,prior=12.0 $OMNI \
			-resource:1000G,known=false,training=true,truth=false,prior=10.0 $G1K \
			-resource:dbsnp,known=true,training=false,truth=false,prior=2.0 $DBSNP \
  		"""
	}

	process RunRecalibrationModeIndel {

  		tag "ALL"
  		publishDir "${OUTDIR}/Variants/Recal"

  		input:
  		file(gvcf) from inputRecalIndel

  		output:
  		set file(recal_file),file(tranches),file(rscript),file(gvcf) into inputRecalIndelApply

  		script:

  		recal_file = "genotypes.recal_Indel.recal"
  		tranches = "genotypes.recal_Indel.tranches"
		rscript = "genotypes.recal_Indel.R"

  		"""
	        gatk-launch --javaOptions "-Xmx25G" VariantRecalibrator \
        	        -R $REF \
	                -input $gvcf \
                	--recal_file $recal_file \
        	        --tranches_file $tranches \
	                --rscript_file $rscript \
                	-an MQ -an MQRankSum -an SOR -an ReadPosRankSum -an FS  \
        	        --mode INDEL \
	                -resource:mills,known=false,training=true,truth=true,prior=15.0 $GOLD1 \
                	-resource:dbsnp,known=true,training=false,truth=false,prior=2.0 $DBSNP \
  		"""
	}

	process runRecalSNPApply {

  		tag "ALL"
  		publishDir "${OUTDIR}/Variants/Filtered"

  		input:
  		set file(recal_file),file(tranches),file(rscript),file(gvcf) from inputRecalSNPApply

  		output:
  		file vcf_snp   into outputRecalSNPApply

  		script:
 
  		vcf_snp = "genotypes.recal_SNP.vcf"

  		"""
	 	gatk-launch --javaOptions "-Xmx25G" ApplyRecalibration \
			-R $REF \
			-input $gvcf \
		        -recalFile $recal_file \
                	-tranchesFile $tranches \
			--mode SNP \
			--ts_filter_level 99.0 \
			-o $vcf_snp	
  		"""
	}

	process runRecalIndelApply {

  		tag "ALL"
	  	publishDir "${OUTDIR}/Variants/Recal"

  		input:
	  	set file(recal_file),file(tranches),file(rscript),file(gvcf) from inputRecalIndelApply

	  	output:
	  	file vcf_indel into outputRecalIndelApply

	  	script:

  		vcf_indel = "genotypes.recal_Indel.vcf"

  		"""
        	gatk-launch --javaOptions "-Xmx25G" ApplyRecalibration \
                	-R $REF \
	                -input $gvcf \
        	        -recalFile $recal_file \
                	-tranchesFile $tranches \
	                --mode Indel \
        	        --ts_filter_level 99.0 \
                	-o $vcf_indel
	  	"""
	}

	process runVariantFiltrationIndel {

  		tag "ALL"
  		publishDir "${OUTDIR}/Variants/Filtered"

	  	input:
  		file(gvcf) from outputRecalIndelApply

	  	output:
	  	file(filtered_gvcf) into outputVariantFiltrationIndel

	  	script:

	  	filtered_gvcf = "genotypes.recal_Indel.filtered.vcf"

  		"""
		gatk-launch --javaOptions "-Xmx25G" VariantFiltration \
                -R $REF \
                -V $gvcf \
		-filter "QD < 2.0" \
		-filterName "QDFilter" \
                -o $filtered_gvcf
  		"""
	}

	inputCombineVariants = outputVariantFiltrationIndel.mix(outputRecalSNPApply)

	process runCombineVariants {

  	tag "ALL"
  	publishDir "${OUTDIR}/Variants/Final", mode: 'copy'

  	input: 
     	set file(indel),file(snp) from inputCombineVariants.collect()

  	output:
	file(merged_file) into outputCombineVariants

	script:
	merged_file = "merged_callset.vcf"

	"""
		gatk-launch --javaOptions "-Xmx25G" CombineVariants \
		-R $REF \
		--variant $indel --variant $snp \
		-o $merged_file \
		--genotypemergeoption UNSORTED
  	"""
	}

	process runRemoveCalibrationExomes {

	  tag "ALL"
	  publishDir "${OUTDIR}/Variants/Final", mode: 'copy'

	  input:
	  file(merged_vcf) from outputCombineVariants

	  output:
	  file(filtered_vcf) into (inputVep, inputAnnovar)

	  script:
	  filtered_vcf = "merged_callset.calibration_removed.vcf"

	  """
		gatk-launch --javaOptions "-Xmx25G" SelectVariants \
	        -R $REF \
		-V $merged_vcf \
		--exclude_sample_file $calibration_samples_list \
        	-o $filtered_vcf
  	"""
  
	}

} 

// *********************
// JOINT REPORTING
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
		java -XX:ParallelGCThreads=1 -Xmx5g -Djava.io.tmpdir=tmp/ -jar $PICARD CollectMultipleMetrics \
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
		ASSUME_SORTED=true \
		QUIET=true \
		OUTPUT=${prefix} \
		TMP_DIR=tmp
	"""
}	

process runFastQC {

    tag "${indivID}|${sampleID}|${libraryID}|${rgID}"
    publishDir "${OUTDIR}/${indivID}/${sampleID}/Processing/Libraries/${libraryID}/${rgID}/FastQC/", mode: 'copy'

    scratch use_scratch

    input:
    set indivID, sampleID, libraryID, rgID, platform_unit, platform, platform_model, run_date, center, fastqR1, fastqR2 from readPairsFastQC

    output:
    set file("*.zip"), file("*.html") into FastQCOutput
    	
    script:
    """
    fastqc -t 1 -o . ${fastqR1} ${fastqR2}
    """
}



// ------------------------------------------------------------------------------------------------------------
//
// Plot results with multiqc
//
// ------------------------------------------------------------------------------------------------------------

process runMultiQCFastq {

    tag "Generating fastq level summary and QC plots"
	publishDir "${OUTDIR}/Summary/Fastq", mode: 'copy'
	    
    input:
    file('*') from FastQCOutput.flatten().toList()
    
    output:
    file("fastq_multiqc*") into runMultiQCFastqOutput
    	
    script:

    """
    multiqc -n fastq_multiqc *.zip *.html
    """
}

process runMultiQCLibrary {

    tag "Generating library level summary and QC plots"
	publishDir "${OUTDIR}/Summary/Library", mode: 'copy'
	    
    input:
    file('*') from DuplicatesOutput_QC.flatten().toList()

    output:
    file("library_multiqc*") into runMultiQCLibraryOutput
    	
    script:

    """

    multiqc -n library_multiqc *.txt
    """
}

process runMultiQCSample {

    tag "Generating sample level summary and QC plots"
	publishDir "${OUTDIR}/Summary/Sample", mode: 'copy'
	    
    input:
     file('*') from CollectMultipleMetricsOutput.flatten().toList()
        
    output:
    file("sample_multiqc*") into runMultiQCSampleOutput
    	
    script:

    """
    multiqc -n sample_multiqc *.txt
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
   file('annotation.vep') into outputVep

 script:

   """
     $VEP --offline --cache --dir \$ENSEMBLCACHE --fork 8 \
 	--assembly GRCh37 -i $vcf_file -o annotation.vep --allele_number --canonical \
	--force_overwrite --vcf --no_progress \
	--pubmed \
	--plugin ExAC,/ifs/data/nfs_share/ikmb_repository/references/exac/0.3.1/ExAC.r0.3.1.sites.vep.vcf.gz \
	--plugin CADD,/ifs/data/nfs_share/ikmb_repository/references/cadd/1.3/whole_genome_SNVs.tsv.gz \
	--plugin LoFtool --plugin LoF \
	--fasta /ifs/data/nfs_share/ikmb_repository/references/genomes/homo_sapiens/EnsEMBL/GRCh37/genome.fa
   """

}

process runAnnovar {

 tag "ALL"
 publishDir "${OUTDIR}/Annotation/Annovar", mode: 'copy'

 input:
   file(vcf_file) from inputAnnovar

 output:
   file(annovar_result) into outputAnnovar

 script:
  annovar_target = vcf_file + ".annovar"
  annovar_result = vcf_file + ".annovar.hg19_multianno.vcf"

   """
      $ANNOVAR -v \
	--protocol ensGene,knownGene,refGene,genomicSuperDups,hrcr1,esp6500siv2_all,exac03nontcga,kaviar_20150923,1000g2014oct_all,cg69,145_ikmb_control_exomes.gatk.flt.frq,snp138,avsnp144,clinvar_20160302,dann_gw,fathmm_gw,cadd_gw,eigen,dbnsfp30a,dbscsnv11,dbnsfp31a_interpro,ljb26_all \
	--operation g,g,g,r,f,f,f,f,f,f,f,f,f,f,f,f,f,f,f,f,f,f \
	--outfile $annovar_target \
	--buildver hg19 \
	--remove \
        --thread 8 \
	--otherinfo \
	--vcfinput \
	${vcf_file} /ifs/data/nfs_share/sukmb205/annovar/humandb/
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

