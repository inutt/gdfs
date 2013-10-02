#!/usr/bin/perl

package Google::API;

use common::sense;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;
use JSON;
use Google::Auth;

our $VERSION = "0.1";

sub new
{
	my ($class, %options) = @_;

	my $this = {
		auth => Google::Auth->new(%options),
		api_base_url => 'https://www.googleapis.com/',
		lwp => LWP::UserAgent->new(),
	};

	bless $this, $class;
	return $this;
};

sub request
{
	my $this = shift;
	my $url = shift;
	return undef if !$url;

	# Ensure we have a valid access token, one way or another.
	$this->{'auth'}->auth();

	# Make the request
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
		print Dumper $response;
		die "API request failed: ".$response->message;
	};
};

1;
