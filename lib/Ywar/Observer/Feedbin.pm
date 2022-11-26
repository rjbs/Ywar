use 5.14.0;
package Ywar::Observer::Feedbin;
use Moose;

use DateTime::Format::ISO8601;
use JSON::XS;
use LWP::UserAgent;
use Ywar::Logger '$Logger';
use Ywar::Util qw(not_today);

has auth => (is => 'ro', required => 1);

sub did_reading {
  my ($self, $laststate) = @_;

  # Recorded is the number of items that were one days old yesterday.
  # The goal is to have nothing unread over 24 hours old.
  my $ua   = LWP::UserAgent->new(keep_alive => 1);
  my $JSON = JSON::XS->new;

  my $auth = $self->auth;

  my $per_page = 50;

  my $uri = "https://api.feedbin.me/v2/entries.json"
          . "?read=false&per_page=$per_page&page=1";

  my @responses;

  my $error;
  my @entries;
  my $next_page = sub {
    return unless $uri;

    $Logger->log_debug([ "fetching $uri" ]);
    my $res = $ua->get($uri, 'Authorization' => "Basic $auth");
    $uri = undef;

    push @responses, $res;

    unless ($res->is_success) {
      warn "failed to get feeds from Feedbin: " . $res->status_line . "\n";
      $error = 1;
      return;
    }

    my $json = $res->decoded_content;
    my $data = $JSON->decode($json);
    push @entries, @$data;

    if (my $links = $res->header('Links')) {
      my ($wanted) = grep { /rel="next"/ } split /,/, $links;
      ($uri) = ($wanted // '') =~ /<([^>]+)>/;
    }

    return @$data;
  };

  my $nonrecent = 0;
  my $total     = 0;
  while (my @entries = $next_page->()) {
    for my $e (@entries) {
      my $date = DateTime::Format::ISO8601->parse_datetime($e->{published});
      $total++;
      next if $date->epoch >= $^T - 86_400;
      $nonrecent++;
    }
  }

  if ($error) {
    die "got errors from Feedbin when retrieving entries\n";
  }

  if ($total == 0) {
    open my $logfile, '>>', "/home/rjbs/log/ywar/0-items"
      or die "can't write to 0-items: $!";
    print { $logfile } "----> " . scalar(localtime) . "\n";
    for my $res (@responses) {
      print { $logfile } $res->as_string;
    }
  }

  $Logger->log_debug([ "Feedbin items: %s total, %s nonrecent", $total, $nonrecent ]);

  return {
    # We only get enough pages to answer the question atm, so we do not have
    # all the stats we suggest in this note: -- rjbs, 2013-10-28
    note  => sprintf("at least %s old unread items", $nonrecent),
    value    => $nonrecent,
    met_goal => $nonrecent <= 10 && not_today($laststate->completion),
  };
}

1;
