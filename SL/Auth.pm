package SL::Auth;

use DBI;

use Digest::MD5 qw(md5_hex);
use IO::File;
use Time::HiRes qw(gettimeofday);
use List::MoreUtils qw(uniq);
use YAML;

use SL::Auth::ColumnInformation;
use SL::Auth::Constants qw(:all);
use SL::Auth::DB;
use SL::Auth::LDAP;
use SL::Auth::Password;
use SL::Auth::SessionValue;

use SL::SessionFile;
use SL::User;
use SL::DBConnect;
use SL::DBUpgrade2;
use SL::DBUtils;

use strict;

sub new {
  $main::lxdebug->enter_sub();

  my $type = shift;
  my $self = {};

  bless $self, $type;

  $self->_read_auth_config();
  $self->reset;

  $main::lxdebug->leave_sub();

  return $self;
}

sub reset {
  my ($self, %params) = @_;

  $self->{SESSION}            = { };
  $self->{FULL_RIGHTS}        = { };
  $self->{RIGHTS}             = { };
  $self->{unique_counter}     = 0;
  $self->{column_information} = SL::Auth::ColumnInformation->new(auth => $self);
  $self->{authenticator}->reset;
}

sub get_user_dbh {
  my ($self, $login, %params) = @_;
  my $may_fail = delete $params{may_fail};

  my %user = $self->read_user(login => $login);
  my $dbh  = SL::DBConnect->connect(
    $user{dbconnect},
    $user{dbuser},
    $user{dbpasswd},
    {
      pg_enable_utf8 => $::locale->is_utf8,
      AutoCommit     => 0
    }
  );

  if (!$may_fail && !$dbh) {
    $::form->error($::locale->text('The connection to the authentication database failed:') . "\n" . $DBI::errstr);
  }

  if ($user{dboptions} && $dbh) {
    $dbh->do($user{dboptions}) or $::form->dberror($user{dboptions});
  }

  return $dbh;
}

sub DESTROY {
  my $self = shift;

  $self->{dbh}->disconnect() if ($self->{dbh});
}

# form isn't loaded yet, so auth needs it's own error.
sub mini_error {
  $::lxdebug->show_backtrace();

  my ($self, @msg) = @_;
  if ($ENV{HTTP_USER_AGENT}) {
    print Form->create_http_response(content_type => 'text/html');
    print "<pre>", join ('<br>', @msg), "</pre>";
  } else {
    print STDERR "Error: @msg\n";
  }
  ::end_of_request();
}

sub _read_auth_config {
  $main::lxdebug->enter_sub();

  my $self = shift;

  map { $self->{$_} = $::lx_office_conf{authentication}->{$_} } keys %{ $::lx_office_conf{authentication} };

  # Prevent password leakage to log files when dumping Auth instances.
  $self->{admin_password} = sub { $::lx_office_conf{authentication}->{admin_password} };

  $self->{DB_config}   = $::lx_office_conf{'authentication/database'};
  $self->{LDAP_config} = $::lx_office_conf{'authentication/ldap'};

  if ($self->{module} eq 'DB') {
    $self->{authenticator} = SL::Auth::DB->new($self);

  } elsif ($self->{module} eq 'LDAP') {
    $self->{authenticator} = SL::Auth::LDAP->new($self);
  }

  if (!$self->{authenticator}) {
    my $locale = Locale->new('en');
    $self->mini_error($locale->text('No or an unknown authenticantion module specified in "config/lx_office.conf".'));
  }

  my $cfg = $self->{DB_config};

  if (!$cfg) {
    my $locale = Locale->new('en');
    $self->mini_error($locale->text('config/lx_office.conf: Key "DB_config" is missing.'));
  }

  if (!$cfg->{host} || !$cfg->{db} || !$cfg->{user}) {
    my $locale = Locale->new('en');
    $self->mini_error($locale->text('config/lx_office.conf: Missing parameters in "authentication/database". Required parameters are "host", "db" and "user".'));
  }

  $self->{authenticator}->verify_config();

  $self->{session_timeout} *= 1;
  $self->{session_timeout}  = 8 * 60 if (!$self->{session_timeout});

  $main::lxdebug->leave_sub();
}

sub authenticate_root {
  $main::lxdebug->enter_sub();

  my ($self, $password) = @_;

  $password             = SL::Auth::Password->hash_if_unhashed(login => 'root', password => $password);
  my $admin_password    = SL::Auth::Password->hash_if_unhashed(login => 'root', password => $self->{admin_password}->());

  $main::lxdebug->leave_sub();

  return OK if $password eq $admin_password;
  sleep 5;
  return ERR_PASSWORD;
}

sub authenticate {
  $main::lxdebug->enter_sub();

  my ($self, $login, $password) = @_;

  $main::lxdebug->leave_sub();

  my $result = $login ? $self->{authenticator}->authenticate($login, $password) : ERR_USER;
  return OK if $result eq OK;
  sleep 5;
  return $result;
}

sub store_credentials_in_session {
  my ($self, %params) = @_;

  if (!$self->{authenticator}->requires_cleartext_password) {
    $params{password} = SL::Auth::Password->hash_if_unhashed(login             => $params{login},
                                                             password          => $params{password},
                                                             look_up_algorithm => 1,
                                                             auth              => $self);
  }

  $self->set_session_value(login => $params{login}, password => $params{password});
}

