#!/usr/bin/env perl

# Small VWF::Display helpers

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::Most;

use lib File::Spec->catfile($Bin, '..', 'lib');

use VWF::Display;

subtest 'obfuscate' => sub {
	is(VWF::Display::obfuscate('a@b'), '&#97;&#64;&#98;', 'returns the entities');

	# It is called inside a concatenation, where map's count used to leak out
	my $msg = 'use ' . VWF::Display::obfuscate('a@b') . ' instead';
	is($msg, 'use &#97;&#64;&#98; instead', 'one string in scalar context');
};

subtest 'http() Retry-After' => sub {
	my $display = bless { config => { security => { csrf => { enable => 0 } } } }, 'VWF::Display';

	my $headers = $display->http({ 'Content-Type' => 'Content-Type: text/plain', 'Retry-After' => 60 });
	like($headers, qr/^Content-Type: text\/plain$/m, 'Content-Type is kept');
	like($headers, qr/^Retry-After: 60$/m, 'Retry-After header is sent');

	$headers = $display->http({ 'Content-Type' => 'Content-Type: text/plain' });
	unlike($headers, qr/Retry-After/, 'no Retry-After unless asked for');

	throws_ok { $display->http({ 'Content-Type' => 'Content-Type: text/plain', 'Retry-After' => "60\r\nSet-Cookie: x=1" }) }
		qr/Retry-After must be a number of seconds/, 'header injection is refused';
};

done_testing();
