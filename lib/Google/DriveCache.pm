#!/usr/bin/perl

package Google::DriveCache;

use common::sense;
use DBI;
use File::Slurp;

sub new
{
	my $class = shift;
	my %options = @_;

	my $this = {
		config_dir => $options{'config_dir'} // $ENV{'HOME'}.'/.gdfs',
		debug => $options{'debug'},
	};
	bless $this,$class;

#	$this->dbh = DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1});
	$this->{'dbh'} = DBI->connect('dbi:SQLite:dbname='. $this->{'config_dir'}.'/metadata.db' ,'','',{RaiseError=>1});
	$this->{'dbh'}->do("CREATE TABLE IF NOT EXISTS files(id text primary key, title text, mimeType text, fileSize int, parents text, modifiedDate int, lastViewedByMeDate int)");
	$this->{'dbh'}->do("CREATE TABLE IF NOT EXISTS lastchange(id text primary key)");

	$this->{'del_cmd'} = $this->{'dbh'}->prepare("DELETE FROM files WHERE id = ?");
	$this->{'get_cmd'} = $this->{'dbh'}->prepare("SELECT * FROM files WHERE id = ?");
	$this->{'set_cmd'} = $this->{'dbh'}->prepare("INSERT INTO files(id, title, mimeType, fileSize, parents, modifiedDate, lastViewedByMeDate) VALUES (?,?,?,?,?,?,?)");
	$this->{'get_children_cmd'} = $this->{'dbh'}->prepare("SELECT id FROM files WHERE INSTR(parents,?)");

	$this->{'get_last_change'} = $this->{'dbh'}->prepare("SELECT MAX(id) AS id FROM lastchange");
	$this->{'set_last_change'} = $this->{'dbh'}->prepare("INSERT INTO lastchange (id) VALUES (?)");
	$this->{'truncate_last_change'} = $this->{'dbh'}->prepare("DELETE FROM lastchange where id < ?");

	mkdir $this->{'config_dir'}.'/cache' or die "Can't create cache dir" if !-d $this->{'config_dir'}.'/cache';

	return $this;
};

sub del_metadata
{
	my $this = shift;
	my $id = shift || return undef;

	$this->{'del_cmd'}->execute( $id );
};

sub get_metadata
{
	my $this = shift;
	my $id = shift || return undef;

	$this->{'get_cmd'}->execute( $id );
	my $file = $this->{'get_cmd'}->fetchrow_hashref() || return undef;

	$file->{'parents'} = [ split / /,$file->{'parents'} ];
	return $file;
};

sub get_child_ids
{
	my $this = shift;
	my $parent_id = shift;

	$this->{'get_children_cmd'}->execute(" ".$parent_id." ");

	my @child_ids = ();
	while (my $child = $this->{'get_children_cmd'}->fetchrow_hashref())
	{
		push @child_ids,$child->{'id'};
	};

	return @child_ids;
};

sub set_metadata
{
	my $this = shift;
	my $options = shift;

	return unless $options->{'id'};

	my @parent_ids = ();
	foreach (@{$options->{'parents'}}) { push @parent_ids,$_->{'id'}; };

	$this->{'del_cmd'}->execute($options->{'id'});
	$this->{'set_cmd'}->execute(
		$options->{'id'},
		$options->{'title'},
		$options->{'mimeType'},
		$options->{'fileSize'},
		' '.join(' ',@parent_ids).' ', # Add a space either end, for later pattern matching
		$options->{'modifiedDate'},
		$options->{'lastViewedByMeDate'},
	);
};


sub is_cached
{
	my $this = shift;
	my $id = shift;

	return (-f $this->{'config_dir'}.'/cache/'.$id);
};

sub set_cached
{
	my $this = shift;
	my $id = shift;
	my $content = shift;

	write_file($this->{'config_dir'}.'/cache/'.$id, $content);
};

sub get_cached
{
	my $this = shift;
	my $id = shift;

	return scalar(read_file($this->{'config_dir'}.'/cache/'.$id));
};

sub del_cached
{
	my $this = shift;
	my $id = shift;

	unlink $this->{'config_dir'}.'/cache/'.$id;
};

sub keep_cached
{
	# Intended to keep the updated file in the cache if an upload fails, since the
	# process that was writing to the file doesn't see the upload and will have
	# assumed the file was written correctly
	my $this = shift;
	my $id = shift;

	rename $this->{'config_dir'}.'/cache/'.$id, $this->{'config_dir'}.'/cache/failed-'.time().'-'.$id;
};

sub get_last_change
{
	my $this = shift;

	$this->{'get_last_change'}->execute();
	return($this->{'get_last_change'}->fetchrow_hashref()->{'id'} // undef);
};

sub set_last_change
{
	my $this = shift;
	my $id = shift;

	my $existing_id = $this->get_last_change();

	if ($id > $existing_id)
	{
		$this->{'set_last_change'}->execute($id);
		$this->{'truncate_last_change'}->execute($id);
	};
};

1;