sub store_root_credentials_in_session {
  my ($self, $rpw) = @_;

  $self->set_session_value(rpw => SL::Auth::Password->hash_if_unhashed(login => 'root', password => $rpw));
}

sub get_stored_password {
  my ($self, $login) = @_;

  my $dbh            = $self->dbconnect;

  return undef unless $dbh;

  my $query             = qq|SELECT password FROM auth."user" WHERE login = ?|;
  my ($stored_password) = $dbh->selectrow_array($query, undef, $login);

  return $stored_password;
}

sub dbconnect {
  $main::lxdebug->enter_sub(2);

  my $self     = shift;
  my $may_fail = shift;

  if ($self->{dbh}) {
    $main::lxdebug->leave_sub(2);
    return $self->{dbh};
  }

  my $cfg = $self->{DB_config};
  my $dsn = 'dbi:Pg:dbname=' . $cfg->{db} . ';host=' . $cfg->{host};

  if ($cfg->{port}) {
    $dsn .= ';port=' . $cfg->{port};
  }

  $main::lxdebug->message(LXDebug->DEBUG1, "Auth::dbconnect DSN: $dsn");

  $self->{dbh} = SL::DBConnect->connect($dsn, $cfg->{user}, $cfg->{password}, { pg_enable_utf8 => $::locale->is_utf8, AutoCommit => 1 });

  if (!$may_fail && !$self->{dbh}) {
    $main::form->error($main::locale->text('The connection to the authentication database failed:') . "\n" . $DBI::errstr);
  }

  $main::lxdebug->leave_sub(2);

  return $self->{dbh};
}

sub dbdisconnect {
  $main::lxdebug->enter_sub();

  my $self = shift;

  if ($self->{dbh}) {
    $self->{dbh}->disconnect();
    delete $self->{dbh};
  }

  $main::lxdebug->leave_sub();
}

sub check_tables {
  $main::lxdebug->enter_sub();

  my ($self, $dbh)    = @_;

  $dbh   ||= $self->dbconnect();
  my $query   = qq|SELECT COUNT(*) FROM pg_tables WHERE (schemaname = 'auth') AND (tablename = 'user')|;

  my ($count) = $dbh->selectrow_array($query);

  $main::lxdebug->leave_sub();

  return $count > 0;
}

sub check_database {
  $main::lxdebug->enter_sub();

  my $self = shift;

  my $dbh  = $self->dbconnect(1);

  $main::lxdebug->leave_sub();

  return $dbh ? 1 : 0;
}

sub create_database {
  $main::lxdebug->enter_sub();

  my $self   = shift;
  my %params = @_;

  my $cfg    = $self->{DB_config};

  if (!$params{superuser}) {
    $params{superuser}          = $cfg->{user};
    $params{superuser_password} = $cfg->{password};
  }

  $params{template} ||= 'template0';
  $params{template}   =~ s|[^a-zA-Z0-9_\-]||g;

  my $dsn = 'dbi:Pg:dbname=template1;host=' . $cfg->{host};

  if ($cfg->{port}) {
    $dsn .= ';port=' . $cfg->{port};
  }

  $main::lxdebug->message(LXDebug->DEBUG1(), "Auth::create_database DSN: $dsn");

  my $charset    = $::lx_office_conf{system}->{dbcharset};
  $charset     ||= Common::DEFAULT_CHARSET;
  my $encoding   = $Common::charset_to_db_encoding{$charset};
  $encoding    ||= 'UNICODE';

  my $dbh        = SL::DBConnect->connect($dsn, $params{superuser}, $params{superuser_password}, { pg_enable_utf8 => scalar($charset =~ m/^utf-?8$/i) });

  if (!$dbh) {
    $main::form->error($main::locale->text('The connection to the template database failed:') . "\n" . $DBI::errstr);
  }

  my $query = qq|CREATE DATABASE "$cfg->{db}" OWNER "$cfg->{user}" TEMPLATE "$params{template}" ENCODING '$encoding'|;

  $main::lxdebug->message(LXDebug->DEBUG1(), "Auth::create_database query: $query");

  $dbh->do($query);

  if ($dbh->err) {
    my $error = $dbh->errstr();

    $query                 = qq|SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'template0'|;
    my ($cluster_encoding) = $dbh->selectrow_array($query);

    if ($cluster_encoding && ($cluster_encoding =~ m/^(?:UTF-?8|UNICODE)$/i) && ($encoding !~ m/^(?:UTF-?8|UNICODE)$/i)) {
      $error = $main::locale->text('Your PostgreSQL installationen uses UTF-8 as its encoding. Therefore you have to configure Lx-Office to use UTF-8 as well.');
    }

    $dbh->disconnect();

    $main::form->error($main::locale->text('The creation of the authentication database failed:') . "\n" . $error);
  }

  $dbh->disconnect();

  $main::lxdebug->leave_sub();
}

sub create_tables {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my $dbh  = $self->dbconnect();

  my $charset    = $::lx_office_conf{system}->{dbcharset};
  $charset     ||= Common::DEFAULT_CHARSET;

  $dbh->rollback();
  SL::DBUpgrade2->new(form => $::form)->process_query($dbh, 'sql/auth_db.sql', undef, $charset);

  $main::lxdebug->leave_sub();
}

