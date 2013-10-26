use 5.16.0;
use warnings;
use utf8;
package Ywar::App::Command::update;
use Ywar::App -command;

use DateTime;
use DateTime::Duration;
use DateTime::Format::ISO8601;
use DBI;
use Getopt::Long::Descriptive;
use JSON ();
use List::AllUtils 'sum0';
use LWP::Authen::OAuth;
use LWP::UserAgent;
use LWP::Simple qw(get);
use Pithub;
use Net::OAuth::Client;
use Ywar::Maildir -all;
use WebService::RTMAgent;

use Ywar::Config;

sub opt_spec {
  return (
    [ 'debug|d'   => 'debugging output' ],
    [ 'dry-run|n' => 'dry run!' ],
  );
}

my $dsn = Ywar::Config->config->{Ywar}{dsn};
my $dbh = DBI->connect($dsn, undef, undef)
  or die $DBI::errstr;

sub most_recent_measurement {
  my ($thing) = @_;
  return $dbh->selectrow_hashref(
    "SELECT thing_measured, measured_at, measured_value
    FROM lifestats
    WHERE thing_measured = ?
    ORDER BY measured_at DESC",
    undef,
    $thing,
  );
}

sub skip_unless_known {
  my ($name, $measurement) = @_;
  no warnings 'exiting';

  unless ($measurement) {
    warn "can't find any previous measurement for $name\n";
    last;
  }
}

sub skip_unless_dayold {
  my ($measurement) = @_;
  no warnings 'exiting';
  return if $^T - $measurement->{measured_at} >= 86_000; # 400s grace
  warn "$measurement->{thing_measured} less than a day old\n";
  last;
}

sub max { (sort { $b <=> $a } @_)[0] }

my $ROOT = Ywar::Config->config->{Maildir}{root};

our $OPT;

use String::Flogger 'flog';
sub debug { return unless $OPT->debug; STDERR->say(flog($_)) for @_ }

