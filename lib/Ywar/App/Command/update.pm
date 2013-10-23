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
use Ywar::Instapaper;

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

sub debug { return unless $OPT->debug; STDERR->say(@_) }

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

  # 335 - do work on RT tickets
  CODEREVIEW: {
    my $most_recent = most_recent_measurement('tickets');

    skip_unless_known('tickets', $most_recent);

    # https://api.github.com/repos/rjbs/misc/contents/code-review.mkdn
    # http://developer.github.com/v3/repos/contents/#get-contents

    my $fn = q{code-review.mkdn};
    last unless my $json = get("https://api.github.com/repos/rjbs/misc/contents/$fn");
    my $data = JSON->new->decode($json);

    my $sha = $data->{sha};
    warn("can't figure out sha of $fn"), last unless defined $sha;

    last if $sha eq $most_recent->{measured_value};

    complete_goal(335, "latest sha: $sha", $most_recent); # could be better
    save_measurement('tickets', $sha, $most_recent);
  }

  # 49957 - close some github issues
  ISSUES: {
    last; # not implemented yet
    my $most_recent = most_recent_measurement('github.issues');

    skip_unless_known('github.issues', $most_recent);

    my $pithub = Pithub->new(
      user  => Ywar::Config->config->{GitHub}{user},
      token => Ywar::Config->config->{GitHub}{token},
      auto_pagination => 1,
    );

    my $repos = $pithub->issues->list(params => { filter => 'all' });

    my $owned_14 = 0;
    my $owned_15 = 0;

    my @issues;
    while ( my $issue = $repos->next ) {
      next unless $issue->{repository}{owner}{id} == 30682;

      my $date = DateTime::Format::ISO8601->parse_datetime($issue->{created_at})
                                          ->epoch;

      my $diff = $^T - $date;

      next if $diff < 14 * 86_400;
      $owned_14++;

      next if $diff < 15 * 86_400;
      $owned_15++;
    }

    if (my $diff = $most_recent->{measured_value} - $owned_15) {
      complete_goal(49957, "closed: $diff", $most_recent);
    }
    save_measurement('github.issues', $owned_14, $most_recent);
  }

  # 49985 - step on the scale
  SCALE: {
    last; # not implemented yet
    my $most_recent = most_recent_measurement('weight.measured');

    skip_unless_known('weight.measured', $most_recent);

    my $client = Net::OAuth::Client->new(
      Ywar::Config->config->{Withings}{api_key},
      Ywar::Config->config->{Withings}{secret},
      site => 'https://oauth.withings.com/',
      request_token_path => '/account/request_token',
      authorize_path => '/account/authorize',
      access_token_path => '/account/access_token',
      callback => 'oob',
    );

    my $userid = Ywar::Config->config->{Withings}{userid};

    my $access_token = Net::OAuth::AccessToken->new(
      client => $client,
      token  => Ywar::Config->config->{Withings}{token},
      token_secret => Ywar::Config->config->{Withings}{tsecret},
    );

    my $start_o_day = DateTime->today(time_zone => 'America/New_York')
                    ->epoch;

    my $res = $access_token->get(
      "http://wbsapi.withings.net/measure"
      . "?action=getmeas&startdate=$start_o_day&userid=$userid"
    );

    my $payload = JSON->new->decode($res->decoded_content);
    my @groups  = @{ $payload->{body}{measuregrps} };

    last unless @groups;

    my $latest = $groups[-1]; # rarely more than one, right?
    my ($meas) = grep { $_->{type} == 1 } @{ $latest->{measures} };

    unless ($meas) { warn "no weight today!\n"; last }

    my $kg = $meas->{value} * (10 ** $meas->{unit});
    my $lb = $kg * 2.2046226;

    complete_goal(49985, "weighed in at $lb", $most_recent); # could be better
    save_measurement('weight.measured', $lb, $most_recent);
  }

  # 37752 - write an opening sentence
  OPENER: {
    my $most_recent = most_recent_measurement('writing.openers');

    skip_unless_known('writing.openers', $most_recent);

    my $count = grep { -f $_ } </home/rjbs/Dropbox/writing/openers/*>;

    my $last = $most_recent->{measured_value};
    warn "fewer openers today ($count) than last time ($last)\n"
      if $count < $last;

    last if $count == $last;

    complete_goal(37752, "openers written: $count", $most_recent);
    save_measurement('writing.openers', $count, $most_recent);
  }

  my $rtm_ua = WebService::RTMAgent->new;
  $rtm_ua->api_key( Ywar::Config->config->{RTM}{api_key} );
  $rtm_ua->api_secret( Ywar::Config->config->{RTM}{api_secret} );
  $rtm_ua->init;

  OVERDUE: {
    my $res = $rtm_ua->tasks_getList(
      'filter=status:incomplete AND dueBefore:today'
    );

    unless ($res) {
      warn "RTM API error: " . $rtm_ua->error;
      last OVERDUE;
    }

    my $count = @{ $res->{tasks}[0]{list} || [] };

    my $most_recent = most_recent_measurement('rtm.overdue');

    skip_unless_known('rtm.overdue', $most_recent);

    if ($count == 0) {
      complete_goal(47355, "overdue items: $count", $most_recent);
    }

    save_measurement('rtm.overdue', $count, $most_recent);
  }

  RTMPROGRESS: {
    my $most_recent = most_recent_measurement('rtm.progress');
    skip_unless_known('rtm.progress', $most_recent);

    my %count;

    for my $age (
      [ last  => $most_recent->{measured_at} ],
      [ today => $^T ],
    ) {
      my $date = DateTime->from_epoch(epoch => $age->[1])
                         ->subtract(days => 14)
                         ->format_cldr("yyyy-MM-dd");

      my $filter = "status:incomplete AND addedBefore:$date"
                 . " AND due:never AND NOT tag:nag";

      my $res = $rtm_ua->tasks_getList("filter=$filter");

      unless ($res) {
        warn "RTM API error: " . $rtm_ua->error;
        last RTMPROGRESS;
      }

      my @series = @{ $res->{tasks}[0]{list} || [] };
      $count{ $age->[0] } = sum0 map {; scalar @{ $_->{taskseries} } } @series;
    }

    my $last = $most_recent->{measured_value};

    if ($count{last} == 0 || $count{last} < $last) {
      my $closed = $last - $count{last};
      complete_goal(47730, "items closed: $closed", $most_recent);
    }

    save_measurement('rtm.progress', $count{today}, $most_recent);
  }

  INSTAPROGRESS: {
    my $most_recent = most_recent_measurement('instapaper.progress');
    skip_unless_known('instapaper.progress', $most_recent);

    # Recorded is the number of items that were 14 days old yesterday.  The
    # number of items 15 days old today should be fewer.
    my %count;

    my @bookmarks = Ywar::Instapaper->bookmark_list;

    my $old_14 = grep { $_->{time} < $^T - 14 * 86_400 } @bookmarks;
    my $old_15 = grep { $_->{time} < $^T - 15 * 86_400 } @bookmarks;

    my $last = $most_recent->{measured_value};
    if ($old_15 < $last) {
      my $closed = $last - $old_15;
      complete_goal(49692, "items read (or deleted): $closed", $most_recent);
    }

    save_measurement('instapaper.progress', $old_14, $most_recent);
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