sub save_user {
  $main::lxdebug->enter_sub();

  my $self   = shift;
  my $login  = shift;
  my %params = @_;

  my $form   = $main::form;

  my $dbh    = $self->dbconnect();

  my ($sth, $query, $user_id);

  $dbh->begin_work;

  $query     = qq|SELECT id FROM auth."user" WHERE login = ?|;
  ($user_id) = selectrow_query($form, $dbh, $query, $login);

  if (!$user_id) {
    $query     = qq|SELECT nextval('auth.user_id_seq')|;
    ($user_id) = selectrow_query($form, $dbh, $query);

    $query     = qq|INSERT INTO auth."user" (id, login) VALUES (?, ?)|;
    do_query($form, $dbh, $query, $user_id, $login);
  }

  $query = qq|DELETE FROM auth.user_config WHERE (user_id = ?)|;
  do_query($form, $dbh, $query, $user_id);

  $query = qq|INSERT INTO auth.user_config (user_id, cfg_key, cfg_value) VALUES (?, ?, ?)|;
  $sth   = prepare_query($form, $dbh, $query);

  while (my ($cfg_key, $cfg_value) = each %params) {
    next if ($cfg_key eq 'password');

    do_statement($form, $sth, $query, $user_id, $cfg_key, $cfg_value);
  }

  $dbh->commit();

  $main::lxdebug->leave_sub();
}

sub can_change_password {
  my $self = shift;

  return $self->{authenticator}->can_change_password();
}

sub change_password {
  $main::lxdebug->enter_sub();

  my ($self, $login, $new_password) = @_;

  my $result = $self->{authenticator}->change_password($login, $new_password);

  $self->store_credentials_in_session(login             => $login,
                                      password          => $new_password,
                                      look_up_algorithm => 1,
                                      auth              => $self);

  $main::lxdebug->leave_sub();

  return $result;
}

sub read_all_users {
  $main::lxdebug->enter_sub();

  my $self  = shift;

  my $dbh   = $self->dbconnect();
  my $query = qq|SELECT u.id, u.login, cfg.cfg_key, cfg.cfg_value
                 FROM auth.user_config cfg
                 LEFT JOIN auth."user" u ON (cfg.user_id = u.id)|;
  my $sth   = prepare_execute_query($main::form, $dbh, $query);

  my %users;

  while (my $ref = $sth->fetchrow_hashref()) {
    $users{$ref->{login}}                    ||= { 'login' => $ref->{login}, 'id' => $ref->{id} };
    $users{$ref->{login}}->{$ref->{cfg_key}}   = $ref->{cfg_value} if (($ref->{cfg_key} ne 'login') && ($ref->{cfg_key} ne 'id'));
  }

  $sth->finish();

  $main::lxdebug->leave_sub();

  return %users;
}

sub read_user {
  $main::lxdebug->enter_sub();

  my ($self, %params) = @_;

  my $dbh   = $self->dbconnect();

  my (@where, @values);
  if ($params{login}) {
    push @where,  'u.login = ?';
    push @values, $params{login};
  }
  if ($params{id}) {
    push @where,  'u.id = ?';
    push @values, $params{id};
  }
  my $where = join ' AND ', '1 = 1', @where;
  my $query = qq|SELECT u.id, u.login, cfg.cfg_key, cfg.cfg_value
                 FROM auth.user_config cfg
                 LEFT JOIN auth."user" u ON (cfg.user_id = u.id)
                 WHERE $where|;
  my $sth   = prepare_execute_query($main::form, $dbh, $query, @values);

  my %user_data;

  while (my $ref = $sth->fetchrow_hashref()) {
    $user_data{$ref->{cfg_key}} = $ref->{cfg_value};
    @user_data{qw(id login)}    = @{$ref}{qw(id login)};
  }

  # The XUL/XML backed menu has been removed.
  $user_data{menustyle} = 'v3' if lc($user_data{menustyle} || '') eq 'xml';

  $sth->finish();

  $main::lxdebug->leave_sub();

  return %user_data;
}

sub get_user_id {
  $main::lxdebug->enter_sub();

  my $self  = shift;
  my $login = shift;

  my $dbh   = $self->dbconnect();
  my ($id)  = selectrow_query($main::form, $dbh, qq|SELECT id FROM auth."user" WHERE login = ?|, $login);

  $main::lxdebug->leave_sub();

  return $id;
}

sub delete_user {
  $::lxdebug->enter_sub;

  my $self  = shift;
  my $login = shift;

  my $dbh   = $self->dbconnect;
  my $id    = $self->get_user_id($login);
  my $user_db_exists;

  $dbh->rollback and return $::lxdebug->leave_sub if (!$id);

  my $u_dbh = $self->get_user_dbh($login, may_fail => 1);
  $user_db_exists = $self->check_tables($u_dbh) if $u_dbh;

  $u_dbh->begin_work if $u_dbh && $user_db_exists;

  $dbh->begin_work;

  do_query($::form, $dbh, qq|DELETE FROM auth.user_group WHERE user_id = ?|, $id);
  do_query($::form, $dbh, qq|DELETE FROM auth.user_config WHERE user_id = ?|, $id);
  do_query($::form, $dbh, qq|DELETE FROM auth.user WHERE id = ?|, $id);
  do_query($::form, $u_dbh, qq|UPDATE employee SET deleted = 't' WHERE login = ?|, $login) if $u_dbh && $user_db_exists;

  $dbh->commit;
  $u_dbh->commit if $u_dbh && $user_db_exists;

  $::lxdebug->leave_sub;
}

