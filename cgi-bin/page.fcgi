#!/usr/bin/env perl

# VWF is licensed under GPL2.0 for personal use only
# njh@bandsman.co.uk

# Can be tested at the command line, e.g.:
#	LANG=en_GB root_dir=$(pwd)/.. ./page.fcgi page=index
# To mimic a French mobile site:
#	root_dir=$(pwd)/.. ./page.fcgi --mobile page=index lang=fr
# To turn off the linting of HTML on a search-engine landing page
#	LANG=en_GB root_dir=$(pwd)/.. ./page.fcgi --search-engine page=index lint_content=0

use strict;
use warnings;
# use diagnostics;

BEGIN {
	# Sanitize environment variables
	delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
	$ENV{'PATH'} = '/usr/local/bin:/bin:/usr/bin';	# For insecurity
}

no lib '.';

use Log::WarnDie 0.09;
use Carp::Always;
use CGI::ACL 0.06;	# For deny_cloud
use CGI::Carp qw(fatalsToBrowser);
use CGI::Info 0.94;	# Gets all messages
use CGI::Lingua 0.61;
use CHI;
use Class::Simple;
use Config::Abstraction;
use Database::Abstraction;
# use Devel::Confess;
use File::Basename;
# use CGI::Alert $ENV{'SERVER_ADMIN'} || 'you@example.com';
use FCGI;
use FCGI::Buffer;
use File::HomeDir;
use HTTP::Status;
use Log::Abstraction;
use Error qw(:try);
use File::Spec;
use POSIX qw(strftime);
use Readonly;
use Module::Runtime qw(require_module);	# Safe dynamic module loading; avoids string eval
use Timer::Simple;
use Time::HiRes;

# FIXME: Sometimes gives Insecure dependency in require while running with -T switch in Module/Runtime.pm
# use Taint::Runtime qw($TAINT taint_env);
use autodie qw(:all);

# Where to find the VWF modules
# use lib '/usr/lib';	# This needs to point to the VWF directory lives,
			# i.e., the contents of the lib directory in the
			# distribution
# use lib '../lib';
use lib CGI::Info::script_dir() . '/../lib';
use lib File::HomeDir->my_home() . '/lib/perl5';

use VWF::Allow;
use VWF::Config;
use VWF::Utils;

# $TAINT = 1;
# taint_env();

# Soft rate-limit: present a CAPTCHA challenge when a client exceeds this
# many requests within $TIME_WINDOW.  Overridable via the config file.
Readonly my $MAX_REQUESTS => 100;
Readonly my $TIME_WINDOW => '60s';	# CHI-style duration string

# Bootstrap CGI::Info before the FCGI accept loop so we can derive the script
# name and temp directory for logging even before the first real request.
my $info = CGI::Info->new();
my @suffixlist = ('.pl', '.fcgi');
my $script_name = basename($info->script_name(), @suffixlist);
my $tmpdir = $info->tmpdir();

# When running under a real HTTP server, redirect STDERR to a per-script log
# file in the temp directory so that die/warn messages are captured.
if($ENV{'HTTP_USER_AGENT'}) {
	close STDERR;
	open(STDERR, '>>', File::Spec->catfile($tmpdir, "$script_name.stderr"));
}

# Register the log filter that suppresses known-harmless warnings.
Log::WarnDie->filter(\&filter);

# $vwflog holds the path to the CSV access log; resolved from config on first request.
my $vwflog;

# These caches are created lazily on the first request and reused across the
# FCGI accept loop to amortise the cost of cache initialisation.
my $info_cache;
my $lingua_cache;
my $buffercache;

# Derive the environment-variable prefix from the hostname (e.g. MY_SITE_)
# so that per-domain config overrides can be passed as environment variables.
my $script_dir = $info->script_dir();
my $env_prefix = uc($info->host_name()) . '_';
$env_prefix =~ tr/\./_/;	# dots in hostnames become underscores in env var names
my $logger = Log::Abstraction->new(Config::Abstraction->new(env_prefix => $env_prefix, flatten => 0, config_file => $info->domain_name(), config_dirs => ["$script_dir/../conf/", "$script_dir/../../conf"])->all());
Log::WarnDie->dispatcher($logger);

# my $pagename = "VWF::Display::$script_name";
# eval "require $pagename";

# Loaded later, only when needed
# use VWF::Display::index;
# use VWF::Display::upload;
# use VWF::Display::editor;
# use VWF::Display::meta_data;

use VWF::Data::index;
if($@) {
	$logger->error($@) if($logger);
	Log::WarnDie->dispatcher(undef);
	die $@;
}
use VWF::Data::vwf_log;

my $database_dir = "$script_dir/../data";
Database::Abstraction::init({
	cache => CHI->new(driver => 'Memory', datastore => {}),
	cache_duration => '1 day',
	directory => $database_dir,
	logger => $logger
});

