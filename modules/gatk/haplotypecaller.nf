process GATK_HAPLOTYPECALLER {

	tag "${meta.patient_id}|${meta.sample_id}"
	
	publishDir "${params.outdir}/${meta.patient_id}/${meta.sample_id}/GATK/HC", mode: 'copy'

	label 'gatk'

	input:
	tuple val(meta),path(bam),path(bai)
	path(intervals)
	val(modus)

	output:
	tuple val(meta),path(vcf),path(tbi), emit: vcf
	tuple val(meta),path(bam_out),path(bai_out), optional: true, emit: bam

	script:
	def options = ""
	if (modus == "single") {
		vcf = bam.getBaseName() + ".hc.vcf.gz"
		tbi = vcf + ".tbi"
		bam_out = bam.getBaseName() + ".hc.bam"
		bai_out = bam.getBaseName() + ".hc.bai"
		options = "--bam-output $bam_out -OBI true"
	} else {
		vcf = bam.getBaseName() + ".hc.vcf.gz"
		tbi = vcf + ".tbi"
		options = "-ERC GVCF -G AS_StandardAnnotation"
	}

	//  -GQB 10 -GQB 20 -GQB 30 -GQB 40 -GQB 50 -GQB 60 -GQB 70 -GQB 80 -GQB 90
	"""
		gatk HaplotypeCaller --java-options "-Xmx${task.memory.giga}g" -R $params.fasta -I $bam -L $intervals -O $vcf \
			$options \
			-G StandardAnnotation -G StandardHCAnnotation \
			-OVI true -ip ${params.interval_padding} -D ${params.dbsnp} 
	"""
}