# --------------------------------------

my $session_id;

sub restore_session {
  $main::lxdebug->enter_sub();

  my $self = shift;

  $session_id        =  $::request->{cgi}->cookie($self->get_session_cookie_name());
  $session_id        =~ s|[^0-9a-f]||g if $session_id;

  $self->{SESSION}   = { };

  if (!$session_id) {
    $main::lxdebug->leave_sub();
    return SESSION_NONE;
  }

  my ($dbh, $query, $sth, $cookie, $ref, $form);

  $form   = $main::form;

  # Don't fail if the auth DB doesn't yet.
  if (!( $dbh = $self->dbconnect(1) )) {
    $::lxdebug->leave_sub;
    return SESSION_NONE;
  }

  # Don't fail if the "auth" schema doesn't exist yet, e.g. if the
  # admin is creating the session tables at the moment.
  $query  = qq|SELECT *, (mtime < (now() - '$self->{session_timeout}m'::interval)) AS is_expired FROM auth.session WHERE id = ?|;

  if (!($sth = $dbh->prepare($query)) || !$sth->execute($session_id)) {
    $sth->finish if $sth;
    $::lxdebug->leave_sub;
    return SESSION_NONE;
  }

  $cookie = $sth->fetchrow_hashref;
  $sth->finish;

  if (!$cookie || $cookie->{is_expired} || ($cookie->{ip_address} ne $ENV{REMOTE_ADDR})) {
    $self->destroy_session();
    $main::lxdebug->leave_sub();
    return $cookie ? SESSION_EXPIRED : SESSION_NONE;
  }

  if ($self->{column_information}->has('auto_restore')) {
    $self->_load_with_auto_restore_column($dbh, $session_id);
  } else {
    $self->_load_without_auto_restore_column($dbh, $session_id);
  }

  $main::lxdebug->leave_sub();

  return SESSION_OK;
}

sub _load_without_auto_restore_column {
  my ($self, $dbh, $session_id) = @_;

  my $query = <<SQL;
    SELECT sess_key, sess_value
    FROM auth.session_content
    WHERE (session_id = ?)
SQL
  my $sth = prepare_execute_query($::form, $dbh, $query, $session_id);

  while (my $ref = $sth->fetchrow_hashref) {
    my $value = SL::Auth::SessionValue->new(auth  => $self,
                                            key   => $ref->{sess_key},
                                            value => $ref->{sess_value},
                                            raw   => 1);
    $self->{SESSION}->{ $ref->{sess_key} } = $value;

    next if defined $::form->{$ref->{sess_key}};

    my $data                    = $value->get;
    $::form->{$ref->{sess_key}} = $data if $value->{auto_restore} || !ref $data;
  }
}

sub _load_with_auto_restore_column {
  my ($self, $dbh, $session_id) = @_;

  my $auto_restore_keys = join ', ', map { "'${_}'" } qw(login password rpw);

  my $query = <<SQL;
    SELECT sess_key, sess_value, auto_restore
    FROM auth.session_content
    WHERE (session_id = ?)
      AND (   auto_restore
           OR sess_key IN (${auto_restore_keys}))
SQL
  my $sth = prepare_execute_query($::form, $dbh, $query, $session_id);

  while (my $ref = $sth->fetchrow_hashref) {
    my $value = SL::Auth::SessionValue->new(auth         => $self,
                                            key          => $ref->{sess_key},
                                            value        => $ref->{sess_value},
                                            auto_restore => $ref->{auto_restore},
                                            raw          => 1);
    $self->{SESSION}->{ $ref->{sess_key} } = $value;

    next if defined $::form->{$ref->{sess_key}};

    my $data                    = $value->get;
    $::form->{$ref->{sess_key}} = $data if $value->{auto_restore} || !ref $data;
  }

  $sth->finish;

  $query = <<SQL;
    SELECT sess_key
    FROM auth.session_content
    WHERE (session_id = ?)
      AND NOT COALESCE(auto_restore, FALSE)
      AND (sess_key NOT IN (${auto_restore_keys}))
SQL
  $sth = prepare_execute_query($::form, $dbh, $query, $session_id);

  while (my $ref = $sth->fetchrow_hashref) {
    my $value = SL::Auth::SessionValue->new(auth => $self,
                                            key  => $ref->{sess_key});
    $self->{SESSION}->{ $ref->{sess_key} } = $value;
  }
}

sub destroy_session {
  $main::lxdebug->enter_sub();

  my $self = shift;

  if ($session_id) {
    my $dbh = $self->dbconnect();

    $dbh->begin_work;

    do_query($main::form, $dbh, qq|DELETE FROM auth.session_content WHERE session_id = ?|, $session_id);
    do_query($main::form, $dbh, qq|DELETE FROM auth.session WHERE id = ?|, $session_id);

    $dbh->commit();

    SL::SessionFile->destroy_session($session_id);

    $session_id      = undef;
    $self->{SESSION} = { };
  }

  $main::lxdebug->leave_sub();
}