my $index = VWF::Data::index->new();
if($@) {
	$logger->error($@) if($logger);
	Log::WarnDie->dispatcher(undef);
	die $@;
}

# $config is populated lazily inside doit() so that per-domain configuration
# is loaded after the FCGI request has been accepted and the domain is known.
my $config;
my $vwf_log = VWF::Data::vwf_log->new({ directory => $info->logdir(), filename => 'vwf.log', no_entry => 1 });

# FastCGI signal handling: the FCGI process lives across many requests so we
# cannot exit immediately on SIGTERM/SIGUSR1 — we set a flag and exit cleanly
# after the current request finishes.  See http://fastcgi.com/docs/faq.html#PerlSignals
my $requestcount = 0;
my $handling_request = 0;	# 1 while inside doit(), 0 between requests
my $exit_requested = 0;		# set to 1 by sig_handler; checked after each request

# In-memory set of IPs that have been permanently blacklisted this process
# lifetime (e.g. for sending SQL-injection strings).
my %blacklisted_ip;

# Per-IP request counter cache; created lazily on first request.
my $rate_limit_cache;

# Loopback and private addresses are trusted and exempt from rate limiting.
Readonly my @rate_limit_trusted_ips => ('127.0.0.1', '192.168.1.1');

# Countries from which we receive a disproportionate volume of malicious
# traffic.  Geo-blocking is a blunt instrument but effective at reducing noise.
Readonly my @blacklist_country_list => (
	'BY', 'MD', 'RU', 'CN', 'BR', 'UY', 'TR', 'MA', 'VE', 'SA', 'CY',
	'CO', 'MX', 'IN', 'RS', 'PK', 'UA', 'XH'
);

# Build the ACL object once at startup.  deny_cloud() blocks all known cloud
# provider address ranges (AWS, GCP, Azure) which generate almost no legitimate
# human traffic but are a common origin for automated scanning.
my $acl = CGI::ACL->new()->deny_cloud()->deny_country(country => \@blacklist_country_list)->allow_ip('108.44.193.70')->allow_ip('127.0.0.1');

# Deferred shutdown handler: set the exit flag and, if we are between requests,
# flush caches and exit immediately.  If we are mid-request, the flag is checked
# after doit() returns so the in-flight response is sent cleanly.
sub sig_handler {
	$exit_requested = 1;
	$logger->trace('In sig_handler');
	if(!$handling_request) {
		$logger->info('Shutting down');
		# Flush the page-level response cache to disk before we exit.
		if($buffercache) {
			$buffercache->purge();
		}
		CHI->stats->flush();
		# Detach the dispatcher so that Log::WarnDie does not try to log
		# after the logger object has been destroyed.
		Log::WarnDie->dispatcher(undef);
		exit(0);
	}
}

# USR1 and TERM both trigger a clean shutdown; PIPE is silenced because a
# broken client connection mid-response should not kill the worker.
$SIG{USR1} = \&sig_handler;
$SIG{TERM} = \&sig_handler;
$SIG{PIPE} = 'IGNORE';

# Catch all Perl warnings and mirror them to the per-script stderr log file
# as well as to the structured logger.
$SIG{__WARN__} = sub {
	my $msg = join '', @_;
	if(open(my $fout, '>>', File::Spec->catfile($tmpdir, "$script_name.stderr"))) {
		print $fout $info->domain_name(), ": $msg";
		close $fout;
	}
	$logger->warn($msg) if($logger);
};

# Catch fatal errors.  The $^S guard prevents this handler from interfering
# with Error.pm's try/catch blocks which use eval internally.
$SIG{__DIE__} = sub {
	return if $^S;	# inside an eval — let the caller handle it
	my $msg = join '', @_;
	# Detach Log::WarnDie first so a logger error cannot cause infinite recursion.
	Log::WarnDie->dispatcher(undef);
	if(open(my $fout, '>>', File::Spec->catfile($tmpdir, "$script_name.stderr"))) {
		print $fout $info->domain_name(), ": $msg";
		close $fout;
	}
	$logger->fatal($msg) if($logger);
	CORE::die @_;	# re-throw so the original die location is preserved
};

# my $request = FCGI::Request($stdin, $stdout, $stderr);
my $request = FCGI::Request();

