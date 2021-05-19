configfile: "config.yml"


from glob import glob 
import re
import os
# include "rules/illumina.smk"
# include "rules/qc.smk"

def get_final_output():
    final_output = []
    final_output.extend(expand("{out_dir}/qc/fastqc/{sample}_{pair}_fastqc.html", sample=SAMPLES, pair=[1,2], out_dir=[OUT_DIR])),
    # final_output.extend(expand("{out_dir}/mapped/{sample}.primertrimmed.sorted.bam", sample=SAMPLES, out_dir=[OUT_DIR])),
    final_output.extend(expand("{out_dir}/variants/{sample}.variants.tsv", sample=SAMPLES, out_dir=[OUT_DIR])),
    # final_output.extend(expand("consensus/{sample}.primertrimmed.consensus.fa", sample=SAMPLES))
    # final_output.extend()
    

    return final_output

# Global variable 
GENOME = config["GENOME"]
GENOME_BWA_INDEX = GENOME + ".bwt"
GENOME_FAI_INDEX = GENOME + ".fai"
GENOME_NAME="NC_045512.2"
OUT_DIR = config["OUT_DIR"]
PRIMER_DIR = config["PRIMER_DIR"]
PRIMER_BED = os.path.join(PRIMER_DIR, "nCoV-2019.primer.bed")
# Get samples names from fastq 
FASTQ_DIR= config["FASTQ_DIR"]

SAMPLES = [re.search(FASTQ_DIR+r"/(.+)_1.fastq.gz",i).group(1) for i in glob(os.path.join(FASTQ_DIR,"*_1.fastq.gz"))]

print(SAMPLES)


rule root:
    input:
        get_final_output(),
        OUT_DIR +"/annotation/pangolin_lineage_report.csv"


rule fastqc:
    conda: 
        "envs/illumina/environment.yml",
    input:
        R1=FASTQ_DIR + "/{sample}_1.fastq.gz",
        R2=FASTQ_DIR + "/{sample}_2.fastq.gz",
    output:
        html1=OUT_DIR + "/qc/fastqc/{sample}_1_fastqc.html",
        html2=OUT_DIR +"/qc/fastqc/{sample}_2_fastqc.html",
    log:
        OUT_DIR +"/logs/fastqc/{sample}.log",
    params:
        out_dir=OUT_DIR + "/qc/fastqc/",
    shell:
        """
        fastqc -o {params.out_dir} -f fastq -q {input.R1} {input.R2}
        """  

rule readTrimming:
    conda: 
        "envs/illumina/environment.yml",

    input:
        R1=FASTQ_DIR + "/{sample}_1.fastq.gz",
        R2=FASTQ_DIR + "/{sample}_2.fastq.gz",

    output:
        OUT_DIR +"/trimmed/{sample}_1_val_1.fq.gz",
        OUT_DIR +"/trimmed/{sample}_2_val_2.fq.gz",
    log:
        OUT_DIR +"/logs/trimmed/{sample}_1.log",
        OUT_DIR +"/logs/trimmed/{sample}_2.log",
    params:
        out_dir=OUT_DIR +"/trimmed"
    shell:
        "trim_galore --paired {input.R1} {input.R2} -o {params.out_dir}"


rule index_genome:
    conda: "envs/illumina/environment.yml"
    input:
        GENOME
    output:
        GENOME_FAI_INDEX,
        GENOME_BWA_INDEX
    shell:
        "bwa index {input}; samtools faidx {input}"

rule bwa_align:
    conda: "envs/illumina/environment.yml"
    input:
        R1=OUT_DIR +"/trimmed/{sample}_1_val_1.fq.gz",
        R2=OUT_DIR +"/trimmed/{sample}_2_val_2.fq.gz",
        index=GENOME_BWA_INDEX

    output:
        OUT_DIR +"/mapped/{sample}.sam"
    log:
        OUT_DIR +"/logs/mapped/{sample}.log"
    params:
        genome = GENOME
    shell:
        "bwa mem -R '@RG\\tID:{wildcards.sample}\\tSM:{wildcards.sample}' {params.genome} {input.R1} {input.R2} > {output} 2> {log}"


rule sam2bam:
    conda: "envs/illumina/environment.yml"
    input:
        OUT_DIR +"/mapped/{sample}.sam"
    output:
        OUT_DIR +"/bams/{sample}.bam"
    shell:
        "samtools sort -O BAM {input} > {output}"


rule samIndex:
    conda: "envs/illumina/environment.yml"
    input:
        OUT_DIR +"/bams/{sample}.bam"
    output:
        OUT_DIR +"/bams/{sample}.bam.bai"
    shell:
        "samtools index {input}"


rule trimPrimerSequences:
    conda: 
        "envs/illumina/environment.yml",
    input:
        bam=OUT_DIR +"/bams/{sample}.bam",
        bai=OUT_DIR +"/bams/{sample}.bam.bai",
        bedfile=PRIMER_BED

    output:
        mapped=OUT_DIR +"/mapped/{sample}.mapped.bam",
        ptrim=OUT_DIR +"/mapped/{sample}.primertrimmed.sorted.bam",

    log:
        "logs/primer_trime/{sample}_trimPrimerSequences.log",

    params:
        ivarCmd = "ivar trim -e" if config["allowNoprimer"] else "ivar trim",
        illuminaKeepLen = config["illuminaKeepLen"],
        illuminaQualThreshold = config["illuminaQualThreshold"],
        cleanBamHeader = config["cleanBamHeader"]
    
    script:
        "bin/trimPrimerSequences.py"


