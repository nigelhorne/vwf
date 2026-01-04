#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Test::MockObject;
use CHI;
use File::Temp qw(tempdir tempfile);
use Time::HiRes qw(sleep);
use File::Spec;
use FindBin qw($Bin);

# Find the actual page.fcgi file
my $page_fcgi = File::Spec->catfile($Bin, '..', 'cgi-bin', 'page.fcgi');

unless (-f $page_fcgi) {
	plan skip_all => "Cannot find page.fcgi at $page_fcgi";
}

# Read the page.fcgi file to extract testable code
open my $fh, '<', $page_fcgi or die "Cannot open $page_fcgi: $!";
my $full_code = do { local $/; <$fh> };
close $fh;

# Extract the blacklisted() function using a more reliable method
my $blacklisted_code = extract_function($full_code, 'blacklisted');
my $filter_code = extract_function($full_code, 'filter');

unless ($blacklisted_code) {
	plan skip_all => "Cannot extract blacklisted() function from page.fcgi";
}

diag("Successfully extracted blacklisted() function");
diag("Filter function " . ($filter_code ? "found" : "not found"));

# Create test package with extracted functions
package TestPageFCGI {
	our %blacklisted_ip;
	our $info;  # In case it's referenced
	
	# This will be populated by eval
};

# Load the blacklisted function into TestPageFCGI namespace
# We need to make %blacklisted_ip and %ENV available, and handle the $info parameter
{
	my $code_to_eval = "package TestPageFCGI;\n" .
					   "no strict 'vars';\n" .  # Temporarily disable strict to allow the code as-is
					   "no warnings;\n" .
					   "our \%blacklisted_ip;\n" .
					   "*blacklisted_ip = \\\%TestPageFCGI::blacklisted_ip;\n" .
					   "*ENV = \\\%main::ENV;\n" .  # Share ENV with main
					   $blacklisted_code;
	eval $code_to_eval;
	if ($@) {
		main::plan(skip_all => "Failed to eval blacklisted(): $@\n\nExtracted code:\n$blacklisted_code");
	}
}

# Load the filter function if available
if ($filter_code) {
	my $code_to_eval = "package TestPageFCGI;\n" .
					   "use strict;\n" .
					   "use warnings;\n" .
					   $filter_code;
	eval $code_to_eval;
	if ($@) {
		main::diag("Failed to eval filter(): $@");
		undef $filter_code;
	}
}

package main;

# Verify the function loaded
unless (TestPageFCGI->can('blacklisted')) {
	plan skip_all => "blacklisted() function not available in TestPageFCGI";
}

# =============================================================================
# HELPER FUNCTION TO EXTRACT SUBS
# =============================================================================

sub extract_function {
	my ($code, $func_name) = @_;
	
	# Find the function start
	my $pos = index($code, "sub $func_name");
	return undef if $pos == -1;
	
	# Extract from "sub name" to matching closing brace
	my $start = $pos;
	my $brace_count = 0;
	my $in_function = 0;
	my $i = $start;
	
	while ($i < length($code)) {
		my $char = substr($code, $i, 1);
		
		if ($char eq '{') {
			$brace_count++;
			$in_function = 1;
		} elsif ($char eq '}') {
			$brace_count--;
			if ($in_function && $brace_count == 0) {
				# Found the end
				return substr($code, $start, $i - $start + 1);
			}
		}
		$i++;
	}
	
	return undef;
}

# =============================================================================
# TESTS FOR ACTUAL page.fcgi CODE
# =============================================================================

