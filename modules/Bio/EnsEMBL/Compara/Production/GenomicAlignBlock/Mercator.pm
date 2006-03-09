#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::Production::GenomicAlignBlock::Mercator

=cut

=head1 SYNOPSIS

=cut

=head1 DESCRIPTION


=cut

=head1 CONTACT

Abel Ureta-Vidal <abel@ebi.ac.uk>

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::Production::GenomicAlignBlock::Mercator;

use strict;
use Bio::EnsEMBL::Analysis::Runnable::Mercator;
use Bio::EnsEMBL::Compara::DnaFragRegion;
use Bio::EnsEMBL::Compara::Production::DBSQL::DBAdaptor;;
use Bio::EnsEMBL::Utils::Exception;
use Time::HiRes qw(time gettimeofday tv_interval);

use Bio::EnsEMBL::Hive::Process;
our @ISA = qw(Bio::EnsEMBL::Hive::Process);


=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data for repeatmasker from the database
    Returns :   none
    Args    :   none

=cut

sub fetch_input {
  my( $self) = @_;

  #create a Compara::DBAdaptor which shares the same DBI handle
  #with $self->db (Hive DBAdaptor)
  $self->{'comparaDBA'} = Bio::EnsEMBL::Compara::Production::DBSQL::DBAdaptor->new(-DBCONN=>$self->db->dbc);

  $self->strict_map(1);

  $self->get_params($self->parameters);
  $self->get_params($self->input_id);

#  throw("Missing dna_collection_name") unless($self->dna_collection_name);

  return 1;
}

sub run
{
  my $self = shift;
  $self->dumpMercatorFiles;

  unless (defined $self->output_dir) {
    my $output_dir = $self->worker_temp_directory . "/output_dir";
    $self->output_dir($output_dir);
  }
  if (! -e $self->output_dir) {
    mkdir($self->output_dir, 0777);
  }

  my $runnable = new Bio::EnsEMBL::Analysis::Runnable::Mercator
    (-input_dir => $self->input_dir,
     -output_dir => $self->output_dir,
     -genome_names => $self->genome_db_ids,
     -analysis => $self->analysis);
  $self->{'_runnable'} = $runnable;
  $runnable->run_analysis;
#  $self->output($runnable->output);
#  rmdir($runnable->workdir) if (defined $runnable->workdir);
}

sub write_output {
  my ($self) = @_;

  my %run_ids2synteny_and_constraints;
  my $synteny_region_ids = $self->store_synteny(\%run_ids2synteny_and_constraints);
  foreach my $sr_id (@{$synteny_region_ids}) {
    my $dataflow_output_id = "synteny_region_id=>$sr_id";
    if ($self->msa_method_link_species_set_id()) {
      $dataflow_output_id .= ",method_link_species_set_id=>".
          $self->msa_method_link_species_set_id();
    }
    if ($self->tree_file()) {
      $dataflow_output_id .= ",tree_file=>'".$self->tree_file()."'";
    }
    $self->dataflow_output_id("{$dataflow_output_id}");
  }

#  if ($self->mavid_constraints) {
#    $self->store_mavid_constraints(\%run_ids2synteny_and_constraints);
#  }

  return 1;
}

sub store_synteny {
  my ($self, $run_ids2synteny_and_constraints) = @_;

  my $mlssa = $self->{'comparaDBA'}->get_MethodLinkSpeciesSetAdaptor;
  my $sra = $self->{'comparaDBA'}->get_SyntenyRegionAdaptor;
  my $dfa = $self->{'comparaDBA'}->get_DnaFragAdaptor;
  my $gdba = $self->{'comparaDBA'}->get_GenomeDBAdaptor;

  my @genome_dbs;
  foreach my $gdb_id (@{$self->genome_db_ids}) {
    my $gdb = $gdba->fetch_by_dbID($gdb_id);
    push @genome_dbs, $gdb;
  }
  my $mlss = new Bio::EnsEMBL::Compara::MethodLinkSpeciesSet
    (-method_link_type => "SYNTENY",
     -species_set => \@genome_dbs);
  $mlssa->store($mlss);
  $self->method_link_species_set($mlss);

  my $synteny_region_ids;
  my %dnafrag_hash;
  foreach my $sr (@{$self->{'_runnable'}->output}) {
    my $synteny_region = new Bio::EnsEMBL::Compara::SyntenyRegion
      (-method_link_species_set_id => $mlss->dbID);
    my $run_id;
    foreach my $dfr (@{$sr}) {
      my ($gdb_id, $seq_region_name, $start, $end, $strand);
      ($run_id, $gdb_id, $seq_region_name, $start, $end, $strand) = @{$dfr};
      next if ($seq_region_name eq 'NA' && $start eq 'NA' && $end eq 'NA' && $strand eq 'NA');
      my $dnafrag = $dnafrag_hash{$gdb_id."_".$seq_region_name};
      unless (defined $dnafrag) {
        $dnafrag = $dfa->fetch_by_GenomeDB_and_name($gdb_id, $seq_region_name);
        $dnafrag_hash{$gdb_id."_".$seq_region_name} = $dnafrag;
      }
      $strand = ($strand eq "+")?1:-1;
      my $dnafrag_region = new Bio::EnsEMBL::Compara::DnaFragRegion
        (-dnafrag_id => $dnafrag->dbID,
         -dnafrag_start => $start+1, # because half-open coordinate system
         -dnafrag_end => $end,
         -dnafrag_strand => $strand);
      $synteny_region->add_child($dnafrag_region);
    }
    $sra->store($synteny_region);
    push @{$synteny_region_ids}, $synteny_region->dbID;
    push @{$run_ids2synteny_and_constraints->{$run_id}}, $synteny_region->dbID;
    $synteny_region->release;
  }

  return $synteny_region_ids;
}

