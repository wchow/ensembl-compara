

use Test;
BEGIN { plan tests => 7 }



use lib './t';
use EnsTestDB;
use Bio::EnsEMBL::Compara::DBSQL::GenomicAlignAdaptor;

use Bio::AlignIO;

ok 1;

if( ! -e '../../ensembl' ) {
   die "genomic align test requires an ensembl peer directory to locate ensembl schema"
}
    
my $ens_test = EnsTestDB->new();

$ens_test->do_sql_file("t/genomicalign.dump");

my $db = $ens_test->get_DBSQL_Obj;

ok $ens_test;

$genome_db = $db->get_GenomeDBAdaptor->fetch_by_dbID(1);

# sneaky in-memory substitution of the ensembl locator

$loc = $ens_test->ensembl_locator;
$loc =~ s/Compara:://;

$genome_db->locator($loc);


$gadp = Bio::EnsEMBL::Compara::DBSQL::GenomicAlignAdaptor->new($db);
        
ok $gadp;

my $align = $gadp->fetch_GenomicAlign_by_dbID(1);

ok $align;

$alignblockset = $align->get_AlignBlockSet(1);

($a,$alignblock) = $alignblockset->get_AlignBlocks;

$a = undef;

ok ($alignblock->start == 11 && $alignblock->end == 16 && $alignblock->align_start == 15 
	&& $alignblock->align_end == 20);

$alignout = Bio::AlignIO->new( -format => 'fasta',-file => '>t/test.aln' );
$alignout->write_aln($align);
$alignout = undef;
ok 6;

$alignin = Bio::AlignIO->new( -format => 'fasta',-file => 't/test.aln');

$aln = $alignin->next_aln();
$aln = undef;
ok 7;

