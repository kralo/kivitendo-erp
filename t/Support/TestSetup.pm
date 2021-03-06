package Support::TestSetup;

use strict;

use Data::Dumper;
use CGI qw( -no_xhtml);
use SL::Auth;
use SL::Form;
use SL::Locale;
use SL::LXDebug;
use Data::Dumper;
use SL::Layout::None;
use SL::LxOfficeConf;
use SL::InstanceConfiguration;
use SL::Request;

sub _login {
  my ($client, $login) = @_;

  die 'need client and login' unless $client && $login;

  package main;

  $::lxdebug       = LXDebug->new(target => LXDebug::STDERR_TARGET);
  $::lxdebug->disable_sub_tracing;
  $::locale        = Locale->new($::lx_office_conf{system}->{language});
  $::form          = Form->new;
  $::auth          = SL::Auth->new;
  die "Cannot find client with ID or name '$client'" if !$::auth->set_client($client);

  $::instance_conf = SL::InstanceConfiguration->new;
  $::request       = SL::Request->new( cgi => CGI->new({}), layout => SL::Layout::None->new );

  die 'cannot reach auth db'               unless $::auth->session_tables_present;

  $::auth->restore_session;

  require "bin/mozilla/common.pl";

  die "cannot find user $login"            unless %::myconfig = $::auth->read_user(login => $login);

  $::form->{login} = $login; # normaly implicit at login

  die "cannot find locale for user $login" unless $::locale   = Locale->new($::myconfig{countrycode});

  $::instance_conf->init;

  return 1;
}

sub login {
  SL::LxOfficeConf->read;

  my $login        = shift || $::lx_office_conf{testing}{login}        || 'demo';
  my $client        = shift || $::lx_office_conf{testing}{client}      || '';
  _login($client, $login);
}

1;
