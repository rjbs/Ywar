use 5.34.0;
package Ywar::Observer::Dropbox;
use Moose;

use WebService::Dropbox;
use Ywar::Logger '$Logger';
use Ywar::Util qw(not_today);

has [ qw( api_key api_secret refresh_token ) ] => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has dropbox => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my ($self) = @_;

    my $dropbox = WebService::Dropbox->new({
      key     => $self->api_key,
      secret  => $self->api_secret,
    });

    $dropbox->refresh_access_token($self->refresh_token);

    return $dropbox;
  },
);

sub file_count_went_down {
  my ($self, $laststate, $arg) = @_;

  my $dropbox = $self->dropbox;
  my $files = 0;

  for my $root ($arg->{roots}->@*) {
    my $done = 0;

    my $page = $dropbox->list_folder(
      '/to-upload/images',
      { recursive => \1 },
    );

    until ($done) {
      die $dropbox->errstr unless $page;

      my @entries = $page->{entries}->@*;

      $files += grep {; $_->{'.tag'} eq 'file' } @entries;

      $done = ! $page->{has_more};

      $page = $dropbox->list_folder_continue($page->{cursor});
    }
  }

  my $last  = $laststate->completion->{measured_value};

  $Logger->log_debug("last good file count: $last; current count: $files");

  my $fewer = $files < $last || $files == 0;

  my $note  = $last  > $files ? "files cleared: " . ($last - $files)
            : $last == $files ? "no change"
            :                   "files added: " . ($files - $last);

  return {
    value    => $files,
    met_goal => $fewer && not_today($laststate->completion),
    note     => $note,
  };
}

1;
