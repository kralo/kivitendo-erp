use Test::More tests => 56;

use lib 't';
use utf8;

use Data::Dumper;
use Support::TestSetup;

use_ok 'SL::Helper::Csv';

Support::TestSetup::login();

my $csv = SL::Helper::Csv->new(
  file    => \"Kaffee\n",       # " # make emacs happy
  header  => [[ 'description' ]],
  profile => [{ class  => 'SL::DB::Part', }],
);

isa_ok $csv->_csv, 'Text::CSV_XS';
isa_ok $csv->_io, 'IO::File';
isa_ok $csv->parse, 'SL::Helper::Csv', 'parsing returns self';
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'simple case works';

is $csv->get_objects->[0]->description, 'Kaffee', 'get_object works';
####

$::myconfig{numberformat} = '1.000,00';
$::myconfig{dateformat} = 'dd.mm.yyyy';

$csv = SL::Helper::Csv->new(
  file    => \"Kaffee;0.12;12,2;1,5234\n",
  header  => [[ 'description', 'sellprice', 'lastcost_as_number', 'listprice' ]],
  profile => [{profile => { listprice => 'listprice_as_number' },
               class   => 'SL::DB::Part',}],
);
$csv->parse;

is $csv->get_objects->[0]->sellprice, 0.12, 'numeric attr works';
is $csv->get_objects->[0]->lastcost, 12.2, 'attr helper works';
is $csv->get_objects->[0]->listprice, 1.5234, 'dispatch works';

#####


$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description,sellprice,lastcost_as_number,listprice,
Kaffee,0.12,'12,2','1,5234'
EOL
  sep_char => ',',
  quote_char => "'",
  profile => [{profile => { listprice => 'listprice_as_number' },
               class   => 'SL::DB::Part',}]
);
$csv->parse;
is scalar @{ $csv->get_objects }, 1, 'auto header works';
is $csv->get_objects->[0]->description, 'Kaffee', 'get_object works on auto header';

#####


$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
;;description;sellprice;lastcost_as_number;
#####;Puppy;Kaffee;0.12;12,2;1,5234
EOL
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is scalar @{ $csv->get_objects }, 1, 'bozo header doesn\'t blow things up';

#####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;
Kaffee;;0.12;12,2;1,5234
Beer;1123245;0.12;12,2;1,5234
EOL
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is scalar @{ $csv->get_objects }, 2, 'multiple objects work';
is $csv->get_objects->[0]->description, 'Kaffee', 'first object';
is $csv->get_objects->[1]->partnumber, '1123245', 'second object';

####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;
Kaffee;;0.12;1,221.52
Beer;1123245;0.12;1.5234
EOL
  numberformat => '1,000.00',
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is $csv->get_objects->[0]->lastcost, '1221.52', 'formatnumber';

######

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
"description;partnumber;sellprice;lastcost_as_number;
Kaffee;;0.12;1,221.52
Beer;1123245;0.12;1.5234
EOL
  numberformat => '1,000.00',
  profile => [{class  => 'SL::DB::Part'}],
);
is $csv->parse, undef, 'broken csv header won\'t get parsed';

######

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;
"Kaf"fee";;0.12;1,221.52
Beer;1123245;0.12;1.5234
EOL
  numberformat => '1,000.00',
  profile => [{class  => 'SL::DB::Part'}],
);
is $csv->parse, undef, 'broken csv content won\'t get parsed';
is_deeply $csv->errors, [ '"Kaf"fee";;0.12;1,221.52'."\n", 2023, 'EIQ - QUO character not allowed', 5, 2 ], 'error';
isa_ok( ($csv->errors)[0], 'SL::Helper::Csv::Error', 'Errors get objectified');

####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;wiener;
Kaffee;;0.12;1,221.52;ja wiener
Beer;1123245;0.12;1.5234;nein kein wieder
EOL
  numberformat => '1,000.00',
  ignore_unknown_columns => 1,
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is $csv->get_objects->[0]->lastcost, '1221.52', 'ignore_unkown_columns works';

#####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;buchungsgruppe;
Kaffee;;0.12;1,221.52;Standard 7%
Beer;1123245;0.12;1.5234;16 %
EOL
  numberformat => '1,000.00',
  profile => [{
    profile => {buchungsgruppe => "buchungsgruppen.description"},
    class  => 'SL::DB::Part',
  }]
);
$csv->parse;
isa_ok $csv->get_objects->[0]->buchungsgruppe, 'SL::DB::Buchungsgruppe', 'deep dispatch auto vivify works';
is $csv->get_objects->[0]->buchungsgruppe->description, 'Standard 7%', '...and gets set correctly';