# ─── Main FCGI request loop ───────────────────────────────────────────────────
# Accept() blocks until the web server sends a new request.  It returns a
# negative value when the server wants this worker to exit (e.g. graceful
# shutdown), which breaks the loop naturally.
while($handling_request = ($request->Accept() >= 0)) {

	# REMOTE_ADDR is absent when running from the command line for testing.
	# Switch to a verbose debug logger and single-shot mode in that case.
	unless($ENV{'REMOTE_ADDR'}) {
		my $timer = Timer::Simple->new();

		# Disable all caching so every run reflects the current templates.
		$ENV{'NO_CACHE'} = 1;

		# Map the LANG shell variable to the HTTP Accept-Language header so
		# that language detection works the same way it does in production.
		if((!defined($ENV{'HTTP_ACCEPT_LANGUAGE'})) && defined($ENV{'LANG'})) {
			my $lang = $ENV{'LANG'};
			$lang =~ s/\..*$//;	# strip encoding suffix (e.g. .UTF-8)
			$lang =~ tr/_/-/;	# POSIX uses _, HTTP uses -
			$ENV{'HTTP_ACCEPT_LANGUAGE'} = lc($lang);
		}

		Database::Abstraction::init({ logger => $logger });

		# Replace the production logger with a simple STDOUT printer.
		$logger = Log::Abstraction->new(logger => sub { print join(', ', @{$_[0]->{'message'}}), "\n" }, level => 'debug');
		Log::WarnDie->dispatcher($logger);
		$info->set_logger($logger);
		$index->set_logger($logger);
		$vwf_log->set_logger($logger);

		# Enable full stack traces in Error.pm for command-line debugging.
		$Error::Debug = 1;
		try {
			doit(debug => 1);
		} catch Error with {
			my $msg = shift;
			warn "$msg\n", $msg->stacktrace();
			$logger->error($msg);
		};

		# Report wall-clock time taken for this command-line invocation.
		my @elapsed_time = $timer->hms();
		my $timetaken = int($elapsed_time[2] * 1000);
		$logger->info("$script_name completed in ${timetaken}ms");

		last;	# command-line mode is single-shot; exit the accept loop
	}

	# ── Live HTTP request ──────────────────────────────────────────────────
	$requestcount++;
	$logger->info("Request $requestcount: ", $ENV{'REMOTE_ADDR'});

	# Propagate the current logger to all data-access objects that may emit
	# log messages during this request.
	$info->set_logger($logger);
	$index->set_logger($logger);
	$vwf_log->set_logger($logger);

	# Dispatch the request.  Any unhandled Error.pm exception is caught here
	# so a single bad request cannot kill the FCGI worker process.
	try {
		doit(debug => 0);
	} catch Error with {
		my $msg = shift;
		$logger->error("$msg: ", $msg->stacktrace());
		# Invalidate the response cache on error so a stale error page is
		# never served to subsequent clients.
		if($buffercache) {
			$buffercache->clear();
			$buffercache = undef;
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

# Clean up resources before shutdown
$logger->info('Shutting down');
if($buffercache) {
	$buffercache->purge();
}
if($rate_limit_cache) {
	# Memcached can't purge().
	# I don't like this hardwired code, it would be better if I could find a way to determine if a driver can run purge()
	$rate_limit_cache->purge() if($rate_limit_cache->short_driver_name() ne 'Memcached');
}
if($info_cache) {
	$info_cache->purge();
}
if($lingua_cache) {
	$lingua_cache->purge();
}
CHI->stats->flush();
Log::WarnDie->dispatcher(undef);
exit(0);

# ─── doit() — per-request handler ────────────────────────────────────────────
# Called once per FCGI iteration.  Handles security checks, language detection,
# template dispatch, response caching, and access logging.
sub doit
{
	# Record the wall-clock start time so we can report request duration later.
	my $request_start = Timer::Simple->new();

	# CGI::Info caches state between calls; reset it so this request gets a
	# fresh view of the environment rather than stale values from the last one.
	CGI::Info->reset();

	$logger->debug('In doit - domain is ', CGI::Info->domain_name());

	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	# $config is built once per process and reused.  We cannot build it before
	# the first Accept() because the domain name is not known until then.
	$config ||= VWF::Config->new({
		logger => $logger,
		info => $info,
		debug => $params{'debug'},
		# A throwaway CGI::Lingua is used here only to satisfy VWF::Config;
		# the real, cache-backed instance is created further below.
		lingua => CGI::Lingua->new({ supported => [ 'en-gb' ], info => $info, logger => $logger })
	});

	# The CGI::Info disc cache stores parsed request data across FCGI restarts.
	$info_cache ||= create_disc_cache(config => $config, logger => $logger, namespace => 'CGI::Info');

	my $options = {
		cache => $info_cache,
		logger => $logger
	};

	# If syslog is configured, normalise the 'server' key to 'host' (the
	# Sys::Syslog convention) and pass the stanza to CGI::Info.
	my $syslog;
	if($syslog = $config->syslog()) {
		if($syslog->{'server'}) {
			$syslog->{'host'} = delete $syslog->{'server'};
		}
		$options->{'syslog'} = $syslog;
	}
	# Rebuild $info now that we have a cache and the domain is known.
	$info = CGI::Info->new($options);

	# Lazily initialise the in-memory rate-limit counter store.
	$rate_limit_cache ||= create_memory_cache(config => $config, logger => $logger, namespace => 'rate_limit');

	# Use the real remote IP as the rate-limit key; fall back to 'unknown'
	# only in the unlikely event that REMOTE_ADDR is absent.
	my $client_ip = $ENV{'REMOTE_ADDR'} || 'unknown';

	# A successful CAPTCHA solve stores a short-lived bypass token in the cache.
	# While the token is present the client is exempt from rate-limit checks.
	my $captcha_bypass_key = "$script_name:captcha_bypass:$client_ip";
	my $has_captcha_bypass = $rate_limit_cache->get($captcha_bypass_key);

	# Read the current request count for this IP from the sliding-window cache.
	my $request_count = $rate_limit_cache->get("$script_name:rate_limit:$client_ip") || 0;

	# Allow the thresholds to be tuned via the config file; fall back to the
	# compile-time constants if the stanza is missing.
	my $max_requests = $config->{'security'}->{'rate_limiting'}->{'max_requests'} || $MAX_REQUESTS;
	my $max_requests_hard = $config->{'security'}->{'rate_limiting'}->{'max_requests_hard'} || ($max_requests * 1.5);

	# Check if this is a CAPTCHA verification attempt
	if ($info->param('g-recaptcha-response')) {
		unless(VWF::CAPTCHA->can('new')) {
			require VWF::CAPTCHA;
			VWF::CAPTCHA->import();
		}

		my $recaptcha_config = $config->recaptcha();
		if ($recaptcha_config && $recaptcha_config->{enabled}) {
			my $captcha = VWF::CAPTCHA->new(
				site_key => $recaptcha_config->{site_key},
				secret_key => $recaptcha_config->{secret_key},
				logger => $logger
			);

			if ($captcha->verify($info->param('g-recaptcha-response'), $client_ip)) {
				# CAPTCHA verified - grant bypass
				my $bypass_duration = $config->{'security'}->{'rate_limiting'}->{'captcha_bypass_duration'} || '300s';
				$rate_limit_cache->set($captcha_bypass_key, 1, $bypass_duration);
				$rate_limit_cache->set("$script_name:rate_limit:$client_ip", 0, '60s'); # Reset counter

				$logger->info("CAPTCHA verified for $client_ip - rate limit bypass granted");
				$has_captcha_bypass = 1;

				# Redirect the client back to the page they were trying to reach.
				# SECURITY — CRLF / header-injection defence:
				#   Both the page name and SCRIPT_NAME are interpolated into the
				#   Location header.  A raw %0d%0a sequence in either value would
				#   let an attacker inject arbitrary HTTP response headers
				#   (response-splitting / header-injection).
				#   Strip $redirect_page to a strict allowlist (word chars and
				#   hyphens only), and remove any embedded CR or LF from the
				#   server-supplied SCRIPT_NAME before building the header.
				my $redirect_page = $info->param('page') || 'index';
				$redirect_page =~ s/[^A-Za-z0-9_-]//g;

				# Also sanitize the server variable — it is attacker-influenced
				# in some reverse-proxy configurations.
				my $script = $ENV{SCRIPT_NAME} // '/cgi-bin/page.fcgi';
				$script =~ s/[\r\n]//g;

				$info->status(302);
				print "Status: 302 Found\r\n",
					"Location: ${script}?page=${redirect_page}\r\n\r\n";
				return;
			} else {
				$logger->warn("CAPTCHA verification failed for $client_ip");
				# Fall through to show CAPTCHA again
			}
		}
	}

	# TODO: update the vwf_log variable to point here
	$vwflog ||= $config->vwflog() || File::Spec->catfile($info->logdir(), 'vwf.log');
	my $log = Class::Simple->new();

	# Stores things for a month or longer
	$lingua_cache ||= create_disc_cache(config => $config, logger => $logger, namespace => 'CGI::Lingua');

	# Language negotiation
	my $lingua = CGI::Lingua->new({
		supported => [ 'en-gb' ],
		cache => $lingua_cache,
		info => $info,
		logger => $logger,
		debug => $params{'debug'},
		syslog => $syslog,
	});

	my $cachedir = $params{'cachedir'} || $config->{disc_cache}->{root_dir} || File::Spec->catfile($tmpdir, 'cache');

	# Rate limit by IP (unless bypassed)
	unless($has_captcha_bypass || grep { $_ eq $client_ip } @rate_limit_trusted_ips) {
		if ($request_count >= $max_requests_hard) {
			# Hard limit exceeded - show CAPTCHA with warning
			my $recaptcha_config = $config->recaptcha();

			if ($recaptcha_config && $recaptcha_config->{enabled}) {
				$logger->warn("Hard rate limit exceeded for $client_ip ($request_count requests)");
				$info->status(429);

				unless(VWF::Display::captcha->can('new')) {
					require VWF::Display::captcha;
					VWF::Display::captcha->import();
				}
				my $display = VWF::Display::captcha->new({
					cachedir => $cachedir,
					info => $info,
					logger => $logger,
					lingua => $lingua,
					config => $config,
				});

				# print "Pragma: no-cache\n\n";
				print $display->as_string({
					Retry_After => 60,
					hard_block => 1,
					request_count => $request_count,
				});

				vwflog($vwflog, $info, $lingua, $syslog, 'Hard rate limit - CAPTCHA shown', $log, $request_start);
				return;
			}
		} elsif ($request_count >= $max_requests) {
			# Soft limit exceeded - show CAPTCHA
			my $recaptcha_config = $config->recaptcha();

			if ($recaptcha_config && $recaptcha_config->{enabled}) {
				$logger->info("Soft rate limit exceeded for $client_ip ($request_count requests) - CAPTCHA challenge issued");

				unless(VWF::Display::captcha->can('new')) {
					require VWF::Display::captcha;
					VWF::Display::captcha->import();
				}
				my $display = VWF::Display::captcha->new({
					cachedir => $cachedir,
					info => $info,
					logger => $logger,
					lingua => $lingua,
					config => $config,
				});

				# print "Pragma: no-cache\n\n";
				print $display->as_string({
					Retry_After => 60,
					hard_block => 0,
					request_count => $request_count,
				});

				vwflog($vwflog, $info, $lingua, $syslog, 'Soft rate limit - CAPTCHA shown', $log, $request_start);
				return;
			}
		}
	}

	# Commit the incremented request count back to the sliding-window cache.
	# The TTL is the rate-limit window; the counter expires automatically.
	my $time_window = $config->{'security'}->{'rate_limiting'}->{'time_window'} || $TIME_WINDOW;
	$rate_limit_cache->set("$script_name:rate_limit:$client_ip", $request_count + 1, $time_window);

	# A request with no page parameter cannot be dispatched; send a 300
	# response listing the known valid pages instead.
	if(!defined($info->param('page'))) {
		$logger->info('No page given in ', $info->as_string());
		choose();
		return;
	}

	# ── Multi-layer access control ─────────────────────────────────────────
	# Three independent checks are run in order of cheapness:
	#   1. CGI::ACL — cloud ranges, country blocks, explicit IP allow/deny.
	#   2. blacklisted() — in-process IP set built from prior SQL-injection attempts.
	#   3. VWF::Allow — DShield feed, user-agent blacklist, throttler, IDS.
	if(my $remote_addr = $ENV{'REMOTE_ADDR'}) {
		my $reason;
		if($acl->all_denied(lingua => $lingua)) {
			$reason = 'Denied by CGI::ACL';
		} elsif(blacklisted($info)) {
			$reason = 'Blacklisted for attempting to break in';
		} else {
			# VWF::Allow may throw an Error object when it blocks a request.
			# Catch it here so the 403 response is sent rather than propagating.
			try {
				unless(VWF::Allow::allow({
					info   => $info,
					lingua => $lingua,
					logger => $logger,
					cache  => $rate_limit_cache,
					config => $config,
				})) {
					$reason = 'Blocked by VWF::Allow';
				}
			} catch Error with {
				$reason = shift;
			};
		}
		if($reason) {
			# Return a minimal plain-text 403 — no template rendering so that
			# a blocked attacker receives no information about site structure.
			print "Status: 403 Forbidden\n",
				"Content-type: text/plain\n",
				"Pragma: no-cache\n\n";

			# Suppress the body on HEAD requests per RFC 7231 §4.3.2.
			unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
				print "Access Denied\n";
			}
			$logger->info("$remote_addr: access denied: $reason");
			$info->status(403);
			vwflog($vwflog, $info, $lingua, $syslog, $reason, $log, $request_start);
			return;
		}
	}

	# ── FCGI::Buffer setup ────────────────────────────────────────────────
	# FCGI::Buffer post-processes the output: compresses it, generates an ETag
	# and Last-Modified header, and serves a 304 Not Modified when appropriate.
	my $args = {
		generate_etag => 1,
		generate_last_modified => 1,
		compress_content => 1,
		generate_304 => 1,
		info => $info,
		optimise_content => 1,
		logger => $logger,
		# lint_content runs HTML::Tidy on the output; enable in debug mode or
		# when explicitly requested via the lint_content query parameter.
		lint_content => $info->param('lint_content') // $params{'debug'},
		lingua => $lingua
	};

	if((!$info->is_search_engine()) && $config->root_dir() &&
	   ($info->param('page') ne 'home') &&
	   ((!defined($info->param('action'))) || ($info->param('action') ne 'send'))) {
		$args->{'save_to'} = {
			directory => File::Spec->catfile($config->root_dir(), 'save_to'),
			ttl => 3600 * 24,
			create_table => 1
		};
	}

	my $fb = FCGI::Buffer->new()->init($args);

	if($fb->can_cache()) {
		$buffercache ||= create_disc_cache(config => $config, logger => $logger, namespace => $script_name, root_dir => $cachedir);
		$fb->init(
			cache => $buffercache,
			# generate_304 => 0,
			cache_duration => '1 day',
		);
		if($fb->is_cached()) {
			return;
		}
	}

	# $display holds the instantiated VWF::Display subclass when the page is
	# found; $invalidpage is set when the page name is invalid or unloadable.
	my $display;
	my $invalidpage;

	# Arguments forwarded to every VWF::Display subclass constructor.
	$args = {
		cachedir => $cachedir,
		info => $info,
		logger => $logger,
		lingua => $lingua,
		config => $config,
		log => $log
	};

	# ── Page dispatch ──────────────────────────────────────────────────────
	# The outer block eval catches any exception thrown during module loading
	# or display-object construction, setting $@ for inspection below.
	eval {
		my $page = $info->param('page');

		# Strip URL fragment identifiers — the server never needs them.
		$page =~ s/#.*$//;

		# Reject backslashes: no legitimate page name contains one, and
		# they have historically been used to probe Windows path traversal.
		$page =~ s/\\//g;

		if($page =~ /\//) {
			# A slash in the page name indicates an attempt to traverse
			# directories (e.g. page=/etc/passwd or page=http://evil.com).
			$logger->info("Blocking '/' in $page");
			$info->status(403);
			$log->status(403);
			$invalidpage = 1;
		} else {
			# Strip every non-word character so that the page name can only
			# contain [A-Za-z0-9_] — safe to use as a Perl package suffix.
			$page =~ s/\W//g;
			$page =~ s/\s//g;
			my $display_module = "VWF::Display::$page";

			# TODO: consider creating a whitelist of valid modules
			$logger->debug("doit(): Loading module $display_module from @INC");
			unless($display_module->can('new')) {
				# SECURITY — string-eval elimination:
				#   The original code used eval "require $display_module" which is a
				#   string eval on a user-derived value.  Although $page has been
				#   stripped of \W characters, a Unicode or locale edge-case could
				#   allow a bypass.  Module::Runtime::require_module() loads a module
				#   by name using a block eval internally, with no string-eval surface.
				eval { require_module($display_module) };
				$display_module->import() unless $@;
			}
			if($@) {
				$logger->debug("Failed to load module $display_module: $@");
				$logger->info("Unknown page $page");
				$invalidpage = 1;
				if($info->status() == 200) {
					$info->status(404);
				}
			} else {
				# use Class::Inspector;
				# my $methods = Class::Inspector->methods($display_module);
				# print "$display_module exports ", join(', ', @{$methods}), "\n";
				$display = do {
					eval { $display_module->new($args) };
				};
				if(!defined($display)) {
					if($@) {
						$logger->warn("$display_module->new(): $@");
					} else {
						$logger->notice("Can't instantiate page $page");
					}
					$invalidpage = 1;
					if($info->status() == 200) {
						$info->status(404);
					}
				} elsif(!$display->can('as_string')) {
					$logger->warn("Problem understanding $page");
					undef $display;
				}
			}
		}
	};

	my $error = $@;
	if($error) {
		if($info->status() == 429) {
			$logger->notice($error);
		} else {
			$logger->error($error);
		}
		$display = undef;
	}

	if(defined($display)) {
		# Pass in handles to the databases
		print $display->as_string({
			cachedir => $cachedir,
			config => $config,
			databasedir => $database_dir,
			database_dir => $database_dir,
			index => $index,
			vwf_log => $vwf_log,
		});
		vwflog($vwflog, $info, $lingua, $syslog, '', $log, $request_start);
	} elsif($invalidpage) {
		choose();
		vwflog($vwflog, $info, $lingua, $syslog, 'Unknown page', $log, $request_start);
		return;
	} else {
		$logger->debug('disabling cache');
		$fb->init(
			cache => undef,
		);
		# Handle errors gracefully
		if($error eq 'Unknown page to display') {
			print "Status: 400 Bad Request\n",
				"Content-type: text/plain\n",
				"Pragma: no-cache\n\n";

			unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
				print "I don't know what you want me to display.\n";
			}
			$info->status(400);
			$log->status(400);
		} elsif($error =~ /Can\'t locate .* in \@INC/) {
			$logger->error($error);
			print "Status: 500 Internal Server Error\n",
				"Content-type: text/plain\n",
				"Pragma: no-cache\n\n";

			unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
				print "Software error - contact the webmaster\n";
			}
			$info->status(500);
			$log->status(500);
		} elsif(($info->status() == 200) || ($info->status() == 403)) {
			# No permission to show this page
			print "Status: 403 Forbidden\n",
				"Content-type: text/plain\n",
				"Pragma: no-cache\n\n";

			unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
				print "Access Denied\n";
			}
			$info->status(403);
			$log->status(403);
		} else {
			my $status = $info->status();
			print "Status: $status ",
				HTTP::Status::status_message($status),
				"Content-type: text/plain\n",
				"Pragma: no-cache\n\n";

			unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
				print "Page unavailable - something is wrong at your end, please fix and try again\n";
			}
			$log->status($status);
		}
		vwflog($vwflog, $info, $lingua, $syslog, $error ? $error : 'Access denied', $log, $request_start);
		throw Error::Simple($error ? $error : $info->as_string());
	}
}