sub store_mavid_contraints {
  my ($self, $run_ids2synteny_and_constraints) = @_;
  
  my $mlssa = $self->{'comparaDBA'}->get_MethodLinkSpeciesSetAdaptor;
  my $sra = $self->{'comparaDBA'}->get_SyntenyRegionAdaptor;
  my $dfa = $self->{'comparaDBA'}->get_DnaFragAdaptor;
  my $gdba = $self->{'comparaDBA'}->get_GenomeDBAdaptor;
  my $pafa = $self->{'comparaDBA'}->get_PeptideAlignAdaptor;

  my @genome_dbs;
  foreach my $gdb_id (@{$self->genome_db_ids}) {
    my $gdb = $gdba->fetch_by_dbID($gdb_id);
    push @genome_dbs, $gdb;
  }
  my $mlss = new Bio::EnsEMBL::Compara::MethodLinkSpeciesSet
    (-method_link_type => "MAVID_CONSTRAINTS",
     -species_set => \@genome_dbs);
  $mlssa->store($mlss);

  my $pairwisehits_file = $self->output_dir . "/pairwisehits";

  open F, $pairwisehits_file ||
    throw("Can't open $pairwisehits_file\n");

  my %hash;
  while (<F>) {
    my ($run_id, $gdb_id1, $member_id1, $gdb_id2, $member_id2) = split;
    my ($paf) = sort {$b->score <=> $a->score} @{$pafa->fetch_all_by_qmember_id_hmember_id($member_id1,$member_id2)};
    # here we need to recalculate peptide coordinates to genomic coordinates....
    # and match with a hash to the corresponding synteny_region_id
    # push @{$run_ids2synteny_and_constraints}, $synteny_region->dbID;
  }
  close F;
#  my $output = [ values %hash ];
#  print "scalar output", scalar @{$output},"\n";
#  print "No synteny regions found" if (scalar @{$output} == 0);
#  $self->output($output);
}

##########################################
#
# getter/setter methods
# 
##########################################

#sub dna_collection_name {
#  my $self = shift;
#  $self->{'_dna_collection_name'} = shift if(@_);
#  return $self->{'_dna_collection_name'};
#}

sub input_dir {
  my $self = shift;
  $self->{'_input_dir'} = shift if(@_);
  return $self->{'_input_dir'};
}

sub output_dir {
  my $self = shift;
  $self->{'_output_dir'} = shift if(@_);
  return $self->{'_output_dir'};
}

sub genome_db_ids {
  my $self = shift;
  $self->{'_genome_db_ids'} = shift if(@_);
  return $self->{'_genome_db_ids'};
}

sub cutoff_score {
  my $self = shift;
  $self->{'_cutoff_score'} = shift if(@_);
  return $self->{'_cutoff_score'};
}

sub cutoff_evalue {
  my $self = shift;
  $self->{'_cutoff_evalue'} = shift if(@_);
  return $self->{'_cutoff_evalue'};
}

sub strict_map {
  my $self = shift;
  $self->{'_strict_map'} = shift if(@_);
  return $self->{'_strict_map'};
}

sub mavid_constraints {
  my $self = shift;
  $self->{'_mavid_constraints'} = shift if(@_);
  return $self->{'_mavid_constraints'};
}

sub method_link_species_set {
  my $self = shift;
  $self->{'_method_link_species_set'} = shift if(@_);
  return $self->{'_method_link_species_set'};
}

sub msa_method_link_species_set_id {
  my $self = shift;
  $self->{'_msa_method_link_species_set_id'} = shift if(@_);
  return $self->{'_msa_method_link_species_set_id'};
}

sub tree_file {
  my $self = shift;
  $self->{'_tree_file'} = shift if(@_);
  return $self->{'_tree_file'};
}

##########################################
#
# internal methods
#
##########################################

