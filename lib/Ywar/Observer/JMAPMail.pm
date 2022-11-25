use 5.36.0;
package Ywar::Observer::JMAPMail;
use Moose;

use JMAP::Tester;
use List::Util qw(sum0);
use Ywar::Util qw(not_today);

sub max { (sort { $b <=> $a } @_)[0] }

has auth_url => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_token => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub _build_mailboxes ($self) {
  my $tester = JMAP::Tester->new({
    authentication_uri => $self->auth_url,
    default_using => [ qw(
      urn:ietf:params:jmap:core
      urn:ietf:params:jmap:mail
    ) ],
  });

  $tester->ua->set_default_header(Authorization => "Bearer " . $self->api_token);

  $tester->update_client_session;

  my $mailbox_res = $tester->request([
    [
      'Mailbox/get',
      {
        accountId   => $tester->primary_account_for('urn:ietf:params:jmap:mail'),
        properties  => [ qw( name role parentId totalThreads unreadThreads ) ],
      }
    ]
  ]);

  return {
    map {; $_->{id} => $_ }
      $mailbox_res->single_sentence('Mailbox/get')->arguments->{list}->@*
  };
};

has _mailboxes => (
  is   => 'ro',
  isa  => 'HashRef',
  lazy => 1,
  builder => '_build_mailboxes',
);

sub mailbox_by_role ($self, $role) {
  my ($mailbox) = grep {; ($_->{role}//'') eq $role }
                  values $self->_mailboxes->%*;

  return $mailbox;
}

sub mailbox_by_path ($self, $path) {
  # Derp. -- rjbs, 2022-11-24
  return undef unless @$path;

  my @mailboxes = values $self->_mailboxes->%*;

  my $curr;
  for my $name (@$path) {
    my $want_parent = $curr ? $curr->{id} : q{};

    ($curr) = grep {; ($_->{parentId}//'') eq $want_parent && $_->{name} eq $name }
              @mailboxes;

    return undef unless $curr;
  }

  return $curr;
}

sub decreasing_todo_mail {
  my ($self, $laststate, $arg) = @_;

  # flagged mail should be less than it was last time, or <10
  my $min = $arg->{threshold} // 10;

  my @todo_mailboxes = grep {; ! $_->{parentId} && $_->{name} =~ /^@/ }
                       values $self->_mailboxes->%*;

  my $count = sum0 map {; $_->{totalThreads} } @todo_mailboxes;

  my %result = (value => $count);

  if ($result{value} < max($laststate->completion->{measured_value}, $min)) {
    $result{note} = "new count: $result{value}";
    $result{met_goal} = not_today($laststate->completion);
  }

  return \%result;
}

sub decreasing_role_mail ($self, $laststate, $arg) {
  my $mailbox = $self->mailbox_by_role($arg->{role});
  return unless $mailbox;
  return $self->_decreasing_mail($mailbox, $laststate, $arg);
}

sub decreasing_mailbox_mail ($self, $laststate, $arg) {
  my $mailbox = $self->mailbox_by_path($arg->{mailbox});
  return unless $mailbox;
  return $self->_decreasing_mail($mailbox, $laststate, $arg);
}

sub _decreasing_mail ($self, $mailbox, $laststate, $arg) {
  # unread mail should be less than it was last time, or <n
  my $min = $arg->{threshold} // 10;

  my %result = (value => $mailbox->{totalThreads});

  if ($result{value} < max($laststate->completion->{measured_value}, $min)) {
    $result{note} = "new count: $result{value}";
    $result{met_goal} = not_today($laststate->completion);
  }

  return \%result;
}

1;
