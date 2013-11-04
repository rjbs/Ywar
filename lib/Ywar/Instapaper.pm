use 5.16.0;
use warnings;
package Ywar::Instapaper;

use JSON;
use LWP::Authen::OAuth;

sub bookmark_list {
  my ($self, $configger) = @_;
  my $c_key     = $configger->consumer_key;
  my $c_secret  = $configger->consumer_secret;

  my $ua = LWP::Authen::OAuth->new(
    oauth_consumer_secret => $c_secret,
    oauth_token           => $configger->oauth_token,
    oauth_token_secret    => $configger->oauth_token_secret,
  );

  my $r = $ua->post(
    'https://www.instapaper.com/api/1/bookmarks/list',
    [
      limit => 200,
      oauth_consumer_key    => $c_key,
    ],
  );

  my @bookmarks = sort {; $a->{time} <=> $b->{time} }
                  grep {; $_->{type} eq 'bookmark' }
                  @{ JSON->new->decode($r->decoded_content) };

  return @bookmarks;
}

1;
