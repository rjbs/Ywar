use 5.14.0;
package Ywar::Observer::Instapaper;
use Moose;

use Ywar::Instapaper;

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

  my $last = $laststate->completion->{measured_value};

  my %result;

  if ($old_15 < $last) {
    my $closed = $last - $old_15;
    @result{ qw(note met_goal) } = ("items read (or deleted): $closed", 1);
  }

  $result{value} = $old_14;

  return \%result;
}

1;
