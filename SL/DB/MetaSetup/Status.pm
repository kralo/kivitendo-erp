# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::Status;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('status');

__PACKAGE__->meta->columns(
  trans_id  => { type => 'integer' },
  formname  => { type => 'text' },
  printed   => { type => 'boolean', default => 'false' },
  emailed   => { type => 'boolean', default => 'false' },
  spoolfile => { type => 'text' },
  chart_id  => { type => 'integer' },
  itime     => { type => 'timestamp', default => 'now()' },
  mtime     => { type => 'timestamp' },
  id        => { type => 'serial', not_null => 1 },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

__PACKAGE__->meta->allow_inline_column_values(1);

# __PACKAGE__->meta->initialize;

1;
;
