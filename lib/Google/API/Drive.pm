#!/usr/bin/perl

package Google::API::Drive;

use common::sense;

use base 'Google::API';

our $VERSION = "0.1";

sub new
{
	my ($class, %options) = @_;
	push @{$options{'scope'}}, 'drive';
	my $this = $class->SUPER::new(%options);

	return $this;
};