# Send a 300 Multiple Choices response listing the pages this site serves.
# Called when the ?page= parameter is absent or the requested page is unknown.
sub choose
{
	$logger->info('Called with no page to display');

	my $status = $info->status();

	# If the status is already non-200 (e.g. 404 set by the caller), relay
	# that status rather than overriding it with a 300.
	if($status != 200) {
		print "Status: $status ",
			HTTP::Status::status_message($status),
			"\n\n";
		return;
	}

	print "Status: 300 Multiple Choices\n",
		"Content-type: text/plain\n";

	$info->status(300);

	# Include a Last-Modified header based on the script's mtime so that
	# caches and conditional-GET clients can revalidate efficiently.
	if(my $path = $info->script_path()) {
		require HTTP::Date;
		HTTP::Date->import();

		my @statb = stat($path);
		my $mtime = $statb[9];
		print 'Last-Modified: ', HTTP::Date::time2str($mtime), "\n";
	}

	print "\n";

	# RFC 7231 §4.3.2: a HEAD response must not include a body.
	unless($ENV{'REQUEST_METHOD'} && ($ENV{'REQUEST_METHOD'} eq 'HEAD')) {
		print "/cgi-bin/page.fcgi?page=index\n",
			"/cgi-bin/page.fcgi?page=upload\n",
			"/cgi-bin/page.fcgi?page=editor\n",
			"/cgi-bin/page.fcgi?page=meta_data\n";
	}
}

