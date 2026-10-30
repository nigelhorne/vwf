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

subtest 'a CSRF token is only sent to a page with a form' => sub {
	my $send = sub {
		my ($csrf, $page) = @_;

		my $display = bless { config => { security => { csrf => $csrf } } }, 'VWF::Display';
		my $out = '';
		open(my $fh, '>', \$out) or die "Can't open a string: $!";
		my $old = select($fh);
		$display->_send_csrf_token($page);
		select($old);
		close($fh);
		return $out;
	};
	my $secret = { secret => 'test' };

	like($send->($secret, '<form method="post">'), qr/^Set-Cookie: csrf_token=\d+:[0-9a-f]{64}:[0-9a-f]{64}; path=\/; HttpOnly; SameSite=Strict$/m, 'sent to a form');
	like($send->($secret, '<FORM>'), qr/csrf_token=/, 'whatever its case');
	is($send->($secret, '<p>No form here</p><formula>'), '', 'not sent to a page without one');
	is($send->({ enable => 0, secret => 'test' }, '<form>'), '', 'not sent when turned off');
};

done_testing();
