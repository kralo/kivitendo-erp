# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::Unit;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('units');

__PACKAGE__->meta->columns(
  name      => { type => 'varchar', length => 20, not_null => 1 },
  base_unit => { type => 'varchar', length => 20 },
  factor    => { type => 'numeric', precision => 5, scale => 20 },
  type      => { type => 'varchar', length => 20 },
  sortkey   => { type => 'integer', not_null => 1 },
  id        => { type => 'serial', not_null => 1 },
);

__PACKAGE__->meta->primary_key_columns([ 'name' ]);

__PACKAGE__->meta->unique_keys([ 'id' ]);

__PACKAGE__->meta->foreign_keys(
  unit => {
    class       => 'SL::DB::Unit',
    key_columns => { base_unit => 'name' },
  },
);

# __PACKAGE__->meta->initialize;

1;
;
