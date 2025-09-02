package VWF::Display::meta_data;

use strict;
use warnings;

# Display the meta-data page - the internal status of the server and VWF system

use parent 'VWF::Display';

sub html
{
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $vwf_log = $args{'vwf_log'} or die "Missing 'vwf_log' handle";
	my $domain_name = $self->{'info'}->domain_name();

	my $datapoints;
	foreach my $type('web', 'mobile', 'search', 'robot') {
		my @entries = $vwf_log->type({ domain_name => $domain_name, type => $type });
		$datapoints .= '{y: ' . scalar(@entries) . ", label: \"$type\"},\n";
		if($self->{'logger'}) {
			$self->{'logger'}->debug("$type = " . scalar(@entries));
		}
	}

	return $self->SUPER::html({ datapoints => $datapoints });
}

1;
