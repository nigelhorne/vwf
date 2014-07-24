package VWF::page;

# Display a page. Certain variables are available to all templates, such as
# the stuff in the configuration file

use Template;
use Config::Auto;
use CGI::Info;
use File::Spec;
use Data::Throttler;

my %blacklist = (
	'MD' => 1,
	'RU' => 1,
	'CN' => 1,
	'BR' => 1,
	'UY' => 1,
	'TR' => 1,
	'MA' => 1,
	'VE' => 1,
	'SA' => 1,
	'CY' => 1,
	'CO' => 1,
	'MX' => 1,
	'IN' => 1,
	'RS' => 1,
	'PK' => 1,
);

sub new {
	my $proto = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $class = ref($proto) || $proto;

	my $info = $args{info} || CGI::Info->new();

	unless($info->is_search_engine() || !defined($ENV{'REMOTE_ADDR'})) {
		# Handle YAML Errors
		my $db_file = $info->tmpdir() . '/throttle';
		eval {
			my $throttler = Data::Throttler->new(
				max_items => 30,
				interval => 90,
				backend => 'YAML',
				backend_options => {
					db_file => $db_file
				}
			);

			unless($throttler->try_push(key => $ENV{'REMOTE_ADDR'})) {
				die "$ENV{REMOTE_ADDR} connexion throttled";
			}
		};
		if($@) {
			unlink($db_file);
		}
		my $lingua = $args{lingua};
		if($lingua) {
			if($blacklist{uc($lingua->country())}) {
				die "$ENV{REMOTE_ADDR} is from a blacklisted country " . $lingua->country();
			}
		}
	}
	my $path = File::Spec->catdir(
			$info->script_dir(),
			File::Spec->updir(),
			File::Spec->updir(),
			'conf'
		);

	unless(-d $path) {
		if($ENV{'DOCUMENT_ROOT'}) {
			$path = File::Spec->catdir(
				$ENV{'DOCUMENT_ROOT'},
				File::Spec->updir(),
				'lib',
				'conf'
			);
		} else {
			$path = File::Spec->catdir(
				$ENV{'HOME'},
				'lib',
				'conf'
			);
		}
	}
	my $config;
	eval {
		$config = Config::Auto::parse($info->domain_name(), path => $path);
	};
	if($@) {
		die "Configuration error: $@" . $path . '/' . $info->domain_name();
	}

	return bless {
		_config => $config,
		_info => $info,
		_lingua => $args{lingua},
		_key => (defined($info->params())) ? $info->params()->{key} : undef,
	}, $class;
}

sub get_template_path {
	my $self = shift;

	my $dir = $self->{_config}->{rootdir} || $self->{_info}->rootdir();
	$dir .= '/templates';

	#  Look in .../en/gb/web, then .../en/web then /web
	if($self->{_lingua}) {
		my $lingua = $self->{_lingua};
		my $candidate;
		if($lingua->sublanguage_code_alpha2()) {
			$candidate = "$dir/" . $lingua->code_alpha2() . '/' . $lingua->sublanguage_code_alpha2();
		} elsif($lingua->code_alpha2()) {
			$candidate = "$dir/" . $lingua->code_alpha2();
		} else {
			$candidate = $dir;
		}
		if(!-d $candidate) {
			if(defined($lingua->code_alpha2())) {
				$candidate = "$dir/" . $lingua->code_alpha2();
				if(!-d $candidate) {
					$candidate = $dir;
				}
			} else {
				$candidate = $dir;
			}
		}
		$dir = $candidate;
	}

	# Look in .../robot or .../mobile first, if appropriate
	my $prefix;
	if($self->{_info}->is_mobile()) {
		$prefix = "$dir/mobile";
	} elsif($self->{_info}->is_search_engine() || $self->{_info}->is_robot()) {
		$prefix = "$dir/robot";
	}

	my $modulepath = ref($self);
	$modulepath =~ s/::/\//g;

	my $filename;

	if(defined($prefix)) {
		$filename = "$prefix/$modulepath.tmpl";

		if(-f $filename) {
			if(-r $filename) {
				return $filename;
			}
			die "Can't open $filename";
		}
		$filename = "$prefix/$modulepath.html";
		if(-f $filename) {
			if(-r $filename) {
				return $filename;
			}
			die "Can't open $filename";
		}
	}

	# Fall back to .../web, or if that fails, assume no web, robot or
	# mobile variant
	$filename = _pfopen("$dir/web:$dir", $modulepath, 'tmpl:html');
	if((!defined($filename)) || (!-f $filename) || (!-r $filename)) {
		die "Can't find suitable html or tmpl file in $modulepath in $dir or a subdir";
	}
	return $filename;
}