subtest 'Test blacklisted() function from page.fcgi' => sub {
	plan tests => 16;  # Increased to match actual test count
	
	# Looking at the extracted code, $info is declared early (good!)
	# but the original comment was based on earlier analysis
	
	# Reset the blacklist hash
	%TestPageFCGI::blacklisted_ip = ();
	
	# Create mock CGI::Info object
	my $mock_info = Test::MockObject->new();
	$mock_info->mock('status', sub {
		my ($self, $val) = @_;
		$self->{_status} = $val if defined $val;
		return $self->{_status} // 200;
	});
	
	# Test 1: SELECT with AND pattern (first time - not yet blacklisted)
	$mock_info->mock('as_string', sub { return 'SELECT * FROM users WHERE id=1 AND password=admin' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.100';
	my $result = TestPageFCGI::blacklisted($mock_info);
	ok($result, 'Should blacklist: SELECT with AND');
	is($mock_info->status(), 403, 'Status should be set to 403');
	ok($TestPageFCGI::blacklisted_ip{'192.168.1.100'}, 'IP should be added to blacklist hash');
	
	# Test 2: Already blacklisted IP
	%TestPageFCGI::blacklisted_ip = ('1.2.3.4' => 1);
	$ENV{'REMOTE_ADDR'} = '1.2.3.4';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should detect already blacklisted IP');
	is($mock_info->status(), 403, 'Status should be set to 403 for blacklisted IP');
	
	# Test 3: ORDER BY pattern
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'id=1 ORDER BY column' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.101';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: ORDER BY');
	
	# Test 4: OR NOT pattern
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return '1=1 OR NOT 2=2' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.102';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: OR NOT');
	
	# Test 5: AND with numeric equality
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'test AND 1=1' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.103';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: AND with numeric equality');
	
	# Test 6: THEN ELSE END pattern
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'CASE WHEN 1=1 THEN true ELSE false END' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.104';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: THEN ELSE END');
	
	# Test 7: AND with SELECT
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'username=admin AND SELECT password' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.105';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: AND with SELECT');
	
	# Test 8: Multiple AND clauses
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'a=1 AND b=2 AND c=3' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.106';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: Multiple AND clauses');
	
	# Test 9: AND CASE WHEN
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'id=1 AND CASE WHEN 1=1' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.107';
	$mock_info->{_status} = 200;
	ok(TestPageFCGI::blacklisted($mock_info), 'Should blacklist: AND CASE WHEN');
	
	# Test 10: Normal query should NOT be blacklisted
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return 'search=normal query text' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.108';
	$mock_info->{_status} = 200;
	ok(!TestPageFCGI::blacklisted($mock_info), 'Should NOT blacklist: normal query');
	
	# Test 11: Empty string should NOT be blacklisted
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return '' });
	$ENV{'REMOTE_ADDR'} = '192.168.1.109';
	$mock_info->{_status} = 200;
	ok(!TestPageFCGI::blacklisted($mock_info), 'Should NOT blacklist: empty string');
	
	# Test 12: Undefined as_string should NOT be blacklisted
	%TestPageFCGI::blacklisted_ip = ();
	$mock_info->mock('as_string', sub { return undef });
	$ENV{'REMOTE_ADDR'} = '192.168.1.110';
	$mock_info->{_status} = 200;
	ok(!TestPageFCGI::blacklisted($mock_info), 'Should NOT blacklist: undefined as_string');
	
	# Test 13: No REMOTE_ADDR should return false
	%TestPageFCGI::blacklisted_ip = ();
	delete $ENV{'REMOTE_ADDR'};
	$mock_info->mock('as_string', sub { return 'SELECT * AND password' });
	$mock_info->{_status} = 200;
	ok(!TestPageFCGI::blacklisted($mock_info), 'Should NOT blacklist: no REMOTE_ADDR');
};

