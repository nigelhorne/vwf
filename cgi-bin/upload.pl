#!/usr/bin/env perl

# VWF is licensed under GPL2.0 for personal use only
# njh@bandsman.co.uk

# use File::HomeDir;
# use lib File::HomeDir->my_home() . '/lib/perl5';

use strict;
use warnings;
# use diagnostics;

no lib '.';

BEGIN {
	if(-d '/home/hornenj/perlmods') {
		# Running at Dreamhost
		use lib '/home/hornenj/perlmods/lib/perl/5.14';
		use lib '/home/hornenj/perlmods/lib/perl/5.14.2';
		use lib '/home/hornenj/perlmods/share/perl/5.14';
		use lib '/home/hornenj/perlmods/share/perl/5.14.2';
		use lib '/home/hornenj/perlmods/lib/perl5';
	}
}

use Log::Log4perl qw(:levels);	# Put first to cleanup last
use CGI::Info;
use File::Basename;
use Log::WarnDie;
use String::Random;
use HTML::Entities;
use autodie qw(:all);
use CGI::Alert 'njh@bandsman.co.uk';

use lib '../lib';
use VWF::Config;
use VWF::Utils;

if(0) {
	open(my $f, '>>', '/tmp/NJH');
	while(my $line = <STDIN>) {
		print $f $line;
	}
	# exit;
}

print "Status: 200 OK\n",
	"Content-type: application/json\n\n";

my $info = CGI::Info->new(max_upload_size => 10 * 1024 * 1024);

my $tmpdir = $info->tmpdir();
my $site = 'VWF';
my $script_dir = $info->script_dir();
my @suffixlist = ('.pl', '.fcgi');
my $script_name = basename($info->script_name(), @suffixlist);

# open STDERR, ">&STDOUT";
close STDERR;
open(STDERR, '>>', "$tmpdir/$script_name.stderr");

Log::Log4perl->init("$script_dir/../conf/$script_name.l4pconf");
my $logger = Log::Log4perl->get_logger($script_name);
Log::WarnDie->dispatcher($logger);

my $dir = $info->script_dir() . '/../uploads';
if(!-d $dir) {
	mkdir $dir;
}
my %FORM;
if($info->params(upload_dir => $dir, logger => $logger)) {
	%FORM = %{$info->params()};
}

# my $address = $FORM{'address'};
my $address = 'njh@bandsman.co.uk';
my $domain_name = $info->domain_name();

open(my $fout, '>>', '/tmp/scratch_upload');

print $fout "Subject: scratch_upload\n";

print $fout "\n";

foreach my $key (sort keys(%FORM)) {
	if (length($FORM{$key}) > 0) {
		print $fout "$key: $FORM{$key}\n";
	}
}

print $fout '-' x 40, "\n";

if($ENV{'REQUEST_METHOD'}) {
        if($ENV{'REQUEST_METHOD'} eq 'DELETE') {
		print $fout "DELETE\n";
	}
	if(($ENV{'REQUEST_METHOD'} eq 'DELETE') && $ENV{'SCRIPT_URI'}) {
		unlink $info->script_dir() . $ENV{'SCRIPT_URI'};
	}
}

my $config = VWF::Config->new({ logger => $logger, info => $info });
my $cache = create_memory_cache(config => $config, namespace => 'upload', logger => $logger);

