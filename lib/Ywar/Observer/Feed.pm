use 5.14.0;
package Ywar::Observer::Feed;
use Moose;

use XML::Feed;
use URI;
use List::Util 'first';

## I think the logic of this observer seems wrongheaded.  It should probably
## say met_goal whenever a new post is made on a new day, and care nothing
## about the interval length, which is TDP's job. -- rjbs, 2014-02-15

sub did_post {
  my ($self, $laststate, $args) = @_;

  my $feed = XML::Feed->parse(URI->new($args->{url}))
    or die XML::Feed->errstr;

  my $most_recent = first { $_ }
    reverse
    sort { $a->issued <=> $b->issued }
    $feed->entries;

  my $day = 24 * 60 * 60;
  my $days_since_last_post = int(
    (DateTime->now->epoch - $most_recent->issued->epoch) / $day
  );

  return {
    note => "blogged: " . $most_recent->title . ' (' . $most_recent->link . ')',
    value => $days_since_last_post,
    met_goal => $days_since_last_post < 1 ? 1 : 0,
  };
}

1;

