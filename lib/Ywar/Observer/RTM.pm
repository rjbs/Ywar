use 5.14.0;
package Ywar::Observer::RTM;
use Moose;

use List::Util qw(sum0);
use WebService::RTMAgent;
use Ywar::Util qw(not_today);

has [ qw(api_key api_secret) ] => (is => 'ro', required => 1);

has rtm_ua => (
  is   => 'ro',
  isa  => 'WebService::RTMAgent',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    my $rtm_ua = WebService::RTMAgent->new;
    $rtm_ua->api_key( $self->api_key );
    $rtm_ua->api_secret( $self->api_secret );
    $rtm_ua->init;
    return $rtm_ua;
  },
);

sub nothing_overdue {
  my ($self, $laststate) = @_;

  my $res = $self->rtm_ua->tasks_getList(
    'filter=status:incomplete AND dueBefore:today'
  );

  unless ($res) {
    warn "RTM API error: " . $self->rtm_ua->error;
    return;
  }

  my $count = @{ $res->{tasks}[0]{list} || [] };

  return {
    value    => $count,
    met_goal => $count == 0 && not_today($laststate->completion),
    note     => "overdue items: $count",
  };
}

sub closed_old_tasks {
  my ($self, $laststate) = @_;

  my %count;

  for my $age (
    [ last  => $laststate->completion->{measured_at} ],
    [ today => $^T ],
  ) {
    my $date = DateTime->from_epoch(epoch => $age->[1])
                       ->subtract(days => 14)
                       ->format_cldr("yyyy-MM-dd");

    my $filter = "status:incomplete AND addedBefore:$date"
               . " AND due:never AND NOT tag:nag";

    my $res = $self->rtm_ua->tasks_getList("filter=$filter");

    unless ($res) {
      warn "RTM API error: " . $self->rtm_ua->error;
      return;
    }

    my @series = @{ $res->{tasks}[0]{list} || [] };
    $count{ $age->[0] } = sum0 map {; scalar @{ $_->{taskseries} } } @series;
  }

  my $last = $laststate->completion->{measured_value};

  my %result = (value => $count{today});

  if ($count{last} == 0 || $count{last} < $last) {
    my $closed = $last - $count{last};
    $result{note} = "items closed: $closed";
    $result{met_goal} = not_today($laststate->completion);
  }

  return \%result;
}

1;
