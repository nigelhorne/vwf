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
use CGI::Buffer { optimise_content => 1 };
use CHI;
use CGI::Info;
use CGI::Lingua;
use File::Basename;

use lib '/usr/lib';	# This needs to point to the VWF directory lives,
			# i.e. the contents of the lib directory in the
			# distribution

my $cachedir = CGI::Info->tmpdir() . '/cache';
my $info = CGI::Info->new({
	cache => CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => 'CGI::Info'),
});

my @suffixlist = ('.pl', '.fcgi');
my $script_name = basename($info->script_name(), @suffixlist);

my $script_dir = $info->script_dir();
Log::Log4perl->init("$script_dir/../conf/$script_name.l4pconf");
my $logger = Log::Log4perl->get_logger($script_name);

if(CGI::Buffer::can_cache()) {
	CGI::Buffer::set_options(
		cache => CHI->new(driver => 'File', root_dir => $cachedir, namespace => $script_name),
		info => $info,
		logger => $logger,
		# generate_304 => 0,
	);
	if(CGI::Buffer::is_cached()) {
		exit;
	}
} else {
	CGI::Buffer::set_options(info => $info, logger => $logger);
}

my $lingua = CGI::Lingua->new({
        supported => [ 'en-gb' ],
	cache => CHI->new(driver => 'BerkeleyDB', root_dir => $cachedir, namespace => 'CGI::Lingua'),
	info => $info,
	logger => $logger,
});

my $pagename = "VWF::$script_name";
eval "require $pagename";

my $display;
eval {
	$display = VWF::index->new({
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

	# Make 'em wait
	sleep 30;

	unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
		print "There is a problem with your connection. Please contact your ISP.\n";
		print $error if $error;
	}
}