if($FORM{'delete'} && $FORM{'key'}) {
	my($address, $file) = split(/\//, $cache->get($FORM{'key'}), 2);
	if($file) {
		$file =~ s/%20/ /g;
		$file = decode_entities($file);
		my $ndir = "$dir/$address";
		my $remove;
		if(unlink "$ndir/$file") {
			$remove = $file;
		} else {
			$logger->warn("Can't remove $ndir/$file: $!");
		}
		opendir(my $direct, $ndir);

		print '{"files": [';
		my $first = 1;
		while(my $file = readdir($direct)) {
			next if($file =~ /^\./);

			my $size = (stat("$ndir/$file"))[7];
			if($first) {
				$first = 0;
			} else {
				print ',';
			}
			my $displayname = $file;
			$displayname =~ s/_\d{10}$//;
			my $key = $cache->get("$FORM{address}/$file");
			print '{"name": "', $displayname, '",',
			    '"size": ', $size, ',',
			    '"url": "\/uploads\/' . $FORM{'address'} . "\/$file", '",',
			    '"thumbnailUrl": "\/icons\/icons8-File-50.png",',
			    # '"deleteUrl": "\/uploads\/' . $FORM{'address'} . "\/$file", '",',
			    # '"deleteType": "DELETE"',
			    '"deleteUrl": "', $info->script_name(), "?delete=1&key=$key", '",',
			    '"deleteType": "GET"',
			    '}';
		}
		if($remove) {
			if(!$first) {
				print ',';
			}
			print "{\"$remove\": true}";
		}
		print ']}';

		$cache->remove($FORM{'key'});
		$cache->remove("$address/$file");
	} else {
		my $filename = $dir . '/' . $FORM{'files'};
		my $size = (stat($filename))[7];
		print '{"files": [',
			  '{',
			    '"name": "', $FORM{files}, '",',
			    '"size": ', $size, ',',
			    '"error": "Cannot determine the file to remove"',
			  '}',
			']}';
		$logger->warn("Can't find $FORM{key} in the datastore");
	}
}

if($FORM{'album_title'}) {
	if($FORM{'files'}) {
		my $f = $FORM{'album_title'};
		my $filename = "$dir/$f";

		mkdir $dir;
		my $nfilename = "$dir/$f";
		rename $filename, $nfilename;

		my $rand = String::Random->new();
		my $key;
		do {
			$key = $rand->randregex('\w\w\w\w\w\w\w\w');
		} while($cache->get($key));	# FIXME: race condition
		my $encoded_name = encode_entities($f);
		$encoded_name =~ s/ /%20/g;
		$cache->set($key, $encoded_name, '1 week');
		$cache->set($encoded_name, $key, '1 week');
		print $fout "set $encoded_name to $key in the memcache\n";
		$logger->debug("set $encoded_name to $key in the memcache");
		if(!defined($cache->get($key))) {
			print $fout "Can't find new $key in the memcache\n";
			$logger->warn("Can't find new $key in the memcache");
		}
		if(!defined($cache->get($encoded_name))) {
			print $fout "Can't find new $encoded_name in the memcache\n";
			$logger->warn("Can't find new $encoded_name in the memcache");
		}
	}

	opendir(my $direct, $dir);

	print '{"files": [';
	my $first = 1;
	while(my $file = readdir($direct)) {
		next if($file =~ /^\./);

		my $size = (stat("$dir/$file"))[7];
		if($first) {
			$first = 0;
		} else {
			print ',';
		}
		my $encoded_name = encode_entities($FORM{album_title});
		$encoded_name =~ s/ /%20/g;
		my $key = $cache->get($encoded_name);
		if(!defined($key)) {
			print $fout "Can't find $encoded_name in the memcache\n";
			$logger->warn("Can't find $encoded_name in the memcache");
		}
		my $displayname = $file;
		$displayname =~ s/_\d{10}$//;
		print '{"name": "', $displayname, '",',
		    '"size": ', $size, ',',
		    '"url": "\/uploads\/' . $FORM{'album_title'} . "\/$file", '",',
		    '"thumbnailUrl": "\/icons\/icons8-File-50.png",',
		    # '"deleteUrl": "\/uploads\/' . $FORM{'address'} . "\/$file", '",',
		    # '"deleteType": "DELETE"',
		    '"deleteUrl": "', $info->script_name(), "?delete=1&key=$key", '",',
		    '"deleteType": "GET"',
		    '}';
		print $fout '{"name": "', $displayname, '",',
		    '"size": ', $size, ',',
		    '"url": "\/uploads\/' . $FORM{'album_title'} . "\/$file", '",',
		    '"thumbnailUrl": "\/icons\/icons8-File-50.png",',
		    # '"deleteUrl": "\/uploads\/' . $FORM{'address'} . "\/$file", '",',
		    # '"deleteType": "DELETE"',
		    '"deleteUrl": "', $info->script_name(), "?delete=1&key=$key", '",',
		    '"deleteType": "GET"',
		    '}';
	}
	print ']}';
	print $fout ']}';
} else {
	if($FORM{'files'}) {
		my $filename = $dir . '/' . $FORM{'files'};
		my $size = (stat($filename))[7];
		# TODO: list other files owned by this person
		print '{"files": [',
			  '{',
			    '"name": "', $FORM{files}, '",',
			    '"size": ', $size, ',',
			    '"error": "Fill in the picture name"',
			  '}',
			']}';
		unlink $filename;
	}
}
