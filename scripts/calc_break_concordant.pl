#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use Getopt::Std;
use Getopt::Long;
use File::Basename;
use Cwd qw[abs_path];
use List::Util qw[min max];

use lib dirname($0);
use configdata;

my @usage;
push @usage, "Usage: ".basename($0)." [options]\n";
push @usage, "Annotate fusions\n";
push @usage, "  -h, --help      Displays this information\n";
push @usage, "  -c, --config    Configuration Filename\n";
push @usage, "  -o, --output    Output Directory\n";
push @usage, "  -b, --breaks    Breaks filename\n";

my $help;
my $config_filename;
my $output_directory;
my $breaks_filename;

GetOptions
(
	'help'        => \$help,
	'config=s'    => \$config_filename,
	'output=s'    => \$output_directory,
	'breaks=s'    => \$breaks_filename,
);

not defined $help or usage() and exit;

defined $config_filename or die @usage;
defined $output_directory or die @usage;
defined $breaks_filename or die @usage;

my $config = configdata->new();
$config->read($config_filename);

# Config values
my $cdna_gene_regions		= $config->get_value("cdna_gene_regions");
my $cdna_regions		= $config->get_value("cdna_regions");
my $gene_tran_list			= $config->get_value("gene_tran_list");
my $splice_bias             = $config->get_value("splice_bias");
my $samtools_bin			= $config->get_value("samtools_bin");

# Require concordant alignments bam
my $cdna_bam_filename = $output_directory."/cdna.pair.bam";

# Read in the read stats
my $read_stats = $output_directory."/concordant.read.stats";
my %read_stat_values;
get_stats($read_stats, \%read_stat_values);

# Approximate max fragment length
my $max_fragment_length = int($read_stat_values{"fraglength_mean"} + 3 * $read_stat_values{"fraglength_stddev"});

# Read in the gene transcripts
my %gene_transcripts;
read_gene_transcript($gene_tran_list, \%gene_transcripts);

# Read in the cdna regions
my %cdna;
read_regions($cdna_regions, \%cdna);

# Read in the cdna gene regions
my %cdna_gene;
read_regions($cdna_gene_regions, \%cdna_gene);

# Read the breakpoints file
my %breaks;
read_breaks($breaks_filename, \%breaks);

# Calculate break concordant
my %break_concordant;
calculate_break_concordant(\%breaks, \%cdna, \%cdna_gene, \%gene_transcripts, $cdna_bam_filename, $max_fragment_length, $splice_bias, \%break_concordant);

# Output
foreach my $cluster_id (keys %break_concordant)
{
	foreach my $gene (keys %{$break_concordant{$cluster_id}})
	{
		print $cluster_id."\t".$gene."\t".$break_concordant{$cluster_id}{$gene}."\n";
	}
}

sub read_breaks
{
	my $breaks_filename = shift;
	my $breaks_hash_ref = shift;
	
	open BR, $breaks_filename or die "Error: Unable to find $breaks_filename: $!\n";
	while (<BR>)
	{
		chomp;
		my @fields = split /\t/;
		
		my $cluster_id = $fields[0];
		my $reference = $fields[1];
		my $strand = $fields[2];
		my $breakpos = $fields[3];
		
		push @{$breaks_hash_ref->{$cluster_id}{breakpos}}, [$reference,$strand,$breakpos];
	}
	close BR;
}

sub read_gene_transcript
{
	my $gene_tran_filename = shift;
	my $gene_tran_ref = shift;
	
	# Read in gene transcript mapping
	open GT, $gene_tran_filename or die "Error: Unable to open $gene_tran_filename: $!\n";
	while (<GT>)
	{
		chomp;
		my @fields = split /\t/;
		
		my $ensgene = $fields[0];
		my $enstran = $fields[1];
		
		push @{$gene_tran_ref->{$ensgene}}, $enstran;
	}
	close GT;
}

