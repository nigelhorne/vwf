package BBPortal::table;

use Config::Auto;
use Text::xSV::Slurp;
use File::Slurp;

# Read in a small flat file of ! delimted records and make them available
# as object methods so that they can be read from a page display routine or
# template

# An optional filename can be given, if it isn't then it's derived from the
# class name, which works most of the time
sub new {
	my $proto = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $class = ref($proto) || $proto;

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
	my $info = $args{info} || CGI::Info->new();
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
		_table => $args{table},
	}, $class;
}

sub get_file_path {
        my $self = shift;

        my $dir = $self->{_config}->{rootdir} || $self->{_info}->rootdir();
	$dir .= '/files';

	#  Look in .../en/gb/web, then .../en/web then /web
	if($self->{_lingua}) {
		my $lingua = $self->{_lingua};
		my $candidata;
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

        my $filename;

	if($self->{_table}) {
		$filename = $self->{_table};
	} else {
		$filename = ref($self);
	}
	$filename =~ s/::/\//g;
	$filename = "$dir/$filename.conf";

	if((!-f $filename) || (!-r $filename)) {
		die "Can't open $filename";
		return;
	}
	return $filename;
}

sub columns {
	my $self = shift;

	$self->load_data();

	return $self->{_columns};
}

sub fetch {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	$self->load_data();

	my $key = $args{key};
	unless($key) {
		# Return all the data as an array of hashes
		return $self->{_data_as_array};
	}
	# Return just one hash
	return $self->{_data_as_hash}->{$key};
}

sub fetch_as_hash {
	my $self = shift;

	$self->load_data();

	return $self->{_data_as_hash};
}

sub load_data {
	my $self = shift;

	if($self->{_data_as_array} && $self->{_data_as_hash}) {
		return;
	}
	my $filename = $self->get_file_path();
	unless(-r $filename) {
		die "$filename: $!";
	}
	# Slurp it all in, it won't be that big
	# Remove comments and empty lines
	my $in = join('', grep(!/^\s*(#|$)/, read_file($filename)));

	my $data = xsv_slurp(
		shape => 'aoh',
		text_csv => {
			sep_char => '!',
			allow_loose_quotes => 1,
			blank_is_undef => 1,
			empty_is_undef => 1,
		},
		string => \$in
	);
	$self->{_data_as_array} = $data;

	# Create list of columns
	my $first = $self->{_data_as_array}[0];

	my @column_names = keys(%{$first});
	$self->{_columns} = \@column_names;

	$data = xsv_slurp(
		shape => 'hoh',
		# FIXME: RT79478
		# key => $column_names[0],
		key => 'key',
		text_csv => {
			sep_char => '!',
			allow_loose_quotes => 1,
			blank_is_undef => 1,
			empty_is_undef => 1,
		},
		string => \$in
	);

	$self->{_data_as_hash} = $data;
}

# sub AUTOLOAD {
	# my $self = shift;
	# my $type = ref($self) or die "$self is not an object";
# 
	# my $name = $AUTOLOAD;
	# $name =~ s/.*://;   # strip fully-qualified portion
# 
	# if($name eq 'DESTROY') {
		# return;
	# }
# 
	# $self->load_data();
# 
# warn $name;
# 
	# # unless (exists $self->{_permitted}->{$name} ) {
		# # croak "Can't access `$name' field in class $type";
	# # }
# 
	# # if (@_) {
		# # return $self->{$name} = shift;
	# # } else {
		# # return $self->{$name};
	# # }
# }

1;