# Check whether the current request looks like a SQL injection attempt.
# IPs that trigger a match are added to the in-process %blacklisted_ip set so
# that subsequent requests from the same IP are rejected without re-scanning.
sub blacklisted
{
	if(my $remote = $ENV{'REMOTE_ADDR'}) {
		my $info = shift;

		# Fast path: this IP was already blacklisted earlier in this process
		# lifetime; no need to re-scan the request string.
		if($blacklisted_ip{$remote}) {
			$info->status(403);
			return 1;
		}

		if(my $string = $info->as_string()) {
			# SECURITY — ReDoS defence:
			#   The original patterns used greedy .+ between SQL keywords, which
			#   causes catastrophic (exponential) backtracking when an attacker
			#   sends a string that contains the opening keyword but not the
			#   closing one (e.g. thousands of chars after SELECT with no AND).
			#   All .+ quantifiers are replaced with the bounded class [^;]{0,N}:
			#     • the semicolon is a natural SQL statement terminator so it is
			#       a safe anchor that real SQL injection never crosses, and
			#     • the explicit upper bound caps backtracking to O(N) steps.
			#   Word-boundary assertions (\b) also eliminate false positives on
			#   ordinary words that happen to contain the substring.
			if(   ($string =~ /SELECT\b[^;]{0,500}\bAND\b/i)
			   || ($string =~ /ORDER\s+BY\s/i)
			   || ($string =~ /\bOR\s+NOT\b/i)
			   || ($string =~ /\bAND\s+\d+=\d+/i)
			   || ($string =~ /\bTHEN\b[^;]{0,200}\bELSE\b[^;]{0,200}\bEND\b/i)
			   || ($string =~ /\bAND\b[^;]{0,200}\bSELECT\b/i)
			   || ($string =~ /\sAND\s[^;]{0,100}\sAND\s/i)
			   || ($string =~ /\bAND\s+CASE\s+WHEN\b/i)) {
				$blacklisted_ip{$remote} = 1;
				$info->status(403);
				return 1;
			}
		}
	}
	return 0;
}

