package VWF::DB;

my $dbh;

BEGIN {
	if($directory) {
		die($directory);
	}
}

sub new {
	my $proto = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $class = ref($proto) || $proto;

	if($dbh) {
		return bless { dbh => $dbh }, $class;
	}

	init(\%args);

	return bless { dbh => $dbh }, $class;
}

# Can also be run as a class level VWF::DB::init(args)
sub init {
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	die 'databases list not given' unless($args{'databases'});
	die 'directory not given' unless($args{'directory'});

	my $directory = $args{'directory'};

	# Read in the databases
	$dbh = DBI->connect('dbi:CSV:csv_sep_char=!');
	$dbh->{'RaiseError'} = 1;

	foreach my $db(@{$args{'databases'}}) {
		my $table = $db;
		$table =~ tr/-/_/;

		my $slurp_file = "$directory/../databases/$db.db";
		unless(-r $slurp_file) {
			die "Can't open $slurp_file";
		}

		if($args{'logger'}) {
			$args{'logger'}->debug("read in $table from $slurp_file");
		}

		$dbh->{csv_tables}->{$table} = {
			allow_loose_quotes => 1,
			blank_is_undef => 1,
			empty_is_undef => 1,
			binary => 1,
			f_file => $slurp_file,
		};
	}
}

# Returns a reference to an array of hash references of all the data
sub selectall_hashref {
	my $self = shift;

	my $table = ref($self);
	$table =~ s/.*:://;

	my $sth = $dbh->prepare("SELECT * FROM $table WHERE name IS NOT NULL AND name NOT LIKE '#%'");
	$sth->execute() || die "$table->selectall_hashref";
	my @rc;
	while (my $href = $sth->fetchrow_hashref()) {
		push @rc, $href;
	}

	return \@rc;
}

sub AUTOLOAD {
	my $column = $AUTOLOAD;

	$column =~ s/.*:://;

	return if($column eq 'DESTROY');

	my $self = shift;

	my $table = ref($self);
	$table =~ s/.*:://;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $query = "SELECT DISTINCT $column FROM $table WHERE name IS NOT NULL AND name NOT LIKE '#%'";
	my @args;
	foreach my $c1(keys(%args)) {
		$query .= " AND $c1 LIKE ?";
		push @args, $args{$c1};
	}
	my $sth = $self->{'dbh'}->prepare($query);
	$sth->execute(@args);

	return map { $_->[0] } @{$sth->fetchall_arrayref()};
}

1;
