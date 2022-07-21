process GATK_GENOTYPEGVCFS {

	label 'gatk'

	input:
	tuple path(gvcf),path(tbi)
	path(intervals)

	output:
	tuple path(vcf),path(tbi), emit: vcf

	script:
	vcf = gvcf.getSimpleName() + ".genotyped.vcf.gz"
	tbi = vcf + ".tbi"

	"""
		gatk --java-options "-Xmx4g" GenotypeGVCFs \
			-R $params.fasta \
			-V $gvcf -L $intervals -O $vcf \
			-G StandardAnnotation -G AS_StandardAnnotation \
			--allow-old-rms-mapping-quality-annotation-data \
			-ip $params.interval_padding -OVI true
	"""

}
