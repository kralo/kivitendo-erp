# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::CsvImportReport;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('csv_import_reports');

__PACKAGE__->meta->columns(
  id         => { type => 'serial', not_null => 1 },
  session_id => { type => 'text', not_null => 1 },
  profile_id => { type => 'integer', not_null => 1 },
  type       => { type => 'text', not_null => 1 },
  file       => { type => 'text', not_null => 1 },
  numrows    => { type => 'integer' },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

__PACKAGE__->meta->foreign_keys(
  profile => {
    class       => 'SL::DB::CsvImportProfile',
    key_columns => { profile_id => 'id' },
  },
);

# __PACKAGE__->meta->initialize;

1;
;
