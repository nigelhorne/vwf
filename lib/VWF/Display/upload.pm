package VWF::Display::upload;

use warnings;
use strict;

use VWF::Display;

our @ISA = ('VWF::Display');

sub html {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $info = $self->{_info};
	die 'Missing _info in object' unless $info;

	# Define allowed parameters (use state to avoid redeclaring in subsequent calls)
	# state $allowed = {
	my $allow = {
		'page' => 'upload',
		'action' => 'publish',	# TODO: regex of allowable name formats
		'title' => undef,
		'contents' => undef,
		'lang' => qr/^[A-Z]{2}$/i,
		'lint_content' => qr/^\d$/,
	};

	my $params = $info->params({ allow => $allow });

	if(!defined($params)) {
		# No parameters to process: display the main upload page
		return $self->SUPER::html();
	}

	# Parameters to exclude from further processing
	# my @exclude_keys = qw(page lint_content lang fbclid gclid);
	# delete @params{@exclude_keys};
	delete $params->{'page'};
	delete $params->{'lang'};
	delete $params->{'lint_content'};
	delete $params->{'fbclid'};
	delete $params->{'gclid'};

	if(scalar(keys %{$params}) == 0) {
		# Display a blank editor page
		return $self->SUPER::html();
	}

	open(my $fout, '>>', '/tmp/NJH');

	use Data::Dumper;

	print $fout Data::Dumper->new([\$params])->Dump();

	close $fout;

	return $self->SUPER::html({ published => 1 });
}

1;
