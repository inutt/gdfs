#!/usr/bin/perl

package Google::API;

use common::sense;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;
use URI::Escape;
use JSON;
use Time::HiRes qw/usleep/;
use Carp;
use Google::Auth;

our $VERSION = "0.1";

sub new
{
	my ($class, %options) = @_;

	my $this = {
		auth => Google::Auth->new(%options),
		api_base_url => 'https://www.googleapis.com/',
		lwp => LWP::UserAgent->new(),
		debug => $options{'debug'},
	};

	bless $this, $class;
	return $this;
};

sub debug:lvalue { my $this = shift; return $this->{'debug'}; };

sub request_raw
{
	my $this = shift;
	my $url = shift || return undef;
	my %params = @_;

	# Ensure we have a valid access token, one way or another.
	$this->{'auth'}->auth();

	# Assemble the query parameters (if supplied)
	$params{'prettyPrint'} = 'false'; # Disable pretty printing to reduce response size
	my @params;
	my $range_header;
	if (exists $params{'_range_header'})
	{
		# Used for partial file gets
		$range_header = $params{'_range_header'};
		delete $params{'_range_header'};
	};
	my $method = 'GET';
	if (exists $params{'_method'})
	{
		# Used for partial file gets
		$method = $params{'_method'};
		delete $params{'_method'};
	};
	# Arrange parameters into a query string
	foreach my $key (keys %params)
	{
		push @params, $key."=".uri_escape($params{$key}) if $params{$key};
	};
	$url .= "?" . join('&',@params) if @params;

	print STDERR "Requesting ".$url."\n" if $this->debug;

	# Make the request
	# TODO: Check the LWP object accepts gzip compression
	my $request = HTTP::Request->new(
		$method => $url,
		HTTP::Headers->new(Authorization => $this->{'auth'}->token_type.' '.$this->{'auth'}->access_token)
	);
	$request->header(Range => 'bytes='.$range_header) if $range_header;

	$request->header("Content-length" => 0) if $method eq 'POST';

	my $response = $this->api_request($request);

	if ($response->is_success())
	{
		return $response->decoded_content();
	}
	else
	{
		my $error = decode_json($response->decoded_content)->{'error'};
		croak "API request failed: ".$error->{'code'}." ".$error->{'message'};
	};
};

sub request
{
	my $this = shift;
	my $url = shift || return undef;
	my %params = @_;
	return decode_json $this->request_raw($this->{'api_base_url'}.$url,%params);
};

sub api_request
{
	my $this = shift;
	my $request = shift || return undef;

	my $response = $this->{'lwp'}->request($request);

	my $counter = 0;
	while (($response->code == 403 && grep({$_->{'reason'}=~/ratelimitexceeded/i} @{$response->{'error'}->{'errors'}})) || ($response->code == 500))
	{
		$counter++;
		# Rate limit exceeded, or Google internal error, so backoff and try again
		print "API Request failed, retrying (counter = $counter)\n" if $this->debug;
		usleep((2**$counter + rand(1))*1e6);
		$response = $this->{'lwp'}->request($request);
		last if $counter == 5;
	};

	return $response;
};

1;
