use 5.16.0;
use warnings;
package Ywar::Maildir;

use PIR;
use File::Find::Rule;
use List::AllUtils qw(minmax sum0);

use Sub::Exporter -setup => [ qw(
  find_maildirs_in
  summarize_maildir
  sum_summaries
) ];

my $READ    = qr/,\w*S\w*\z/a;
my $FLAGGED = qr/,\w*F\w*\z/a;

sub find_maildirs_in {
  my $root = $_[0];

  return PIR->new
            ->directory
            ->max_depth(1)
            ->and(sub { -d "$_/new" })
            ->all($root);
}

sub summarize_maildir {
  my ($dir, $root) = @_;

  my @files = PIR->new
                 ->max_depth(2)
                 ->file
                 ->and(sub { m{/(?:new|cur)/} && (! /$READ/ || /$FLAGGED/); })
                 ->all_fast($dir);

  return unless @files;

  my %result;

  my $name = $dir;
  $name =~ s{\Q$root\E(?:/(?:\.)?)?}{/INBOX/};
  $name =~ tr|.|/|;
  $name = '/INBOX' if $name eq '/INBOX/INBOX' or $name eq '/INBOX/';
  $result{name} = $name;

  $result{messages} = { map {; $_ => {
    file    => $_,
    age     => ($^T - (stat $_)[9]),
    unread  => ($_ =~ $READ    ? 0 : 1),
    flagged => ($_ =~ $FLAGGED ? 1 : 0),
  } } @files };

  for my $which (qw(unread flagged)) {
    $result{"$which\_count"} = grep { $_->{$which} }
                               values %{ $result{messages} };
  }

  $result{total_count} = @files;

  @result{qw(latest oldest)} = minmax map {; $_->{age} }
                                      values %{ $result{messages} };

  return \%result;
}

sub sum_summaries {
  my ($summaries) = @_;

  my %result = (
    unread_count  => 0,
    flagged_count => 0,
  );

  for my $summary (@$summaries) {
    for my $key (keys %result) {
      $result{$key} += $summary->{$key};
    }
  }

  $result{maildir} = {};
  for my $summary (@$summaries) {
    my $name = $summary->{name};
    die "two summaries for $name!\n" if $result{maildir}{$name};
    $result{maildir}{$name} = $summary;
  }

  return \%result;
}

1;
