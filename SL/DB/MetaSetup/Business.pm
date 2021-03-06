# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::Business;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('business');

__PACKAGE__->meta->columns(
  id                 => { type => 'integer', not_null => 1, sequence => 'id' },
  description        => { type => 'text' },
  discount           => { type => 'float', precision => 4 },
  customernumberinit => { type => 'text' },
  salesman           => { type => 'boolean', default => 'false' },
  itime              => { type => 'timestamp', default => 'now()' },
  mtime              => { type => 'timestamp' },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

__PACKAGE__->meta->allow_inline_column_values(1);

# __PACKAGE__->meta->initialize;

1;
;
