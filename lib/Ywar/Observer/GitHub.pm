use 5.14.0;
package Ywar::Observer::GitHub;
use Moose;

use Pithub;

has pithub => (
  is   => 'ro',
  isa  => 'Pithub',
  lazy => 1,
  default => sub {
    Pithub->new(
      user  => Ywar::Config->config->{GitHub}{user},
      token => Ywar::Config->config->{GitHub}{token},
      auto_pagination => 1,
    );
  },
);

sub closed_issues {
  my ($self, $prev) = @_;

  my $repos = $self->pithub->issues->list(params => { filter => 'all' });

  my $owned_14 = 0;
  my $owned_15 = 0;

  my @issues;
  while ( my $issue = $repos->next ) {
    next unless $issue->{repository}{owner}{id}
                == Ywar::Config->config->{GitHub}{userid};

    my $date = DateTime::Format::ISO8601->parse_datetime($issue->{created_at})
                                        ->epoch;

    my $diff = $^T - $date;

    next if $diff < 14 * 86_400;
    $owned_14++;

    next if $diff < 15 * 86_400;
    $owned_15++;
  }

  my %result = (value => $owned_14);

  if (my $diff = $prev->{measured_value} - $owned_15) {
    @result{ qw(note met_goal) } = ("closed: $diff", 1);
  }

  return \%result;
}

1;
