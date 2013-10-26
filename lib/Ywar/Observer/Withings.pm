use 5.14.0;
package Ywar::Observer::Withings;
use Moose;

use WebService::RTMAgent;

sub measured_weight {
  my ($self, $prev) = @_;

  my $client = Net::OAuth::Client->new(
    Ywar::Config->config->{Withings}{api_key},
    Ywar::Config->config->{Withings}{secret},
    site => 'https://oauth.withings.com/',
    request_token_path => '/account/request_token',
    authorize_path => '/account/authorize',
    access_token_path => '/account/access_token',
    callback => 'oob',
  );

  my $userid = Ywar::Config->config->{Withings}{userid};

  my $access_token = Net::OAuth::AccessToken->new(
    client => $client,
    token  => Ywar::Config->config->{Withings}{token},
    token_secret => Ywar::Config->config->{Withings}{tsecret},
  );

  my $start_o_day = DateTime->today(time_zone => 'America/New_York')
                  ->epoch;

  my $res = $access_token->get(
    "http://wbsapi.withings.net/measure"
    . "?action=getmeas&startdate=$start_o_day&userid=$userid"
  );

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
