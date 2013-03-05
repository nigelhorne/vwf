#!/usr/bin/perl -w

# Copyright (C) 2004-2012 Nigel Horne, All rights reserved
# Build the data to be displayed on the shop's index page

# Dreamhost
use lib '/home/nigelhorne/perlmods/lib/perl/5.10';
use lib '/home/nigelhorne/perlmods/lib/perl/5.10.0';
use lib '/home/nigelhorne/perlmods/share/perl/5.10';
use lib '/home/nigelhorne/perlmods/share/perl/5.10.0';
use lib '/home/nigelhorne/perlmods/lib/perl5';
use lib '/home/nigelhorne/lib/perl5';

use lib '/home/njh/lib/perl5';

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

my $display = VWF::shop::index->new({ info => $info });

print $display->as_string();
