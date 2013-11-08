use 5.14.0;
package Ywar::Observer::Maildir;
use Moose;

use Ywar::Maildir -all;

sub max { (sort { $b <=> $a } @_)[0] }

has root => (is => 'ro', required => 1);

has stats => (
  is   => 'ro',
  isa  => 'HashRef',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    my $ROOT = $self->root;
    my @dirs  = grep { ! /spam\.[0-9]{4}/ } find_maildirs_in($ROOT);
    my $stats = sum_summaries([ map {; summarize_maildir($_, $ROOT) } @dirs ]);
  },
);

sub decreasing_flagged_mail {
  my ($self, $prev) = @_;
  # flagged mail should be less than it was last time, or <10

  my %result = (value => $self->stats->{flagged_count});

  if ($result{value} < max($prev->{measured_value}, 10)) {
    @result{qw(met_goal note)} = (1, "new count: $result{value}");
  }

  return \%result;
}

sub decreasing_unread_mail {
  my ($self, $prev) = @_;
  # unread mail should be less than it was last time, or <25

  my %result = (value => $self->stats->{unread_count});

  if ($result{value} < max($prev->{measured_value}, 25)) {
    @result{qw(met_goal note)} = (1, "new count: $result{value}");
  }

  return \%result;
}

sub folder_old_unread {
  my ($self, $prev, $arg) = @_;
  my $folder = $arg->{folder};
  my $age    = $arg->{age};

  my $maildir = $self->stats->{maildir}{ $folder } || {};

  my @all_unread = grep { $_->{unread} } values %{ $maildir->{messages} };
  my $old_unread = grep { $_->{age} > $age } @all_unread;

  my %result = (
    value => 0+@all_unread,
    note  => sprintf(
      "unread mail: %s; old unread: %s", 0+@all_unread, $old_unread,
    ),
  );

  if ($old_unread == 0 or $old_unread <= $prev->{measured_value}) {
    $result{met_goal} = 1;
  }

  return \%result;
}

1;