sub execute {
  my ($self, $opt, $args) = @_;
  local $OPT = $opt; # XXX <- temporary hack
  my @dirs  = grep { ! /spam\.[0-9]{4}/ } find_maildirs_in($ROOT);
  my $stats = sum_summaries([ map {; summarize_maildir($_, $ROOT) } @dirs ]);

  # flagged mail should be less than it was last time, or <10
  FLAGGED: {
    my $most_recent = most_recent_measurement('mail.flagged');

    skip_unless_known('mail.flagged', $most_recent);

    if ($stats->{flagged_count} < max($most_recent->{measured_value}, 10)) {
      complete_goal(45660, "new count: $stats->{flagged_count}", $most_recent);
    }

    save_measurement('mail.flagged', $stats->{flagged_count}, $most_recent);
  }

  UNREAD: {
    my $most_recent = most_recent_measurement('mail.unread');

    skip_unless_known('mail.unread', $most_recent);

    if ($stats->{unread_count} < max($most_recent->{measured_value}, 25)) {
      complete_goal(333, "new count: $stats->{unread_count}", $most_recent);
    }

    save_measurement('mail.unread', $stats->{unread_count}, $most_recent);
  }

  # 334 - write a journal entry
  JOURNAL: {
    my $most_recent = most_recent_measurement('journal.any');

    skip_unless_known('journal.any', $most_recent);

    my $rubric_dbh = DBI->connect("dbi:SQLite:/home/rjbs/rubric/rubric.db", undef, undef)
      or die $DBI::errstr;

    my $last_post = $rubric_dbh->selectrow_hashref(
      "SELECT title, created
      FROM entries e
      JOIN entrytags et ON e.id = et.entry
      WHERE body IS NOT NULL AND LENGTH(body) > 0 AND tag='journal'
      ORDER BY e.created DESC
      LIMIT 1",
    );

    last unless $last_post && $last_post->{created} > $most_recent->{measured_at};

    complete_goal(334, "latest post: $last_post->{title}", $most_recent);
    save_measurement('journal.any', $last_post->{created}, $most_recent);
  }

  # 37751 - update perlball
  PERLBALL: {
    my $most_recent = most_recent_measurement('p5p.perlball');

    skip_unless_known('p5p.perlball', $most_recent);

    # https://api.github.com/repos/rjbs/perlball/branches
    # http://developer.github.com/v3/repos/#list-branches

    last unless my $json = get('https://api.github.com/repos/rjbs/perlball/branches');
    my $data = JSON->new->decode($json);
    last unless my ($master) = grep {; $_->{name} eq 'master' } @$data;

    my $sha = $master->{commit}{sha};
    warn("can't figure out sha of master"), last unless defined $sha;

    last if $sha eq $most_recent->{measured_value};

    complete_goal(37751, "latest sha: $sha", $most_recent); # could be better
    save_measurement('p5p.perlball', $sha, $most_recent);
  }

  # 325 - review perl.git commits
  P5COMMITS: {
    my $most_recent = most_recent_measurement('p5p.changes');
    skip_unless_known('p5p.changes', $most_recent);

    my $maildir = $stats->{maildir}{'/INBOX/perl/changes'};

    my @all_unread = grep { $_->{unread} } values %{ $maildir->{messages} };
    my $old_unread = grep { $_->{age} > 3*86_400 } @all_unread;

    last if $old_unread;

    my $new_unread = @all_unread;
    complete_goal(325, "waiting to be read: $new_unread", $most_recent);
    save_measurement('p5p.changes', 0, $most_recent);
  }

  # 328 - get p5p unread count for mail >2wk old
  # should be 0 or descending
  P5P: {
    my $most_recent = most_recent_measurement('p5p.unread');
    skip_unless_known('p5p.unread', $most_recent);

    my $maildir = $stats->{maildir}{'/INBOX/perl/p5p'};

    my @all_unread = grep { $_->{unread} } values %{ $maildir->{messages} };
    my $old_unread = grep { $_->{age} > 14*86_400 } @all_unread;
    debug("p5p: old unread: $old_unread, measured: $most_recent->{measured_value}");

    last if $old_unread and $old_unread >= $most_recent->{measured_value};

    my $new_unread = @all_unread;
    complete_goal(328, "waiting to be read: $new_unread", $most_recent);
    save_measurement('p5p.unread', 0, $most_recent);
  }

  {
    require Ywar::Observer::GitHub;
    my $github = Ywar::Observer::GitHub->new;

    # 335 - do work on RT tickets
    CODEREVIEW: {
      my $prev = most_recent_measurement('tickets');
      skip_unless_known('tickets', $prev);
      my $new = $github->file_sha_changed(
        $prev,
        rjbs => misc => 'code-review.mkdn'
      );
      debug('tickets = no measurement'), last unless $new;
      debug('tickets', $prev, $new);
      complete_goal(335, $new->{note}, $prev) if $new->{met_goal};
      save_measurement('tickets', $new->{value}, $prev);
    }

    # 49957 - close some github issues
    ISSUES: {
      my $prev = most_recent_measurement('github.issues');
      skip_unless_known('github.issues', $prev);
      my $new = $github->closed_issues($prev);
      debug('github.issues = no measurement'), last unless $new;
      debug('github.issues', $prev, $new);
      complete_goal(49957, $new->{note}, $prev) if $new->{met_goal};
      save_measurement('github.issues', $new->{value}, $prev);
    }
  }

  # 49985 - step on the scale
  SCALE: {
    require Ywar::Observer::Withings;
    my $prev = most_recent_measurement('weight.measured');
    skip_unless_known('weight.measured', $prev);
    my $new = Ywar::Observer::Withings->measured_weight($prev);
    debug('weight.measured = no measurement'), last unless $new;
    debug('weight.measured', $prev, $new);
    complete_goal(49985, $new->{note}, $prev) if $new->{met_goal};
    save_measurement('weight.measured', $new->{value}, $prev);
  }

  # 37752 - write an opening sentence
  OPENER: {
    require Ywar::Observer::Filesystem;

    my $prev = most_recent_measurement('writing.openers');
    skip_unless_known('writing.openers', $prev);
    my $new = Ywar::Observer::Filesystem->more_files_in_dir(
      $prev,
      '/home/rjbs/Dropbox/writing/openers',
    );
    debug('writing.openers'), last unless $new;
    debug('writing.openers = no measurement'), last unless $new;
    debug('writing.openers', $prev, $new);
    complete_goal(37752, $new->{note}, $prev) if $new->{met_goal};
    save_measurement('writing.openers', $new->{value}, $prev);
  }

  {
    require Ywar::Observer::RTM;
    my $rtm = Ywar::Observer::RTM->new;

    {
      my $prev = most_recent_measurement('rtm.overdue');
      skip_unless_known('rtm.overdue', $prev);
      my $new = $rtm->nothing_overdue($prev);
      debug('rtm.overdue = no measurement'), last unless $new;
      debug('rtm.overdue', $prev, $new);
      complete_goal(47355, $new->{note}, $prev) if $new->{met_goal};
      save_measurement('rtm.overdue', $new->{value}, $prev);
    }

    {
      my $prev = most_recent_measurement('rtm.progress');
      skip_unless_known('rtm.progress', $prev);
      my $new = $rtm->closed_old_tasks($prev);
      debug('rtm.progress = no measurement'), last unless $new;
      debug('rtm.progress', $prev, $new);
      complete_goal(47730, $new->{note}, $prev) if $new->{met_goal};
      save_measurement('rtm.progress', $new->{value}, $prev);
    }
  }

  INSTAPROGRESS: {
    my $prev = most_recent_measurement('instapaper.progress');
    skip_unless_known('instapaper.progress', $prev);
    require Ywar::Observer::Instapaper;
    my $new = Ywar::Observer::Instapaper->new->did_reading($prev);
    debug('instapaper.progress = no measurement'), last unless $new;
    debug('instapaper.progress', $prev, $new);
    complete_goal(49692, $new->{note}, $prev) if $new->{met_goal};
    save_measurement('instapaper.progress', $new->{value}, $prev);
  }
}

sub complete_goal {
  my ($id, $note, $prev) = @_;
  skip_unless_dayold($prev);
  if ($OPT->dry_run) {
    warn "dry run: not completing goal $id ($note)\n";
    return;
  }

  my $res = LWP::UserAgent->new->post(
    "http://tdp.me/v1/goals/$id/completion",
    Content => JSON->new->encode({ note => $note }),
    'Content-type' => 'application/json',
    'X-Access-Token' => Ywar::Config->config->{TDP}{token},
  );

  warn "error completing $id: " . $res->status unless $res->is_success;
}

sub save_measurement {
  my ($thing, $value, $prev) = @_;
  skip_unless_dayold($prev);
  if ($OPT->dry_run) {
    warn "dry run: not really setting $thing to $value\n";
    return;
  }

  return $dbh->selectrow_hashref(
    "INSERT INTO lifestats (thing_measured, measured_at, measured_value)
    VALUES (?, ?, ?)",
    undef,
    $thing, $^T, $value,
  );
}

1;