rule callVariants:
    conda: 
        "envs/illumina/environment.yml",

    input:
        bam=OUT_DIR +"/mapped/{sample}.primertrimmed.sorted.bam",
        genome=GENOME

    output:
        OUT_DIR +"/variants/{sample}.variants.tsv",

    params:
        ivarMinDepth=config["ivarMinDepth"],
        ivarMinVariantQuality=config["ivarMinVariantQuality"],
        ivarMinFreqThreshold=config["ivarMinFreqThreshold"]

    shell:
        """
        samtools mpileup -A -d 0 --reference {input.genome} -B -Q 0 {input.bam} |\
        ivar variants -r {input.genome} -m {params.ivarMinDepth} -p {wildcards.sample}.variants -q {params.ivarMinVariantQuality} -t {params.ivarMinFreqThreshold} 
        mv  {wildcards.sample}.variants.tsv {output}
        """

rule makeConsensus:
    conda: 
        "envs/illumina/environment.yml",

    input:
        bam=OUT_DIR +"/mapped/{sample}.primertrimmed.sorted.bam",

    output:
        fasta=OUT_DIR +"/consensus/{sample}.primertrimmed.consensus.fa",
        quality=OUT_DIR +"/consensus/{sample}.primertrimmed.consensus.qual.txt"
        # quallity=directory("consensus")
    params:
        mpileupDepth=config["mpileupDepth"],
        ivarFreqThreshold=config["ivarFreqThreshold"],
        ivarMinDepth=config["ivarMinDepth"],


    shell:
        """
        samtools mpileup -aa -A -B -d {params.mpileupDepth} -Q0 {input.bam} | \
        ivar consensus -t {params.ivarFreqThreshold} -m {params.ivarMinDepth} \
        -n N -p {wildcards.sample}.primertrimmed.consensus.fa
        mv {wildcards.sample}.primertrimmed.consensus.fa {output.fasta}
        mv {wildcards.sample}.primertrimmed.consensus.qual.txt {output.quality}
        """

rule pangolin:
    conda: 
        "envs/illumina/environment.yml",
    
    input:
        expand("{out_dir}/consensus/{sample}.primertrimmed.consensus.fa", sample=SAMPLES, out_dir=[OUT_DIR])
    
    output:
        fasta=OUT_DIR +"/annotation/all_consensus_seqs.fa",
        csv=OUT_DIR +"/annotation/pangolin_lineage_report.csv"

    shell:
        """
        cat {input} > {output.fasta}
        pangolin {output.fasta} --outfile {output.csv}
        """

# process anno_CorGat{
#     publishDir "${config.outdir}/${task.process.replaceAll(":","_")}", mode: 'copy'
#     conda config.conda_path
#     label 'error_ignore'
#     input:
#     tuple val(sampleName), path(consensus_seq) 
    
#     output:
#     path "${sampleName}_align.csv"
#     path "${sampleName}_anno.csv"

     
#     script:
#     """
#     awk -v path=${config.corgat_path} '{full_path=path\$2; print \$1,full_path}' ${config.corgat_conf} > test.conf
#     align.pl --multi  $consensus_seq --refile $config.corgat_fna  --out ${sampleName}_align.csv
#     annotate.pl --in ${sampleName}_align.csv --conf test.conf --out ${sampleName}_anno.csv
#     """
# }

# rule vcf:
#     input:
#         "{sample}.bam", "{sample}.bam.bai", GENOME_FAI_INDEX
#     output:
#         "{sample}.vcf"
#     params:
#         genome = GENOME
#     shell:
#         "freebayes -f {GENOME} -p 1 -C10 {input[0]} > {output} "


# rule bgzip:
#     input:
#         "{sample}.vcf"
#     output:
#         "{sample}.vcf.gz"
#     shell:
#         "bgzip {input} ;  tabix -p vcf {output}"


# rule merge_vcf:
#     input: 
#         [f'{sample}.vcf.gz' for sample in SAMPLES]
#     output:
#         "final.vcf.gz"
#     shell:
#         "bcftools merge {input} -Oz -o {output}"

# rule merge_annotation:
#     input:
#         "final.vcf.gz"
#     output:
#         "final.ann.vcf"
#     log:
#         "final.snpeff.log"
#     shell:
#         "snpEff -Xmx10G -v {GENOME_NAME} {input}> {output} 2> {log}"

# rule single_annotation:
#     input:
#         "{sample}.vcf.gz"
#     output:
#         "{sample}.ann.vcf"
#     log:
#         "{sample}.snpeff.log"
#     shell:
#         "snpEff -Xmx10G -v {GENOME_NAME} {input}> {output} 2> {log}"


# rule ann_to_csv:
#     input:
#         "{sample}.ann.vcf"
#     output:
#         "{sample}.results.csv"
#     params:
#         qual = config["VCF_QUAL_FILTER"]
#     shell:
#         """
#         SnpSift filter 'QUAL > {params.qual}' {input} |
#         ./scripts/vcfEffOnePerLine.pl|
#         SnpSift extractFields - 'ANN[*].GENE' 'ANN[*].FEATUREID' 'POS' 'REF' 'ALT' 'ANN[*].HGVS_C' 'ANN[*].HGVS_P' 'ANN[*].IMPACT' 'ANN[*].EFFECT' > {output}
#         """



# rule consensus:
#     input:
#         "{sample}.vcf.gz"
#     output:
#         report("{sample}.fa",caption="report/sample.rst",category="sample")
#     params:
#         genome = GENOME
#     log:
#         "{sample}.consensus.log"
#     shell:
#         "bcftools consensus {input} -f {params.genome} --sample {wildcards.sample} > {output} 2> {log}"


# rule pangolin:
#     input:
#         "{sample}.fa"
#     output:
#         "{sample}.lineage_report.csv"
#     shell:
#         "pangolin {input} --outfile {output}"