#####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;make_1;model_1;
  Kaffee;;0.12;1,221.52;213;Chair 0815
Beer;1123245;0.12;1.5234;
EOL
  numberformat => '1,000.00',
  profile => [{
    profile => {
      make_1 => "makemodels.0.make",
      model_1 => "makemodels.0.model",
    },
    class  => 'SL::DB::Part',
  }],
);
$csv->parse;
my @mm = $csv->get_objects->[0]->makemodel;
is scalar @mm,  1, 'one-to-many dispatch';
is $csv->get_objects->[0]->makemodels->[0]->model, 'Chair 0815', '... and works';

#####


$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;make_1;model_1;make_2;model_2;
 Kaffee;;0.12;1,221.52;213;Chair 0815;523;Table 15
EOL
  numberformat => '1,000.00',
  profile => [{
    profile => {
      make_1 => "makemodels.0.make",
      model_1 => "makemodels.0.model",
      make_2 => "makemodels.1.make",
      model_2 => "makemodels.1.model",
    },
    class  => 'SL::DB::Part',
  }]
);
$csv->parse;

print Dumper($csv->errors);

@mm = $csv->get_objects->[0]->makemodel;
is scalar @mm,  1, 'multiple one-to-many dispatch';
is $csv->get_objects->[0]->makemodels->[0]->model, 'Chair 0815', '...check 1';
is $csv->get_objects->[0]->makemodels->[0]->make, '213', '...check 2';
is $csv->get_objects->[0]->makemodels->[1]->model, 'Table 15', '...check 3';
is $csv->get_objects->[0]->makemodels->[1]->make, '523', '...check 4';

######

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost_as_number;buchungsgruppe;
EOL
  numberformat => '1,000.00',
  profile => [{
    profile => {buchungsgruppe => "buchungsgruppen.1.description"},
    class  => 'SL::DB::Part',
  }]
);
is $csv->parse, undef, 'wrong profile gets rejected';
is_deeply $csv->errors, [ 'buchungsgruppen.1.description', undef, "Profile path error. Indexed relationship is not OneToMany around here: 'buchungsgruppen.1'", undef ,0 ], 'error indicates wrong header';
isa_ok( ($csv->errors)[0], 'SL::Helper::Csv::Error', 'Errors get objectified');

####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost;wiener;
Kaffee;;0.12;1,221.52;ja wiener
Beer;1123245;0.12;1.5234;nein kein wieder
EOL
  numberformat => '1,000.00',
  ignore_unknown_columns => 1,
  strict_profile => 1,
  profile => [{
    profile => {lastcost => 'lastcost_as_number'},
    class  => 'SL::DB::Part',
  }]
);
$csv->parse;
is $csv->get_objects->[0]->lastcost, '1221.52', 'strict_profile with ignore';
is $csv->get_objects->[0]->sellprice, undef,  'strict profile with ignore 2';

####

$csv = SL::Helper::Csv->new(
  file   => \<<EOL,
description;partnumber;sellprice;lastcost;wiener;
Kaffee;;0.12;1,221.52;ja wiener
Beer;1123245;0.12;1.5234;nein kein wieder
EOL
  numberformat => '1,000.00',
  strict_profile => 1,
  profile => [{
    profile => {lastcost => 'lastcost_as_number'},
    class  => 'SL::DB::Part',
  }]
);
$csv->parse;

is_deeply( ($csv->errors)[0], [ 'description', undef, 'header field \'description\' is not recognized', undef, 0 ], 'strict_profile without ignore_columns throws error');

#####

