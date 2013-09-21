package CO::NGSPipeline::Common;

##############################################################################
# provide command method for each pipeline. It is a base module for all specific
# pipelines.

use strict;
use CO::NGSPipeline::Config;
use CO::NGSPipeline::Utils;
use List::Vectorize;
use File::Basename;

sub fastqc {
	my $self = shift;
	my $pipeline = $self->{pipeline};
	
	my %param = ( "fastq" => undef,
	              "output_dir" => $pipeline->{dir},
	              @_);

	my $fastq      = to_abs_path( $param{fastq} );
	my $output_dir = to_abs_path( $param{output_dir} );

	if(! -e $output_dir) {
		$pipeline->add_command("mkdir -p $output_dir", 0);
	}
	$pipeline->add_command("fastqc -o $output_dir $fastq");

	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_fastqc",
					          "-l" => { nodes => "1:ppn=1:lsdf",
							            mem => "1GB",
							            walltime => "5:00:00"},);
	return($qid);
	
}

=item C<$self-E<gt>trim(HASH)>

Trim FALSTQ files. FASTQ file can be either gziped or not

  fastq1        path of read 1
  fastq2        path of read 2
  output1       path of output 1
  output2       path of output 2
  output_dir    dir for the trimmed data
  delete_input  whether delete input files
 
=cut
sub trim {
	my $self = shift;
	my $pipeline = $self->{pipeline};
	
	my %param = ( "fastq1" => undef,
	              "fastq2" => undef,
				  "output1" => undef,
				  "output2" => undef,
				  "polya" => 0,
				  "delete_input" => 0,
				  @_);
	
	my $fastq1  = to_abs_path( $param{fastq1} );
	my $fastq2  = to_abs_path( $param{fastq2} );
	my $output1 = to_abs_path( $param{output1} );
	my $output2 = to_abs_path( $param{output2} );
	my $polya = $param{polya};
	
	my $delete_input = $param{delete_input};
	
	$pipeline->add_command("perl $TRIMPAIR_BIN_DIR/trim.pl --fastq1=$fastq1 --fastq2=$fastq2 --output1=$output1 --output2=$output2 --tmp=$pipeline->{tmp_dir}".($polya ? " --trim-polyA" : ""));
	
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_trim",
					          "-l" => { nodes => "1:ppn=1:lsdf",
							            mem => "1GB",
							            walltime => "20:00:00"},);
	return($qid);
}

=item C<$self-E<gt>sort_sam(HASH)>

Sort SAM or BAM files

  same          sam file or bam file
  output        path of output
  delete_input  whether delete input files
 
=cut
sub sort_sam {
	my $self = shift;
	
	my %param = ( "sam" => undef,
				  "output" => undef,
				  "delete_input" => 0,
				  "sort_by" => "coordinate",
				  "add_index" => 0,
				  @_);
	
	my $sam    = to_abs_path( $param{sam} );
	my $output = to_abs_path( $param{output} );
	my $delete_input = $param{delete_input};
	my $sort_by = $param{sort_by};
	my $add_index = $param{add_index};
	
	my $pipeline = $self->{pipeline};
	
	$pipeline->add_command("JAVA_OPTIONS=-Xmx16G picard.sh SortSam INPUT=$sam OUTPUT=$output SORT_ORDER=$sort_by TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
	if($output =~/\.bam$/ and $add_index) {
		$pipeline->add_command("samtools index $output");
	}
	$pipeline->check_filesize($output);
	$pipeline->del_file($sam) if($delete_input);
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_sort_sam",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "16GB",
										walltime => "20:00:00"});
	return($qid);
}

=item C<$self-E<gt>samtools_view(HASH)>

convert between SAM and BAM

  input         path of input
  output        path of output
  delete_input  whether delete input files
 
=cut
sub samtools_view {
	my $self = shift;
	
	my %param = ( "input" => undef,
				  "output" => undef,
				  "delete_input" => 0,
				  @_);
	
	my $input    = to_abs_path( $param{input} );
	my $output = to_abs_path( $param{output} );
	my $delete_input = $param{delete_input};
	
	my $pipeline = $self->{pipeline};
	
	if($input =~/\.sam$/ and $output =~/\.bam/) {
		$pipeline->add_command("samtools view -Sbh $input -o $output");
	} elsif($input =~/\.bam$/ and $output =~/\.sam/) {
		$pipeline->add_command("samtools view -h $input -o $output");
	} else {
		die "Wrong extended file name.\n";
	}
	
	
	$pipeline->del_file($input) if($delete_input);
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_samtools_view",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "10GB",
										walltime => "20:00:00"});
	return($qid);

}

