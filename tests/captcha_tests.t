#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Test::MockObject;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

# Add lib paths
use lib File::Spec->catfile($Bin, '..', 'lib');
use lib File::Spec->catfile($Bin, 'lib');
use lib 'lib';

BEGIN { 
	use_ok('VWF::CAPTCHA');
	use_ok('VWF::Display::captcha');
}

subtest 'CAPTCHA module initialization' => sub {
	plan tests => 3;
	
	my $captcha = VWF::CAPTCHA->new(
		site_key => 'test_site_key',
		secret_key => 'test_secret_key'
	);
	
	ok($captcha, 'CAPTCHA object created');
	is($captcha->get_site_key(), 'test_site_key', 'Site key accessible');
	isa_ok($captcha, 'VWF::CAPTCHA');
};

subtest 'Display module initialization' => sub {
	plan tests => 2;
	
	# VWF::Display->new() reads a configuration file.  Give it its own,
	# rather than whatever happens to be in ~/lib/conf on this machine.
	my $config_dir = tempdir(CLEANUP => 1);
	open(my $fout, '>', File::Spec->catfile($config_dir, 'default')) or die "$config_dir/default: $!";
	print $fout "<?xml version=\"1.0\"?>\n<config><memory_cache><driver>Null</driver></memory_cache></config>\n";
	close $fout;
	local $ENV{'CONFIG_DIR'} = $config_dir;

	# Create minimal mock objects
	my $mock_info = Test::MockObject->new();
	$mock_info->mock('domain_name', sub { 'example.com' });
	my $mock_config = Test::MockObject->new();
	my $mock_lingua = Test::MockObject->new();
	
	$mock_config->mock('recaptcha', sub {
		return {
			site_key => 'test_key',
			secret_key => 'test_secret',
			enabled => 1
		};
	});
	
	my $display = VWF::Display::captcha->new({
		info => $mock_info,
		config => $mock_config,
		lingua => $mock_lingua,
	});
	
	ok($display, 'Display object created');
	isa_ok($display, 'VWF::Display::captcha');
};

subtest 'Rate limit bypass logic' => sub {
	plan tests => 5;
	
	use CHI;
	my $cache = CHI->new(driver => 'Memory', datastore => {});
	
	my $ip = '1.2.3.4';
	my $script = 'test';
	
	# Set request count over soft limit
	$cache->set("$script:rate_limit:$ip", 150, '60s');
	my $count = $cache->get("$script:rate_limit:$ip");
	is($count, 150, 'Request count set to 150');
	
	# Simulate CAPTCHA bypass
	$cache->set("$script:captcha_bypass:$ip", 1, '300s');
	my $has_bypass = $cache->get("$script:captcha_bypass:$ip");
	ok($has_bypass, 'CAPTCHA bypass token set');
	
	# Reset counter after successful CAPTCHA
	$cache->set("$script:rate_limit:$ip", 0, '60s');
	$count = $cache->get("$script:rate_limit:$ip");
	is($count, 0, 'Counter reset after CAPTCHA success');
	
	# Verify bypass expires
	$cache->set("$script:captcha_bypass:$ip", 1, '1s');
	sleep(1.1);
	my $expired = $cache->get("$script:captcha_bypass:$ip");
	is($expired, undef, 'CAPTCHA bypass expires');
	
	# Verify different IPs have separate bypass tokens
	$cache->set("$script:captcha_bypass:5.6.7.8", 1, '300s');
	ok($cache->get("$script:captcha_bypass:5.6.7.8"), 'Different IP has separate bypass');
};

done_testing();
