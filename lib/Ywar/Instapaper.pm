use 5.16.0;
use warnings;

use JSON;
use LWP::Authen::OAuth;
use Ywar::Config;

sub bookmark_list {
  my $c_key     = Ywar::Config->config->{Instapaper}{consumer_key};
  my $c_secret  = Ywar::Config->config->{Instapaper}{consumer_secret};

  my $ua = LWP::Authen::OAuth->new(
   oauth_consumer_secret => $c_secret,
   oauth_token           => Ywar::Config->config->{Instapaper}{oauth_token},
   oauth_token_secret    => Ywar::Config->config->{Instapaper}{oauth_token_secret},
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