sub expire_sessions {
  $main::lxdebug->enter_sub();

  my $self  = shift;

  $main::lxdebug->leave_sub and return if !$self->session_tables_present;

  my $dbh   = $self->dbconnect();

  my $query = qq|SELECT id
                 FROM auth.session
                 WHERE (mtime < (now() - '$self->{session_timeout}m'::interval))|;

  my @ids   = selectall_array_query($::form, $dbh, $query);

  if (@ids) {
    $dbh->begin_work;

    SL::SessionFile->destroy_session($_) for @ids;

    $query = qq|DELETE FROM auth.session_content
                WHERE session_id IN (| . join(', ', ('?') x scalar(@ids)) . qq|)|;
    do_query($main::form, $dbh, $query, @ids);

    $query = qq|DELETE FROM auth.session
                WHERE id IN (| . join(', ', ('?') x scalar(@ids)) . qq|)|;
    do_query($main::form, $dbh, $query, @ids);

    $dbh->commit();
  }

  $main::lxdebug->leave_sub();
}

sub _create_session_id {
  $main::lxdebug->enter_sub();

  my @data;
  map { push @data, int(rand() * 255); } (1..32);

  my $id = md5_hex(pack 'C*', @data);

  $main::lxdebug->leave_sub();

  return $id;
}

sub create_or_refresh_session {
  $session_id ||= shift->_create_session_id;
}

sub save_session {
  $::lxdebug->enter_sub;
  my $self         = shift;
  my $provided_dbh = shift;

  my $dbh          = $provided_dbh || $self->dbconnect(1);

  $::lxdebug->leave_sub && return unless $dbh && $session_id;

  $dbh->begin_work unless $provided_dbh;

  # If this fails then the "auth" schema might not exist yet, e.g. if
  # the admin is just trying to create the auth database.
  if (!$dbh->do(qq|LOCK auth.session_content|)) {
    $dbh->rollback unless $provided_dbh;
    $::lxdebug->leave_sub;
    return;
  }

  my @unfetched_keys = map     { $_->{key}        }
                       grep    { ! $_->{fetched}  }
                       values %{ $self->{SESSION} };
  # $::lxdebug->dump(0, "unfetched_keys", [ sort @unfetched_keys ]);
  # $::lxdebug->dump(0, "all keys", [ sort map { $_->{key} } values %{ $self->{SESSION} } ]);
  my $query          = qq|DELETE FROM auth.session_content WHERE (session_id = ?)|;
  $query            .= qq| AND (sess_key NOT IN (| . join(', ', ('?') x scalar @unfetched_keys) . qq|))| if @unfetched_keys;

  do_query($::form, $dbh, $query, $session_id, @unfetched_keys);

  my ($id) = selectrow_query($::form, $dbh, qq|SELECT id FROM auth.session WHERE id = ?|, $session_id);

  if ($id) {
    do_query($::form, $dbh, qq|UPDATE auth.session SET mtime = now() WHERE id = ?|, $session_id);
  } else {
    do_query($::form, $dbh, qq|INSERT INTO auth.session (id, ip_address, mtime) VALUES (?, ?, now())|, $session_id, $ENV{REMOTE_ADDR});
  }

  my @values_to_save = grep    { $_->{fetched} }
                       values %{ $self->{SESSION} };
  if (@values_to_save) {
    my ($columns, $placeholders) = ('', '');
    my $auto_restore             = $self->{column_information}->has('auto_restore');

    if ($auto_restore) {
      $columns      .= ', auto_restore';
      $placeholders .= ', ?';
    }

    $query  = qq|INSERT INTO auth.session_content (session_id, sess_key, sess_value ${columns}) VALUES (?, ?, ? ${placeholders})|;
    my $sth = prepare_query($::form, $dbh, $query);

    foreach my $value (@values_to_save) {
      my @values = ($value->{key}, $value->get_dumped);
      push @values, $value->{auto_restore} if $auto_restore;

      do_statement($::form, $sth, $query, $session_id, @values);
    }

    $sth->finish();
  }

  $dbh->commit() unless $provided_dbh;
  $::lxdebug->leave_sub;
}

sub set_session_value {
  $main::lxdebug->enter_sub();

  my $self   = shift;
  my @params = @_;

  $self->{SESSION} ||= { };

  while (@params) {
    my $key = shift @params;

    if (ref $key eq 'HASH') {
      $self->{SESSION}->{ $key->{key} } = SL::Auth::SessionValue->new(key          => $key->{key},
                                                                      value        => $key->{value},
                                                                      auto_restore => $key->{auto_restore});

    } else {
      my $value = shift @params;
      $self->{SESSION}->{ $key } = SL::Auth::SessionValue->new(key   => $key,
                                                               value => $value);
    }
  }

  $main::lxdebug->leave_sub();

  return $self;
}

sub delete_session_value {
  $main::lxdebug->enter_sub();

  my $self = shift;

  $self->{SESSION} ||= { };
  delete @{ $self->{SESSION} }{ @_ };

  $main::lxdebug->leave_sub();

  return $self;
}

sub get_session_value {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my $data = $self->{SESSION} && $self->{SESSION}->{ $_[0] } ? $self->{SESSION}->{ $_[0] }->get : undef;

  $main::lxdebug->leave_sub();

  return $data;
}

sub create_unique_sesion_value {
  my ($self, $value, %params) = @_;

  $self->{SESSION} ||= { };

  my @now                   = gettimeofday();
  my $key                   = "$$-" . ($now[0] * 1000000 + $now[1]) . "-";
  $self->{unique_counter} ||= 0;

  my $hashed_key;
  do {
    $self->{unique_counter}++;
    $hashed_key = md5_hex($key . $self->{unique_counter});
  } while (exists $self->{SESSION}->{$hashed_key});

  $self->set_session_value($hashed_key => $value);

  return $hashed_key;
}

