#!/usr/bin/perl

package Google::Auth;

our $VERSION = "0.1";

use common::sense;
use File::Slurp;
use JSON;
use LWP::UserAgent;
use URI::Escape;
use File::Basename;

# Client identification tokens from the Google API console
my $client = {
	id => "1002753445009.apps.googleusercontent.com",
	secret => "WL4RwO8z8YvHzgPTbOVGVwbs",
};

my @fields = qw/access_token token_type client_id client_secret expires_at refresh_token/;

sub new
{
	my $class = shift;
	my %options = @_; # $config_file, @scope

	my $scope_base_url = 'https://www.googleapis.com/auth/';

	foreach (@{$options{'scope'}}) { $_ = $scope_base_url.$_; };

	my $this = {
		config_dir => $options{'config_dir'} // $ENV{'HOME'}."/.gdfs",
		cfg => {},
		scopes => $options{'scope'},
	};
	bless $this,$class;

	# Check the config dir exists, and create it if not
	mkdir $this->{'config_dir'} or die "Can't create config dir at ".$this->{'config_dir'} if !-d $this->{'config_dir'};
	chmod 0700, $this->{'config_dir'};

	foreach (@fields) { $this->{'cfg'}->{$_} = undef; };

	$this->load_config() if -r $this->{'config_dir'}."/auth";
	$this->client_id = $client->{'id'} if !defined $this->client_id;
	$this->client_secret = $client->{'secret'} if !defined $this->client_secret;
	$this->save_config() if !-f $this->{'config_dir'}."/auth";
	return $this;
};


# Config file interaction stuff

sub load_config
{
	my $this = shift;
	$this->{'cfg'} = 
	decode_json(
		scalar read_file($this->{'config_dir'}."/auth")
	);
};

sub save_config
{
	my $this = shift;
	# Should probably use encode_json() here to handle UTG-8 properly, but that doesn't support pretty printing without using it in OO-form
	write_file( $this->{'config_dir'}."/auth", to_json($this->{'cfg'},{pretty=>1}) );
	chmod 0600, $this->{'config_dir'}."/auth";
};

# Clever auto-attributes, adapted from http://www.perlmonks.org/?node_id=806486 and lvalue stuff from elsewhere that I forgot the link for
foreach (@fields)
{
	my $attribute = $_;
	*{__PACKAGE__.'::'.$attribute} = sub :lvalue {
		my $this = shift;
		$this->{'cfg'}->{$attribute};
	};
};


# Google authorization API interaction stuff

sub auth
{
	# General auth function - do whatever is necessary to make a valid access token available
	my $this = shift;

	if (defined($this->access_token) && !$this->token_expired())
	{
		# Valid token available, nothing to do
	}
	elsif (defined($this->refresh_token))
	{
		# Access token not available or expired, but refresh token available -> refresh the access token
		$this->refresh_access_token();
	}
	else
	{
		# No valid access token or refresh token -> do initial authorisation stuff
		$this->get_initial_tokens();
	};
};

sub get_initial_tokens
{
	my $this = shift;

	my $auth_url = "https://accounts.google.com/o/oauth2/auth";
	my %auth_params = (
		response_type => 'code',
		client_id => '1002753445009.apps.googleusercontent.com',
		redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
		access_type => 'offline',
		scope => join(" ",@{$this->{'scopes'}}),
	);

	my @params;
	foreach (keys %auth_params)
	{
		my $param = $_."=".uri_escape($auth_params{$_});
		push @params,$param;
	};
	my $auth_param_string = join '&',@params;

	print "Please open the following URL in a web browser to grant access to your Google account. Once done, please copy and paste the code it provides into this terminal:\n\n";
	print $auth_url."?".$auth_param_string."\n";
	print "\n";
	print "Access code: ";
	my $code = <STDIN>;
	print "\n";

	#print "Got code $code\n";

	# Exchange the initial auth code for an access and refresh token
	my $lwp = LWP::UserAgent->new();
	my $response = $lwp->post(
		'https://accounts.google.com/o/oauth2/token',
		Content => {
			code => $code,
			client_id => $this->client_id,
			client_secret => $this->client_secret,
			redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
			grant_type => 'authorization_code',
		},
	);

	if( !$response->is_success() )
	{
		my $error_msg = decode_json($response->decoded_content())->{'error'};
		die "Couldn't get auth token: ".$error_msg;
	};

	# Store the token data
	my $auth_tokens = decode_json($response->decoded_content);
	$this->access_token = $auth_tokens->{'access_token'};
	$this->token_type = $auth_tokens->{'token_type'};
	$this->refresh_token = $auth_tokens->{'refresh_token'};
	$this->expires_at = $auth_tokens->{'expires_in'} + time();

	$this->save_config();
};

sub refresh_access_token
{
	my $this = shift;

	my $lwp = LWP::UserAgent->new();

	# Use the refresh token to get a new access token
	my $response = $lwp->post(
		'https://accounts.google.com/o/oauth2/token',
		Content => {
			refresh_token => $this->refresh_token,
			client_id => $this->client_id,
			client_secret => $this->client_secret,
			grant_type => 'refresh_token',
		},
	);

	die "Couldn't refresh auth token: ".$response->message if !$response->is_success();

	# Store the token data
	my $auth_tokens = decode_json($response->decoded_content);
	$this->access_token = $auth_tokens->{'access_token'};
	$this->token_type = $auth_tokens->{'token_type'};
	$this->expires_at = $auth_tokens->{'expires_in'} + time();

	$this->save_config();
};

sub revoke_tokens
{
	my $this = shift;

	my $lwp = LWP::UserAgent->new();
	my $response = $lwp->post(
		'https://accounts.google.com/o/oauth2/revoke',
		Content => { token => $this->refresh_token },
	);

	if ($response->is_success())
	{
		# Token revoked successfully
		$this->access_token = undef;
		$this->refresh_token = undef;
		$this->expires_at = undef;
		$this->token_type = undef;
		
		$this->save_config;
		return 1;
	}
	else
	{
		# Token revocation failed for some reason
		return 0;
	};
};

sub token_expired
{
	my $this = shift;

	my $time_remaining = $this->expires_at - time();
	return 1 if $time_remaining < 300;
	return 0;
};

1;
