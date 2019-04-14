use 5.14.0;
package Ywar::Observer::RTM;
use Moose;

use DateTime::Format::ISO8601;
use List::Util qw(sum0);
use WebService::RTMAgent;
use Ywar::Logger '$Logger';
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

  # This is a stupid hack. -- rjbs, 2019-02-25
  my $yesterday_14 = $laststate->yesterday_value
                   ? $laststate->yesterday_value->{measured_value}
                   : 0;

  my $old_date = DateTime->today(time_zone => Ywar::Config->time_zone)
                         ->subtract(days => 14);

  my $filter = "status:incomplete AND addedBefore:"
             . $old_date->format_cldr('yyyy-MM-dd')
             . " AND due:never AND NOT tag:nag";

  my $res = $self->rtm_ua->tasks_getList("filter=$filter");

  unless ($res) {
    warn "RTM API error: " . $self->rtm_ua->error;
    return;
  }

  my @tasks = map {; @{ $_->{taskseries} } }
              @{ $res->{tasks}[0]{list} || [] };

  my $today_14 = 0;
  my $today_15 = 0;

  for my $task (@tasks) {
    my $created = DateTime::Format::ISO8601
                    ->parse_datetime($task->{created});

    $today_14++;
    $today_15++ if $created < $old_date;
  }

  my %result = (value => $today_14);

  my $closed = 0;
  if ($today_15 < $yesterday_14) {
    $closed = $yesterday_14 - $today_15;
    $result{note} = "items closed: $closed";
    $result{met_goal} = not_today($laststate->completion);
  }

  $Logger->log("RTM tasks: yesterday's count: $yesterday_14; closed: $closed; today: $today_14");

  return \%result;
}

1;