=item C<$self-E<gt>merge_nodup(HASH)>

Merge and remove duplications from SAM/BAM files

  sam_list      list of SAM/BAM files, array reference
  output        path of output
  same_library  whether these multiple lanes from same library
  delete_input  whether delete input files
 
=cut
sub merge_nodup {
	my $self = shift;
	
	my %param = ( "sam_list" => [],
	               "output" => undef,
				   "library" => undef,
				   "delete_input" => 0,
				   "sort_by" => "coordinate",
				   @_);
	
	
	my $sam_list = $param{sam_list};
	$sam_list = sapply($sam_list, \&to_abs_path);
	my $output = to_abs_path( $param{output} );
	my $library = $param{library}; $library = defined($library) ? $library : rep(1, len($sam_list));
	my $delete_input = $param{delete_input};
	my $sort_by = $param{sort_by};
	
	$sam_list->[0] =~/\.(sam|bam)$/i;
	my $suffix = $1;
	
	my $pipeline = $self->{pipeline};
	
	if(scalar(@$sam_list) == 1) {
		my $sam_file;
		my $sam_sort_file;
		my $sam_nodup_file;
		my $sam_nodup_metric_file;
	
		$sam_file = $sam_list->[0];
		$sam_nodup_file = $output;
		$sam_nodup_metric_file = $output; $sam_nodup_metric_file =~s/\.(sam|bam)$/.mkdup.metrics/;
		$pipeline->add_command("JAVA_OPTIONS=-Xmx50G picard.sh MarkDuplicates INPUT=$sam_file OUTPUT=$output METRICS_FILE=$sam_nodup_metric_file TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT REMOVE_DUPLICATES=TRUE ASSUME_SORTED=TRUE CREATE_INDEX=TRUE MAX_RECORDS_IN_RAM=50000000");
		$pipeline->del_file($sam_file) if($delete_input);
		$pipeline->del_file("$sam_file.bai") if($delete_input);
	} else {
		# merge and remove duplicate in each library
		my $sam_nodup_file = tapply([0..$#$library], $library, sub {
			my @index = @_;
			my $library_subset_name = subset($library, \@index);
			$library_subset_name = $library_subset_name->[0];
			my $library_bam = [];
			
			my $sam_file;
			my $sam_sort_file;
			my $sam_nodup_file;
			my $sam_nodup_metric_file;
			
			if(scalar(@index) == 1) {
				$sam_file = $sam_list->[ $index[0] ];
				$sam_nodup_file = "$output";
				$sam_nodup_file =~s/\.(sam|bam)$/.$library_subset_name.$1/;
				$sam_nodup_metric_file = $sam_nodup_file; $sam_nodup_metric_file =~s/\.(sam|bam)$/.mkdup.metrics/;
				$pipeline->add_command("JAVA_OPTIONS=-Xmx50G picard.sh MarkDuplicates INPUT=$sam_file OUTPUT=$sam_nodup_file METRICS_FILE=$sam_nodup_metric_file TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT REMOVE_DUPLICATES=TRUE ASSUME_SORTED=TRUE CREATE_INDEX=TRUE MAX_RECORDS_IN_RAM=50000000");
				$pipeline->del_file($sam_file) if($delete_input);
				$pipeline->del_file("$sam_file.bai") if($delete_input);
				
			} else {
				my $input_str;
				for(my $i = 0; $i < scalar(@index); $i ++) {
					$input_str .= "INPUT=$sam_list->[ $index[$i] ] ";
				}
				$sam_sort_file = dirname($sam_list->[0])."/_tmp_$library_subset_name.".int(rand(999999)).".$suffix";
				$pipeline->add_command("JAVA_OPTIONS=-Xmx16G picard.sh MergeSamFiles $input_str OUTPUT=$sam_sort_file SORT_ORDER=$sort_by TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
				$sam_nodup_file = "$output";
				$sam_nodup_file =~s/\.(sam|bam)$/.$library_subset_name.$1/;
				$sam_nodup_metric_file = $sam_nodup_file; $sam_nodup_metric_file =~s/\.(sam|bam)$/.mkdup.metrics/;
				$pipeline->add_command("JAVA_OPTIONS=-Xmx50G picard.sh MarkDuplicates INPUT=$sam_sort_file OUTPUT=$sam_nodup_file METRICS_FILE=$sam_nodup_metric_file TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT REMOVE_DUPLICATES=TRUE ASSUME_SORTED=TRUE CREATE_INDEX=TRUE MAX_RECORDS_IN_RAM=50000000");
				for(my $i = 0; $i < scalar(@$sam_list); $i ++) {
					$pipeline->del_file($sam_list->[$i]) if($delete_input);
					$pipeline->del_file("$sam_list->[$i].bai") if($delete_input);
				}
				$pipeline->del_file("$sam_sort_file");
			}
			
			return $sam_nodup_file;
		});
		$sam_nodup_file = [values %$sam_nodup_file];
		
		# finally merge samples from different libraries
		if(len($sam_nodup_file) == 1) {
			$pipeline->add_command("mv $sam_nodup_file->[0] $output", 0);
			my $sam_nodup_metric_file = $sam_nodup_file->[0]; $sam_nodup_metric_file =~s/\.(sam|bam)$/.mkdup.metrics/;
			my $output_metric_file = $output; $output_metric_file =~s/\.(sam|bam)$/.mkdup.metrics/;
			$pipeline->add_command("mv $sam_nodup_metric_file $output_metric_file", 0);
			my $sam_nodup_file_bai = $sam_nodup_file->[0]; $sam_nodup_file_bai=~s/\.bam/.bai/;
			my $output_bai = $output; $output_bai =~s/\.bam/.bai/;
			$pipeline->add_command("mv $sam_nodup_file_bai $output_bai", 0);
		} else {
			my $input_str;
			for(my $i = 0; $i < scalar(@$sam_nodup_file); $i ++) {
				$input_str .= "INPUT=$sam_nodup_file->[$i] ";
			}
			$pipeline->add_command("JAVA_OPTIONS=-Xmx16G picard.sh MergeSamFiles $input_str OUTPUT=$output SORT_ORDER=$sort_by TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
			$pipeline->add_command("samtools index $output");
			for(my $i = 0; $i < scalar(@$sam_nodup_file); $i ++) {
				$pipeline->del_file($sam_nodup_file->[$i]);
				my $bai = $sam_nodup_file->[$i]; $bai =~s/\.bam/.bai/;
				$pipeline->del_file($bai);
			}
		}
	}
	$pipeline->check_filesize($output);
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_merge_nodup",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "55GB",
										walltime => "100:00:00"});

	return($qid);
}

