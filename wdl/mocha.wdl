version development

## Copyright (c) 2020-2021 Giulio Genovese
##
## Version 2021-01-20
##
## Contact Giulio Genovese <giulio.genovese@gmail.com>
##
## This WDL workflow runs MoChA on a cohort of samples genotyped with either Illumina or Affymetrix DNA microarrays
##
## Cromwell version support
## - Successfully tested on v55
##
## Distributed under terms of the MIT License

struct Reference {
  String name
  File fasta
  Int n_chrs
  String mhc_reg
  String kir_reg
  File dup_file
  File genetic_map_file
  File cnp_file
  File cyto_file
  String panel_pfx
  String panel_sfx
  String panel_idx
  Int n_panel_smpls
}

workflow mocha {
  input {
    String sample_set_id
    String mode # idat gtc cel chp txt vcf pvcf
    String target = "pngs" # vcf pvcf calls pngs
    Boolean realign = false
    Boolean gtc_output = false # only for idat mode
    Boolean chp_output = false # only for cel mode
    Int idat_batch_size = 48
    Int gtc_batch_size = 1024
    Int chp_batch_size = 1024
    Int phase_threads = 4
    Float max_win_size_cm = 300.0
    Float overlap_size_cm = 5.0
    Float sample_call_rate_thr = 0.97
    Float variant_call_rate_thr = 0.97
    Float baf_auto_thr = 0.03
    String ext_string = "bdev"

    String ref_name = "GRCh38"
    String ref_path = ""
    String? ref_fasta
    Int? n_chrs
    String? mhc_reg
    String? kir_reg
    String? dup_file
    String? genetic_map_file
    String? cnp_file
    String? cyto_file
    String? panel_pfx
    String? panel_sfx
    String? panel_idx
    Int? n_panel_smpls

    String manifest_path = ""
    String data_path = ""
    File sample_tsv_file # sample_id batch_id green_idat red_idat gtc cel chp computed_gender call_rate
    File batch_tsv_file # batch_id path bpm csv egt sam xml zip probeset_ids snp report calls confidences summary vcf vcf_index xcl_vcf xcl_vcf_index
    File? ped_file
    File? duplicate_samples_file
    File? extra_xcl_vcf_file
    String? phase_extra_args
    String? mocha_extra_args
    String? mocha_plot_extra_args
    String basic_bash_docker = "ubuntu:latest"
    String pandas_docker = "amancevice/pandas:slim"
    String iaap_cli_docker = "us.gcr.io/mccarroll-mocha/iaap_cli:1.11-20210120"
    String autoconvert_docker = "us.gcr.io/mccarroll-mocha/autoconvert:1.11-20210120"
    String apt_docker = "us.gcr.io/mccarroll-mocha/apt:1.11-20210120"
    String gtc2vcf_docker = "us.gcr.io/mccarroll-mocha/mocha:1.11-20210120"
    String bcftools_docker = "us.gcr.io/mccarroll-mocha/mocha:1.11-20210120"
    String shapeit4_docker = "us.gcr.io/mccarroll-mocha/shapeit4:1.11-20210120"
    String eagle_docker = "us.gcr.io/mccarroll-mocha/eagle:1.11-20210120"
    String mocha_docker = "us.gcr.io/mccarroll-mocha/mocha:1.11-20210120"
    String mocha_plot_docker = "us.gcr.io/mccarroll-mocha/mocha_plot:1.11-20210120"
    Boolean autoconvert = false
    Boolean? table_output
    Boolean? do_not_check_bpm
    Boolean? do_not_use_reference
    Boolean eagle = false
    String delim = "~"
    Array[String]? chip_type
    String tags = "GT,BAF,LRR"
    Int? gc_window_size
  }

  Boolean mode_is_vcf = mode == "vcf" || mode == "pvcf"

  String ref_path_with_sep = ref_path + (if ref_path == "" || sub(ref_path, "/$", "") != ref_path then "" else "/")
  Reference ref = object {
    name: ref_name,
    fasta: ref_path_with_sep + select_first([ref_fasta, if ref_name == "GRCh38" then "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna" else if ref_name == "GRCh37" then "human_g1k_v37.fasta" else None]),
    n_chrs: select_first([n_chrs, 23]),
    mhc_reg: select_first([mhc_reg, if ref_name == "GRCh38" then "chr6:27518932-33480487" else if ref_name == "GRCh37" then "6:27486711-33448264" else None]),
    kir_reg: select_first([kir_reg, if ref_name == "GRCh38" then "chr19:54071493-54992731" else if ref_name == "GRCh37" then "19:54574747-55504099" else None]),
    dup_file: ref_path_with_sep + select_first([dup_file, if ref_name == "GRCh38" then "dup.grch38.bed.gz" else if ref_name == "GRCh37" then "dup.grch37.bed.gz" else None]),
    genetic_map_file: ref_path_with_sep + select_first([genetic_map_file, if ref_name == "GRCh38" then "genetic_map_hg38_withX.txt.gz" else if ref_name == "GRCh37" then "genetic_map_hg19_withX.txt.gz" else None]),
    cnp_file: ref_path_with_sep + select_first([cnp_file, if ref_name == "GRCh38" then "cnp.grch38.bed" else if ref_name == "GRCh37" then "cnp.grch37.bed" else None]),
    cyto_file: ref_path_with_sep + select_first([cyto_file, if ref_name == "GRCh38" then "cytoBand.hg38.txt.gz" else if ref_name == "GRCh37" then "cytoBand.hg19.txt.gz" else None]),
    panel_pfx: ref_path_with_sep + select_first([panel_pfx, if ref_name == "GRCh38" then "ALL." else if ref_name == "GRCh37" then "ALL.chr" else None]),
    panel_sfx: select_first([panel_sfx, if ref_name == "GRCh38" then "_GRCh38.genotypes.20170504.bcf" else if ref_name == "GRCh37" then ".phase3_integrated.20130502.genotypes.bcf" else None]),
    panel_idx: select_first([panel_idx, ".csi"]),
    n_panel_smpls: select_first([n_panel_smpls, 2504])
  }

  # read table with batches information (scatter could be avoided if there was a tail() function)
  call tsv_sorted as batch_sorted_tsv { input: tsv_file = batch_tsv_file, column = "batch_id", docker = basic_bash_docker }
  Array[Array[String]] batch_tsv = read_tsv(batch_sorted_tsv.file)
  Int n_batches = length(batch_tsv)-1
  scatter (idx in range(n_batches)) { Array[String] batch_tsv_rows = batch_tsv[(idx+1)] }
  Map[String, Array[String]] batch_tbl = as_map(zip(batch_tsv[0], transpose(batch_tsv_rows)))
  Array[String] batches = batch_tbl["batch_id"]

  String manifest_path_with_sep = manifest_path + (if manifest_path == "" || sub(manifest_path, "/$", "") != manifest_path then "" else "/")
  # compute data paths for each batch, if available (scatter could be avoided if there was a contains_key() function)
  scatter (key in keys(batch_tbl)) { Boolean? is_key_equal_path = if key == "path" then true else None }
  scatter (idx in range(n_batches)) {
    String data_paths = if length(select_all(is_key_equal_path))>0 then batch_tbl["path"][idx] else data_path
    String data_paths_with_sep = data_paths + (if data_paths == "" || sub(data_paths, "/$", "") != data_paths then "" else "/")
    String pfxs = sample_set_id + (if n_batches == 1 then "" else "." + batches[idx])
  }

  # aligns manifest file to human genome reference if requested
  if (realign && !mode_is_vcf) {
    # hack due to lack of unique function
    Array[String] csv_files = keys(collect_by_key(zip(batch_tbl["csv"], batches)))
    scatter (csv_file in csv_files) {
      call csv2bam {
        input:
          plugin = if mode == "idat" || mode == "gtc" then "gtc2vcf" else "affy2vcf",
          csv_file = manifest_path_with_sep + csv_file,
          ref_fasta = ref.fasta,
          ref_fasta_idxs = prefix(ref.fasta + ".", ["amb", "ann", "bwt", "pac", "sa"]),
          docker = gtc2vcf_docker,
      }
    }
    Map[String, File] csv2sam = as_map(zip(csv_files, csv2bam.bam_file))
  }
  # compute sam file for each batch, if available (scatter could be avoided if there was a contains_key() function)
  scatter (key in keys(batch_tbl)) { Boolean? is_key_equal_sam = if key == "sam" then true else None }
  scatter (idx in range(n_batches)) {
    File? sams = if realign && !mode_is_vcf then select_first([csv2sam])[(batch_tbl["csv"][idx])]
      else if length(select_all(is_key_equal_sam))>0 then manifest_path_with_sep + batch_tbl["sam"][idx] else None
  }

  if (!mode_is_vcf) {
    # resort table with sample information and extract sample_id column
    call tsv_sorted as sample_sorted_tsv { input: tsv_file = sample_tsv_file, column = "batch_id", docker = basic_bash_docker }
    call tsv_column as sample_id_lines { input: tsv_file = sample_sorted_tsv.file, column = "sample_id", docker = basic_bash_docker }
    call tsv_column as batch_id_lines { input: tsv_file = sample_sorted_tsv.file, column = "batch_id", docker = basic_bash_docker }

    # process Illumina data
    if (mode == "idat") {
      call tsv_column as green_idat_lines { input: tsv_file = sample_sorted_tsv.file, column = "green_idat", docker = basic_bash_docker }
      call tsv_column as red_idat_lines { input: tsv_file = sample_sorted_tsv.file, column = "red_idat", docker = basic_bash_docker }
      # group samples by IDAT batches
      call batch_scatter as idat_scatter { input: batch_id_file = batch_id_lines.file, sub_batch_size = idat_batch_size, delim = delim, docker = basic_bash_docker }
      Map[String, Array[String]] idat_batch2green_idat_files = collect_by_key(zip(read_lines(idat_scatter.sub_batch_id), read_lines(green_idat_lines.file)))
      Map[String, Array[String]] idat_batch2red_idat_files = collect_by_key(zip(read_lines(idat_scatter.sub_batch_id), read_lines(red_idat_lines.file)))
      Map[String, Int] idat_batch2idx = as_map(zip(idat_scatter.sub_batches, idat_scatter.idxs))
      scatter (idat_batch in idat_scatter.sub_batches) {
        Int idat_idx = idat_batch2idx[idat_batch]
        call idat2gtc {
          input:
            bpm_file = manifest_path_with_sep + batch_tbl["bpm"][idat_idx],
            egt_file = manifest_path_with_sep + batch_tbl["egt"][idat_idx],
            green_idat_files = prefix(data_paths_with_sep[idat_idx], idat_batch2green_idat_files[idat_batch]),
            red_idat_files = prefix(data_paths_with_sep[idat_idx], idat_batch2red_idat_files[idat_batch]),
            autoconvert = autoconvert,
            filebase = sample_set_id + "." + idat_batch,
            docker = if autoconvert then autoconvert_docker else iaap_cli_docker,
        }
      }
      call tsv_concat as green_idat_tsv { input: tsv_files = idat2gtc.green_idat_tsv, filebase = sample_set_id + ".green_idat", docker = basic_bash_docker }
      call tsv_concat as red_idat_tsv { input: tsv_files = idat2gtc.red_idat_tsv, filebase = sample_set_id + ".red_idat", docker = basic_bash_docker }
    }

    if (mode == "gtc") {
      call tsv_column as gtc_lines { input: tsv_file = sample_sorted_tsv.file, column = "gtc", docker = basic_bash_docker }
    }

    if (mode == "idat" || mode == "gtc") {
      # group samples by GTC batches
      call batch_scatter as gtc_scatter { input: batch_id_file = batch_id_lines.file, sub_batch_size = gtc_batch_size, delim = delim, docker = basic_bash_docker }
      Array[String]+ input_gtc_files = if mode == "idat" then flatten(select_first([idat2gtc.gtc_files])) else read_lines(select_first([gtc_lines.file]))
      Map[String, Array[String]] gtc_batch2gtc_files = collect_by_key(zip(read_lines(gtc_scatter.sub_batch_id), input_gtc_files))
      call get_barcodes as gtc_barcodes { input: lst_files = select_first([green_idat_lines.file, gtc_lines.file]), docker = basic_bash_docker }
      Map[String, Array[String]] gtc_batch2barcode = collect_by_key(zip(read_lines(gtc_scatter.sub_batch_id), read_lines(gtc_barcodes.file)))
      Map[String, Array[String]] gtc_batch2sample_id = collect_by_key(zip(read_lines(gtc_scatter.sub_batch_id), read_lines(sample_id_lines.file)))
      Map[String, Int] gtc_batch2idx = as_map(zip(gtc_scatter.sub_batches, gtc_scatter.idxs))
      scatter (gtc_batch in gtc_scatter.sub_batches) {
        Int gtc_idx = gtc_batch2idx[gtc_batch]
        call gtc2vcf {
          input:
            tags = tags,
            bpm_file = manifest_path_with_sep + batch_tbl["bpm"][gtc_idx],
            csv_file = manifest_path_with_sep + batch_tbl["csv"][gtc_idx],
            egt_file = manifest_path_with_sep + batch_tbl["egt"][gtc_idx],
            ref_fasta = ref.fasta,
            ref_fasta_fai = ref.fasta + ".fai",
            gc_window_size = gc_window_size,
            gtc_files = if mode == "idat" then gtc_batch2gtc_files[gtc_batch] else prefix(data_paths_with_sep[gtc_idx], gtc_batch2gtc_files[gtc_batch]),
            do_not_check_bpm = do_not_check_bpm,
            sam_file = sams[gtc_idx],
            reheader_map = as_map(zip(gtc_batch2barcode[gtc_batch], gtc_batch2sample_id[gtc_batch])),
            filebase = sample_set_id + "." + gtc_batch,
            docker = gtc2vcf_docker,
        }
      }
      call tsv_concat as gtc_tsv { input: tsv_files = gtc2vcf.gtc_tsv, filebase = sample_set_id + ".gtc", docker = basic_bash_docker }

      # this job can be long, so it is better to run as non-preemptible
      Map[Int, Array[String]] idx2gtc2vcf_files = collect_by_key(zip(gtc_scatter.idxs, gtc2vcf.vcf_file))
      Map[Int, Array[String]] idx2gtc2vcf_idxs = collect_by_key(zip(gtc_scatter.idxs, gtc2vcf.vcf_idx))
      scatter (idx in range(n_batches)) {
        if (length(idx2gtc2vcf_files[idx]) > 1) {
          call vcf_merge as gtc2vcf_merge {
            input:
              vcf_files = idx2gtc2vcf_files[idx],
              filebase = pfxs[idx],
              docker = bcftools_docker
          }
        }
        File gtc2vcf_files = select_first([gtc2vcf_merge.vcf_file, idx2gtc2vcf_files[idx][0]])
        File gtc2vcf_idxs = select_first([gtc2vcf_merge.vcf_idx, idx2gtc2vcf_idxs[idx][0]])
      }
    }

    if (mode == "cel" || mode == "chp" || mode == "txt") {
      scatter (key in keys(batch_tbl)) { Boolean? is_key_equal_probeset = if key == "probeset_ids" then true else None }
    }

    if (mode == "cel" || mode == "txt") {
      call tsv_column as cel_lines { input: tsv_file = sample_sorted_tsv.file, column = "cel", docker = basic_bash_docker }
    }

    # process Affymetrix data
    if (mode == "cel") {
      Map[String, Array[String]] batch2cel_files = collect_by_key(zip(read_lines(batch_id_lines.file), read_lines(select_first([cel_lines.file]))))
      scatter (idx in range(n_batches)) {
        call cel2affy as cel2chp {
          input:
            xml_file = manifest_path_with_sep + batch_tbl["xml"][idx],
            zip_file = manifest_path_with_sep + batch_tbl["zip"][idx],
            cel_files = prefix(data_paths_with_sep[idx], batch2cel_files[(batches[idx])]),
            probeset_file = if length(select_all(select_first([is_key_equal_probeset])))>0 && batch_tbl["probeset_ids"][idx] != ""
              then manifest_path_with_sep + batch_tbl["probeset_ids"][idx] else None,
            chip_type = chip_type,
            table_output = table_output,
            filebase = pfxs[idx],
            docker = apt_docker
        }
      }
      call tsv_concat as cel_tsv { input: tsv_files = cel2chp.cel_tsv, filebase = sample_set_id + ".cel", docker = basic_bash_docker }
    }

    if (mode == "chp") {
      call tsv_column as chp_lines { input: tsv_file = sample_sorted_tsv.file, column = "chp", docker = basic_bash_docker }
    }

    if (mode == "cel" || mode == "chp") {
      # group samples by CHP batches
      call batch_scatter as chp_scatter { input: batch_id_file = batch_id_lines.file, sub_batch_size = chp_batch_size, delim = delim, docker = basic_bash_docker }
      Array[String]+ input_chp_files = if mode == "cel" then flatten(select_first([cel2chp.chp_files])) else read_lines(select_first([chp_lines.file]))
      Map[String, Array[String]] chp_batch2chp_files = collect_by_key(zip(read_lines(chp_scatter.sub_batch_id), input_chp_files))
      call get_barcodes as chp_barcodes { input: lst_files = select_first([cel_lines.file, chp_lines.file]), docker = basic_bash_docker }
      Map[String, Array[String]] chp_batch2barcode = collect_by_key(zip(read_lines(chp_scatter.sub_batch_id), read_lines(chp_barcodes.file)))
      Map[String, Array[String]] chp_batch2sample_id = collect_by_key(zip(read_lines(chp_scatter.sub_batch_id), read_lines(sample_id_lines.file)))
      Map[String, Int] chp_batch2idx = as_map(zip(chp_scatter.sub_batches, chp_scatter.idxs))
      scatter (chp_batch in chp_scatter.sub_batches) {
        Int chp_idx = chp_batch2idx[chp_batch]
        call chp2vcf {
          input:
            tags = tags,
            csv_file = manifest_path_with_sep + batch_tbl["csv"][chp_idx],
            ref_fasta = ref.fasta,
            ref_fasta_fai = ref.fasta + ".fai",
            gc_window_size = gc_window_size,
            probeset_file = if length(select_all(select_first([is_key_equal_probeset])))>0 && batch_tbl["probeset_ids"][chp_idx] != ""
              then manifest_path_with_sep + batch_tbl["probeset_ids"][chp_idx] else None,
            snp_file = if mode == "cel" then select_first([cel2chp.snp_file])[chp_idx] else data_paths_with_sep[chp_idx] + batch_tbl["snp"][chp_idx],
            chp_files = if mode == "cel" then chp_batch2chp_files[chp_batch] else prefix(data_paths_with_sep[chp_idx], chp_batch2chp_files[chp_batch]),
            sam_file = sams[chp_idx],
            reheader_map = as_map(zip(chp_batch2barcode[chp_batch], chp_batch2sample_id[chp_batch])),
            filebase = sample_set_id + "." + chp_batch,
            docker = gtc2vcf_docker
        }
      }

      # this job can be long, so it is better to run as non-preemptible
      Map[Int, Array[String]] idx2chp2vcf_files = collect_by_key(zip(chp_scatter.idxs, chp2vcf.vcf_file))
      Map[Int, Array[String]] idx2chp2vcf_idxs = collect_by_key(zip(chp_scatter.idxs, chp2vcf.vcf_idx))
      scatter (idx in range(n_batches)) {
        if (length(idx2chp2vcf_files[idx]) > 1) {
          call vcf_merge as chp2vcf_merge {
            input:
              vcf_files = idx2chp2vcf_files[idx],
              filebase = pfxs[idx],
              docker = bcftools_docker
          }
        }
        File chp2vcf_files = select_first([chp2vcf_merge.vcf_file, idx2chp2vcf_files[idx][0]])
        File chp2vcf_idxs = select_first([chp2vcf_merge.vcf_idx, idx2chp2vcf_idxs[idx][0]])
      }
    }

    if (mode == "txt") {
      scatter (key in keys(batch_tbl)) { Boolean? is_key_equal_confidences = if key == "confidences" then true else None }
      call get_barcodes as txt_barcodes { input: lst_files = select_first([cel_lines.file]), docker = basic_bash_docker }
      Map[String, Array[String]] batch2barcode = collect_by_key(zip(read_lines(batch_id_lines.file), read_lines(txt_barcodes.file)))
      Map[String, Array[String]] batch2sample_id = collect_by_key(zip(read_lines(batch_id_lines.file), read_lines(sample_id_lines.file)))
      scatter (idx in range(n_batches)) {
        # this job can be long, so it is better to run as non-preemptible
        call txt2vcf {
          input:
            tags = tags,
            csv_file = manifest_path_with_sep + batch_tbl["csv"][idx],
            ref_fasta = ref.fasta,
            ref_fasta_fai = ref.fasta + ".fai",
            gc_window_size = gc_window_size,
            probeset_file = if length(select_all(select_first([is_key_equal_probeset])))>0 && batch_tbl["probeset_ids"][idx] != ""
              then manifest_path_with_sep + batch_tbl["probeset_ids"][idx] else None,
            calls_file = data_paths_with_sep[idx] + batch_tbl["calls"][idx],
            confidences_file = if length(select_all(is_key_equal_confidences))>0 then data_paths_with_sep[idx] + batch_tbl["confidences"][idx] else None,
            summary_file = data_paths_with_sep[idx] + batch_tbl["summary"][idx],
            report_file = data_paths_with_sep[idx] + batch_tbl["report"][idx],
            snp_file = data_paths_with_sep[idx] + batch_tbl["snp"][idx],
            sam_file = sams[idx],
            reheader_map = as_map(zip(batch2barcode[(batches[idx])], batch2sample_id[(batches[idx])])),
            filebase = pfxs[idx],
            docker = gtc2vcf_docker
        }
      }
    }

    if (mode == "cel" || mode == "chp" || mode == "txt") {
      call tsv_concat as affy_tsv { input: tsv_files = select_first([chp2vcf.affy_tsv, txt2vcf.affy_tsv]), filebase = sample_set_id + ".affy", docker = basic_bash_docker }
    }

    Array[File] unphased_vcf_files = select_first([gtc2vcf_files, chp2vcf_files, txt2vcf.vcf_file])
    Array[File] unphased_vcf_idxs = select_first([gtc2vcf_idxs, chp2vcf_idxs, txt2vcf.vcf_idx])
    call lst_flatten as flatten_sample_id_lines { input: lst_files = select_first([gtc2vcf.sample_id_lines, chp2vcf.sample_id_lines, txt2vcf.sample_id_lines]), filebase = "sample_id", docker = basic_bash_docker }
  }

  if (mode_is_vcf) {
    call tsv_column as vcf_sample_id_lines { input: tsv_file = sample_tsv_file, column = "sample_id", docker = basic_bash_docker }
  }

  call tsv_column as computed_gender_lines { input: tsv_file = select_first([gtc_tsv.file, affy_tsv.file, sample_tsv_file]), column = "computed_gender", docker = basic_bash_docker }
  call tsv_column as call_rate_lines { input: tsv_file = select_first([gtc_tsv.file, affy_tsv.file, sample_tsv_file]), column = "call_rate", docker = basic_bash_docker }
  if (mode != "pvcf" && target != "vcf") {
    call ref_scatter {
      input:
        n_chrs = ref.n_chrs,
        ref_fasta_fai = ref.fasta + ".fai",
        genetic_map_file = ref.genetic_map_file,
        max_win_size_cm = max_win_size_cm,
        overlap_size_cm = overlap_size_cm,
        docker = pandas_docker
    }
    scatter (idx in range(n_batches)) {
      call vcf_scatter {
        input:
          vcf_file = if mode_is_vcf then data_paths_with_sep[idx] + batch_tbl["vcf"][idx] else select_first([unphased_vcf_files])[idx],
          intervals_bed = ref_scatter.intervals_bed,
          docker = bcftools_docker
      }
    }
    if (defined(extra_xcl_vcf_file)) {
      call vcf_scatter as xcl_vcf_scatter {
        input:
          vcf_file = select_first([extra_xcl_vcf_file]),
          intervals_bed = ref_scatter.intervals_bed,
          docker = bcftools_docker
      }
    }

    call lst_concat as sample_id_split_tsv { input: lst_files = vcf_scatter.sample_id_lines, filebase = "split_sample_id", docker = basic_bash_docker }
    Int n_smpls = length(flatten(read_tsv(sample_id_split_tsv.file)))
    Boolean use_reference = !select_first([do_not_use_reference, n_smpls > 2 * ref.n_panel_smpls])
    Array[Array[File]] interval_slices = transpose(vcf_scatter.vcf_files)
    Array[String] chrs = transpose(read_tsv(ref_scatter.intervals_bed))[0]
    scatter (idx in range(length(chrs))) {
      call vcf_merge {
        input:
          vcf_files = interval_slices[idx],
          filebase = sample_set_id + "." + idx,
          docker = bcftools_docker
      }
      call vcf_qc {
        input:
          vcf_file = vcf_merge.vcf_file,
          vcf_idx = vcf_merge.vcf_idx,
          dup_file = ref.dup_file,
          sample_id_file = select_first([flatten_sample_id_lines.file, vcf_sample_id_lines.file]),
          computed_gender_file = computed_gender_lines.file,
          call_rate_file = call_rate_lines.file,
          sample_call_rate_thr = sample_call_rate_thr,
          variant_call_rate_thr = variant_call_rate_thr,
          duplicate_samples_file = duplicate_samples_file,
          extra_xcl_vcf_file = if defined(extra_xcl_vcf_file) then select_first([xcl_vcf_scatter.vcf_files])[idx] else None,
          docker = bcftools_docker
      }
      call vcf_phase {
        input:
          n_smpls = n_smpls,
          n_vars = vcf_qc.n_vars,
          unphased_vcf_file = vcf_merge.vcf_file,
          unphased_vcf_idx = vcf_merge.vcf_idx,
          genetic_map_file = ref.genetic_map_file,
          n_panel_smpls = if use_reference then ref.n_panel_smpls else None,
          ref_vcf_file = if use_reference then ref.panel_pfx + chrs[idx] + ref.panel_sfx else None,
          ref_vcf_idx = if use_reference then ref.panel_pfx + chrs[idx] + ref.panel_sfx + ref.panel_idx else None,
          xcl_vcf_file = vcf_qc.xcl_vcf_file,
          xcl_vcf_idx = vcf_qc.xcl_vcf_idx,
          chr = chrs[idx],
          eagle = eagle,
          phase_extra_args = phase_extra_args,
          docker = if eagle then eagle_docker else shapeit4_docker,
          cpu = phase_threads
      }
      call vcf_split {
        input:
          vcf_file = vcf_phase.pvcf_file,
          batches = batches,
          sample_id_file = sample_id_split_tsv.file,
          ped_file = ped_file,
          rule = if defined(ped_file) then ref.name else None,
          docker = bcftools_docker
      }
    }

    call vcf_concat as xcl_vcf_concat {
      input:
        vcf_files = vcf_qc.xcl_vcf_file,
        filebase = sample_set_id + ".xcl",
        docker = bcftools_docker
    }

    Array[Array[File]] batch_slices = transpose(vcf_split.vcf_files)
    scatter (idx in range(n_batches)) {
      call vcf_concat {
        input:
          vcf_files = batch_slices[idx],
          ref_fasta_fai = ref.fasta + ".fai",
          filebase = pfxs[idx] + ".GT",
          docker = bcftools_docker
      }
      call vcf_import {
        input:
          pvcf_file = vcf_concat.vcf_file,
          pvcf_idx = vcf_concat.vcf_idx,
          unphased_vcf_file = if mode_is_vcf then data_paths_with_sep[idx] + batch_tbl["vcf"][idx] else select_first([unphased_vcf_files])[idx],
          unphased_vcf_idx = if mode_is_vcf then data_paths_with_sep[idx] + batch_tbl["vcf_index"][idx] else select_first([unphased_vcf_idxs])[idx],
          docker = bcftools_docker
      }
    }
  }

  if (target == "calls" || target == "pngs") {
    scatter (idx in range(n_batches)) {
      call vcf_mocha {
        input:
          rule = ref.name,
          pvcf_file = if mode == "pvcf" then data_paths_with_sep[idx] + batch_tbl["vcf"][idx] else select_first([vcf_import.vcf_file])[idx],
          pvcf_idx = if mode == "pvcf" then data_paths_with_sep[idx] + batch_tbl["vcf_index"][idx] else select_first([vcf_import.vcf_idx])[idx],
          sample_id_file = select_first([flatten_sample_id_lines.file, vcf_sample_id_lines.file]),
          computed_gender_file = computed_gender_lines.file,
          call_rate_file = call_rate_lines.file,
          xcl_vcf_file = if mode == "pvcf" then data_paths_with_sep[idx] + batch_tbl["xcl_vcf"][idx] else xcl_vcf_concat.vcf_file,
          xcl_vcf_idx = if mode == "pvcf" then data_paths_with_sep[idx] + batch_tbl["xcl_vcf_index"][idx] else xcl_vcf_concat.vcf_idx,
          cnp_file = ref.cnp_file,
          mhc_reg = if ref.mhc_reg != "" then ref.mhc_reg else None,
          kir_reg = if ref.kir_reg != "" then ref.kir_reg else None,
          mocha_extra_args = mocha_extra_args,
          ext_string = ext_string,
          docker = mocha_docker
      }
      if (target == "pngs") {
        call mocha_plot {
          input:
            vcf_file = vcf_mocha.mocha_vcf_file,
            vcf_idx = vcf_mocha.mocha_vcf_idx,
            stats_tsv = vcf_mocha.stats_tsv,
            calls_tsv = vcf_mocha.calls_tsv,
            cyto_file = ref.cyto_file,
            call_rate_thr = sample_call_rate_thr,
            baf_auto_thr = baf_auto_thr,
            mocha_plot_extra_args = mocha_plot_extra_args,
            docker = mocha_plot_docker
        }
      }
    }
    call tsv_concat as mocha_stats_tsv { input: tsv_files = vcf_mocha.stats_tsv, filebase = sample_set_id + ".stats", docker = basic_bash_docker }
    call tsv_concat as mocha_calls_tsv { input: tsv_files = vcf_mocha.calls_tsv, filebase = sample_set_id + ".calls", docker = basic_bash_docker }
    call mocha_summary {
      input:
        calls_tsv = mocha_calls_tsv.file,
        stats_tsv = mocha_stats_tsv.file,
        ucsc_beds = vcf_mocha.ucsc_bed,
        cyto_file = ref.cyto_file,
        filebase = sample_set_id,
        call_rate_thr = sample_call_rate_thr,
        baf_auto_thr = baf_auto_thr,
        docker = mocha_plot_docker
    }
  }

  # generate a table summarizing the main output files and serialize the table to disk
  # vcf_files and vcf_idxs are defined in the output section
  scatter (idx in range(n_batches)) {
    String basename_vcf_files = basename(vcf_files[idx])
    String basename_vcf_idxs = basename(vcf_idxs[idx])
    String basename_xcl_vcf_files = basename(if mode == "pvcf" then batch_tbl["xcl_vcf"][idx] else select_first([xcl_vcf_concat.vcf_file, ""]))
    String basename_xcl_vcf_idxs = basename(if mode == "pvcf" then batch_tbl["xcl_vcf_index"][idx] else select_first([xcl_vcf_concat.vcf_idx, ""]))
  }
  Map[String, Array[String]] output_map = {
    "batch_id": batch_tbl["batch_id"],
    "vcf": basename_vcf_files,
    "vcf_index": basename_vcf_idxs,
    "xcl_vcf": basename_xcl_vcf_files,
    "xcl_vcf_index": basename_xcl_vcf_idxs,
  }
  scatter (key in ["batch_id", "vcf", "vcf_index", "xcl_vcf", "xcl_vcf_index"]) { Array[String] output_tsv_cols = output_map[key] }
  call write_tsv {
    input:
      tsv = flatten([[["batch_id", "vcf", "vcf_index", "xcl_vcf", "xcl_vcf_index"]], transpose(output_tsv_cols)]),
      filebase = sample_set_id + ".output",
      docker = basic_bash_docker
  }

  output {
    File? ref_intervals_bed = ref_scatter.intervals_bed
    File? green_idat_tsv_file = green_idat_tsv.file
    File? red_idat_tsv_file = red_idat_tsv.file
    File? gtc_tsv_file = gtc_tsv.file
    File? cel_tsv_file = cel_tsv.file
    File? affy_tsv_file = affy_tsv.file
    File sample_id_file = select_first([flatten_sample_id_lines.file, vcf_sample_id_lines.file])
    File computed_gender_file = computed_gender_lines.file
    File call_rate_file = call_rate_lines.file
    File? mocha_stats_file = mocha_stats_tsv.file
    File? mocha_calls_file = mocha_calls_tsv.file
    File? mocha_ucsc_bed = mocha_summary.ucsc_bed
    File? mocha_summary_pdf = mocha_summary.summary_pdf
    File? mocha_pileup_pdf = mocha_summary.pileup_pdf
    Array[File]? png_files = if target == "pngs" then flatten(select_all(select_first([mocha_plot.png_files]))) else None
    Array[File]? bam_files = csv2bam.bam_file
    Array[File]? mendel_files = if mode != "pvcf" && target != "vcf" && defined(ped_file) then select_all(select_first([vcf_split.mendel_tsv])) else None
    Array[File]? gtc_files = if mode == "idat" && gtc_output then flatten(select_first([idat2gtc.gtc_files])) else None
    Array[File]? chp_files = if mode == "cel" && chp_output then flatten(select_first([cel2chp.chp_files])) else None
    Array[File]? snp_files = if mode == "cel" && chp_output then select_first([cel2chp.snp_file]) else None
    Array[File] vcf_files = select_first([vcf_mocha.mocha_vcf_file, vcf_import.vcf_file, unphased_vcf_files])
    Array[File] vcf_idxs = select_first([vcf_mocha.mocha_vcf_idx, vcf_import.vcf_idx, unphased_vcf_idxs])
    File? xcl_vcf_file = xcl_vcf_concat.vcf_file
    File? xcl_vcf_idx = xcl_vcf_concat.vcf_idx
    File output_tsv_file = write_tsv.file
  }

  meta {
    author: "Giulio Genovese (with help from Chris Whelan)"
    email: "giulio.genovese@gmail.com"
    description: "See the [MoChA](https://github.com/freeseek/mocha) website for more information."
  }
}

