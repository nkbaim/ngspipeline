package CO::NGSPipeline::RNAseq::GSNAP;

use strict;
use CO::NGSPipeline::RNAseq::Config;
use CO::NGSPipeline::Utils;

use base qw(CO::NGSPipeline::RNAseq::Common
            CO::NGSPipeline::Common);

sub new {
	my $class = shift;
	$class = ref($class) ? ref($class) : $class;
	
	my $pipeline = shift;
	
	my $self = {"pipeline" => $pipeline};
	
	return bless $self, $class;
}

sub align {
	my $self = shift;
	
	my %param = ( "fastq1" => undef,
	              "fastq2" => undef,
				  "output" => undef,
				  "sample_id" => "sample",
				  "delete_input" => 0,
				  "strand" => 0,
				  @_);
	
	my $fastq1 = to_abs_path($param{fastq1});
	my $fastq2 = to_abs_path($param{fastq2});
	my $output = to_abs_path($param{output});
	my $delete_input = $param{delete_input};
	my $sample_id = $param{sample_id};
	my $strand = $param{strand};
	
	unless($outptu =~/\.bam$/) {
		die "Only permit outputting bam file in GSNAP alignment.\n";
	}
	
	my $pipeline = $self->{pipeline};
	
	# which value should be set to -B to ensure maximum memory usage under 90G
	$pipeline->add_command("gsnap -D $GSNAP_GENOME_DIR -d $GSNAP_GENOME --nthreads=16 -B 5 -s $GSNAP_IIT -n 2 -Q --nofails --format=sam --gunzip $fastq1 $fastq2 | mbuffer -q -m 2G -l /dev/null | samtools view -uSbh - | mbuffer -q -m 2G -l /dev/null | samtools sort - $pipeline->{dir}/tmp_$sample_id");

	$pipeline->add_command("mv $pipeline->{dir}/tmp_$sample_id.bam $output", 0);
	$pipeline->check_filesize("$output");
	my $qid = $pipeline->run("-N" => $pipeline->get_job_name ? $pipeline->get_job_name : "_gsnap_align",
							 "-l" => { nodes => "1:ppn=16:lsdf", 
									    mem => "20GB",
										walltime => "300:00:00"});

	return($qid);

}

1;