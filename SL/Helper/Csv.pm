package SL::Helper::Csv;

use strict;
use warnings;

use Carp;
use IO::File;
use Params::Validate qw(:all);
use List::MoreUtils qw(all pairwise);
use Text::CSV_XS;
use Rose::Object::MakeMethods::Generic scalar => [ qw(
  file encoding sep_char quote_char escape_char header profile
  numberformat dateformat ignore_unknown_columns strict_profile is_multiplexed
  _row_header _io _csv _objects _parsed _data _errors all_cvar_configs case_insensitive_header
) ];

use SL::Helper::Csv::Dispatcher;
use SL::Helper::Csv::Error;

# public interface

sub new {
  my $class  = shift;
  my %params = validate(@_, {
    sep_char               => { default => ';' },
    quote_char             => { default => '"' },
    escape_char            => { default => '"' },
    header                 => { type    => ARRAYREF, optional => 1 },
    profile                => { type    => ARRAYREF, optional => 1 },
    file                   => 1,
    encoding               => 0,
    numberformat           => 0,
    dateformat             => 0,
    ignore_unknown_columns => 0,
    strict_profile         => 0,
    case_insensitive_header => 0,
  });
  my $self = bless {}, $class;

  $self->$_($params{$_}) for keys %params;

  $self->_io(IO::File->new);
  $self->_csv(Text::CSV_XS->new({
    binary => 1,
    sep_char    => $self->sep_char,
    quote_char  => $self->quote_char,
    escape_char => $self->escape_char,

  }));
  $self->_errors([]);

  return $self;
}

sub parse {
  my ($self, %params) = @_;

  $self->_open_file;
  return if ! $self->_check_multiplexed;
  return if ! $self->_check_header;
  return if ! $self->dispatcher->parse_profile;
  return if ! $self->_parse_data;

  $self->_parsed(1);
  return $self;
}

sub get_data {
  $_[0]->_data;
}

sub get_objects {
  my ($self, %params) = @_;
  croak 'must parse first' unless $self->_parsed;

  $self->_make_objects unless $self->_objects;
  return wantarray ? @{ $self->_objects } : $self->_objects;
}

sub errors {
  @{ $_[0]->_errors }
}

sub check_header {
  $_[0]->_check_header;
}

# private stuff

sub _open_file {
  my ($self, %params) = @_;

  $self->encoding($self->_guess_encoding) if !$self->encoding;

  $self->_io->open($self->file, '<' . $self->_encode_layer)
    or die "could not open file " . $self->file;

  return $self->_io;
}

# check, if data is multiplexed and if all nessesary infos are given
sub _check_multiplexed {
  my ($self, %params) = @_;

  $self->is_multiplexed(0);

  # If more than one profile is given, it is multiplexed.
  if ($self->profile) {
    my @profile = @{ $self->profile };
    if (scalar @profile > 1) {
      # Each profile needs a class and a row_ident
      my $info_ok = all { defined $_->{class} && defined $_->{row_ident} } @profile;

      # If header is given, there need to be a header for each profile
      # and no empty headers.
      if ($info_ok && $self->header) {
        my @header = @{ $self->header };
        $info_ok = $info_ok && scalar @profile == scalar @header;
        $info_ok = $info_ok && all { scalar @$_ > 0} @header;
      }
      $self->is_multiplexed($info_ok);
      return $info_ok;
    }
  }

  # ok, if not multiplexed
  return 1;
}

sub _check_header {
  my ($self, %params) = @_;
  my $header;

  $header = $self->header;
  if (!$header) {
    my $n_header = ($self->is_multiplexed)? scalar @{ $self->profile } : 1;
    foreach my $p_num (0..$n_header - 1) {
      my $h = $self->_csv->getline($self->_io);

      $self->_push_error([
        $self->_csv->error_input,
        $self->_csv->error_diag,
        0,
      ]) unless $h;

      push @{ $header }, $h;
    }
  }

  # Special case: utf8 BOM.
  # certain software (namely MS Office and notepad.exe insist on prefixing
  # data with a discouraged but valid byte order mark
  # if not removed, the first header field will not be recognized
  if ($header) {
    my $h = $header->[0];
    if ($h && $h->[0] && $self->encoding =~ /utf-?8/i) {
      $h->[0] =~ s/^\x{FEFF}//;
    }
  }

  # check, if all header fields are parsed well
  return unless $header && all { $_ } @$header;

  # Special case: human stupidity
  # people insist that case sensitivity doesn't exist and try to enter all
  # sorts of stuff. at this point we've got a profile (with keys that represent
  # valid methods), and a header full of strings. if two of them match, the user
  # mopst likely meant that field, so rewrite the header
  if ($self->case_insensitive_header) {
    die 'case_insensitive_header is only possible with profile' unless $self->profile;
    if ($header) {
      my $p_num = 0;
      foreach my $h (@{ $header }) {
        my @names = (
          keys %{ $self->profile->[$p_num]->{profile} || {} },
        );
        for my $name (@names) {
          for my $i (0..$#$h) {
            $h->[$i] = $name if lc $h->[$i] eq lc $name;
          }
        }
        $p_num++;
      }
    }
  }

  return $self->header($header);
}