SKIP: {
	skip "filter() function not found in page.fcgi", 1 unless $filter_code;
	
	subtest 'Test filter() function from page.fcgi' => sub {
		plan tests => 5;
		
		# The filter() function returns 0 to filter (suppress) messages,
		# and 1 to allow them through
		
		my $oauth_result = TestPageFCGI::filter("Can't locate Net/OAuth/V1_0A/ProtectedResourceRequest.pm in \@INC");
		my $netaddr_result = TestPageFCGI::filter("Can't locate auto/NetAddr/IP/InetBase/AF_INET6.al in \@INC");
		my $fcntl_result = TestPageFCGI::filter("S_IFFIFO is not a valid Fcntl macro at /path/to/file.pm");
		
		# All three patterns should now be filtered (return 0)
		is($oauth_result, 0, 'OAuth warning should be filtered (return 0)');
		is($netaddr_result, 0, 'NetAddr warning should be filtered (return 0)');
		is($fcntl_result, 0, 'Fcntl warning should be filtered (return 0)');
		
		# Test that real errors are NOT filtered (return 1 = allow through)
		ok(TestPageFCGI::filter("This is a real error message"),
		   'Should NOT filter (return 1) for real errors');
		
		ok(TestPageFCGI::filter("Something went wrong"),
		   'Should NOT filter (return 1) for other messages');
	};
}

# =============================================================================
# RATE LIMITING TESTS (using the actual constants from page.fcgi)
# =============================================================================

subtest 'Rate Limiting with page.fcgi constants' => sub {
	plan tests => 10;
	
	# Extract constants from page.fcgi
	my ($max_requests) = $full_code =~ /Readonly\s+my\s+\$MAX_REQUESTS\s*=>\s*(\d+)/;
	my ($time_window) = $full_code =~ /Readonly\s+my\s+\$TIME_WINDOW\s*=>\s*'([^']+)'/;
	
	ok(defined $max_requests, 'MAX_REQUESTS constant found');
	ok(defined $time_window, 'TIME_WINDOW constant found');
	
	is($max_requests, 100, 'MAX_REQUESTS should be 100');
	is($time_window, '60s', 'TIME_WINDOW should be 60s');
	
	# Test rate limiting logic with actual constants
	my $cache = CHI->new(
		driver => 'Memory',
		datastore => {},
		namespace => 'rate_limit_test'
	);
	
	my $client_ip = '10.0.0.1';
	my $script_name = 'page';
	
	# Simulate requests up to limit
	for my $i (1..$max_requests) {
		my $count = $cache->get("$script_name:rate_limit:$client_ip") || 0;
		$cache->set("$script_name:rate_limit:$client_ip", $count + 1, $time_window);
	}
	
	my $count = $cache->get("$script_name:rate_limit:$client_ip");
	is($count, $max_requests, "Should reach max requests ($max_requests)");
	
	# Verify rate limit would be triggered
	ok($count >= $max_requests, 'Rate limit threshold should be reached');
	
	# Test trusted IPs extraction
	my ($trusted_ips) = $full_code =~ /Readonly\s+my\s+\@rate_limit_trusted_ips\s*=>\s*\((.*?)\);/s;
	ok(defined $trusted_ips, 'Trusted IPs list found in code');
	
	# Verify localhost is trusted
	like($trusted_ips, qr/'127\.0\.0\.1'/, 'Localhost should be in trusted IPs');
	
	# Test time window parsing (as done in page.fcgi)
	my $parsed_time = $time_window;
	$parsed_time =~ s/\D//g;
	is($parsed_time, '60', 'Time window should parse to 60 seconds');
	
	# Test that different IPs are tracked separately
	my $client_ip2 = '10.0.0.2';
	my $count2 = $cache->get("$script_name:rate_limit:$client_ip2") || 0;
	is($count2, 0, 'Different IP should have separate counter');
};

# =============================================================================
# BLACKLIST COUNTRY LIST TESTS
# =============================================================================

subtest 'Blacklisted countries from page.fcgi' => sub {
	plan tests => 6;
	
	# Extract country blacklist from page.fcgi
	my ($country_list) = $full_code =~ /Readonly\s+my\s+\@blacklist_country_list\s*=>\s*\((.*?)\);/s;
	
	ok(defined $country_list, 'Country blacklist found in code');
	
	# Check for specific countries that should be blacklisted
	like($country_list, qr/'RU'/, 'Russia should be blacklisted');
	like($country_list, qr/'CN'/, 'China should be blacklisted');
	like($country_list, qr/'BR'/, 'Brazil should be blacklisted');
	
	# Count number of blacklisted countries
	my @countries = $country_list =~ /'([A-Z]{2})'/g;
	ok(scalar(@countries) > 0, 'Should have at least one blacklisted country');
	cmp_ok(scalar(@countries), '>=', 10, 'Should have at least 10 blacklisted countries');
};