sub save_form_in_session {
  my ($self, %params) = @_;

  my $form        = delete($params{form}) || $::form;
  my $non_scalars = delete $params{non_scalars};
  my $data        = {};

  my %skip_keys   = map { ( $_ => 1 ) } (qw(login password stylesheet version titlebar), @{ $params{skip_keys} || [] });

  foreach my $key (grep { !$skip_keys{$_} } keys %{ $form }) {
    $data->{$key} = $form->{$key} if !ref($form->{$key}) || $non_scalars;
  }

  return $self->create_unique_sesion_value($data, %params);
}

sub restore_form_from_session {
  my ($self, $key, %params) = @_;

  my $data = $self->get_session_value($key);
  return $self unless $data;

  my $form    = delete($params{form}) || $::form;
  my $clobber = exists $params{clobber} ? $params{clobber} : 1;

  map { $form->{$_} = $data->{$_} if $clobber || !exists $form->{$_} } keys %{ $data };

  return $self;
}

sub set_cookie_environment_variable {
  my $self = shift;
  $ENV{HTTP_COOKIE} = $self->get_session_cookie_name() . "=${session_id}";
}

sub get_session_cookie_name {
  my $self = shift;

  return $self->{cookie_name} || 'lx_office_erp_session_id';
}

sub get_session_id {
  return $session_id;
}

sub session_tables_present {
  $main::lxdebug->enter_sub();

  my $self = shift;

  # Only re-check for the presence of auth tables if either the check
  # hasn't been done before of if they weren't present.
  if ($self->{session_tables_present}) {
    $main::lxdebug->leave_sub();
    return $self->{session_tables_present};
  }

  my $dbh  = $self->dbconnect(1);

  if (!$dbh) {
    $main::lxdebug->leave_sub();
    return 0;
  }

  my $query =
    qq|SELECT COUNT(*)
       FROM pg_tables
       WHERE (schemaname = 'auth')
         AND (tablename IN ('session', 'session_content'))|;

  my ($count) = selectrow_query($main::form, $dbh, $query);

  $self->{session_tables_present} = 2 == $count;

  $main::lxdebug->leave_sub();

  return $self->{session_tables_present};
}

# --------------------------------------

sub all_rights_full {
  my $locale = $main::locale;

  my @all_rights = (
    ["--crm",                          $locale->text("CRM optional software")],
    ["crm_search",                     $locale->text("CRM search")],
    ["crm_new",                        $locale->text("CRM create customers, vendors and contacts")],
    ["crm_service",                    $locale->text("CRM services")],
    ["crm_admin",                      $locale->text("CRM admin")],
    ["crm_adminuser",                  $locale->text("CRM user")],
    ["crm_adminstatus",                $locale->text("CRM status")],
    ["crm_email",                      $locale->text("CRM send email")],
    ["crm_termin",                     $locale->text("CRM termin")],
    ["crm_opportunity",                $locale->text("CRM opportunity")],
    ["crm_knowhow",                    $locale->text("CRM know how")],
    ["crm_follow",                     $locale->text("CRM follow up")],
    ["crm_notices",                    $locale->text("CRM notices")],
    ["crm_other",                      $locale->text("CRM other")],
    ["--master_data",                  $locale->text("Master Data")],
    ["customer_vendor_edit",           $locale->text("Create customers and vendors. Edit all vendors. Edit only customers where salesman equals employee (login)")],
    ["customer_vendor_all_edit",       $locale->text("Create customers and vendors. Edit all vendors. Edit all customers")],
    ["part_service_assembly_edit",     $locale->text("Create and edit parts, services, assemblies")],
    ["project_edit",                   $locale->text("Create and edit projects")],
    ["--ar",                           $locale->text("AR")],
    ["sales_quotation_edit",           $locale->text("Create and edit sales quotations")],
    ["sales_order_edit",               $locale->text("Create and edit sales orders")],
    ["sales_delivery_order_edit",      $locale->text("Create and edit sales delivery orders")],
    ["invoice_edit",                   $locale->text("Create and edit invoices and credit notes")],
    ["dunning_edit",                   $locale->text("Create and edit dunnings")],
    ["sales_all_edit",                 $locale->text("View/edit all employees sales documents")],
    ["edit_prices",                    $locale->text("Edit prices and discount (if not used, textfield is ONLY set readonly)")],
    ["--ap",                           $locale->text("AP")],
    ["request_quotation_edit",         $locale->text("Create and edit RFQs")],
    ["purchase_order_edit",            $locale->text("Create and edit purchase orders")],
    ["purchase_delivery_order_edit",   $locale->text("Create and edit purchase delivery orders")],
    ["vendor_invoice_edit",            $locale->text("Create and edit vendor invoices")],
    ["--warehouse_management",         $locale->text("Warehouse management")],
    ["warehouse_contents",             $locale->text("View warehouse content")],
    ["warehouse_management",           $locale->text("Warehouse management")],
    ["--general_ledger_cash",          $locale->text("General ledger and cash")],
    ["general_ledger",                 $locale->text("Transactions, AR transactions, AP transactions")],
    ["datev_export",                   $locale->text("DATEV Export")],
    ["cash",                           $locale->text("Receipt, payment, reconciliation")],
    ["--reports",                      $locale->text('Reports')],
    ["report",                         $locale->text('All reports')],
    ["advance_turnover_tax_return",    $locale->text('Advance turnover tax return')],
    ["--batch_printing",               $locale->text("Batch Printing")],
    ["batch_printing",                 $locale->text("Batch Printing")],
    ["--others",                       $locale->text("Others")],
    ["email_bcc",                      $locale->text("May set the BCC field when sending emails")],
    ["config",                         $locale->text("Change Lx-Office installation settings (all menu entries beneath 'System')")],
    ["admin",                          $locale->text("Administration (Used to access instance administration from user logins)")],
    );

  return @all_rights;
}

