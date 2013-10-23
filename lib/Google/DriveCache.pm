#!/usr/bin/perl

package Google::DriveCache;

use common::sense;
use DBI;

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

	$this->{'del_cmd'} = $this->{'dbh'}->prepare("DELETE FROM files WHERE id = ?");
	$this->{'get_cmd'} = $this->{'dbh'}->prepare("SELECT * FROM files WHERE id = ?");
	$this->{'set_cmd'} = $this->{'dbh'}->prepare("INSERT INTO files(id, title, mimeType, fileSize, parents, modifiedDate, lastViewedByMeDate) VALUES (?,?,?,?,?,?,?)");
	$this->{'get_children_cmd'} = $this->{'dbh'}->prepare("SELECT id FROM files WHERE INSTR(parents,?)");

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

1;
