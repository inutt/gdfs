#!/usr/bin/perl

package Google::API;

use common::sense;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;
use URI::Escape;
use JSON;
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

sub request
{
	my $this = shift;
	my $url = shift || return undef;
	my %params = @_;

	# Ensure we have a valid access token, one way or another.
	$this->{'auth'}->auth();

	# Assemble the query parameters (if supplied)
	$params{'prettyPrint'} = 'false'; # Disable pretty printing to reduce response size
	my @params;
	foreach my $key (keys %params)
	{
		push @params, $key."=".uri_escape($params{$key});
	};
	$url .= "?" . join('&',@params) if @params;

	print STDERR "Requesting ".$this->{'api_base_url'}.$url."\n" if $this->debug;

	# Make the request
	# TODO: Check the LWP object accepts gzip compression
	my $request = HTTP::Request->new(
		GET => $this->{'api_base_url'}.$url,
		HTTP::Headers->new(Authorization => $this->{'auth'}->token_type.' '.$this->{'auth'}->access_token)
	);

	my $response = $this->{'lwp'}->request($request);

	if ($response->is_success())
	{
		return decode_json $response->decoded_content();
	}
	else
	{
		croak "API request failed: ".decode_json($response->decoded_content)->{'error'}->{'message'};
	};
};

1;