sub all_rights {
  return grep !/^--/, map { $_->[0] } all_rights_full();
}

sub read_groups {
  $main::lxdebug->enter_sub();

  my $self = shift;

  my $form   = $main::form;
  my $groups = {};
  my $dbh    = $self->dbconnect();

  my $query  = 'SELECT * FROM auth."group"';
  my $sth    = prepare_execute_query($form, $dbh, $query);

  my ($row, $group);

  while ($row = $sth->fetchrow_hashref()) {
    $groups->{$row->{id}} = $row;
  }
  $sth->finish();

  $query = 'SELECT * FROM auth.user_group WHERE group_id = ?';
  $sth   = prepare_query($form, $dbh, $query);

  foreach $group (values %{$groups}) {
    my @members;

    do_statement($form, $sth, $query, $group->{id});

    while ($row = $sth->fetchrow_hashref()) {
      push @members, $row->{user_id};
    }
    $group->{members} = [ uniq @members ];
  }
  $sth->finish();

  $query = 'SELECT * FROM auth.group_rights WHERE group_id = ?';
  $sth   = prepare_query($form, $dbh, $query);

  foreach $group (values %{$groups}) {
    $group->{rights} = {};

    do_statement($form, $sth, $query, $group->{id});

    while ($row = $sth->fetchrow_hashref()) {
      $group->{rights}->{$row->{right}} |= $row->{granted};
    }

    map { $group->{rights}->{$_} = 0 if (!defined $group->{rights}->{$_}); } all_rights();
  }
  $sth->finish();

  $main::lxdebug->leave_sub();

  return $groups;
}

sub save_group {
  $main::lxdebug->enter_sub();

  my $self  = shift;
  my $group = shift;

  my $form  = $main::form;
  my $dbh   = $self->dbconnect();

  $dbh->begin_work;

  my ($query, $sth, $row, $rights);

  if (!$group->{id}) {
    ($group->{id}) = selectrow_query($form, $dbh, qq|SELECT nextval('auth.group_id_seq')|);

    $query = qq|INSERT INTO auth."group" (id, name, description) VALUES (?, '', '')|;
    do_query($form, $dbh, $query, $group->{id});
  }

  do_query($form, $dbh, qq|UPDATE auth."group" SET name = ?, description = ? WHERE id = ?|, map { $group->{$_} } qw(name description id));

  do_query($form, $dbh, qq|DELETE FROM auth.user_group WHERE group_id = ?|, $group->{id});

  $query  = qq|INSERT INTO auth.user_group (user_id, group_id) VALUES (?, ?)|;
  $sth    = prepare_query($form, $dbh, $query);

  foreach my $user_id (uniq @{ $group->{members} }) {
    do_statement($form, $sth, $query, $user_id, $group->{id});
  }
  $sth->finish();

  do_query($form, $dbh, qq|DELETE FROM auth.group_rights WHERE group_id = ?|, $group->{id});

  $query = qq|INSERT INTO auth.group_rights (group_id, "right", granted) VALUES (?, ?, ?)|;
  $sth   = prepare_query($form, $dbh, $query);

  foreach my $right (keys %{ $group->{rights} }) {
    do_statement($form, $sth, $query, $group->{id}, $right, $group->{rights}->{$right} ? 't' : 'f');
  }
  $sth->finish();

  $dbh->commit();

  $main::lxdebug->leave_sub();
}

sub delete_group {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my $id   = shift;

  my $form = $main::form;

  my $dbh  = $self->dbconnect();
  $dbh->begin_work;

  do_query($form, $dbh, qq|DELETE FROM auth.user_group WHERE group_id = ?|, $id);
  do_query($form, $dbh, qq|DELETE FROM auth.group_rights WHERE group_id = ?|, $id);
  do_query($form, $dbh, qq|DELETE FROM auth."group" WHERE id = ?|, $id);

  $dbh->commit();

  $main::lxdebug->leave_sub();
}

sub evaluate_rights_ary {
  $main::lxdebug->enter_sub(2);

  my $ary    = shift;

  my $value  = 0;
  my $action = '|';

  foreach my $el (@{$ary}) {
    if (ref $el eq "ARRAY") {
      if ($action eq '|') {
        $value |= evaluate_rights_ary($el);
      } else {
        $value &= evaluate_rights_ary($el);
      }

    } elsif (($el eq '&') || ($el eq '|')) {
      $action = $el;

    } elsif ($action eq '|') {
      $value |= $el;

    } else {
      $value &= $el;

    }
  }

  $main::lxdebug->leave_sub(2);

  return $value;
}

