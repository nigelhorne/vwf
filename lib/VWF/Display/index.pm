package VWF::Display::index;

# Display the index page

use VWF::Display::page;

our @ISA = ('VWF::Display::page');

sub html {
	my $self = shift;
	my %args = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	my $info = $self->{_info};
	my $allowed = {
		'person' => undef,
	};
	my $params = $info->params({ allowed => $allowed });
	my $index = $args{'index'};	# Handle into the database

	# Look in the index.db for the name given as the CGI arument and
	# find their e-mail address
	my $to = ($index->email({ entry => $info->person() }))[0];

	# Insert code here to error if $to isn't defined

	open(my $fout, '|-', '/usr/sbin/sendmail -t');

	print $fout "To: $to\n",
		"From: webmaster\n",
		"Subject: VWF sending an e-mail\n\n",
		"Hello, world\n";

	close $fout;

	if($self->{_logger}) {
		$self->{_logger}->trace("E-mail sent to $to");
	}

	return $self->SUPER::html({ action => 'sent' });
}

1;
