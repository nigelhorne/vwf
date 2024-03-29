package VWF::Display::upload;

use warnings;
use strict;

use VWF::Display;

our @ISA = ('VWF::Display');

sub html {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $info = $self->{_info};
	my $allow = {
		'page' => 'upload',
		'action' => 'publish',	# TODO: regex of allowable name formats
		'title' => undef,
		'contents' => undef,
		'lang' => qr/^[A-Z][A-Z]/i,
		'lint_content' => qr/^\d$/,
	};
	my %params = %{$info->params({ allow => $allow })};

	delete $params{'page'};
	delete $params{'lang'};
	delete $params{'lint_content'};

	unless(scalar(keys %params)) {
		# Display a blank editor page
		return $self->SUPER::html();
	}

	open(my $fout, '>>', '/tmp/NJH');

	use Data::Dumper;

	print $fout Data::Dumper->new([\%params])->Dump();

	return $self->SUPER::html({ published => 1 });
}

1;
