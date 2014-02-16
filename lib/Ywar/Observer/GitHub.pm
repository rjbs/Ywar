use 5.14.0;
package Ywar::Observer::GitHub;
use Moose;

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

  my $repos = $self->pithub->issues->list(params => { filter => 'all' });

  my $owned_14 = 0;
  my $owned_15 = 0;

  my @issues;
  while ( my $issue = $repos->next ) {
    next unless $issue->{repository}{owner}{id} == $self->userid;

    my $date = DateTime::Format::ISO8601->parse_datetime($issue->{created_at})
                                        ->epoch;

    my $diff = $^T - $date;

    next if $diff < 14 * 86_400;
    $owned_14++;

    next if $diff < 15 * 86_400;
    $owned_15++;
  }

  my %result = (value => $owned_14);

  if (my $diff = $laststate->completion->{measured_value} - $owned_15) {
    $result{note} = "closed: $diff";
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
