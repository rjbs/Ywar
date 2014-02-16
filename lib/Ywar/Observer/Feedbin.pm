use 5.14.0;
package Ywar::Observer::Feedbin;
use Moose;

use DateTime::Format::ISO8601;
use JSON 2;
use LWP::UserAgent;
use Ywar::Util qw(not_today);

has auth => (is => 'ro', required => 1);

sub did_reading {
  my ($self, $laststate) = @_;

  # Recorded is the number of items that were one days old yesterday.
  # The goal is to have nothing unread over 24 hours old.
  my $ua   = LWP::UserAgent->new(keep_alive => 1);
  my $JSON = JSON->new;

  my $auth = $self->auth;

  my $per_page = 50;
  my $page_num = 1;

  my @entries;
  my $next_page = sub {
    return if state $exhausted;

    my $uri = "https://api.feedbin.me/v2/entries.json"
            . "?read=false&per_page=$per_page&page=$page_num";
    my $res = $ua->get($uri, 'Authorization' => "Basic $auth");

    unless ($res->is_success) {
      warn "failed to get feeds from Feedbin: " . $res->status_line . "\n";
      $exhausted = 1;
      return;
    }

    $page_num++;
    my $json = $res->decoded_content;
    my $data = $JSON->decode($json);
    push @entries, @$data;
    $exhausted = 1 unless @$data == $per_page;
    return @$data;
  };

  my $nonrecent = 0;
  while (my @entries = $next_page->()) {
    for my $e (@entries) {
      my $date = DateTime::Format::ISO8601->parse_datetime($e->{published});
      next if $date->epoch >= $^T - 86_400;
      $nonrecent++;
    }
    last if $nonrecent;
  }

  return {
    # We only get enough pages to answer the question atm, so we do not have
    # all the stats we suggest in this note: -- rjbs, 2013-10-28
    note  => sprintf("at least %s old unread items", $nonrecent),
    value    => $nonrecent,
    met_goal => $nonrecent <= 10 && not_today($laststate->completion),
  };
}

1;