=item C<$self-E<gt>bwa_aln(HASH)>

bwa alignment

  fastq         fastq file
  genome        genome
  output        output file
  delete_input  whether delete input files
 
=cut
sub bwa_aln {
	my $self = shift;
	
	my %param = ( "fastq" => undef,
	              "genome" => undef,
				  "output" => undef,
				  "delete_input" => 0,
				  "use_convey" => 0,
				  @_);
	
	my $fastq = to_abs_path($param{fastq});
	my $genome = to_abs_path($param{genome});
	my $output = to_abs_path($param{output});
	my $delete_input = $param{delete_input};
	my $use_convey = $param{use_convey};
	
	my $pipeline = $self->{pipeline};
	
	if($use_convey) {
		$pipeline->add_command("$CNYBWA aln -t 12 -q 20 $genome $fastq > $output");
		$pipeline->del_file($fastq) if($delete_input);
		$pipeline->check_filesize($output); # 1M
		my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_bwa_align",
								"-l" => { nodes => "1:ppn=12:lsdf", 
											mem => "10GB",
											walltime => "150:00:00"},
								"-q" => "convey",
								"-S" => "/bin/bash");

		return($qid);
	} else {
		$pipeline->add_command("$BWA aln -t 8 -q 20 $genome $fastq > $output");
		$pipeline->del_file($fastq) if($delete_input);
		$pipeline->check_filesize($output); # 1M
		my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_bwa_align",
								"-l" => { nodes => "1:ppn=8:lsdf", 
											mem => "10GB",
											walltime => "150:00:00"},
								);
		return($qid);
	}
}


=item C<$self-E<gt>sampe(HASH)>

bwa pair-end

  aln1          alignment for read 1
  aln2          alignment for read 2
  fastq1        path of read 1
  fastq2        path of read 2
  genome        genome
  output        output
  delete_input  whether delete input files
 