sub _parse_data {
  my ($self, %params) = @_;
  my (@data, @errors);

  while (1) {
    my $row = $self->_csv->getline($self->_io);
    if ($row) {
      my $header = $self->_header_by_row($row);
      my %hr;
      @hr{@{ $header }} = @$row;
      push @data, \%hr;
    } else {
      last if $self->_csv->eof;
      push @errors, [
        $self->_csv->error_input,
        $self->_csv->error_diag,
        $self->_io->input_line_number,
      ];
    }
    last if $self->_csv->eof;
  }

  $self->_data(\@data);
  $self->_push_error(@errors);

  return ! @errors;
}

sub _header_by_row {
  my ($self, $row) = @_;

  # initialize lookup hash if not already done
  if ($self->is_multiplexed && ! defined $self->_row_header ) {
    $self->_row_header({ pairwise { $a->{row_ident} => $b } @{ $self->profile }, @{ $self->header } });
  }
    
  if ($self->is_multiplexed) {
    return $self->_row_header->{$row->[0]}
  } else {
    return $self->header->[0];
  }
}

sub _encode_layer {
  ':encoding(' . $_[0]->encoding . ')';
}

sub _make_objects {
  my ($self, %params) = @_;
  my @objs;

  local $::myconfig{numberformat} = $self->numberformat if $self->numberformat;
  local $::myconfig{dateformat}   = $self->dateformat   if $self->dateformat;

  for my $line (@{ $self->_data }) {
    my $tmp_obj = $self->dispatcher->dispatch($line);
    push @objs, $tmp_obj;
  }

  $self->_objects(\@objs);
}

sub dispatcher {
  my ($self, %params) = @_;

  $self->{_dispatcher} ||= $self->_make_dispatcher;
}

sub _make_dispatcher {
  my ($self, %params) = @_;

  die 'need a header to make a dispatcher' unless $self->header;

  return SL::Helper::Csv::Dispatcher->new($self);
}

sub _guess_encoding {
  # won't fix
  'utf-8';
}

sub _push_error {
  my ($self, @errors) = @_;
  my @new_errors = ($self->errors, map { SL::Helper::Csv::Error->new(@$_) } @errors);
  $self->_errors(\@new_errors);
}


1;

__END__

=encoding utf-8

=head1 NAME

SL::Helper::Csv - take care of csv file uploads

=head1 SYNOPSIS

  use SL::Helper::Csv;

  my $csv = SL::Helper::Csv->new(
    file        => \$::form->{upload_file},
    encoding    => 'utf-8', # undef means utf8
    sep_char    => ',',     # default ';'
    quote_char  => '\'',    # default '"'
    escape_char => '"',     # default '"'
    header      => [ [qw(id text sellprice word)] ], # see later
    profile     => [ { profile => { sellprice => 'sellprice_as_number'},
                       class   => 'SL::DB::Part' } ],
  );

  my $status  = $csv->parse;
  my $hrefs   = $csv->get_data;
  my @objects = $csv->get_objects;

  my @errors  = $csv->errors;

=head1 DESCRIPTION

See Synopsis.

Text::CSV offeres already good functions to get lines out of a csv file, but in
most cases you will want those line to be parsed into hashes or even objects,
so this model just skips ahead and gives you objects.

Its basic assumptions are:

=over 4

=item You do know what you expect to be in that csv file.

This means first and foremost you have knowledge about encoding, number and
date format, csv parameters such as quoting and separation characters. You also
know what content will be in that csv and what L<Rose::DB> is responsible for
it. You provide valid header columns and their mapping to the objects.

=item You do NOT know if the csv provider yields to your expectations.

Stuff that does not work with what you expect should not crash anything, but
give you a hint what went wrong. As a result, if you remeber to check for
errors after each step, you should be fine.

=item Data does not make sense. It's just data.

Almost all data imports have some type of constraints. Some data needs to be
unique, other data needs to be connected to existing data sets. This will not
happen here. You will receive a plain mapping of the data into the class tree,
nothing more.

=item Multiplex data

This module can handle multiplexed data of different class types. In that case
multiple profiles with classes and row identifiers must be given. Multiple
headers may also be given or read from csv data. Data must contain the row
identifier in the first column and it's field name must be 'datatype'.

=back

=head1 METHODS

=over 4

=item C<new> PARAMS

Standard constructor. You can use this to set most of the data.

=item C<parse>