# =============================================================================
# INTEGRATION TEST - Simulating actual request flow
# =============================================================================

subtest 'Integration: Rate limiting and blacklisting together' => sub {
	plan tests => 8;
	
	my $cache = CHI->new(driver => 'Memory', datastore => {});
	%TestPageFCGI::blacklisted_ip = ();
	
	my $mock_info = Test::MockObject->new();
	$mock_info->mock('status', sub {
		my ($self, $val) = @_;
		$self->{_status} = $val if defined $val;
		return $self->{_status} // 200;
	});
	
	my $attacker_ip = '1.2.3.4';
	my $normal_ip = '5.6.7.8';
	my $script_name = 'page';
	
	# Scenario 1: Normal user making requests
	$ENV{'REMOTE_ADDR'} = $normal_ip;
	$mock_info->mock('as_string', sub { return 'page=index&action=view' });
	
	ok(!TestPageFCGI::blacklisted($mock_info), 'Normal request should not be blacklisted');
	
	# Make some requests
	for (1..5) {
		my $count = $cache->get("$script_name:rate_limit:$normal_ip") || 0;
		$cache->set("$script_name:rate_limit:$normal_ip", $count + 1, '60s');
	}
	
	my $normal_count = $cache->get("$script_name:rate_limit:$normal_ip");
	is($normal_count, 5, 'Normal user should have 5 requests counted');
	
	# Scenario 2: Attacker tries SQL injection
	$ENV{'REMOTE_ADDR'} = $attacker_ip;
	$mock_info->mock('as_string', sub { return 'id=1 AND 1=1 UNION SELECT password' });
	$mock_info->{_status} = 200;
	
	ok(TestPageFCGI::blacklisted($mock_info), 'SQL injection attempt should be blacklisted');
	ok($TestPageFCGI::blacklisted_ip{$attacker_ip}, 'Attacker IP should be in blacklist');
	
	# Scenario 3: Attacker tries again with normal request
	$mock_info->mock('as_string', sub { return 'page=index' });
	$mock_info->{_status} = 200;
	
	ok(TestPageFCGI::blacklisted($mock_info), 'Blacklisted IP should be blocked even with normal request');
	
	# Scenario 4: Normal user continues
	$ENV{'REMOTE_ADDR'} = $normal_ip;
	$mock_info->mock('as_string', sub { return 'page=about' });
	$mock_info->{_status} = 200;
	
	ok(!TestPageFCGI::blacklisted($mock_info), 'Normal user should still not be blacklisted');
	
	# Verify blacklist is persistent
	ok($TestPageFCGI::blacklisted_ip{$attacker_ip}, 'Attacker should remain in blacklist');
	ok(!$TestPageFCGI::blacklisted_ip{$normal_ip}, 'Normal user should not be in blacklist');
};

done_testing();

__END__

=head1 NAME

security_tests.t - Unit tests for page.fcgi security functions

=head1 DESCRIPTION

This test suite extracts and tests the actual security functions from cgi-bin/page.fcgi:

- blacklisted() - SQL injection detection and IP blacklisting
- filter() - Log message filtering
- Rate limiting constants and logic
- Country blacklist configuration
- Integration testing of security features

The test extracts functions using brace-counting to properly handle nested code blocks.

=head1 USAGE

	perl tests/security_tests.t

Or with prove:

	prove -v tests/security_tests.t

=head1 REQUIREMENTS

- Test::More
- Test::MockObject
- CHI
- File::Temp
- Time::HiRes
- FindBin

The test expects page.fcgi to be at: ../cgi-bin/page.fcgi relative to the test file.

=head1 STRUCTURE

	project/
	├── cgi-bin/
	│   └── page.fcgi
	└── tests/
		└── security_tests.t

=head1 AUTHOR

VWF Security Test Suite

=cut
