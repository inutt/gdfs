#!/usr/bin/perl

package Google::API::Drive;

use common::sense;
use Carp;
use File::Slurp;
use JSON;
use Google::DriveCache;

use base 'Google::API';

our $VERSION = "0.1";

sub new
{
	my ($class, %options) = @_;
	push @{$options{'scope'}}, 'drive';
	my $this = $class->SUPER::new(%options);

	# Get some useful data and store it
	$this->{'user_email'} = $this->request('oauth2/v2/userinfo', fields=>'email')->{'email'};
	$this->{'root_folder_id'} = $this->request('drive/v2/about', fields=>'rootFolderId')->{'rootFolderId'};

	# Set up the local cache
	$this->{'cache'} = Google::DriveCache->new(%options);

	return $this;
};

sub user_email { my $this = shift; return $this->{'user_email'}; };
sub cache { my $this = shift; return $this->{'cache'}; };

sub quota
{
	my $this = shift;
	my $unit = shift // 'b';

	my $data = $this->request('drive/v2/about',fields=>'quotaBytesTotal,quotaBytesUsed');
	my $total = $data->{'quotaBytesTotal'};
	my $used = $data->{'quotaBytesUsed'};

	# Scale to the requested unit
	my $scaling_exponent = 0;
	given ($unit)
	{
		when ('tb') { $scaling_exponent = 4; };
		when ('gb') { $scaling_exponent = 3; };
		when ('mb') { $scaling_exponent = 2; };
		when ('kb') { $scaling_exponent = 1; };
	};
	$total /= 1024**$scaling_exponent;
	$used /= 1024**$scaling_exponent;

	return ($total, $used, $total-$used);
};

sub get_metadata_for_id
{
	my $this = shift;
	my $id = shift || return undef;
	my %options = @_;

	my $metadata = $this->cache->get_metadata($id); # Get the metadata from the local cache

	if (!$options{'uncached'} && !$metadata) # If uncached version requested, or metadata isn't in the cache
	{
		# Get the metdata from Google
		$metadata = $this->request('drive/v2/files/'.$id, fields => 'id,title,mimeType,fileSize,parents,modifiedDate,lastViewedByMeDate,downloadUrl');
		# ...and cache it
		$this->cache->set_metadata($metadata);
	};

	# The API returns parents as objects, but it's easier to simplify it to just their IDs
	$metadata->{'parents'} = [ split / /,$metadata->{'parents'} ];

	return $metadata;
};

sub get_child_ids
{
	my $this = shift;
	my $parent_id = shift || return undef;

	# NB: The APIs provide a method to get the children of an object directly, but in this
	#     case, it makes more sense to find objects with the specified ID as a parent.
	#     (It'll make adding caching a lot easier later)

	# ...and now caching is added :-)
	my @child_ids = $this->cache->get_child_ids($parent_id); # Attempt to retrieve from the cache

	if (!@child_ids)
	{
		# No children in local cache, so check Google.
		#TODO: Find a way to separate "no children in cache" and "no children"
		my $children = $this->request('drive/v2/files',
										fields => 'items(id)',
										q => "'".$parent_id."' in parents"
									);
		foreach my $child (@{$children->{'items'}})
		{
			push @child_ids, $child->{'id'};
		};
	};

	return @child_ids;
};

sub path_to_id
{
	my $this = shift;
	my $pathname = shift || return undef;

	$pathname =~ s#^/?(.*)/?$#$1#; # Remove leading and trailing '/' if present
	my @path_components = split m#/#,$pathname;

	my $parent_id = $this->{'root_folder_id'};
	while (my $component = shift @path_components)
	{
		my @child_ids = $this->get_child_ids($parent_id);
		my $found = 0;
		foreach my $child_id (@child_ids)
		{
			my $child = $this->get_metadata_for_id($child_id);
			if ($child->{'title'} eq $component)
			{
				$parent_id = $child_id;
				$found = 1;
				last;
			};
		};
		return undef if !$found; # Couldn't find the path component -> FileNotFound
	};

	return $parent_id; # Found the specified path
};

sub download_url
{
	my $this = shift;
	my $id = shift || return undef;

	# NB: Download URLs are short-lived, so can't be cached locally
	#
	# Non-google native files have a downloadUrl, google native formats have an array
	# of exportLinks for the various formats they can be converted to.

	my $file = $this->get_metadata_for_id($id,uncached=>1);
	return $file->{'downloadUrl'} if $file->{'downloadUrl'}; # Normal files are easy

	# Find the correct url to obtain an exported version of a google native file
	#TODO: Check for folders since they're not downloadable
	#TODO: Implement this.
	carp "Downloading google native formats is not implemented yet (".$file->{'title'}.")";
	return undef;
};

sub get_file_contents
{
	my $this = shift;

	my $id = shift;
	my $requested_size = shift // undef;
	my $offset = shift // 0;

	#TODO: Google native formats will need handling differently.
	my $file = $this->get_metadata_for_id($id);
	$requested_size = $file->{'fileSize'} if !defined $requested_size;

	return $this->request_raw($this->download_url($id), _range_header => $offset.'-'.($offset+$requested_size));
};