sub set_cookie {
	my $self = shift;
	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	foreach my $key(keys(%params)) {
		$self->{_cookies}->{$key} = $params{$key};
	}
}

sub http {
	my ($self, $params) = @_;

	# TODO: Only session cookies as the moment
	my $cookies = $self->{_cookies};
	if(defined($cookies)) {
		foreach my $cookie (keys(%{$cookies})) {
			if(exists($cookies->{$cookie})) {
				print "Set-Cookie:$cookie=$cookies->{$cookie}; path=/; HttpOnly\n";
			} else {
				print "Set-Cookie:$cookie=0:0; path=/; HttpOnly\n";
			}
		}
	}

	my $language;
	if($self->{_lingua}) {
		$language = $self->{_lingua}->language();
	} else {
		$language = 'English';
	}

	# https://www.owasp.org/index.php/Clickjacking_Defense_Cheat_Sheet
	my $rc = "X-Frame-Options: SAMEORIGIN\n";

	if($language eq 'Japanese') {
		binmode(STDOUT, ':utf8');

		$rc = "Content-type: text/html; charset=UTF-8\n";
	} elsif($language eq 'Polish') {
		binmode(STDOUT, ':utf8');

		# print "Content-type: text/html; charset=ISO-8859-2\n";
		$rc = "Content-type: text/html; charset=UTF-8\n";
	} else {
		$rc = "Content-type: text/html; charset=ISO-8859-1\n";
	}

	return $rc . "\n";
}

sub html {
	my ($self, $params) = @_;

	my $info = $self->{_info};

	my $template = Template->new({
		INTERPOLATE => 1,
		POST_CHOMP => 1,
		ABSOLUTE => 1,
	});

	# The values in config are defaults which can be overriden by
	# the values in params
	my $vals;

	if(defined($params)) {
		if(defined($self->{_config})) {
			$vals = { %{$self->{_config}}, %{$params} };
		} else {
			$vals = $params;
		}
	} elsif(defined($self->{_config})) {
		$vals = $self->{_config};
	}

	$vals->{cart} = $info->get_cookie(cookie_name => 'cart');

	my $filename = $self->get_template_path();
	my $rc;
	if($filename =~ /.+\.tmpl$/) {
		$template->process($filename, $vals, \$rc) ||
			die $template->error();
	} elsif($filename =~ /.*\.html?$/) {
		open(my $fin, '<', $filename) || die "$filename: $!";

		my @lines = <$fin>;

		close $fin;

		$rc = join('', @lines);
	} else {
		warn "Unhandled file type $filename";
	}
	return $rc;
}

sub as_string {
	my ($self, $args) = @_;

	# TODO: Get all cookies and send them to to template.
	# 'cart' is an example
	unless($args && $args->{cart}) {
		$purchases = $self->{_info}->get_cookie(cookie_name => 'cart');
		if($purchases) {
			my %cart = split(/:/, $purchases);
			$args->{cart} = \%cart;
		}
	}
	unless($args && $args->{itemsincart}) {
		if($args->{cart}) {
			my $itemsincart;
			foreach my $key(keys %{$args->{cart}}) {
				if(defined($args->{cart}{$key}) && ($args->{cart}{$key} ne '')) {
					$itemsincart += $args->{cart}{$key};
				} else {
					delete $args->{cart}{$key};
				}
			}
			$args->{itemsincart} = $itemsincart;
		}
	}

	my $html = $self->html($args);
	unless($html) {
		return;
	}
	return $self->http() . $html;
}

# my $f = pfopen('/tmp:/var/tmp:/home/njh/tmp', 'foo', 'txt:bin' );
# $f = pfopen('/tmp:/var/tmp:/home/njh/tmp', 'foo');
sub _pfopen {
	my $path = shift;
	my $prefix = shift;
	my $suffixes = shift;

	foreach my $dir(split(/:/, $path)) {
		if($suffixes) {
			foreach my $suffix(split(/:/, $suffixes)) {
				if(-r "$dir/$prefix.$suffix") {
					return "$dir/$prefix.$suffix";
				}
			}
		} elsif(-r "$dir/$prefix") {
			return "$dir/$prefix";
		}
	}
}

1;