Do the actual work. Will return true ($self actually) if success, undef if not.

=item C<get_objects>

Parse the data into objects and return those.

This method will return list or arrayref depending on context.

=item C<get_data>

Returns an arrayref of the raw lines as hashrefs.

=item C<errors>

Return all errors that came up during parsing. See error handling for detailed
information.

=back

=head1 PARAMS

=over 4

=item C<file>

The file which contents are to be read. Can be a name of a physical file or a
scalar ref for memory data.

=item C<encoding>

Encoding of the CSV file. Note that this module does not do any encoding
guessing. Know what your data is. Defaults to utf-8.

=item C<sep_char>

=item C<quote_char>

=item C<escape_char>

Same as in L<Text::CSV>

=item C<header> \@HEADERS

If given, it contains an ARRAYREF for each different class type (i.e. one
ARRAYREF if the data is only of one class type). These ARRAYREFS are the header
fields which are an array of columns. In this case the first lines are not used
as a header. Empty header fields will be ignored in objects.

If not given, headers are taken from the first n lines of data, where n is the
number of different class types.

Examples:

  classic data of one type:
  [ [ 'name', 'street', 'zipcode', 'city' ] ]

  multiplexed data with two different types
  [ [ 'ordernumber', 'customer', 'transdate' ], [ 'partnumber', 'qty', 'sellprice' ] ]

=item C<profile> [{profile => \%ACCESSORS, class => class, row_ident => ri},]

This is an ARRAYREF to HASHREFs which may contain the keys C<profile>, C<class>
and C<row_ident>.

The C<profile> is a HASHREF which may be used to map header fields to custom
accessors. Example:

  [ {profile => { listprice => listprice_as_number }} ]

In this case C<listprice_as_number> will be used to read in values from the
C<listprice> column.

In case of a One-To-One relationsship these can also be set over
relationsships by sparating the steps with a dot (C<.>). This will work:

  [ {profile => { customer => 'customer.name' }} ]

And will result in something like this:

  $obj->customer($obj->meta->relationship('customer')->class->new);
  $obj->customer->name($csv_line->{customer})

But beware, this will not try to look up anything in the database. You will
simply receive objects that represent what the profile defined. If some of
these information are unique, and should be connected to preexisting data, you
will have to do that for yourself. Since you provided the profile, it is
assumed you know what to do in this case.

If no profile is given, any header field found will be taken as is.

If the path in a profile entry is empty, the field will be subjected to
C<strict_profile> and C<case_insensitive_header> checking, will be parsed into
C<get_data>, but will not be attempted to be dispatched into objects.

If C<class> is present, the line will be handed to the new sub of this class,
and the return value used instead of the line itself.

C<row_ident> is a string to recognize the right profile and class for each data
line in multiplexed data.

In case of multiplexed data, C<class> and C<row_ident> must be given.
Example:
  [ {
      class     => 'SL::DB::Order',
      row_ident => 'O'
    },
    {
      class     => 'SL::DB::OrderItem',
      row_ident => 'I',
      profile   => {sellprice => sellprice_as_number}
    } ]

=item C<ignore_unknown_columns>

If set, the import will ignore unkown header columns. Useful for lazy imports,
but deactivated by default.

=item C<case_insensitive_header>

If set, header columns will be matched against profile entries case
insensitive, and on match the profile name will be taken.

Only works if a profile is given, will die otherwise.

If both C<case_insensitive_header> and C<strict_profile> is set, matched header
columns will be accepted.

=item C<strict_profile>

If set, all columns to be parsed must be specified in C<profile>. Every header
field not listed there will be treated like an unknown column.

If both C<case_insensitive_header> and C<strict_profile> is set, matched header
columns will be accepted.

=back

=head1 ERROR HANDLING

After parsing a file all errors will be accumulated into C<errors>.
Each entry is an object with the following attributes:

 raw_input:  offending raw input,
 code:   Text::CSV error code if Text:CSV signalled an error, 0 else,
 diag:   error diagnostics,
 line:   position in line,
 col:    estimated line in file,

Note that the last entry can be off, but will give an estimate.

=head1 CAVEATS

=over 4

=item *

sep_char, quote_char, and escape_char are passed to Text::CSV on creation.
Changing them later has no effect currently.

=item *

Encoding errors are not dealt with properly.

=back

=head1 TODO

Dispatch to child objects, like this:

 $csv = SL::Helper::Csv->new(
   file    => ...
   profile => [ {
     profile => [
       makemodel => {
         make_1  => make,
         model_1 => model,
       },
       makemodel => {
         make_2  => make,
         model_2 => model,
       },
     ],
     class   => SL::DB::Part,
   } ]
 );

=head1 AUTHOR

Sven Schöling E<lt>s.schoeling@linet-services.deE<gt>

=cut
