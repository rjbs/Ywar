use 5.14.0;
package Ywar::Observer::RunKeeper;
use Moose;

use DateTime::Format::HTTP;
use JSON;
use LWP::UserAgent;
use Time::Duration;
use Ywar::Util qw(not_today);

has token => (is => 'ro', required => 1);

sub worked_out {
  my ($self, $laststate) = @_;

  # Recorded is the epoch sec. of the last activity.
  my $ua   = LWP::UserAgent->new(keep_alive => 1);
  my $JSON = JSON->new;

  my $token = $self->token;

  my $uri = "https://api.runkeeper.com/fitnessActivities";
  my $res = $ua->get($uri, 'Authorization' => "Bearer $token");

  unless ($res->is_success) {
    warn "failed to get activity from RunKeeper: " . $res->status_line . "\n";
    return;
  }

  my $json = $res->decoded_content;
  my $data = $JSON->decode($json);

  my @activities;
  my $most_recent;
  for my $item (@{ $data->{items} }) {
    next unless $item->{duration} >= 1800;
    next if $item->{type} eq 'Walking'; # No. -- rjbs, 2014-10-02

    my $dt = DateTime::Format::HTTP->parse_datetime($item->{start_time}, 'UTC');
    $item->{start_time} = $dt;

    $most_recent ||= $item;
    last unless $item->{start_time}->epoch > $laststate->completion->{measured_at};
    push @activities, $item;
  }

  unless ($most_recent) {
    # warn "got an empty activity feed from RunKeeper";
    return;
  }

  my $string =
    join q<; >,
    map {; $_->{type} . q<, > .  concise(duration($_->{duration}, 1)) }
    (@activities ? @activities : $most_recent);

  my %result = (
    met_goal => @activities && not_today($laststate->completion),
    value    => $most_recent->{start_time}->epoch,
    note     => $string,
  );

  return \%result;
}

1;
