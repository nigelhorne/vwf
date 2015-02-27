#!/usr/bin/env perl

# VWF is licensed under GPL2.0 for personal use only
# njh@bandsman.co.uk

# Build the data to be displayed on the index page

# use File::HomeDir;
# use lib File::HomeDir->my_home() . '/lib/perl5';

use strict;
use warnings;
use diagnostics;

use Log::Log4perl qw(:levels);	# Put first to cleanup last
use CGI::Carp qw(fatalsToBrowser);
use CHI;
use CGI::Info;
use CGI::Lingua;
use File::Basename;
use FCGI;
use FCGI::Buffer;
use File::HomeDir;

use lib '/usr/lib';	# This needs to point to the VWF directory lives,
			# i.e. the contents of the lib directory in the
			# distribution

my $info = CGI::Info->new();
my $tmpdir = $info->tmpdir();
my $cachedir = "$tmpdir/cache";
my $script_dir = $info->script_dir();

my @suffixlist = ('.pl', '.fcgi');
my $script_name = basename($info->script_name(), @suffixlist);

# open STDERR, ">&STDOUT";
close STDERR;
open(STDERR, '>>', "$tmpdir/$script_name.stderr");

my $infocache = CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => 'CGI::Info');
my $linguacache => CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => 'CGI::Lingua');
my $buffercache = CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => $script_name);

my $pagename = "VWF::$script_name";
eval "require $pagename";

Log::Log4perl->init("$script_dir/../conf/$script_name.l4pconf");
my $logger = Log::Log4perl->get_logger($script_name);

my $request = FCGI::Request();

while($request->FCGI::Accept() >= 0) {
	eval {
		doit();
	};
	if($@) {
		$logger->error($@);
	}
	# $request->Finish();
}

sub doit
{
	my $info = CGI::Info->new({ cache => $infocache });

	my $fb = FCGI::Buffer->new();
	$fb->init({ info => $info, optimise_content => 1, lint_content => 0, logger => $logger });
	if($fb->can_cache()) {
		$fb->init(
			cache => $buffercache,
			# generate_304 => 0,
		);
		if($fb->is_cached()) {
			$request->Finish();
			return;
		}
	}

	my $lingua = CGI::Lingua->new({
		supported => [ 'en-gb' ],
		cache => $linguacache,
		info => $info,
		logger => $logger,
	});

	my $display;
	eval {
		$display = $pagename->new({
			info => $info,
			lingua => $lingua,
			logger => $logger,
		});
	};

	my $error = $@;

	if(defined($display)) {
		print $display->as_string();
	} else {
		# No permission to show this page
		print "Status: 403 Forbidden\n";
		print "Content-type: text/plain\n";
		print "Pragma: no-cache\n\n";

		warn $error if $error;

		unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
			print "There is a problem with your connection. Please contact your ISP.\n";
			print $error if $error;
		}
	}
}
