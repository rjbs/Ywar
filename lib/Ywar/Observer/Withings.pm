use 5.14.0;
package Ywar::Observer::Withings;
use Moose;

use Ywar::Util qw(not_today);

has [ qw(bearer_token) ] => (is => 'ro', required => 1);

sub measured_weight {
  my ($self, $laststate) = @_;

  return unless not_today($laststate->completion);

  my $ua = LWP::UserAgent->new(keep_alive => 2);

  my $start_o_day = DateTime->today(time_zone => Ywar::Config->time_zone)
                  ->epoch;

  my $res = $ua->get(
    "https://wbsapi.withings.net/measure?action=getmeas&meastype=1&category=1&startdate=$start_o_day",
    Authorization => 'Bearer ' . $self->bearer_token,
  );

  die $res->as_string unless $res->is_success;

  my $payload = JSON->new->decode($res->decoded_content);
  my @groups  = @{ $payload->{body}{measuregrps} };

  return unless @groups;

  my $latest = $groups[-1]; # rarely more than one, right?
  my ($meas) = grep { $_->{type} == 1 } @{ $latest->{measures} };

  unless ($meas) { warn "no weight today!\n"; return }

  my $kg = $meas->{value} * (10 ** $meas->{unit});
  my $lb = $kg * 2.2046226;

  return {
    met_goal => 1,
    note     => "weighed in at $lb",
    value    => $lb,
  };
}

1;
