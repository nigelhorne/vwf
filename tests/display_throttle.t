#!/usr/bin/env perl

# VWF::Display::new() must refuse to build a page for a throttled client,
# and must not erase the throttle database when it does so.

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::Most;

use lib File::Spec->catfile($Bin, '..', 'lib');

# Don't slow the test down; must be in place before VWF::Display is compiled
BEGIN { *CORE::GLOBAL::sleep = sub { return 0 } }

use CGI::Info;
use VWF::Display;

# A stand-in for CGI::Lingua: new() wants country(), HTML::SocialMedia
# asks for more, and undef is a good enough answer to the rest
{
	package StubLingua;
	our $AUTOLOAD;
	sub new { return bless { country => $_[1] }, $_[0] }
	sub country { return $_[0]{country} }
	sub AUTOLOAD { return }
	sub DESTROY { }
}

my $dir = tempdir(CLEANUP => 1);
my $db_file = File::Spec->catfile($dir, 'throttle');

# Config::Abstraction reads 'default' first
open(my $fout, '>', File::Spec->catfile($dir, 'default')) or die "$dir/default: $!";
print $fout <<"EOF";
<?xml version="1.0"?>
<config>
	<memory_cache><driver>Null</driver></memory_cache>
	<throttle>
		<file>$db_file</file>
		<max_items>2</max_items>
		<interval>90</interval>
	</throttle>
</config>
EOF
close $fout;

local $ENV{'CONFIG_DIR'} = $dir;
local $ENV{'REMOTE_ADDR'} = '10.1.2.3';
local $ENV{'REQUEST_METHOD'} = 'GET';
local $ENV{'HTTP_HOST'} = 'example.com';
delete local $ENV{'QUERY_STRING'};
delete local $ENV{'HTTP_REFERER'};

my @displays;
foreach my $n (1..3) {
	CGI::Info->reset();
	my $info = CGI::Info->new();
	my $display = VWF::Display->new(info => $info, lingua => StubLingua->new('GB'));
	push @displays, [ $display, $info ];
}

ok(defined($displays[0][0]), 'first request is served');
ok(defined($displays[1][0]), 'second request is served');
ok(!defined($displays[2][0]), 'third request, over the limit, is refused');
is($displays[2][1]->status(), 429, 'status is 429');
ok(-e $db_file, 'throttle database is kept');

done_testing();
