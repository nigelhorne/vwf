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
use Log::Any::Adapter;
use Error qw(:try);

# use lib '/usr/lib';	# This needs to point to the VWF directory lives,
			# i.e. the contents of the lib directory in the
			# distribution
use lib '../lib';
use lib './lib';

my $info = CGI::Info->new();
my $tmpdir = $info->tmpdir();
my $cachedir = "$tmpdir/cache";
my $script_dir = $info->script_dir();

my @suffixlist = ('.pl', '.fcgi');
my $script_name = basename($info->script_name(), @suffixlist);

# open STDERR, ">&STDOUT";
close STDERR;
open(STDERR, '>>', "$tmpdir/$script_name.stderr");

my $infocache = CHI->new(driver => 'Memcached', servers => [ '127.0.0.1:11211' ], namespace => 'CGI::Info');
my $linguacache = CHI->new(driver => 'Memcached', servers => [ '127.0.0.1:11211' ], namespace => 'CGI::Lingua');
my $buffercache = CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => $script_name);

Log::Log4perl->init("$script_dir/../conf/$script_name.l4pconf");
my $logger = Log::Log4perl->get_logger($script_name);

my $pagename = "VWF::Display::$script_name";
eval "require $pagename";

use VWF::DB::index;

my $database_dir = "$script_dir/../databases";
VWF::DB::init({ directory => $database_dir, logger => $logger });

my $index = VWF::DB::index->new();
if($@) {
	$logger->error($@);
	die $@;
}

# http://www.fastcgi.com/docs/faq.html#PerlSignals
my $requestcount = 0;
my $handling_request = 0;
my $exit_requested = 0;

sub sig_handler {
	$exit_requested = 1;
	$logger->trace('In sig_handler');
	if(!$handling_request) {
		$logger->info('Shutting down');
		if($buffercache) {
			$buffercache->purge();
		}
		CHI->stats->flush();
		exit(0);
	}
}

$SIG{USR1} = \&sig_handler;
$SIG{TERM} = \&sig_handler;
$SIG{PIPE} = 'IGNORE';

my $request = FCGI::Request();

while($handling_request = ($request->Accept() >= 0)) {
	$requestcount++;
	if($ENV{'REMOTE_ADDR'}) {
		Log::Any::Adapter->set( { category => $script_name }, 'Log4perl');
	} else {
		Log::Any::Adapter->set('Stdout');
	}
	$logger = Log::Any->get_logger(category => $script_name);
	$logger->info("Request $requestcount", $ENV{'REMOTE_ADDR'} ? " $ENV{'REMOTE_ADDR'}" : '');

	$Error::Debug = 1;

	try {
		doit();
	} catch Error with {
		my $msg = shift;
		warn "$msg\n", $msg->stacktrace unless(defined($ENV{'REMOTE_ADDR'}));
		$logger->error($msg);
		if($buffercache) {
			$buffercache->clear();
		}
	};
	$request->Finish();
	$handling_request = 0;
	if($exit_requested) {
		last;
	}
	if($ENV{SCRIPT_FILENAME}) {
		if(-M $ENV{SCRIPT_FILENAME} < 0) {
			last;
		}
	}
}

$logger->info("Shutting down");
if($buffercache) {
	$buffercache->purge();
}
CHI->stats->flush();

sub doit
{
	CGI::Info->reset();
	my $info = CGI::Info->new({ cache => $infocache, logger => $logger });

	my $fb = FCGI::Buffer->new();
	$fb->init({ info => $info, optimise_content => 1, lint_content => 0, logger => $logger });
	if(!$ENV{'REMOTE_ADDR'}) {
		$fb->init(lint_content => 1);
	}
	if($fb->can_cache()) {
		$fb->init(
			cache => $buffercache,
			# generate_304 => 0,
		);
		if($fb->is_cached()) {
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
		# Pass in a handle to the database
		print $display->as_string({
			index => $index, cachedir => $cachedir
		});
	} else {
		# No permission to show this page
		print "Status: 403 Forbidden\n",
			"Content-type: text/plain\n",
			"Pragma: no-cache\n\n";

		warn $error if $error;

		unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
			print "There is a problem with your connection. Please contact your ISP.\n";
			print $error if $error;
		}
	}
}
