use 5.14.0;
package Ywar::Observer::Instapaper;
use Moose;

use Ywar::Instapaper;
use Ywar::Util qw(not_today);

has [ qw( consumer_key consumer_secret oauth_token oauth_token_secret ) ] => (
  is => 'ro',
  required => 1,
);

sub did_reading {
  my ($self, $laststate) = @_;

  # Recorded is the number of items that were 14 days old yesterday.  The
  # number of items 15 days old today should be fewer.
  my %count;

  # stupid passing of $self is a temporary situation -- rjbs, 2013-11-04
  my @bookmarks = Ywar::Instapaper->bookmark_list($self);

  my $old_14 = grep { $_->{time} < $^T - 14 * 86_400 } @bookmarks;
  my $old_15 = grep { $_->{time} < $^T - 15 * 86_400 } @bookmarks;

  my $last = $laststate->yesterday_value->{measured_value};

  my %result;

  if ($old_15 < $last) {
    my $closed = $last - $old_15;
    $result{note} = "items read (or deleted): $closed";
    $result{met_goal} = not_today($laststate->completion);
  }

  $result{value} = $old_14;

  return \%result;
}

1;
