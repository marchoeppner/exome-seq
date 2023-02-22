include { STRELKA_SINGLE_SAMPLE as STRELKA } from './../../modules/strelka/strelka_single.nf'
include { PICARD_SORTVCF  as VCF_GATK_SORT } from "./../../modules/picard/sortvcf"
include { BCFTOOLS_ANNOTATE  as VCF_ADD_HEADER } from "./../../modules/bcftools/annotate"
include { TABIX as VCF_INDEX } from "./../../modules/htslib/tabix"
include { BCFTOOLS_ANNOTATE_DBSNP as VCF_ADD_DBSNP } from "./../../modules/bcftools/annotate_dbsnp"
include { BCFTOOLS_VIEW as VCF_FILTER_PASS } from "./../../modules/bcftools/view"
include { BCFTOOLS_MERGE as MERGE_VCF } from "./../../modules/bcftools/merge"
include { GATK_SELECTVARIANTS as VCF_GET_SAMPLE } from "./../../modules/gatk/selectvariants"
include { BCFTOOLS_NORMALIZE as VCF_INDEL_NORMALIZE } from './../../modules/bcftools/normalize'

workflow STRELKA_SINGLE_CALLING {

        ch_merged_vcf = Channel.empty()
        ch_vcf = Channel.empty()

	take:
	bam
	bed
	sample_names
	fasta
	dbsnp

	main:

	STRELKA(
		bam,
		bed.collect(),
		fasta.collect()
	)
	VCF_INDEX(STRELKA.out.vcf)
        VCF_FILTER_PASS(VCF_INDEX.out.vcf)
        VCF_ADD_DBSNP(VCF_FILTER_PASS.out.vcf,dbsnp)
	VCF_ADD_HEADER(VCF_ADD_DBSNP.out.vcf.map { meta,v,t ->
			new_meta = [ id: meta.id, sample_id: meta.sample_id, patient_id: meta.patient_id, variantcaller: "STRELKA" ]
			tuple(new_meta,v,t)
		}
	)
	single_vcf = ch_vcf.mix(VCF_ADD_HEADER.out.vcf)

	bam.map { m,b,i -> 
		new_key = m.sample_id
		tuple(new_key,b,i)
	}.set { ch_bams_key }

	single_vcf.map { m,v,t ->
		new_key = m.sample_id
		tuple(new_key,m,v,t)
	}.set { ch_vcfs_key }

	//WHATSHAP_SINGLE(
	//	ch_vcfs_key.join(ch_bams_key).map { n,m,v,t,b,i -> [ m,v,t,b,i ] }
	//)

	// Fiddly work-around to determine whether we have 1 or multiple vcfs. No merging when n=1
	VCF_FILTER_PASS.out.vcf.map { m,v,t ->
		def new_meta = [ id: "all", sample_id: "UNDEFINED", patient_id: "UNDEFINED", variantcaller: "STRELKA" ]
		tuple(new_meta,v,t)
	}
	.groupTuple()
	.branch { m,v,t ->
                        single: v.size() == 1
                        multi: v.size() > 1
        }.set { ch_grouped_vcfs }

	MERGE_VCF(
                ch_grouped_vcfs.multi.map { m,v,t -> [ [ id: "all", sample_id: "Bcftools", patient_id: "MergedCallset", variantcaller: "STRELKA"],v,t] }
	)
        ch_merged_vcf = ch_merged_vcf.mix(MERGE_VCF.out.vcf)

	emit:
	vcf = single_vcf
	vcf_multi = ch_merged_vcf
	ch_phased_multi = Channel.empty()
}