# False positives we don't need in the logs
sub filter
{
	# return 0 if($_[0] =~ /Can't locate Net\/OAuth\/V1_0A\/ProtectedResourceRequest.pm in /);
	# return 0 if($_[0] =~ /Can't locate auto\/NetAddr\/IP\/InetBase\/AF_INET6.al in /);
	# return 0 if($_[0] =~ /S_IFFIFO is not a valid Fcntl macro at /);

	return 0 if $_[0] =~ /Can't locate (Net\/OAuth\/V1_0A\/ProtectedResourceRequest\.pm|auto\/NetAddr\/IP\/InetBase\/AF_INET6\.al) in |S_IFFIFO is not a valid Fcntl macro at /;
	return 1;
}

# Escape a single value for safe inclusion in a double-quoted CSV field.
# Follows RFC 4180 §2.7 and additionally neutralises spreadsheet formulas.
sub _csv_escape
{
	my $v = shift // '';

	# RFC 4180: a double-quote inside a quoted field is represented by two
	# double-quote characters.  Without this, one embedded " would break the
	# column boundary and corrupt every subsequent field on the row.
	$v =~ s/"/""/g;

	# SECURITY — CSV formula injection defence:
	#   Spreadsheet applications (Excel, LibreOffice Calc) interpret cell values
	#   that begin with = + - @ TAB or CR as formulas.  An attacker who controls
	#   a logged field (e.g. the page parameter) could inject =cmd|'/C calc'!A0.
	#   Prefix such values with a single-quote to force literal interpretation.
	$v =~ s/^([=+\-@\t\r])/'$1/;

	return $v;
}