=cut
sub sampe {
	my $self = shift;
	
	my %param = ( "aln1" => undef,
	              "aln2" => undef,
	              "fastq1" => undef,
	              "fastq2" => undef,
	              "genome" => undef,
				  "output" => undef,
				  "delete_input" => 0,
				  @_);
	
	my $aln1 = to_abs_path($param{aln1});
	my $aln2 = to_abs_path($param{aln2});
	my $fastq1 = to_abs_path($param{fastq1});
	my $fastq2 = to_abs_path($param{fastq2});
	my $genome = to_abs_path($param{genome});
	my $output = to_abs_path($param{output});
	my $delete_input = $param{delete_input};
	
	my $pipeline = $self->{pipeline};
	
	$pipeline->add_command("$BWA sampe $genome $aln1 $aln2 $fastq1 $fastq2 | samtools view -hbS - > $output");
	$pipeline->del_file($aln1, $aln2, $fastq1, $fastq2) if($delete_input);
	$pipeline->check_filesize($output); # 1M
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_sampe",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "10GB",
										walltime => "150:00:00"});

	return($qid);
}


sub merge_sam {
	my $self = shift;
	
	my %param = ( "sam_list" => [],
	               "output" => undef,
				   "delete_input" => 0,
				   @_);
	
	my $sam_list = $param{sam_list};
	$sam_list = sapply($sam_list, \&to_abs_path);
	my $output = to_abs_path( $param{output} );
	my $delete_input = $param{delete_input};
	
	my $pipeline = $self->{pipeline};
	
	my $input_str;
	for(my $i = 0; $i < scalar(@$sam_list); $i ++) {
		$input_str .= "INPUT=$sam_list->[$i] ";
	}

	$pipeline->add_command("JAVA_OPTIONS=-Xmx16G picard.sh MergeSamFiles $input_str OUTPUT=$output SORT_ORDER=coordinate TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
	for(my $i = 0; $i < scalar(@$sam_list); $i ++) {
		$pipeline->del_file($sam_list->[$i]) if($delete_input);
	}
	
	$pipeline->check_filesize($output); # 1M
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_merge_sam",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "20GB",
										walltime => "100:00:00"});

	return($qid);
}


sub samtools_flagstat {
	my $self = shift;
	
	my %param = ( "sam" => undef,
				  "output" => undef,
				  @_);
	
	my $sam    = to_abs_path( $param{sam} );
	my $output = to_abs_path( $param{output} );
	my $delete_input = $param{delete_input};
	
	my $pipeline = $self->{pipeline};
	
	$pipeline->add_command("samtools flagstat $sam > $output");
	
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_flagstat",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "10GB",
										walltime => "5:00:00"});
	return($qid);
}

sub picard_metrics {
	my $self = shift;
	
	my %param = ( "sam" => undef,
				"genome" => undef,
				  @_);
	
	my $sam    = to_abs_path( $param{sam} );
	my $genome    = to_abs_path( $param{genome} );
	my $output_aln = $sam.".aln.metrics";
	my $output_gcbias = $sam.".gcbias.metrics";
	my $output_insertsize = $sam.".insertsiz.metrics";
	
	my $pipeline = $self->{pipeline};
	
	$pipeline->add_command("JAVA_OPTIONS=-Xmx10G picard.sh CollectAlignmentSummaryMetrics IS_BISULFITE_SEQUENCED=true INPUT=$sam OUTPUT=$output_aln REFERENCE_SEQUENCE=$genome TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
	$pipeline->add_command("JAVA_OPTIONS=-Xmx10G picard.sh CollectGcBiasMetrics REFERENCE_SEQUENCE=$genome INPUT=$sam OUTPUT=$output_gcbias CHART_OUTPUT=$output_gcbias.pdf IS_BISULFITE_SEQUENCED=true TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");
	$pipeline->add_command("JAVA_OPTIONS=-Xmx10G picard.sh CollectInsertSizeMetrics HISTOGRAM_FILE=$output_insertsize.pdf INPUT=$sam OUTPUT=$output_insertsize REFERENCE_SEQUENCE=$genome TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");

	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_picard_metrics",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "10GB",
										walltime => "10:00:00"});
	return($qid);
}


sub picard_insertsize {
	my $self = shift;
	
	my %param = ( "sam" => undef,
				  @_);
	
	my $sam    = to_abs_path( $param{sam} );
	my $output_insertsize = $sam.".insertsiz.metrics";
	
	my $pipeline = $self->{pipeline};
	
	$pipeline->add_command("JAVA_OPTIONS=-Xmx10G picard.sh CollectInsertSizeMetrics HISTOGRAM_FILE=$output_insertsize.pdf INPUT=$sam OUTPUT=$output_insertsize TMP_DIR=$pipeline->{tmp_dir} VALIDATION_STRINGENCY=SILENT");

	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_common_picard_metrics",
							 "-l" => { nodes => "1:ppn=1:lsdf", 
									    mem => "2GB",
										walltime => "2:00:00"});
	return($qid);
}


1;