sub get_params {
  my $self         = shift;
  my $param_string = shift;

  return unless($param_string);
  print("parsing parameter string : ",$param_string,"\n");

  my $params = eval($param_string);
  return unless($params);
  if(defined($params->{'input_dir'})) {
    $self->input_dir($params->{'input_dir'});
  }
  if(defined($params->{'output_dir'})) {
    $self->input_dir($params->{'output_dir'});
  }
  if(defined($params->{'gdb_ids'})) {
    $self->genome_db_ids($params->{'gdb_ids'});
  }
  if(defined($params->{'cutoff_score'})) {
    $self->cutoff_score($params->{'cutoff_score'});
  }
  if(defined($params->{'cutoff_evalue'})) {
    $self->cutoff_evalue($params->{'cutoff_evalue'});
  }
  if(defined($params->{'strict_map'})) {
    $self->strict_map($params->{'strict_map'});
  }
  if(defined($params->{'mavid_constraints'})) {
    $self->mavid_constraints($params->{'mavid_constraints'});
  }
  if(defined($params->{'msa_method_link_species_set_id'})) {
    $self->msa_method_link_species_set_id($params->{'msa_method_link_species_set_id'});
  }
  if(defined($params->{'tree_file'})) {
    $self->tree_file($params->{'tree_file'});
  }
  return 1;
}

sub dumpMercatorFiles {
  my $self = shift;

#  $self->{'comparaDBA'}->dbc->disconnect_when_inactive(1);
  
  my $starttime = time();

  unless (defined $self->input_dir) {
    my $input_dir = $self->worker_temp_directory . "/input_dir";
    $self->input_dir($input_dir);
  }
  if (! -e $self->input_dir) {
    mkdir($self->input_dir, 0777);
  }

  my $dfa = $self->{'comparaDBA'}->get_DnaFragAdaptor;
  my $gdba = $self->{'comparaDBA'}->get_GenomeDBAdaptor;
  my $ma = $self->{'comparaDBA'}->get_MemberAdaptor;
  my $ssa = $self->{'comparaDBA'}->get_SubsetAdaptor;

  foreach my $gdb_id (@{$self->genome_db_ids}) {
    ## Create the Chromosome file for Mercator
    my $gdb = $gdba->fetch_by_dbID($gdb_id);
    my $file = $self->input_dir . "/$gdb_id.chroms";
    open F, ">$file";
    foreach my $df (@{$dfa->fetch_all_by_GenomeDB_region($gdb)}) {
      print F $df->name . "\t" . $df->length,"\n";
    }
    close F;

    ## Create the anchor file for Mercator
    my $ss = $ssa->fetch_by_set_description("gdb:".$gdb->dbID ." ". $gdb->name . ' coding exons');
    $file = $self->input_dir . "/$gdb_id.anchors";
    open F, ">$file";
    foreach my $member (@{$ma->fetch_by_subset_id($ss->dbID)}) {
      my $strand = "+";
      $strand = "-" if ($member->chr_strand == -1);
      print F $member->dbID . "\t" .
        $member->chr_name ."\t" .
          $strand . "\t" .
            ($member->chr_start - 1) ."\t" .
              $member->chr_end ."\n";
    }
    close F;
  }

  ## Use best reciprocal hits only
  my $sql = "SELECT paf1.qmember_id, paf1.hmember_id, paf1.score, paf1.evalue, paf2.score, paf2.evalue
    FROM peptide_align_feature paf1, peptide_align_feature paf2
    WHERE paf1.qgenome_db_id = ? AND paf1.hgenome_db_id = ?
      AND paf1.qmember_id = paf2.hmember_id AND paf1.hmember_id = paf2.qmember_id
      AND paf1.hit_rank = 1 AND paf2.hit_rank = 1";
  my $sth = $self->{'comparaDBA'}->dbc->prepare($sql);
  my ($qmember_id,$hmember_id,$score1,$evalue1,$score2,$evalue2);
  my @genome_db_ids = @{$self->genome_db_ids};

  while (my $gdb_id1 = shift @genome_db_ids) {
    foreach my $gdb_id2 (@genome_db_ids) {
      my $file = $self->input_dir . "/$gdb_id1" . "-$gdb_id2.hits";
      open F, ">$file";
      $sth->execute($gdb_id1, $gdb_id2);
      $sth->bind_columns( \$qmember_id,\$hmember_id,\$score1,\$evalue1,\$score2,\$evalue2);
      my %pair_seen = ();
      while ($sth->fetch()) {
        next if ($pair_seen{$qmember_id . "_" . $hmember_id});
        my $score = ($score1>$score2)?$score2:$score1; ## Use smallest score
        my $evalue = ($evalue1>$evalue2)?$evalue1:$evalue2; ## Use largest e-value
        next if (defined $self->cutoff_score && $score < $self->cutoff_score);
        next if (defined $self->cutoff_evalue && $evalue > $self->cutoff_evalue);
        print F "$qmember_id\t$hmember_id\t" . int($score). "\t$evalue\n";
        $pair_seen{$qmember_id . "_" . $hmember_id} = 1;
      }
      close F;
    }
  }

  if($self->debug){printf("%1.3f secs to dump nib for \"%s\" collection\n", (time()-$starttime), $self->collection_name);}

#  $self->{'comparaDBA'}->dbc->disconnect_when_inactive(0);

  return 1;
}





1;
