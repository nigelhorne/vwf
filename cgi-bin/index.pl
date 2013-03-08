#!/usr/bin/perl -w

# VWF is licensed under GPL2.0 for personal use only
# njh@bandsman.co.uk

# Build the data to be displayed on the index page

use "/usr/lib/VKF";	# This needs to point to where page.pm has been installed

use strict;
use warnings;
use diagnostics;

use CGI::Carp qw(fatalsToBrowser);
use CGI::Buffer { optimise_content => 1 };
use CHI;

use VWF::index;

my $info = CGI::Info->new();
my $cachedir = $info->tmpdir() . '/cache';
my $script_name = $info->script_name();
CGI::Buffer::set_options(
	cache => CHI->new(driver => 'File', root_dir => $cachedir, namespace => $script_name),
	# generate_304 => 0,
);
if(CGI::Buffer::is_cached()) {
	exit;
}

my $display = VWF::index->new({ info => $info });

if(defined($display)) {
	print $display->as_string();
} else {
	# No permission to show this page
	print "Status: 403 Forbidden\n";
	print "Content-type: text/plain\n";
	print "Pragma: no-cache\n\n";

	# Make 'em wait
	sleep 30;

	unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
		print "There is a problem with your connection. Please contact your ISP.\n";
	}
	exit;
}
