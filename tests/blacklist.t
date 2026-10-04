#!/usr/bin/env perl

# VWF::Blacklist: the one country blacklist used by page.fcgi (via CGI::ACL),
# VWF::Allow and VWF::Display.  Moved here from the syslogd fork's t/locales.t.

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::Most;

use lib File::Spec->catfile($Bin, '..', 'lib');

use_ok('VWF::Blacklist');

subtest 'no GeoIP needed' => sub {
	my $bl = VWF::Blacklist->new();

	ok($bl->is_blocked('CN'), 'CN blocked by default');
	ok($bl->is_blocked($_), "$_ blocked by default (was missing from VWF::Display)") foreach(qw(BY UA XH));
	ok(!$bl->is_blocked('GB'), 'GB allowed by default');
	is(scalar(@{$bl->countries()}), 18, 'built-in list has 18 countries');
	is_deeply(VWF::Blacklist->new(countries => 'ru cn')->countries(), ['CN', 'RU'], 'string list, sorted and upper-cased');
	is_deeply(VWF::Blacklist->new(countries => [])->countries(), [], 'empty list blocks nobody');
};

SKIP: {
	skip('GeoIP tests need IP::Country::Fast and CGI::ACL', 6)
		unless(eval { require IP::Country::Fast; require CGI::ACL; 1 });

	# Addresses whose country has been stable for many years.  If the bundled
	# database ever disagrees, every result below would be meaningless.
	my %KNOWN = (
		GB => '81.2.69.160',
		US => '8.8.8.8',
		FR => '193.51.224.1',
		DE => '194.25.2.129',
		CN => '202.106.0.20',
	);

	my $geo = IP::Country::Fast->new();

	# Map a country back to its known address's GeoIP result
	my $country_of = sub { return $geo->inet_atocc($KNOWN{$_[0]}) };

	subtest 'GeoIP sanity' => sub {
		foreach my $cc (sort keys %KNOWN) {
			my $got = $country_of->($cc) // 'undef';
			is($got, $cc, "$KNOWN{$cc} maps to $cc")
				or BAIL_OUT("GeoIP drift: $KNOWN{$cc} is now $got, not $cc; update %KNOWN");
		}
	};

	subtest 'default blacklist: country-based access' => sub {
		my $bl = VWF::Blacklist->new();

		foreach my $cc (qw(GB US FR DE)) {
			ok(!$bl->is_blocked($country_of->($cc)), "$cc allowed");
		}
		ok($bl->is_blocked($country_of->('CN')), 'CN blocked');
		ok(!$bl->is_blocked(undef), 'unknown country (GeoIP miss) allowed');
		ok(!$bl->is_blocked(''), 'empty country allowed');
	};

	subtest 'case-insensitivity' => sub {
		my $bl = VWF::Blacklist->new(countries => 'fr, De');

		foreach my $cc (qw(FR fr Fr DE de dE)) {
			ok($bl->is_blocked($cc), "$cc blocked");
		}
		ok(!$bl->is_blocked('gb'), 'gb allowed');
		is_deeply($bl->countries(), ['DE', 'FR'], 'stored upper-case');
	};

	subtest 'concurrent instances do not interfere' => sub {
		my $us_only = VWF::Blacklist->new(countries => ['US']);
		my $gb_cn = VWF::Blacklist->new(countries => [qw(GB CN)]);
		my $empty = VWF::Blacklist->new(countries => []);

		my %expect = (
			GB => [0, 1, 0],
			US => [1, 0, 0],
			FR => [0, 0, 0],
			DE => [0, 0, 0],
			CN => [0, 1, 0],
		);
		foreach my $cc (sort keys %expect) {
			my $country = $country_of->($cc);
			is_deeply(
				[map { $_->is_blocked($country) } ($us_only, $gb_cn, $empty)],
				$expect{$cc},
				"$cc: each instance answers from its own list",
			);
		}
	};

	subtest 'CGI::ACL integration (as page.fcgi uses it)' => sub {
		# A stand-in for CGI::Lingua, which would do the same GeoIP lookup
		{
			package StubLingua;
			sub new { return bless { country => $_[1] }, $_[0] }
			sub country { return $_[0]{country} }
		}

		my $acl = CGI::ACL->new()->deny_country(country => VWF::Blacklist->new()->countries());
		foreach my $cc (sort keys %KNOWN) {
			local $ENV{REMOTE_ADDR} = $KNOWN{$cc};
			my $denied = $acl->all_denied(lingua => StubLingua->new(lc $country_of->($cc))) ? 1 : 0;
			is($denied, ($cc eq 'CN') ? 1 : 0, "$cc " . ($denied ? 'denied' : 'allowed'));
		}
	};

	subtest 'invalid configuration is rejected' => sub {
		throws_ok { VWF::Blacklist->new(countries => ['GBR']) } qr/Invalid country code 'GBR'/, 'three letters';
		throws_ok { VWF::Blacklist->new(countries => 'C1') } qr/Invalid country code 'C1'/, 'digit';
	};
}

done_testing();