# Write one access record to vwf.log (CSV format) and optionally to syslog.
# All user-influenced fields are escaped through _csv_escape before output.
sub vwflog
{
	my ($vwflog, $info, $lingua, $syslog, $message, $log, $request_start) = @_;

	# Calculate request duration in milliseconds if a start timer was supplied.
	my $duration_ms = '';
	if($request_start) {
		$duration_ms = int((Time::HiRes::time() - $request_start) * 1000);
	}

	# Determine which template was rendered for this request (may be empty on error).
	my $template;
	if($log) {
		$template = $log->template();
	}
	if(!defined($template)) {
		$template = '';
	}
	$message ||= '';

	# Create the log file with a header row on first use.
	if(!-e $vwflog) {
		open(my $fout, '>', $vwflog);
		print $fout '"domain_name","time","IP","country","type","language","http_code","template","args","messages","error","duration_ms"',
			"\n";
		close $fout;
	}

	# Collect any warn/notice-level messages emitted during this request.
	my $warnings;
        if(my $messages = $info->messages()) {
                $warnings = join('; ',
                        grep defined, map { (($_->{'level'} eq 'warn') || ($_->{'level'} eq 'notice')) ? $_->{'message'} : undef } @{$messages}
                        )
        }
	$warnings ||= '';

	my $country = $lingua->country() || 'unknown';

	# Open the log in append mode.  If the open fails we skip logging silently
	# so that a disk-full or permissions error does not crash the live request.
	if(open(my $fout, '>>', $vwflog)) {
		# SECURITY — CSV injection defence:
		#   Every user-visible field is passed through _csv_escape so that
		#   embedded double-quotes cannot break the CSV column structure, and
		#   leading formula characters cannot trigger code execution when the
		#   file is opened in a spreadsheet application.
		print $fout
			'"', _csv_escape($info->domain_name()), '",',
			'"', strftime('%F %T', localtime), '",',
			'"', _csv_escape($ENV{REMOTE_ADDR} // ''), '",',
			'"', _csv_escape($country), '",',
			'"', _csv_escape($info->browser_type()), '",',
			'"', _csv_escape($lingua->language() // ''), '",',
			$info->status(), ',',
			'"', _csv_escape($template), '",',
			'"', _csv_escape($info->as_string(raw => 1)), '",',
			'"', _csv_escape($warnings), '",',
			'"', _csv_escape($message), '",',
			$duration_ms,
			"\n";
		close($fout);
	}

	# Optionally mirror the record to syslog (configured via the syslog stanza).
	if($syslog) {
		unless(Sys::Syslog->can('openlog')) {
			require Sys::Syslog;
			Sys::Syslog->import();
		}

		# Configure the socket transport if a hash of options was provided.
		if(ref($syslog) eq 'HASH') {
			Sys::Syslog::setlogsock($syslog);
		}
		Sys::Syslog::openlog($script_name, 'cons,pid', 'user');
		# Use positional %s/%d format args so that special characters in the
		# values cannot be interpreted as syslog format directives.
		Sys::Syslog::syslog('info|local0', '%s %s %s %s %s %d %s %s %d %s %s',
			$info->domain_name() || '',
			$ENV{REMOTE_ADDR} || '',
			$country,
			$info->browser_type() || '',
			$lingua->language() || '',
			$info->status() || '',
			$template || '',
			$info->as_string(raw => 1) || '',
			$duration_ms,
			$warnings,
			$message
		);
		Sys::Syslog::closelog();
	}
}
