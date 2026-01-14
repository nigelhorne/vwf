package VWF::Display::meta_data;

# Display the meta-data page - the internal status of the server and VWF system

use strict;
use warnings;

use parent 'VWF::Display';

use Date::Manip;
use System::Info;
use Filesys::Df;
use Sys::Uptime;
use Sys::MemInfo;
use Time::Piece;
use List::Util qw(max);

sub html {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $vwf_log = $args{'vwf_log'} or die "Missing 'vwf_log' handle";
	my $domain_name = $self->{'info'}->domain_name();

	# --- Browser breakdown for existing chart ---
	my $datapoints;
	foreach my $type ('web','mobile','search','robot') {
		my @entries = $vwf_log->type({ domain_name => $domain_name, type => $type });
		$datapoints .= '{y: ' . scalar(@entries) . ", label: \"$type\"},\n";
		if($self->{'logger'}) {
			$self->{'logger'}->debug("$type = " . scalar(@entries));
		}
	}

	# --- Server metrics using CPAN modules ---
	my $server_metrics = get_server_metrics();

	# --- Traffic metrics from vwf_log ---
	my $traffic_metrics = get_traffic_metrics($self, $vwf_log, $domain_name);

	return $self->SUPER::html({
		datapoints => $datapoints,
		server	 => $server_metrics,
		traffic => $traffic_metrics,
	});
}

sub get_server_metrics {
	my $metrics = {};

	# CPU info
	my $si = System::Info->new;
	$metrics->{cpu_count} = $si->ncpu // 0;
	$metrics->{cpu_type} = $si->cpu_type // '';

	# Disk usage
	my $df = df('/');
	$metrics->{disk_used_pct} = $df->{per_used} if $df;

	# Memory usage (via Sys::MemInfo)
	my $total_mem = Sys::MemInfo::totalmem();
	my $free_mem = Sys::MemInfo::freemem();
	$metrics->{memory_used_pct} = $total_mem
		? int(100 * ($total_mem - $free_mem) / $total_mem)
		: undef;

	return $metrics;
}

# ------------------------------
# Traffic metrics from vwf_log
# ------------------------------
sub get_traffic_metrics {
	my ($self, $vwf_log, $domain_name) = @_;
	my $metrics = {};

	my $now = time();
	my $hour_ago = $now - 3600;

	# Filter entries in the last hour
	my @recent = grep {
		my $epoch = UnixDate(ParseDate($_->{time}), '%s');
		$epoch && $epoch > $hour_ago;
	} $vwf_log->selectall_array({ domain_name => $domain_name });

	# Requests per hour
	$metrics->{requests_per_hour} = scalar @recent;

	# Active users (unique IPs)
	my %ips = map { $_->{ip} => 1 } @recent;
	$metrics->{active_users} = scalar keys %ips;

	# Top 5 endpoints
	my %urls;
	$urls{$_->{url}}++ for @recent;
	my @top_urls = sort { $urls{$b} <=> $urls{$a} } keys %urls;
	$metrics->{top_urls} = [ @top_urls[0..(4 > $#top_urls ? $#top_urls : 4)] ];

	# Error count (status >= 400)
	my $errors = grep { $_->{status} >= 400 } @recent;
	$metrics->{errors_last_hour} = $errors;

	return $metrics;
}

1;