task tsv_sorted {
  input {
    File tsv_file
    String column

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  String filebase = basename(tsv_file, ".tsv")

  command <<<
    set -euo pipefail
    mv "~{tsv_file}" .
    col=$(head -n1 "~{basename(tsv_file)}" | tr '\t' '\n' | awk -F"\t" '$0=="~{column}" {print NR}')
    if [ "$col" == "" ]; then
      echo "Column \"~{column}\" does not exist" 1>&2
      exit 1
    fi
    cat "~{basename(tsv_file)}" | (read -r; printf "%s\n" "$REPLY"; sort -k $col,$col -s -t $'\t') > "~{filebase}.sorted.tsv"
    rm "~{basename(tsv_file)}"
  >>>

  output {
    File file = filebase + ".sorted.tsv"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task tsv_column {
  input {
    File tsv_file
    String column

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    mv "~{tsv_file}" .
    col=$(head -n1 "~{basename(tsv_file)}" | tr '\t' '\n' | awk -F"\t" '$0=="~{column}" {print NR}')
    if [ "$col" == "" ]; then
      echo "Column \"~{column}\" does not exist" 1>&2
      exit 1
    fi
    ~{if column != "call_rate" then "tail -n+2 \"" + basename(tsv_file) + "\" | cut -f$col > \"" + column + ".lines\""
    else "max_call_rate=$(tail -n+2 \"" + basename(tsv_file) + "\" | cut -f$col | sort -g | tail -n1)\n" +
    "tail -n+2 \"" + basename(tsv_file) + "\" | cut -f$col | if [[ $max_call_rate > 1.0 ]]; then awk '{print $0/100}'; else cat; fi > \"" + column + ".lines\"\n"}
    rm "~{basename(tsv_file)}"
  >>>

  output {
    File file = column + ".lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}


task tsv_concat {
  input {
    Array[File]+ tsv_files
    String filebase

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    tsv_files=~{write_lines(tsv_files)}
    ~{if length(tsv_files) > 1 then
    "cat $tsv_files | tr '\\n' '\\0' | xargs -0 mv -t .\n" +
    "sed -i 's/^.*\\///' $tsv_files\n" +
    "(head -n1 \"" + basename(tsv_files[0]) + "\";\n" +
    "cat $tsv_files | tr '\\n' '\\0' | xargs -0 tail -qn+2) > \"" + filebase + ".tsv\"\n" +
    "cat $tsv_files | tr '\\n' '\\0' | xargs -0 rm"
    else "mv \"" + tsv_files[0] + "\" \"" + filebase + ".tsv\""}
  >>>

  output {
    File file = filebase + ".tsv"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task lst_flatten {
  input {
    Array[File] lst_files
    String filebase

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    lst_files=~{write_lines(lst_files)}
    cat $lst_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $lst_files
    cat $lst_files | tr '\n' '\0' | xargs -0 awk 1 > "~{filebase}.lines"
    cat $lst_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File file = filebase + ".lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task lst_concat {
  input {
    Array[File] lst_files
    String filebase

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    lst_files=~{write_lines(lst_files)}
    cat $lst_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $lst_files
    cat $lst_files | tr '\n' '\0' | xargs -0 -n 1 awk '{printf $0"\t"} END {printf "\n"}' | sed 's/\t$//' > "~{filebase}.tsv"
    cat $lst_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File file = filebase + ".tsv"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# this task generates sub batches from batches and then returns them in the same order as batches
# batch_id_file should contain batch names without the delim string, or else behavior is undefined
task batch_scatter {
  input {
    File batch_id_file
    Int sub_batch_size
    String delim

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    mv "~{batch_id_file}" .
    awk -F"\t" 'NR==FNR {x[$0]++} NR>FNR {n=x[$0]/int((x[$0]-1)/~{sub_batch_size}+1);
      if (x[$0]>n) print $0"~{delim}"int(y[$0]/n); else print $0; y[$0]++}' \
      "~{basename(batch_id_file)}" "~{basename(batch_id_file)}" > sub_batch_ids.lines
    uniq sub_batch_ids.lines
    uniq sub_batch_ids.lines | cut -d"~{delim}" -f1 | awk '!x[$0]++ {idx++} {print idx-1}' 1>&2
    rm "~{basename(batch_id_file)}"
  >>>

  output {
    File sub_batch_id = "sub_batch_ids.lines"
    Array[String] sub_batches = read_lines(stdout())
    Array[Int] idxs = read_lines(stderr())
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task get_barcodes {
  input {
    File lst_files

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    mv "~{lst_files}" .
    sed 's/^.*\///;s/.gz$//;s/_Grn.idat$//;s/.gtc$//;s/.CEL$//;s/.AxiomGT1.chp$//;s/.birdseed-v2.chp$//' "~{basename(lst_files)}" > barcodes.lines
    rm "~{basename(lst_files)}"
  >>>

  output {
    File file = "barcodes.lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task write_tsv {
  input {
    Array[Array[String]] tsv
    String filebase

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    mv ~{write_tsv(tsv)} "~{filebase}.tsv"
  >>>

  output {
    File file = filebase + ".tsv"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task csv2bam {
  input {
    String plugin = "gtc2vcf"
    File csv_file
    File ref_fasta
    Array[File]+ ref_fasta_idxs

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float csv_size = (if basename(csv_file) != basename(csv_file, ".gz") then 4.0 else 1.0) * size(csv_file, "GiB")
  Float ref_size = size(ref_fasta, "GiB")
  Float index_size = size(ref_fasta_idxs, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 2.0 * csv_size + ref_size + index_size)])
  # if gtc2vcf was memory efficient this requirement could be eased
  Float memory = select_first([memory_override, ceil(7.25 + 2.5 * csv_size)])

  command <<<
    set -euo pipefail
    echo "~{sep="\n" flatten([[csv_file, ref_fasta], ref_fasta_idxs])}" | \
      tr '\n' '\0' | xargs -0 mv -t .
    bcftools +~{plugin} \
      --csv "~{basename(csv_file)}" \
      --fasta-flank | \
      bwa mem~{if cpu > 1 then " -t " + cpu else ""} -M "~{basename(ref_fasta)}" - | \
      samtools view -bS -o "~{basename(basename(csv_file, ".gz"), ".csv")}.bam"
    echo "~{sep="\n" flatten([[csv_file, ref_fasta], ref_fasta_idxs])}" | \
      sed 's/^.*\///' | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File bam_file = basename(basename(csv_file, ".gz"), ".csv") + ".bam"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# https://support.terra.bio/hc/en-us/community/posts/360071476431-Terra-fails-to-delocalize-files-listed-through-read-lines-
task idat2gtc {
  input {
    File bpm_file
    File egt_file
    Array[File]+ green_idat_files
    Array[File]+ red_idat_files
    Boolean is_gender_autocall = true # from dsde-pipelines/tasks/IlluminaGenotypingArrayTasks.wdl
    Boolean autoconvert = false
    String filebase

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0

    Float mult = 6.0 # to estimate the amount of memory required given the size of the manifest files
  }

  Float bpm_size = (if basename(bpm_file) != basename(bpm_file, ".gz") then 4.0 else 1.0) * size(bpm_file, "GiB")
  Float egt_size = (if basename(egt_file) != basename(egt_file, ".gz") then 2.0 else 1.0) * size(egt_file, "GiB")
  Float green_idat_size = length(green_idat_files) * size(green_idat_files[0], "GiB")
  Float red_idat_size = length(red_idat_files) * size(red_idat_files[0], "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + bpm_size + egt_size + 4.0 * (green_idat_size + red_idat_size))])
  Float memory = select_first([memory_override, 3.5 + mult * (bpm_size + egt_size)]) # will request more than 8GB for Omni5

  command <<<
    set -euo pipefail
    green_idat_files=~{write_lines(green_idat_files)}
    red_idat_files=~{write_lines(red_idat_files)}
    mv "~{bpm_file}" .
    mv "~{egt_file}" .
    cat $green_idat_files $red_idat_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $green_idat_files $red_idat_files
    ~{if basename(bpm_file) != basename(bpm_file, ".gz") then "gunzip --force \"" + basename(bpm_file) + "\"" else ""}
    ~{if basename(egt_file) != basename(egt_file, ".gz") then "gunzip --force \"" + basename(egt_file) + "\"" else ""}
    (grep -h "\.gz" $green_idat_files $red_idat_files || if [[ $? -eq 1 ]]; then true; else exit $?; fi) | \
      tr '\n' '\0' | xargs -0 gunzip --force
    sed -i 's/.gz$//' $green_idat_files $red_idat_files
    bcftools +gtc2vcf --idat --gtcs $green_idat_files --output "~{filebase}.green_idat.tsv"
    bcftools +gtc2vcf --idat --gtcs $red_idat_files --output "~{filebase}.red_idat.tsv"
    ~{if autoconvert then
      "sed -i 's/^   <NumberOfThreads>4<\\/NumberOfThreads>\\r$/   <NumberOfThreads>" + cpu + "<\\/NumberOfThreads>\\r/' \\\n" +
      "  \"/opt/AutoConvert 2.0/AutoCallConfig.xml\"\n" +
      "mkdir gtcs\n" +
      "cat $green_idat_files | tr '\\n' '\\0' | \\\n" +
      "  xargs -0 -i mono \\\n" +
      "  \"/opt/AutoConvert 2.0/AutoConvert.exe\" \\\n" +
      "  \"{}\" \\\n" +
      "  gtcs \\\n" +
      "  \"" + basename(bpm_file, ".gz") + "\" \\\n" +
      "  \"" + basename(egt_file, ".gz") + "\" \\\n"
    else
      "iaap-cli \\\n" +
      "  gencall \\\n" +
      "  \"" + basename(bpm_file, ".gz") + "\" \\\n" +
      "  \"" + basename(egt_file, ".gz") + "\" \\\n" +
      "  gtcs \\\n" +
      "  --idat-folder . \\\n" +
      "  --output-gtc \\\n" +
      (if is_gender_autocall then "  --gender-estimate-call-rate-threshold -0.1 \\\n" else "") +
      (if cpu > 1 then "  --num-threads " + cpu + " \\\n" else "")}  1>&2
    sed 's/^/gtcs\//;s/_Grn\.idat$/.gtc/' $green_idat_files
    rm "~{basename(bpm_file, ".gz")}"
    rm "~{basename(egt_file, ".gz")}"
    cat $green_idat_files $red_idat_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File green_idat_tsv = filebase + ".green_idat.tsv"
    File red_idat_tsv = filebase + ".red_idat.tsv"
    Directory gtcs = "gtcs"
    Array[File] gtc_files = read_lines(stdout())
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# https://support.terra.bio/hc/en-us/community/posts/360071476431-Terra-fails-to-delocalize-files-listed-through-read-lines-
task cel2affy {
  input {
    File? xml_file
    File? zip_file
    Array[File]+ cel_files
    File? cdf
    File? chrX_snps
    File? special_snps
    File? chrX_probes
    File? chrY_probes
    File? probeset_file
    Array[String]? chip_type
    Boolean table_output = false
    String? qmethod_spec
    File? read_models_brlmmp
    String? set_analysis_name
    File? target_sketch
    String? set_gender_method
    String? em_gender
    Float? female_thresh
    Float? male_thresh
    String filebase

    String docker
    Int cpu = 1 # unfortunately this task is not parallelizable
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 0
    Int maxRetries = 0
  }

  Float xml_size = size(xml_file, "GiB")
  Float zip_size = size(zip_file, "GiB")
  Float cel_size = length(cel_files) * size(cel_files[0], "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + xml_size + zip_size + (if table_output then 8.0 else 6.0) * cel_size)])
  Float memory = select_first([memory_override, 2 * 7.25])

  String? zip_dir = if defined(zip_file) then basename(select_first([zip_file]), ".zip") else None
  String analysis_name = if defined(set_analysis_name) then set_analysis_name else "AxiomGT1"

  command <<<
    set -euo pipefail
    cel_files=~{write_lines(cel_files)}
    echo "~{sep="\n" select_all([xml_file, zip_file, cdf, chrX_snps, special_snps, chrX_probes, chrY_probes, read_models_brlmmp, target_sketch])}" | \
      cat - $cel_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $cel_files
    (grep "\.gz" $cel_files  || if [[ $? -eq 1 ]]; then true; else exit $?; fi) | \
      tr '\n' '\0' | xargs -0 gunzip --force
    sed -i 's/.gz$//' $cel_files
    ~{if defined(zip_file) then "unzip -jd \"" + zip_dir + "\" \"" + basename(select_first([zip_file])) + "\" 1>&2" else ""}
    bcftools +affy2vcf --cel --chps $cel_files --output "~{filebase}.cel.tsv"
    echo "cel_files" | cat - $cel_files > cel_files.lines
    apt-probeset-genotype \
      ~{if defined(zip_dir) then "--analysis-files-path \"" + zip_dir + "\"" else ""} \
      ~{if defined(xml_file) then "--xml-file \"" + basename(select_first([xml_file])) + "\"" else ""} \
      --cel-files cel_files.lines \
      ~{if defined(cdf) then "--cdf-file \"" + basename(select_first([cdf])) + "\"" else ""} \
      ~{if defined(chrX_snps) then "--chrX-snps \"" + basename(select_first([chrX_snps])) + "\"" else ""} \
      ~{if defined(special_snps) then "--special-snps \"" + basename(select_first([special_snps])) + "\"" else ""} \
      ~{if defined(chrX_probes) then "--chrX-probes \"" + basename(select_first([chrX_probes])) + "\"" else ""} \
      ~{if defined(chrY_probes) then "--chrY-probes \"" + basename(select_first([chrY_probes])) + "\"" else ""} \
      ~{if defined(probeset_file) then "--probeset-ids \"" + select_first([probeset_file]) + "\"" else ""} \
      ~{if defined(chip_type) then "--chip-type " else ""}~{sep=" --chip-type " chip_type} \
      --table-output ~{table_output} \
      --cc-chp-output \
      ~{if table_output then "--summaries" else ""} \
      ~{if defined(qmethod_spec) then "--qmethod-spec " + qmethod_spec else ""} \
      ~{if defined(read_models_brlmmp) then "--read-models-brlmmp \"" + basename(select_first([read_models_brlmmp])) + "\"" else ""} \
      --write-models \
      ~{if defined(target_sketch) then "--target-sketch \"" + basename(select_first([target_sketch])) + "\"" else ""} \
      ~{if defined(set_analysis_name) then "--set-analysis-name " + set_analysis_name else ""} \
      ~{if defined(set_gender_method) then "--set-gender-method " + set_gender_method else ""} \
      ~{if defined(em_gender) then "--em-gender " + em_gender else ""} \
      ~{if defined(female_thresh) then "--female-thresh " + female_thresh else ""} \
      ~{if defined(male_thresh) then "--male-thresh " + male_thresh else ""}
    for sfx in snp-posteriors report~{if table_output then " calls confidences summary normalized-summary" else ""}; do
      mv "~{analysis_name}.$sfx.txt" "~{filebase}.$sfx.txt"
    done
    sed 's/^/cc-chp\//;s/\.CEL$/.~{analysis_name}.chp/' $cel_files
    echo "~{sep="\n" select_all([xml_file, zip_file, cdf, chrX_snps, special_snps, chrX_probes, chrY_probes, read_models_brlmmp, target_sketch])}" | \
      sed 's/^.*\///' | cat - $cel_files | tr '\n' '\0' | xargs -0 rm
    ~{if defined(zip_file) then "rm -r \"" + zip_dir + "\"" else ""}
    rm cel_files.lines
  >>>

  output {
    File cel_tsv = filebase + ".cel.tsv"
    Directory chps = "cc-chp"
    Array[File] chp_files = read_lines(stdout())
    File log_file = "apt-probeset-genotype.log"
    File snp_file = filebase + ".snp-posteriors.txt"
    File report_file = filebase + ".report.txt"
    File? calls_file = if table_output then filebase + ".calls.txt" else None
    File? confidences_file = if table_output then filebase + ".confidences.txt" else None
    File? summary_file = if table_output then filebase + ".summary.txt" else None
    File? normalized_summary_file = if table_output then filebase + ".normalized-summary.txt" else None
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task gtc2vcf {
  input {
    String? tags
    File bpm_file
    File csv_file
    File egt_file
    File ref_fasta
    File ref_fasta_fai
    Int? gc_window_size
    Array[File]+ gtc_files
    Int capacity = 32768
    Boolean use_gtc_sample_names = false
    Boolean do_not_check_bpm = false
    File? sam_file
    Map[String, String]? reheader_map
    String filebase
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float bpm_size = (if basename(bpm_file) != basename(bpm_file, ".gz") then 4.0 else 1.0) * size(bpm_file, "GiB")
  Float csv_size = (if basename(csv_file) != basename(csv_file, ".gz") then 4.0 else 1.0) * size(csv_file, "GiB")
  Float egt_size = (if basename(egt_file) != basename(egt_file, ".gz") then 2.0 else 1.0) * size(egt_file, "GiB")
  Float ref_size = size(ref_fasta, "GiB")
  Float gtc_size = length(gtc_files) * size(gtc_files[0], "GiB")
  Float sam_size = size(sam_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + bpm_size + csv_size + egt_size + ref_size + 8.0 * gtc_size + sam_size)])
  # due to heavy random access to the reference genome, it is important here that enough memory to cache the reference is provided
  Float memory = select_first([memory_override, 3.5 + 2.0 * csv_size + 2.0 * egt_size + ref_size +
    length(gtc_files) * capacity * 19 / 1024 / 1024 / 1024])

  command <<<
    set -euo pipefail
    gtc_files=~{write_lines(gtc_files)}
    echo "~{sep="\n" select_all([bpm_file, csv_file, egt_file, ref_fasta, ref_fasta_fai, sam_file])}" | \
      cat - $gtc_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $gtc_files
    ~{if basename(bpm_file) != basename(bpm_file, ".gz") then "gunzip --force \"" + basename(bpm_file) + "\"" else ""}
    ~{if basename(egt_file) != basename(egt_file, ".gz") then "gunzip --force \"" + basename(egt_file) + "\"" else ""}
    (grep "\.gz" $gtc_files || if [[ $? -eq 1 ]]; then true; else exit $?; fi) | \
      tr '\n' '\0' | xargs -0 gunzip --force
    sed -i 's/.gz$//' $gtc_files
    ~{if defined(reheader_map) then "reheader_file=" else ""}~{if defined(reheader_map) then write_map(select_first([reheader_map])) else ""}
    bcftools +gtc2vcf \
      --no-version \
      --output-type u \
      ~{if defined(tags) then "--tags " + tags else ""} \
      --bpm "~{basename(bpm_file, ".gz")}" \
      --csv "~{basename(csv_file)}" \
      --egt "~{basename(egt_file, ".gz")}" \
      --fasta-ref "~{basename(ref_fasta)}" \
      ~{if defined(gc_window_size) then "--gc-window-size " + select_first([gc_window_size]) else ""} \
      --gtcs $gtc_files \
      ~{if capacity != 32768 then "--capacity " + capacity else ""} \
      ~{if use_gtc_sample_names then "--use-gtc-sample-names" else ""} \
      ~{if do_not_check_bpm then "--do-not-check-bpm" else ""} \
      --extra "~{filebase}.gtc.tsv" \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      ~{if defined(sam_file) then "--sam-flank \"" + basename(select_first([sam_file])) + "\"" else ""} | \
      ~{if defined(reheader_map) then "bcftools reheader --samples $reheader_file |" else ""} \
      bcftools sort --output-type u --temp-dir ./bcftools-sort.XXXXXX | \
      bcftools norm --no-version --output-type ~{if uncompressed then "u" else "b"} --output "~{filebase}.bcf" --check-ref x --fasta-ref "~{basename(ref_fasta)}"~{if cpu > 1 then " --threads " + (cpu - 1) else ""}
    bcftools index --force "~{filebase}.bcf"
    bcftools query --list-samples "~{filebase}.bcf" > "~{filebase}.sample_id.lines"
    rm "~{basename(bpm_file, ".gz")}"
    rm "~{basename(egt_file, ".gz")}"
    echo "~{sep="\n" select_all([csv_file, ref_fasta, ref_fasta_fai, sam_file])}" | \
      sed 's/^.*\///' | cat - $gtc_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File gtc_tsv = filebase + ".gtc.tsv"
    File vcf_file = filebase + ".bcf"
    File vcf_idx = filebase + ".bcf.csi"
    File sample_id_lines = filebase + ".sample_id.lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task chp2vcf {
  input {
    String? tags
    File csv_file
    File ref_fasta
    File ref_fasta_fai
    Int? gc_window_size
    File? probeset_file
    File snp_file
    Array[File] chp_files
    File? sam_file
    Map[String, String]? reheader_map
    String filebase
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float csv_size = (if basename(csv_file) != basename(csv_file, ".gz") then 4.0 else 1.0) * size(csv_file, "GiB")
  Float ref_size = size(ref_fasta, "GiB")
  Float snp_size = (if basename(snp_file) != basename(snp_file, ".gz") then 2.0 else 1.0) * size(snp_file, "GiB")
  Float chp_size = length(chp_files) * size(chp_files[0], "GiB")

  Float sam_size = size(sam_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + csv_size + ref_size + 8.0 * chp_size + snp_size + sam_size)])
  # due to heavy random access to the reference genome, it is important here that enough memory to cache the reference is provided
  Float memory = select_first([memory_override, 3.5 + 2.0 * csv_size + 2.0 * snp_size + ref_size +
    length(chp_files) * 32768 / 1024 / 1024 / 1024])

  command <<<
    set -euo pipefail
    chp_files=~{write_lines(chp_files)}
    echo "~{sep="\n" select_all([csv_file, ref_fasta, ref_fasta_fai, snp_file, sam_file])}" | \
      cat - $chp_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $chp_files
    (grep "\.gz" $chp_files || if [[ $? -eq 1 ]]; then true; else exit $?; fi) | \
      tr '\n' '\0' | xargs -0 gunzip --force
    sed -i 's/.gz$//' $chp_files
    ~{if defined(reheader_map) then "reheader_file=" else ""}~{if defined(reheader_map) then write_map(select_first([reheader_map])) else ""}
    bcftools +affy2vcf \
      --no-version \
      --output-type u \
      ~{if defined(tags) then "--tags " + tags else ""} \
      --csv "~{basename(csv_file)}" \
      --fasta-ref "~{basename(ref_fasta)}" \
      ~{if defined(gc_window_size) then "--gc-window-size " + select_first([gc_window_size]) else ""} \
      ~{if defined(probeset_file) then "--probeset-ids \"" + select_first([probeset_file]) + "\"" else ""} \
      --snp "~{basename(snp_file)}" \
      --chps $chp_files \
      --extra "~{filebase}.affy.tsv" \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      ~{if defined(sam_file) then "--sam-flank \"" + basename(select_first([sam_file])) + "\"" else ""} | \
      ~{if defined(reheader_map) then "bcftools reheader --samples $reheader_file |" else ""} \
      bcftools sort --output-type u --temp-dir ./bcftools-sort.XXXXXX | \
      bcftools norm --no-version --output-type ~{if uncompressed then "u" else "b"} --output "~{filebase}.bcf" --check-ref x --fasta-ref "~{basename(ref_fasta)}"~{if cpu > 1 then " --threads " + (cpu - 1) else ""}
    bcftools index --force "~{filebase}.bcf"
    bcftools query --list-samples "~{filebase}.bcf" > "~{filebase}.sample_id.lines"
    echo "~{sep="\n" select_all([csv_file, ref_fasta, ref_fasta_fai, snp_file, sam_file])}" | \
      sed 's/^.*\///' | cat - $chp_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File affy_tsv = filebase + ".affy.tsv"
    File vcf_file = filebase + ".bcf"
    File vcf_idx = filebase + ".bcf.csi"
    File sample_id_lines = filebase + ".sample_id.lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task txt2vcf {
  input {
    String? tags
    File csv_file
    File ref_fasta
    File ref_fasta_fai
    Int? gc_window_size
    File? probeset_file
    File calls_file
    File? confidences_file
    File summary_file
    File report_file
    File snp_file
    File? sam_file
    Map[String, String]? reheader_map
    String filebase
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float csv_size = (if basename(csv_file) != basename(csv_file, ".gz") then 4.0 else 1.0) * size(csv_file, "GiB")
  Float ref_size = size(ref_fasta, "GiB")
  Float calls_size = (if basename(calls_file) != basename(calls_file, ".gz") then 2.0 else 1.0) * size(calls_file, "GiB")
  Float confidences_size = (if defined(confidences_file) && basename(select_first([confidences_file])) != basename(select_first([confidences_file]), ".gz") then 2.0 else 1.0) * size(confidences_file, "GiB")
  Float summary_size = (if basename(summary_file) != basename(summary_file, ".gz") then 2.0 else 1.0) * size(summary_file, "GiB")
  Float report_size = (if basename(report_file) != basename(report_file, ".gz") then 2.0 else 1.0) * size(report_file, "GiB")
  Float snp_size = (if basename(snp_file) != basename(snp_file, ".gz") then 2.0 else 1.0) * size(snp_file, "GiB")

  Float sam_size = size(sam_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + csv_size + ref_size + 8.0 * (calls_size + confidences_size + summary_size) + 2.0 * report_size + snp_size + sam_size)])
  # due to heavy random access to the reference genome, it is important here that enough memory to cache the reference is provided
  Float memory = select_first([memory_override, 3.5 + 2.0 * csv_size + 2.0 * snp_size + ref_size])

  command <<<
    set -euo pipefail
    ~{if defined(reheader_map) then "reheader_file=" else ""}~{if defined(reheader_map) then write_map(select_first([reheader_map])) else ""}
    echo "~{sep="\n" select_all([csv_file, ref_fasta, ref_fasta_fai, calls_file, confidences_file, summary_file, report_file, snp_file, sam_file])}" | \
      tr '\n' '\0' | xargs -0 mv -t .
    ~{if basename(report_file) != basename(report_file, ".gz") then "gunzip --force \"" + basename(report_file) + "\"" else ""}
    (~{if basename(calls_file) != basename(calls_file, ".gz") then "z" else ""}grep -v ^# "~{basename(calls_file)}" || if [[ $? -eq 141 ]]; then true; else exit $?; fi) | \
      head -n1 | tr '\t' '\n' | tail -n+2 | \
      awk -F"\t" 'NR==FNR && $0!~"^#" {if ($1=="cel_files") print; else x[$1]=$0} NR>FNR {print x[$1]}' \
      "~{basename(report_file, ".gz")}" - > ~{filebase}.affy.tsv
    rm "~{basename(report_file, ".gz")}"
    bcftools +affy2vcf \
      --no-version \
      --output-type u \
      ~{if defined(tags) then "--tags " + tags else ""} \
      --csv "~{basename(csv_file)}" \
      --fasta-ref "~{basename(ref_fasta)}" \
      ~{if defined(gc_window_size) then "--gc-window-size " + select_first([gc_window_size]) else ""} \
      ~{if defined(probeset_file) then "--probeset-ids \"" + select_first([probeset_file]) + "\"" else ""} \
      --calls "~{basename(calls_file)}" \
      ~{if defined(confidences_file) then "--confidences \"" + basename(select_first([confidences_file])) + "\"" else ""} \
      --summary "~{basename(summary_file)}" \
      --snp "~{basename(snp_file)}" \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      ~{if defined(sam_file) then "--sam-flank \"" + basename(select_first([sam_file])) + "\"" else ""} | \
      ~{if defined(reheader_map) then "bcftools reheader --samples $reheader_file |" else ""} \
      bcftools sort --output-type u --temp-dir ./bcftools-sort.XXXXXX | \
      bcftools norm --no-version --output-type ~{if uncompressed then "u" else "b"} --output "~{filebase}.bcf" --check-ref x --fasta-ref "~{basename(ref_fasta)}"~{if cpu > 1 then " --threads " + (cpu - 1) else ""}
    bcftools index --force "~{filebase}.bcf"
    bcftools query --list-samples "~{filebase}.bcf" > "~{filebase}.sample_id.lines"
    echo "~{sep="\n" select_all([csv_file, ref_fasta, ref_fasta_fai, calls_file, confidences_file, summary_file, snp_file, sam_file])}" | \
      sed 's/^.*\///' | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File affy_tsv = filebase + ".affy.tsv"
    File vcf_file = filebase + ".bcf"
    File vcf_idx = filebase + ".bcf.csi"
    File sample_id_lines = filebase + ".sample_id.lines"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task ref_scatter {
  input {
    Int n_chrs
    File ref_fasta_fai
    File genetic_map_file
    Float max_win_size_cm
    Float overlap_size_cm

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  String filebase = basename(ref_fasta_fai, ".fai")

  command <<<
    set -euo pipefail
    mv "~{ref_fasta_fai}" .
    mv "~{genetic_map_file}" .
    head -n~{n_chrs} "~{basename(ref_fasta_fai)}" | cut -f1,2 > chr2len.tsv
    python3 <<CODE
    import sys, pandas as pd, numpy as np
    chr2len = {}
    with open('chr2len.tsv') as f:
      for line in f:
        (key, val) = line.split('\t')
        chr2len[key] = int(val)
    df_map = pd.read_csv('~{basename(genetic_map_file)}', delim_whitespace = True, header = 0, names = ['CHR', 'POS' ,'RATE', 'CM'])
    df_out = {}
    for chr, df_group in df_map.groupby('CHR'):
      fai_chr = str(chr) if str(chr) in chr2len else 'chr' + str(chr) if 'chr' + str(chr) in chr2len else 'X' if 'X' in chr2len else 'chrX' if 'chrX' in chr2len else None
      chr_cm_len = max(df_group['CM'])
      n_win = np.ceil((chr_cm_len - ~{overlap_size_cm})/(~{max_win_size_cm} - ~{overlap_size_cm}))
      win_size = (chr_cm_len - ~{overlap_size_cm}) / n_win + ~{overlap_size_cm}
      cm_begs = (win_size - ~{overlap_size_cm}) * np.arange(1, n_win)
      cm_ends = (win_size - ~{overlap_size_cm}) * np.arange(1, n_win) + ~{overlap_size_cm}
      pos_begs = np.concatenate(([1], np.interp(cm_begs, df_group['CM'], df_group['POS'], period = np.inf).astype(int)))
      pos_ends = np.concatenate((np.interp(cm_ends, df_group['CM'], df_group['POS'], period = np.inf).astype(int), [chr2len[fai_chr]]))
      df_out[fai_chr] = pd.DataFrame.from_dict({'CHR': fai_chr, 'BEG': pos_begs, 'END': pos_ends})
    df = pd.concat([df_out[fai_chr] for fai_chr in chr2len.keys()])
    df[['CHR', 'BEG', 'END']].to_csv('~{filebase}.bed', sep='\t', header = False, index = False)
    CODE
    rm chr2len.tsv
    rm "~{basename(ref_fasta_fai)}"
    rm "~{basename(genetic_map_file)}"
  >>>

  output {
    File intervals_bed = filebase + ".bed"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# https://support.terra.bio/hc/en-us/community/posts/360071476431-Terra-fails-to-delocalize-files-listed-through-read-lines-
task vcf_scatter {
  input {
    File vcf_file
    File intervals_bed
    String other = "other"
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 3.0 * vcf_size)])
  Float memory = select_first([memory_override, 3.5])
  String filebase = basename(basename(vcf_file, ".bcf"), ".vcf.gz")

  command <<<
    set -euo pipefail
    mv "~{vcf_file}" .
    mv "~{intervals_bed}" .
    awk -F"\t" '{print $1":"$2"-"$3"\t"NR-1}' "~{basename(intervals_bed)}" > regions.lines
    bcftools query --list-samples "~{basename(vcf_file)}" > "~{filebase}.sample_id.lines"
    bcftools annotate \
      --no-version \
      --output-type u \
      --remove ID,QUAL,INFO,^FMT/GT \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      "~{basename(vcf_file)}" | \
    bcftools +scatter \
      --no-version \
      --output-type ~{if uncompressed then "u" else "b"} \
      --output vcfs \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      --scatter-file regions.lines \
      --prefix "~{filebase}." \
      --extra "~{other}"
    cut -f2 regions.lines | sed 's/^/vcfs\/~{filebase}./;s/$/.bcf/'
    rm "~{basename(vcf_file)}"
    rm "~{basename(intervals_bed)}"
    rm regions.lines
  >>>

  output {
    File sample_id_lines = filebase + ".sample_id.lines"
    Directory vcfs = "vcfs"
    Array[File] vcf_files = read_lines(stdout())
    File other_vcf_file = "vcfs/" + filebase + "." + other + ".bcf"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_merge {
  input {
    Array[File]+ vcf_files
    String filebase
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_files, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10 + 2.0 * vcf_size)])
  Float memory = select_first([memory_override, 3.5])

  command <<<
    set -euo pipefail
    ~{if length(vcf_files) > 1 then "vcf_files=" else ""}~{if length(vcf_files) > 1 then write_lines(vcf_files) else ""}
    ~{if length(vcf_files) > 1 then "cat $vcf_files | tr '\\n' '\\0' | xargs -0 mv -t .\n" +
      "sed -i 's/^.*\\///' $vcf_files\n" +
      "bcftools merge \\\n" +
      "  --no-version \\\n" +
      "  --output-type " + (if uncompressed then "u" else "b") + " \\\n" +
      "  --output \"" + filebase + ".bcf\" \\\n" +
      "  --file-list $vcf_files \\\n" +
      "  --merge none \\\n" +
      "  --no-index \\\n" +
      (if cpu > 1 then "  --threads " + (cpu - 1) else "")
    else "mv \"" + vcf_files[0] + "\" \"" + filebase + ".bcf\""}
    bcftools index --force "~{filebase}.bcf"
    ~{if length(vcf_files) > 1 then "cat $vcf_files | tr '\\n' '\\0' | xargs -0 rm" else ""}
  >>>

  output {
    File vcf_file = filebase + ".bcf"
    File vcf_idx = filebase + ".bcf.csi"
  }

  runtime {
    memory: memory + " GiB"
    disks: "local-disk " + disk_size + " HDD"
    cpu: cpu
    docker: docker
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_qc {
  input {
    File vcf_file
    File vcf_idx
    File dup_file
    File sample_id_file
    File computed_gender_file
    File call_rate_file
    Float sample_call_rate_thr = 0.97
    Float variant_call_rate_thr = 0.97
    Float dup_divergence_thr = 0.02
    Float genotype_exc_het_thr = 0.000001
    Float genotype_sex_cor_thr = 0.000001
    File? duplicate_samples_file
    File? extra_xcl_vcf_file
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + vcf_size)])
  Float memory = select_first([memory_override, 3.5])
  String filebase = basename(basename(vcf_file, ".bcf"), ".vcf.gz")

  command <<<
    set -euo pipefail
    echo "~{sep="\n" select_all([vcf_file, vcf_idx, dup_file, sample_id_file, computed_gender_file, call_rate_file, duplicate_samples_file, extra_xcl_vcf_file])}" | \
      tr '\n' '\0' | xargs -0 mv -t .
    paste -d $'\t' "~{basename(sample_id_file)}" "~{basename(computed_gender_file)}" > computed_gender.map
    paste -d $'\t' "~{basename(sample_id_file)}" "~{basename(call_rate_file)}" | \
      awk -F"\t" '$2<~{sample_call_rate_thr} {print $1}' ~{if defined(duplicate_samples_file) then "| \\\n" +
      "  cat - \"" + basename(select_first([duplicate_samples_file])) + "\" | \\\n" +
      "  sort | uniq " else ""}> samples_xcl.lines
    bcftools query --format "\n" "~{basename(vcf_file)}" | wc -l
    echo '##INFO=<ID=JK,Number=1,Type=Float,Description="Jukes Cantor">' | \
      bcftools annotate --no-version --output-type u --annotations "~{basename(dup_file)}" --columns CHROM,FROM,TO,JK --header-lines /dev/stdin~{if cpu > 1 then " --threads " + (cpu - 1) else ""} "~{basename(vcf_file)}" | \
      bcftools view --no-version --output-type u~{if cpu > 1 then " --threads " + (cpu - 1) else ""} --samples-file ^samples_xcl.lines | \
      bcftools +fill-tags --no-version --output-type u --targets ^Y,MT,chrY,chrM~{if cpu > 1 then " --threads " + (cpu - 1) else ""} -- --tags ExcHet,F_MISSING | \
      bcftools +mochatools --no-version --output-type u~{if cpu > 1 then " --threads " + (cpu - 1) else ""} -- --sex computed_gender.map --drop-genotypes | \
      bcftools annotate --no-version --output-type ~{if uncompressed then "u" else "b"} --output "~{filebase}.xcl.bcf" \
      --include 'FILTER!="." && FILTER!="PASS" || INFO/JK<~{dup_divergence_thr} || INFO/ExcHet<~{genotype_exc_het_thr} || INFO/F_MISSING>1-~{variant_call_rate_thr} ||
        INFO/AC_Sex_Test<~{genotype_sex_cor_thr} && CHROM!="X" && CHROM!="chrX" && CHROM!="Y" && CHROM!="chrY"' \
      --remove ^INFO/JK,^INFO/ExcHet,^INFO/F_MISSING,^INFO/AC_Sex_Test~{if cpu > 1 then " --threads " + (cpu - 1) else ""}
    bcftools index --force "~{filebase}.xcl.bcf"
    ~{if defined(extra_xcl_vcf_file) then "mv \"" + filebase + ".xcl.bcf\" \"" + filebase + ".tmp.bcf\"\n" +
      "mv \"" + filebase + ".xcl.bcf.csi\" \"" + filebase + ".tmp.bcf.csi\"\n" +
      "bcftools index --force \"" + basename(select_first([extra_xcl_vcf_file])) + "\"\n" +
      "bcftools merge --no-version --output-type " + (if uncompressed then "u" else "b") + " --output \"" + filebase + ".xcl.bcf\" --merge none \"" + filebase + ".tmp.bcf\" \"" + basename(select_first([extra_xcl_vcf_file])) + "\"\n" +
      "bcftools index --force \"" + filebase + ".xcl.bcf\"\n" +
      "rm \"" + filebase + ".tmp.bcf\" \"" + filebase + ".tmp.bcf.csi\"" else ""}
    echo "~{sep="\n" select_all([vcf_file, vcf_idx, dup_file, sample_id_file, computed_gender_file, call_rate_file, duplicate_samples_file, extra_xcl_vcf_file])}" | \
      sed 's/^.*\///' | tr '\n' '\0' | xargs -0 rm
    rm computed_gender.map samples_xcl.lines
  >>>

  output {
    Int n_vars = read_int(stdout())
    File xcl_vcf_file = filebase + ".xcl.bcf"
    File xcl_vcf_idx = filebase + ".xcl.bcf.csi"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_phase {
  input {
    Int n_vars
    Int n_smpls
    File unphased_vcf_file
    File unphased_vcf_idx
    File genetic_map_file
    Int? n_panel_smpls
    File? ref_vcf_file
    File? ref_vcf_idx
    File? xcl_vcf_file
    File? xcl_vcf_idx
    String chr
    Boolean eagle = false
    Boolean uncompressed = false
    String? phase_extra_args

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0

    Float mult = 6.0 # how much more memory SHAPEIT4 consumes compared to Eagle
  }

  Float vcf_size = size(unphased_vcf_file, "GiB")
  Float ref_size = size(ref_vcf_file, "GiB")
  Float xcl_size = size(xcl_vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 3.0 * vcf_size + ref_size + xcl_size)])
  Float memory = select_first([memory_override, 3.5 + (if eagle then 1.5 else mult * 1.5) *
    n_vars * (n_smpls + (if defined(ref_vcf_file) then select_first([n_panel_smpls]) else 0)) / 1024 / 1024 / 1024])

  String filebase = basename(basename(unphased_vcf_file, ".bcf"), ".vcf.gz")
  String dollar = "$"

  command <<<
    set -euo pipefail
    echo "~{sep="\n" select_all([unphased_vcf_file, unphased_vcf_idx, genetic_map_file, ref_vcf_file, ref_vcf_idx, xcl_vcf_file, xcl_vcf_idx])}" | \
      tr '\n' '\0' | xargs -0 mv -t .
    ~{if defined(xcl_vcf_file) then
    "bcftools isec \\\n" +
    "  --no-version \\\n" +
    "  --output-type " + (if uncompressed then "u" else "b") + " \\\n" +
    "  --output \"" + filebase + ".isec.bcf\" \\\n" +
    "  --complement \\\n" +
    "  --exclude \"N_ALT>1\" \\\n" +
    "  --write 1 \\\n" +
    "  \"" + basename(unphased_vcf_file) + "\" \\\n" +
    "  \"" + basename(select_first([xcl_vcf_file])) + "\"\n" +
    "bcftools index --force \"" + filebase + ".isec.bcf\"" else ""}
    ~{if eagle then
      "bio-eagle \\\n" +
      "  --geneticMapFile \"" + basename(genetic_map_file) + "\" \\\n" +
      "  --outPrefix \"" + filebase + ".tmp\" \\\n" +
      (if cpu > 1 then "  --numThreads " + cpu + " \\\n" else "") +
      (if defined(ref_vcf_file) then "  --vcfRef \"" + basename(select_first([ref_vcf_file])) + "\" \\\n" +
      "  --vcfTarget \"" else "  --vcf \"") + (if defined(xcl_vcf_file) then filebase + ".isec.bcf" else basename(unphased_vcf_file)) + "\" \\\n" +
      "  --vcfOutFormat " + (if uncompressed then "u" else "b") + " \\\n" +
      "  --chrom " + chr + " \\\n" +
      (if defined(phase_extra_args) then phase_extra_args + " \\\n" else "") +
      "  1>&2"
    else
      "chr=" + chr + "; zcat \"" + basename(genetic_map_file) + "\" | \\\n" +
      "  sed 's/^23/X/' | awk -v chr=" + dollar + "{chr#chr} '$1==chr {print $2,$3,$4}' > genetic_map.txt\n" +
      "shapeit4 \\\n" +
      (if cpu > 1 then "  --thread " + cpu + " \\\n" else "") +
      "  --input \"" + (if defined(xcl_vcf_file) then filebase + ".isec.bcf" else basename(unphased_vcf_file)) + "\" \\\n" +
      (if defined(ref_vcf_file) then "  --reference \"" + basename(select_first([ref_vcf_file])) + "\" \\\n" else "") +
      "  --map genetic_map.txt \\\n" +
      "  --region " + chr + " \\\n" +
      "  --output \"" + filebase + ".tmp.bcf\" \\\n" +
      (if defined(phase_extra_args) then phase_extra_args + " \\\n" else "") +
      "  1>&2\n" +
      "rm genetic_map.txt"}
    ~{if defined(xcl_vcf_file) then "rm \"" + filebase + ".isec.bcf\" \"" + filebase + ".isec.bcf.csi\"" else ""}
    bcftools index --force "~{filebase}.tmp.bcf"
    bcftools annotate \
      --no-version \
      --output-type ~{if uncompressed then "u" else "b"} \
      --output "~{filebase}.phased.bcf" \
      --annotations "~{filebase}.tmp.bcf" \
      --columns -FMT/GT \
      "~{basename(unphased_vcf_file)}" \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""}
    rm "~{filebase}.tmp.bcf" "~{filebase}.tmp.bcf.csi"
    echo "~{sep="\n" select_all([unphased_vcf_file, unphased_vcf_idx, genetic_map_file, ref_vcf_file, ref_vcf_idx, xcl_vcf_file, xcl_vcf_idx])}" | \
      sed 's/^.*\///' | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File pvcf_file = filebase + ".phased.bcf"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# https://support.terra.bio/hc/en-us/community/posts/360071476431-Terra-fails-to-delocalize-files-listed-through-read-lines-
task vcf_split {
  input {
    File vcf_file
    Array[String] batches
    File sample_id_file
    File? ped_file
    String? rule
    Boolean uncompressed = false

    String docker
    Int? disk_size_override
    Int cpu = 1
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 2.0 * vcf_size)])
  Float memory = select_first([memory_override, 3.5])
  String filebase = basename(basename(vcf_file, ".bcf"), ".vcf.gz")

  command <<<
    set -euo pipefail
    filebases=~{write_lines(prefix(filebase + '.', batches))}
    mv "~{vcf_file}" .
    mv "~{sample_id_file}" .
    ~{if defined(ped_file) then "mv -t . \"" + ped_file + "\"" else ""}
    mkdir mendel
    ~{if defined(ped_file) && defined(rule) then "bcftools +mendelian --output \"mendel/" + filebase + ".mendel.tsv\" --rules \"" + select_first([rule]) + "\" --ped \"" + basename(select_first([ped_file])) + "\" \"" + basename(vcf_file) + "\"" else ""}
    sed 's/\t/,/g;s/$/\t-/' "~{basename(sample_id_file)}" | paste -d $'\t' - $filebases > samples_file.txt
    ~{if defined(ped_file) then "bcftools +trio-phase --no-version --output-type u" + (if cpu > 1 then " --threads " + (cpu - 1) else "") + " \"" + basename(vcf_file) + "\" -- --ped \"" + basename(select_first([ped_file])) + "\" | \\\n" +
      "  bcftools +split --output-type " + (if uncompressed then "u" else "b") + " --output vcfs --samples-file samples_file.txt"
      else "bcftools +split --output-type " + (if uncompressed then "u" else "b") + " --output vcfs --samples-file samples_file.txt \"" + basename(vcf_file) + "\""}
    cut -f1 $filebases | sed 's/^/vcfs\//;s/$/.bcf/'
    rm "~{basename(vcf_file)}"
    rm "~{basename(sample_id_file)}"
    ~{if defined(ped_file) then "rm \"" + basename(select_first([ped_file])) + "\"" else ""}
    rm samples_file.txt
  >>>

  output {
    File? mendel_tsv = if defined(ped_file) then "mendel/" + filebase + ".mendel.tsv" else None
    Directory vcfs = "vcfs"
    Array[File] vcf_files = read_lines(stdout())
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_concat {
  input {
    Array[File]+ vcf_files
    File? other_vcf_file
    File? ref_fasta_fai
    Boolean ligate = true
    String filebase
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_files, "GiB")
  Float other_vcf_size = size(other_vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 2.0 * vcf_size + 2.0 * other_vcf_size)])
  Float memory = select_first([memory_override, 3.5])

  command <<<
    set -euo pipefail
    vcf_files=~{write_lines(vcf_files)}
    ~{if defined(other_vcf_file) then "echo \"" + other_vcf_file + "\" >> $vcf_files" else ""}
    ~{if defined(ref_fasta_fai) then "mv \"" + select_first([ref_fasta_fai]) + "\" ." else ""}
    cat $vcf_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $vcf_files
    ~{if ligate then "cat $vcf_files | tr '\\n' '\\0' | xargs -0 -n 1 bcftools index --force" else ""}
    bcftools concat \
      --no-version \
      --output-type ~{if uncompressed then "u" else "b"} \
      --file-list $vcf_files \
      ~{if ligate then "--ligate" else ""} \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      --output "~{filebase}.bcf"
    ~{if defined(ref_fasta_fai) then
       "mv  \"" + filebase + ".bcf\" \"" + filebase + ".tmp.bcf\"\n" +
       "bcftools reheader \\\n" +
       "  --fai \"" + basename(select_first([ref_fasta_fai])) + "\" \\\n" +
       "  --output \"" + filebase + ".bcf\" \\\n" +
       "  \"" + filebase + ".tmp.bcf\"\n" +
       "rm \"" + filebase + ".tmp.bcf\""
      else ""}
    bcftools index --force "~{filebase}.bcf"
    ~{if ligate then "cat $vcf_files | sed 's/$/.csi/' | tr '\\n' '\\0' | xargs -0 rm" else ""}
    ~{if defined(ref_fasta_fai) then "rm \"" + basename(select_first([ref_fasta_fai])) + "\"" else ""}
    cat $vcf_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File vcf_file = filebase + ".bcf"
    File vcf_idx = filebase + ".bcf.csi"
  }

  runtime {
    memory: memory + " GiB"
    disks: "local-disk " + disk_size + " HDD"
    cpu: cpu
    docker: docker
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_import {
  input {
    File pvcf_file
    File pvcf_idx
    File unphased_vcf_file
    File unphased_vcf_idx
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float gt_size = size(pvcf_file, "GiB")
  Float vcf_size = size(unphased_vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 2.0 * gt_size + 2.0 * vcf_size)])
  Float memory = select_first([memory_override, 3.5])
  String filebase = basename(basename(unphased_vcf_file, ".bcf"), ".vcf.gz")

  command <<<
    set -euo pipefail
    mv "~{pvcf_file}" .
    mv "~{pvcf_idx}" .
    mv "~{unphased_vcf_file}" .
    mv "~{unphased_vcf_idx}" .
    bcftools annotate \
      --no-version \
      --output-type ~{if uncompressed then "u" else "b"} \
      --output "~{filebase}.phased.bcf" \
      --annotations "~{basename(pvcf_file)}" \
      --columns -FMT/GT \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      "~{basename(unphased_vcf_file)}"
    bcftools index --force "~{filebase}.phased.bcf"
    rm "~{basename(pvcf_file)}"
    rm "~{basename(pvcf_idx)}"
    rm "~{basename(unphased_vcf_file)}"
    rm "~{basename(unphased_vcf_idx)}"
  >>>

  output {
    File vcf_file = filebase + ".phased.bcf"
    File vcf_idx = filebase + ".phased.bcf.csi"
  }

  runtime {
    memory: memory + " GiB"
    disks: "local-disk " + disk_size + " HDD"
    cpu: cpu
    docker: docker
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task vcf_mocha {
  input {
    String rule
    File pvcf_file
    File pvcf_idx
    File? sample_id_file
    File? computed_gender_file
    File? call_rate_file
    File? xcl_vcf_file
    File? xcl_vcf_idx
    File? cnp_file
    String? mhc_reg
    String? kir_reg
    String? mocha_extra_args
    String ext_string
    Boolean uncompressed = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float? memory_override
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float pvcf_size = size(pvcf_file, "GiB")
  Float xcl_size = size(xcl_vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + 2.0 * pvcf_size + xcl_size)])
  Float memory = select_first([memory_override, ceil(4.0 + 0.1 * pvcf_size)])
  String filebase = basename(basename(pvcf_file, ".bcf"), ".vcf.gz")

  command <<<
    set -euo pipefail
    echo "~{sep="\n" select_all([pvcf_file, pvcf_idx, sample_id_file, computed_gender_file, call_rate_file, xcl_vcf_file, xcl_vcf_idx, cnp_file])}" | \
      tr '\n' '\0' | xargs -0 mv -t .
    ~{if defined(sample_id_file) && defined(computed_gender_file) then "paste -d $'\\t' \"" + basename(select_first([sample_id_file])) + "\" \"" +
      basename(select_first([computed_gender_file])) + "\" > computed_gender.map" else ""}
    ~{if defined(sample_id_file) && defined(call_rate_file) then "paste -d $'\\t' \"" + basename(select_first([sample_id_file])) + "\" \"" +
      basename(select_first([call_rate_file])) + "\" > call_rate.map" else ""}
    bcftools +mocha \
      --rules "~{rule}" \
      --no-version \
      ~{if defined(sample_id_file) && defined(computed_gender_file) then "--sex computed_gender.map" else ""} \
      ~{if defined(sample_id_file) && defined(call_rate_file) then "--call-rate call_rate.map" else ""} \
      ~{if defined(xcl_vcf_file) then "--variants \"^" + basename(select_first([xcl_vcf_file])) + "\"" else ""} \
      ~{if defined(cnp_file) then "--cnp \"" + basename(select_first([cnp_file])) + "\"" else ""} \
      ~{if defined(mhc_reg) then "--mhc \"" + mhc_reg + "\"" else ""} \
      ~{if defined(kir_reg) then "--kir \"" + kir_reg + "\"" else ""} \
      ~{if cpu > 1 then "--threads " + (cpu - 1) else ""} \
      --output-type ~{if uncompressed then "u" else "b"} \
      --output "~{filebase}.~{ext_string}.bcf" \
      --mosaic-calls "~{filebase}.calls.tsv" \
      --genome-stats "~{filebase}.stats.tsv" \
      --ucsc-bed "~{filebase}.ucsc.bed" \
      "~{basename(pvcf_file)}" \
      ~{mocha_extra_args}
    bcftools index --force "~{filebase}.~{ext_string}.bcf"
    echo "~{sep="\n" select_all([pvcf_file, pvcf_idx, sample_id_file, computed_gender_file, call_rate_file, xcl_vcf_file, xcl_vcf_idx, cnp_file])}" | \
      sed 's/^.*\///' | tr '\n' '\0' | xargs -0 rm
    ~{if defined(sample_id_file) && defined(computed_gender_file) then "rm computed_gender.map" else ""}
  >>>

  output {
    File mocha_vcf_file = filebase + "." + ext_string + ".bcf"
    File mocha_vcf_idx = filebase + "." + ext_string + ".bcf.csi"
    File calls_tsv = filebase + ".calls.tsv"
    File stats_tsv = filebase + ".stats.tsv"
    File ucsc_bed = filebase + ".ucsc.bed"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

# https://support.terra.bio/hc/en-us/community/posts/360071476431-Terra-fails-to-delocalize-files-listed-through-read-lines-
task mocha_plot {
  input {
    File vcf_file
    File vcf_idx
    File calls_tsv
    File stats_tsv
    File cyto_file
    Float call_rate_thr = 0.97
    Float baf_auto_thr = 0.03
    String? mocha_plot_extra_args
    Boolean do_not_plot_sex_chromosomes = false

    String docker
    Int cpu = 1
    Int? disk_size_override
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  Float vcf_size = size(vcf_file, "GiB")
  Int disk_size = select_first([disk_size_override, ceil(10.0 + vcf_size)])

  command <<<
    set -euo pipefail
    mv "~{vcf_file}" .
    mv "~{vcf_idx}" .
    mv "~{calls_tsv}" .
    mv "~{stats_tsv}" .
    mv "~{cyto_file}" .
    mkdir pngs
    beg_pos=$(head -n1 "~{basename(calls_tsv)}" | tr '\t' '\n' | grep ^beg_)
    end_pos=$(head -n1 "~{basename(calls_tsv)}" | tr '\t' '\n' | grep ^end_)
    awk -F"\t" -v OFS="\t" -v beg_pos=$beg_pos -v end_pos=$end_pos '
      NR==FNR && FNR==1 {for (i=1; i<=NF; i++) f[$i] = i}
      NR==FNR && FNR>1 {sample_id=$(f["sample_id"]); call_rate=$(f["call_rate"]); baf_auto=$(f["baf_auto"])}
      NR==FNR && FNR>1 && (call_rate<~{call_rate_thr} || baf_auto>~{baf_auto_thr}) {xcl[sample_id]++}
      NR>FNR && FNR==1 {for (i=1; i<=NF; i++) g[$i] = i}
      NR>FNR && FNR>1 {sample_id=$(g["sample_id"]); chrom=$(g["chrom"]); beg=$(g[beg_pos]); end=$(g[end_pos]);
        len=$(g["length"]); p_arm=$(g["p_arm"]); q_arm=$(g["q_arm"]); bdev=$(g["bdev"]); rel_cov=$(g["rel_cov"]);
        lod_baf_phase=$(g["lod_baf_phase"]); type=$(g["type"]); if (lod_baf_phase=="nan") lod_baf_phase=0}
      NR>FNR && FNR>1 && !(sample_id in xcl) && rel_cov>0.5 && type!~"^CNP" &&~{if do_not_plot_sex_chromosomes
        then "\n    chrom!=\"X\" && chrom!=\"chrX\" && chrom!=\"Y\" && chrom!=\"chrY\" &&" else ""}
        ( len>5e6 + 5e6 * (p_arm!="N" && q_arm!="N") ||
          len>5e5 && (bdev<1/10 && rel_cov<2.5) && lod_baf_phase>10 ||
          rel_cov<2.1 && lod_baf_phase>10 ) {print sample_id,chrom,beg,end}' \
      "~{basename(stats_tsv)}" "~{basename(calls_tsv)}" > "~{basename(calls_tsv, ".tsv")}.coords.tsv"
    while read sample_id chrom beg_pos end_pos; do
      mocha_plot.R \
        --cytoband "~{basename(cyto_file)}" \
        --mocha \
        --stats "~{basename(stats_tsv)}" \
        --png pngs/$sample_id.${chrom}_${beg_pos}_$end_pos.png \
        --vcf "~{basename(vcf_file)}" \
        --samples $sample_id \
        --regions $chrom:$beg_pos-$end_pos \
        ~{mocha_plot_extra_args}
      echo pngs/$sample_id.${chrom}_${beg_pos}_$end_pos.png
    done < "~{basename(calls_tsv, ".tsv")}.coords.tsv"
    rm "~{basename(calls_tsv, ".tsv")}.coords.tsv"
    rm "~{basename(vcf_file)}"
    rm "~{basename(vcf_idx)}"
    rm "~{basename(calls_tsv)}"
    rm "~{basename(stats_tsv)}"
    rm "~{basename(cyto_file)}"
  >>>

  output {
    Directory pngs = "pngs"
    Array[File] png_files = read_lines(stdout())
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}

task mocha_summary {
  input {
    File calls_tsv
    File stats_tsv
    Array[File]+ ucsc_beds
    File cyto_file
    String filebase
    Float call_rate_thr = 0.97
    Float baf_auto_thr = 0.03

    String docker
    Int cpu = 1
    Int disk_size = 10
    Float memory = 3.5
    Int preemptible = 1
    Int maxRetries = 0
  }

  command <<<
    set -euo pipefail
    ucsc_files=~{write_lines(ucsc_beds)}
    mv "~{calls_tsv}" .
    mv "~{stats_tsv}" .
    mv "~{cyto_file}" .
    cat $ucsc_files | tr '\n' '\0' | xargs -0 mv -t .
    sed -i 's/^.*\///' $ucsc_files
    summary_plot.R \
      --pdf "~{filebase}.summary.pdf" \
      --stats "~{basename(stats_tsv)}" \
      --calls "~{basename(calls_tsv)}"
    awk -F "\t" 'NR==FNR && FNR==1 {for (i=1; i<=NF; i++) f[$i] = i}
      NR==FNR && FNR>1 {sample_id=$(f["sample_id"]); call_rate=$(f["call_rate"]); baf_auto=$(f["baf_auto"])}
      NR==FNR && FNR>1 && (call_rate<~{call_rate_thr} || baf_auto>~{baf_auto_thr}) {xcl[sample_id]++}
      NR>FNR && FNR==1 {for (i=1; i<=NF; i++) g[$i] = i; print}
      NR>FNR && FNR>1 {sample_id=$(g["sample_id"]); len=$(g["length"]); p_arm=$(g["p_arm"]); q_arm=$(g["q_arm"]);
        bdev=$(g["bdev"]); rel_cov=$(g["rel_cov"]); lod_baf_phase=$(g["lod_baf_phase"]); type=$(g["type"]);
        if (lod_baf_phase=="nan") lod_baf_phase=0}
      NR>FNR && FNR>1 && !(sample_id in xcl) && rel_cov>0.5 && type!~"^CNP" &&
        ( len>5e6 + 5e6 * (p_arm!="N" && q_arm!="N") ||
          len>5e5 && (bdev<1/10 && rel_cov<2.5) && lod_baf_phase>10 ||
          rel_cov<2.1 && lod_baf_phase>10 )' \
      "~{basename(stats_tsv)}" "~{basename(calls_tsv)}" > "~{basename(calls_tsv, ".tsv")}.filtered.tsv"
    pileup_plot.R \
      --cytoband "~{basename(cyto_file)}" \
      --pdf "~{filebase}.pileup.pdf" \
      --stats "~{basename(stats_tsv)}" \
      --calls "~{basename(calls_tsv, ".tsv")}.filtered.tsv"
    rm "~{basename(calls_tsv, ".tsv")}.filtered.tsv"
    cat $ucsc_files | tr '\n' '\0' | xargs -0 cat | \
      awk '{if ($0~"^track") track=$0; else bed[track]=bed[track]$0"\n"}
      END {for (track in bed) printf track"\n"bed[track]}' > "~{filebase}.ucsc.bed"
    rm "~{basename(calls_tsv)}"
    rm "~{basename(stats_tsv)}"
    rm "~{basename(cyto_file)}"
    cat $ucsc_files | tr '\n' '\0' | xargs -0 rm
  >>>

  output {
    File ucsc_bed = filebase + ".ucsc.bed"
    File summary_pdf = filebase + ".summary.pdf"
    File pileup_pdf = filebase + ".pileup.pdf"
  }

  runtime {
    docker: docker
    cpu: cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: memory + " GiB"
    preemptible: preemptible
    maxRetries: maxRetries
  }
}
