use 5.14.0;
package Ywar::Observer::Feed;
use Moose;

use DateTime;
use List::Util 'first';
use URI;
use XML::Feed;
use Ywar::Util qw(not_today);

sub did_post {
  my ($self, $laststate, $args) = @_;

  my $feed = XML::Feed->parse(URI->new($args->{url}))
    or die XML::Feed->errstr;

  my $most_recent = first { $_ }
    reverse
    sort { $a->issued <=> $b->issued }
    $feed->entries;

  my $previous_post_at = DateTime->from_epoch(
    epoch => $laststate->measurement->{measured_value},
  );

  my $newer = $most_recent->issued > $previous_post_at;

  return {
    note => "latest: " . $most_recent->title . ' (' . $most_recent->link . ')',
    value => $most_recent->issued->epoch,
    met_goal => ($newer && not_today($laststate->completion)) ? 1 : 0,
  };
}

1;