sub read_regions
{
	my $regions_filename = shift;
	my $regions_hash_ref = shift;

	open REG, $regions_filename or die;
	while (<REG>)
	{
		chomp;
		my @fields = split /\t/;
		
		my $gene = $fields[0];
		my $chromosome = $fields[1];
		my $strand = $fields[2];
	
		my @exons;
		my $fieldindex = 4;
		while ($fieldindex <= $#fields)
		{
			push @exons, [$fields[$fieldindex-1],$fields[$fieldindex]];
			$fieldindex += 2;
		}
		
		$regions_hash_ref->{$gene}{chromosome} = $chromosome;
		$regions_hash_ref->{$gene}{strand} = $strand;
		$regions_hash_ref->{$gene}{exons} = [@exons];
	}
	close REG;
}

sub calculate_break_concordant
{
	my $breaks_ref = shift;
	my $cdna_ref = shift;
	my $cdna_gene_ref = shift;
	my $gene_transcripts_ref = shift;
	my $cdna_bam_filename = shift;
	my $max_fragment_length = shift;
	my $splice_bias = shift;
	my $break_concordant_ref = shift;
	
	foreach my $cluster_id (keys %{$breaks_ref})
	{
		foreach my $breakpos (@{$breaks_ref->{$cluster_id}{breakpos}})
		{
			my $reference = $breakpos->[0];
			my $strand = $breakpos->[1];
			my $breakpos = $breakpos->[2];
			
			$reference =~ /(ENSG\d+)/;
			my $gene = $1;
			
			# Find the genomic position of the break with bias
			my $breakpos_genomic;
			if ($strand eq "+")
			{
				$breakpos_genomic = calc_genomic_position($breakpos - $splice_bias, $cdna_gene_ref->{$reference}) + $splice_bias;
			}
			elsif ($strand eq "-")
			{
				$breakpos_genomic = calc_genomic_position($breakpos + $splice_bias, $cdna_gene_ref->{$reference}) - $splice_bias;
			}
			
			# Find position of break in each cdna
			# Count the number of concordant reads spanning the breakpoint
			my $concordant_count = 0;
			foreach my $transcript (@{$gene_transcripts_ref->{$gene}})
			{
				# Find position of break in cdna space
				my $breakpos_transcript = calc_transcript_position($breakpos_genomic, $cdna_ref->{$transcript});
				
				my $query_start_pos = max(1, $breakpos_transcript - $max_fragment_length);
				my $query_end_pos = $breakpos_transcript + $max_fragment_length;
				my $query_pos = $transcript.":".$query_start_pos."-".$query_end_pos;
				
				# Read in potential spanning alignments
				open TA, "$samtools_bin view $cdna_bam_filename '$query_pos' |" or die "Error: Unable to run samtools on $cdna_bam_filename: $!\n";
				my %qname_alignment;
				while (<TA>)
				{
					chomp;
					my @sam_fields = split /\t/;
					
					my $qname = $sam_fields[0];
					my $flag = $sam_fields[1];
					my $rname = $sam_fields[2];
					my $pos = $sam_fields[3];
					my $seq = $sam_fields[9];

					my $read_align_strand = ($flag & hex('0x0010')) ? "-" : "+";
					my $read_align_start = int($pos);
					my $read_align_end = int($pos + length($seq) - 1);
					
					$transcript eq $rname or die "Error: samtools retrieived alignments to $rname when alignments to $transcript were requested\n";

					$qname_alignment{$qname}{$read_align_strand} = [$read_align_start,$read_align_end];
				}
				close TA;
				
				# Count the number of concordant reads spanning the breakpoint
				foreach my $qname (keys %qname_alignment)
				{
					next unless defined $qname_alignment{$qname}{"+"} and defined $qname_alignment{$qname}{"-"};
					
					if ($qname_alignment{$qname}{"+"}->[0] < $breakpos_transcript and $qname_alignment{$qname}{"-"}->[1] > $breakpos_transcript)
					{
						$concordant_count++;
					}
				}
			}
			
			$break_concordant_ref->{$cluster_id}{$gene} = $concordant_count;
		}
	}
}

sub get_stats
{
	my $stats_filename = shift;
	my $stats_outref = shift;
	
	open STATS, $stats_filename or die "Error: Unable to open $stats_filename\n";
	my @stats = <STATS>;
	chomp(@stats);
	close STATS;

	scalar @stats == 2 or die "Error: Stats file $stats_filename does not have 2 lines\n";

	my @keys = split /\t/, $stats[0];
	my @values = split /\t/, $stats[1];

	scalar @keys == scalar @values or die "Error: Stats file $stats_filename with column mismatch\n";

	foreach my $stat_index (0..$#keys)
	{
		my $key = $keys[$stat_index];
		my $value = $values[$stat_index];

		$stats_outref->{$key} = $value;
	}
}

# Find the combined length of a set of regions
sub regions_length
{
	my @regions = @_;

	my $length = 0;
	foreach my $region (@regions)
	{
		$length += $region->[1] - $region->[0] + 1;
	}

	return $length;
}

# Merge overlapping regions
sub merge_regions
{
	my @regions = @_;
	my @merged;

	@regions = sort { $a->[0] <=> $b->[0] } (@regions);

	my $merged_start;
	my $merged_end;
	foreach my $region (@regions)
	{
		$merged_start = $region->[0] if not defined $merged_start;
		$merged_end = $region->[1] if not defined $merged_end;

		if ($region->[0] > $merged_end + 1)
		{
			push @merged, [$merged_start, $merged_end];

			$merged_start = $region->[0];
			$merged_end = $region->[1];
		}
		else
		{
			$merged_end = max($merged_end, $region->[1]);
		}
	}
	push @merged, [$merged_start, $merged_end];

	return @merged;
}

# Find position in genome given a position and the strand and exons of the transcript
sub calc_genomic_position
{
	my $position = shift;
	my $transcript_ref = shift;
	
	my $strand = $transcript_ref->{strand};
	my $exons = $transcript_ref->{exons};
	
	if ($strand eq "-")
	{
		$position = regions_length(@{$exons}) - $position + 1;
	}
	
	if ($position < 1)
	{
		return $exons->[0]->[0] + $position - 1;
	}
	
	my $local_offset = 0;
	foreach my $exon (@{$exons})
	{
		my $exonsize = $exon->[1] - $exon->[0] + 1;
			
		if ($position <= $local_offset + $exonsize)
		{
			return $position - $local_offset - 1 + $exon->[0];
		}
				
		$local_offset += $exonsize;
	}
	
	return $position - $local_offset + $exons->[$#{$exons}]->[1];
}

# Find position in a transcript given a genomic position and strand and exons of the transcript
# This version returns the position of the beginning of the next exon if the genomic position is intronic
sub calc_transcript_position
{
	my $position = shift;
	my $transcript_ref = shift;

	my $strand = $transcript_ref->{strand};
	my $exons = $transcript_ref->{exons};
	
	my $local_offset = 0;
	my $transcript_position;
	foreach my $exon (@{$exons})
	{
		my $exonsize = $exon->[1] - $exon->[0] + 1;

		if ($position <= $exon->[1])
		{
			if ($position < $exon->[0])
			{
				$transcript_position = $local_offset + 1;
				last;
			}
			else
			{
				$transcript_position = $local_offset + $position - $exon->[0] + 1;
				last;
			}
		}
				
		$local_offset += $exonsize;
	}

	$transcript_position = regions_length(@{$exons}) if not defined $transcript_position;
	
	if ($strand eq "-")
	{
		$transcript_position = regions_length(@{$exons}) - $transcript_position + 1;
	}
	
	return $transcript_position;
}