sub _parse_rights_string {
  $main::lxdebug->enter_sub(2);

  my $self   = shift;

  my $login  = shift;
  my $access = shift;

  my @stack;
  my $cur_ary = [];

  push @stack, $cur_ary;

  while ($access =~ m/^([a-z_0-9]+|\||\&|\(|\)|\s+)/) {
    my $token = $1;
    substr($access, 0, length $1) = "";

    next if ($token =~ /\s/);

    if ($token eq "(") {
      my $new_cur_ary = [];
      push @stack, $new_cur_ary;
      push @{$cur_ary}, $new_cur_ary;
      $cur_ary = $new_cur_ary;

    } elsif ($token eq ")") {
      pop @stack;

      if (!@stack) {
        $main::lxdebug->leave_sub(2);
        return 0;
      }

      $cur_ary = $stack[-1];

    } elsif (($token eq "|") || ($token eq "&")) {
      push @{$cur_ary}, $token;

    } else {
      push @{$cur_ary}, $self->{RIGHTS}->{$login}->{$token} * 1;
    }
  }

  my $result = ($access || (1 < scalar @stack)) ? 0 : evaluate_rights_ary($stack[0]);

  $main::lxdebug->leave_sub(2);

  return $result;
}

sub check_right {
  $main::lxdebug->enter_sub(2);

  my $self    = shift;
  my $login   = shift;
  my $right   = shift;
  my $default = shift;

  $self->{FULL_RIGHTS}           ||= { };
  $self->{FULL_RIGHTS}->{$login} ||= { };

  if (!defined $self->{FULL_RIGHTS}->{$login}->{$right}) {
    $self->{RIGHTS}           ||= { };
    $self->{RIGHTS}->{$login} ||= $self->load_rights_for_user($login);

    $self->{FULL_RIGHTS}->{$login}->{$right} = $self->_parse_rights_string($login, $right);
  }

  my $granted = $self->{FULL_RIGHTS}->{$login}->{$right};
  $granted    = $default if (!defined $granted);

  $main::lxdebug->leave_sub(2);

  return $granted;
}

sub assert {
  $::lxdebug->enter_sub(2);
  my ($self, $right, $dont_abort) = @_;

  if ($self->check_right($::myconfig{login}, $right)) {
    $::lxdebug->leave_sub(2);
    return 1;
  }

  if (!$dont_abort) {
    delete $::form->{title};
    $::form->show_generic_error($::locale->text("You do not have the permissions to access this function."));
  }

  $::lxdebug->leave_sub(2);

  return 0;
}

sub load_rights_for_user {
  $::lxdebug->enter_sub;

  my ($self, $login) = @_;
  my $dbh   = $self->dbconnect;
  my ($query, $sth, $row, $rights);

  $rights = { map { $_ => 0 } all_rights() };

  $query =
    qq|SELECT gr."right", gr.granted
       FROM auth.group_rights gr
       WHERE group_id IN
         (SELECT ug.group_id
          FROM auth.user_group ug
          LEFT JOIN auth."user" u ON (ug.user_id = u.id)
          WHERE u.login = ?)|;

  $sth = prepare_execute_query($::form, $dbh, $query, $login);

  while ($row = $sth->fetchrow_hashref()) {
    $rights->{$row->{right}} |= $row->{granted};
  }
  $sth->finish();

  $::lxdebug->leave_sub;

  return $rights;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

SL::Auth - Authentication and session handling

=head1 FUNCTIONS

=over 4

=item C<set_session_value @values>

=item C<set_session_value %values>

Store all values of C<@values> or C<%values> in the session. Each
member of C<@values> is tested if it is a hash reference. If it is
then it must contain the keys C<key> and C<value> and can optionally
contain the key C<auto_restore>. In this case C<value> is associated
with C<key> and restored to C<$::form> upon the next request
automatically if C<auto_restore> is trueish or if C<value> is a scalar
value.

If the current member of C<@values> is not a hash reference then it
will be used as the C<key> and the next entry of C<@values> is used as
the C<value> to store. In this case setting C<auto_restore> is not
possible.

Therefore the following two invocations are identical:

  $::auth-E<gt>set_session_value(name =E<gt> "Charlie");
  $::auth-E<gt>set_session_value({ key =E<gt> "name", value =E<gt> "Charlie" });

All of these values are copied back into C<$::form> for the next
request automatically if they're scalar values or if they have
C<auto_restore> set to trueish.

The values can be any Perl structure. They are stored as YAML dumps.

=item C<get_session_value $key>

Retrieve a value from the session. Returns C<undef> if the value
doesn't exist.

=item C<create_unique_sesion_value $value, %params>

Create a unique key in the session and store C<$value>
there.

Returns the key created in the session.

=item C<save_session>

Stores the session values in the database. This is the only function
that actually stores stuff in the database. Neither the various
setters nor the deleter access the database.

=item <save_form_in_session %params>

Stores the content of C<$params{form}> (default: C<$::form>) in the
session using L</create_unique_sesion_value>.

If C<$params{non_scalars}> is trueish then non-scalar values will be
stored as well. Default is to only store scalar values.

The following keys will never be saved: C<login>, C<password>,
C<stylesheet>, C<titlebar>, C<version>. Additional keys not to save
can be given as an array ref in C<$params{skip_keys}>.

Returns the unique key under which the form is stored.

=item <restore_form_from_session $key, %params>

Restores the form from the session into C<$params{form}> (default:
C<$::form>).

If C<$params{clobber}> is falsish then existing values with the same
key in C<$params{form}> will not be overwritten. C<$params{clobber}>
is on by default.

Returns C<$self>.

=back

=head1 BUGS

Nothing here yet.

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

=cut
