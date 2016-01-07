package VWF::DB;

use warnings;

use File::Glob;
use File::Basename;
use DBI;

our @databases;
our $directory;

sub new {
	my $proto = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $class = ref($proto) || $proto;

	init(\%args);

	return bless { logger => $args{'logger'} }, $class;
}

# Can also be run as a class level VWF::DB::init(directory => '../databases')
sub init {
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	$directory ||= $args{'directory'};
	throw Error::Simple('directory not given') unless($directory);
}

sub _open {
	my $self = shift;

	my $table = ref($self);
	$table =~ s/.*:://;

	return if($self->{table});

	# Read in the databases
	my $dbh = DBI->connect('dbi:CSV:csv_sep_char=!');
	$dbh->{'RaiseError'} = 1;

	my $slurp_file = "$directory/$table.db";

	unless(-r $slurp_file) {
		throw Error::Simple("Can't open $slurp_file");
	}

	if($self->{'logger'}) {
		$self->{'logger'}->debug("read in $table from $slurp_file");
	}

	$dbh->{csv_tables}->{$table} = {
		allow_loose_quotes => 1,
		blank_is_undef => 1,
		empty_is_undef => 1,
		binary => 1,
		f_file => $slurp_file,
	};

	push @databases, $table;

	$self->{$table} = $dbh;
}

# Returns a reference to an array of hash references of all the data meeting
# the given criteria
sub selectall_hashref {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $table = ref($self);
	$table =~ s/.*:://;

	$self->_open() if(!$self->{$table});

	my $query = "SELECT * FROM $table WHERE entry IS NOT NULL AND entry NOT LIKE '#%'";
	my @args;
	foreach my $c1(keys(%args)) {
		$query .= " AND $c1 LIKE ?";
		push @args, $args{$c1};
	}
	$query .= ' ORDER BY entry';
	my $sth = $self->{$table}->prepare($query);
	$sth->execute(@args) || throw Error::Simple($query);
	my @rc;
	while (my $href = $sth->fetchrow_hashref()) {
		push @rc, $href;
	}

	return \@rc;
}

# Returns a hash reference for one row in a table
sub fetchrow_hashref {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $table = ref($self);
	$table =~ s/.*:://;

	$self->_open() if(!$self->{table});

	my $query = "SELECT * FROM $table WHERE entry IS NOT NULL AND entry NOT LIKE '#%'";
	my @args;
	foreach my $c1(keys(%args)) {
		$query .= " AND $c1 LIKE ?";
		push @args, $args{$c1};
	}
	$query .= ' ORDER BY entry';
	my $sth = $self->{$table}->prepare($query);
	$sth->execute(@args) || throw Error::Simple($query);
	return $sth->fetchrow_hashref();
}

# Returns an array of the matches
sub AUTOLOAD {
	my $column = $AUTOLOAD;

	$column =~ s/.*:://;

	return if($column eq 'DESTROY');

	my $self = shift;

	if(!defined(wantarray)) {
		throw Error::Simple("$self->$column called in scalar context");
	}

	my $table = ref($self);
	$table =~ s/.*:://;

	$self->_open() if(!$self->{$table});

	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $query = "SELECT DISTINCT $column FROM $table WHERE entry IS NOT NULL AND entry NOT LIKE '#%'";
	my @args;
	foreach my $c1(keys(%args)) {
		# $query .= " AND $c1 LIKE ?";
		$query .= " AND $c1 = ?";
		push @args, $args{$c1};
	}
	$query .= ' ORDER BY entry';
	my $sth = $self->{$table}->prepare($query);
	$sth->execute(@args) || throw Error::Simple($query);

	return map { $_->[0] } @{$sth->fetchall_arrayref()};
}

1;
