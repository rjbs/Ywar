use 5.14.0;
package Ywar::Observer::GitHub;
use Moose;

use DateTime;
use Pithub;
use Ywar::Util qw(not_today);

has pithub => (
  is   => 'ro',
  isa  => 'Pithub',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    Pithub->new(
      user  => $self->user,
      token => $self->token,
      auto_pagination => 1,
    );
  },
);

has user   => (is => 'ro', required => 1);
has userid => (is => 'ro', required => 1);
has token  => (is => 'ro', required => 1);

sub closed_issues {
  my ($self, $laststate) = @_;

  my $since = DateTime->from_epoch(epoch => $laststate->completion->{measured_at})
                      ->truncate(to => 'day')
                      ->add(days => 1)
                      ->iso8601;

  my $recent = DateTime->now
                       ->truncate(to => 'day')
                       ->subtract(days => 14)
                       ->iso8601;

  my $repos = $self->pithub->issues->list(params => {
    filter => 'all',
    state  => 'closed',
    sort   => 'updated',
    direction => 'desc',
  });

  my @closed;

  ISSUE: while (my $issue = $repos->next) {
    unless (defined $issue->{repository}{owner}{id}) {
      warn("couldn't determine repository owner for issue");
      use Data::Dumper;
      warn Dumper($issue);
      return;
    }

    next unless $issue->{repository}{owner}{id} == $self->userid;

    if ( $issue->{closed_at} eq $issue->{updated_at}
      && $issue->{closed_at} lt $since
    ) {
      last ISSUE;
    }

    # If the issue was created recently, we don't count closing it as much of
    # an achievement.  Maybe this is still, but it's the deal.
    if ($issue->{created_at} gt $recent) {
      warn "skipping issue, $issue->{created_at} too recent\n";
      next;
    }

    my @bits = split m{/}, $issue->{repository_url};
    my $id   = join q{!}, "$bits[-2]/$bits[-1]", $issue->{number};
    push @closed, $id;
  }

  @closed = sort @closed;

  my %result = (value => 0+@closed);

  if (@closed > 0) {
    $result{note} = "closed: @closed";
    $result{met_goal} = not_today($laststate->completion);
  }

  return \%result;
}

sub file_sha_changed {
  my ($self, $laststate, $arg) = @_;
  my ($user, $repo, $path) = @$arg{ qw(user repo path) };

  my $contents = $self->pithub->repos->contents->new(
    user => $user,
    repo => $repo,
  );

  my $new_sha = $contents->get(path => $path)->first->{sha};

  unless (defined $new_sha) {
    warn "got an undef sha for $path, giving up";
    return;
  }

  return {
    note     => "latest sha: $new_sha",
    value    => $new_sha,
    met_goal => (
      not_today($laststate->completion)
      && $new_sha ne $laststate->completion->{measured_value},
    ),
  }
}

sub branch_sha_changed {
  my ($self, $laststate, $arg) = @_;
  my ($user, $repo, $branch_name) = @$arg{ qw(user repo branch) };

  my $branch_iter = $self->pithub->repos->branches(
    user => $user,
    repo => $repo,
  );

  my $branch = { name => "\0" };
  $branch = $branch_iter->next
    until ! defined $branch or $branch->{name} eq $branch_name;

  warn "can't find requested branch: $user/$repo/$branch_name", return
    unless $branch;

  my $new_sha = $branch->{commit}{sha};

  return {
    note     => "latest sha: $new_sha",
    value    => $new_sha,
    met_goal => (
      not_today($laststate->completion)
      && $new_sha ne $laststate->completion->{measured_value},
    ),
  }
}

1;
