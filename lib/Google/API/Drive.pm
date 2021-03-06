#!/usr/bin/perl

package Google::API::Drive;

use common::sense;
use Carp;
use File::Slurp;
use JSON;
use IO::Scalar;
use File::MimeInfo::Magic;
use Google::DriveCache;

use base 'Google::API';

our $VERSION = "0.1";

our $file_metadata_fields = 'id,title,mimeType,fileSize,parents(id),modifiedDate,lastViewedByMeDate,downloadUrl';
our $poller_pid;

sub new
{
	my ($class, %options) = @_;
	push @{$options{'scope'}}, 'drive';
	my $this = $class->SUPER::new(%options);

	# Get some useful data and store it
	$this->{'root_folder_id'} = $this->request('drive/v2/about', fields=>'rootFolderId')->{'rootFolderId'};

	$this->{'poll_interval'} = $options{'poll_interval'} // 60, # seconds
	$this->{'label'} = $options{'label'} // undef;

	# Set up the local cache
	$this->{'cache'} = Google::DriveCache->new(%options);
	
	# Assume if we have no change ID stored, we're starting with an empty database and don't need to catch up on changes
	$this->cache->set_last_change( $this->request('drive/v2/about', fields=>'largestChangeId')->{'largestChangeId'} ) if !defined($this->cache->get_last_change());

	# Sub process for polling remote changes
	$this->fork_poller();

	return $this;
};

sub label { my $this = shift; return $this->{'label'}; };
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

	if ($options{'uncached'} || !$metadata) # If uncached version requested, or metadata isn't in the cache
	{
		# Get the metdata from Google
		$metadata = $this->request('drive/v2/files/'.$id, fields => $file_metadata_fields);
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
		my $children;
		do
		{
			$children = $this->request(
											'drive/v2/files',
											'pageToken' => $children->{'nextPageToken'},
											fields => 'items(id),nextPageToken,nextLink',
											q => "'".$parent_id."' in parents and trashed = false"
										);
			foreach my $child (@{$children->{'items'}})
			{
				push @child_ids, $child->{'id'};
			};
		} while ($children->{'nextPageToken'});
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

sub put_file_contents
{
	my $this = shift;
	my $path = shift || return undef;
	my $content = shift;

	my %metadata;

	# Ensure we have a valid access token, one way or another.
	$this->{'auth'}->auth();

	# Check if the file already exists
	my $file_id = $this->path_to_id($path);

	my @components = split m#/#,$path;
	my $filename = pop @components;
	my $path = join '/',@components;

	$metadata{'title'} = $filename;
	$metadata{'fileSize'} = length($content);

	# Detect the mime type of the content
	$metadata{'mimeType'} = mimetype(IO::Scalar->new(\$content));

	# Determine the parent ID
	my $parent_id = $this->path_to_id($path) || return undef;
	$metadata{'parents'} = [ { id => $parent_id } ];

	$metadata{'id'} = $file_id if $file_id;

	my $url = $this->{'api_base_url'}.'upload/drive/v2/files';

	my $method;
	if ($file_id)
	{
		# File exists, so we're replacing the contents
		print STDERR "Replacing file contents, " if $this->debug;
		$method = 'PUT';
		$url .= '/'.$file_id;
	}
	else
	{
		# File doesn't exist, so create a new one
		print STDERR "Creating new file, " if $this->debug;
		$method = 'POST';
	};
	$url .= '?uploadType=multipart';

	print STDERR "sending ".length($content)." bytes to ".$url."\n" if $this->debug;


	# Make the request
	# TODO: Check the LWP object accepts gzip compression
	my $request = HTTP::Request->new(
		$method => $url,
		HTTP::Headers->new(Authorization => $this->{'auth'}->token_type.' '.$this->{'auth'}->access_token),
	);
	$request->add_part(HTTP::Message->new([
				Content_Type => 'application/json'],
				encode_json(\%metadata),
			));
	$request->add_part(HTTP::Message->new([
				Content_Type => $metadata{'mimeType'}],
				$content,
			));

	my $response = $this->api_request($request);

	if (!$response->is_success())
	{
		croak "API request failed: ".decode_json($response->decoded_content)->{'error'}->{'message'};
	};

	# Cache the metadata for the new/updated file
	# (Saves a second call to get the metadata we already have, and means that newly created
	# files exist in the cache, eliminating problems with the create/setattr/write process
	# of creating a new file)
	my $metadata = decode_json $response->decoded_content;
	$this->cache->set_metadata($metadata);
	return $metadata->{'id'};
};

sub delete_file
{
	my $this = shift;
	my $path = shift || return undef;


	my $id = $this->path_to_id($path) || return undef;

	my $response = $this->request('drive/v2/files/'.$id.'/trash', _method=>'POST');
	$this->cache->del_metadata($id);
	return $response;
};

sub get_remote_changes
{
	my $this = shift;

	my $last_seen_change = $this->cache->get_last_change();

	my $changes;
	do
	{
		$changes = $this->request(
										'drive/v2/changes',
										startChangeId => $last_seen_change+1,
										'pageToken' => $changes->{'nextPageToken'},
										#fields => 'items('.$file_metadata_fields.'),nextPageToken,nextLink',
										fields => 'items(id,fileId,deleted,file('.$file_metadata_fields.',labels(trashed))),nextPageToken,nextLink',
									);
		foreach my $change (@{$changes->{'items'}})
		{
			if ($change->{'file'})    { $this->cache->set_metadata($change->{'file'});   print STDERR "Remote change ".$change->{'id'}.": metadata change for ID ".$change->{'fileId'}."\n" if $this->debug; };
			if ($change->{'file'}->{'labels'}->{'trashed'} eq "true") { $this->cache->del_metadata($change->{'fileId'}); print STDERR "Remote change ".$change->{'id'}.": ID ".$change->{'fileId'}." trashed\n" if $this->debug; };
			use Data::Dumper; print Dumper $change;

			$last_seen_change = $change->{'id'};
		};
	} while ($changes->{'nextPageToken'});

	$this->cache->set_last_change($last_seen_change);
};

sub fork_poller
{
	# Fork a separate process to poll for changes
	my $this = shift;

	$poller_pid = fork();
	die("Fork failed!") if $poller_pid < 0;

	if ($poller_pid == 0)
	{
		# This is the child (poller)
		$0 .= " [change poller]";
		while(1)
		{
			my $ppid = getppid();
			exit(0) if $ppid == 1; # Exit the polling subprocess if the parent exits and didn't tell us
#			kill 'TSTP',$ppid; # Temporarily suspend the main process to avoid the possibility of both processing updating things simultaneously
			$this->get_remote_changes();
#			kill 'CONT',$ppid; # Resume the main process
			sleep $this->{'poll_interval'};
		};
	}
	else
	{
		# Parent
#		$SIG{'CHLD'} = sub { say "received SIGCHLD"; die "Update poller died unexpectedly" if !kill(0,$poller_pid) };
	};
};

sub DESTROY
{
	# Tidy up the polling subprocess if the parent exits normally
	my $this = shift;
	if ($poller_pid)
	{
		kill('TERM',$poller_pid);
		while(wait() > -1) { sleep 1 };
	};
};

1;