$csv = SL::Helper::Csv->new(
  file   => \"Kaffee",
  header =>  [[ 'description' ]],
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'eol bug at the end of files';

#####

$csv = SL::Helper::Csv->new(
  file   => \"Description\nKaffee",
  case_insensitive_header => 1,
  profile => [ {profile => { description => 'description' }, class  => 'SL::DB::Part'} ],
);
$csv->parse;
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'case insensitive header from csv works';

#####

$csv = SL::Helper::Csv->new(
  file   => \"Kaffee",
  header =>  [[ 'Description' ]],
  profile => [{profile => { description => 'description' }, {class  => 'SL::DB::Part'}],
);
$csv->parse;
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'case insensitive header as param works';

#####

$csv = SL::Helper::Csv->new(
  file   => \"\x{FEFF}description\nKaffee",
  profile => [{class  => 'SL::DB::Part'}],
  encoding => 'utf8',
);
$csv->parse;
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'utf8 BOM works (bug 1872)';

#####

$csv = SL::Helper::Csv->new(
  file   => \"Kaffee",
  header => [[ 'Description' ]],
  profile => [{class  => 'SL::DB::Part'}],
);
$csv->parse;
is_deeply $csv->get_data, undef, 'case insensitive header without flag ignores';

#####
my $csv = SL::Helper::Csv->new(
  file    => \"Kaffee;1,50\nSchoke;0,89\n",
  header  => [
    [ 'datatype', 'description', 'sellprice' ],
  ],
  profile => [
    { profile   => { sellprice => 'sellprice_as_number' },
      class     => 'SL::DB::Part',}
  ],
);

ok $csv->_check_multiplexed, 'multiplex check works on not-multiplexed data';
ok !$csv->is_multiplexed, 'not-multiplexed data is recognized';

#####
my $csv = SL::Helper::Csv->new(
  file    => \"P;Kaffee;1,50\nC;Meier\n",
  header  => [
    [ 'datatype', 'description', 'listprice' ],
    [ 'datatype', 'name' ],
  ],
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      class     => 'SL::DB::Part',
      row_ident => 'P' },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
);
$csv->parse;

ok $csv->_check_multiplexed, 'multiplex check works on multiplexed data';
ok $csv->is_multiplexed, 'multiplexed data is recognized';

#####
my $csv = SL::Helper::Csv->new(
  file    => \"P;Kaffee;1,50\nC;Meier\n",
  header  => [
    [ 'datatype', 'description', 'listprice' ],
    [ 'datatype', 'name' ],
  ],
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      class     => 'SL::DB::Part', },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
);

ok !$csv->_check_multiplexed, 'multiplex check works on multiplexed data an detects missing row_ident';

#####
my $csv = SL::Helper::Csv->new(
  file    => \"P;Kaffee;1,50\nC;Meier\n",
  header  => [
    [ 'datatype', 'description', 'listprice' ],
    [ 'datatype', 'name' ],
  ],
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      row_ident => 'P' },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
);
$csv->parse;

ok !$csv->_check_multiplexed, 'multiplex check works on multiplexed data an detects missing class';

#####
my $csv = SL::Helper::Csv->new(
  file    => \"P;Kaffee;1,50\nC;Meier\n",  # " # make emacs happy
  header  => [
    [ 'datatype', 'description', 'listprice' ],
  ],
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      class     => 'SL::DB::Part',
      row_ident => 'P' },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
);

ok !$csv->_check_multiplexed, 'multiplex check works on multiplexed data an detects missing header';

#####

my $csv = SL::Helper::Csv->new(
  file    => \"P;Kaffee;1,50\nC;Meier\n",  # " # make emacs happy
  header  => [
    [ 'datatype', 'description', 'listprice' ],
    [ 'datatype', 'name' ],
  ],
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      class     => 'SL::DB::Part',
      row_ident => 'P' },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
  ignore_unknown_columns => 1,
);
$csv->parse;
is_deeply $csv->get_data,
    [ { datatype => 'P', description => 'Kaffee', listprice => '1,50' }, { datatype => 'C', name => 'Meier' } ],
    'multiplex: simple case works';
is scalar @{ $csv->get_objects }, 2, 'multiplex: multiple objects work';
is $csv->get_objects->[0]->description, 'Kaffee', 'multiplex: first object';
is $csv->get_objects->[1]->name,        'Meier',  'multiplex: second object';

#####

my $csv = SL::Helper::Csv->new(
  file    => \"datatype;description;listprice\ndatatype;name\nP;Kaffee;1,50\nC;Meier\n",  # " # make emacs happy
  profile => [
    { profile   => { listprice => 'listprice_as_number' },
      class     => 'SL::DB::Part',
      row_ident => 'P' },
    { class  => 'SL::DB::Customer',
      row_ident => 'C' }
  ],
  ignore_unknown_columns => 1,
);

$csv->parse;
is_deeply $csv->get_data, [ { description => 'Kaffee' } ], 'without profile and class works';

# vim: ft=perl
# set emacs to perl mode
# Local Variables:
# mode: perl
# End:
